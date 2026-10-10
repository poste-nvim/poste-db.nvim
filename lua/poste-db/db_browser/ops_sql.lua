--- Shared node/SQL-generation helpers for browser operations.
--- Extracted from db_browser/operations.lua so the operation modules
--- (operations, ops_drop) reuse the same implementations.
local ident = require("poste-db.ident")
local core_util = require("poste-db.util")
local notify = require("poste-db.db_browser.notify")
local util = require("poste-db.db_browser.util")

local M = {}

function M.safe_str(v)
  if v == nil or v == vim.NULL or type(v) == "userdata" then return nil end
  return tostring(v)
end

function M.get_dialect(node, context)
  return util.get_dialect(node, context and context.root_nodes or {})
end

function M.get_connection_name(node, context)
  return util.get_connection(node)
end

function M.get_search_dir(context)
  return util.get_search_dir(context and context.source_buf)
end

function M.find_table_node(context, start_idx)
  return util.find_table_node(context and context.line_to_node or {}, start_idx)
end

function M.insert_into_source(context, lines, cursor_offset, cursor_col)
  if not context.source_buf or not vim.api.nvim_buf_is_valid(context.source_buf) then
    notify.warn("No source SQL buffer found")
    return false
  end
  local line_count = vim.api.nvim_buf_line_count(context.source_buf)
  vim.api.nvim_buf_set_lines(context.source_buf, line_count, line_count, false, lines)
  local target_win = vim.fn.bufwinid(context.source_buf)
  if target_win and target_win ~= -1 then
    vim.api.nvim_set_current_win(target_win)
    if cursor_offset then
      vim.api.nvim_win_set_cursor(target_win, { line_count + cursor_offset, cursor_col or 0 })
    end
  end
  return true
end

--- Qualified, quoted table reference for generated SQL.
--- PG applies the schema prefix; other dialects quote the bare name.
---
--- `meta.schema` is a name inherited from an introspection row or a connection
--- entry, so "unusable" arrives in two shapes and both used to emit wrong SQL.
--- `""`: `ident.quote` returns an empty name unchanged, so the prefix was still
--- joined and the ref became `."users"` — the leading dot is a syntax error on
--- Postgres, which is what every generated ALTER/UPDATE/INSERT/DROP for that
--- table then reported. A JSON null decodes to `vim.NIL`, which is truthy and
--- reached `name:gsub` as a userdata (`ident.lua:11`), raising inside the menu
--- action. The hand-written `schema ~= ""` in `mssql_object_ref` was this rule,
--- half-covered.
function M.qualified_table_ref(table_node, dialect)
  local schema = core_util.named(table_node.meta and table_node.meta.schema)
  local schema_prefix = ""
  if schema and dialect == "postgres" then
    schema_prefix = ident.quote(schema, dialect) .. "."
  end
  return schema_prefix .. ident.quote(table_node.name, dialect)
end

--- `ALTER TABLE … ADD COLUMN`, spelled once.
---
--- Both generators used to re-spell this inline and had drifted: the browser
--- form dropped the SQLite caveat (and rebuilt the identical string a second
--- time inside a `dialect == "mysql"` branch that changed nothing), while the
--- prompt flow kept it. The refs arrive pre-quoted so the browser can pass a
--- schema-qualified table (see `qualified_table_ref`) — a bare name there made
--- the generated ALTER depend on the session search_path.
--- @param table_ref string
--- @param col_ref string
--- @return string[] the statement, plus a caveat line where the server rejects it
function M.add_column_sql(table_ref, col_ref, col_type, nullable, default_val, dialect)
  local has_default = default_val ~= nil and default_val ~= ""
  local sql = "ALTER TABLE " .. table_ref .. " ADD COLUMN " .. col_ref .. " " .. col_type
  if not nullable then sql = sql .. " NOT NULL" end
  if has_default then sql = sql .. " DEFAULT " .. default_val end
  local lines = { sql .. ";" }
  -- SQLite rejects a NOT NULL added column without a DEFAULT: existing rows
  -- have no value to materialize for it.
  if dialect == "sqlite" and not nullable and not has_default then
    table.insert(lines, "-- SQLite: a NOT NULL added column requires a DEFAULT; add one above.")
  end
  return lines
end

--- `SELECT *` with a row cap, spelled for the dialect. T-SQL has no LIMIT
--- clause — the count goes in front as TOP.
function M.select_star_sql(table_ref, dialect, count)
  count = count or 100
  if dialect == "mssql" then
    return string.format("SELECT TOP %d * FROM %s;", count, table_ref)
  end
  return string.format("SELECT * FROM %s LIMIT %d;", table_ref, count)
end

--- T-SQL has no RENAME TO / RENAME COLUMN. `sp_rename` takes its arguments as
--- string literals, so names are unquoted there (apostrophes doubled via
--- quote_literal) rather than bracket-quoted identifiers.
local function sp_rename(old_ref, new_name, object_kind)
  local lit = function(s) return ident.quote_literal(tostring(s), "mssql") end
  local stmt = "EXEC sp_rename " .. lit(old_ref) .. ", " .. lit(new_name)
  if object_kind then stmt = stmt .. ", " .. lit(object_kind) end
  return stmt .. ";"
end

--- `schema.table` (or a bare table) as sp_rename wants it: plain names.
local function mssql_object_ref(node)
  local schema = core_util.named(node.meta and node.meta.schema)
  if schema then return schema .. "." .. node.name end
  return node.name
end

--- Rename DDL for a table node, spelled for the dialect.
--- The target is schema-qualified where the dialect resolves names that way
--- (postgres); the new name stays bare — a rename does not move the table.
function M.rename_table_sql(node, new_name, dialect)
  if dialect == "mssql" then
    return sp_rename(mssql_object_ref(node), new_name, nil)
  end
  if dialect == "mysql" then
    return "RENAME TABLE " .. M.qualified_table_ref(node, dialect)
      .. " TO " .. ident.quote(new_name, dialect) .. ";"
  end
  return "ALTER TABLE " .. M.qualified_table_ref(node, dialect)
    .. " RENAME TO " .. ident.quote(new_name, dialect) .. ";"
end

--- Rename DDL for a column node, spelled for the dialect.
function M.rename_column_sql(table_node, col_node, new_name, dialect)
  if dialect == "mssql" then
    return sp_rename(mssql_object_ref(table_node) .. "." .. col_node.name, new_name, "COLUMN")
  end
  local table_ref = M.qualified_table_ref(table_node, dialect)
  if dialect == "mysql" then
    local col_type = col_node.meta and col_node.meta.col_type or "TEXT"
    return "ALTER TABLE " .. table_ref
      .. " CHANGE COLUMN " .. ident.quote(col_node.name, dialect)
      .. " " .. ident.quote(new_name, dialect) .. " " .. col_type .. ";"
  end
  return "ALTER TABLE " .. table_ref
    .. " RENAME COLUMN " .. ident.quote(col_node.name, dialect)
    .. " TO " .. ident.quote(new_name, dialect) .. ";"
end

--- Directive header (`-- @connection` / `-- @database`) for generated SQL.
--- Returns the lines and the cursor offset relative to the first inserted line.
---
--- A directive with no value declares nothing — `constants.directive_value`
--- answers nil for the blank after `-- @database ` — so the line is noise in the
--- buffer the user has to delete by hand, and the file reads as if it had a
--- target when it has none. Emit the line only when it carries a name; the
--- offset counts the lines actually inserted, which is what keeps the cursor on
--- the statement. A JSON null name used to reach the concat and raise.
function M.build_directive_lines(table_node, conn)
  local lines = { "" }
  local cursor_offset = 2
  local connection = core_util.named(conn)
  if connection then
    table.insert(lines, "-- @connection " .. connection)
    cursor_offset = cursor_offset + 1
  end
  local database = core_util.named(table_node.meta and table_node.meta.database)
  if database then
    table.insert(lines, "-- @database " .. database)
    cursor_offset = cursor_offset + 1
  end
  return lines, cursor_offset
end

--- Build ALTER COLUMN migration statements for a modified column.
--- Spellings are per dialect (mirrors table_ops.gen_alter_type): postgres
--- `ALTER COLUMN c TYPE t`, mysql/clickhouse `MODIFY COLUMN`, mssql bare
--- `ALTER COLUMN c t` (no TYPE keyword, no inline DEFAULT), sqlite cannot
--- alter types in place at all. The table reference is schema-qualified
--- where the dialect resolves it (postgres) so the generated SQL does not
--- depend on the session search_path.
--- @param table_node table  the parent table node
--- @param node table  the column node being modified
--- @param values { col_type: string, nullable: boolean, default_val: string|nil, comment_val: string|nil }
--- @param dialect string
--- @return string[]  SQL lines (leading blank / trailing blank added by callers)
function M.build_alter_column_sql(table_node, node, values, dialect)
  local col_type = values.col_type
  local nullable = values.nullable
  local default_val = values.default_val
  local comment_val = values.comment_val
  local col_ref = ident.quote(node.name, dialect)
  local table_ref = M.qualified_table_ref(table_node, dialect)

  if dialect == "postgres" then
    local lines = { "ALTER TABLE " .. table_ref .. " ALTER COLUMN " .. col_ref .. " TYPE " .. col_type .. ";" }
    if not nullable then
      table.insert(lines, "ALTER TABLE " .. table_ref .. " ALTER COLUMN " .. col_ref .. " SET NOT NULL;")
    end
    if default_val ~= nil and default_val ~= "" then
      table.insert(lines, "ALTER TABLE " .. table_ref .. " ALTER COLUMN " .. col_ref .. " SET DEFAULT " .. default_val .. ";")
    elseif default_val == "" then
      table.insert(lines, "ALTER TABLE " .. table_ref .. " ALTER COLUMN " .. col_ref .. " SET DEFAULT '';")
    end
    if comment_val ~= nil and comment_val ~= "" then
      table.insert(lines, "COMMENT ON COLUMN " .. table_ref .. "." .. col_ref .. " IS '" .. tostring(comment_val):gsub("'", "''") .. "';")
    end
    return lines
  elseif dialect == "mysql" or dialect == "mariadb" then
    local parts = { "ALTER TABLE " .. table_ref .. " MODIFY COLUMN " .. col_ref .. " " .. col_type }
    if not nullable then table.insert(parts, " NOT NULL") end
    if default_val ~= nil and default_val ~= "" then table.insert(parts, " DEFAULT " .. default_val)
    elseif default_val == "" then table.insert(parts, " DEFAULT ''") end
    if comment_val ~= nil and comment_val ~= "" then
      table.insert(parts, " COMMENT '" .. tostring(comment_val):gsub("'", "''") .. "'")
    end
    table.insert(parts, ";")
    return { table.concat(parts, "") }
  elseif dialect == "clickhouse" then
    local lines = { "ALTER TABLE " .. table_ref .. " MODIFY COLUMN " .. col_ref .. " " .. col_type .. ";" }
    if comment_val ~= nil and comment_val ~= "" then
      table.insert(lines, "ALTER TABLE " .. table_ref .. " COMMENT COLUMN " .. col_ref .. " '" .. tostring(comment_val):gsub("'", "''") .. "';")
    end
    return lines
  elseif dialect == "mssql" then
    local stmt = "ALTER TABLE " .. table_ref .. " ALTER COLUMN " .. col_ref .. " " .. col_type
    if not nullable then stmt = stmt .. " NOT NULL" end
    local lines = { stmt .. ";" }
    if default_val ~= nil and default_val ~= "" then
      -- MSSQL cannot add a DEFAULT inline in ALTER COLUMN (that spelling
      -- binds only to new columns); it needs a named constraint.
      table.insert(lines, "-- DEFAULT needs a separate named constraint:")
      table.insert(lines, "-- ALTER TABLE " .. table_ref .. " ADD CONSTRAINT DF_" .. node.name
        .. " DEFAULT " .. default_val .. " FOR " .. col_ref .. ";")
    end
    return lines
  elseif dialect == "sqlite" then
    return {
      "-- SQLite does not support ALTER COLUMN TYPE directly.",
      "-- Recreate " .. table_node.name .. " to change " .. node.name .. " to " .. col_type .. ".",
    }
  else
    -- Unknown dialect: keep the postgres-like spelling (same default as
    -- table_ops.gen_alter_type).
    local parts = { "ALTER TABLE " .. table_ref .. " ALTER COLUMN " .. col_ref .. " TYPE " .. col_type }
    if not nullable then table.insert(parts, " NOT NULL") end
    if default_val ~= nil and default_val ~= "" then table.insert(parts, " DEFAULT " .. default_val)
    elseif default_val == "" then table.insert(parts, " DEFAULT ''") end
    table.insert(parts, ";")
    return { table.concat(parts, "") }
  end
end

--- Get column names/types from a table node (must be expanded).
function M.get_columns_from_node(table_node)
  if not table_node.children or #table_node.children == 0 then return nil end
  local cols = {}
  for _, child in ipairs(table_node.children) do
    if child.node_type == "column" then
      table.insert(cols, {
        name = child.name,
        col_type = child.meta and child.meta.col_type or "TEXT",
        is_pk = child.meta and child.meta.is_pk or false,
        nullable = child.meta and child.meta.nullable ~= false,
      })
    end
  end
  if #cols == 0 then return nil end
  return cols
end

return M
