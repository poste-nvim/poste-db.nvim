local types = require("poste-db.types")

local M = {}

--- The `true`/`false` spelling of a value is a boolean only in a column that
--- can hold one — MySQL spells it `tinyint(1)`/`bit(1)` — or when introspection
--- gave no type at all. Coerced anywhere else it becomes an unquoted TRUE in
--- the INSERT, which postgres rejects for a text column and MySQL answers by
--- storing `1`: the file said "true", the table holds something else.
local function takes_boolean_literal(ctype)
  if ctype == "" then return true end
  return ctype:find("bool", 1, true) ~= nil
    or ctype == "bit"
    or ctype:find("^bit%(%s*1%s*%)") ~= nil
    or ctype:find("^tinyint%(%s*1%s*%)") ~= nil
end

--- A double carries 53 bits of mantissa, so `9050341234567890123` arrives back as
--- `…889920` — the digits themselves move. Past that range the text must stay text;
--- dml then emits its exact digits rather than the corrupted number.
local MAX_EXACT_DOUBLE = 2 ^ 53

--- Significant decimal digits a double round-trips exactly. 15 is the
--- guaranteed floor (`%.17g` is where the last digit starts to wobble), and a
--- numeric column with a longer literal must reach the server as text.
local MAX_EXACT_DIGITS = 15

--- Significant decimal digits in a numeric literal: sign, decimal point and
--- leading zeros are not significant.
--- @param s string
--- @return number
local function significant_digits(s)
  local digits = s:gsub("^[%-+]", ""):gsub("%.", ""):gsub("^0+", "")
  return #digits
end

--- Whether a double keeps every digit of this literal. Two different limits:
---  * an integer literal is exact anywhere below 2^53, whatever its digit
---    count (that is what MAX_EXACT_DOUBLE checks), and
---  * a literal with a real fractional part carries at most 15 significant
---    decimal digits (`0.1234567890123456789` rounds, silently, and a
---    numeric(30,19) column accepts the rounded value).
--- @param s string
--- @return boolean
local function digits_are_exact(s)
  local frac = s:match("%.([0-9]*)$")
  if not frac or frac:match("^0*$") then return true end
  return significant_digits(s) <= MAX_EXACT_DIGITS
end

function M.coerce_value(str, col_type)
  if str == nil or str == vim.NIL then return vim.NIL end
  local s = tostring(str):gsub("^%s+", ""):gsub("%s+$", "")

  if s == "" then return nil end

  -- NULL/true/false literals match case-insensitively: CSV exports write
  -- NULL (databases), null (JSON tools), True/False (Python csv).
  local lower = s:lower()
  if lower == "null" or lower == "(null)" then return vim.NIL end

  -- ClickHouse spells a column's type through a modifier (`Nullable(Int32)`),
  -- which says nothing about what the column holds, and the checks below read
  -- the leading word — so take the modifier off first, once, here.
  local ctype = types.unwrap_modifier((col_type or ""):lower())
  if takes_boolean_literal(ctype) then
    if lower == "true" then return true end
    if lower == "false" then return false end
  end
  if ctype == "boolean" or ctype == "bool" then
    if s == "1" then return true end
    if s == "0" then return false end
  end

  -- A digit-string becomes a number only when the column holds numbers (`007`
  -- in a varchar column is the text `007`), the value fits a double, and an
  -- integer column is not being handed a fraction.
  --
  -- The digit COUNT matters as much as the magnitude: `math.abs(num) < 2^53`
  -- only guarantees exact INTEGERS, while a double carries ~15 significant
  -- decimal digits. `0.1234567890123456789` is small enough to pass the
  -- magnitude test and still gets rounded on the way to a numeric(30,19)
  -- column — silently, on a server that accepts the rounded value. Keeping the
  -- literal as text lets the database parse it at full precision.
  local num = tonumber(s)
  if num and s:match("^%-?%d+%.?%d*$")
    and types.is_numeric(ctype)
    and math.abs(num) < MAX_EXACT_DOUBLE
    and digits_are_exact(s)
    and not (types.is_integer(ctype) and num ~= math.floor(num)) then
    return num
  end

  return s
end

function M.build_column_map(parsed_cols, table_cols)
  local col_map = {}
  local unmatched_import = {}
  local matched_table = {}
  local unmatched_table = {}

  for ii, name in ipairs(parsed_cols) do
    -- Names arrive from CSV/TSV headers (always strings) and from decoded JSON
    -- keys, which a heterogeneous array can hand over as numbers. Compare as
    -- text so a non-string cannot raise "attempt to index a number value" here
    -- — the parse layer rejects that shape, this is the second line.
    local key = type(name) == "string" and name or tostring(name)
    local found = false
    for ti, tc in ipairs(table_cols) do
      if tc.name:lower() == key:lower() then
        table.insert(col_map, {
          import_idx = ii,
          import_name = name,
          table_col = tc,
          table_idx = ti,
        })
        matched_table[ti] = true
        found = true
        break
      end
    end
    if not found then
      table.insert(unmatched_import, name)
    end
  end

  for ti, tc in ipairs(table_cols) do
    if not matched_table[ti] then
      table.insert(unmatched_table, tc)
    end
  end

  return col_map, unmatched_import, unmatched_table
end

--- Lay the file's values out by *table* column position.
--- A table column the file has no value for stays absent, which is what the
--- INSERT generator reads as "omit this column" (so the default or the
--- sequence applies) — as opposed to `vim.NIL`, an explicit NULL. The row is
--- therefore deliberately sparse; there is no length to pad.
function M.build_row_values(import_row, col_map)
  local row_values = {}
  for _, mc in ipairs(col_map) do
    row_values[mc.table_idx] = import_row[mc.import_idx]
  end
  return row_values
end

function M.normalize_columns(table_cols)
  local cols = {}
  for _, tc in ipairs(table_cols) do
    table.insert(cols, {
      name = tc.name,
      type = tc.col_type,
      primary_key = tc.is_pk,
    })
  end
  return cols
end

--- Coerce every mapped cell and reject rows whose primary key came out null.
--- The table columns the file does not supply are *not* an error — they stay
--- absent and the database decides — so this needs nothing beyond `col_map`,
--- whose `table_col` entries carry the type and key information. Previewing the
--- unmatched columns is the caller's concern.
function M.validate_and_type(import_rows, col_map)
  local valid = {}
  local bad = {}

  for ri, import_row in ipairs(import_rows) do
    local row_vals = M.build_row_values(import_row, col_map)
    local row_errors = {}

    for _, mc in ipairs(col_map) do
      local raw_val = import_row[mc.import_idx]
      local coerced = M.coerce_value(raw_val, mc.table_col.col_type)
      row_vals[mc.table_idx] = coerced

      if mc.table_col.is_pk and (coerced == nil or coerced == vim.NIL) then
        if not (mc.table_col.extra and mc.table_col.extra:find("auto", 1, true)) then
          table.insert(row_errors, string.format("  %s: primary key column '%s' cannot be null",
            ri + 1, mc.table_col.name))
        end
      end
    end

    if #row_errors > 0 then
      table.insert(bad, { row_idx = ri + 1, import_row = import_row, errors = row_errors })
    else
      table.insert(valid, row_vals)
    end
  end

  return valid, bad
end

return M
