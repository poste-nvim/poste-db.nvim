--- SQL Dataset formatter — renders query results as Unicode tables.
--- Used by the Dataset buffer (bottom horizontal split).
local C = require("poste-db.constants")
local dataset = require("poste-db.dataset")
-- `wutil`, not `width`: pad/wrap helpers below take a `width` parameter and
-- would shadow the module binding (luacheck W431).
local wutil = require("poste-db.width")
local util = require("poste-db.util")
local log = require("poste-db.log")
local types = require("poste-db.types")
local verdict = require("poste-db.verdict")
local M = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function split_lines(s)
  local lines = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

--- Calculate display width of a string. strdisplaywidth() alone under-counts
--- Devanagari/Indic spacing marks (vim folds them to 0, the terminal paints
--- them) — width.display_width() corrects that; see lua/poste-db/width.lua.
local function displaywidth(s)
  return wutil.display_width(s)
end

--- Truncate a string to fit within a given display width, preserving UTF-8 validity.
--- Walks character-by-character so multi-byte chars like CJK are never split.
local function truncate_to_displaywidth(s, max_dw)
  return wutil.truncate(s, max_dw)
end

--- Pad a string to a given display width (right-pad with spaces).
local function pad_right(s, width)
  local dw = displaywidth(s)
  if dw >= width then return s end
  return s .. string.rep(" ", width - dw)
end

--- Wrap a long line to fit within a given display width, splitting at word
--- boundaries. The leading run of whitespace becomes a hanging indent: every
--- row carries it, so the width checked here is the width the row occupies
--- once it reaches the buffer. A single word wider than `width` gets its own
--- overflowing row rather than an empty row before it.
local function wrap_line(text, width)
  if displaywidth(text) <= width then return { text } end
  local indent = text:match("^%s*")
  local lines = {}
  local current, fresh = indent, true
  for word in text:gmatch("%S+") do
    local sep = fresh and "" or " "
    if displaywidth(current .. sep .. word) > width then
      if not fresh then table.insert(lines, current) end
      current, fresh = indent .. word, false
    else
      current = current .. sep .. word
      fresh = false
    end
  end
  if not fresh then table.insert(lines, current) end
  if #lines == 0 then lines = { "" } end
  return lines
end

--- Pad a string to a given display width (left-pad with spaces).
local function pad_left(s, width)
  local dw = displaywidth(s)
  if dw >= width then return s end
  return string.rep(" ", width - dw) .. s
end

--- Local timezone offset (seconds east of UTC), computed by comparing the
--- local and UTC renderings of the same instant.
local function local_utc_offset()
  local now = os.time()
  return os.time(os.date("*t", now)) - os.time(os.date("!*t", now))
end

--- Convert a datetime string to local timezone for display.
--- Only converts if the string has a timezone indicator (Z or +/-HH:MM);
--- the indicator is honored — a `Z` timestamp renders as the local wall
--- clock, not as the raw UTC fields. A fractional-seconds suffix is carried
--- over untouched: dropping it silently changed the value a timestamp(6)
--- column showed (two commits 200ms apart rendered as the same second).
--- @param s string
--- @return string
local function format_datetime_local(s)
  if not s or s == "" then return s end
  local tz_tail = s:match("(Z)$") or s:match("([%+%-]%d%d:%d%d)$")
  if not tz_tail then return s end
  -- Lua patterns cannot quantify a group, so the fraction is the greedy
  -- digit/dot run right after the fixed-length timestamp head ("" when the
  -- value carries no sub-second part).
  local ts, fraction = s:match("^(%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d)(%.?%d*)")
  if not ts then return s end
  local y, mo, d, h, mi, sec = ts:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
  if not y then return s end
  -- Offset carried by the string: 0 for `Z`, ±seconds for ±hh:mm.
  local tz_off = 0
  if tz_tail ~= "Z" then
    local sign, oh, om = tz_tail:match("^([%+%-])(%d%d):(%d%d)$")
    if sign then
      tz_off = tonumber(oh) * 3600 + tonumber(om) * 60
      if sign == "-" then tz_off = -tz_off end
    end
  end
  -- os.time reads the fields as LOCAL time; shifting by (local_off - tz_off)
  -- yields the true epoch, which os.date then renders in local time.
  local ok, result = pcall(function()
    return os.date("%Y-%m-%d %H:%M:%S",
      os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec })
        - tz_off + local_utc_offset())
  end)
  if not ok then return s end
  return result .. (fraction or "")
end

--- Format a Lua number for table display. Integer-valued numbers keep the
--- integer form; fractional doubles are rounded to at most `MAX_FLOAT_DECIMALS`
--- digits after the dot (trailing zeros stripped) so values like
--- `578.47196567559` don't blow up the column width. `format_number` is also
--- used for cell previews, so precision beyond the cap is expected display only.
local MAX_FLOAT_DECIMALS = 4

local function trim_trailing_zeros(s)
  s = s:gsub("0+$", "")
  s = s:gsub("%.$", "")
  return s
end

function M.format_number(val)
  if type(val) ~= "number" then return tostring(val) end
  if val == math.floor(val) and math.abs(val) < 1e15 then
    return string.format("%.0f", val)
  end
  -- Every double at or above 1e15 in magnitude is integer-valued, so the
  -- branch above already took every honest integer; what still falls through
  -- is ±inf and magnitudes whose %f form is the FULL expansion — a Float64
  -- 1e300 printed ~300 digits and blew the column width up with it.
  -- Scientific form is the honest display past the exact-integer range.
  if math.abs(val) >= 1e15 then
    return string.format("%.6g", val)
  end
  if val ~= 0 and math.abs(val) < 0.0001 then
    -- Tiny magnitudes: keep significant digits (scientific form) instead of
    -- collapsing to 0.0000.
    return string.format("%.6g", val)
  end
  local s = string.format("%." .. MAX_FLOAT_DECIMALS .. "f", val)
  return trim_trailing_zeros(s)
end

-- Local binding so cell_to_string (defined below) can call it without a global.
local format_number = M.format_number

--- Convert a cell value to display string.
--- Newlines are replaced with ⏎ to keep table layout intact.
--- Timestamps are converted to local timezone.
local function cell_to_string(val, col)
  if val == "[Auto]" then
    return "<auto>"
  end
  if type(val) == "string" and val:match("^__expr:") then
    return val:match("^__expr:(.*)$")
  end
  if val == vim.NIL or val == nil then
    if col and col.default then
      return "<default>"
    end
    return "<null>"
  end
  if type(val) == "boolean" then
    if col and col.type and col.type:lower():match("^tinyint") then
      return val and "1" or "0"
    end
    return tostring(val)
  end
  if type(val) == "number" then
    return format_number(val)
  end
  local s
  if type(val) == "table" then
    -- JSON/JSONB values — compact encode
    local ok, encoded = pcall(vim.json.encode, val)
    s = ok and encoded or vim.inspect(val)
  elseif type(val) == "blob" then
    s = "<blob: " .. #val .. " bytes>"
  else
    s = tostring(val)
  end
  -- Convert timestamps to local timezone
  if col and col.type and col.type:upper():match("TIME") then
    s = format_datetime_local(s)
  end
  -- Replace newlines with a visual indicator so nvim_buf_set_lines doesn't break
  s = s:gsub("\r\n", "⏎"):gsub("\n", "⏎"):gsub("\r", "⏎")
  return s
end

--- Normalize raw DB type name to ctype for editor type-checking.
--- Maps database-specific type names (INT4, VARCHAR, etc.) to
--- the normalized forms used in editor.lua's type tables, after taking any
--- ClickHouse modifier (`Nullable(...)`, `LowCardinality(...)`) off the name.
--- @param raw string Raw type name from DB (e.g. "INT4", "VARCHAR", "BOOL")
--- @return string Normalized type name (e.g. "integer", "varchar", "boolean")
local function normalize_type(raw)
  if not raw then return "" end
  local t = types.unwrap_modifier(raw:lower())
  local map = {
    -- PostgreSQL / generic integer
    int4 = "integer", int8 = "bigint", int2 = "smallint",
    integer = "integer", bigint = "bigint", smallint = "smallint",
    serial = "serial", bigserial = "bigserial", smallserial = "smallserial",
    tinyint = "integer",
    -- PostgreSQL/Oracle-style numeric
    numeric = "numeric", decimal = "decimal",
    float4 = "real", float8 = "float", real = "real", float = "float",
    double = "float", ["double precision"] = "float", money = "numeric",
    -- Boolean
    bool = "boolean", boolean = "boolean",
    -- Text
    text = "text", varchar = "varchar", char = "char", character = "char",
    ["character varying"] = "varchar",
    nvarchar = "nvarchar", nchar = "nchar",
    longtext = "longtext", mediumtext = "mediumtext", tinytext = "tinytext",
    citext = "text", name = "varchar",
    -- Date/time
    date = "date", timestamp = "timestamp", timestamptz = "timestamptz",
    datetime = "datetime", datetime2 = "datetime",
    time = "date", timetz = "timestamp", interval = "interval",
    -- JSON
    json = "json", jsonb = "jsonb",
    -- UUID
    uuid = "uuid",
    -- Binary / ineditable
    bytea = "bytea", blob = "blob", binary = "binary", varbinary = "varbinary",
    tinyblob = "blob", mediumblob = "blob", longblob = "blob",
    geometry = "geometry", geography = "geography",
    point = "point", polygon = "polygon", linestring = "linestring",
    multipolygon = "multipolygon",
    inet = "inet", cidr = "cidr", macaddr = "macaddr", macaddr8 = "macaddr8",
    bit = "bit", varbit = "varbit",
    tsvector = "tsvector", tsquery = "tsquery",
    xml = "xml", hstore = "hstore",
  }
  return map[t] or t
end

--- The non-finite doubles arrive as text because JSON has no spelling for them
--- (see `poste.nvim` `sql_values::float_json`): the engines print `Infinity` /
--- `NaN`, and ClickHouse's text rows carry its own bare `inf` / `nan`. Checked
--- only for a column whose declared type is already numeric, so a text column
--- full of "Infinity" strings cannot borrow the exemption.
local function is_non_finite_text(val)
  local s = val:lower()
  return s == "inf" or s == "-inf" or s == "infinity" or s == "-infinity" or s == "nan"
end

--- Check if a column contains only numeric values (for right-alignment).
--- Values may arrive as Lua numbers OR as strings (bigints above 2^53 and
--- large DECIMALs are serialized as JSON strings to preserve precision).
--- @param rows table[] Row data
--- @param col_idx number Column index (1-based)
--- @param col_meta table|nil Column metadata with .type
--- @return boolean
local function is_numeric_column(rows, col_idx, col_meta)
  local is_numeric_type = false
  if col_meta and col_meta.type then
    local ctype = normalize_type(col_meta.type)
    -- the same root-word lookup the import mapper and the DML generators use,
    -- so a size-tagged or dialect-flavoured declaration (`decimal(10,2)`,
    -- `UInt64`) aligns the way the bare name does. An empty ctype means the
    -- server gave nothing, and guessing that a text column is numeric is not
    -- what alignment is for.
    is_numeric_type = ctype ~= "" and types.is_numeric(ctype)
  end
  for _, row in ipairs(rows) do
    -- a row that is not a sequence of cells cannot be a numeric column
    if type(row) ~= "table" then return false end
    local val = row[col_idx]
    if val ~= nil and val ~= vim.NIL then
      local is_number = type(val) == "number"
      -- numeric string (bigint/decimal preserved as string, or a non-finite
      -- double spelled as text)
      local numeric_string = is_numeric_type and type(val) == "string"
        and (val:match("^%-?%d+%.?%d*$") ~= nil or is_non_finite_text(val))
      if not is_number and not numeric_string then
        return false
      end
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Unicode table rendering
---------------------------------------------------------------------------

--- Calculate optimal column widths for a result set.
--- @param columns table[] Column metadata
--- @param rows table[][] Row data
--- @param max_width number Maximum total table width (0 = unlimited)
--- @param max_col_width number Per-column cap (0 = unlimited)
--- @return number[] widths Array of column display widths
local function calc_column_widths(columns, rows, max_width, max_col_width)
  local widths = {}
  local min_data_widths = {}
  for i, col in ipairs(columns) do
    widths[i] = displaywidth(col.name)
    min_data_widths[i] = widths[i]
  end

  for _, row in ipairs(rows) do
    -- A row that is not a sequence of cells (a malformed or hand-built
    -- response) is skipped rather than fatal: format_dataset is called
    -- unpcall'd from four seams, so a raise here drops the whole response —
    -- the user sees nothing at all for a query the server answered.
    if type(row) == "table" then
      for i, val in ipairs(row) do
        if i <= #widths then
          local s = cell_to_string(val, columns[i])
          local dw = displaywidth(s)
          widths[i] = math.max(widths[i], dw)
          min_data_widths[i] = math.max(min_data_widths[i], dw)
        end
      end
    end
  end

  -- Cap each column at max_col_width so short columns keep natural width
  if max_col_width and max_col_width > 0 then
    for i = 1, #widths do
      widths[i] = math.min(widths[i], max_col_width)
    end
  end

  if max_width and max_width > 0 then
    local overhead = #widths * 3 + 1
    local available = max_width - overhead
    if available < #widths then
      available = #widths
    end

    local total = 0
    for _, w in ipairs(widths) do total = total + w end

    if total > available then
      -- Proportional squeeze only when still too wide after capping
      local scale = available / total
      for i = 1, #widths do
        widths[i] = math.max(4, math.floor(widths[i] * scale))
      end
      for i, col in ipairs(columns) do
        local name_w = displaywidth(col.name or "")
        if name_w > widths[i] then
          widths[i] = name_w
        end
      end
      -- Protect date/time columns from truncation: column name or value
      -- pattern suggests a timestamp — ensure full value fits (capped at 25).
      for i, col in ipairs(columns) do
        local name = (col.name or ""):lower()
        if name:match("date") or name:match("time") or name:match("_at$") or name:match("timestamp") then
          widths[i] = math.max(widths[i], math.min(min_data_widths[i], 25))
        end
      end
    end
  end

  for i = 1, #widths do
    widths[i] = widths[i] + 2
  end

  return widths
end

--- Build a horizontal border line.
--- @param widths number[] Column widths
--- @param left string Left junction character
--- @param mid string Middle junction character
--- @param right string Right junction character
--- @param fill string Fill character (usually ─)
local function border_line(widths, left, mid, right, fill)
  local parts = {}
  for _, w in ipairs(widths) do
    parts[#parts + 1] = string.rep(fill, w + 2) -- +2 for padding spaces
  end
  return left .. table.concat(parts, mid) .. right
end

--- Total display width of a complete bordered row for the given column
--- widths (already including the +2 padding margin). Matches border_line()
--- and the two padding spaces every data cell gets.
local function row_total_width(widths)
  local total = #widths + 1
  for _, w in ipairs(widths) do total = total + w + 2 end
  return total
end

--- Build a data row line.
--- @param cells string[] Cell display strings
--- @param widths number[] Column widths
--- @param numeric_cols boolean[] Which columns are numeric (right-align)
---
--- Note on rendering consistency: `strdisplaywidth` of a composed line is not
--- always the sum of its individually-padded cells (two-byte glyphs adjacent
--- to box-drawing characters can flush a cell differently in context). When
--- that happens the trailing `│` lands one cell past the right border, hiding
--- it. The rightmost column absorbs the exact remainder so every row has
--- exactly the border width.
--- A cell is text by the time it reaches the row builder — except a column
--- whose NAME is absent: `col.name` can decode to the truthy `vim.NIL`, which
--- measures fine and then raises on `..` (and `displaywidth` would have
--- spelled it "vim.NIL" even if it had not). One name for the whole row.
local function cell_text(v)
  if type(v) == "string" then return v end
  if v == nil or v == vim.NIL then return "" end
  return tostring(v)
end

local function data_row(cells, widths, numeric_cols)
  local line_buf = { "│" }
  local col_starts = {}
  local byte_pos = 3
  local total = row_total_width(widths)
  local last = #widths
  for i, cell in ipairs(cells) do
    if i > #widths then break end
    cell = cell_text(cell)
    local w = widths[i]
    local s
    if i == last then
      local prefix_w = displaywidth(table.concat(line_buf))
      local avail = total - prefix_w - 3
      local content = cell
      if displaywidth(content) > avail then
        content = truncate_to_displaywidth(content, math.max(2, avail - 1)) .. "…"
      end
      local cw = displaywidth(content)
      local pad = math.max(0, total - prefix_w - cw - 3)
      if numeric_cols[i] then
        s = " " .. pad_left(content, cw + pad) .. " "
      else
        s = " " .. content .. string.rep(" ", pad) .. " "
      end
    else
      s = displaywidth(cell) > w
        and (truncate_to_displaywidth(cell, w - 1) .. "…")
        or cell
      if numeric_cols[i] then
        s = " " .. pad_left(s, w) .. " "
      else
        s = " " .. pad_right(s, w) .. " "
      end
    end
    line_buf[#line_buf + 1] = s
    col_starts[i] = { ext_start = byte_pos, ext_end = byte_pos + #s }
    byte_pos = byte_pos + #s
    line_buf[#line_buf + 1] = "│"
    byte_pos = byte_pos + 3
  end
  return table.concat(line_buf), col_starts
end

---------------------------------------------------------------------------
-- Dataset rendering result
---------------------------------------------------------------------------

--- Metadata about the rendered dataset, used by buffer.lua for cell navigation.
--- @class DatasetMeta
--- @field columns table[] Column metadata from the response
--- @field col_widths number[] Display width of each column
--- @field header_line number Line number of the header row
--- @field data_start_line number First line of data rows
--- @field data_end_line number Last line of data rows
--- @field row_count number Number of data rows
--- @field is_numeric boolean[] Whether each column is numeric

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Append the translated-SQL footnote. `original_sql` is flattened to one
--- line first: nvim_buf_set_lines rejects strings containing newlines, so an
--- embedded raw multi-line statement would abort the whole render.
local function append_translated_footnote(lines, layout)
  local footnote_width = math.max(40, (vim.o.columns or 80) - 4)
  local original = (layout.original_sql or ""):gsub("%s*\n%s*", " ")
  lines[#lines + 1] = "  -- " .. original
  lines[#lines + 1] = ""
  -- wrap_line keeps a leading run of spaces as a hanging indent, so wrapping
  -- the statement with the continuation pad in front of it makes every row
  -- land inside footnote_width; the marker row then swaps that pad for the
  -- ⚡ prefix, which occupies the same five cells.
  local pad = "     "
  local wrapped = wrap_line(pad .. layout.translated_sql, footnote_width)
  local first = wrapped[1]
  if first:sub(1, #pad) == pad then first = first:sub(#pad + 1) end
  lines[#lines + 1] = "  ⚡ " .. first
  for i = 2, #wrapped do
    lines[#lines + 1] = wrapped[i]
  end
end

--- Format a SQL response as a dataset table.
--- @param r table Response object (with .body as JSON string)
--- @return string[] lines Lines to display in the buffer
--- @return DatasetMeta meta Metadata for cell navigation
function M.format_dataset(r)
  local ok, data = pcall(vim.json.decode, r.body)
  if not ok or type(data) ~= "table" then
    return split_lines(r.body or "(empty)"), {}
  end

  local rtype = data.type or "unknown"

  -- USE statement: context switch
  if rtype == "use" then
    -- util.named, not `or ""`: a decoded JSON null is the truthy vim.NIL, and
    -- concatenating it raised inside the panel (the same "a name that names
    -- nothing" family the AI scope, the browser schema and the DDL generators
    -- already went through). The `???` / `unknown` fallbacks stay visible.
    local lines = {
      "",
      "  Context switched to: " .. (util.named(data.database_name) or "???"),
      "",
      string.format("  Connection: %s", log.redact_url(util.named(data.connection) or "unknown")),
      string.format("  Dialect:    %s", util.named(data.dialect) or ""),
      "",
    }
    return lines, { type = "use" }
  end

  -- Affected rows (INSERT/UPDATE/DELETE)
  if rtype == "affected" then
    local lines = { "" }
    local has_err = false
    local results = data.results or {}
    for i, res in ipairs(results) do
      -- The flag decides, the text only explains. `affected` responses are where
      -- a silently rejected INSERT/UPDATE used to print "Query OK" — the only
      -- thing missing was a message.
      local failed, err_text = verdict.classify(res)
      if failed then
        has_err = true
        local ms = tonumber(res.execution_time_ms) or 0
        local msg
        if #results > 1 then
          msg = string.format("  Statement %d: ERROR · %s · %dms", i, err_text, ms)
        else
          msg = string.format("  ERROR: %s · %dms", err_text, ms)
        end
        table.insert(lines, msg)
      else
        local affected = tonumber(res.affected_rows) or 0
        local ms = tonumber(res.execution_time_ms) or 0
        local msg
        if #results > 1 then
          msg = string.format("  Statement %d: %s · %dms", i,
            affected > 0 and string.format("%d row(s) affected", affected) or "Query OK", ms)
        else
          msg = string.format("  %s · %dms",
            affected > 0 and string.format("%d row(s) affected", affected) or "Query OK", ms)
        end
        table.insert(lines, msg)
      end
    end
    if has_err then
      table.insert(lines, "")
      return lines, { type = "error" }
    end
    -- Connection/db context is shown in the dataset winbar, not in the content.
    table.insert(lines, "")
    return lines, {
      type = "affected",
      connection = data.connection,
      database = data.database,
    }
  end

  -- Resultset: render table
  if rtype == "resultset" then
    local layout = M.plan_resultset_layout(data)
    if not layout or #layout.columns == 0 then
      return { "", "  (no results)", "" }, { type = "empty" }, layout
    end
    local lines, meta = M.render_page(layout, 1, dataset.default_page_size)
    meta.total_rows = layout.total_rows
    meta.table_name = data.table_name
    if layout.translated_sql then
      append_translated_footnote(lines, layout)
    end
    return lines, meta, layout
  end

  -- Fallback: raw JSON
  return split_lines(vim.json.encode(data)), { type = "raw" }
end

----------------------------------------------------------------------
-- Layout: full-table metadata (scans all rows once)
----------------------------------------------------------------------


--- Compute layout metadata for a result set. Scans all rows for
--- column widths and numeric detection, but produces no rendered strings.
--- @param data table Parsed JSON with results, columns, rows
--- @return table|nil Layout object (nil if no results/columns)
function M.plan_resultset_layout(data)
  local results = data.results or {}
  if #results == 0 then return nil end
  local res = results[1]
  local columns = res.columns or {}
  local rows = res.rows or {}

  if #columns == 0 then return nil end

  local total_rows = tonumber(data.total_rows) or #rows
  local row_num_width = math.max(1, math.floor(math.log10(math.max(1, total_rows))) + 1)

  local col_widths = calc_column_widths(columns, rows, 200, C.MAX_COL_WIDTH)
  table.insert(col_widths, 1, row_num_width)

  local numeric_cols = { false }
  for i = 1, #columns do
    numeric_cols[i + 1] = is_numeric_column(rows, i, columns[i])
  end

  -- Normalize raw DB type names to ctype for editor type-checking
  for _, col in ipairs(columns) do
    local raw = col.type
    if raw then
      col.ctype = normalize_type(raw)
    end
  end

  local conn = data.connection or ""
  if conn == vim.NIL then conn = "" end
  local db = data.database
  if db == vim.NIL then db = nil end
  local dialect = data.dialect or ""
  if dialect == vim.NIL then dialect = "" end

  return {
    columns = columns,
    col_widths = col_widths,
    numeric_cols = numeric_cols,
    row_num_width = row_num_width,
    total_rows = total_rows,
    original_row_count = #rows,
    data = data,
    res = res,
    rows = rows,
    translated_sql = res.translated_sql,
    original_sql = res.original_sql,
    execution_time_ms = data.total_execution_time_ms or 0,
    connection = conn,
    database = db,
    dialect = dialect,
    table_name = data.table_name,
  }
end

--- One rendered row's cells: the row number, then one cell per column.
--- A row that is not a sequence of cells — or a view index with no row behind
--- it — renders as empty cells instead of raising: `format_dataset` is called
--- unpcall'd from four seams, so a raise here drops the whole response and the
--- user sees nothing at all for a query the server answered.
local function row_cells(rows, idx, columns, row_number)
  local cells = { tostring(row_number) }
  local row = type(rows[idx]) == "table" and rows[idx] or nil
  for i = 1, #columns do
    cells[i + 1] = cell_to_string(row and row[i] or nil, columns[i])
  end
  return cells
end

--- Render a single page from a Layout. Produces a bordered table with
--- only `page_size` data rows. Column widths come from Layout (stable).
--- @param layout table Layout from plan_resultset_layout()
--- @param page number 1-based page number
--- @param page_size number Rows per page
--- @return string[] lines
--- @return DatasetMeta meta
function M.render_page(layout, page, page_size)
  local col_widths = layout.col_widths
  local columns = layout.columns
  local numeric_cols = layout.numeric_cols
  local rows = layout.rows
  local total_rows = layout.total_rows or #rows
  -- `or 1`: a zero page size is not "infinitely many pages" — it is a call
  -- that has no rows to page through, and the ceil would answer nan/inf.
  local total_pages = page_size > 0 and math.ceil(#rows / page_size) or 1
  page = math.min(page, total_pages)
  if page < 1 then page = 1 end
  local start_idx = (page - 1) * page_size + 1
  local end_idx = math.min(start_idx + page_size - 1, #rows)
  local page_rows = end_idx - start_idx + 1

  local lines = {}
  local line_num = 0

  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "┌", "┬", "┐", "─")

  line_num = line_num + 1
  local header_cells = { "#" }
  for i, col in ipairs(columns) do
    header_cells[i + 1] = col.name
  end
  local header_line_str, header_col_starts = data_row(header_cells, col_widths, {})
  lines[line_num] = header_line_str
  local header_line = line_num

  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "├", "┼", "┤", "─")

  local row_col_starts = {}
  local row_sources = {}
  local data_start = line_num + 1
  for row_idx = start_idx, end_idx do
    line_num = line_num + 1
    row_sources[#row_sources + 1] = row_idx
    local line, starts = data_row(row_cells(rows, row_idx, columns, row_idx),
      col_widths, numeric_cols)
    lines[line_num] = line
    row_col_starts[#row_col_starts + 1] = starts
  end
  if page_rows == 0 then
    line_num = line_num + 1
    local empty_cells = { "" }
    for i = 1, #columns do
      empty_cells[i + 1] = ""
    end
    lines[line_num] = data_row(empty_cells, col_widths, {})
    row_col_starts[#row_col_starts + 1] = {}
    line_num = line_num + 1
    lines[line_num] = "  (empty)"
  end
  local data_end = line_num

  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "└", "┴", "┘", "─")

  local meta = {
    type = "resultset",
    columns = columns,
    col_widths = col_widths,
    numeric_cols = numeric_cols,
    header_line = header_line,
    data_start_line = data_start,
    data_end_line = data_end,
    row_count = page_rows,
    col_count = #columns,
    total_rows = total_rows,
    total_execution_time_ms = layout.execution_time_ms,
    connection = layout.connection,
    database = layout.database,
    dialect = layout.dialect,
    table_name = layout.table_name,
    col_starts = row_col_starts,
    row_sources = row_sources,
    header_col_starts = header_col_starts,
  }

  return lines, meta
end

--- Render an arbitrary row view (filtered/sorted) from a Layout.
--- `view_indices` are 1-based indices into `layout.rows`.
--- @param layout table Layout from plan_resultset_layout()
--- @param view_indices number[] 1-based indices into layout.rows
--- @param page number 1-based page number over view_indices
--- @param page_size number Rows per page
--- @param opts? table Options: { row_number_mode = "source"|"view" }
--- @return string[] lines
--- @return DatasetMeta meta
function M.render_view(layout, view_indices, page, page_size, opts)
  opts = opts or {}
  local row_number_mode = opts.row_number_mode or "source"
  local col_widths = layout.col_widths
  local columns = layout.columns
  local numeric_cols = layout.numeric_cols
  local rows = layout.rows
  local total_view_rows = #view_indices
  -- `or 1`: see render_page — a filter that matched nothing renders with a
  -- zero page size, and ceil(0/0) is nan.
  local total_pages = page_size > 0 and math.ceil(total_view_rows / page_size) or 1
  page = math.min(page, total_pages)
  if page < 1 then page = 1 end
  local start_pos = (page - 1) * page_size + 1
  local end_pos = math.min(start_pos + page_size - 1, total_view_rows)
  local page_rows = end_pos - start_pos + 1

  local lines = {}
  local line_num = 0

  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "┌", "┬", "┐", "─")

  line_num = line_num + 1
  local header_cells = { "#" }
  for i, col in ipairs(columns) do
    header_cells[i + 1] = col.name
  end
  local header_line_str, header_col_starts = data_row(header_cells, col_widths, {})
  lines[line_num] = header_line_str
  local header_line = line_num

  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "├", "┼", "┤", "─")

  local row_col_starts = {}
  local row_sources = {}
  local row_numbers = {}
  local data_start = line_num + 1
  for view_pos = start_pos, end_pos do
    line_num = line_num + 1
    local src_idx = view_indices[view_pos]
    local row_num = (row_number_mode == "view") and view_pos or src_idx
    row_sources[#row_sources + 1] = src_idx
    row_numbers[#row_numbers + 1] = row_num
    local line, starts = data_row(row_cells(rows, src_idx, columns, row_num),
      col_widths, numeric_cols)
    lines[line_num] = line
    row_col_starts[#row_col_starts + 1] = starts
  end
  if page_rows == 0 then
    -- A filter or search that matched nothing used to render a bare table with
    -- two borders and no rows — the same view render_page already labelled.
    line_num = line_num + 1
    local empty_cells = { "" }
    for i = 1, #columns do
      empty_cells[i + 1] = ""
    end
    lines[line_num] = data_row(empty_cells, col_widths, {})
    row_col_starts[#row_col_starts + 1] = {}
    line_num = line_num + 1
    lines[line_num] = "  (empty)"
  end
  local data_end = line_num
  line_num = line_num + 1
  lines[line_num] = border_line(col_widths, "└", "┴", "┘", "─")

  local meta = {
    type = "resultset",
    columns = columns,
    col_widths = col_widths,
    numeric_cols = numeric_cols,
    header_line = header_line,
    data_start_line = data_start,
    data_end_line = data_end,
    row_count = page_rows,
    col_count = #columns,
    total_rows = total_view_rows,
    total_execution_time_ms = layout.execution_time_ms,
    connection = layout.connection,
    database = layout.database,
    dialect = layout.dialect,
    table_name = layout.table_name,
    col_starts = row_col_starts,
    row_sources = row_sources,
    row_numbers = row_numbers,
    header_col_starts = header_col_starts,
  }

  return lines, meta
end

--- Render a resultset response as a Unicode table (legacy: all rows).
--- Used by the old path and callers still expecting full render.
--- @param data table Parsed JSON with results, columns, rows
--- @return string[] lines
--- @return DatasetMeta meta
--- @return table|nil layout planned layout (nil for empty results), so
---   callers can render layout-aware (pagination, filtering, sorting)
function M.format_resultset(data)
  local layout = M.plan_resultset_layout(data)
  if not layout then
    return { "", "  (no results)", "" }, { type = "empty" }, nil
  end
  if #layout.columns == 0 then
    return { "", "  (empty result set)", "" }, { type = "empty" }, layout
  end

  local page_size = #layout.rows
  local lines, meta = M.render_page(layout, 1, page_size)

  if layout.translated_sql then
    append_translated_footnote(lines, layout)
  end

  meta.total_rows = layout.total_rows

  return lines, meta, layout
end

--- A rendered page numbers its rows by their position on screen, while the
--- row DATA lives in `layout.rows` / `rows_source` at source indices, and the
--- `#` column may show either (row_number_mode). `meta.row_sources` /
--- `meta.row_numbers` record what each rendered line holds; a meta without
--- them (rendered elsewhere, or before this bookkeeping) maps identity.
--- @param meta DatasetMeta from render_page/render_view
--- @param visible_row number 1-based row within the rendered page
--- @return number|nil index into layout.rows, nil when off this page
function M.source_row_of(meta, visible_row)
  if not meta then return nil end
  if not meta.row_sources then return visible_row end
  return meta.row_sources[visible_row]
end

--- @param meta DatasetMeta
--- @param source_row number index into layout.rows
--- @return number|nil 1-based row within the rendered page, nil when off it
function M.visible_row_of(meta, source_row)
  if not meta then return nil end
  if not meta.row_sources then return source_row end
  for i, s in ipairs(meta.row_sources) do
    if s == source_row then return i end
  end
  return nil
end

--- @param meta DatasetMeta
--- @param visible_row number
--- @return number|nil the number shown in the `#` column for that line
function M.row_number_of(meta, visible_row)
  if not meta then return nil end
  if meta.row_numbers then return meta.row_numbers[visible_row] end
  return M.source_row_of(meta, visible_row)
end

--- Render a single data row as a formatted line.
--- @param row table Row data array
--- @param layout table Layout with columns, col_widths, numeric_cols
--- @param row_number number Row number to display
--- @return string Formatted line with │ separators
function M.render_row(row, layout, row_number)
  local cells = { tostring(row_number) }
  for i = 1, #layout.columns do
    cells[i + 1] = cell_to_string(row[i], layout.columns[i])
  end
  return data_row(cells, layout.col_widths, layout.numeric_cols)
end

local function wrap_text(text, width)
  if not text or #text == 0 then return {} end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    -- Cut on character boundaries by display width. The old byte-based
    -- `line:sub(1, width)` split multibyte characters in half and put
    -- invalid UTF-8 into the buffer (error messages routinely contain
    -- non-ASCII table/column names).
    -- wutil.truncate walks the line once per cut; the scan it replaced
    -- measured every character with its own strdisplaywidth() call, so a
    -- long driver error paid O(n^2) nvim round-trips to wrap.
    local chunks = 0
    while wutil.display_width(line) > width do
      local head = wutil.truncate(line, width)
      if head == "" then
        -- one character wider than the line: take it whole or loop forever
        head = vim.fn.strcharpart(line, 0, 1)
      end
      table.insert(lines, head)
      line = line:sub(#head + 1)
      chunks = chunks + 1
    end
    -- A cut that lands exactly on the end of the line leaves "": emitting it
    -- added a blank row the message never had.
    if chunks == 0 or line ~= "" then table.insert(lines, line) end
  end
  return lines
end

--- Format a SQL error response.
--- @param err string Error message
--- @param connection string Connection info
--- @return string[] lines
function M.format_error(err, connection)
  -- BOTH arguments arrive from several seams and neither is guaranteed to be
  -- text: the binary's `error` field passes through verdict.error_text
  -- (structured → vim.inspect), response.handle_error forwards its raw message,
  -- and `connection` is whatever the response envelope carried — a decoded JSON
  -- null is the truthy `vim.NIL`, which `or "unknown"` does not catch and
  -- concatenating raises on. Normalize each before use: `#text` raises on a
  -- number, `text .. "\n"` on a table, and a crash here kills the panel
  -- instead of rendering the error it was about to show.
  local function as_text(v)
    if v == nil or v == vim.NIL then return "" end
    if type(v) == "string" then return v end
    return vim.inspect(v)
  end
  -- A driver error can echo the DSN it failed on, so the message is redacted
  -- too — the panel is user-visible and the journal already is.
  local wrapped = wrap_text(log.redact_url(as_text(err)), 78)
  local lines = { "", "  ✗ SQL Error", "" }
  for _, l in ipairs(wrapped) do
    table.insert(lines, "  " .. l)
  end
  table.insert(lines, "")
  local conn = as_text(connection)
  if conn == "" then conn = "unknown" end
  table.insert(lines, "  Connection: " .. log.redact_url(conn))
  table.insert(lines, "")
  return lines
end

--- Exposed for tests.
M._test = {
  format_datetime_local = format_datetime_local,
  wrap_text = wrap_text,
  wrap_line = wrap_line,
  format_error = M.format_error,
}

return M
