--- Dataset cell editor — pure functions for value conversion, validation,
--- edit state tracking. No vim.ui calls (those are in nav.lua).

local ident = require("poste-db.ident")
local types = require("poste-db.types")
local lex = require("poste-db.lex")

local M = {}

---------------------------------------------------------------------------
-- Type classification helpers
---------------------------------------------------------------------------

local TYPES = {
  integer = { integer=true, int=true, bigint=true, smallint=true,
              serial=true, bigserial=true, smallserial=true },
  numeric = { integer=true, int=true, bigint=true, smallint=true, serial=true, bigserial=true, smallserial=true,
              numeric=true, decimal=true, real=true, float=true, double=true, double_precision=true },
  boolean = { boolean=true, bool=true },
  date    = { date=true, timestamp=true, timestamptz=true, datetime=true, datetime2=true, time=true },
  json    = { json=true, jsonb=true },
  uuid    = { uuid=true },
  text    = { text=true, varchar=true, char=true, character=true, character_varying=true,
              nvarchar=true, nchar=true, longtext=true, mediumtext=true, tinytext=true },
  ineditable = { binary=true, bytea=true, blob=true, varbinary=true,
                 geometry=true, geography=true, point=true, polygon=true, linestring=true, multipolygon=true,
                 inet=true, cidr=true, macaddr=true, macaddr8=true,
                 bit=true, varbit=true, interval=true,
                 tsvector=true, tsquery=true, xml=true, hstore=true,
                 array=true, range=true, multirange=true },
}

local function is_type(ctype, category)
  -- Non-string (nil from broken metadata, a number from a weird driver)
  -- classifies as false — the same answer is_json_column's guard gives —
  -- instead of crashing the caller that asked "is this editable?"
  if type(ctype) ~= "string" then return false end
  return TYPES[category] and TYPES[category][ctype:lower()] == true
end

function M.is_numeric_type(ctype) return is_type(ctype, "numeric") end
function M.is_integer_type(ctype) return is_type(ctype, "integer") end
function M.is_boolean_type(ctype) return is_type(ctype, "boolean") end
function M.is_date_type(ctype) return is_type(ctype, "date") end
function M.is_uuid_type(ctype) return is_type(ctype, "uuid") end
function M.is_text_type(ctype) return is_type(ctype, "text") end

function M.is_json_column(col_meta)
  return col_meta and col_meta.ctype and is_type(col_meta.ctype, "json")
end

function M.is_boolean_column(col_meta)
  return col_meta and col_meta.ctype and is_type(col_meta.ctype, "boolean")
end

function M.is_datetime_column(col_meta)
  return col_meta and col_meta.ctype and is_type(col_meta.ctype, "date")
end

function M.is_enum_column(col_meta)
  return col_meta and col_meta.enum_values and #col_meta.enum_values > 0 or false
end

function M.is_editable_field(col_meta)
  if not col_meta then return false end
  if col_meta.user_defined then
    return false
  end
  if col_meta.primary_key and col_meta.default then
    return true
  end
  if col_meta.primary_key then
    return false
  end
  -- Root-word read on the unwrapped name, not the exact-name table: MySQL
  -- introspection spells widths into the declaration (`varbinary(16)`,
  -- `bit(1)`) and ClickHouse wraps modifiers (`Nullable( String )`), and an
  -- exact match on those spelled a binary column editable — the text editor
  -- offered it, and the commit only failed at the server with a type error.
  -- The same root lookup validate_value already asks via `types`.
  if type(col_meta.ctype) == "string" then
    local root = types.unwrap_modifier(col_meta.ctype:lower()):match("^%a[%a_]*")
    if root and TYPES.ineditable[root] then
      return false
    end
  end
return true
end

--- True when the statement actually joins tables: the word JOIN outside
--- string literals, comments and dollar-quoted bodies, on word boundaries.
--- A bare substring find also matched column names like `join_date` and any
--- literal containing "join", which blocked cell editing with a bogus
--- multi-table warning; the gsub literal-blanker this used to sit on knew
--- nothing about comments, so a `-- join` note after the query (or a
--- `$$body$$`'s internal JOIN) blocked editing the same way.
function M.has_join(sql)
  if not sql then return false end
  -- blank_regions keeps quoted identifiers blanked here (default), so a
  -- "left join" column alias hides like a literal does
  local blanked = lex.blank_regions(sql:upper())
  -- [%w_] not %w: SQL identifiers treat _ as a word char, so the frontier
  -- must too, or JOIN_DATE still matches.
  return blanked:match("%f[%w_]JOIN%f[^%w_]") ~= nil
end

------------------------------------------------------------------------------
-- Value parsing
---------------------------------------------------------------------------

--- Can this column hold anything but the characters as typed?
--- `types.is_numeric` is the shared root-word check, so it covers the dialect
--- spellings the exact-name table below misses (`UInt64`, `numeric(10,2)`);
--- json is the other family whose cell is stored parsed, because the editor
--- shows and re-reads it as a table. No column at all answers yes: an unknown
--- target keeps the older, permissive inference every caller predating this
--- parameter relied on.
local function infers_non_text(col_meta)
  local ctype = col_meta and col_meta.ctype
  if not ctype then return true end
  ctype = ctype:lower()
  return types.is_numeric(ctype) or is_type(ctype, "json")
end

--- Parse a user input string into a typed value suitable for SQL.
--- Handles: JSON, UUID, datetime, numbers, booleans, NULL.
--- @param col_meta table|nil the column being edited, when the caller knows it.
---   Decisive for text columns: digits typed into a varchar cell are the data,
---   and inferring a number there made `validate_value` reject the edit — even
---   the no-op edit of a cell that already read "42" — so it could not be saved.
---   The DML layer has always agreed (`quote_val`'s col_type check).
function M.parse_value(input, old_val, col_meta)
  if input == "(NULL)" then return vim.NIL end
  if input == "null" or input == "NULL" then return vim.NIL end
  if input == "" then
    return old_val ~= nil and vim.NIL or nil
  end
  if input == "''" then return "" end

  -- Expressions (computed in SQL)
  if input:match("^__expr:") then return input end

  if not infers_non_text(col_meta) then return input end

  -- Preserve integers/decimals that can't round-trip through a LuaJIT double
  -- (|value| >= 2^53). Returning them as strings keeps bigint digits exact.
  if input:match("^%-?%d+%.?%d*$") then
    local num = tonumber(input)
    if num then
      local round_trip = num == math.floor(num) and string.format("%.0f", num) or tostring(num)
      if round_trip ~= input then
        return input
      end
    end
  end

  local ok, parsed = pcall(vim.json.decode, input)
  if ok and type(parsed) ~= "string" then
    return parsed
  end

  if input == "true" then return true end
  if input == "false" then return false end

  local num = tonumber(input)
  if num and not input:match("^0") then
    return num
  end

  return input
end

---------------------------------------------------------------------------
-- Value validation
---------------------------------------------------------------------------

--- Validate a parsed value against column metadata.
--- Returns (true) or (false, error_message).
function M.validate_value(value, col_meta)
  if not col_meta then return true end
  if value == vim.NIL then return true end

  local ctype = col_meta.ctype and col_meta.ctype:lower() or ""
  -- No type at all: nothing to check against. `types.is_numeric` reads an empty
  -- name as numeric, which is right for picking a literal's shape but would make
  -- a non-digit string an invalid value for a column introspection never typed.
  if ctype == "" then return true end

  if value == true or value == false then
    if not is_type(ctype, "boolean") then
      return false, "Cannot assign boolean to " .. (col_meta.ctype or "unknown") .. " column"
    end
    return true
  end

  if type(value) == "table" then
    if not is_type(ctype, "json") then
      return false, "Cannot assign object to " .. (col_meta.ctype or "unknown") .. " column"
    end
    return true
  end

  if type(value) == "number" then
    if is_type(ctype, "boolean") then
      if value == 1 or value == 0 then return true end
      return false, "Only 0 and 1 allowed for boolean column"
    end
    -- The shared root-word checks, not this file's exact-name table: the types
    -- introspection hands over carry parameters and widths (`numeric(10,2)`,
    -- `UInt64`), and reading those as "not numeric" made every number an
    -- invalid cell value — a `numeric(10,2)` column could not be edited. The
    -- DML layer already asks `types` the same way.
    if not types.is_numeric(ctype) then
      return false, "Cannot assign number to " .. (col_meta.ctype or "unknown") .. " column"
    end
    local val_str = tostring(value)
    if types.is_integer(ctype) then
      -- Two ways a double says it is not an integer, and the old guard read
      -- only the first: a point in its text, and the non-finite spellings
      -- (`tostring(math.huge)` is "inf", point-free, so an integer column
      -- accepted it and the commit became `SET seq = 'Infinity'`).
      if val_str:match("%.") then
        return false, "Cannot assign decimal to " .. (col_meta.ctype or "unknown") .. " column"
      end
      if ident.is_non_finite(value) then
        return false, "Cannot assign " .. val_str .. " to " .. (col_meta.ctype or "unknown") .. " column"
      end
      return true
    end
    return true
  end

  if type(value) == "string" then
    if value:match("^__expr:") then return true end
    if is_type(ctype, "uuid") then
      local parts = { value:match("^(%x%x%x%x%x%x%x%x)-(%x%x%x%x)-(%x%x%x%x)-(%x%x%x%x)-(%x%x%x%x%x%x%x%x%x%x%x%x)$") }
      if not parts or #parts ~= 5 then
        return false, "Invalid UUID format"
      end
      return true
    end
    if types.is_integer(ctype) then
      if value:match("^%-?%d+$") then return true end
      return false, "Cannot assign string to " .. (col_meta.ctype or "unknown") .. " integer column"
    end
    if types.is_numeric(ctype) then
      if value:match("^%-?%d+%.?%d*$") then return true end
      return false, "Cannot assign string to " .. (col_meta.ctype or "unknown") .. " column"
    end
    if is_type(ctype, "boolean") then
      return false, "Cannot assign string to boolean column"
    end
    if is_type(ctype, "date") then
      if not value:match("^%d") then
        return false, "Invalid date format"
      end
    end
    return true
  end

  return true
end

---------------------------------------------------------------------------
-- Edit state management
---------------------------------------------------------------------------

--- Create a fresh edit state tracker.
--- @return table edit_state
function M.create_edit_state()
  return {
    modified_cells = {},
    deleted_rows = {},
    added_rows = {},
    dirty = false,
    cell_errors = {},
  }
end

--- Track a cell modification.
--- @param es table Edit state
--- @param row_key string "row:col"
--- @param col number Column index
--- @param old_val any Previous value
--- @param new_val any New value
function M.track_cell_edit(es, row_key, col, old_val, new_val)
  if new_val == old_val then
    es.modified_cells[row_key] = nil
    if not next(es.modified_cells) then
      es.dirty = false
    end
    return
  end
  local row_idx = tonumber(row_key:match("^(%d+):"))
  if row_idx and es.deleted_rows[row_idx] then
    return
  end
  es.modified_cells[row_key] = { col = col, old_val = old_val, new_val = new_val }
  es.dirty = true
end

--- Track a row deletion.
--- @param es table Edit state
--- @param row_idx number Row index
function M.track_row_delete(es, row_idx)
  for i = #es.added_rows, 1, -1 do
    if es.added_rows[i].row_idx == row_idx then
      -- A row `o` only queued is not on the server, so there is nothing to
      -- delete: cancelling it means dropping the insert. Marking it deleted
      -- instead generated the INSERT anyway — the DELETE found no `rows_source`
      -- twin at that index and was refused, so the cancelled row was committed.
      table.remove(es.added_rows, i)
      es.dirty = next(es.modified_cells) ~= nil or next(es.deleted_rows) ~= nil
        or #es.added_rows > 0
      return
    end
  end
  es.deleted_rows[row_idx] = true
  es.dirty = true
  for k, _ in pairs(es.modified_cells) do
    local r = tonumber(k:match("^(%d+):"))
    if r == row_idx then
      es.modified_cells[k] = nil
    end
  end
end

--- Track a row addition.
--- @param es table Edit state
--- @param row_data table Row data
--- @param row_idx number Row index
function M.track_row_add(es, row_data, row_idx)
  table.insert(es.added_rows, { data = row_data, row_idx = row_idx })
  es.dirty = true
end

--- Check if there are any pending changes.
function M.has_pending_changes(es)
  if not es or not es.dirty then return false end
  return next(es.modified_cells) ~= nil
      or next(es.deleted_rows) ~= nil
      or #es.added_rows > 0
end

--- Get a summary of pending changes for display.
--- Count pending changes (for display).
function M.count_pending_changes(es)
  if not es or not es.dirty then return { modified = 0, deleted = 0, added = 0 } end
  local mod = 0
  for _ in pairs(es.modified_cells) do mod = mod + 1 end
  local del = 0
  for _ in pairs(es.deleted_rows) do del = del + 1 end
  return { modified = mod, deleted = del, added = #es.added_rows }
end

--- Return a short text representation of pending changes.
function M.pending_changes_text(es)
  if not es or not es.dirty or not M.has_pending_changes(es) then return nil end
  local counts = M.count_pending_changes(es)
  local parts = {}
  if counts.modified > 0 then table.insert(parts, "~" .. counts.modified) end
  if counts.added > 0 then table.insert(parts, "+" .. counts.added) end
  if counts.deleted > 0 then table.insert(parts, "-" .. counts.deleted) end
  return table.concat(parts, " ")
end

--- Reset edit state, clearing all pending changes.
function M.reset_edit_state(es)
  if not es then return end
  es.modified_cells = {}
  es.deleted_rows = {}
  es.added_rows = {}
  es.dirty = false
  es.cell_errors = {}
end

--- Clear a cell error.
function M.clear_cell_error(es, row_key)
  if es and es.cell_errors then
    es.cell_errors[row_key] = nil
  end
end

--- Set a cell error.
function M.set_cell_error(es, row_key, msg)
  if not es then return end
  if not es.cell_errors then es.cell_errors = {} end
  es.cell_errors[row_key] = msg
end

---------------------------------------------------------------------------
-- JSON formatting helpers
---------------------------------------------------------------------------

--- Format a Lua table as JSON for editing.
--- @param val table JSON value
--- @return string
function M.format_json_input(val)
  if type(val) == "string" then return val end
  local ok, str = pcall(vim.json.encode, val)
  if ok then
    -- Plain encode, escapes intact: this used to gsub('\\"', '"') the output,
    -- which read prettier but turned every string VALUE containing a quote
    -- (`{"note":"he said "hi""}`) into invalid JSON — the editor's default
    -- text no longer re-parsed, so even a no-op edit of such a cell failed.
    return str
  end
  return tostring(val)
end

--- Parse a JSON string into a Lua value.
--- @param input string
--- @return table|nil
function M.parse_json_input(input)
  local ok, decoded = pcall(vim.json.decode, input)
  if ok then return decoded end
  return nil
end

return M
