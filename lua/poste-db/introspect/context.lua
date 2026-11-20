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

local function split_qualified_ident(token)
  local qualifier, name = token:match("^(.*)%.([^.]+)$")
  if qualifier and qualifier ~= "" then
    return util.unquote_ident(qualifier), util.unquote_ident(name)
  end
  return nil, util.unquote_ident(token)
end

--- Resolve the source table of a MySQL/MariaDB `CREATE TABLE ... LIKE`
--- statement when the cursor is on that source name. The Rust context detector
--- sees the destination table plus a keyword context and would otherwise report
--- the source as a column of the destination.
--- @param sql_text string current `###` block text
--- @param offset number 0-based byte offset of the source word's end
--- @param cword string word under the cursor
--- @param db string|nil current database
--- @return table|nil DDL target
function M.resolve_create_table_like_source(sql_text, offset, cword, db)
  if type(sql_text) ~= "string" or type(offset) ~= "number" then return nil end
  offset = math.max(0, math.min(offset, #sql_text - 1))

  -- Only inspect the statement containing the cursor. The source table is the
  -- last token before the cursor, so a previous statement's LIKE cannot leak in.
  local stop = offset + 1
  local closing = sql_text:sub(stop + 1, stop + 1)
  if closing == "`" or closing == '"' then stop = stop + 1 end
  local before = sql_text:sub(1, stop)
  local stmt_start = 1
  for pos in before:gmatch("()%;") do stmt_start = pos + 1 end
  local stmt = before:sub(stmt_start):match("^%s*(.-)%s*$")
  if not stmt or stmt == "" then return nil end

  local upper = stmt:upper()
  local pos = 1
  local function consume(pattern)
    local _, finish = upper:sub(pos):find("^" .. pattern)
    if not finish then return false end
    pos = pos + finish
    return true
  end

  if not consume("CREATE%s+") then return nil end
  consume("TEMPORARY%s+") -- optional
  if not consume("TABLE%s+") then return nil end
  consume("IF%s+NOT%s+EXISTS%s+") -- optional

  local rest = stmt:sub(pos)
  local like_start, like_end = upper:sub(pos):find("%s+LIKE%s+")
  if not like_start then return nil end

  local destination = rest:sub(1, like_start - 1):match("^%s*(.-)%s*$")
  local source = rest:sub(like_end + 1):match("^%s*(.-)%s*$")
  if not destination or not source or destination == "" or source == "" then return nil end
  if not destination:match("^[^%s;(),]+$") or not source:match("^[^%s;(),]+$") then
    return nil
  end

  local schema, table_name = split_qualified_ident(source)
  if table_name:lower() ~= util.unquote_ident(cword):lower() then return nil end

  return {
    kind = "ddl",
    db = db,
    schema = schema,
    table_name = table_name,
  }
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
      -- The argv layer wants the bare name. `pick_table_match` compared the
      -- unquoted form, but handing back `matched.name` verbatim sent
      -- `` `users` `` / `"Users"` to `poste introspect --table`, which then
      -- answered "No DDL found" for any quoted table.
      local name = util.unquote_ident(matched.name)
      if name == "" then name = util.unquote_ident(matched.alias) end
      return {
        kind = "ddl",
        db = db,
        schema = ts ~= "" and ts or nil,
        table_name = name ~= "" and name or cword,
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
      local name = util.unquote_ident(schema_match.name)
      return {
        kind = "ddl",
        db = db,
        schema = cword,
        table_name = name ~= "" and name or cword,
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
