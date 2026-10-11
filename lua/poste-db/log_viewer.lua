--- SQL Execution Log Viewer
--- Reads sql_log.jsonl, renders entries in a buffer with expand/collapse.
local M = {}

local const = require("poste-db.constants")
local syntax = require("poste-db.syntax")
local float_window = require("poste-db.float_window")
local ns = vim.api.nvim_create_namespace("poste_db_log")
local buf = nil
local win = nil
local entries = {}
local expanded = {}
local filter_text = ""

--- The journal's location, from the module that writes it — the viewer must
--- read the same file the writer was pointed at (a spec's `set_log_path`
--- included), not a second copy of the path string.
local function get_log_path()
  return require("poste-db.sql_log").path()
end

--- Fields the viewer reads as strings, coerced at the load seam. The journal
--- lives in the user's data dir, so one hand-edited or corrupt line (a numeric
--- `ts`, an object `error`) used to take the whole viewer down: format_time
--- indexed a number, filter_matches indexed a non-string field, count of an
--- object `error` raised on concat. Numbers and booleans coerce; tables and
--- userdata are unreadable as any of these fields and are treated as absent.
local STRING_FIELDS = { "ts", "source", "sql", "connection", "database",
  "status", "error", "table", "table_name" }

--- Normalize one decoded journal entry; returns nil when the line was not an
--- object at all (a bare `42` in the jsonl used to crash the ts sort).
local function normalize_entry(entry)
  if type(entry) ~= "table" then return nil end
  for _, f in ipairs(STRING_FIELDS) do
    local v = entry[f]
    if v ~= nil and type(v) ~= "string" then
      if type(v) == "number" or type(v) == "boolean" then
        entry[f] = tostring(v)
      else
        entry[f] = nil
      end
    end
  end
  -- summary_parts interpolates it with %5s; a non-number reads as noise
  if entry.elapsed_ms ~= nil and type(entry.elapsed_ms) ~= "number" then
    entry.elapsed_ms = nil
  end
  return entry
end

local function load_entries()
  local path = get_log_path()
  local file = io.open(path, "r")
  if not file then return {} end
  local result = {}
  for line in file:lines() do
    if line ~= "" then
      local ok, entry = pcall(vim.json.decode, line)
      if ok then
        entry = normalize_entry(entry)
        if entry then table.insert(result, entry) end
      end
    end
  end
  file:close()
  table.sort(result, function(a, b) return (a.ts or "") > (b.ts or "") end)
  -- Cap at the shared log limit.
  if #result > const.LOG_MAX_ENTRIES then
    local capped = {}
    for i = 1, const.LOG_MAX_ENTRIES do capped[i] = result[i] end
    result = capped
  end
  return result
end

local function filter_matches(entry)
  if filter_text == "" then return true end
  local lower = filter_text:lower()
  if (entry.table or ""):lower():find(lower, 1, true) then return true end
  if (entry.connection or ""):lower():find(lower, 1, true) then return true end
  if (entry.status or ""):lower():find(lower, 1, true) then return true end
  if (entry.database or ""):lower():find(lower, 1, true) then return true end
  if (entry.source or ""):lower():find(lower, 1, true) then return true end
  if (entry.sql or ""):lower():find(lower, 1, true) then return true end
  -- The error text is the one field an expanded entry shows that the filter
  -- skipped: the highlight pass already marks matches on error detail lines,
  -- so searching for the reason ("Timeout", "does not exist") filtering the
  -- list down to nothing read the filter as broken rather than as scoped.
  if (entry.error or ""):lower():find(lower, 1, true) then return true end
  return false
end
M._filter_matches = filter_matches

--- source field → summary-column tag. The log is the journal of every SQL
--- request (manual runs, run-file, AI, EXPLAIN, commits, imports, browser
--- queries, schema introspection, connection probes), so each surface gets a
--- short tag for the summary row.
local SOURCE_TAGS = {
  manual_exec = "exec",
  run_file = "file",
  ai_chat = "ai",
  dataset_commit = "commit",
  import = "import",
  explain = "explain",
  browser = "browser",
  introspect = "schema",
  connection = "conn",
}

local function source_tag(entry)
  return SOURCE_TAGS[entry.source or ""] or tostring(entry.source or "exec")
end
M._source_tag = source_tag

local function format_time(ts)
  if type(ts) ~= "string" then return "??-?? ??:??:??" end
  local _, month, day, hms = ts:match("(%d+)-(%d+)-(%d+)T(%d+:%d+:%d+)")
  if month and day and hms then
    return string.format("%s-%s %s", month, day, hms)
  end
  local t = ts:match("T(%d+:%d+:%d+)")
  if t then return t end
  t = ts:match("T(%d+:%d+)")
  return t or ts
end
M._format_time = format_time

--- Truncate to a display-width budget on a character boundary, marking the
--- cut with an ellipsis. Byte-based `sub` split multibyte characters in half
--- and wrote invalid UTF-8 into the summary buffer. Defined BEFORE its first
--- caller (preview_sql): a local declared after the call site resolves to a
--- nil global there (see AGENTS.md).
local function fit_width(s, max_w)
  local dw = vim.fn.strdisplaywidth(s)
  if dw <= max_w then return s end
  local width, fit = 0, 0
  local nchars = vim.fn.strchars(s)
  for i = 0, nchars - 1 do
    local cw = vim.fn.strdisplaywidth(vim.fn.strcharpart(s, i, 1))
    if width + cw > max_w - 1 then break end -- reserve one column for "…"
    width = width + cw
    fit = fit + 1
  end
  return vim.fn.strcharpart(s, 0, fit) .. "…"
end

local function preview_sql(sql, max_len)
  if not sql or sql == "" then return "" end
  -- Show only the first line for multi-line SQL
  local first_line = sql:match("^(.-)\n")
  if first_line then
    first_line = first_line:gsub("%s+$", "")
    if vim.fn.strdisplaywidth(first_line) <= max_len - 1 then
      return first_line .. "…"
    end
  end
  if vim.fn.strdisplaywidth(sql) <= max_len then return sql end
  return fit_width(sql, max_len)
end
M._preview_sql = preview_sql

local function clean_sql(sql)
  if not sql then return "" end
  local lines = {}
  for line in (sql .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed and not const.is_directive_comment(trimmed) and trimmed ~= const.SECTION_MARKER then
      table.insert(lines, trimmed)
    end
  end
  local result = table.concat(lines, "\n")
  return result:match("^%s*(.-)%s*$") or ""
end
M._clean_sql = clean_sql

local function guess_table(sql)
  if not sql then return nil end
  local patterns = {
    "[Jj][Oo][Ii][Nn]%s+([%w_]+)",
    "[Ff][Rr][Oo][Mm]%s+([%w_]+%.?([%w_]+))",
    "[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_]+)",
    "[Ii][Nn][Tt][Oo]%s+([%w_]+)",
    "[Dd][Ee][Ll][Ee][Tt][Ee]%s+[Ff][Rr][Oo][Mm]%s+([%w_]+)",
    "[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+([%w_]+)",
  }
  for _, pat in ipairs(patterns) do
    local t = sql:match(pat)
    if t then
      local _, after_dot = t:match("([%w_]+)%.([%w_]+)")
      return after_dot or t
    end
  end
  return nil
end
M._guess_table = guess_table

local function entry_table(entry)
  if entry.table and entry.table ~= "" then return entry.table end
  if entry.table_name and entry.table_name ~= "" then return entry.table_name end
  return guess_table(entry.sql)
end
M._entry_table = entry_table

local function count_detail_lines(entry)
  local n = 0
  if entry.connection or entry.database or entry.source then
    n = n + 1
  end
  if entry.edit_summary then
    n = n + 1
  end
  local display_sql = clean_sql(entry.sql)
  if display_sql and display_sql ~= "" then
    for _ in (display_sql .. "\n"):gmatch("(.-)\n") do
      n = n + 1
    end
  end
  if entry.error and entry.error ~= "" then
    for _ in (entry.error .. "\n"):gmatch("(.-)\n") do
      n = n + 1
    end
  end
  n = n + 1 -- trailing blank line
  return n
end
M._count_detail_lines = count_detail_lines

--- Set entries directly (for testing). Runs the same normalization the disk
--- load applies, so a spec feeding raw hostile-shaped data exercises the seam
--- every entry really passes through.
function M._set_entries(data)
  local normalized = {}
  for _, e in ipairs(data or {}) do
    local n = normalize_entry(e)
    if n then normalized[#normalized + 1] = n end
  end
  entries = normalized
  expanded = {}
  filter_text = ""
end

--- Set filter text directly (for testing).
function M._set_filter_text(text)
  filter_text = text
end

--- Set expanded state directly (for testing).
function M._set_expanded(idx, val)
  expanded[idx] = val
end

local TBL_W = 0

local function entry_database(entry)
  if entry.database and entry.database ~= "" then return entry.database end
  if entry.connection and entry.connection ~= "" then
    local ok, config = pcall(require, "poste-db.connections")
    if ok then
      local cfg = config.get_connection_config(entry.connection)
      if cfg and cfg.database and cfg.database ~= "" then return cfg.database end
    end
  end
  return nil
end

--- Outcome column, first character of every summary row: ✗ = the request
--- failed, ! = it ran but delivered less than it promised (a partial edit
--- commit), blank = success or an outcome the writer did not classify. The
--- row-wide red tint is easy to miss in a long list and says nothing about a
--- partial commit, which is neither success nor failure.
local function status_mark(entry)
  if entry.status == "error" then return "✗" end
  if entry.status == "partial" then return "!" end
  return " "
end
M._status_mark = status_mark

local function compute_table_width()
  local max_w = 0
  for _, entry in ipairs(entries) do
    local db = entry_database(entry) or entry_table(entry) or "?"
    -- display width, not byte length: CJK names count 2 columns per char
    max_w = math.max(max_w, vim.fn.strdisplaywidth(db))
  end
  TBL_W = math.min(math.max(max_w, 4), 25)
end

--- Pad/truncate one cell to `width` display columns, or to the width computed
--- for the current render when the caller has no opinion.
local function pad_table(s, width)
  local w = width or TBL_W
  local dw = vim.fn.strdisplaywidth(s)
  if dw > w then return fit_width(s, w) end
  return s .. string.rep(" ", w - dw)
end

--- Summary-line segments, shared by render and apply_highlights so the
--- highlight byte offsets derive from the real parts. Fixed arithmetic used
--- to assume a 15-byte timestamp (actual: 14) and a db segment of exactly
--- TBL_W bytes — both wrong once a name has multibyte characters, since
--- pad_table pads to display width, not bytes.
--- Part order (see apply_highlights): 2 = outcome mark, 4 = time, 6 = db,
--- 8 = duration, 10 = source tag, 12 = SQL preview.
local function summary_parts(entry, width)
  local time = format_time(entry.ts)
  local db = pad_table(entry_database(entry) or entry_table(entry) or "?", width)
  local ms = string.format("%5s", tostring(entry.elapsed_ms or 0) .. "ms")
  local src_tag = string.format("%-7s", source_tag(entry))
  local display_sql = clean_sql(entry.sql)
  local sql = preview_sql(display_sql, 70)
  return { " ", status_mark(entry), "  ", time, "  ", db, "  ", ms, "  ", src_tag, " ", sql }
end

--- Byte range [start, end) of part `n` (1-based) in the concatenated summary.
local function part_range(parts, n)
  local start = 0
  for i = 1, n - 1 do start = start + #parts[i] end
  return start, start + #parts[n]
end

local function apply_highlights(line_idx, entry, _)
  -- Get actual line length for bounds checking
  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  local line_len = #line

  -- Error row: red for entire line (low priority so element colors show through)
  if entry.status == "error" and line_len > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 0, {
      end_col = line_len, hl_group = "PosteDbHistoryError", priority = 100, hl_mode = "combine",
    })
  end

  local parts = summary_parts(entry)
  local mark_s, mark_e = part_range(parts, 2)
  local time_s, time_e = part_range(parts, 4)
  local db_s, db_e = part_range(parts, 6)
  local ms_s, ms_e = part_range(parts, 8)
  local src_s, src_e = part_range(parts, 10)

  -- Outcome mark (red ✗ / yellow !)
  if entry.status == "error" then
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, mark_s, {
      end_col = mark_e, hl_group = "PosteDbHistoryError", priority = 170,
    })
  elseif entry.status == "partial" then
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, mark_s, {
      end_col = mark_e, hl_group = "PosteDbHistoryWarning", priority = 170,
    })
  end

  -- Timestamp (gray)
  vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, time_s, {
    end_col = time_e, hl_group = "PosteDbDatasetMetaDim", priority = 150,
  })
  -- Table/db name
  vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, db_s, {
    end_col = db_e, hl_group = "PosteDbDatasetMeta", priority = 150,
  })
  -- Duration (yellow)
  vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, ms_s, {
    end_col = ms_e, hl_group = "PosteDbDatasetWinbarModified", priority = 150,
  })
  -- Source tag (gray)
  vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, src_s, {
    end_col = src_e, hl_group = "PosteDbDatasetMetaDim", priority = 150,
  })

  -- Filter word highlight
  if filter_text ~= "" and line_len > 0 then
    local lower = line:lower()
    local ftext = filter_text:lower()
    local scan_pos = 1
    while scan_pos <= line_len do
      local start = lower:find(ftext, scan_pos, true)
      if not start then break end
      vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, start - 1, {
        end_col = start - 1 + #filter_text,
        hl_group = "PosteDbDatasetSearchActive",
        priority = 180,
        hl_mode = "combine",
      })
      scan_pos = start + #filter_text
    end
  end
end

--- Apply SQL syntax highlighting to a single line via shared syntax module.
--- @param buf number  Buffer handle
--- @param ns number   Namespace
--- @param line_idx number  Buffer line (1-indexed)
--- @param text string SQL text for this line (without buffer prefix)
--- @param offset number  Column offset in buffer
local function highlight_sql_line(buf2, ns2, line_idx, text, offset)  -- luacheck: ignore 431
  syntax.highlight_line(buf2, ns2, line_idx, text, offset)
end

local function apply_detail_highlights(line_idx, entry, detail_idx)
  -- Precompute line counts for this entry
  local n_sql = 0
  local display_sql = clean_sql(entry.sql)
  if display_sql and display_sql ~= "" then
    for _ in (display_sql .. "\n"):gmatch("(.-)\n") do
      n_sql = n_sql + 1
    end
  end
  local n_err = 0
  if entry.error and entry.error ~= "" then
    for _ in (entry.error .. "\n"):gmatch("(.-)\n") do
      n_err = n_err + 1
    end
  end

  local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
  local line_len = #line

  if line_len == 0 then return end

  -- Determine line type by position (order: SQL → error → meta → edit)
  local pos = detail_idx
  if pos <= n_sql then
    -- SQL line: vertical bar + > marker + keyword highlights
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 2, {
      virt_text = {{"│", "PosteDbDatasetMetaDim"}}, virt_text_pos = "overlay",
      priority = 90,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 3, {
      virt_text = {{"> ", "PosteDbHistorySQL"}}, virt_text_pos = "overlay",
      priority = 170,
    })
    -- Full SQL syntax highlighting
    if line_len > 5 then
      highlight_sql_line(buf, ns, line_idx, line:sub(6), 5)
    end
  elseif pos <= n_sql + n_err then
    -- Reason line: vertical bar + red fg + < marker. A "partial" entry stores
    -- what was missed in the same field, but the statements did run and some
    -- changes landed — so that one is tinted as a warning, not an error.
    local reason_hl = entry.status == "partial" and "PosteDbHistoryWarning" or "PosteDbHistoryError"
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 0, {
      end_col = line_len, hl_group = reason_hl, priority = 160,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 2, {
      virt_text = {{"│", "PosteDbDatasetMetaDim"}}, virt_text_pos = "overlay",
      priority = 90,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 3, {
      virt_text = {{"< ", reason_hl}}, virt_text_pos = "overlay",
      priority = 170,
    })
  else
    -- Meta/edit line: gray, bar, no marker
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 2, {
      virt_text = {{"│", "PosteDbDatasetMetaDim"}}, virt_text_pos = "overlay",
      priority = 90,
    })
    vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, 0, {
      end_col = line_len, hl_group = "PosteDbDatasetMetaDim", priority = 160,
    })
  end

  -- Filter word highlight on detail lines
  if filter_text ~= "" and line_len > 0 then
    local lower = line:lower()
    local ftext = filter_text:lower()
    local scan_pos = 1
    while scan_pos <= line_len do
      local start = lower:find(ftext, scan_pos, true)
      if not start then break end
      vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, start - 1, {
        end_col = start - 1 + #filter_text,
        hl_group = "PosteDbDatasetSearchActive",
        priority = 180,
        hl_mode = "combine",
      })
      scan_pos = start + #filter_text
    end
  end
end

local function update_winbar()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local total = #entries
  local count = 0
  for _ in ipairs(entries) do
    if filter_matches(entries[_]) then count = count + 1 end
  end
  local parts = { "%#PosteDbDatasetMeta# SQL Log" }
  if filter_text ~= "" then
    table.insert(parts, string.format(" %%#PosteDbHistoryFilter#filter: %s%%#PosteDbDatasetMeta#", filter_text))
  end
  table.insert(parts, string.format("  [%d/%d]", count, total))
  if count < total then
    table.insert(parts, "  %#PosteDbDatasetMetaDim#filtered%#PosteDbDatasetMeta#")
  end
  table.insert(parts, "  %#PosteDbDatasetMetaDim#│  q=close  f=filter  F=clear  y=copy  r=to buffer  C=delete-all  ↵=expand%#PosteDbDatasetMeta#")
  pcall(vim.api.nvim_set_option_value, "winbar", table.concat(parts), { win = win })
end

--- Edit-commit detail line: what the commit intended, and — when the writer
--- recorded it — what actually landed. Without the second half, a partial
--- commit expands to "Edit: 2 updates, 0 inserts, 0 deletes" and looks
--- indistinguishable from a clean one.
local function edit_summary_line(entry)
  local s = entry.edit_summary
  if not s then return nil end
  local line = string.format("     Edit: +%d updates, %d inserts, %d deletes",
    s.updates or 0, s.inserts or 0, s.deletes or 0)
  if type(entry.affected_rows) == "number" then
    local expected = (s.updates or 0) + (s.inserts or 0) + (s.deletes or 0)
    line = line .. string.format(" · %d of %d row(s) affected", entry.affected_rows, expected)
  end
  return line
end
M._edit_summary_line = edit_summary_line

local function build_lines()
  local lines = {}
  local filtered = {}
  for i, entry in ipairs(entries) do
    if filter_matches(entry) then
      table.insert(filtered, i)
    end
  end
  compute_table_width()
  local line_idx = 1
  for _, idx in ipairs(filtered) do
    local entry = entries[idx]
    local summary = table.concat(summary_parts(entry))
    table.insert(lines, summary)
    line_idx = line_idx + 1
    if expanded[idx] then
      -- SQL lines first
      local display_sql2 = clean_sql(entry.sql)
      if display_sql2 and display_sql2 ~= "" then
        for sql_line in (display_sql2 .. "\n"):gmatch("(.-)\n") do
          table.insert(lines, "     " .. sql_line)
          line_idx = line_idx + 1
        end
      end
      -- Error lines
      if entry.error and entry.error ~= "" then
        for err_line in (entry.error .. "\n"):gmatch("(.-)\n") do
          table.insert(lines, "     " .. err_line)
          line_idx = line_idx + 1
        end
      end
      -- Connection info (gray)
      local entry_db = entry_database(entry) or ""
      if entry.connection or entry.database or entry.source then
        table.insert(lines, "     " .. table.concat({
          "Connection: " .. (entry.connection or "?"),
          "Database: " .. (entry_db ~= "" and entry_db or "?"),
          "Source: " .. (entry.source or "?"),
        }, " · "))
        line_idx = line_idx + 1
      end
      -- Edit summary (gray)
      local edit_line = edit_summary_line(entry)
      if edit_line then
        table.insert(lines, edit_line)
        line_idx = line_idx + 1
      end
      table.insert(lines, "")
      line_idx = line_idx + 1
    end
  end
  return lines, filtered
end

local function render()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local lines, filtered = build_lines()
  if #lines == 0 then
    lines = { "  <empty>" }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if #filtered == 0 then
    local line_len = #(lines[1] or "")
    if line_len > 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
        end_col = line_len, hl_group = "PosteDbDatasetMetaDim", priority = 150,
      })
    end
    return
  end
  local line_idx = 1
  for _, idx in ipairs(filtered) do
    local entry = entries[idx]
    apply_highlights(line_idx, entry, false)
    line_idx = line_idx + 1
    if expanded[idx] then
      local dl = count_detail_lines(entry)
      for d = 1, dl do
        apply_detail_highlights(line_idx, entry, d)
        line_idx = line_idx + 1
      end
    end
  end
  vim.bo[buf].modifiable = false
  update_winbar()
end

function M.get_entry_at_cursor()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return M._get_entry_at_line(0) end
  local cursor = vim.api.nvim_win_get_cursor(win or 0)
  return M._get_entry_at_line(cursor[1] or 0)
end

function M._get_entry_at_line(line_idx)
  if line_idx == 0 then return nil end
  local filtered = {}
  for i, _ in ipairs(entries) do
    if filter_matches(entries[i]) then
      table.insert(filtered, i)
    end
  end
  local current = 1
  for _, idx in ipairs(filtered) do
    if current == line_idx then return idx end
    current = current + 1
    if expanded[idx] then
      current = current + count_detail_lines(entries[idx])
    end
    if current > line_idx then return idx end
  end
  return nil
end

function M.toggle_expand()
  local idx = M.get_entry_at_cursor()
  if not idx then return end
  expanded[idx] = not expanded[idx]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    render()
  end
end

function M.set_filter()
  vim.ui.input({ prompt = "SQL log filter: ", default = filter_text }, function(input)
    if input == nil then return end
    filter_text = input
    render()
  end)
end

function M.clear_filter()
  filter_text = ""
  render()
end

--- Lines for the scratch buffer `r` hands the statement to: an optional
--- connection directive, then the SQL verbatim.
---
--- A logged `connection` is either a name or a redacted URL (`sql_log` runs
--- `redact_url` on write when no name override was given). Only the name is
--- usable: a `postgres://user:***@host/db` line would be echoed into the
--- buffer, and the directive parser would try to resolve that as a stanza.
local function rerun_lines(entry)
  local lines = {}
  local conn = entry.connection
  if type(conn) == "string" and conn ~= "" and not conn:find("://", 1, true) then
    table.insert(lines, "-- @connection " .. conn)
  end
  for line in (tostring(entry.sql or "") .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  return lines
end

M._rerun_lines = rerun_lines

--- Open `lines` in a fresh, listed `.sql` buffer and focus it. Setting the
--- filetype is what makes the buffer runnable: the plugin's FileType
--- autocommand installs the guarded run keymap there.
function M._open_in_sql_buffer(lines)
  local new_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(new_buf, 0, -1, true, lines)
  vim.bo[new_buf].filetype = "sql"
  vim.api.nvim_win_set_buf(0, new_buf)
  -- Park on the statement, not the directive: the cursor line is where the
  -- runner resolves context and picks the statement under point. Matched
  -- literally because `rerun_lines` is what writes the line — a `^%-%s*@`
  -- pattern looks right and never matches, since the directive has two dashes.
  local first = (lines[1] or ""):sub(1, 4) == "-- @" and 2 or 1
  pcall(vim.api.nvim_win_set_cursor, 0, { first, 0 })
  return new_buf
end

--- `r`: take the entry's SQL into a real `.sql` buffer.
---
--- Deliberately *not* an execution. The viewer has no DML guard, no
--- confirmation step and no dataset window, and a logged `DELETE` is exactly
--- as destructive the second time; the `.sql` buffer has all three. So `r`
--- closes the float and hands the statement (plus its connection directive) to
--- a buffer the user runs from, rather than firing it from a window whose
--- keystrokes were never meant to reach a database.
function M.re_run()
  local idx = M.get_entry_at_cursor()
  if not idx then return end
  local entry = entries[idx]
  if not entry.sql or entry.sql == "" then
    vim.notify("No SQL to re-run", vim.log.levels.WARN, { title = "PosteDb" })
    return
  end
  local lines = rerun_lines(entry)
  M.close()
  M._open_in_sql_buffer(lines)
  vim.notify("SQL moved to a buffer — run it with <CR>", vim.log.levels.INFO)
end

function M.yank_sql()
  local idx = M.get_entry_at_cursor()
  if not idx then return end
  local entry = entries[idx]
  if not entry.sql or entry.sql == "" then
    vim.notify("No SQL to yank", vim.log.levels.WARN, { title = "PosteDb" })
    return
  end
  vim.fn.setreg('"', entry.sql)
  vim.fn.setreg("+", entry.sql)
  vim.notify("SQL yanked", vim.log.levels.INFO)
end

function M.refresh()
  entries = load_entries()
  render()
end

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  buf = nil
  win = nil
end

--- `C` used to wipe the whole journal on one keypress. The journal is the
--- only copy of what ran — the notify that reported a failure scrolled off
--- seconds later — and `C` sits one key away from `y`/`r`/`f` in normal mode.
--- Ask first, in the same `[y] / [n]` shape the paste confirm already uses.
--- `M.clear_logs` stays the unconditional entry point for callers that have
--- already decided (and for specs).
--- @param opts table|nil { on_confirm = fun(), on_cancel = fun() } for tests
function M.request_clear(opts)
  opts = opts or {}
  if #entries == 0 then
    -- nothing to lose: skip the question
    M.clear_logs()
    if opts.on_confirm then opts.on_confirm() end
    return true
  end

  local dialog = require("poste-db.dialog")
  local path = get_log_path()
  local lines = {
    "  Entries:  " .. #entries,
    "  File:     " .. path,
    "",
    "  The journal is the only record of what ran — this cannot be undone.",
    "",
    "  [y] Clear  [n] Cancel",
  }

  -- One settle path, like show_paste_confirm: y clears, and n / q / <Esc> /
  -- WinLeave all count as cancel, so a bare close cannot be read as consent.
  local answered = false
  local dlg
  local function answer(is_cancel)
    if answered then return end
    answered = true
    dlg:close() -- re-enters via on_close; the answered flag absorbs it
    if is_cancel then
      vim.notify("SQL log left untouched", vim.log.levels.INFO, { title = "PosteDb" })
      if opts.on_cancel then opts.on_cancel() end
      return
    end
    M.clear_logs()
    if opts.on_confirm then opts.on_confirm() end
  end

  dlg = dialog.open({
    title = "Clear SQL log",
    width = math.max(60, 8 + vim.fn.strdisplaywidth(path)),
    height = #lines + 2,
    border = "rounded",
    backdrop = true,
    on_close = function() answer(true) end,
  })

  local km = { buffer = dlg.buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "y", function() answer(false) end, km)
  vim.keymap.set("n", "n", function() answer(true) end, km)

  dlg:update(lines)
  return true
end

function M.clear_logs()
  local path = get_log_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    pcall(vim.fn.mkdir, dir, "p") -- E739 on a permission wall; io.open below reports
  end
  local f = io.open(path, "w")
  local truncated = f ~= nil
  if f then
    f:write("")
    f:close()
  end
  entries = {}
  expanded = {}
  filter_text = ""
  render()
  -- The in-memory view is always cleared; only claim the file itself is
  -- gone when the truncate actually opened for writing.
  if truncated then
    vim.notify("SQL log cleared", vim.log.levels.INFO, { title = "PosteDb" })
  else
    vim.notify("Cleared the in-memory log, but " .. path .. " could not be written",
      vim.log.levels.WARN, { title = "PosteDb" })
  end
end

function M.toggle()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    M.close()
    return
  end
  entries = load_entries()
  expanded = {}
  filter_text = ""
  buf, win = float_window.open({
    filetype = "poste_db_log",
    buf_options = { buftype = "nofile", bufhidden = "wipe", swapfile = false },
    relative = "editor",
    width = math.floor(vim.o.columns * 0.85),
    height = math.floor(vim.o.lines * 0.75),
    row = math.floor(vim.o.lines * 0.12),
    col = math.floor(vim.o.columns * 0.07),
    win_options = { cursorline = true, breakindent = true },
  })
  vim.api.nvim_buf_set_name(buf, "poste://sql-log")
  render()
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<Esc>", M.close, opts)
  vim.keymap.set("n", "j", "<Cmd>normal! j<CR>", opts)
  vim.keymap.set("n", "k", "<Cmd>normal! k<CR>", opts)
  vim.keymap.set("n", "<CR>", M.toggle_expand, opts)
  vim.keymap.set("n", "f", M.set_filter, opts)
  vim.keymap.set("n", "F", M.clear_filter, opts)
  vim.keymap.set("n", "r", M.re_run, opts)
  vim.keymap.set("n", "y", M.yank_sql, opts)
  vim.keymap.set("n", "C", M.request_clear, opts)
end

--- Test hooks for the display-width helpers. Kept at the bottom of the file:
--- a hook defined before its helper resolves the helper's local name as a
--- nil global (AGENTS.md forward-declaration pitfall).
function M._fit_width(s, max_w)
  return fit_width(s, max_w)
end

--- The load-seam normalizer, for direct hostile-shape specs.
function M._normalize_entry(e)
  return normalize_entry(e)
end

--- Pad/truncate to a given width; `width` nil falls back to the width computed
--- for the current render, exactly like the render path itself. Deliberately a
--- parameter and not a write: this hook used to assign `TBL_W`, so one spec that
--- pinned a column width leaked it into every later row of the same process and
--- the padding assertions had to match by `find` — which width a row got
--- depended on which test ran first.
function M._pad_table(s, width)
  return pad_table(s, width)
end

--- The summary row split into its highlight parts. apply_highlights addresses
--- them by hand-numbered index, so the part count and order are a contract.
--- `width` pads the db segment; nil uses the current render's width.
function M._summary_parts(entry, width)
  return summary_parts(entry, width)
end

return M
