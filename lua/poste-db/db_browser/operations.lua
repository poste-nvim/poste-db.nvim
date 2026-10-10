--- Operations dispatched from the DB Browser context menu.
--- Each function: op(node, context) → performs the action.
local cli = require("poste-db.cli")
local icons = require("poste-db.db_browser.icons")
local forms = require("poste-db.db_browser.forms")
local ident = require("poste-db.ident")
local util = require("poste-db.db_browser.util")
local core_util = require("poste-db.util")
local compat = require("poste-db.compat")
local notify = require("poste-db.db_browser.notify")

local HEADER_LINES = icons.HEADER_LINES
local M = {}

-- Shared node/SQL-generation helpers (see ops_sql.lua).
local ops_sql = require("poste-db.db_browser.ops_sql")
local safe_str = ops_sql.safe_str
local get_dialect = ops_sql.get_dialect
local get_connection_name = ops_sql.get_connection_name
local get_search_dir = ops_sql.get_search_dir
local find_table_node = ops_sql.find_table_node
local insert_into_source = ops_sql.insert_into_source
local qualified_table_ref = ops_sql.qualified_table_ref
local build_directive_lines = ops_sql.build_directive_lines
local build_alter_column_sql = ops_sql.build_alter_column_sql
local get_columns_from_node = ops_sql.get_columns_from_node

---------------------------------------------------------------------------
-- Operations
---------------------------------------------------------------------------

--- SELECT * LIMIT 100 for table/view; insert at end of source buffer.
---
--- A view is a `table` node carrying `meta.table_type == "VIEW"` (tree.lua):
--- the browser has no `"view"` node type, so no check here can key off one.
function M.select_star(node, context)
  local table_node = node
  if table_node.node_type ~= "table" then
    -- A column or any other leaf/group row: resolve to the table the cursor
    -- actually sits under, the same way rename does.
    table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  end

  if not table_node or table_node.node_type ~= "table" then
    notify.info("Move cursor to a table or view node")
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)

  local query_lines, cursor_offset = build_directive_lines(table_node, conn)
  table.insert(query_lines,
    ops_sql.select_star_sql(qualified_table_ref(table_node, dialect), dialect))
  table.insert(query_lines, "")

  if insert_into_source(context, query_lines, cursor_offset) then
    notify.info("Generated SELECT for: " .. table_node.name)
  end
end

--- Show DDL for table/view in a float window.
function M.show_ddl(node, context)
  local table_node = node
  if table_node.node_type ~= "table" then
    -- For index/key nodes, walk up to table
    table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  end

  if not table_node or table_node.node_type ~= "table" then
    notify.info("DDL is only available for tables and views")
    return
  end

  local conn = get_connection_name(table_node, context)
  -- Node meta arrives straight from a listing row: `""` is "the connection's
  -- own database" and a JSON null decodes to vim.NIL. Both are truthy, so
  -- `if schema then` handed them to the binary — an empty `--database` is
  -- applied as replace_database_in_url and the DDL came back for whatever the
  -- stripped URL pointed at, not for this table (see util.named).
  local schema = core_util.named(table_node.meta and table_node.meta.schema)
  local database = core_util.named(table_node.meta and table_node.meta.database)

  local connections = require("poste-db.connections")
  local url, url_err = connections.resolve_connection_url(conn)
  if not url then
    vim.notify("DDL: " .. (url_err or "unknown error"), vim.log.levels.ERROR, { title = "PosteDb" })
    return
  end

  local cmd = { "introspect", "--connection-url", url, "--type", "ddl", "--table", table_node.name }
  if schema then
    table.insert(cmd, "--schema"); table.insert(cmd, schema)
  end
  if database then
    table.insert(cmd, "--database"); table.insert(cmd, database)
  end

  local log = require("poste-db.log")
  log.info("DB Browser DDL: " .. log.redact_cmd(cmd))

  local sql_log = require("poste-db.sql_log")
  local journal = sql_log.cli_fields(cmd, "browser")
  journal.connection = conn -- friendly name beats the redacted URL here
  local t0 = vim.uv.now()
  local journaled = false
  local stderr_buf = {}
  local function journal_once(status, error_msg)
    if journaled then return end
    journaled = true
    sql_log.record(vim.tbl_extend("force", journal, {
      status = status,
      elapsed_ms = vim.uv.now() - t0,
      error_msg = error_msg,
    }))
  end

  cli.run_async(cmd, {
    on_stdout = function(data)
      if not data then return end
      while #data > 0 and data[#data] == "" do data[#data] = nil end
      if #data == 0 then return end
      local output = table.concat(data, "\n")
      local ok, parsed = pcall(vim.json.decode, output)
      if not ok or type(parsed) ~= "table" then
        vim.schedule(function()
          notify.warn("DDL: failed to parse output")
        end)
        journal_once("error", "failed to parse output")
        return
      end

      local items = parsed.items
      if not items or #items == 0 then
        vim.schedule(function()
          notify.warn("DDL: no items in response")
        end)
        journal_once("error", "no items in response")
        return
      end

      journal_once("success", nil)

      vim.schedule(function()
        local ddl = items[1].ddl or ""
        if ddl == "" then
          notify.warn("DDL: empty result")
          return
        end
        local lines = vim.split(ddl, "\n")
        local title = "DDL: " .. table_node.name
        require("poste-db.introspect").show_float(lines, title, "sql")
      end)
    end,
    on_stderr = function(data)
      if not data then return end
      -- Keep what the process said: `on_exit` reports the failure, and the
      -- stderr text is the only reason a user gets without re-running the
      -- command by hand. (async.lua's introspect does the same.)
      for _, l in ipairs(data) do
        if l ~= "" then stderr_buf[#stderr_buf + 1] = l end
      end
    end,
    on_exit = function(code)
      if code ~= 0 then
        local reason = table.concat(stderr_buf, "\n")
        if reason == "" then reason = "exit " .. tostring(code) end
        vim.schedule(function()
          -- flash WARN like actions.lua's table-info fetch failure — same
          -- class of browser fetch, same non-blocking channel (the journal
          -- keeps the reason either way).
          notify.warn("DDL fetch failed: " .. reason)
        end)
        journal_once("error", reason)
      end
    end,
  })
end

--- Copy node name to system clipboard.
function M.copy_name(node)
  local name = node.name or ""
  vim.fn.setreg("+", name)
  notify.info("Copied: " .. name)
end

--- Rename table or column via vim.ui.input → generate ALTER SQL.
function M.rename(node, context)
  if node.node_type ~= "table" and node.node_type ~= "column" then
    notify.info("Rename is only available for tables and columns")
    return
  end

  local dialect = get_dialect(node, context)
  local label = node.node_type == "table" and "table" or "column"

  -- Temporarily disable dressing.nvim to avoid cmp completions
  local ok_dr, dr = pcall(require, "dressing")
  local dr_saved = ok_dr and dr.config and dr.config.input and dr.config.input.enabled
  if ok_dr and dr.config and dr.config.input then dr.config.input.enabled = false end

  vim.ui.input({
    prompt = "Rename " .. label .. " (" .. node.name .. "): ",
    default = node.name,
  }, function(input)
    if ok_dr and dr.config and dr.config.input then dr.config.input.enabled = dr_saved end
    if not input or input == "" or input == node.name then return end

    local conn = get_connection_name(node, context)
    -- The header is build_directive_lines' job — rename spelled it inline twice
    -- and drifted from every other generator: it emitted `-- @connection` /
    -- `-- @database` for a blank name too, leaving a valueless directive (which
    -- selects nothing) in front of the statement the user asked for.
    local lines, cursor_offset
    if node.node_type == "table" then
      lines, cursor_offset = build_directive_lines(node, conn)
      table.insert(lines, ops_sql.rename_table_sql(node, input, dialect))
    else
      local table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
      if not table_node then
        notify.warn("Could not find parent table")
        return
      end
      -- A column is renamed through its table's target: the column node has no
      -- database of its own.
      lines, cursor_offset = build_directive_lines(table_node, conn)
      table.insert(lines, ops_sql.rename_column_sql(table_node, node, input, dialect))
    end

    table.insert(lines, "")
    insert_into_source(context, lines, cursor_offset)
    notify.info("Generated RENAME " .. label .. " SQL")
  end)
end

--- Refresh (re-fetch children) for expandable nodes.
function M.refresh(node, context)
  if node.node_type == "column" or node.node_type == "index"
      or node.node_type == "key_item" or node.node_type == "fk_item"
      or node.node_type == "index_item" then
    notify.info("Cannot refresh leaf nodes")
    return
  end

  util.refresh_subtree(node, context, node.node_type, get_search_dir(context))
end

--- Execute SQL File: pick a .sql file and execute it against this database.
function M.exec_file(node, context)
  local conn = get_connection_name(node, context)
  local database = node.node_type == "database" and node.name
    or (node.meta and node.meta.database)

  -- Mode selection
  local modes = {
    { value = "greedy", label = "Greedy", desc = "Continue on error" },
    { value = "transaction", label = "Transaction", desc = "Rollback on any error" },
  }
  vim.ui.select(modes, {
    prompt = "Execution mode:",
    format_item = function(m) return m.label .. "  " .. m.desc end,
  }, function(choice)
    if not choice then return end

    -- File selection via beyondlex/finder
    local ok, finder = pcall(require, "finder")
    if ok then
      finder.open({
        mode = "both",
        initial_path = vim.fn.getcwd(),
        extensions = { "sql" },
        on_confirm = function(path)
          if not path then return end
          local file_exec = require("poste-db.file_exec")
          file_exec.run({
            filepath = path,
            conn = conn,
            database = database,
            mode = choice.value,
          })
        end,
        on_cancel = function() end,
      })
    else
      -- Fallback: vim.ui.input with file completion
      vim.ui.input({
        prompt = "SQL file path: ",
        default = vim.fn.getcwd() .. "/",
        completion = "file",
      }, function(path)
        if not path or path == "" then return end
        local file_exec = require("poste-db.file_exec")
        file_exec.run({
          filepath = path,
          conn = conn,
          database = database,
          mode = choice.value,
        })
      end)
    end
  end)
end

--- Insert a new query block with connection context.
function M.new_query(node, context)
  local conn = get_connection_name(node, context)
  -- Same dialect resolution as set_default: without it the USE statement
  -- falls back to double quotes even on backtick/bracket dialects.
  local dialect = get_dialect(node, context)
  local lines = { "" }
  local cursor_offset = 2  -- empty + first blank line
  if conn then
    table.insert(lines, "-- @connection " .. conn)
    cursor_offset = cursor_offset + 1
  end
  if node.node_type == "database" then
    table.insert(lines, "USE " .. ident.quote(node.name, dialect) .. ";")
    cursor_offset = cursor_offset + 1
  end
  table.insert(lines, "")
  table.insert(lines, "")

  insert_into_source(context, lines, cursor_offset)
  notify.info("New query block created")
end

--- Set default database/schema: insert USE or SET search_path.
function M.set_default(node, context)
  local dialect = get_dialect(node, context)
  local conn = get_connection_name(node, context)
  local lines = { "" }
  local cursor_offset = 2  -- empty + USE/SET line
  if conn then
    table.insert(lines, "-- @connection " .. conn)
    cursor_offset = cursor_offset + 1
  end

  if node.node_type == "database" then
    table.insert(lines, "USE " .. ident.quote(node.name, dialect) .. ";")
  elseif node.node_type == "schema" then
    if dialect == "postgres" then
      table.insert(lines, "SET search_path TO " .. ident.quote(node.name, dialect) .. ";")
    elseif dialect == "mysql" or dialect == "mariadb" then
      table.insert(lines, "USE " .. ident.quote(node.name, dialect) .. ";")
    else
      table.insert(lines, "-- schema: " .. node.name)
    end
  end
  table.insert(lines, "")

  insert_into_source(context, lines, cursor_offset)
  notify.info("Set default: " .. node.name)
end

--- Open connections.toml at this connection's entry.
function M.edit_conn(node, context)
  local conn_name = node.node_type == "connection" and node.name
    or (node.meta and node.meta.connection)
  if not conn_name then
    notify.warn("No connection name found")
    return
  end

  local connections = require("poste-db.connections")
  local config_path = connections.find_connections_toml(get_search_dir(context))
  if not config_path then
    notify.warn("connections.toml not found")
    return
  end

  local target_win = vim.fn.bufwinid(context.source_buf)
  if target_win and target_win ~= -1 then
    vim.api.nvim_set_current_win(target_win)
  end
  vim.cmd("edit " .. vim.fn.fnameescape(config_path))

  -- Jump to the connection entry (TOML [section] header)
  local search_target = '[' .. conn_name .. ']'
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local found_line = nil
  for i, line in ipairs(lines) do
    if line:find(search_target, 1, true) then
      found_line = i
      break
    end
  end
  if found_line then
    vim.api.nvim_win_set_cursor(0, { found_line, 0 })
  else
    notify.warn("Connection '" .. conn_name .. "' not found in file")
  end
end

--- Modify Column: open form with type/nullable/default, generate ALTER SQL.
function M.modify_col(node, context)
  if node.node_type ~= "column" then
    notify.info("Modify is only available for columns")
    return
  end

  local table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  if not table_node then
    notify.warn("Could not find parent table")
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)
  local types = require("poste-db.db_browser.completion").get_types(dialect)

  local fields = {
    { label = "Type",     key = "col_type", value = node.meta and node.meta.col_type or "", kind = "select", choices = types },
    { label = "Nullable", key = "nullable", value = not not (node.meta and node.meta.nullable), kind = "bool" },
    { label = "Default",  key = "default",  value = safe_str(node.meta and node.meta.default), kind = "text" },
    { label = "Comment",  key = "comment",  value = safe_str(node.meta and node.meta.comment), kind = "text" },
  }

  compat.set("dialect", dialect)

  forms.open("Modify Column: " .. table_node.name .. "." .. node.name, fields, function(updated)
    local lines, cursor_offset = build_directive_lines(table_node, conn)
    vim.list_extend(lines, build_alter_column_sql(table_node, node, {
      col_type = updated[1].value,
      nullable = updated[2].value,
      default_val = updated[3].value,
      comment_val = updated[4].value,
    }, dialect))
    table.insert(lines, "")
    insert_into_source(context, lines, cursor_offset)
    notify.info("Generated ALTER SQL for column: " .. node.name)
  end)
end

--- CREATE TABLE target for the "New Table" form. `Name` is typed, so it may
--- already carry the qualifier (`analytics.events`) — quote_ref splits it, and
--- when it does the node's own schema must not be prepended again, which used
--- to emit `"analytics"."analytics"."events"`, naming no table at all.
local function new_table_ref(table_name, schema, dialect)
  local qualified = ident.quote_ref(table_name, dialect)
  if schema and dialect == "postgres" and not ident.is_qualified(table_name) then
    qualified = ident.quote(schema, dialect) .. "." .. qualified
  end
  return qualified
end

--- New Table: open form with table name, generate CREATE TABLE template.
function M.new_table(node, context)
  local dialect = get_dialect(node, context)
  local conn = get_connection_name(node, context)
  local schema = node.node_type == "schema" and node.name or nil
  local database = node.node_type == "database" and node.name or (node.meta and node.meta.database)

  local fields = {
    { label = "Name", key = "table_name", value = "", kind = "text" },
  }

  local title = "New Table"
  if node.node_type == "database" then title = "New Table: " .. node.name end
  if node.node_type == "schema" then title = "New Table: " .. (schema or "") end

  forms.open(title, fields, function(updated)
    local table_name = updated[1].value
    if table_name == "" then
      notify.warn("Table name cannot be empty")
      return
    end

    local lines = { "" }
    local cursor_offset = 2
    if conn then
      table.insert(lines, "-- @connection " .. conn)
      cursor_offset = cursor_offset + 1
    end
    if database then
      table.insert(lines, "-- @database " .. database)
      cursor_offset = cursor_offset + 1
    end

    local qualified = new_table_ref(table_name, schema, dialect)

    table.insert(lines, "CREATE TABLE " .. qualified .. " (")
    table.insert(lines, "  id SERIAL PRIMARY KEY,")
    table.insert(lines, "  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP")
    table.insert(lines, ");")
    table.insert(lines, "")

    insert_into_source(context, lines, cursor_offset)
    notify.info("Generated CREATE TABLE: " .. table_name)
  end)
end

--- Create Table Template: insert CREATE TABLE snippet with tab stops.
function M.create_table_template(node, context)
  local conn = get_connection_name(node, context)

  if not context.source_buf or not vim.api.nvim_buf_is_valid(context.source_buf) then
    notify.warn("No source SQL buffer found")
    return
  end

  local target_win = vim.fn.bufwinid(context.source_buf)
  if target_win and target_win ~= -1 then
    vim.api.nvim_set_current_win(target_win)
  end

  local line_count = vim.api.nvim_buf_line_count(context.source_buf)
  local insert_line = { "" }
  if conn then
    insert_line = { "", "-- @connection " .. conn, "" }
  end
  vim.api.nvim_buf_set_lines(context.source_buf, line_count, line_count, false, insert_line)
  line_count = vim.api.nvim_buf_line_count(context.source_buf)
  vim.api.nvim_win_set_cursor(0, { line_count, 0 })

  local snippet = [[
create table ${1:table_name} (
  ${2:column_name} ${3:INTEGER} ${4:NOT NULL}
);
]]

  local ok, _ = pcall(vim.snippet.expand, snippet)
  if not ok then
    vim.api.nvim_buf_set_lines(context.source_buf, line_count - 1, line_count, false, {
      "create table ",
      "  ",
      ");",
    })
    vim.api.nvim_win_set_cursor(0, { line_count - 1, 13 })
  end

  notify.info("Generated CREATE TABLE template")
end

--- New Column: open form with name/type/nullable/default, generate ALTER TABLE ADD COLUMN.
function M.new_column(node, context)
  local table_node = node
  if node.node_type ~= "table" then
    table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  end
  if not table_node or table_node.node_type ~= "table" then
    notify.info("Move cursor to a table node")
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)
  local types = require("poste-db.db_browser.completion").get_types(dialect)

  local fields = {
    { label = "Name",     key = "col_name",  value = "",     kind = "text" },
    { label = "Type",     key = "col_type",  value = "TEXT", kind = "select", choices = types },
    { label = "Nullable", key = "nullable",  value = true,   kind = "bool" },
    { label = "Default",  key = "default",   value = "",     kind = "text" },
  }

  compat.set("dialect", dialect)

  forms.open("New Column: " .. table_node.name, fields, function(updated)
    local col_name = updated[1].value
    local col_type = updated[2].value
    local nullable = updated[3].value
    local default_val = updated[4].value

    if col_name == "" then
      notify.warn("Column name cannot be empty")
      return
    end

    local lines = { "" }
    local cursor_offset = 2
    if conn then
      table.insert(lines, "-- @connection " .. conn)
      cursor_offset = cursor_offset + 1
    end
    if table_node.meta and table_node.meta.database then
      table.insert(lines, "-- @database " .. table_node.meta.database)
      cursor_offset = cursor_offset + 1
    end

    -- Schema-qualified where the dialect resolves it: a bare name here made
    -- the ALTER land on public.<table> for anything browsed in another schema.
    local stmt = ops_sql.add_column_sql(
      qualified_table_ref(table_node, dialect), ident.quote(col_name, dialect),
      col_type, nullable, default_val, dialect)
    for _, line in ipairs(stmt) do
      table.insert(lines, line)
    end
    table.insert(lines, "")

    insert_into_source(context, lines, cursor_offset)
    notify.info("Generated ADD COLUMN: " .. col_name)
  end)
end

--- INSERT template: generate INSERT INTO ... VALUES based on table columns.
function M.insert_template(node, context)
  local table_node = node
  if node.node_type ~= "table" then
    table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  end
  if not table_node or table_node.node_type ~= "table" then
    notify.info("Move cursor to a table node")
    return
  end

  local cols = get_columns_from_node(table_node)
  if not cols then
    notify.warn("Expand the table first to see columns")
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)

  local col_names = {}
  for _, c in ipairs(cols) do
    if not c.is_pk then
      table.insert(col_names, ident.quote(c.name, dialect))
    end
  end
  -- A junction table has no non-key column to offer: skipping every primary
  -- key left `INSERT INTO "t" ()`, which no engine parses. Fall back to the
  -- key itself, the same way update_template does for its SET list.
  if #col_names == 0 then
    for _, c in ipairs(cols) do
      table.insert(col_names, ident.quote(c.name, dialect))
    end
  end

  local lines, cursor_offset = build_directive_lines(table_node, conn)
  table.insert(lines, "INSERT INTO " .. qualified_table_ref(table_node, dialect) .. " (" .. table.concat(col_names, ", ") .. ")")
  table.insert(lines, "VALUES ()")
  table.insert(lines, "")
  cursor_offset = cursor_offset + 1  -- land on VALUES line

  insert_into_source(context, lines, cursor_offset, 8)  -- col 8 = inside VALUES ()
  notify.info("Generated INSERT template for: " .. table_node.name)
end

--- UPDATE template: generate UPDATE ... SET ... WHERE based on table columns.
function M.update_template(node, context)
  local table_node = node
  if node.node_type ~= "table" then
    table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  end
  if not table_node or table_node.node_type ~= "table" then
    notify.info("Move cursor to a table node")
    return
  end

  local cols = get_columns_from_node(table_node)
  if not cols then
    notify.warn("Expand the table first to see columns")
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)

  local pk_cols = {}
  local set_lines = {}
  for _, c in ipairs(cols) do
    if c.is_pk then
      table.insert(pk_cols, ident.quote(c.name, dialect))
    else
      table.insert(set_lines, "  " .. ident.quote(c.name, dialect) .. " = 'val'")
    end
  end
  -- A table whose every column is part of the key has nothing to SET but the
  -- key itself. Emit that rather than a `SET` line with no assignments: the
  -- comma was stripped from whatever the last line happened to be, which
  -- truncated the bare `SET` keyword to `SE`.
  if #set_lines == 0 then
    for _, pk in ipairs(pk_cols) do
      table.insert(set_lines, "  " .. pk .. " = ?")
    end
  end

  local lines, cursor_offset = build_directive_lines(table_node, conn)
  table.insert(lines, "UPDATE " .. qualified_table_ref(table_node, dialect))
  table.insert(lines, "SET")
  for i, sc in ipairs(set_lines) do
    table.insert(lines, i < #set_lines and (sc .. ",") or sc)
  end
  if #pk_cols > 0 then
    table.insert(lines, "WHERE " .. table.concat(pk_cols, " = ? AND ") .. " = ?;")
  else
    table.insert(lines, "WHERE ?;")
  end
  table.insert(lines, "")

  insert_into_source(context, lines, cursor_offset)
  notify.info("Generated UPDATE template for: " .. table_node.name)
end

--- Import data from CSV/TSV/JSON into this table.
function M.import_data(node, context)
  if node.meta and node.meta.table_type == "VIEW" then
    notify.warn("Cannot import data into a view")
    return
  end
  if node.node_type ~= "table" then
    notify.info("Import is only available for tables")
    return
  end
  require("poste-db.import").run(node, context)
end

-- Drop flows live in ops_drop.lua. context_menu dispatches actions by
-- name through this module's table, so both entries must stay on M here.
local ops_drop = require("poste-db.db_browser.ops_drop")
M.drop_table = ops_drop.drop_table
M.batch_drop_tables = ops_drop.batch_drop_tables

function M.create_database(node, context)
  require("poste-db.db_browser.db_create").open(node, context)
end

function M.create_schema(node, context)
  require("poste-db.db_browser.schema_create").open(node, context)
end

M._test = {
  safe_str = safe_str,
  get_columns_from_node = get_columns_from_node,
  qualified_table_ref = qualified_table_ref,
  build_directive_lines = build_directive_lines,
  build_alter_column_sql = build_alter_column_sql,
  new_table_ref = new_table_ref,
}

return M
