--- Column metadata introspection and primary key detection.
--- Handles building and running SQL queries for PK/enum metadata.

local const = require("poste-db.constants")
local M = {}

local state = nil
local function get_state()
  if not state then state = require("poste-db.state") end
  return state
end

---------------------------------------------------------------------------
-- Metadata query templates
---------------------------------------------------------------------------

local METADATA_QUERIES = {
  primary_keys = {
    postgres = [[
      SELECT c.column_name, c.column_default,
        CASE WHEN pk.attname IS NOT NULL THEN 1 ELSE 0 END AS IS_PK
      FROM information_schema.columns c
      LEFT JOIN (
        SELECT a.attname FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        JOIN pg_class cl ON cl.oid = i.indrelid
        WHERE i.indisprimary AND cl.relname = '%s'
      ) pk ON pk.attname = c.column_name
      WHERE c.table_name = '%s' AND c.table_schema = '%s'
    ]],
    mysql = [[
      SELECT c.COLUMN_NAME, c.COLUMN_DEFAULT, c.EXTRA,
        CASE WHEN k.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS IS_PK
      FROM INFORMATION_SCHEMA.COLUMNS c
      LEFT JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE k
        ON k.TABLE_NAME = c.TABLE_NAME AND k.COLUMN_NAME = c.COLUMN_NAME
        AND k.CONSTRAINT_NAME = 'PRIMARY' AND k.TABLE_SCHEMA = c.TABLE_SCHEMA
      WHERE c.TABLE_NAME = '%s'
    ]],
    sqlite = [[
      SELECT name AS column_name, dflt_value AS column_default, pk AS IS_PK
      FROM pragma_table_info('%s')
    ]],
  },
  enums = {
    postgres = [[
      SELECT t.typname AS type_name, e.enumlabel AS enum_value
      FROM pg_type t
      JOIN pg_enum e ON t.oid = e.enumtypid
      ORDER BY t.typname, e.enumsortorder
    ]],
    mysql = [[
      SELECT COLUMN_NAME, COLUMN_TYPE FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_NAME = '%s' AND DATA_TYPE = 'enum'
    ]],
  },
}

-- Cache: { ["connection:database:table"] = true }
local pk_cache = {}

function M.clear_pk_cache()
  pk_cache = {}
end

---------------------------------------------------------------------------
-- Query builders
---------------------------------------------------------------------------

local function build_pk_query(dialect, table_name, db)
  local template = METADATA_QUERIES.primary_keys[dialect]
  if not template then return nil end
  local safe_table = table_name:gsub("'", "''")
  if dialect == "mysql" or dialect == "mariadb" then
    local sql = string.format(template, safe_table)
    if db and db ~= "" then
      sql = sql .. string.format(" AND c.TABLE_SCHEMA = '%s'", db:gsub("'", "''"))
    end
    return sql
  elseif dialect == "postgres" then
    local schema = "public"
    return string.format(template, safe_table, safe_table, schema:gsub("'", "''"))
  elseif dialect == "sqlite" then
    return string.format(template, safe_table)
  end
  return nil
end

local function build_enum_query(dialect, table_name, db)
  local template = METADATA_QUERIES.enums[dialect]
  if not template then return nil end
  local safe_table = table_name:gsub("'", "''")
  if dialect == "mysql" or dialect == "mariadb" then
    local sql = string.format(template, safe_table)
    if db and db ~= "" then
      sql = sql .. string.format(" AND TABLE_SCHEMA = '%s'", db:gsub("'", "''"))
    end
    return sql
  elseif dialect == "postgres" then
    return template
  end
  return nil
end

---------------------------------------------------------------------------
-- Query execution helpers
---------------------------------------------------------------------------

local function resolve_src_file(tab)
  local src_file = tab.src_file or ""
  if src_file ~= "" then return src_file end
  local ok, buf_name = pcall(vim.api.nvim_buf_get_name, 0)
  if ok and buf_name and buf_name ~= "" and not buf_name:match("^poste://") then
    return buf_name
  end
  return vim.fn.tempname() .. ".sql"
end

local function run_introspection_query(query, connection, database, src_file)
  local exec_run = require("poste-db.exec_run")
  local opts = {
    src_file = src_file,
    database = database,
    mode = "greedy",
    log_source = "introspect",
  }
  if connection:match("^%w+://") then
    opts.conn_url = connection
  else
    opts.log_extra = { connection = connection }
    local connections = require("poste-db.connections")
    local resolved, _ = connections.resolve_connection_url(connection)
    if resolved and resolved ~= "" then
      opts.conn_url = resolved
    end
  end
  local parsed = exec_run.run_sql(query, opts)
  if not parsed then return nil end
  -- A refused introspection query and a table that genuinely has no keys arrive
  -- with the same payload the parsers read (no rows), and the caller's cache rule
  -- is "only on success" — so the verdict has to be consulted here, not inferred
  -- from the rows. Returning nil for a failure keeps that promise: the metadata is
  -- absent for this edit and the next one retries, and the user is told which of
  -- the two happened.
  if parsed.has_error then
    local reason = exec_run.first_error(parsed)
    vim.notify("Table metadata lookup failed: " .. tostring(reason or "the server reported a failure"),
      vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return nil
  end
  local body_ok, body = pcall(vim.json.decode, parsed.body or "{}")
  if not body_ok or not body then return nil end
  return body
end

---------------------------------------------------------------------------
-- Result parsers
---------------------------------------------------------------------------

local function parse_pk_results(body, layout, dialect)
  local defaults = {}
  local pk_names = {}
  local is_pk_col_idx = ((dialect == "mysql" or dialect == "mariadb") and 4) or 3
  for _, res in ipairs(body.results) do
    if res.rows then
      for _, row in ipairs(res.rows) do
        local col_name = tostring(row[1] or "")
        local col_default = row[2]
        local is_pk = row[is_pk_col_idx]
        if col_name ~= "" then
          defaults[col_name] = (col_default ~= vim.NIL and col_default ~= nil) and col_default or nil
          if is_pk and (is_pk == 1 or is_pk == "1") then
            pk_names[col_name] = true
          end
        end
      end
    end
  end
  for _, col in ipairs(layout.columns) do
    if defaults[col.name] ~= nil then
      col.default = defaults[col.name]
    end
    if pk_names[col.name] then
      col.primary_key = true
    end
  end
end

local function parse_mysql_enum_body(body, layout)
  for _, res in ipairs(body.results) do
    if res.rows then
      for _, row in ipairs(res.rows) do
        local col_name = tostring(row[1] or "")
        local col_type = tostring(row[2] or "")
        local values = {}
        for v in col_type:gmatch("'([^']*)'") do
          table.insert(values, v)
        end
        if #values > 0 then
          for _, col in ipairs(layout.columns) do
            if col.name == col_name then
              col.enum_values = values
              break
            end
          end
        end
      end
    end
  end
end

local function parse_postgres_enum_body(body, layout)
  local enum_map = {}
  for _, res in ipairs(body.results) do
    if res.rows then
      for _, row in ipairs(res.rows) do
        local type_name = tostring(row[1] or "")
        local enum_value = tostring(row[2] or "")
        if type_name ~= "" and enum_value ~= "" then
          if not enum_map[type_name] then
            enum_map[type_name] = {}
          end
          table.insert(enum_map[type_name], enum_value)
        end
      end
    end
  end
  for _, col in ipairs(layout.columns) do
    if col.ctype and enum_map[col.ctype:lower()] then
      col.enum_values = enum_map[col.ctype:lower()]
    end
  end
end

local function parse_enum_results(body, layout, dialect)
  if dialect == "mysql" or dialect == "mariadb" then
    parse_mysql_enum_body(body, layout)
  elseif dialect == "postgres" then
    parse_postgres_enum_body(body, layout)
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Fetch primary key info for a table via SQL query.
--- Sets primary_key=true and default/enum_values on matching columns.
--- @param tab table Tab state with layout
function M.ensure_primary_key(tab)
  if not tab or not tab.layout then return end
  local layout = tab.layout
  local table_name = layout.table_name
  if not table_name or table_name == "" then return end

  local sql_state = get_state()
  local connection = layout._conn_name
      or (sql_state.context and sql_state.context.connection) or ""
  local database = layout._database or layout.database or ""
  if database == "" and sql_state.context then
    database = sql_state.context.database or ""
  end
  if connection == "" then return end
  local cache_key = connection .. ":" .. database .. ":" .. table_name
  if pk_cache[cache_key] then return end

  for _, col in ipairs(layout.columns) do
    if col.primary_key then
      pk_cache[cache_key] = true
      return
    end
  end

  local dialect = layout.dialect or ""
  local db = database
  if (not db or db == "") and layout.connection then
    db = layout.connection:match("/([^/?]+)$")
  end

  local src_file = resolve_src_file(tab)
  local pk_query = build_pk_query(dialect, table_name, db)
  if not pk_query then
    pk_cache[cache_key] = true
    return
  end

  local log = require("poste-db.log")
  log.debug(string.format("PK introspection: table=%s query=%s conn=%s db=%s", table_name, pk_query, log.redact_url(connection), database))
  local body = run_introspection_query(pk_query, connection, database, src_file)
  if body and body.results then
    parse_pk_results(body, layout, dialect)
  end

  local enum_query = build_enum_query(dialect, table_name, db)
  if enum_query then
    local enum_body = run_introspection_query(enum_query, connection, database, src_file)
    if enum_body and enum_body.results then
      parse_enum_results(enum_body, layout, dialect)
    end
  end

  -- Cache only on success so a transient introspection failure is retried
  -- on the next edit/commit instead of being permanently skipped.
  if body and body.results then
    pk_cache[cache_key] = true
  end
end

return M
