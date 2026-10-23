--- Go-to-definition --- handlers for connection/database/table navigation.
--- Requires stay LAZY on purpose: sql_nav_spec stubs poste-db.context /
--- poste-db.db_browser through package.loaded, and a top-level require
--- would capture the real module before the stub lands.
local detect = require("poste-db.nav.detect")
local util = require("poste-db.util")
local const = require("poste-db.constants")

local M = {}

function M.build_connection_search_dir(buf)
  local search_dir = vim.api.nvim_buf_get_name(buf)
  if search_dir ~= "" then
    return vim.fn.fnamemodify(search_dir, ":h")
  end
  return vim.fn.getcwd()
end

function M.find_connection_target_line(config_lines, conn_name)
  -- The TOML parser accepts whitespace-padded quoted headers ([ 'my db' ]),
  -- so a byte-exact ^[name] pattern would report a connection the file
  -- really has as missing. Trim, then drop one MATCHING quote pair.
  for i, line in ipairs(config_lines or {}) do
    local header = line:match("^%s*%[(.-)%]%s*$")
    if header then
      header = vim.trim(header)
      local q = header:sub(1, 1)
      if (q == "'" or q == '"') and #header >= 2 and header:sub(-1) == q then
        header = header:sub(2, -2)
      end
      if header == conn_name then
        return i
      end
    end
  end
  return nil
end

function M.handle_connection_directive(buf, conn_name)
  local connections = require("poste-db.connections")
  local search_dir = M.build_connection_search_dir(buf)
  local config_path = connections.find_connections_toml(search_dir)
  if not config_path then
    vim.notify("connections.toml not found", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return true
  end
  local config_lines = vim.fn.readfile(config_path)
  if not config_lines then
    vim.notify("Cannot read connections.toml", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return true
  end
  local target_line = M.find_connection_target_line(config_lines, conn_name)
  if not target_line then
    vim.notify("Connection '" .. conn_name .. "' not found in connections.toml", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return true
  end
  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(config_path))
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  return true
end

function M.handle_database_directive(buf, line_num, db_name)
  local full_ctx = require("poste-db.context").resolve_full_context(buf, line_num)
  if not full_ctx.connection then
    vim.notify("No connection context for database '" .. db_name .. "'. Add -- @connection <name> to the file.", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return true
  end
  vim.cmd("normal! m'")
  require("poste-db.db_browser").navigate_to(full_ctx.connection, db_name)
  return true
end

function M.handle_table_reference(buf, line_num, line_text, cursor, full_ctx, table_name)
  local data = require("poste-db.completion.data")
  local bin = data.find_binary()
  local column_name = nil

  if bin then
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local nav_line_text = all_lines[line_num] or ""

    local end_col = util.scan_word_end(nav_line_text, cursor[2])

    local block = detect.extract_sql_block(all_lines, line_num, nav_line_text, end_col)
    if block then
      local conn_config = require("poste-db.connections").get_connection_config(full_ctx.connection)
      local cmd = require("poste-db.context").detect_command(bin, block.offset, conn_config and conn_config.dialect or nil)
      -- :wait() blocks the editor; completion runs the same subcommand per
      -- keystroke at 2000ms — don't let a wedged binary freeze
      -- go-to-definition for longer.
      local ok_sys, result_obj = pcall(vim.system, cmd, { stdin = block.sql_text, timeout = 2000 })
      if ok_sys then
        local result = result_obj:wait()
        if result.code == 0 and result.stdout then
          local ok, parsed = pcall(vim.json.decode, result.stdout)
          if ok and parsed then
            util.clean_nil(parsed)
            local target = detect.resolve_detected_table_target(parsed, line_text, end_col, table_name, full_ctx)
            if target then
              if target.action == "navigate_to" then
                vim.cmd("normal! m'")
                require("poste-db.db_browser").navigate_to(
                  target.connection or full_ctx.connection,
                  target.database or full_ctx.database or table_name
                )
                return true
              end
              table_name = target.table_name or table_name
              column_name = target.column_name
              if target.database then
                full_ctx.database = target.database
              end
            end
          end
        end
      end
    end
  end

  vim.cmd("normal! m'")
  require("poste-db.db_browser").navigate_to_table(full_ctx.connection, full_ctx.database, table_name, column_name)
  return true
end

return M
