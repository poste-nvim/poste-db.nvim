--- Introspection --- target resolver: map table/column names to DDL targets.
local M = {}

function M.resolve_directive_action(entry)
  if not entry then return nil end
  if entry.kind == "database" then
    return { kind = "database", db_name = entry.db_name }
  end
  if entry.kind == "connection" then
    return { kind = "connection", conn_name = entry.conn_name }
  end
  return nil
end

function M.resolve_detected_action(target, db, _cword)
  if not target then return nil end

  if target.kind == "list_tables" and target.db then
    return { kind = "list_tables", db = target.db }
  end

  if target.kind == "column" and target.parent_table and target.parent_table:lower() ~= target.column_name:lower() then
    return {
      kind = "column",
      db = target.db or db,
      parent_table = target.parent_table,
      parent_schema = target.parent_schema,
      column_name = target.column_name,
    }
  end

  if target.kind == "ddl" and target.table_name then
    return {
      kind = "ddl",
      db = target.db or db,
      schema = target.schema,
      table_name = target.table_name,
    }
  end

  return nil
end

return M
