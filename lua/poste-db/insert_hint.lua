local M = {}
local ns = vim.api.nvim_create_namespace("poste_insert_hint")
local const = require("poste-db.constants")

local _debounce_timer = nil
local DEBOUNCE_MS = 150

local function dbg(msg)
  if vim.g.poste_insert_hint_debug then
    vim.notify("[insert_hint] " .. msg, vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
  end
end

--- One line with its `-- comment` tail removed. The strip is quote-aware:
--- `--` inside a string literal is DATA (`VALUES ('a--b')`), and a blind
--- gsub cut it, left the quote unterminated, broke the value counting and
--- pointed the hint at the wrong column.
local function strip_comment(line)
  local in_quote = nil
  for i = 1, #line do
    local ch = line:sub(i, i)
    if in_quote then
      if ch == in_quote then in_quote = nil end  -- '' closes: two toggles
    elseif ch == "'" or ch == '"' then
      in_quote = ch
    elseif ch == "-" and line:sub(i + 1, i + 1) == "-" then
      return line:sub(1, i - 1)
    end
  end
  return line
end

--- Clear the hint extmarks; defaults to the current buffer (InsertLeave).
--- @param bufnr number|nil
function M.clear(bufnr)
  if not bufnr then
    local ok, cur = pcall(vim.api.nvim_get_current_buf)
    if not ok then return end
    bufnr = cur
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
end

--- Recompute the hint; defaults to the current buffer + window.
--- @param bufnr number|nil
function M.update(bufnr)
  if not bufnr then
    local ok, cur = pcall(vim.api.nvim_get_current_buf)
    if not ok then return end
    bufnr = cur
  end
  -- The hint is cursor-driven and everything below reads the CURRENT window's
  -- cursor: CursorHold can fire after the user switched to another window,
  -- and recomputing would pair a foreign cursor with this buffer's lines.
  -- Returning to the buffer fires CursorMoved, which recomputes anyway.
  if vim.api.nvim_get_current_buf() ~= bufnr then return end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  dbg("update called, bufnr=" .. bufnr)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_row = cursor[1]
  local cursor_col = cursor[2]

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, cursor_row, false)
  dbg("lines count=" .. #lines .. " cursor_row=" .. cursor_row .. " cursor_col=" .. cursor_col)

  local block_start = 1
  for i = #lines, 1, -1 do
    if const.is_section_marker(lines[i]) then block_start = i + 1; break end
  end
  dbg("block_start=" .. block_start .. " first line=" .. (lines[1] or "nil"))

  local text_segments = {}
  for i = block_start, #lines do
    text_segments[#text_segments + 1] = strip_comment(lines[i] or "")
  end
  local full_text = table.concat(text_segments, "\n")

  local text_offset = 0
  for i = block_start, cursor_row - 1 do
    text_offset = text_offset + #strip_comment(lines[i] or "") + 1
  end
  text_offset = text_offset + cursor_col
  dbg("full_text: " .. full_text:sub(1, 200):gsub("\n", "\\n"))

  local s, e = nil, nil
  local search_pos = 1
  while true do
    local ns2, ne = full_text:find("[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+`[^`]+`%s*%(", search_pos)
    if not ns2 or ns2 > text_offset then
      ns2, ne = full_text:find("[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+[%w_]+%s*%(", search_pos)
    end
    if not ns2 or ns2 > text_offset then break end
    s, e = ns2, ne
    search_pos = ne + 1
  end
  if not s then dbg("no INSERT INTO before cursor"); return end
  dbg("INSERT INTO found, col_list_paren at pos " .. e)

  local paren_open = e
  local depth = 1
  local col_list_end = paren_open
  for i = paren_open + 1, #full_text do
    local ch = full_text:sub(i, i)
    if ch == "(" then depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 then col_list_end = i; break end
    end
  end
  if col_list_end == paren_open then dbg("no closing paren for column list"); return end

  local cols = {}
  for c in full_text:sub(paren_open + 1, col_list_end - 1):gmatch("([%w_]+)") do
    cols[#cols + 1] = c
  end
  if #cols == 0 then dbg("no columns found"); return end
  dbg("columns: " .. table.concat(cols, ", "))

  local v_start = full_text:find("[Vv][Aa][Ll][Uu][Ee][Ss]%s*%(", col_list_end)
  if not v_start then dbg("no VALUES found"); return end
  dbg("VALUES found at " .. v_start)

  local v_paren = full_text:find("%(", v_start)
  if not v_paren then dbg("no VALUES paren"); return end
  dbg("v_paren=" .. v_paren .. " text_offset=" .. text_offset)

  depth = 1
  local v_close = nil
  for i = v_paren + 1, #full_text do
    local ch = full_text:sub(i, i)
    if ch == "(" then depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 then v_close = i; break end
    end
  end

  if text_offset < v_paren then dbg("cursor before VALUES paren"); return end
  -- text_offset is a 0-based offset while v_close is a 1-based index: the
  -- cursor sitting ON the closing paren (offset == v_close) is already past
  -- it — the old `>` let the hint linger on the `;` after the statement
  if v_close and text_offset >= v_close then dbg("cursor after VALUES paren close"); return end
  dbg("cursor inside VALUES parens")

  local vals_prefix = full_text:sub(v_paren + 1, text_offset)
  dbg("vals_prefix='" .. vals_prefix .. "'")
  local value_idx = 0
  local in_str = false
  local str_char = nil
  depth = 0
  for i = 1, #vals_prefix do
    local ch = vals_prefix:sub(i, i)
    local prev = i > 1 and vals_prefix:sub(i - 1, i - 1) or ""
    if in_str then
      if ch == str_char and prev ~= "\\" then in_str = false end
    elseif ch == "'" or ch == '"' then
      in_str = true; str_char = ch
    elseif ch == "(" then depth = depth + 1
    elseif ch == ")" then depth = depth - 1
    elseif ch == "," and depth == 0 then value_idx = value_idx + 1
    end
  end
  dbg("value_idx=" .. value_idx .. " target_idx=" .. (value_idx + 1))

  local target_idx = value_idx + 1
  if target_idx > #cols then dbg("target_idx " .. target_idx .. " > " .. #cols); return end
  local target_col = cols[target_idx]
  dbg("target: col#" .. target_idx .. " = " .. target_col)

  -- Map a 1-based full_text offset to (0-based row, 0-based col) in the
  -- buffer. Consistently 0-based: the old mix (line 1 came back 1-based,
  -- later lines 0-based) shifted the highlight one byte left whenever the
  -- column list did not start on the statement's first line. An offset
  -- pointing at the joining newline maps one past the end of the line
  -- before it, which the search below sees as an empty segment and skips.
  local function to_buf_pos(byte_off)
    local consumed = 0  -- full_text chars used by earlier lines, newline included
    for i = block_start, #lines do
      local line_len = #strip_comment(lines[i] or "")
      if byte_off <= consumed + line_len + 1 then
        return i - 1, byte_off - consumed - 1
      end
      consumed = consumed + line_len + 1
    end
    return nil, nil
  end

  local start_row, start_col = to_buf_pos(paren_open + 1)
  local end_row, end_col = to_buf_pos(col_list_end)
  dbg("search area: rows " .. tostring(start_row) .. "-" .. tostring(end_row) .. " cols " .. tostring(start_col) .. "-" .. tostring(end_col))
  if not start_row then dbg("start_row nil"); return end

  for row = start_row, end_row or start_row do
    local line_text = lines[row + 1] or ""
    -- search_from/search_to are 1-based sub() bounds: start_col is the
    -- 0-based col right after the opening paren, end_col the 0-based col
    -- of the closing paren (exclusive)
    local search_from, search_to
    if row == start_row then search_from = start_col + 1 else search_from = 1 end
    if end_row and row == end_row then search_to = end_col else search_to = #line_text end

    local segment = line_text:sub(search_from, search_to)
    dbg("searching in row " .. row .. " [" .. search_from .. "," .. search_to .. "]: '" .. segment .. "'")
    local col_pos = segment:find(vim.pesc(target_col))
    if col_pos then
      local before = col_pos > 1 and segment:sub(col_pos - 1, col_pos - 1) or ""
      local after = col_pos + #target_col <= #segment and segment:sub(col_pos + #target_col, col_pos + #target_col) or ""
      dbg("found at col_pos=" .. col_pos .. " before='" .. before .. "' after='" .. after .. "'")
      if (before:match("[%s_,(`\"]") or before == "") and (after:match("[%s_,)`\"]") or after == "") then
        local buf_col = search_from + col_pos - 2
        dbg("PLACING extmark row=" .. row .. " col=" .. buf_col)
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, buf_col, {
          end_col = buf_col + #target_col,
          hl_group = "PosteDbDatasetInsertHint",
          priority = 200,
        })
        return
      end
    end
  end
  dbg("column not found in search area")
end

function M.setup()
  local function debounced_update()
    if _debounce_timer then
      _debounce_timer:stop()
      _debounce_timer:close()
    end
    _debounce_timer = vim.defer_fn(function()
      _debounce_timer = nil
      M.update()
    end, DEBOUNCE_MS)
  end
  -- Attach the cursor hooks per BUFFER through FileType, matching the
  -- family convention (au FileType poste_sql). The old `*.sql` filename
  -- patterns missed every buffer without a .sql name — an unnamed scratch
  -- buffer or a renamed file got no hints at all.
  local attach_group = vim.api.nvim_create_augroup("poste_insert_hint_attach", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = attach_group,
    pattern = { "poste_sql", "poste_sqlite" },
    callback = function(args)
      local bufnr = args.buf
      local group = vim.api.nvim_create_augroup("poste_insert_hint_" .. bufnr, { clear = true })
      vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        buffer = bufnr,
        callback = debounced_update,
      })
      vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
        group = group,
        buffer = bufnr,
        callback = function() M.update(bufnr) end,
      })
      vim.api.nvim_create_autocmd("InsertLeave", {
        group = group,
        buffer = bufnr,
        callback = function() M.clear(bufnr) end,
      })
    end,
  })
end

return M
