--- SQL completion — data + cache layer.
--- Provides keyword tables, connection context resolution, lazy-fetch
--- (tables/columns/databases via the Rust CLI), and binary helpers.
local sql_state = require("poste-db.state")
local const = require("poste-db.constants")
local util = require("poste-db.util")

local compat = require("poste-db.compat")

local M = {}

---------------------------------------------------------------------------
-- Keywords & types
---------------------------------------------------------------------------

--- Completion display snippets.
--- Role: completion UI display, may include compound snippets (e.g. "ORDER BY").
--- This is NOT the same as Rust `is_known_keyword()`, which classifies individual
--- tokens for context detection. Every single-word entry here that affects parsing
--- must also be known by Rust. See drift test in `tests/sql_completion_spec.lua`.
local KEYWORDS = {
  "SELECT", "FROM", "WHERE", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN",
  "FULL JOIN", "CROSS JOIN", "ON", "GROUP BY", "ORDER BY", "HAVING",
  "LIMIT", "OFFSET", "DISTINCT", "ALL", "UNION", "UNION ALL", "AS", "WITH",
  "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM",
  "CREATE TABLE", "ALTER TABLE", "DROP TABLE", "TRUNCATE TABLE", "ADD COLUMN", "DROP COLUMN",
  "RENAME COLUMN", "MODIFY COLUMN",
  "AND", "OR", "NOT", "IN", "NOT IN", "EXISTS", "IF", "IS NULL", "IS NOT NULL",
  "LIKE", "ILIKE", "BETWEEN",
  "COUNT", "SUM", "AVG", "MAX", "MIN", "COALESCE", "NULLIF",
  "CAST", "NOW", "CURRENT_TIMESTAMP", "CURRENT_DATE",
  "TRIM", "UPPER", "LOWER", "LENGTH", "SUBSTRING", "CONCAT",
  "PRIMARY KEY", "FOREIGN KEY", "UNIQUE", "NOT NULL", "DEFAULT", "REFERENCES",
  "COMMENT", "CHARACTER", "COLLATE", "AFTER",
  "BEGIN", "COMMIT", "ROLLBACK",
  "CALL", "COPY", "DESC", "EXECUTE", "EXPLAIN", "PREPARE", "RETURNING", "SHOW", "SEQUENCE", "TABLES", "DATABASES", "SCHEMAS", "COLUMNS", "FIELDS", "USE",
  "FOR UPDATE", "FOR SHARE", "FOR UPDATE OF", "FOR SHARE OF", "OF",
  "NOWAIT", "SKIP LOCKED", "LOCKED",
  "NATURAL", "SAVEPOINT", "RELEASE", "QUERY", "PLAN", "RECURSIVE",
}

local DIALECT_KEYWORDS = {
  mysql = { "AUTO_INCREMENT", "INVISIBLE" },
  mariadb = { "AUTO_INCREMENT", "INVISIBLE" },
  sqlite = { "AUTOINCREMENT", "PRAGMA", "GLOB" },
}

local DATA_TYPES = {
  "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "DECIMAL", "NUMERIC",
  "FLOAT", "DOUBLE", "REAL", "SERIAL", "BIGSERIAL",
  "VARCHAR(255)", "TEXT", "CHAR(1)",
  "DATE", "TIME", "DATETIME", "TIMESTAMP", "TIMESTAMPTZ",
  "BOOLEAN", "BOOL", "BLOB", "BYTEA", "JSON", "JSONB", "UUID",
}

local TABLE_CTX = {
  from = true, join = true, update = true, into = true, table = true,
}

local COLUMN_CTX = {
  where = true, set = true, on = true, having = true, select = true,
  ["and"] = true, ["or"] = true, ["not"] = true,
  by = true,  -- ORDER BY, GROUP BY
  ["after"] = true,  -- ALTER TABLE ... ADD/MODIFY COLUMN col AFTER col_name
  ["="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true,
  ["!="] = true, ["<>"] = true,
}

--- Fallback-only SQL function list.
--- Rust `functions.rs` is the authoritative source. This list is only used
--- when the Rust binary is unavailable (`vim.g.poste_db_legacy_completion = true`).
--- MUST be a subset of Rust's `known_functions()`. See drift tests in
--- `tests/sql_completion_spec.lua`.
local SQL_FUNCTIONS = {
  -- String
  "CONCAT", "CONCAT_WS", "FORMAT", "INSTR", "LOCATE", "POSITION",
  "LEFT", "RIGHT", "SUBSTRING", "SUBSTR", "MID", "SUBSTRING_INDEX",
  "LENGTH", "CHAR_LENGTH", "CHARACTER_LENGTH", "OCTET_LENGTH", "BIT_LENGTH",
  "LOWER", "LCASE", "UPPER", "UCASE", "TRIM", "LTRIM", "RTRIM",
  "REPLACE", "REGEXP_REPLACE", "REGEXP_LIKE", "REGEXP_SUBSTR", "REGEXP_INSTR",
  "REPEAT", "REVERSE", "LPAD", "RPAD", "SPACE",
  "FIELD", "FIND_IN_SET", "ELT", "SOUNDEX",
  "ASCII", "ORD", "CHAR", "UNICODE", "UNHEX", "HEX",
  "QUOTE", "STRCMP",

  -- Numeric / Math
  "ABS", "CEIL", "CEILING", "FLOOR", "ROUND", "TRUNCATE", "TRUNC",
  "RAND", "RANDOM", "POWER", "POW", "SQRT", "EXP", "LN", "LOG", "LOG2", "LOG10",
  "MOD", "SIGN", "PI", "DIV", "CRC32",
  "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "ATAN2",
  "RADIANS", "DEGREES",
  "GREATEST", "LEAST",

  -- Aggregate / Window
  "COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP_CONCAT", "STRING_AGG", "ARRAY_AGG",
  "STD", "STDDEV", "STDDEV_POP", "STDDEV_SAMP",
  "VAR_POP", "VAR_SAMP", "VARIANCE",
  "BIT_AND", "BIT_OR", "BIT_XOR",
  "ROW_NUMBER", "RANK", "DENSE_RANK", "NTILE", "LAG", "LEAD",
  "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE",
  "CUME_DIST", "PERCENT_RANK", "PERCENTILE_CONT", "PERCENTILE_DISC",

  -- Date / Time
  "NOW", "SYSDATE", "LOCALTIME", "LOCALTIMESTAMP",
  "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP",
  "CURDATE", "CURTIME",
  "YEAR", "MONTH", "DAY", "DAYOFMONTH", "DAYOFWEEK", "DAYOFYEAR",
  "WEEK", "WEEKDAY", "WEEKOFYEAR",
  "HOUR", "MINUTE", "SECOND", "MICROSECOND",
  "QUARTER", "LAST_DAY",
  "DATE_FORMAT", "TIME_FORMAT",
  "FROM_UNIXTIME", "UNIX_TIMESTAMP",
  "STR_TO_DATE", "TO_DAYS", "FROM_DAYS",
  "DATE_ADD", "DATE_SUB", "ADDDATE", "SUBDATE",
  "ADDTIME", "SUBTIME", "TIMEDIFF", "TIMESTAMPDIFF", "TIMESTAMPADD",
  "DATEDIFF",
  "EXTRACT", "DATE_PART",
  "MAKEDATE", "MAKETIME", "MAKE_DATE", "MAKE_TIME", "MAKE_TIMESTAMP",
  "CONVERT_TZ",
  "DATE_TRUNC", "TIME_TRUNC",
  "AGE", "ISFINITE", "JUSTIFY_DAYS", "JUSTIFY_HOURS", "JUSTIFY_INTERVAL",
  "CLOCK_TIMESTAMP", "STATEMENT_TIMESTAMP", "TRANSACTION_TIMESTAMP",

  -- JSON
  "JSON_EXTRACT", "JSON_UNQUOTE", "JSON_KEYS", "JSON_CONTAINS",
  "JSON_CONTAINS_PATH", "JSON_SET", "JSON_INSERT", "JSON_REPLACE",
  "JSON_REMOVE", "JSON_ARRAY", "JSON_OBJECT", "JSON_ARRAY_APPEND",
  "JSON_MERGE", "JSON_MERGE_PATCH",
  "JSON_TYPE", "JSON_VALID", "JSON_DEPTH", "JSON_LENGTH",
  "JSON_QUOTE", "JSON_TABLE", "JSON_VALUE",
  "JSON_AGG", "JSON_OBJECT_AGG",
  "JSONB_BUILD_OBJECT", "JSONB_AGG", "JSONB_PRETTY", "JSONB_EXTRACT_PATH",
  "TO_JSON", "ROW_TO_JSON",

  -- Conditional
  "COALESCE", "NULLIF", "IFNULL", "IF",

  -- Type conversion
  "CAST", "CONVERT", "TRY_CAST", "TRY_CONVERT",
  "TO_CHAR", "TO_NUMBER", "TO_TIMESTAMP",

  -- Security / Hash
  "MD5", "SHA1", "SHA2", "AES_ENCRYPT", "AES_DECRYPT",
  "RANDOM_BYTES", "UUID", "UUID_SHORT",

  -- System / Info
  "VERSION", "DATABASE", "SCHEMA", "USER",
  "SESSION_USER", "SYSTEM_USER", "CONNECTION_ID",
  "ROW_COUNT", "FOUND_ROWS", "LAST_INSERT_ID",
  "CHARSET", "COLLATION", "CURRENT_SCHEMA",
  "CURRENT_SETTING", "SET_CONFIG",

  -- Full-Text Search
  "MATCH", "AGAINST",

  -- Postgres extras
  "UNNEST", "GENERATE_SERIES", "ARRAY", "ROW", "SETSEED",

  -- MySQL extras
  "ANY_VALUE", "BENCHMARK",
  "GET_LOCK", "RELEASE_LOCK", "RELEASE_ALL_LOCKS",
  "IS_FREE_LOCK", "IS_USED_LOCK",
  "SLEEP", "VALUES",

  -- SQLite extras
  "TOTAL", "TYPEOF", "LIKELY", "UNLIKELY", "LIKELIHOOD",
  "CHANGES", "TOTAL_CHANGES",
  "SQLITE_VERSION", "SQLITE_SOURCE_ID", "ZEROBLOB",
}

M.KEYWORDS = KEYWORDS
M.DIALECT_KEYWORDS = DIALECT_KEYWORDS
M.DATA_TYPES = DATA_TYPES
M.SQL_FUNCTIONS = SQL_FUNCTIONS
M.TABLE_CTX = TABLE_CTX
M.COLUMN_CTX = COLUMN_CTX

---------------------------------------------------------------------------
-- Cache  { [key] = { tables=[], columns={[tbl]=[]} } }
---------------------------------------------------------------------------

local cache = {}
local cache_epoch = 0

function M.get_cache() return cache end

--- Clear the schema cache for the current connection.
--- Call after DDL execution (CREATE TABLE, ALTER, DROP, etc.)
--- to force re-fetching on next completion.
function M.clear_cache()
  cache_epoch = cache_epoch + 1
  local ctx = M.resolve_current_context()
  local conn = ctx and ctx.connection
  if not conn then return end
  -- Cache keys are `<conn>/<db>`, `<conn>/<db>/db:<name>` and
  -- `<conn>/__databases__`. The old anchored `^db:` prefix matched none of
  -- them, so every per-database table list survived a CREATE/DROP.
  for k in pairs(cache) do
    if k == conn or k:sub(1, #conn + 1) == conn .. "/" then
      cache[k] = nil
    end
  end
end

--- Resolve the connection/database the completion request runs against.
--- `buf`/`limit_line` default to the live window; a deferred caller (the
--- completion source resolving context for a buffer the user may have left)
--- has to pass what it was triggered on, not whatever is on screen now.
function M.resolve_current_context(buf, limit_line)
  local ok, sql_context = pcall(require, "poste-db.context")
  if not ok then return sql_state and sql_state.context end
  local ctx = sql_context.resolve_full_context(buf or vim.api.nvim_get_current_buf(), limit_line)
  if not ctx.connection then
    ctx.connection = sql_state and sql_state.context and sql_state.context.connection
  end
  if not ctx.database then
    ctx.database = sql_state and sql_state.context and sql_state.context.database
  end
  return ctx
end

--- The schema cache key for a context: `<connection>/<database>`.
--- `ctx` lets a caller that already walked the buffer reuse it — resolving the
--- context is a full buffer scan, so `conn_key()` on its own is the second one.
function M.conn_key(ctx)
  ctx = ctx or M.resolve_current_context()
  if ctx and ctx.connection then
    return ctx.connection .. "/" .. (ctx.database or "")
  end
  if compat.opt("debug") then
    sql_state.log("WARN", "SQL completion: no connection context found")
  end
  return nil
end

function M.cache_tables(items)
  local key = M.conn_key()
  if not key then return end
  cache[key] = cache[key] or { tables = {}, columns = {} }
  cache[key].tables = vim.tbl_map(function(i) return i.name end, items or {})
end

function M.cache_columns(tbl, items, schema)
  local key = M.conn_key()
  if not key then return end
  local cache_key = schema and (schema .. "." .. tbl) or tbl
  cache[key] = cache[key] or { tables = {}, columns = {} }
  cache[key].columns[cache_key] = vim.tbl_map(function(i) return i.name end, items or {})
end

---------------------------------------------------------------------------
-- Binary helper
---------------------------------------------------------------------------

function M.find_binary()
  return sql_state.find_poste_binary()
end

function M.search_dir()
  local name = vim.api.nvim_buf_get_name(0)
  return name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
end

local function resolve_conn_url(conn)
  if not conn or conn == "" then return nil end
  if const.dialect_from_url(conn:lower()) then return conn end
  local ok, conn_mod = pcall(require, "poste-db.connections")
  if ok then
    local url, _ = conn_mod.resolve_connection_url(conn)
    return url
  end
  return nil
end

---------------------------------------------------------------------------
-- Shared introspect-fetch scaffold
---------------------------------------------------------------------------

-- In-flight/callback registries shared by all ensure_* fetchers. Keys are
-- namespaced per fetcher ("tables:", "dbs:", ...) so unrelated fetches never
-- collide even when their cache keys do.
local fetching = {}
local callbacks = {}

--- Run every queued callback for `key` synchronously (pre-job failure paths).
local function flush_now(key, value)
  fetching[key] = false
  local cbs = callbacks[key] or {}
  callbacks[key] = nil
  for _, cb in ipairs(cbs) do cb(value) end
end

--- Run every queued callback for `key` on the next scheduler tick. Marks the
--- fetch finished synchronously so on_exit skips an already-flushed job.
local function flush_scheduled(key, value)
  fetching[key] = false
  vim.schedule(function()
    local cbs = callbacks[key] or {}
    callbacks[key] = nil
    for _, cb in ipairs(cbs) do cb(value) end
  end)
end

local function queue_cb(key, cb)
  callbacks[key] = callbacks[key] or {}
  table.insert(callbacks[key], cb)
end

--- Resolve the binary + connection URL every fetcher needs; flushes `key`
--- with `fail_value` and returns nil when either is missing.
local function resolve_fetch_target(key, connection, fail_value)
  local binary = M.find_binary()
  if not binary then flush_now(key, fail_value); return nil end
  local url = resolve_conn_url(connection)
  if not url then flush_now(key, fail_value); return nil end
  return binary, url
end

--- Start one `poste introspect` job. stdout is epoch-guarded, trimmed, JSON
--- decoded and handed to on_items(items_or_nil, flush); on_items must call
--- flush(value) exactly once to run the queued callbacks. A fetch still
--- pending at exit time (empty stdout or non-zero exit) is flushed with
--- `exit_default` instead of hanging forever.
local function start_introspect_job(key, args, on_items, exit_default)
  local epoch = cache_epoch
  -- jobstart raises E475 when the binary vanished between find_binary and
  -- this call; unwrapped, the raise escaped into whatever triggered the
  -- fetch instead of flushing the waiters the way a dead job's on_exit does
  local ok_job, job = pcall(vim.fn.jobstart, args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if epoch ~= cache_epoch then return end
      data = util.ensure_job_data(data)
      if #data == 0 then return end
      local ok, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
      local items = (ok and parsed and parsed.items) and parsed.items or nil
      on_items(items, function(value) flush_scheduled(key, value) end)
    end,
    on_exit = function(_, _code)
      if fetching[key] then
        flush_scheduled(key, exit_default)
      end
    end,
  })
  if not ok_job or job <= 0 then
    flush_scheduled(key, exit_default)
  end
end

---------------------------------------------------------------------------
-- Lazy fetch tables
---------------------------------------------------------------------------

function M.ensure_tables(callback)
  local ctx = M.resolve_current_context()
  local key = M.conn_key(ctx)
  if not key or not ctx or not ctx.connection then
    callback()
    return
  end

  if cache[key] and #cache[key].tables > 0 then callback(); return end

  local fkey = "tables:" .. key
  if fetching[fkey] then
    queue_cb(fkey, callback)
    return
  end

  fetching[fkey] = true
  callbacks[fkey] = { callback }

  local binary, url = resolve_fetch_target(fkey, ctx.connection, nil)
  if not binary then return end

  local args = { binary, "introspect", "--connection-url", url,
    "--type", "tables" }
  if ctx.database and ctx.database ~= "" then
    vim.list_extend(args, { "--database", ctx.database })
  end

  start_introspect_job(fkey, args, function(items, flush)
    if items then
      cache[key] = cache[key] or { tables = {}, columns = {} }
      cache[key].tables = vim.tbl_map(function(i) return i.name end, items)
    end
    flush()
  end, nil)
end

--- CLI flag used to scope a table list to a `db.`/`schema.` prefix such as
--- `FROM order_catalog.` or `FROM pg_catalog.`. postgres/sqlite/mssql scope
--- by schema; mysql/mariadb (and unknown dialects) by database.
--- @param dialect string|nil
--- @return string "--schema" or "--database"
function M.tables_db_flag(dialect)
  dialect = dialect and dialect:lower() or ""
  if dialect == "postgres" or dialect == "postgresql"
    or dialect == "sqlite" or dialect == "mssql" then
    return "--schema"
  end
  return "--database"
end

--- Fetch tables for a specific database/schema (e.g. `FROM inventory.`)
function M.ensure_tables_for_db(db_name, callback)
  local ctx = M.resolve_current_context()
  local key = M.conn_key(ctx)
  if not key or not ctx or not ctx.connection then
    callback()
    return
  end

  local db_cache_key = key .. "/db:" .. db_name
  if cache[db_cache_key] and #cache[db_cache_key].tables > 0 then callback(); return end

  local fkey = "tables-db:" .. db_cache_key
  if fetching[fkey] then
    queue_cb(fkey, callback)
    return
  end

  fetching[fkey] = true
  callbacks[fkey] = { callback }

  local binary, url = resolve_fetch_target(fkey, ctx.connection, nil)
  if not binary then return end

  local flag = M.tables_db_flag(nil)
  if ctx.connection then
    local ok_conn, conn_mod = pcall(require, "poste-db.connections")
    if ok_conn then
      local conn = conn_mod.get_connection_config(ctx.connection)
      if conn and conn.dialect then flag = M.tables_db_flag(conn.dialect) end
    end
  end

  local args = { binary, "introspect", "--connection-url", url,
    "--type", "tables", flag, db_name }

  start_introspect_job(fkey, args, function(items, flush)
    if items then
      cache[db_cache_key] = cache[db_cache_key] or { tables = {}, columns = {} }
      cache[db_cache_key].tables = vim.tbl_map(function(i) return i.name end, items)
    end
    flush()
  end, nil)
end

---------------------------------------------------------------------------
-- Lazy fetch databases for current connection
---------------------------------------------------------------------------

function M.ensure_databases(callback)
  local ctx = M.resolve_current_context()
  if not ctx or not ctx.connection then callback({}); return end

  local conn_key_str = ctx.connection
  local cache_key = conn_key_str .. "/__databases__"
  if cache[cache_key] then callback(cache[cache_key]); return end

  local fkey = "dbs:" .. conn_key_str
  if fetching[fkey] then
    queue_cb(fkey, callback)
    return
  end

  fetching[fkey] = true
  callbacks[fkey] = { callback }

  local binary, url = resolve_fetch_target(fkey, ctx.connection, {})
  if not binary then return end

  local args = { binary, "introspect", "--connection-url", url,
    "--type", "databases" }

  start_introspect_job(fkey, args, function(items, flush)
    local names = {}
    if items then
      names = vim.tbl_map(function(i) return i.name end, items)
      cache[cache_key] = names
    end
    flush(names)
  end, {})
end

---------------------------------------------------------------------------
-- Lazy fetch columns for a single table
---------------------------------------------------------------------------

--- Ensure columns for `tbl` are cached, optionally with schema qualification.
--- schema can be a string or nil. When set, columns are cached and fetched
--- as `schema.table` to distinguish same-named tables in different schemas.
function M.ensure_columns(tbl, schema, callback)
  if type(schema) == "function" then
    callback = schema
    schema = nil
  end
  local ctx = M.resolve_current_context()
  local key = M.conn_key(ctx)
  local cache_tbl_key = schema and (schema .. "." .. tbl) or tbl

  -- Debug traces go to the log file (state.log), never to vim.notify: a
  -- popup for a routine trace would interrupt typing.
  if compat.opt("debug") then
    sql_state.log("INFO", string.format("DEBUG: ensure_columns(%s, %s) key=%s, conn=%s",
      tbl, tostring(schema), tostring(key), tostring(ctx and ctx.connection)))
  end

  if not key or not ctx or not ctx.connection then
    if compat.opt("debug") then
      sql_state.log("INFO", "DEBUG: ensure_columns - NO CONNECTION, returning")
    end
    callback()
    return
  end

  if cache[key] and cache[key].columns[cache_tbl_key] then
    if compat.opt("debug") then
      sql_state.log("INFO", string.format("DEBUG: cache hit for %s, %d columns",
        cache_tbl_key, #cache[key].columns[cache_tbl_key]))
    end
    callback()
    return
  end

  local fkey = "cols:" .. key .. "/" .. cache_tbl_key

  if fetching[fkey] then
    if compat.opt("debug") then
      sql_state.log("INFO", string.format("DEBUG: already fetching %s, queuing callback", cache_tbl_key))
    end
    queue_cb(fkey, callback)
    return
  end

  if compat.opt("debug") then
    sql_state.log("INFO", string.format("DEBUG: starting fetch for %s", cache_tbl_key))
  end

  fetching[fkey] = true
  callbacks[fkey] = { callback }

  local binary, url = resolve_fetch_target(fkey, ctx.connection, nil)
  if not binary then
    if compat.opt("debug") then sql_state.log("INFO", "DEBUG: binary not found!") end
    return
  end

  local args = { binary, "introspect", "--connection-url", url,
    "--type", "columns", "--table", tbl }

  local db_override = ctx.database
  if schema and schema ~= "" then
    local ok_conn, conn_mod = pcall(require, "poste-db.connections")
    if ok_conn then
      local conn = conn_mod.get_connection_config(ctx.connection)
      if conn and (conn.dialect == "mysql" or conn.dialect == "mariadb") then
        db_override = schema
        schema = nil
      end
    end
  end

  if schema and schema ~= "" then
    vim.list_extend(args, { "--schema", schema })
  end
  if db_override and db_override ~= "" then
    vim.list_extend(args, { "--database", db_override })
  end

  start_introspect_job(fkey, args, function(items, flush)
    if items then
      cache[key] = cache[key] or { tables = {}, columns = {} }
      local cols = {}
      for _, item in ipairs(items) do
        table.insert(cols, item.name)
      end
      -- An empty list is not authoritative (same rule ensure_tables applies to
      -- `#tables > 0`): caching one would blacklist the table from column
      -- completion for the rest of the session.
      if #cols > 0 then
        cache[key].columns[cache_tbl_key] = cols
      end
    end
    flush()
  end, nil)
end

---------------------------------------------------------------------------
-- Lazy fetch connection names
---------------------------------------------------------------------------

local conn_names_cache = nil
local conn_names_fp = nil -- config-path + mtime fingerprint (invalidation hint)

--- Connection names for `-- @connection <tab>` (and the connection-kind
--- fallback under `-- @database`). The cache is keyed on the file's path and
--- mtime, not on "have we looked yet": a connection added to connections.toml
--- mid-session used to stay unsuggested until restart, because directive
--- completion is the only consumer and nothing ever cleared this cache.
function M.ensure_conn_names(callback)
  local search_dir = M.search_dir()
  local config_path = require("poste-db.connections").find_connections_toml(search_dir)
  local fp = tostring(config_path) .. "|" .. tostring(config_path and vim.fn.getftime(config_path) or nil)
  if conn_names_cache and conn_names_fp == fp then
    callback(conn_names_cache)
    return
  end
  vim.schedule(function()
    local names = {}
    if config_path then
      local toml = require("poste-db.toml")
      local parsed, _ = toml.parse_file(config_path)
      if parsed then
        for name, _ in pairs(parsed) do
          table.insert(names, name)
        end
        table.sort(names)
        conn_names_cache = names
        conn_names_fp = fp
      end
    end
    callback(names)
  end)
end

return M
