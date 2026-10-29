local M = {}

--- Byte index of the first significant char at or after `from`, skipping
--- whitespace and (line-local, non-nesting) `/* … */` block comments. Quotes
--- are SIGNIFICANT here, not region-skips: the caller may be about to read a
--- quoted name (`USE "my db"`), and a quote inside a comment is consumed by
--- the comment branch anyway. An unterminated comment skips to the end. Used
--- before matching a keyword so `USE /* default */ mydb` sees the keyword
--- where a comment actually starts, not inside one.
local function skip_ws_and_block_comments(s, from)
  local i = from
  while i <= #s do
    local ch = s:sub(i, i)
    if ch == "/" and s:sub(i + 1, i + 1) == "*" then
      local close = s:find("*/", i + 2, true)
      if not close then return #s + 1 end
      i = close + 2
    elseif ch:match("^%s$") then
      i = i + 1
    else
      return i
    end
  end
  return i
end

--- TEST-ONLY surface: no production caller (kept alive by sql_lex_spec).
--- Its string reading differs from the live scanners on purpose of history:
--- this treats `\` as an escape inside EVERY quoting style (lex.lua:49),
--- while blank_regions and dml_guard's strip_non_code read backslash as
--- ordinary content. If this is ever wired back into a boundary or comment
--- path, reconcile the two readings first — the three-scanners-disagree
--- class is what LEARNINGS #11 records.
function M.is_comment_or_string(line, pos)
  local i = 1
  local region_start = nil
  local region_type = nil
  local string_char = nil
  local in_block_comment = 0

  while i <= #line do
    local ch = line:sub(i, i)
    if region_type == "line_comment" then
      if pos >= region_start then return true end
      i = i + 1
    elseif region_type == "block_comment" then
      if ch == "*" and line:sub(i + 1, i + 1) == "/" then
        if pos >= region_start and pos <= i + 1 then return true end
        in_block_comment = in_block_comment - 1
        if in_block_comment == 0 then region_type = nil; region_start = nil end
        i = i + 2
      else
        i = i + 1
      end
    elseif region_type == "string" then
      if ch == "\\" then
        i = i + 2
      elseif ch == string_char then
        if pos >= region_start and pos <= i then return true end
        region_type = nil; region_start = nil; string_char = nil
        i = i + 1
      else
        i = i + 1
      end
    elseif ch == "-" and line:sub(i + 1, i + 1) == "-" then
      region_start = i; region_type = "line_comment"; i = i + 2
    elseif ch == "/" and line:sub(i + 1, i + 1) == "*" then
      if in_block_comment == 0 then region_start = i; region_type = "block_comment" end
      in_block_comment = in_block_comment + 1; i = i + 2
    elseif ch == "'" or ch == '"' or ch == "`" then
      region_start = i; region_type = "string"; string_char = ch; i = i + 1
    else
      i = i + 1
    end
  end
  if region_type == "line_comment" and pos >= region_start then return true end
  if region_type == "block_comment" and pos >= region_start then return true end
  if region_type == "string" and pos >= region_start then return true end
  return false
end

--- Extract the database name from a `USE <name>` line, or nil.
--- Handles: case-insensitive USE, a trailing `;`, quoted names (including
--- spaces inside quotes), MSSQL bracket-quoted names (`USE [My DB]` is the
--- canonical T-SQL spelling and used to come back cut at the space), and
--- leading block comments (`USE /* d */ mydb` used to return the comment as
--- the name). A `--` line comment after the name is naturally excluded
--- because the bare-name scan stops at whitespace. A USE inside a multi-line
--- block comment is the caller's concern — pair this with
--- `block_comment_depth_after` when scanning a buffer line by line.
function M.find_use_database(line)
  if not line then return nil end
  local trimmed = line:match("^%s*(.-)%s*$") or ""
  if trimmed == "" then return nil end
  local start = skip_ws_and_block_comments(trimmed, 1)
  local kw_start, kw_end = trimmed:find("^[Uu][Ss][Ee]", start)
  if not kw_start then return nil end
  -- USE must be its own word: `USER` … must not match
  local after = trimmed:sub(kw_end + 1)
  if after ~= "" and after:match("^[%s_/]") == nil then return nil end
  local name_pos = skip_ws_and_block_comments(trimmed, kw_end + 1)
  if name_pos > #trimmed then return nil end
  local quote = trimmed:sub(name_pos, name_pos)
  if quote == '"' or quote == "'" or quote == "`" then
    local close = trimmed:find(quote, name_pos + 1, true)
    if not close then return nil end
    local name = trimmed:sub(name_pos + 1, close - 1)
    if name == "" then return nil end
    return name
  end
  if quote == "[" then
    -- T-SQL bracket-quoted identifier. A `]` inside brackets is doubled
    -- (`]]`) in T-SQL; scan for the closer that is NOT part of a pair, the
    -- same reading the server applies.
    local close = trimmed:find("]", name_pos + 1, true)
    while close and trimmed:sub(close + 1, close + 1) == "]" do
      close = trimmed:find("]", close + 2, true)
    end
    if not close then return nil end
    local name = trimmed:sub(name_pos + 1, close - 1):gsub("]]", "]")
    if name == "" then return nil end
    return name
  end
  -- bare name: up to whitespace or `;` (`USE db;-- c` used to return `db;--`)
  local name = trimmed:match("^[^%s;]+", name_pos) or ""
  name = name:gsub(";$", "")
  if name == "" then return nil end
  return name
end

--- Block-comment depth at end-of-line, given the depth at line start, so a
--- scanner walking a buffer line by line can know whether a line sits inside
--- a `/* … */` region that opened on an earlier line (a bare `USE foo` inside
--- one must not switch the database). Strings and `--` line comments are
--- respected, so markers inside them don't count; depth saturates at 0
--- because a stray `*/` must not go negative.
---
--- SINGLE-LEVEL on purpose: `is_comment_or_string` and `blank_regions` close
--- at the first `*/` no matter how many `/*` opened, and this reader used to
--- nest while they did not — the three scanners disagreed on the same text
--- (`/* /* */ */` was "still in comment" here, plain code there). postgres
--- alone nests block comments; treating `/*` at depth 1 as text is the
--- conservative rule every consumer shares. If nesting ever becomes
--- dialect-aware, all three readers move together.
function M.block_comment_depth_after(line, depth)
  depth = depth or 0
  local i, in_string, string_char = 1, false, nil
  while i <= #line do
    local ch = line:sub(i, i)
    if in_string then
      if ch == "\\" and string_char ~= "`" then
        i = i + 2 -- backslash escape in '-strings (backticks take `\` literally)
      elseif ch == string_char then
        in_string = false
        i = i + 1
      else
        i = i + 1
      end
    elseif ch == "'" or ch == '"' or ch == "`" then
      in_string, string_char = true, ch
      i = i + 1
    elseif ch == "-" and line:sub(i + 1, i + 1) == "-" then
      break -- line comment: nothing later on the line counts
    elseif ch == "/" and line:sub(i + 1, i + 1) == "*" then
      if depth == 0 then depth = 1 end
      i = i + 2
    elseif ch == "*" and line:sub(i + 1, i + 1) == "/" then
      depth = math.max(0, depth - 1)
      i = i + 2
    else
      i = i + 1
    end
  end
  return depth
end

local OPEN_QUOTE = { ["'"] = "squote", ['"'] = "dquote", ["`"] = "bquote" }
local CLOSE_QUOTE = { squote = "'", dquote = '"', bquote = "`" }
-- `$` opens a tag only when a closing `$` follows at once (`$$`) or after a
-- run of identifier chars (`$body$`); `$1` is a placeholder, not a tag.
local DOLLAR_TAG = "^%$[%w_]*%$"

--- Blank every region the keyword/`;` scans must not see, keeping newlines so
--- per-line arithmetic over the output still matches the input. Blanked:
--- single-quoted literals (`''` is the escape; an unterminated one blanks
--- through the end), `--` line comments, `/* */` block comments and
--- dollar-quoted bodies (`$$ … $$`, `$tag$ … $tag$`) — a function body's
--- `DELETE FROM t` is not the outer statement's code.
---
--- `keep_quoted_idents` decides double-quoted/backtick regions: kept verbatim
--- they are identifiers feeding name captures ("my--table" survives; the `--`
--- inside it no longer reads as a comment and kills the parse), blanked the
--- `;` inside "…" cannot end a statement for the ;-scan.
---
--- One state machine, because a gsub chain fails both ways: stripping
--- comments first lets a `--` inside `'a--b'` swallow the FROM (the query
--- loses its table name); blanking literals first lets the apostrophe in
--- `-- don't` open a phantom literal that erases real code. No backslash
--- escape reading — this is the standard-conforming (postgres/sqlite) scan,
--- the same one the extraction has always used; the dialect-aware readings
--- live on the Rust side and in dml_guard's both-readings guard scan.
---
--- Length-preserving: every consumed byte emits exactly one output byte, so
--- offsets into the output are offsets into the input.
--- @param sql string
--- @param keep_quoted_idents boolean|nil  keep "…" and `…` regions verbatim
--- @return string
function M.blank_regions(sql, keep_quoted_idents)
  local out = {}
  local i, n = 1, #sql
  local state = "code"
  local tag = nil
  while i <= n do
    local c = sql:sub(i, i)
    if state == "code" then
      local nx = sql:sub(i + 1, i + 1)
      local dtag = (c == "$") and sql:match(DOLLAR_TAG, i) or nil
      if c == "-" and nx == "-" then
        out[#out + 1] = "  "
        state, i = "line", i + 2
      elseif c == "/" and nx == "*" then
        out[#out + 1] = "  "
        state, i = "block", i + 2
      elseif dtag then
        out[#out + 1] = string.rep(" ", #dtag)
        tag, state, i = dtag, "dollar", i + #dtag
      elseif OPEN_QUOTE[c] then
        state = OPEN_QUOTE[c]
        -- a kept region must keep BOTH its quotes, or the survivors read as
        -- unbalanced junk ("users`" instead of the identifier "users")
        out[#out + 1] = (keep_quoted_idents and state ~= "squote") and c or " "
        i = i + 1
      else
        out[#out + 1] = c
        i = i + 1
      end
    elseif state == "line" then
      out[#out + 1] = (c == "\n") and "\n" or " "
      if c == "\n" then state = "code" end
      i = i + 1
    elseif state == "block" then
      if c == "*" and sql:sub(i + 1, i + 1) == "/" then
        out[#out + 1] = "  "
        state, i = "code", i + 2
      else
        out[#out + 1] = (c == "\n") and "\n" or " "
        i = i + 1
      end
    elseif state == "dollar" then
      if sql:find(tag, i, true) == i then
        out[#out + 1] = string.rep(" ", #tag)
        state, tag, i = "code", nil, i + #tag
      else
        out[#out + 1] = (c == "\n") and "\n" or " "
        i = i + 1
      end
    else
      local closing = CLOSE_QUOTE[state]
      local keep = keep_quoted_idents and (state == "dquote" or state == "bquote")
      if c == closing then
        if sql:sub(i + 1, i + 1) == closing then
          out[#out + 1] = keep and (closing .. closing) or "  "
          i = i + 2 -- doubled quote: still inside the region
        else
          out[#out + 1] = keep and closing or " "
          state, i = "code", i + 1
        end
      else
        out[#out + 1] = keep and c or ((c == "\n") and "\n" or " ")
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

function M.find_block_for_line(lines, cursor_line)
  local block_start = 1
  for i = cursor_line - 1, 1, -1 do
    if lines[i] and lines[i]:match("^%s*###") then
      block_start = i + 1
      break
    end
  end
  return block_start
end

return M