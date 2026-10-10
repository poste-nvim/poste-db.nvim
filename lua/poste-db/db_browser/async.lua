local state = require("poste-db.state")

local tree = require("poste-db.db_browser.tree")
local async = require("poste-db.async")
local log = require("poste-db.log")
local sql_log = require("poste-db.sql_log")
local const = require("poste-db.constants")
local util = require("poste-db.util")

local M = {}

--- Render hook fired after a prefetch completes, so counts become visible
--- without the user expanding the node. Set by db_browser.init.
--- @type function|nil
M.render_hook = nil

--- Node types whose children are prefetched one level after the node itself
--- is fetched. Connection → databases, database → schemas/tables,
--- schema → tables, table → columns.
local PREFETCH_TYPES = {
  connection = true,
  database = true,
  schema = true,
  table = true,
}

local prefetch_timer = nil

local function schedule_render()
  if prefetch_timer then
    pcall(prefetch_timer.stop, prefetch_timer)
    pcall(prefetch_timer.close, prefetch_timer)
  end
  prefetch_timer = vim.defer_fn(function()
    prefetch_timer = nil
    if M.render_hook then M.render_hook() end
  end, 50)
end

function M.run_introspect(conn_name, introspect_type, schema, table_name, database, callback, search_dir)
  -- These three arrive straight from a tree node, i.e. from a listing row:
  -- `""` is what a server reports for "the connection's own database" and a
  -- JSON null decodes to vim.NIL — both truthy, so `if schema then` took them
  -- for names. A null then concatenated into a raise in the journal line or
  -- the log below, and an empty `--database` is applied by the CLI as
  -- replace_database_in_url, so the fetch read a DIFFERENT database than the
  -- node the user clicked (its tables, DDL and columns all came back for
  -- whatever the stripped URL pointed at).
  schema = util.named(schema)
  table_name = util.named(table_name)
  database = util.named(database)

  local connections = require("poste-db.connections")
  local url, err = connections.resolve_connection_url(conn_name)
  if not url then
    vim.schedule(function()
      vim.notify("Introspect failed: " .. (err or "unknown error"), vim.log.levels.ERROR, { title = "PosteDb" })
      callback(nil)
    end)
    sql_log.record({
      source = "browser",
      sql = "introspect " .. tostring(introspect_type),
      connection = conn_name,
      database = database,
      status = "error",
      elapsed_ms = 0,
      error_msg = err or "connection not found",
    })
    return
  end

  local cmd = { "introspect", "--connection-url", url, "--type", introspect_type }

  if schema then
    table.insert(cmd, "--schema"); table.insert(cmd, schema)
  end
  if table_name then
    table.insert(cmd, "--table"); table.insert(cmd, table_name)
  end
  if database then
    table.insert(cmd, "--database"); table.insert(cmd, database)
  end

  log.info("DB Browser introspect: " .. log.redact_cmd(cmd))

  local stderr_buf = {}
  local parsed_result = nil
  local t0 = vim.uv.now()
  local journal_sql = "introspect " .. tostring(introspect_type)
    .. (schema and (" schema=" .. schema) or "")
    .. (table_name and (" table=" .. table_name) or "")
    .. (database and (" db=" .. database) or "")

  local function journal(ok_status, error_msg)
    sql_log.record({
      source = "browser",
      sql = journal_sql,
      connection = conn_name,
      database = database,
      status = ok_status,
      elapsed_ms = vim.uv.now() - t0,
      error_msg = error_msg,
    })
  end

  return async.run(cmd, {
    timeout = 15000,
    on_data = function(data)
      if not data then return end
      while #data > 0 and data[#data] == "" do data[#data] = nil end
      if #data == 0 then return end

      local output = table.concat(data, "\n")
      local ok, parsed = pcall(vim.json.decode, output)
      if ok and type(parsed) == "table" then
        parsed_result = parsed
      else
        state.log("WARN", "Introspect JSON parse failed: " .. output:sub(1, 200))
      end
    end,
    on_stderr = function(data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(stderr_buf, l) end
      end
    end,
    on_exit = function(code)
      if code ~= 0 then
        vim.schedule(function()
          local err_text = table.concat(stderr_buf, "\n")
          vim.notify("Introspect failed: " .. (err_text ~= "" and err_text or "exit " .. code), vim.log.levels.ERROR, { title = "PosteDb" })
        end)
        parsed_result = nil
      end
      local err_text = table.concat(stderr_buf, "\n")
      journal(parsed_result and "success" or "error",
        parsed_result and nil
        or (err_text ~= "" and err_text)
        or (code ~= 0 and ("exit code " .. tostring(code)) or "no valid response"))
      vim.schedule(function()
        callback(parsed_result)
      end)
    end,
    on_error = function(msg)
      journal("error", msg)
      vim.schedule(function()
        vim.notify("Introspect error: " .. msg, vim.log.levels.ERROR, { title = "PosteDb" })
        callback(nil)
      end)
    end,
  })
end

function M.fetch_children(node, callback, search_dir, opts)
  opts = opts or {}
  node.epoch = (node.epoch or 0) + 1
  local epoch = node.epoch
  if not opts.quiet then
    node.loading = true
  end

  local user_callback = callback
  callback = function()
    user_callback()
    if not opts.quiet then
      -- One-level prefetch: after this node's children are loaded, fetch the
      -- children of each child quietly so counts (tables per db, columns per
      -- table) become visible without further expands.
      M.prefetch_children(node, search_dir)
    end
  end

  local conn = node.node_type == "connection" and node.name
    or (node.meta and node.meta.connection) or state.db_browser.connection

  local dialect = "postgres"
  if node.meta and node.meta.dialect then
    dialect = node.meta.dialect
  end

  local function guard()
    if node.epoch ~= epoch then return true end
    return false
  end

  if node.node_type == "connection" then
    if dialect == "sqlite" then
      M.run_introspect(conn, "tables", nil, nil, nil, function(result)
        if guard() then return end
        node.loading = false
        node.children = {}
        if result and result.items then
          for _, item in ipairs(result.items) do
            local child = tree.make_table_node(item, nil, nil, conn)
            child.parent = node
            table.insert(node.children, child)
          end
        end
        callback()
      end, search_dir)
    else
      M.run_introspect(conn, "databases", nil, nil, nil, function(result)
        if guard() then return end
        node.loading = false
        node.children = {}
        if result and result.items then
          for _, item in ipairs(result.items) do
            -- Skip system databases
            local skip = {
              information_schema = true, mysql = true,
              performance_schema = true, sys = true,
              template0 = true, template1 = true,
            }
            if not skip[item.name] then
              local child = tree.make_database_node(item, conn, dialect)
              child.parent = node
              table.insert(node.children, child)
            end
          end
        end
        callback()
      end, search_dir)
    end

  elseif node.node_type == "database" then
    if dialect == "postgres" then
      M.run_introspect(conn, "schemas", nil, nil, node.name, function(result)
        if guard() then return end
        node.loading = false
        node.children = {}
        if result and result.items then
          for _, item in ipairs(result.items) do
            if item.name ~= "pg_catalog"
              and item.name ~= "information_schema"
              and item.name:sub(1, 8) ~= "pg_toast" then
              local child = tree.make_schema_node(item, conn, node.name)
              child.parent = node
              table.insert(node.children, child)
            end
          end
        end
        callback()
      end, search_dir)
    else
      M.run_introspect(conn, "tables", nil, nil, node.name, function(result)
        if guard() then return end
        node.loading = false
        node.children = {}
        if result and result.items then
          for _, item in ipairs(result.items) do
            local child = tree.make_table_node(item, nil, node.name, conn)
            child.parent = node
            table.insert(node.children, child)
          end
        end
        callback()
      end, search_dir)
    end

  elseif node.node_type == "schema" then
    local db_name = node.meta and node.meta.database
    M.run_introspect(conn, "tables", node.name, nil, db_name, function(result)
      if guard() then return end
      node.loading = false
      node.children = {}
      if result and result.items then
        for _, item in ipairs(result.items) do
          local child = tree.make_table_node(item, node.name, db_name, conn)
          child.parent = node
          table.insert(node.children, child)
        end
      end
      callback()
    end, search_dir)

  elseif node.node_type == "table" then
    local schema_name = node.meta and node.meta.schema
    local db_name = node.meta and node.meta.database
    local table_name = node.name
    local columns_done, indexes_done = false, false
    local columns_result, indexes_result = nil, nil

    local function check_done()
      if guard() then return end
      if columns_done and indexes_done then
        node.loading = false
        local cols = columns_result and columns_result.items or {}
        local idxs = indexes_result and indexes_result.items or {}
        local pk_cols, fk_cols, regular_cols = {}, {}, {}
        for _, item in ipairs(cols) do
          local pk = item.pk or item.key == "PRI"
          local fk = item.is_fk or item.key == "MUL"
          if pk then table.insert(pk_cols, item)
          elseif fk then table.insert(fk_cols, item)
          else table.insert(regular_cols, item) end
        end
        node.children = {}
        for _, item in ipairs(pk_cols) do
          local child = tree.make_column_node(item)
          child.parent = node
          table.insert(node.children, child)
        end
        for _, item in ipairs(regular_cols) do
          local child = tree.make_column_node(item)
          child.parent = node
          table.insert(node.children, child)
        end
        for _, item in ipairs(fk_cols) do
          local child = tree.make_column_node(item)
          child.parent = node
          table.insert(node.children, child)
        end

        local key_items = {}
        for _, item in ipairs(pk_cols) do
          table.insert(key_items, { type = "pk", name = item.name })
        end
        for _, item in ipairs(idxs) do
          if item.unique and item.name ~= "PRIMARY" then
            local cols_str = item.columns and #item.columns > 0 and (" (" .. table.concat(item.columns, ", ") .. ")") or ""
            table.insert(key_items, { type = "unique", name = item.name .. cols_str })
          end
        end
        if #key_items > 0 then
          local keys_node = {
            node_type = "key_group",
            name = "keys",
            children = {},
            expanded = false, loading = false,
          }
          for _, ki in ipairs(key_items) do
            local child = {
              node_type = "key_item",
              name = ki.name,
              full_name = ki.name,
              children = {},
              expanded = false, loading = false,
              meta = { is_pk = ki.type == "pk" },
            }
            child.parent = keys_node
            table.insert(keys_node.children, child)
          end
          keys_node.parent = node
          table.insert(node.children, keys_node)
        end

        local fk_items = {}
        local function s(v) -- normalize null/nil to empty string
          if v == nil or v == vim.NIL then return "" end
          return tostring(v)
        end
        for _, item in ipairs(cols) do
          local ref_table = s(item.fk_table)
          local ref_column = s(item.fk_column)
          if ref_table ~= "" then
            table.insert(fk_items, {
              name = item.name,
              ref_table = ref_table,
              ref_column = ref_column,
            })
          elseif item.is_fk or item.key == "MUL" then
            table.insert(fk_items, {
              name = item.name,
              ref_table = "",
              ref_column = "",
            })
          end
        end
        if #fk_items > 0 then
          local fk_node = {
            node_type = "fk_group",
            name = "foreign keys",
            children = {},
            expanded = false, loading = false,
          }
          for _, fi in ipairs(fk_items) do
            local label = fi.name
            if fi.ref_table and fi.ref_table ~= "" then
              label = label .. " -> " .. fi.ref_table .. "(" .. fi.ref_column .. ")"
            end
            local child = {
              node_type = "fk_item",
              name = label,
              full_name = label,
              children = {},
              expanded = false, loading = false,
            }
            child.parent = fk_node
            table.insert(fk_node.children, child)
          end
          fk_node.parent = node
          table.insert(node.children, fk_node)
        end

        local idx_items = {}
        for _, item in ipairs(idxs) do
          local cols_str = item.columns and #item.columns > 0 and (" (" .. table.concat(item.columns, ", ") .. ")") or ""
          local unique_str = item.unique and " UNIQUE" or ""
          local label = item.name .. cols_str .. unique_str
          table.insert(idx_items, { name = label, is_pk = item.name == "PRIMARY" })
        end
        if #idx_items > 0 then
          local idx_node = {
            node_type = "index_group",
            name = "indexes",
            children = {},
            expanded = false, loading = false,
          }
          for _, ii in ipairs(idx_items) do
            local child = {
              node_type = "index_item",
              name = ii.name,
              full_name = ii.name,
              children = {},
              expanded = false, loading = false,
              meta = { is_pk = ii.is_pk },
            }
            child.parent = idx_node
            table.insert(idx_node.children, child)
          end
          idx_node.parent = node
          table.insert(node.children, idx_node)
        end
        callback()
      end
    end

    M.run_introspect(conn, "columns", schema_name, table_name, db_name, function(result)
      if guard() then return end
      columns_result = result
      columns_done = true
      check_done()
    end, search_dir)

    M.run_introspect(conn, "indexes", schema_name, table_name, db_name, function(result)
      if guard() then return end
      indexes_result = result
      indexes_done = true
      check_done()
    end, search_dir)
  else
    node.loading = false
    callback()
  end
end

--- Prefetch the children of each child of `node` (one level), quietly.
--- Called automatically after a node's own children finish loading, so the
--- child counts (tables per db, columns per table) are populated without the
--- user expanding each node. Rendering is deferred via `schedule_render`.
--- @param node table
--- @param search_dir string
function M.prefetch_children(node, search_dir)
  if not node.children then return end
  for _, child in ipairs(node.children) do
    if PREFETCH_TYPES[child.node_type] and not child.children and not child.loading then
      M.fetch_children(child, function()
        schedule_render()
      end, search_dir, { quiet = true })
    end
  end
end

function M.load_connections(callback, search_dir)
  state.log("INFO", "DB Browser load_connections: search_dir=" .. search_dir)

  local config_path = util.find_file_upwards("connections.toml", search_dir)

  vim.schedule(function()
    local nodes = {}
    if config_path then
      local toml = require("poste-db.toml")
      local parsed, err = toml.parse_file(config_path)
      if parsed then
        -- Sort names before building nodes: pairs() order flips as the toml is
        -- edited, which made the browser's top level reshuffle between opens
        -- (the same churn the picker's list_connections already fixes).
        local names = {}
        for name in pairs(parsed) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
          local conn = parsed[name]
          -- Skip dialects poste-db does not support (satellite sections from a
          -- shared connections.toml, e.g. redis)
          if not const.is_sql_dialect(conn.dialect) then goto continue end
          local entry = { name = name, dialect = conn.dialect or "postgres" }
          if conn.host then entry.host = conn.host end
          if conn.port then entry.port = conn.port end
          if conn.database then entry.database = conn.database end
          if conn.path then entry.path = conn.path end
          table.insert(nodes, tree.make_connection_node(entry))
          ::continue::
        end
      else
        state.log("WARN", "DB Browser: TOML parse failed: " .. (err or "unknown"))
      end
    else
      state.log("WARN", "DB Browser: connections.toml not found")
    end
    state.log("INFO", "DB Browser: loaded " .. #nodes .. " connections")
    callback(nodes)
  end)
end

return M