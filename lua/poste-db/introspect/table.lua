--- Introspection --- table-level detail fetching and display.
local const = require("poste-db.constants")
local connections = require("poste-db.connections")
local exec = require("poste-db.introspect.exec")
local ui = require("poste-db.introspect.ui")

local M = {}

local function resolve_url(conn)
  local url, url_err = connections.resolve_connection_url(conn)
  if not url then
    return nil, url_err or "unknown error"
  end
  return url, nil
end

function M.show_database_tables(conn, db_name, show_float)
  local url, url_err = resolve_url(conn)
  if not url then
    vim.notify("Table listing: " .. url_err, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local args = { "introspect", "--connection-url", url, "--type", "tables", "--database", db_name }
  exec.run_json_items_job(args, {
    title = const.PLUGIN_TITLE,
    failure_message = "Failed to list tables",
    empty_message = "No tables found in database '" .. db_name .. "'",
    stderr_prefix = "introspect stderr: ",
    exit_kind = "Table listing",
    on_items = function(items)
      ui.show_table_list(items, db_name, show_float)
    end,
  })
end

function M.show_database_info(conn, db_name, show_float)
  local url, url_err = resolve_url(conn)
  if not url then
    vim.notify("Database info: " .. url_err, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local args = { "introspect", "--connection-url", url, "--type", "database_info" }
  if db_name and db_name ~= "" then
    table.insert(args, "--database")
    table.insert(args, db_name)
  end
  exec.run_json_items_job(args, {
    title = const.PLUGIN_TITLE,
    failure_message = "Failed to get database info",
    empty_message = "No database info returned",
    stderr_prefix = "introspect stderr: ",
    exit_kind = "Database info",
    on_items = function(items)
      ui.show_database_info(items, db_name or "", show_float)
    end,
  })
end

function M.show_table_ddl(conn, db, cword, show_float, schema)
  local url, url_err = resolve_url(conn)
  if not url then
    vim.notify("DDL: " .. url_err, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local args = { "introspect", "--connection-url", url, "--type", "ddl", "--table", cword }

  -- Schema placement, mirroring column.lua: on MySQL/MariaDB a schema IS a
  -- database, so it goes on --database exactly as before. Everywhere else it
  -- goes on --schema, and --database keeps the real context database — the
  -- old `--database <schema>` repointed the connection at a database named
  -- like the schema (postgres: "database app does not exist").
  if schema and schema ~= vim.NIL and schema ~= "" then
    local cc = connections.get_connection_config(conn)
    local dialect = cc and cc.dialect or ""
    if dialect == "mysql" or dialect == "mariadb" then
      db = schema
    else
      table.insert(args, "--schema")
      table.insert(args, schema)
    end
  end
  if db and db ~= vim.NIL and db ~= "" then
    table.insert(args, "--database")
    table.insert(args, db)
  end

  exec.run_json_items_job(args, {
    title = const.PLUGIN_TITLE,
    failure_message = "Failed to parse DDL response",
    empty_message = "No DDL found for table '" .. cword .. "'",
    stderr_prefix = "DDL stderr: ",
    exit_kind = "DDL introspection",
    on_items = function(items)
      ui.show_ddl(items, cword, show_float)
    end,
  })
end

return M
