--- Introspection --- float window UI for DDL/info display.
local const = require("poste-db.constants")
local helpers = require("poste-db.introspect.helpers")

local M = {}

local function notify(msg, level)
  vim.notify(msg, level, { title = const.PLUGIN_TITLE })
end

function M.show_connection(config, conn_name, show_float)
  show_float(helpers.build_connection_lines(config), "Connection: " .. conn_name)
end

function M.show_table_list(items, db_name, show_float)
  show_float(helpers.build_table_lines(items), "Tables: " .. db_name)
end

function M.show_database_info(items, db_name, show_float)
  local item = items and items[1]
  if not item then
    notify("No database info found", vim.log.levels.WARN)
    return
  end
  show_float(helpers.build_database_info_lines(item), "Database: " .. db_name)
end

function M.show_column_info(items, table_name, col_name, show_float)
  local col = nil
  -- exact spelling first, then case-insensitive: postgres folds unquoted
  -- identifiers to lowercase (stored `name`, typed `Name`), MySQL columns
  -- match in any case — both answered "Column 'Name' not found".
  for _, item in ipairs(items or {}) do
    if item.name == col_name then
      col = item
      break
    end
  end
  if not col and type(col_name) == "string" then
    local lower = col_name:lower()
    for _, item in ipairs(items or {}) do
      if type(item.name) == "string" and item.name:lower() == lower then
        col = item
        break
      end
    end
  end
  if not col then
    notify("Column '" .. col_name .. "' not found in table '" .. table_name .. "'", vim.log.levels.WARN)
    return false
  end
  show_float(helpers.build_column_info_lines(table_name, col), "Column: " .. col_name, "sql")
  return true
end

function M.show_ddl(items, cword, show_float)
  local ddl_text = items and items[1] and items[1].ddl or ""
  if not ddl_text or ddl_text == "" then
    notify("No DDL found for table '" .. cword .. "'", vim.log.levels.WARN)
    return false
  end

  local lines = vim.split(ddl_text, "\n", { plain = true })
  show_float(lines, "DDL: " .. cword, "sql")
  return true
end

return M
