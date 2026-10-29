--- Catalog queries for DB Browser copy/paste.
---
--- Enumerates tables/views/triggers/routines and their byte sizes via plain
--- SQL executed through sql_conn.run (no Rust-side changes needed: the
--- binary's introspect types are table-oriented, while views/triggers/
--- routines require dialect-specific catalog queries anyway).
---
--- Pure SQL builders and row parsers are exported separately so tests can
--- assert them without a live connection.
local sql_conn = require("poste-db.db_browser.sql_conn")

local M = {}

-- ---------------------------------------------------------------- helpers

local function esc_quote(name)
  -- Escape a value used inside a single-quoted SQL string literal.
  return "'" .. tostring(name):gsub("'", "''") .. "'"
end

local function esc_backtick(name)
  return "`" .. tostring(name):gsub("`", "``") .. "`"
end

local SYSTEM_NS_SQL = "NOT IN ('pg_catalog', 'information_schema', 'pg_toast')"

--- Find the first column value of `m` whose key starts with `prefix`
--- (e.g. keys named "Create Procedure" / "Create Function" / "Create View"),
--- matching case-insensitively on the value's leading text via the prefix
--- itself when needed.
local function find_column_starting_with(m, prefix_lower)
  for k, v in pairs(m) do
    if type(v) == "string" and type(k) == "string"
        and k:lower():find(prefix_lower, 1, true) == 1 then
      return v
    end
  end
  return nil
end

-- ---------------------------------------------------- pure SQL builders

--- SQL listing base tables + views of one database (all user schemas for PG).
---@param dialect string postgres|mysql|mariadb|sqlite
---@return string|nil sql (nil = dialect unsupported)
function M.list_objects_sql(dialect)
  if dialect == "mysql" or dialect == "mariadb" then
    return "SELECT TABLE_NAME AS name, TABLE_TYPE AS type"
      .. " FROM information_schema.TABLES"
      .. " WHERE TABLE_SCHEMA = DATABASE()"
      .. " AND TABLE_TYPE IN ('BASE TABLE', 'VIEW')"
      .. " ORDER BY TABLE_NAME"
  elseif dialect == "postgres" then
    return "SELECT c.relname AS name,"
      .. " CASE WHEN c.relkind IN ('v','m') THEN 'VIEW' ELSE 'BASE TABLE' END AS type,"
      .. " n.nspname AS table_schema"
      .. " FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
      .. " WHERE n.nspname " .. SYSTEM_NS_SQL
      .. " AND c.relkind IN ('r','p','v','m')"
      .. " ORDER BY n.nspname, c.relname"
  elseif dialect == "sqlite" then
    return "SELECT name, 'BASE TABLE' AS type FROM sqlite_master"
      .. " WHERE type='table' AND name NOT LIKE 'sqlite_%'"
      .. " UNION ALL"
      .. " SELECT name, 'VIEW' AS type FROM sqlite_master"
      .. " WHERE type='view' AND name NOT LIKE 'sqlite_%'"
      .. " ORDER BY name"
  end
  return nil
end

--- SQL returning user-defined trigger definitions.
---@param dialect string
---@return string|nil sql (nil = none possible, e.g. unsupported dialect)
function M.trigger_defs_sql(dialect)
  if dialect == "mysql" or dialect == "mariadb" then
    return "SELECT TRIGGER_NAME AS name, ACTION_TIMING AS timing,"
      .. " EVENT_MANIPULATION AS event_type, EVENT_OBJECT_TABLE AS table_name,"
      .. " ACTION_STATEMENT AS stmt"
      .. " FROM information_schema.TRIGGERS"
      .. " WHERE TRIGGER_SCHEMA = DATABASE()"
      .. " ORDER BY TRIGGER_NAME"
  elseif dialect == "postgres" then
    return "SELECT t.tgname AS name, pg_get_triggerdef(t.oid) AS def"
      .. " FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid"
      .. " JOIN pg_namespace n ON n.oid = c.relnamespace"
      .. " WHERE NOT t.tgisinternal AND n.nspname " .. SYSTEM_NS_SQL
      .. " ORDER BY t.tgname"
  elseif dialect == "sqlite" then
    return "SELECT name, sql AS def FROM sqlite_master"
      .. " WHERE type='trigger' AND name NOT LIKE 'sqlite_%'"
      .. " ORDER BY name"
  end
  return nil
end

--- SQL listing user-defined procedures/functions (names + kinds).
---@return string|nil sql (nil = dialect has none, e.g. sqlite)
function M.routine_names_sql(dialect)
  if dialect == "mysql" or dialect == "mariadb" then
    return "SELECT ROUTINE_NAME AS name, ROUTINE_TYPE AS rtype"
      .. " FROM information_schema.ROUTINES"
      .. " WHERE ROUTINE_SCHEMA = DATABASE()"
      .. " ORDER BY ROUTINE_NAME"
  elseif dialect == "postgres" then
    return "SELECT p.proname AS name,"
      .. " CASE WHEN p.prokind = 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END AS rtype"
      .. " FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
      .. " WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')"
      .. " AND p.prokind IN ('f','p')"
      .. " ORDER BY p.proname"
  end
  return nil
end

--- SQL fetching the full CREATE statement of one procedure/function.
--- `schema` (optional) scopes the postgres lookup: pg_proc is matched by
--- proname alone otherwise, so two schemas holding a same-named function
--- delivered whichever ORDER BY chose first.
function M.routine_def_sql(dialect, name, rtype, schema)
  if dialect == "mysql" or dialect == "mariadb" then
    local kind = (rtype == "PROCEDURE") and "PROCEDURE" or "FUNCTION"
    return "SHOW CREATE " .. kind .. " " .. esc_backtick(name)
  elseif dialect == "postgres" then
    return "SELECT pg_get_functiondef(p.oid)::text AS def"
      .. " FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace"
      .. " WHERE p.proname = " .. esc_quote(name)
      .. (schema and schema ~= ""
          and " AND n.nspname = " .. esc_quote(schema) or "")
      .. " LIMIT 1"
  end
  return nil
end

--- SQL fetching a view definition. MySQL/SQLite return the server's full
--- "CREATE ... VIEW <ident> AS <body>" text; PG returns just the body.
--- `schema` (optional) scopes the postgres lookup the same way: without it
--- the name matched across ALL schemas, public first.
function M.view_definition_sql(dialect, name, schema)
  if dialect == "mysql" or dialect == "mariadb" then
    return "SHOW CREATE VIEW " .. esc_backtick(name)
  elseif dialect == "postgres" then
    return "SELECT pg_get_viewdef(c.oid, true)::text AS body"
      .. " FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
      .. " WHERE c.relname = " .. esc_quote(name)
      .. " AND c.relkind IN ('v','m')"
      .. (schema and schema ~= ""
          and " AND n.nspname = " .. esc_quote(schema) or "")
      .. " AND n.nspname " .. SYSTEM_NS_SQL
      .. " ORDER BY CASE WHEN n.nspname = 'public' THEN 0 ELSE 1 END"
      .. " LIMIT 1"
  elseif dialect == "sqlite" then
    return "SELECT sql AS body FROM sqlite_master"
      .. " WHERE type='view' AND name = " .. esc_quote(name)
  end
  return nil
end

--- SQL returning {name, [schema], bytes} rows for size estimation.
function M.sizes_sql(dialect)
  if dialect == "mysql" or dialect == "mariadb" then
    return "SELECT TABLE_NAME AS name,"
      .. " COALESCE(DATA_LENGTH + INDEX_LENGTH, 0) AS bytes"
      .. " FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()"
  elseif dialect == "postgres" then
    return "SELECT c.relname AS name, n.nspname AS schema,"
      .. " CASE WHEN c.relkind IN ('r','p')"
      .. " THEN pg_total_relation_size(c.oid) ELSE 0 END AS bytes"
      .. " FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
      .. " WHERE c.relkind IN ('r','p','v','m')"
      .. " AND n.nspname " .. SYSTEM_NS_SQL
  elseif dialect == "sqlite" then
    -- dbstat is compile-optional; callers tolerate total failure here.
    return "SELECT name, SUM(pgsize) AS bytes FROM dbstat"
      .. " WHERE name NOT LIKE 'sqlite_%' GROUP BY name"
  end
  return nil
end

-- ------------------------------------------------------ pure row parsing

--- Decode a result's rows/columns into ordered maps.
---@param r table result with { columns = [{name=..}], rows = {{..},..} }
---@return table[] maps, one per row ({ [column_name] = value })
function M.result_to_maps(r)
  local maps = {}
  if not r or not r.columns or not r.rows then return maps end
  local names = {}
  for _, c in ipairs(r.columns) do
    table.insert(names, c.name)
  end
  for _, row in ipairs(r.rows) do
    local m = {}
    for i, val in ipairs(row) do
      m[names[i] or tostring(i)] = val
    end
    table.insert(maps, m)
  end
  return maps
end

--- Position of the first " as " at or after `from` that sits OUTSIDE any
--- quoted segment ('…', "…", `…`), or nil. Doubled quotes ('', ``) stay
--- inside, matching every dialect's escape. A while-loop, not a numeric
--- for: the doubled-quote branch advances i itself, which a for-loop's
--- internal counter would silently undo.
---@param low string lowercased DDL text
---@param from number 1-based scan start
---@return number|nil
local function find_as_outside_quotes(low, from)
  local in_quote
  local i = from
  while i <= #low do
    local c = low:sub(i, i)
    if in_quote then
      if c == in_quote then
        if low:sub(i + 1, i + 1) == in_quote then
          i = i + 1
        else
          in_quote = nil
        end
      end
    elseif c == "'" or c == '"' or c == "`" then
      in_quote = c
    elseif low:find("^%sas%s", i) then
      return i
    end
    i = i + 1
  end
  return nil
end

--- Strip a "CREATE ... VIEW <ident> AS" header, leaving the SELECT body.
--- Handles MySQL (backticks + ALGORITHM/DEFINER clauses) and SQLite; PG's
--- already-bare body passes through unchanged. Matching is case-insensitive
--- AND gated on a leading CREATE: sqlite_master stores the statement exactly
--- as written (`create view …` is common), while pg_get_viewdef returns a
--- bare SELECT — a body that merely CONTAINS " view … as " (a comment, a
--- string literal) must never be stripped. The AS search also ignores quoted
--- segments: a quoted view name may itself contain " as " (legal in every
--- dialect), and splitting there cut the header in half.
---@param text string
---@return string body
function M.view_body_from_ddl(text)
  text = tostring(text)
  local low = text:lower()
  if not low:match("^%s*create%s") then return text end
  local vi = low:find("%sview%s")
  if vi then
    local split_at = find_as_outside_quotes(low, vi + 5)
    if split_at then return text:sub(split_at + 4) end
  end
  return text
end

--- Compose executable CREATE TRIGGER SQL from parsed trigger info.
--- v1 rule: triggers are recreated with their original names referencing the
--- pasted table's original name (rename-mapping is deliberately out of scope;
--- failures surface in the summary dialog).
---@param dialect string
---@param trig table mysql {name,timing,event_type,table_name,stmt};
---                   pg/sqlite {name, def}
---@return string sql
function M.compose_trigger_sql(dialect, trig)
  if dialect == "mysql" or dialect == "mariadb" then
    -- esc_backtick, not bare interpolation: a trigger or table whose name
    -- contains a backtick (legal when quoted) doubled it on the way into the
    -- catalog and must double it again on the way out — `` `a`b` `` is a
    -- syntax error, `` `a``b` `` is the name.
    return "CREATE TRIGGER " .. esc_backtick(trig.name) .. " "
      .. trig.timing .. " " .. trig.event_type
      .. " ON " .. esc_backtick(trig.table_name) .. " FOR EACH ROW " .. trig.stmt
  end
  return trig.def
end

-- --------------------------------------------------- async collectors

local function run_maps(sql, source, on_maps, on_error, on_empty)
  sql_conn.run(source.conn, source.db, sql, function(output)
    local ok, decoded_or_err = sql_conn.decode_first_result(output)
    if not ok then
      if on_error then on_error(decoded_or_err) end
      return
    end
    local r = decoded_or_err
    if not r.columns or not r.rows or #r.rows == 0 then
      if on_empty then on_empty() end
      return
    end
    on_maps(M.result_to_maps(r))
  end, on_error)
end

--- Enumerate copyable objects of a source database.
---@param source table {conn, db, dialect, schema?} (schema narrows PG listing)
---@param on_done function(objects, triggers, routines)
---   objects: { {kind="table"|"view", name, schema, conn, db, dialect} }
---   triggers: parsed rows ready for compose_trigger_sql()
---   routines: { {name, rtype, conn, db, dialect} }
---@param on_error function(string)
function M.enumerate(source, on_done, on_error)
  local obj_sql = M.list_objects_sql(source.dialect)
  if not obj_sql then
    on_error("Unsupported dialect for copy: " .. tostring(source.dialect))
    return
  end

  local pending = 3
  local finished = false
  local objects, triggers, routines = {}, {}, {}

  local function fail(msg)
    if finished then return end
    finished = true
    on_error(msg)
  end

  local function step()
    if finished then return end
    pending = pending - 1
    if pending == 0 then
      finished = true
      on_done(objects, triggers, routines)
    end
  end

  run_maps(obj_sql, source, function(maps)
    for _, m in ipairs(maps) do
      if not source.schema or m.table_schema == vim.NIL or m.table_schema == source.schema then
        table.insert(objects, {
          kind = (m.type == "VIEW") and "view" or "table",
          name = m.name,
          schema = (m.table_schema ~= vim.NIL) and m.table_schema or nil,
          conn = source.conn,
          db = source.db,
          dialect = source.dialect,
        })
      end
    end
    -- Tables first (views may depend on them), names alphabetical.
    table.sort(objects, function(a, b)
      if a.kind ~= b.kind then return a.kind == "table" end
      return a.name < b.name
    end)
    step()
  end, fail, step)

  local trg_sql = M.trigger_defs_sql(source.dialect)
  if not trg_sql then
    step()
  else
    run_maps(trg_sql, source, function(maps)
      triggers = maps
      step()
    end, fail, step)
  end

  local rtn_sql = M.routine_names_sql(source.dialect)
  if not rtn_sql then
    step()
  else
    run_maps(rtn_sql, source, function(maps)
      for _, m in ipairs(maps) do
        table.insert(routines, {
          name = m.name,
          rtype = (m.rtype ~= vim.NIL) and m.rtype or "FUNCTION",
          conn = source.conn,
          db = source.db,
          dialect = source.dialect,
        })
      end
      step()
    end, fail, step)
  end
end

--- Byte-size estimate map for a source database. Tolerant: errors yield an
--- empty map rather than failing the whole paste.
---@param source table {conn, db, dialect}
---@param on_done function(map, ok) map keyed by name / "schema.name"
function M.sizes(source, on_done)
  local sql = M.sizes_sql(source.dialect)
  if not sql then on_done({}, false) return end
  run_maps(sql, source, function(maps)
    local map = {}
    for _, m in ipairs(maps) do
      if m.name then
        map[m.name] = tonumber(m.bytes) or m.bytes
        if m.schema and m.schema ~= vim.NIL then
          map[m.schema .. "." .. m.name] = tonumber(m.bytes) or m.bytes
        end
      end
    end
    on_done(map, next(map) ~= nil)
  end, function() on_done({}, false) end, function() on_done({}, false) end)
end

--- Fetch a view's SELECT body (no CREATE header) so the paste engine can
--- recompose it under any target name.
---@param source table {conn, db, dialect, name, [schema]}
---@param on_done function(body|nil, err|nil)
function M.fetch_view_definition(source, on_done)
  local sql = M.view_definition_sql(source.dialect, source.name, source.schema)
  if not sql then on_done(nil, "unsupported dialect"); return end
  run_maps(sql, source, function(maps)
    local m = maps[1]
    if not m then on_done(nil, "empty view definition"); return end
    local raw = m.body
    if raw == nil or raw == vim.NIL then
      -- SHOW CREATE VIEW returns its text under a driver-chosen key such as
      -- "Create View"; locate it defensively.
      raw = find_column_starting_with(m, "create ")
    end
    if raw == nil or raw == vim.NIL then
      on_done(nil, "empty view definition")
      return
    end
    on_done(M.view_body_from_ddl(tostring(raw)))
  end, function(err) on_done(nil, err) end, function() on_done(nil, "view not found") end)
end

--- Fetch a routine's full CREATE statement.
---@param source table {conn, db, dialect, name, rtype, [schema]}
---@param on_done function(text|nil, err|nil)
function M.fetch_routine_definition(source, on_done)
  local sql = M.routine_def_sql(source.dialect, source.name, source.rtype, source.schema)
  if not sql then on_done(nil, "unsupported dialect"); return end
  run_maps(sql, source, function(maps)
    local m = maps[1]
    if not m then on_done(nil, "routine not found"); return end
    local raw = m.def
    if raw == nil or raw == vim.NIL then
      raw = find_column_starting_with(m, "create ") -- SHOW CREATE … column
    end
    if raw == nil or raw == vim.NIL then
      on_done(nil, "routine definition not found")
      return
    end
    on_done(tostring(raw))
  end, function(err) on_done(nil, err) end, function() on_done(nil, "routine not found") end)
end

--- Exposed for tests.
M._test = { find_as_outside_quotes = find_as_outside_quotes }

return M
