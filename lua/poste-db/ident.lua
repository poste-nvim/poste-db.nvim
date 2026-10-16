local M = {}

--- Read `name` as an identifier's text. Absent (nil, or a decoded JSON null —
--- the truthy `vim.NIL`) yields nil; anything else that is not already a
--- string is spelled out, so a name that arrived as a number still quotes.
---
--- The primitive used to raise on a non-string (`name:gsub` on a userdata) and
--- every caller had to remember `util.named` first — see the note on
--- `ops_sql.qualified_table_ref`, which lists the raise as the bug it fixed at
--- the CALLER. Quoting is not the place to invent a name, but it is also not
--- the place to take the menu action down.
local function as_name(name)
  if type(name) == "string" then return name end
  if name == nil or name == vim.NIL then return nil end
  return tostring(name)
end

--- One identifier, in the dialect's own quoting, with nothing left to split.
local function quote_one(name, dialect)
  if dialect == "mysql" or dialect == "mariadb" or dialect == "clickhouse" then
    return "`" .. name:gsub("`", "``") .. "`"
  end
  if dialect == "mssql" then
    return "[" .. name:gsub("]", "]]") .. "]"
  end
  return '"' .. name:gsub('"', '""') .. '"'
end

--- `schema.table.col` as separate parts, or nil when the dots are not separators:
--- an empty part means the name itself contains them (`my..table`, `.hidden`,
--- `trailing.`). Splitting those would rewrite which object the SQL points at,
--- and a name with a dot in it is legal — Postgres and MySQL both accept
--- `CREATE TABLE "my..table"`, and the browser introspects such a table by its
--- exact name.
local function split_name(name)
  local parts = {}
  local prev = 1
  for i = 1, #name do
    if name:sub(i, i) == "." then
      parts[#parts + 1] = name:sub(prev, i - 1)
      prev = i + 1
    end
  end
  parts[#parts + 1] = name:sub(prev)
  if #parts < 2 then return nil end
  for _, part in ipairs(parts) do
    if part == "" then return nil end
  end
  return parts
end

--- An object the database told us about: a table, column, schema or database
--- name, taken from introspection or from a tree node. Quoted as exactly one
--- identifier. A dot is part of the name here — Postgres and MySQL both accept
--- `CREATE TABLE "staging.v1"` — and splitting it would retarget the statement
--- at a different object (`"staging"."v1"`), so an UPDATE or DROP aimed at the
--- table in front of the user would either error out or hit `v1` in `staging`.
function M.quote(name, dialect)
  name = as_name(name)
  if not name or name == "" or name == "*" then return name or "" end
  return quote_one(name, dialect)
end

--- A reference someone typed into a prompt, or that was parsed out of SQL text
--- (`schema.table`, `db.schema.table`): split on the dots and quote each part.
--- Degenerate dots stay inside the name — see `split_name`.
--- This is the only place the split belongs, and it is a judgement call: from
--- the string alone `staging.v1` (one table) and `staging.v1` (table `v1` in
--- schema `staging`) are indistinguishable. Here the caller's context says a
--- qualifier was intended, which is not true of an introspected name.
function M.quote_ref(name, dialect)
  name = as_name(name)
  if not name or name == "" or name == "*" then return name or "" end
  local parts = split_name(name)
  if not parts then return quote_one(name, dialect) end
  -- quote_one, not M.quote_ref: split_name only returns dot-free parts, so one
  -- pass is enough, and it keeps this function free of a recursion guard.
  for i, part in ipairs(parts) do
    parts[i] = quote_one(part, dialect)
  end
  return table.concat(parts, ".")
end

--- Whether `quote_ref` will split this name, i.e. whether it reads as a
--- qualified reference rather than as one name that carries dots. Callers that
--- decide "should I prepend the schema myself?" need the same answer quote_ref
--- gives — testing for a dot with `find` disagrees for `my..table`, where the
--- split does not happen but the dot check says it did, dropping the prefix.
function M.is_qualified(name)
  name = as_name(name)
  if not name or name == "" then return false end
  return split_name(name) ~= nil
end

function M.quote_qualified(schema, table_name, dialect)
  -- as_name-shaped gate, not `schema ~= ""`: a JSON null schema decodes to
  -- the truthy vim.NIL and would be joined in as the literal name "vim.NIL".
  -- An empty string is not a schema either (it is truthy).
  local s = as_name(schema)
  if s and s ~= "" then
    return M.quote(s, dialect) .. "." .. M.quote(table_name, dialect)
  end
  return M.quote(table_name, dialect)
end

--- True for the doubles `tostring` renders as words: NaN and ±infinity.
function M.is_non_finite(val)
  return type(val) == "number" and (val ~= val or val == math.huge or val == -math.huge)
end

--- `tostring(math.huge)` is "inf" and `tostring(0/0)` is "nan", which postgres
--- and MySQL read as a column reference — the statement failed with "column inf
--- does not exist". The quoted spellings below are the ones those servers parse
--- (and what postgres prints for them), so a value that arrives as the text
--- "Infinity" also leaves as one. ClickHouse spells its own literals `inf` and
--- `nan`, so it keeps what `tostring` gives.
local function non_finite_literal(val, dialect)
  if dialect == "clickhouse" then return tostring(val) end
  if val ~= val then return "'NaN'" end
  return val == math.huge and "'Infinity'" or "'-Infinity'"
end

function M.quote_literal(val, dialect)
  if val == nil or val == vim.NIL then return "NULL" end
  if type(val) == "boolean" then return val and "TRUE" or "FALSE" end
  if type(val) == "number" then
    if M.is_non_finite(val) then return non_finite_literal(val, dialect) end
    -- An integral double gets the full decimal form, NOT `tostring`. LuaJIT
    -- prints a number whose shortest round-trip needs more than ~15 significant
    -- digits in exponent form, and past 1e14 even a value that the double holds
    -- EXACTLY is rewritten by that rounding: an id `123456789012345` (15 digits,
    -- well under 2^53 so perfectly representable) came back as `1.2345678901234e+14`
    -- = 123456789012340, silently shifting the statement's key. `%.0f` emits the
    -- exact integer, so INSERT/UPDATE round-trips the value the row actually has.
    -- (Bigints above 2^53 already arrive as strings, not doubles — see
    -- `format.cell_to_string` — so they never reach this branch.) A genuinely
    -- fractional double has no integer form; keep `tostring`, whose exponent is
    -- still value-preserving.
    if val == math.floor(val) then return string.format("%.0f", val) end
    return tostring(val)
  end
  local s = tostring(val):gsub("'", "''")
  -- Backslash dialects: MySQL/MariaDB and ClickHouse both treat `\` as an
  -- escape character inside single-quoted literals — a raw `\` in the value
  -- would swallow the next char (e.g. `a\b` reads as `a` + backspace).
  if dialect == "mysql" or dialect == "mariadb" or dialect == "clickhouse" then
    s = s:gsub("\\", "\\\\")
  end
  return "'" .. s .. "'"
end

return M