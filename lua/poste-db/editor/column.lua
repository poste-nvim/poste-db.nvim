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

--- Cached table metadata, keyed "connection:database:table":
---   { [column_name] = { default = any, pk = true, enum = string[] },
---     _by_type     = { [lowercased type] = string[] } }   -- postgres enums
---
--- The cache holds the METADATA, not "this table was already queried". A
--- boolean hit returned early and never touched the new layout — and PK flags
--- live on a single layout — so the second dataset for a table (a re-run
--- query, a second browser <CR>) had no primary key at all: the commit fell
--- back to an all-column WHERE ("may update several rows") and the PK column
--- turned editable again.
local meta_cache = {}

function M.clear_pk_cache()
  meta_cache = {}
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
    -- table_name may arrive schema-qualified (`main.users` — export.lua
    -- documents the shape): pinning table_schema = 'public' made a
    -- non-public table's PK/default fallback silently return nothing.
    local schema, bare = table_name:match("^([%w_]+)%.([%w_]+)$")
    if not schema then
      schema, bare = "public", table_name
    end
    safe_table = bare:gsub("'", "''")
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

-- NB: no src_file is threaded into exec_run — it ignores opts.src_file
-- entirely (write_temp_file makes its own tempname), so this used to ship a
-- phantom filename that showed up nowhere.
local function run_introspection_query(query, connection, database)
  local exec_run = require("poste-db.exec_run")
  local opts = {
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
-- Result parsers — body in, column metadata out
--
-- Parsing and applying are separate on purpose: the parsed table is what the
-- cache stores, so a second layout for the same table gets the metadata
-- without a round-trip. Parsers never touch a layout.
---------------------------------------------------------------------------

--- @param body table decoded introspection response
--- @param dialect string
--- @return table map column name -> { default = any, pk = boolean }
local function parse_pk_results(body, dialect)
  local meta = {}
  local is_pk_col_idx = ((dialect == "mysql" or dialect == "mariadb") and 4) or 3
  for _, res in ipairs(body.results or {}) do
    if res.rows then
      for _, row in ipairs(res.rows) do
        local col_name = tostring(row[1] or "")
        if col_name ~= "" then
          local entry = meta[col_name] or {}
          local col_default = row[2]
          if col_default ~= vim.NIL and col_default ~= nil then
            entry.default = col_default
          end
          local is_pk = row[is_pk_col_idx]
          if is_pk == 1 or is_pk == "1" then entry.pk = true end
          meta[col_name] = entry
        end
      end
    end
  end
  return meta
end

--- MySQL/MariaDB: `SHOW COLUMNS`-style rows carry the enum values inside the
--- type text (`enum('a','b')`).
--- @return table map column name -> string[]
local function parse_mysql_enum_body(body)
  local meta = {}
  for _, res in ipairs(body.results or {}) do
    if res.rows then
      for _, row in ipairs(res.rows) do
        local col_name = tostring(row[1] or "")
        local col_type = tostring(row[2] or "")
        local values = {}
        for v in col_type:gmatch("'([^']*)'") do
          table.insert(values, v)
        end
        if col_name ~= "" and #values > 0 then
          meta[col_name] = values
        end
      end
    end
  end
  return meta
end

--- Postgres: `pg_enum` rows pair a type name with one value; the column only
--- names the TYPE, so the result is keyed by type, not by column.
--- @return table map lowercased type name -> string[]
local function parse_postgres_enum_body(body)
  local meta = {}
  for _, res in ipairs(body.results or {}) do
    if res.rows then
      for _, row in ipairs(res.rows) do
        local type_name = tostring(row[1] or "")
        local enum_value = tostring(row[2] or "")
        if type_name ~= "" and enum_value ~= "" then
          local key = type_name:lower()
          meta[key] = meta[key] or {}
          table.insert(meta[key], enum_value)
        end
      end
    end
  end
  return meta
end

--- @return table map column name (mysql) or type name (postgres) -> string[]
local function parse_enum_results(body, dialect)
  if dialect == "mysql" or dialect == "mariadb" then
    return parse_mysql_enum_body(body)
  elseif dialect == "postgres" then
    return parse_postgres_enum_body(body)
  end
  return {}
end

--- Write cached metadata onto a layout's columns.
--- @param layout table
--- @param meta table|nil cached metadata (see `meta_cache`)
--- @param enums table|nil map column name / type name -> string[]
local function apply_column_meta(layout, meta, enums)
  for _, col in ipairs(layout.columns) do
    local entry = meta and meta[col.name]
    if entry then
      if entry.default ~= nil then col.default = entry.default end
      if entry.pk then col.primary_key = true end
    end
    local values = enums and (enums[col.name] or (col.ctype and enums[col.ctype:lower()]))
    if values then col.enum_values = values end
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
  local cached = meta_cache[cache_key]
  if cached then
    apply_column_meta(layout, cached.columns, cached.enums)
    return
  end

  for _, col in ipairs(layout.columns) do
    if col.primary_key then
      -- Already known (the browser's column list carries `pk` on sqlite and
      -- `key` on mysql): nothing to fetch, nothing to cache.
      return
    end
  end

  local dialect = layout.dialect or ""
  local db = database
  if (not db or db == "") and layout.connection then
    db = layout.connection:match("/([^/?]+)$")
  end

  local pk_query = build_pk_query(dialect, table_name, db)
  if not pk_query then
    return
  end

  local log = require("poste-db.log")
  log.debug(string.format("PK introspection: table=%s query=%s conn=%s db=%s", table_name, pk_query, log.redact_url(connection), database))
  local body = run_introspection_query(pk_query, connection, database)
  local columns_meta = (body and body.results) and parse_pk_results(body, dialect) or nil

  local enums_meta
  local enum_query = build_enum_query(dialect, table_name, db)
  if enum_query then
    local enum_body = run_introspection_query(enum_query, connection, database)
    if enum_body and enum_body.results then
      enums_meta = parse_enum_results(enum_body, dialect)
    end
  end

  apply_column_meta(layout, columns_meta, enums_meta)

  -- Cache only on success so a transient introspection failure is retried
  -- on the next edit/commit instead of being permanently skipped.
  if columns_meta then
    meta_cache[cache_key] = { columns = columns_meta, enums = enums_meta }
  end
end

return M
