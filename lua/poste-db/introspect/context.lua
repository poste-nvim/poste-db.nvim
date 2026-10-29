--- Introspection --- context resolver for connection/database fallback.
local util = require("poste-db.util")

local M = {}

local SKIP_KEYWORDS = {
  ["if"] = true, ["exists"] = true, ["else"] = true, ["then"] = true,
  ["when"] = true, ["case"] = true, ["end"] = true,
}

local function pick_table_match(parsed_tables, word_lower)
  local matched = nil
  local schema_matched = nil
  for _, t in ipairs(parsed_tables or {}) do
    local tn = util.unquote_ident(t.name):lower()
    local ta = util.unquote_ident(t.alias):lower()
    local ts = t.schema and t.schema:lower() or ""
    if tn == word_lower and not SKIP_KEYWORDS[tn] then
      matched = t
      break
    end
    if ta == word_lower and not SKIP_KEYWORDS[ta] then
      matched = t
      break
    end
    if ts == word_lower then
      schema_matched = t
    end
  end
  return matched, schema_matched
end

function M.resolve_detected_target(parsed, cword, db, after_dot_col)
  if not parsed then return nil end

  local ct = parsed.ctx_type
  local tables = parsed.tables
  local cword_lower = (cword or ""):lower()

  if ct == "dot_column" and parsed.ctx_data then
    local prefix = parsed.ctx_data
    local parent_table = nil
    local parent_schema = nil
    if tables then
      for _, t in ipairs(tables) do
        if t.alias and t.alias:lower() == prefix:lower() then
          parent_table = util.unquote_ident(t.name)
          parent_schema = t.schema
          break
        end
      end
    end
    if parent_table then
      return {
        kind = "column",
        db = db,
        parent_table = parent_table,
        parent_schema = parent_schema,
        column_name = after_dot_col or cword,
      }
    end
    return nil
  end

  if ct == "schema_table" and parsed.ctx_data then
    local schema = parsed.ctx_data or ""
    -- The schema rides on `schema`, NOT folded into `db`: for postgres a
    -- schema is not a database, and the old fold repointed the connection at
    -- a database named like the schema ("database app does not exist").
    -- mysql/mariadb keep the fold at the argv layer, where database==schema.
    return {
      kind = "ddl",
      db = db,
      schema = schema ~= "" and schema or nil,
      table_name = cword,
    }
  end

  if ct == "table" and tables and #tables > 0 then
    local matched, schema_matched = pick_table_match(tables, cword_lower)
    if schema_matched then
      return {
        kind = "list_tables",
        db = cword,
      }
    end
    if matched then
      local ts = matched.schema or ""
      return {
        kind = "ddl",
        db = db,
        schema = ts ~= "" and ts or nil,
        table_name = matched.name or matched.alias or cword,
      }
    end
    if not SKIP_KEYWORDS[cword_lower] then
      return {
        kind = "ddl",
        db = db,
        table_name = cword,
      }
    end
    return nil
  end

  if ct == "column" or ct == "keyword" then
    local is_table = false
    local schema_match = nil
    for _, t in ipairs(tables or {}) do
      local tn = util.unquote_ident(t.name):lower()
      local ta = util.unquote_ident(t.alias):lower()
      local ts = t.schema and t.schema:lower() or ""
      if (tn == cword_lower or ta == cword_lower) and not SKIP_KEYWORDS[tn] then
        is_table = true
        break
      end
      if ts == cword_lower then
        schema_match = t
      end
    end
    if schema_match then
      return {
        kind = "ddl",
        db = db,
        schema = cword,
        table_name = schema_match.name,
      }
    end
    if not is_table and tables and #tables > 0
      and not SKIP_KEYWORDS[util.unquote_ident(tables[1].name):lower()] then
      return {
        kind = "column",
        db = db,
        parent_table = util.unquote_ident(tables[1].name or tables[1].alias),
        parent_schema = tables[1].schema,
        column_name = cword,
      }
    end
  end

  return nil
end

return M
