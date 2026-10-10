--- Introspection --- route resolution for table/column DDL actions.
local const = require("poste-db.constants")

local M = {}

local KEYWORDS = {
  select = true,
  from = true,
  where = true,
  join = true,
  on = true,
  ["and"] = true,
  ["or"] = true,
  set = true,
  insert = true,
  into = true,
  values = true,
  update = true,
  delete = true,
  create = true,
  modify = true,
  table = true,
  sequence = true,
  index = true,
  drop = true,
  alter = true,
  add = true,
  column = true,
  primary = true,
  key = true,
  foreign = true,
  references = true,
  ["not"] = true,
  null = true,
  default = true,
  unique = true,
  check = true,
  constraint = true,
  ["as"] = true,
  left = true,
  right = true,
  inner = true,
  outer = true,
  cross = true,
  full = true,
  order = true,
  ["by"] = true,
  group = true,
  ["having"] = true,
  limit = true,
  offset = true,
  union = true,
  ["all"] = true,
  distinct = true,
  exists = true,
  ["if"] = true,
  ["in"] = true,
  like = true,
  between = true,
  ["case"] = true,
  ["when"] = true,
  ["then"] = true,
  ["else"] = true,
  ["end"] = true,
  count = true,
  sum = true,
  avg = true,
  min = true,
  max = true,
  ["true"] = true,
  ["false"] = true,
}

function M.is_sql_keyword(word)
  if not word or word == "" then return false end
  return KEYWORDS[word:lower()] == true
end

function M.resolve_table_ddl_entry(line_text)
  local db_name = const.directive_value(line_text, const.DIRECTIVE_DATABASE)
  if db_name then
    return { kind = "database", db_name = db_name }
  end

  local conn_name = const.directive_value(line_text, const.DIRECTIVE_CONNECTION)
  if conn_name then
    return { kind = "connection", conn_name = conn_name }
  end

  return nil
end

return M
