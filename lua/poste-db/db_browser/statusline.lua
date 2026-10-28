--- DB Browser statusline: connection/db/schema/table/column context under the
--- cursor, the enclosing table/column comment (gray, truncated), and the yank
--- register indicator.
---
--- Mirrors the dataset window's statusline approach (buffer/nav_ui.lua): a
--- per-window `statusline` option carrying persistent context. The path tracks
--- the cursor so the statusline always shows where in the tree you are.

local icons = require("poste-db.db_browser.icons")
local MARKER_YANKED = icons.MARKER_YANKED

local M = {}

local ICON_CONN = "\239\136\179"
local ICON_DB = "\239\135\128"
local ICON_SCHEMA = "\239\129\187"
local ICON_TABLE = "\239\131\142"
local ICON_COLUMN = "\238\170\136"

--- Escape `%` for use inside a statusline string.
local function statusline_escape(s)
  return (s:gsub("%%", "%%%%"))
end

--- Truncate a string to `max` display cells, appending "…"
--- (width.truncate_ellipsis — see lua/poste-db/width.lua).
local truncate_display = require("poste-db.width").truncate_ellipsis

local function conn_part(conn_name)
  return "%#PosteDbBrowserIconConn#" .. ICON_CONN .. " %*" .. statusline_escape(conn_name)
end

local function db_part(db_name)
  return "%#PosteDbBrowserIconDb#" .. ICON_DB .. " %*" .. statusline_escape(db_name)
end

local function schema_part(schema_name)
  return "%#PosteDbBrowserIconSchema#" .. ICON_SCHEMA .. " %*" .. statusline_escape(schema_name)
end

local function table_part(table_name)
  return "%#PosteDbBrowserIconTable#" .. ICON_TABLE .. " %*" .. statusline_escape(table_name)
end

local function column_part(column_name)
  return "%#PosteDbBrowserIconCol#" .. ICON_COLUMN .. " %*" .. statusline_escape(column_name)
end

--- Build the path label from the scope under the cursor, e.g.
--- "▃ pg-dev  🗄 blog  📁 public  📊 orders  ⚈ id". Empty when no scope.
---@param conn_name string|nil
---@param db_name string|nil
---@param schema_name string|nil
---@param table_name string|nil
---@param column_name string|nil
---@return string
function M.node_path(conn_name, db_name, schema_name, table_name, column_name)
  local parts = {}
  if conn_name and conn_name ~= "" then
    parts[#parts + 1] = conn_part(conn_name)
  end
  if db_name and db_name ~= "" then
    parts[#parts + 1] = db_part(db_name)
  end
  if schema_name and schema_name ~= "" then
    parts[#parts + 1] = schema_part(schema_name)
  end
  if table_name and table_name ~= "" then
    parts[#parts + 1] = table_part(table_name)
  end
  if column_name and column_name ~= "" then
    parts[#parts + 1] = column_part(column_name)
  end
  return table.concat(parts, "  ")
end

--- Build the DB Browser statusline text.
---@param path string already-built path fragment (M.node_path output)
---@param comment string|nil table/column comment shown gray, truncated
---@param multi_select table|nil {active=boolean} for the selection counter
---@param width number statusline width in cells (for comment truncation)
---@return string statusline text; "" keeps the default statusline
function M.build(path, comment, multi_select, width)
  local yank = require("poste-db.db_browser.yank")
  local yanked = yank.statusline_label()

  local text = path or ""
  if comment and comment ~= "" then
    -- Strip statusline markup (%#...# / %*) so strdisplaywidth measures the
    -- visible text, not the highlight directives.
    local plain = text:gsub("%%#.-#", ""):gsub("%%%*", ""):gsub("%%[<%=>]", "")
    local used = vim.fn.strdisplaywidth(plain)
    local max = math.max(4, width - used - 4)
    text = text .. "  %#PosteDbBrowserComment# " .. statusline_escape(truncate_display(comment, max)) .. "%*"
  end

  if multi_select and multi_select.active then
    local count = 0
    for _ in pairs(multi_select.selected or {}) do
      count = count + 1
    end
    if count > 0 then
      text = text .. "  %#PosteDbBrowserSelected#[" .. count .. " selected]%*"
    end
  end

  if yanked then
    text = text .. "%<" .. "%#PosteDbBrowserYanked#  " .. MARKER_YANKED
      .. " " .. statusline_escape(yanked) .. "%*"
  end

  return text
end

--- Refresh the statusline on the window that owns `browser_buf`, if any.
--- CursorMoved calls this per keystroke; when the built text is unchanged
--- (cursor moved within one node's rows) nothing is re-set and no redraw
--- is forced.
local _last_text = nil

function M.update(browser_buf, path, comment, multi_select)
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == browser_buf then
      -- Under globalstatus the browser's statusline spans the full editor
      -- width, so truncate to that; mirrors buffer/history.lua.
      local width
      if vim.api.nvim_get_option_value("laststatus", {}) >= 3 then
        width = vim.api.nvim_get_option_value("columns", {})
      else
        width = vim.api.nvim_win_get_width(win)
      end
      local text = M.build(path, comment, multi_select, width)
      if text == _last_text then
        return
      end
      _last_text = text
      pcall(vim.api.nvim_set_option_value, "statusline", text, { win = win })
    end
  end

  vim.cmd("redrawstatus")
end

return M