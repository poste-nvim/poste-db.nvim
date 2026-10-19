local M = {}
local ident = require("poste-db.ident")
local types = require("poste-db.types")

local function quote_schema(schema, dialect)
  if not schema or schema == "" then return "" end
  return ident.quote(schema, dialect) .. "."
end

--- A numeric-looking cell can be a number (`2084515900853196878`) or text
--- that merely looks numeric (`007`, `1.50`). Only the former may go out bare:
--- a leading zero or a trailing fraction zero would change the stored value,
--- so those stay string literals.
local function bare_numeric_literal(s)
  return s:match("^%-?0$") ~= nil
    or s:match("^%-?[1-9]%d*$") ~= nil
    or s:match("^%-?%d+%.%d*[1-9]$") ~= nil
end

--- quote a value as a SQL literal. `allow_expr` opens the `__expr:` escape
--- hatch (the value is emitted as RAW SQL). That hatch is an EDITOR feature
--- — the user typed it deliberately into the cell editor — so it defaults to
--- FALSE: imported CSV/JSON cells starting with `__expr:` must become plain
--- string literals, never executed SQL (a CSV cell is untrusted input).
--- `col_type` is the column the value is going into, when the caller knows it:
--- a digit string in a text column is the characters, not a number.
local function quote_val(val, dialect, allow_expr, col_type)
  if val == nil or val == vim.NIL then
    return "NULL"
  end
  if type(val) == "string" and allow_expr then
    local expr = val:match("^__expr:(.*)$")
    if expr then return expr end
  end
  if type(val) == "boolean" then
    return val and "TRUE" or "FALSE"
  end
  if type(val) == "number" then
    -- Checked before the integral branch: `math.floor(inf) == inf` is true, so
    -- an infinite value would take the `%.0f` path and come out as the word
    -- "inf", which the servers read as a column name.
    if ident.is_non_finite(val) then return ident.quote_literal(val, dialect) end
    if val == math.floor(val) then
      -- %.0f, not %d: LuaJIT clamps %d to int64 range, so a big float cell
      -- (1e20) would silently rewrite itself to 9223372036854775807.
      return string.format("%.0f", val)
    end
    return tostring(val)
  end
  if type(val) == "string" then
    local num = tonumber(val)
    if num and val:match("^%-?%d+%.?%d*$") then
      if not types.is_numeric(types.unwrap_modifier((col_type or ""):lower())) then
        -- The column holds text, so the digits are the data. Written bare this
        -- is an integer literal, which postgres rejects for a text column and
        -- the other servers answer by storing something else.
        return ident.quote_literal(val, dialect)
      end
      local round_trip = num == math.floor(num) and string.format("%.0f", num) or tostring(num)
      if round_trip ~= val then
        -- the double cannot hold this text (a bigint) — emit the exact digits
        -- when they are a plain literal, otherwise it is text
        if bare_numeric_literal(val) then return val end
        return ident.quote_literal(val, dialect)
      end
      -- round_trip == val: the text already is the exact literal — return it
      -- verbatim rather than %d, which LuaJIT clamps to int64 (a uint64
      -- above 2^63-1 came back as 9223372036854775807).
      return val
    end
    if dialect == "mysql" or dialect == "mariadb" then
      -- The T→space rewrite exists because a DATETIME cell arrives from the
      -- binary as `2024-01-01T10:00:00Z` while MySQL stores
      -- `2024-01-01 10:00:00` — a round-trip for the column's own spelling.
      -- It must not touch a text column: a VARCHAR the user committed verbatim
      -- came out with the `T` rewritten (and the WHERE rewritten the same way,
      -- so the statement stopped matching the row it named). An unknown type
      -- keeps the rewrite: callers that carry no metadata keep the old,
      -- permissive round-trip.
      local ct = types.unwrap_modifier((col_type or ""):lower())
      if ct == "" or ct:find("time", 1, true) or ct:find("date", 1, true) then
        val = val:gsub("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d:%d%d%.%d+)[%+%-]%d%d:%d%d$", "%1 %2")
        val = val:gsub("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d:%d%d)[%+%-]%d%d:%d%d$", "%1 %2")
        val = val:gsub("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d:%d%d%.%d+)Z$", "%1 %2")
        val = val:gsub("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d:%d%d)Z$", "%1 %2")
      end
    end
    return ident.quote_literal(val, dialect)
  end
  if type(val) == "table" then
    local ok, encoded = pcall(vim.json.encode, val)
    if ok then
      return ident.quote_literal(encoded, dialect)
    end
    return "NULL"
  end
  return ident.quote_literal(tostring(val), dialect)
end

--- A column's type, from whichever field its shape carries: normalized columns
--- (`import/mapping.normalize_columns`) say `type`, dataset layout columns say
--- `ctype`. Nil means the caller had no type, which keeps the older behavior.
local function col_type_of(col)
  if not col then return nil end
  return col.type or col.ctype or col.col_type
end

local function find_pk_columns(columns)
  local pks = {}
  for i, col in ipairs(columns or {}) do
    if col.primary_key then
      pks[#pks + 1] = i
    end
  end
  return pks
end

local function where_eq(col_name, val, dialect, allow_expr, col_type)
  if val == nil or val == vim.NIL then
    return ident.quote(col_name, dialect) .. " IS NULL"
  end
  return ident.quote(col_name, dialect) .. " = " .. quote_val(val, dialect, allow_expr, col_type)
end

local function build_where(columns, pk_cols, row_values, dialect)
  -- The WHERE identifies the row; its values are DATA the user never typed
  -- this commit, so the `__expr:` hatch stays closed here even when the
  -- caller opened it for SET. The pk path already passed nil explicitly; the
  -- all-columns fallback needs the same gate — a stored text value that
  -- merely starts with `__expr:` (a note documenting the feature, or a
  -- crafted `__expr:1=1 OR 1=1`) went out as raw SQL, and the OR form made
  -- the WHERE true for every row: one cell edit rewrote the whole table.
  if #pk_cols > 0 then
    local parts = {}
    for _, ci in ipairs(pk_cols) do
      local col = columns[ci]
      local val = row_values[ci]
      parts[#parts + 1] = where_eq(col.name, val, dialect, nil, col_type_of(col))
    end
    return table.concat(parts, " AND ")
  end
  local parts = {}
  for i, col in ipairs(columns or {}) do
    local val = row_values[i]
    if val ~= nil and val ~= vim.NIL then
      parts[#parts + 1] = where_eq(col.name, val, dialect, nil, col_type_of(col))
    end
  end
  return table.concat(parts, " AND ")
end

--- Generate one UPDATE statement.
--- @param allow_expr boolean|nil honor `__expr:` values as raw SQL (editor
---   edits only; imports pass nil so a crafted cell cannot inject SQL)
--- @return string|nil sql nil when no safe statement can be generated
--- @return string|nil err why generation was refused
function M.generate_update(schema, table_name, columns, modifications, row_values, dialect, allow_expr)
  local set_parts = {}
  for _, mod in ipairs(modifications or {}) do
    local col = columns and columns[mod.col]
    if col then
      set_parts[#set_parts + 1] = ident.quote(col.name, dialect)
        .. " = " .. quote_val(mod.new_val, dialect, allow_expr, col_type_of(col))
    end
  end
  if #set_parts == 0 then
    return nil, "no settable columns"
  end

  local where = ""
  if row_values then
    local pk_cols = find_pk_columns(columns)
    where = build_where(columns, pk_cols, row_values, dialect)
  end
  -- A missing WHERE target means a WHERE-less UPDATE — a full-table rewrite.
  -- Refuse instead: an all-NULL row (no PK, nothing to match on) cannot be
  -- addressed safely.
  if where == "" then
    return nil, "no WHERE target (no primary key and no non-NULL column values)"
  end

  local sql = "UPDATE " .. quote_schema(schema, dialect) .. ident.quote(table_name, dialect)
    .. " SET " .. table.concat(set_parts, ", ")
    .. " WHERE " .. where
  return sql .. ";"
end

--- @param allow_expr boolean|nil honor `__expr:` values as raw SQL (editor
---   edits only; imports pass nil so a crafted cell cannot inject SQL)
--- @return string|nil sql nil when no dialect-legal statement can be generated
--- @return string|nil err why generation was refused
function M.generate_insert(schema, table_name, columns, row_values, dialect, allow_expr)
  local col_parts = {}
  local val_parts = {}

  for i, col in ipairs(columns or {}) do
    local val = row_values and row_values[i]
    if val ~= "[Auto]" and val ~= nil then
      col_parts[#col_parts + 1] = ident.quote(col.name, dialect)
      val_parts[#val_parts + 1] = quote_val(val, dialect, allow_expr, col_type_of(col))
    end
  end

  -- Every cell skipped (nil or "[Auto]"): the row asked for nothing but the
  -- columns' defaults, which still needs a dialect-legal spelling. The bare
  -- `INSERT INTO t () VALUES ();` this used to emit unconditionally is a
  -- syntax error on every engine but MySQL's, so the commit surfaced a raw
  -- server error for a row the user added and never filled.
  if #col_parts == 0 then
    local target = "INSERT INTO " .. quote_schema(schema, dialect)
      .. ident.quote(table_name, dialect)
    if dialect == "mysql" or dialect == "mariadb" then
      return target .. " () VALUES ();"
    end
    if dialect == "postgres" or dialect == "sqlite" or dialect == "mssql" then
      return target .. " DEFAULT VALUES;"
    end
    -- ClickHouse has no default-values INSERT form at all; a refusal names
    -- the gap instead of a server syntax error.
    return nil, "every cell is empty or [Auto] — fill at least one cell to insert"
  end

  return "INSERT INTO " .. quote_schema(schema, dialect) .. ident.quote(table_name, dialect)
    .. " (" .. table.concat(col_parts, ", ") .. ")"
    .. " VALUES (" .. table.concat(val_parts, ", ") .. ");"
end

--- Generate one DELETE statement.
--- @return string|nil sql nil when no safe WHERE target exists
--- @return string|nil err why generation was refused
function M.generate_delete(schema, table_name, columns, row_values, dialect)
  local pk_cols = find_pk_columns(columns)
  local where = build_where(columns, pk_cols, row_values or {}, dialect)
  if where == "" then
    -- previously produced a broken `WHERE ;` (syntax error); a silent
    -- WHERE-less DELETE would be a full-table wipe, so refuse outright
    return nil, "no WHERE target (no primary key and no non-NULL column values)"
  end
  return "DELETE FROM " .. quote_schema(schema, dialect) .. ident.quote(table_name, dialect)
    .. " WHERE " .. where .. ";"
end

--- Generate the DML statements for pending dataset edits.
--- @param es table edit_state
--- @param tab table Tab state (layout.columns / rows_source)
--- @param dialect string
--- @return table stmts { { sql, type } }
--- @return string[] skipped human-readable reasons for refused statements
function M.generate_dml(es, tab, dialect)
  local stmts = {}
  local skipped = {}
  if not tab or not tab.layout then return stmts, skipped end

  local columns = tab.layout.columns
  local rows_source = tab.rows_source
  if not columns or not rows_source then return stmts, skipped end

  local schema = tab.layout.schema or ""
  local table_name = tab.layout.table_name or ""

  -- No table name means the dataset never resolved one. The browser always knows
  -- the node it opened, so this is the buffer path, where the name comes from
  -- reading the SQL text and a JOIN, a subquery or `FROM a, b` resolves to no
  -- single table. Generating anyway produced `UPDATE "public". SET …`:
  -- `ident.quote("")` is `""`, so the schema prefix was left with a dangling dot,
  -- and the server answered with a syntax error for every row in the batch.
  if table_name == "" then
    if next(es.modified_cells or {}) or next(es.deleted_rows or {})
      or #(es.added_rows or {}) > 0 then
      return stmts, { "no table name for this result set — it came from SQL that "
        .. "does not resolve to one table; open the table in the database browser "
        .. "to edit its rows" }
    end
    return stmts, skipped
  end

  local row_mods = {}
  for row_key, mod in pairs(es.modified_cells or {}) do
    local row_idx = tonumber(row_key:match("^(%d+):"))
    if row_idx then
      row_mods[row_idx] = row_mods[row_idx] or {}
      row_mods[row_idx][#row_mods[row_idx] + 1] = mod
    end
  end

  -- Sorted row order: the batch is replayable and the SQL log stable;
  -- pairs() would emit a different statement order per commit.
  local mod_rows = {}
  for row_idx in pairs(row_mods) do mod_rows[#mod_rows + 1] = row_idx end
  table.sort(mod_rows)
  for _, row_idx in ipairs(mod_rows) do
    local mods = row_mods[row_idx]
    -- A row that is not a sequence of cells (a malformed or hand-built
    -- response — the render path shows it as empty cells) has no original
    -- values to build a WHERE from: skip it with a reason instead of raising
    -- mid-commit, which would drop the REST of the batch with it.
    if row_idx <= #rows_source and type(rows_source[row_idx]) == "table" then
      table.sort(mods, function(a, b) return a.col < b.col end) -- stable SET order
      local original_row = {}
      for i = 1, #columns do
        original_row[i] = rows_source[row_idx][i]
      end
      for _, mod in ipairs(mods) do
        original_row[mod.col] = mod.old_val
      end
      local sql, err = M.generate_update(schema, table_name, columns, mods, original_row, dialect, true)
      if sql then
        stmts[#stmts + 1] = { sql = sql, type = "update" }
      else
        skipped[#skipped + 1] = ("update row %d skipped: %s"):format(row_idx, err)
      end
    elseif row_idx <= #rows_source then
      skipped[#skipped + 1] = ("update row %d skipped: row is not tabular data"):format(row_idx)
    end
  end

  local del_rows = {}
  for row_idx in pairs(es.deleted_rows or {}) do del_rows[#del_rows + 1] = row_idx end
  table.sort(del_rows)
  for _, row_idx in ipairs(del_rows) do
    if row_idx <= #rows_source and type(rows_source[row_idx]) == "table" then
      local sql, err = M.generate_delete(schema, table_name, columns, rows_source[row_idx], dialect)
      if sql then
        stmts[#stmts + 1] = { sql = sql, type = "delete" }
      else
        skipped[#skipped + 1] = ("delete row %d skipped: %s"):format(row_idx, err)
      end
    elseif row_idx <= #rows_source then
      skipped[#skipped + 1] = ("delete row %d skipped: row is not tabular data"):format(row_idx)
    end
  end

  for _, added in ipairs(es.added_rows or {}) do
    local row_values
    if added.row_idx and tab.layout.rows and tab.layout.rows[added.row_idx] then
      row_values = tab.layout.rows[added.row_idx]
    else
      row_values = added.data
    end
    local sql, err = M.generate_insert(schema, table_name, columns, row_values, dialect, true)
    if sql then
      stmts[#stmts + 1] = { sql = sql, type = "insert" }
    else
      -- generate_insert refuses the all-empty row; surfacing the reason beats
      -- a `{ sql = nil }` statement the executor would trip over.
      skipped[#skipped + 1] = ("insert%s skipped: %s"):format(
        added.row_idx and (" row %d"):format(added.row_idx) or "", err)
    end
  end

  return stmts, skipped
end

return M
