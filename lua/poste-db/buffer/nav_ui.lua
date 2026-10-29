--- Dataset winbar UI --- status line fragments for the dataset window.
local D = require("poste-db.dataset")
local config = require("poste-db.config")

local sql_state = require("poste-db.state")
local const = require("poste-db.constants")

local M = {}

local ICON_DATABASE = "\239\135\128"
local ICON_TABLE    = "\239\131\142"

--- Escape `%` for use inside a statusline/winbar string.
local function statusline_escape(s)
  return (s:gsub("%%", "%%%%"))
end

--- Flatten a multi-line SQL to a single line.
local function flatten_sql(sql)
  return (sql or ""):gsub("[ \t\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

--- For SELECT queries, replace multi-column lists with just the first column
--- + `, ...` before FROM. Case-insensitive for SELECT/FROM keywords.
local function shorten_select_fields(sql)
  local select_prefix, cols, from_clause = sql:match(
    "^([Ss][Ee][Ll][Ee][Cc][Tt]%s+)(.-)(%s+[Ff][Rr][Oo][Mm]%s.*)$")
  if not select_prefix then return sql end
  local first_col = cols:match("^(.-),")
  if not first_col then return sql end
  return select_prefix .. first_col .. ", ..." .. from_clause
end

--- Truncate a string to `max_width` display cells, appending `…`
--- (width.truncate_ellipsis — see lua/poste-db/width.lua).
local truncate_display = require("poste-db.width").truncate_ellipsis

function M.format_conn_short(conn)
  if not conn or conn == "" then return nil end
  local host, port, db = conn:match("^%w+://[^@]*@([^:]+):(%d+)/([^?]+)")
  if host then return string.format("%s:%s/%s", host, port, db) end
  return conn:match("/([^/]+)$") or conn
end

function M.build_statusline_context(meta, opts)
  if not meta or (meta.type ~= "resultset" and meta.type ~= "affected") then return nil end
  opts = opts or {}

  local parts = {}

  -- The TOML parser and a schema-violating binary can put non-strings in
  -- these fields; every :match/:gsub below needs a string, and a render-seam
  -- crash takes the whole dataset redraw down.
  local conn = type(meta.connection) == "string" and meta.connection or nil
  if conn and conn ~= "" then
    -- The binary echoes connection URLs, never names (exec_file.rs), so
    -- resolve a display name for the dataset's OWN url first — authoritative
    -- even when session state points elsewhere (browser-opened datasets).
    -- Then the applied name (@connection / :PosteDbConnection), then host:port.
    local connections = require("poste-db.connections")
    local conn_name = connections.name_for_url(conn)
      or (sql_state.context and sql_state.context.connection)
    if conn_name and conn_name ~= "" then
      parts[#parts + 1] = conn_name
    else
      local host, port = conn:match("^%w+://[^@]*@([^:]+):(%d+)")
      if host then
        parts[#parts + 1] = string.format("%s:%s", host, port)
      elseif not conn:match("^%w+://") then
        -- not URL-shaped: already a bare name (error/affected metas carry
        -- context.connection verbatim) — show it as-is
        parts[#parts + 1] = conn
      end
    end
  end

  -- Prefer the resolved database actually used by the query (from @database /
  -- USE), falling back to the one embedded in the connection URL.
  local db = type(meta.database) == "string" and meta.database or nil
  if (not db or db == "") and conn and conn ~= "" then
    db = conn:match("^%w+://[^@]*@[^/]+/([^?]+)")
    if db then db = (db:gsub("/$", "")) end
  end
  if db and db ~= "" then
    parts[#parts + 1] = ICON_DATABASE .. " " .. db
  end

  if opts.include_table ~= false then
    local tbl = type(meta.table_name) == "string" and meta.table_name or nil
    if tbl and tbl ~= "" then
      parts[#parts + 1] = ICON_TABLE .. " " .. tbl
    end
  end

  if #parts == 0 then return nil end
  return table.concat(parts, "  ")
end

function M.update_dataset_statusline(meta)
  local buf = D.dataset_buffer
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local ctx = M.build_statusline_context(meta)
  vim.b[buf].poste_db_context = ctx or ""
  if meta and meta.connection then
    vim.b[buf].poste_db_conn = meta.connection
  end
  -- update_dataset_sql_statusline already forces the redraw when its text
  -- changed; the extra one here ran on every render for nothing.
  M.update_dataset_sql_statusline()
end

function M.build_status_left(meta, tab)
  if not meta or meta.type ~= "resultset" then return nil end
  local rows = meta.total_rows or meta.row_count or 0
  local ms = meta.total_execution_time_ms or 0

  local left = string.format("  %d row%s · %dms", rows, rows == 1 and "" or "s", ms)

  if tab and tab.sort then
    local col_name = meta.columns and meta.columns[tab.sort.col] and meta.columns[tab.sort.col].name
    if col_name then
      local arrow = tab.sort.ascending and " ↑" or " ↓"
      left = left .. "   " .. statusline_escape(col_name) .. arrow
    end
  end

  if tab and tab.num_pages and tab.num_pages > 1 and tab.layout then
    if tab.pagination_enabled then
      left = left .. string.format("  %sP:%d/%d%s",
        "%#PosteDbDatasetMetaDim#", tab.page, tab.num_pages, "%#PosteDbDatasetMeta#")
    else
      left = left .. "  %#PosteDbDatasetMetaDim#All%#PosteDbDatasetMeta#"
    end
  end

  if tab and tab.filter_active and tab.filter_col_name then
    local fv = tab.filter_val
    -- Same reading as search.lua's search_text_of: a decoded JSONB value is a
    -- table, and tostring rendered "table: 0x…" into the winbar.
    local fvs
    if fv == nil or fv == vim.NIL then
      fvs = "NULL"
    elseif type(fv) == "table" then
      local ok, encoded = pcall(vim.json.encode, fv)
      fvs = ok and encoded or vim.inspect(fv)
    else
      fvs = tostring(fv)
    end
    -- Column names and filter values come from the data, so a `%` in them must
    -- not reach the statusline as a format item.
    left = left .. string.format("  %sfilter: %s=%s%s",
      "%#PosteDbDatasetFilterActive#", statusline_escape(tab.filter_col_name),
      statusline_escape(fvs), "%#PosteDbDatasetMeta#")
  end

  if tab and tab.search_text and tab.search_matches and #tab.search_matches > 0 then
    local cnt = string.format("%d/%d", tab.search_idx or 0, #tab.search_matches)
    local info = statusline_escape(tab.search_text) .. " (" .. cnt .. ")"
    left = left .. string.format("  %ssearch: %s%s",
      "%#PosteDbDatasetSearchActive#", info, "%#PosteDbDatasetMeta#")
  elseif tab and tab.search_text then
    left = left .. string.format("  %ssearch: %s (0)%s",
      "%#PosteDbDatasetSearchActive#", statusline_escape(tab.search_text), "%#PosteDbDatasetMeta#")
  end

  return left
end

function M.build_status_right(meta, total_tabs, active_idx, pending)
  if not meta or meta.type ~= "resultset" then return nil end

  local right = ""
  if pending then
    right = right .. pending .. "  "
  end
  -- Request history position (JetBrains-style sidebar)
  local hcount = D.history_count()
  if hcount > 1 and D.active_history >= 1 then
    right = right .. string.format("H:%d/%d ", D.active_history, hcount)
  end
  if total_tabs > 1 then
    local label = meta.table_name or ("result " .. active_idx)
    local next_k = config.get_keymap("sql_dataset", "next_tab", "<Tab>")
    local prev_k = config.get_keymap("sql_dataset", "prev_tab", "<S-Tab>")
    right = right .. string.format("[%d/%d: %s] (%s/%s) ", active_idx, total_tabs,
      statusline_escape(tostring(label)), statusline_escape(prev_k), statusline_escape(next_k))
  end

  return right
end

function M.build_pending_changes_text(tab)
  if not tab or not tab.edit_state or not tab.edit_state.dirty then
    return nil
  end
  return require("poste-db.editor").pending_changes_text(tab.edit_state)
end

function M.build_status_winbar_text(meta, tab, total_tabs, active_idx, pending)
  if not meta or (meta.type ~= "resultset" and meta.type ~= "affected") then return nil end

  local left, right
  if meta.type == "affected" then
    -- Non-query results carry no row/sort/pagination fragments; show only the
    -- connection/db context on the winbar.
    left, right = "", ""
  else
    left = M.build_status_left(meta, tab)
    right = M.build_status_right(meta, total_tabs, active_idx, pending)
    if not left or not right then return nil end
  end

  -- Connection/db context lives on the winbar's left (table name omitted — the
  -- queried tables are already visible in the dataset content); `%<` drops the
  -- status fragments first when the window is too narrow.
  local win = D.dataset_window
  local width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or vim.o.columns
  local ctx = M.build_statusline_context(meta, { include_table = false })
  if ctx and ctx ~= "" then
    local ctx_text = truncate_display(flatten_sql(ctx), math.max(10, width - 24))
    left = "%#PosteDbDatasetMeta# " .. statusline_escape(ctx_text) .. "%#PosteDbDatasetMeta#%<" .. left
  end

  local text = left .. "%=" .. right
  return "%#PosteDbDatasetMeta#" .. text
end

function M.build_status_winbar(meta, tab, total_tabs, active_idx)
  local current_tab = D.T()
  local pending = M.build_pending_changes_text(current_tab)
  M.update_dataset_statusline(meta)
  return M.build_status_winbar_text(meta, tab, total_tabs, active_idx, pending)
end

--- Build the dataset statusline: the active request's SQL, truncated to the
--- window width. Empty when no SQL (falls back to the default statusline).
--- @param sql string|nil active entry's SQL
--- @param width number statusline width in cells
--- @return string
function M.build_sql_statusline(sql, width)
  local text = flatten_sql(sql or "")
  text = shorten_select_fields(text)
  text = truncate_display(text, math.max(10, width - 2))
  if text == "" then return "" end
  return "%#PosteDbDatasetMeta# " .. statusline_escape(text) .. "%#PosteDbDatasetMeta#"
end

--- Set the dataset window's statusline to a SQL preview of the active history
--- entry (or its given entry). Called on render and on every history switch.
--- @param entry table|nil overrides D.active_entry()
local _last_sql_statusline = nil

--- Forget the unchanged-text caches. A freshly created dataset window has no
--- win-local statusline yet, so a stale "same text" verdict would leave it
--- blank (run query A, close the panel, run the identical query A again).
--- Call when ensure_dataset_window actually creates a window.
function M.reset_statusline_caches()
  _last_sql_statusline = nil
end

function M.update_dataset_sql_statusline(entry)
  local win = D.dataset_window
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local sql = (entry or D.active_entry() or {}).sql
  local text = M.build_sql_statusline(sql, vim.api.nvim_win_get_width(win))
  -- render_dataset finalizes the page, then rebuilds the winbar again, and
  -- both paths land here: skip the option write and the forced redraw when
  -- the built text is unchanged (window width is part of the text).
  if text == _last_sql_statusline then return end
  _last_sql_statusline = text
  pcall(vim.api.nvim_set_option_value, "statusline", text, { win = win })
  vim.cmd("redrawstatus")
end

--- Show the active history entry's SQL in a floating dialog window.
function M.show_dataset_sql()
  local entry = D.active_entry()
  if not entry then
    vim.notify("No active request", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return
  end
  local sql = entry.sql
  if not sql or sql == "" then
    vim.notify("No SQL for this request", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    return
  end
  local lines = vim.split(sql, "\n")
  local width = math.min(120, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 6)
  local dialog = require("poste-db.dialog")
  local d = dialog.open({
    title = " Dataset SQL ",
    width = width,
    height = height,
    border = "rounded",
  })
  d:update(lines)
  vim.bo[d.buf].filetype = "sql"
  vim.bo[d.buf].syntax = "ON"
end

return M
