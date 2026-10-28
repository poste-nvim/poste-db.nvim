--- SQL statement extraction utilities.
---
--- Pure functions for finding and extracting SQL statements from a buffer.
--- Extracted from sql/init.lua to reduce module size and improve testability.

local cli = require("poste-db.cli")
local util = require("poste-db.util")
local log = require("poste-db.log")
local ts_stmt = require("poste-db.ts_stmt")
local const = require("poste-db.constants")
local compat = require("poste-db.compat")
local lex = require("poste-db.lex")

local M = {}

---------------------------------------------------------------------------
-- Block boundary detection
---------------------------------------------------------------------------

--- Find the ###-delimited block containing a given line.
--- Returns (block_start, block_end) as 1-based line numbers.
function M.find_block_for_line(buf_lines, line)
  -- Search backward for the opening ###
  local start = line
  while start >= 1 do
    if const.is_section_marker(buf_lines[start]) then
      start = start + 1  -- skip past the ### line
      break
    end
    if start == 1 then break end
    start = start - 1
  end
  -- Search forward for the closing ### (or end of buffer)
  local finish = line
  while finish < #buf_lines do
    if const.is_section_marker(buf_lines[finish + 1]) then
      break
    end
    finish = finish + 1
  end
  return start, finish
end

--- Try to find statement boundaries using the Rust binary.
--- Returns {start_line, end_line} as 1-based buffer line numbers, or nil.
--- `dialect` (when resolvable) makes the binary read string literals the way
--- exec-file splits the same buffer — run-statement-under-cursor and run-file
--- must agree on where a MySQL `'it\'s'` puts the boundary.
function M.try_rust_stmt_span(buf_lines, cursor_line, dialect)
  -- Find the current ### block to limit the scope
  local block_start, block_end = M.find_block_for_line(buf_lines, cursor_line)

  -- Extract block lines and compute relative cursor
  local block_lines = {}
  for i = block_start, block_end do
    block_lines[#block_lines + 1] = buf_lines[i] or ""
  end
  local rel_cursor = cursor_line - block_start  -- 0-based within block

  -- Call Rust binary
  local input = table.concat(block_lines, "\n")
  local args = { "context", "stmt", tostring(rel_cursor) }
  if dialect and dialect ~= "" then
    args[#args + 1] = "--dialect"
    args[#args + 1] = dialect
  end
  local parsed, err = cli.run_json(args, { stdin = input })
  if not parsed then
    log.warn("context stmt failed: " .. tostring(err))
    return nil
  end

  -- Convert Rust 0-based lines to absolute Lua 1-based lines
  local rust_start = parsed.start_line
  local rust_end = parsed.end_line
  if type(rust_start) ~= "number" or type(rust_end) ~= "number" then return nil end

  local abs_start = block_start + rust_start
  local abs_end = block_start + rust_end
  if compat.opt("debug") then
    vim.notify(string.format("[poste] Rust stmt span: relative=(%d,%d) absolute=(%d,%d)",
      rust_start, rust_end, abs_start, abs_end), vim.log.levels.INFO)
  end

  return { abs_start, abs_end }
end

--- Try to find ALL statement boundaries using the Rust binary.
--- Calls `poste context stmt-ranges` which returns semantic boundaries
--- without relying on ';'.
--- Returns number[] of 1-based buffer statement start lines, or nil.
--- `dialect` threads the quote-escape reading — see try_rust_stmt_span.
function M.try_rust_stmt_ranges(buf_lines, start_line, end_line, dialect)
  -- Extract the range of lines
  local range_lines = {}
  for i = start_line, end_line do
    range_lines[#range_lines + 1] = buf_lines[i] or ""
  end

  local input = table.concat(range_lines, "\n")
  local args = { "context", "stmt-ranges" }
  if dialect and dialect ~= "" then
    args[#args + 1] = "--dialect"
    args[#args + 1] = dialect
  end
  local parsed, err = cli.run_json(args, { stdin = input })
  if not parsed then
    log.warn("context stmt-ranges failed: " .. tostring(err))
    return nil
  end

  if type(parsed) ~= "table" or #parsed == 0 then return nil end

  -- parsed is [[start0, end0], [start1, end1], ...] (0-based, relative to range)
  local stmt_lines = {}
  for _, pair in ipairs(parsed) do
    local rs, re
    if type(pair[1]) == "number" then
      rs, re = pair[1], pair[2]
    elseif type(pair.start_line) == "number" then
      rs, re = pair.start_line, pair.end_line
    else
      goto continue_range
    end
    local abs_start = start_line + rs
    local abs_end = start_line + (re or rs)
    -- Advance past blank/directive/comment lines within the range
    while abs_start <= abs_end and abs_start <= end_line do
      local t = (buf_lines[abs_start] or ""):match("^%s*(.*)$") or ""
      if t == "" or t:match("^%-%-") or const.is_section_marker(t) or t:upper():match("^USE ") then
        abs_start = abs_start + 1
      else
        break
      end
    end
    if abs_start <= end_line then
      table.insert(stmt_lines, abs_start)
    end
    ::continue_range::
  end

  return #stmt_lines > 0 and stmt_lines or nil
end

--- Try to find statement boundaries using Tree-sitter.
--- Returns {start_line, end_line} as 1-based buffer line numbers, or nil.
function M.try_ts_stmt_span(buf, cursor_line)
  local ok, result = pcall(ts_stmt.find_stmt_span, buf, cursor_line)
  if ok and result then
    return result
  end
  return nil
end

--- True when a visual selection ends in the MIDDLE of a statement — the
--- statement under the selection's last line continues past it, so executing
--- the selection would send a fragment (a VALUES-less INSERT ran as exactly
--- that and failed with a confusing 1064 "near ''"). A selection that ends
--- on the statement's last line, on a blank/comment line between statements,
--- or at the buffer's unterminated end is not a cut. nil when neither
--- Tree-sitter nor the binary could read the statement span: degrade to the
--- old execute-anyway behavior rather than block a legitimate run.
--- @param buf number|nil  buffer handle (for Tree-sitter)
--- @param buf_lines string[]
--- @param sel_end number  1-based last line of the visual selection
--- @param dialect string|nil  quote-escape reading for the Rust fallback
--- @return boolean|nil
function M.selection_cuts_statement(buf, buf_lines, sel_end, dialect)
  local span = M.try_ts_stmt_span(buf, sel_end)
  if not span and type(buf_lines) == "table" then
    -- the binary fallback reads the buffer text, so it needs the lines
    span = M.try_rust_stmt_span(buf_lines, sel_end, dialect)
  end
  if not span or type(span[1]) ~= "number" or type(span[2]) ~= "number" then
    return nil
  end
  -- A detected span that starts below the selection's last line (the blank-
  -- line walks can land on the NEXT statement) is not a cut; an inverted
  -- span is detector noise, not evidence either way.
  if span[1] > sel_end or span[2] < span[1] then
    return false
  end
  return span[2] > sel_end
end

--- Try to find ALL statement boundaries using Tree-sitter.
--- Returns number[] of 1-based buffer statement start lines, or nil.
function M.try_ts_stmt_ranges(buf, start_line, end_line)
  local ok, result = pcall(ts_stmt.find_all_stmt_lines, buf, start_line, end_line)
  if ok and result then
    return result
  end
  return nil
end

---------------------------------------------------------------------------
-- Single-statement extraction
---------------------------------------------------------------------------

local function has_sql_content(stmt_lines, start, stop)
  for i = start, stop do
    local l = stmt_lines[i]
    if l then
      local trimmed = l:match("^%s*(.*)$")
      if trimmed ~= "" and not trimmed:match("^%-%-") then
        return true
      end
    end
  end
  return false
end

--- Extract a single SQL statement at the cursor position.
--- Delimited purely by semicolons, wrapped in a synthetic ### block.
---
--- Preceding `SET @var = ...` statements in the same ### block are pulled in so
--- user variables referenced by the current statement are defined (e.g. a
--- `SET @a = 1;` line before `SELECT * FROM items WHERE id = @a;`). They are
--- returned as `set_lines` for callers that need the raw buffer text (session
--- mode).
---
--- @param buf_lines string[]
--- @param cursor_line number  1-based
--- @param buf number|nil  buffer handle (for Tree-sitter)
--- @return string|nil content, number|nil adjusted_line, number|nil stmt_start, number|nil stmt_end, string[] set_lines
function M.extract_stmt_at_cursor(buf_lines, cursor_line, buf)
  local directives = {}
  for _, l in ipairs(buf_lines) do
    if const.is_directive_comment(l) or l:match("^%s*$") then
      table.insert(directives, l)
    elseif l:match("^%s*%-%-") then -- luacheck: ignore 542
      -- skip non-directive comments (e.g. -- drop database ...)
    else
      break
    end
  end

  local stmt_start
  local stmt_end
  -- Try Tree-sitter for proper statement boundary detection (handles ; in strings/comments, PL/pgSQL, etc.)
  local ts_ok, ts_result
  if buf then
    ts_ok, ts_result = pcall(M.try_ts_stmt_span, buf, cursor_line)
  end
  if ts_ok and ts_result then
    stmt_start = ts_result[1]
    stmt_end = ts_result[2]
  else
    -- Try Rust as fallback
    local legacy = compat.opt("legacy_completion")
    local use_rust = not legacy or legacy == "rust"
    if use_rust then
      -- The dialect's quote-escape reading keeps this span identical to what
      -- exec-file splits the buffer into (resolved lazily: tree-sitter, the
      -- common path, never pays for it)
      local dialect
      if buf then
        local ok_sf, source_format = pcall(require, "poste-db.source_format")
        dialect = ok_sf and source_format.resolve_dialect(buf) or nil
      end
      local rust_ok, rust_result = pcall(M.try_rust_stmt_span, buf_lines, cursor_line, dialect)
      if rust_ok and rust_result then
        stmt_start = rust_result[1]
        stmt_end = rust_result[2]
      end
    end
  end

  if stmt_start then
    -- If cursor is on a blank line, skip forward past empty lines
    -- to find the next statement start.
    if (buf_lines[cursor_line] or ""):match("^%s*$") then
      -- Cursor on blank line: skip forward past empty lines from the
      -- detected result, and show the statement above the blank lines.
      while stmt_start <= #buf_lines and (buf_lines[stmt_start] or ""):match("^%s*$") do
        stmt_start = stmt_start + 1
      end
    end
    -- Skip past directive lines (-- @connection, -- @database), ### markers,
    -- and blank lines before the cursor.
    while stmt_start < cursor_line and stmt_start <= #buf_lines do
      local l = buf_lines[stmt_start] or ""
      if l:match("^%s*$") or l:match("^%s*%-%-") or const.is_section_marker(l) then
        stmt_start = stmt_start + 1
      else
        break
      end
    end
    -- The skips can walk stmt_start out of the detected span: the binary maps
    -- a blank line to the blank itself (`context stmt` on line 2 of
    -- `SELECT 1;\n\n\nSELECT 2;` answers (2,2)), so the forward skip lands on
    -- the NEXT statement while stmt_end still points back — an inverted span
    -- whose empty stmt_lines answered `<CR>` with "nothing to execute" for a
    -- buffer that had a perfectly good statement below the cursor. Re-end the
    -- statement the way the Lua fallback does (blanked `;`-scan: a `;` inside
    -- a literal, comment or dollar body does not bound it).
    if stmt_start > (stmt_end or 0) then
      local blanked_lines = vim.split(
        lex.blank_regions(table.concat(buf_lines, "\n")), "\n", { plain = true })
      stmt_end = #buf_lines
      for i = stmt_start, #buf_lines do
        if (blanked_lines[i] or ""):match(";") then
          stmt_end = i
          break
        end
      end
    end
  else
    -- Fall back to Lua ;-heuristic logic. The `;` probes read the blanked
    -- buffer (`lex.blank_regions` keeps newlines, so blanked_lines[i] is
    -- buf_lines[i]): a `;` inside a literal, comment or dollar-quoted body
    -- must not bound the statement — this fallback is the only splitter left
    -- when neither Tree-sitter nor the binary answered, and starting after a
    -- phantom `;` (or ending at one) sends a truncation of the real
    -- statement off to execute a syntax error.
    local blanked_lines = vim.split(
      lex.blank_regions(table.concat(buf_lines, "\n")), "\n", { plain = true })
    if (buf_lines[cursor_line] or ""):match("^%s*$") then
      -- Cursor on empty line: search forward for next statement
      stmt_start = cursor_line
      while stmt_start <= #buf_lines and (buf_lines[stmt_start] or ""):match("^%s*$") do
        stmt_start = stmt_start + 1
      end
    else
      -- Begin at buffer top; the backward scan pins the start to just after
      -- the nearest preceding `;` / `###` / directive. Initializing to
      -- cursor_line instead would chop off the head of the FIRST multi-line
      -- statement (no `;` above the cursor) and execute a syntax error.
      stmt_start = 1
      for i = cursor_line - 1, 1, -1 do
        local txt = buf_lines[i] or ""
        if (blanked_lines[i] or ""):match(";") then
          stmt_start = i + 1
          break
        end
        if const.is_section_marker(txt) or const.is_directive_comment(txt) then
          stmt_start = i + 1
          break
        end
      end
      while stmt_start <= cursor_line and (buf_lines[stmt_start] or ""):match("^%s*$") do
        stmt_start = stmt_start + 1
      end
    end

    stmt_end = #buf_lines
    for i = cursor_line, #buf_lines do
      if (blanked_lines[i] or ""):match(";") then
        stmt_end = i
        break
      end
    end
  end

  -- Ensure stmt_start is not on a blank line
  while stmt_start and stmt_start <= #buf_lines and (buf_lines[stmt_start] or ""):match("^%s*$") do
    stmt_start = stmt_start + 1
  end

  -- Scan backward in the same ### block for `SET @var = ...` statements that
  -- define user variables referenced by the current statement. Stops at the
  -- first non-SET, non-comment, non-blank line (e.g. a preceding SELECT).
  local set_lines = {}
  if stmt_start then
    local block_start = 1
    for i = stmt_start - 1, 1, -1 do
      if const.is_section_marker(buf_lines[i]) then
        block_start = i + 1
        break
      end
    end
    for i = stmt_start - 1, block_start, -1 do
      local line = buf_lines[i] or ""
      local trimmed = line:match("^%s*(.*)$") or ""
      if trimmed ~= "" then
        if trimmed:upper():match("^SET%s+@") then
          table.insert(set_lines, 1, line)
        elseif not trimmed:match("^%-%-") then
          break
        end
      end
    end
  end

  local stmt_lines = {}
  for i = stmt_start, stmt_end do
    table.insert(stmt_lines, buf_lines[i] or "")
  end

  -- If the detected statement is all blank/empty lines, nothing to execute
  local all_blank = true
  for _, l in ipairs(stmt_lines) do
    if not l:match("^%s*$") then all_blank = false; break end
  end
  if all_blank then
    return nil, nil, stmt_start, stmt_end
  end

  -- If the detected statement contains only comment lines, nothing to execute
  if not has_sql_content(buf_lines, stmt_start, stmt_end) then
    return nil, nil, stmt_start, stmt_end
  end

  local parts = {}
  for _, l in ipairs(directives) do table.insert(parts, l) end
  table.insert(parts, const.SECTION_MARKER)
  for _, l in ipairs(set_lines) do table.insert(parts, l) end
  for _, l in ipairs(stmt_lines) do table.insert(parts, l) end

  -- When cursor is below the statement (e.g. on blank lines below), clamp
  -- adjusted_line to stmt_end so it doesn't exceed the synthetic ### block.
  local cursor_ref = (cursor_line >= stmt_start) and math.min(cursor_line, stmt_end) or stmt_start
  local adjusted_line = #directives + 1 + #set_lines + (cursor_ref - stmt_start + 1)
  return table.concat(parts, "\n"), adjusted_line, stmt_start, stmt_end, set_lines
end

---------------------------------------------------------------------------
-- Multi-statement extraction
---------------------------------------------------------------------------

--- Find buffer line numbers for each SQL statement within a line range.
--- Scans for non-blank, non-comment lines as statement starts. A line
--- containing `;` marks the end of the current statement. The start of
--- the next statement is the next non-blank, non-comment line.
--- @param buf_lines string[]
--- @param start_line number  1-indexed start of range
--- @param end_line   number  1-indexed end of range
--- @param dialect string|nil  quote-escape reading for the Rust fallback
--- @return number[]  buffer line numbers of each statement's first content line
function M.find_stmt_lines(buf_lines, start_line, end_line, dialect)
  -- Lua ;-scan first (deterministic for standard SQL). The `;` probe reads the
  -- blanked range (`lex.blank_regions` keeps newlines, so blanked[k] is
  -- range line k): a `;` inside a literal, comment or dollar-quoted body does
  -- not end a statement. The skip rules still read the ORIGINAL line — a
  -- comment/directive line skips on its own `--` prefix anyway, and `USE` /
  -- `###` must be read verbatim.
  local range = {}
  for i = start_line, end_line do
    range[#range + 1] = buf_lines[i] or ""
  end
  local blanked = vim.split(
    lex.blank_regions(table.concat(range, "\n")), "\n", { plain = true })

  local stmt_lines = {}
  local current_stmt = nil

  for i = start_line, end_line do
    local line = buf_lines[i] or ""
    local trimmed = line:match("^%s*(.*)$")

    -- Skip blank lines and directive comments
    if trimmed == "" then goto continue end
    if const.is_directive_comment(trimmed) then goto continue end
    if const.is_section_marker(trimmed) then goto continue end
    if trimmed:upper():match("^USE ") then goto continue end
    if trimmed:match("^%-%-") then goto continue end

    if current_stmt == nil then current_stmt = i end

    if (blanked[i - start_line + 1] or ""):match(";") then
      table.insert(stmt_lines, current_stmt)
      current_stmt = nil
    end

    ::continue::
  end

  if current_stmt then table.insert(stmt_lines, current_stmt) end

  if #stmt_lines > 0 then return stmt_lines end

  -- Fallback: try Rust semantic boundary detection
  return M.try_rust_stmt_ranges(buf_lines, start_line, end_line, dialect)
end

--- Extract a visual selection as a synthetic ### block for the CLI.
--- @param buf_lines string[]
--- @param start_line number
--- @param end_line   number
--- @param dialect string|nil  quote-escape reading for the Rust fallback
--- @return string block_content  full content with directives + ### + selected lines
--- @return number[] stmt_lines   buffer line numbers of each statement
--- @return number   directive_count  number of file-level directive lines
function M.extract_visual_block(buf_lines, start_line, end_line, dialect)
  local directives = {}
  for _, l in ipairs(buf_lines) do
    if l:match("^%s*%-%-") or l:match("^%s*$") then
      table.insert(directives, l)
    else
      break
    end
  end

  local parts = {}
  for _, l in ipairs(directives) do table.insert(parts, l) end
  table.insert(parts, const.SECTION_MARKER)
  for i = start_line, end_line do
    table.insert(parts, buf_lines[i] or "")
  end

  local stmt_lines = M.find_stmt_lines(buf_lines, start_line, end_line, dialect)
  return table.concat(parts, "\n"), stmt_lines, #directives
end

---------------------------------------------------------------------------
-- Table name extraction from SQL
---------------------------------------------------------------------------

--- One identifier of a reference, read from `text` starting at `pos`.
--- @return string|nil name nil when `pos` does not open with a usable name
--- @return number next the first byte past the name, where a dot continues the
---         chain and anything else ends the reference
local function read_identifier(text, pos)
  local first = text:sub(pos, pos)
  local close
  if first == '"' then close = '"'
  elseif first == "`" then close = "`"
  elseif first == "[" then close = "]"
  else
    -- Unquoted identifiers fold to lower case, which is what the engines make
    -- of them (postgres and MariaDB certainly; MySQL keeps `MyTable` as it was
    -- written, and this helper has no dialect to tell the two apart — see the
    -- review note).
    -- A bare word ends at the first character that cannot belong to it:
    -- whitespace, a dot (which continues the chain), or a delimiter the state-
    -- ment may glue straight onto the name (`users(a,b)`, `users;`). A reference
    -- that *opens* with one of those — `FROM (SELECT 1) x` — has no name here
    -- and yields nil, which is right: a subquery has no table to target.
    -- Everything else stays in the name, including non-ASCII letters.
    local stop = text:find("[%.%s%(%)%[%]\"',;:]", pos) or #text + 1
    local name = text:sub(pos, stop - 1)
    if name == "" then return nil, pos end
    return name:lower(), stop
  end
  -- Quoted: the name ends at its own closing quote, so a space inside it
  -- ("Order Items") does not cut it short the way `%S+` would. A doubled
  -- closing char is the escape itself ("a""b", `a``b`, [a]]b]) and belongs to
  -- the name; the case does too, that being the point of quoting.
  local i = pos + 1
  while true do
    local c = text:find(close, i, true)
    if not c then return nil, pos end
    if text:sub(c + 1, c + 1) == close then
      i = c + 2
    else
      return text:sub(pos + 1, c - 1):gsub(close .. close, close), c + 1
    end
  end
end

--- The table a reference points at: the last identifier in its chain, read from
--- `text` starting at `pos`.
--- Everything in front of the final dot is a qualifier this helper cannot
--- resolve — the dataset layout carries the schema separately, and `db.tbl` and
--- `schema.tbl` are indistinguishable in text — so it is dropped. The dots
--- *inside* a quoted name are not separators at all: `"staging.v1"` is one
--- table, and reading it as `staging`.`v1` handed the DML builder the name of a
--- different object than the one the SELECT read.
--- @return string|nil nil when the chain does not end in a usable name, or when
---         a comma gives it a sibling table
local function last_part(text, pos)
  local name, next_pos = read_identifier(text, pos)
  if not name then return nil end
  while text:sub(next_pos, next_pos) == "." do
    name, next_pos = read_identifier(text, next_pos + 1)
    if not name then return nil end
  end
  -- A comma after the reference (any amount of space in between) is `FROM a, b`
  -- — a second table, spelled without the JOIN keyword whose count the caller
  -- above looks at. Same ambiguity as a two-JOIN query, so the same answer:
  -- nil, and the caller falls back to "result n" rather than targeting whichever
  -- table comes first.
  local k = next_pos
  while text:sub(k, k):match("%s") do k = k + 1 end
  if text:sub(k, k) == "," then return nil end
  return name
end

--- Extract primary table name from a SQL statement.
--- Returns nil when the statement does not name one table unambiguously: 2+
--- JOINs, or a `FROM a, b` list (use "result n" instead).
function M.extract_table_name(sql)
  if not sql or sql == "" then return nil end
  -- One lexical pass blanks single-quoted literals, `--`/`/* */` comments and
  -- dollar-quoted bodies; double-quoted/backtick regions survive as the
  -- identifiers the captures below read (lex.blank_regions is
  -- length-preserving, so `clean` and `upper` share offsets with the input).
  -- A single state machine is the point: the old gsub chain stripped comments
  -- BEFORE blanking literals, so `SELECT 'a--b' FROM t` lost the FROM (the
  -- comment strip ate it) and returned nil; the reverse order would let the
  -- apostrophe in `-- don't` open a phantom literal that erases real code.
  -- The old literal blanker also stopped at an escaped `''`'s *next* literal's
  -- opener (`'it''s', 'note from bob'` leaked "note from bob" as a fake FROM);
  -- the scanner closes each literal at its own unpaired quote.
  local clean = lex.blank_regions(sql, true)
  local upper = clean:upper()
  local join_count = 0
  local idx = 1
  while true do
    -- plain find: LuaJIT coerces any non-nil 4th arg (e.g. the table
    -- {plain=true} this used to pass) to truthy, so behavior was
    -- accidentally right — make it read as the plain find it is.
    local pos = upper:find("JOIN", idx, true)
    if not pos then break end
    local before = upper:sub(pos - 1, pos - 1)
    local after = upper:sub(pos + 4, pos + 4)
    -- Both edges must be non-word: only the left edge was checked, so a
    -- column list like `SELECT joined_at, join_date FROM users` counted two
    -- JOINs and the function gave up ("result n" instead of the table name).
    local boundary_before = before == "" or before == " " or before == "\n" or before == "\t"
    local boundary_after = after == "" or after:match("[%w_]") == nil
    if boundary_before and boundary_after then
      join_count = join_count + 1
    end
    idx = pos + 4
  end
  if join_count >= 2 then return nil end
  -- `()` marks where the reference starts and `%S+` merely insists something
  -- follows the keyword: the name is read out of `clean` from that offset, not
  -- out of the match. `upper` has thrown the identifier's case away on purpose,
  -- and the two strings share byte offsets because string.upper only ever maps
  -- ASCII. A capture could not carry the text either way — LuaJIT's `find`
  -- hands back captured *strings*, not positions, and `%S+` cuts a quoted name
  -- at its first space anyway.
  local patterns = { "FROM%s+()%S+", "UPDATE%s+()%S+", "INTO%s+()%S+", "JOIN%s+()%S+" }
  for _, pat in ipairs(patterns) do
    local _, _, tok_start = upper:find(pat)
    if tok_start then
      local name = last_part(clean, tok_start)
      if name and name ~= "" then return name end
    end
  end
  return nil
end

--- Get SQL text for the i-th statement (1-indexed) from buf_lines using stmt_lines.
--- @param buf_lines string[]
--- @param stmt_lines number[]
--- @param idx number 1-indexed statement index
--- @param max_end number|nil max line to read (e.g. visual selection end)
--- @return string
function M.get_stmt_sql(buf_lines, stmt_lines, idx, max_end)
  local start = stmt_lines[idx]
  if not start then return "" end
  local stop = stmt_lines[idx + 1] and (stmt_lines[idx + 1] - 1) or max_end or start
  local lines = {}
  for i = start, stop do
    local ln = buf_lines[i]
    if ln and ln ~= "" then
      lines[#lines + 1] = ln
    end
  end
  return table.concat(lines, " ")
end

--- Extract a display label for a statement from the comment directly above it.
--- Walks up from `stmt_start - 1`, skipping blank lines, `###` markers and
--- directive comments (`-- @connection` etc.); the first plain `-- comment`
--- found (nearest to the statement) wins. Falls back to the enclosing
--- `### name` block header. Returns nil when neither exists.
--- @param buf_lines string[] buffer lines
--- @param stmt_start number 1-based line of the statement start
--- @return string|nil label (trimmed, capped at LABEL_MAX_CHARS)
local LABEL_MAX_CHARS = 40

function M.extract_label(buf_lines, stmt_start)
  if not buf_lines or not stmt_start or stmt_start < 1 then return nil end
  for i = stmt_start - 1, 1, -1 do
    local trimmed = (buf_lines[i] or ""):match("^%s*(.-)%s*$") or ""
    if trimmed == "" then -- luacheck: ignore 542
      -- blank line: keep walking up
    elseif trimmed:match("^%-%-") then -- luacheck: ignore 542
      if trimmed:match("^%-%-%s*@") then -- luacheck: ignore 542
        -- directive comment: not a label, keep walking
      else
        -- plain comment: nearest one wins
        local text = trimmed:match("^%-%-%s*(.-)%s*$") or ""
        if text == "" then return nil end
        text = util.ellipsize(text, LABEL_MAX_CHARS)
        return text
      end
    elseif trimmed:match("^###") then
      -- enclosing block header name (fallback label)
      local name = trimmed:match("^###%s*(.-)%s*$") or ""
      if name == "" then return nil end
      -- util.ellipsize, like the comment branch above: `#name` counts BYTES,
      -- so a `### 查询用户订单明细…` header was cut mid-character and the
      -- sidebar rendered invalid UTF-8 (and a 40-byte CJK header rendered 13
      -- glyphs where the comment branch kept 40 cells).
      return util.ellipsize(name, LABEL_MAX_CHARS)
    else
      -- code line above: no label
      return nil
    end
  end
  return nil
end

--- Fallback label: `<basename>_<per-buffer counter>` (e.g. test_1, test_2).
--- @param src_file string source buffer path
--- @param src_buf number source buffer handle
--- @return string label
function M.fallback_label(src_file, src_buf)
  local base = vim.fn.fnamemodify(src_file or "", ":t"):gsub("%.sql$", ""):gsub("%.sqlite$", "")
  if base == "" then base = "untitled" end
  return string.format("%s_%d", base, require("poste-db.dataset").next_label_number(src_buf or 0))
end

M._test = {
  extract_stmt_at_cursor = M.extract_stmt_at_cursor,
  find_stmt_lines = M.find_stmt_lines,
  extract_visual_block = M.extract_visual_block,
  try_rust_stmt_span = M.try_rust_stmt_span,
  try_rust_stmt_ranges = M.try_rust_stmt_ranges,
  try_ts_stmt_span = M.try_ts_stmt_span,
  try_ts_stmt_ranges = M.try_ts_stmt_ranges,
  selection_cuts_statement = M.selection_cuts_statement,
  find_block_for_line = M.find_block_for_line,
  extract_label = M.extract_label,
}

return M
