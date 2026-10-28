--- Dataset cell navigation --- extract, format, yank, highlight individual cells.
local C = require("poste-db.constants")
local sql_state = require("poste-db.state")
local sql_format = require("poste-db.format")

local sql_highlights = require("poste-db.highlights")

local M = {}

-- `row` is the visible row within the rendered page; the data lives in the
-- full result set, so page/sort/filter offsets must be undone first.
function M.get_resultset_cell(tab, row, col)
  if not tab or not tab.data or not tab.meta or tab.meta.type ~= "resultset" then return nil end
  local data = tab.data
  if not data or not data.results or #data.results == 0 then return nil end
  local res = data.results[1]
  local src_row = sql_format.source_row_of(tab.meta, row)
  if not src_row or not res.rows or not res.rows[src_row] then return nil end
  return res, res.rows[src_row][col]
end

function M.json_pretty(val, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  local pad1 = string.rep("  ", indent + 1)
  if type(val) == "table" then
    local is_array = #val > 0
    if is_array then
      local items = {}
      for _, v in ipairs(val) do
        items[#items + 1] = pad1 .. M.json_pretty(v, indent + 1)
      end
      return "[\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "]"
    else
      local items = {}
      for k, v in pairs(val) do
        items[#items + 1] = pad1 .. '"' .. tostring(k) .. '": ' .. M.json_pretty(v, indent + 1)
      end
      table.sort(items)
      return "{\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "}"
    end
  elseif val == vim.NIL or val == nil then
    return "null"
  elseif type(val) == "boolean" then
    return tostring(val)
  elseif type(val) == "number" then
    if val == math.floor(val) then
      return string.format("%.0f", val)
    end
    return tostring(val)
  else
    local ok, encoded = pcall(vim.json.encode, val)
    return ok and encoded or ('"' .. tostring(val) .. '"')
  end
end

function M.try_pretty_json(s)
  local ok, decoded = pcall(vim.json.decode, s)
  if ok and type(decoded) == "table" then
    return M.json_pretty(decoded)
  end
  if ok and type(decoded) == "string" then
    local ok2, decoded2 = pcall(vim.json.decode, decoded)
    if ok2 and type(decoded2) == "table" then
      return M.json_pretty(decoded2)
    end
  end
  return nil
end

function M.pretty_print(val)
  if val == nil or val == vim.NIL then
    return "(NULL)", "text"
  end
  if type(val) == "table" then
    return M.json_pretty(val), "json"
  end
  if type(val) == "number" then
    if val == math.floor(val) then
      return string.format("%.0f", val), "text"
    end
    return tostring(val), "text"
  end
  local s = tostring(val)
  if type(val) == "string" then
    local pretty = M.try_pretty_json(s)
    if pretty then return pretty, "json" end
    local trimmed = s:match("^%s*(.*)")
    if trimmed ~= s then
      pretty = M.try_pretty_json(trimmed)
      if pretty then return pretty, "json" end
    end
  end
  return s, "text"
end

--- The text a non-NULL cell value renders/copies as — ONE reading for every
--- yank path (they used to be hand-rolled twice with drifting semantics).
local function scalar_text_of(val)
  if type(val) == "table" then
    local ok, encoded = pcall(vim.json.encode, val)
    return ok and encoded or vim.inspect(val)
  elseif type(val) == "number" then
    if val == math.floor(val) then
      return string.format("%.0f", val)
    end
    return tostring(val)
  end
  return tostring(val)
end

function M.clipboard_text(val)
  if val == nil or val == vim.NIL then return "" end
  return scalar_text_of(val)
end

function M.yank_preview_text(val)
  local text = M.clipboard_text(val)
  return text:sub(1, C.YANK_PREVIEW_CHARS)
end

function M.collect_column_values(tab, col)
  if not tab or not tab.data or not tab.meta or tab.meta.type ~= "resultset" then return nil end
  local data = tab.data
  if not data or not data.results or #data.results == 0 then return nil end

  local res = data.results[1]
  if not res.rows or #res.rows == 0 then return nil end

  -- Yank the column the way the screen shows it: view order, filtered rows
  -- only — the same rule `get_resultset_cell` applies to a single cell, so the
  -- pasted column lines up with the rows on screen. `view_indices` is kept by
  -- the sort/filter paths and indexes layout.rows, which is `res.rows` itself
  -- (plan_resultset_layout hands the table through), so the indices read this
  -- table directly; a tab with no view override is the whole column in source
  -- order, unchanged.
  local order = tab.view_indices
  local values = {}
  for i = 1, order and #order or #res.rows do
    local row = order and res.rows[order[i]] or res.rows[i]
    local v = row[col]
    -- A column yank spells an empty cell NULL (a single-cell copy spells it
    -- with the empty string); everything else goes through the shared scalar
    -- reading.
    if v == nil or v == vim.NIL then
      values[#values + 1] = "NULL"
    else
      values[#values + 1] = scalar_text_of(v)
    end
  end

  local col_name = res.columns and res.columns[col] and res.columns[col].name or tostring(col)
  return values, col_name
end

function M.build_column_yank_text(tab, col)
  local values, col_name = M.collect_column_values(tab, col)
  if not values then return nil end
  return table.concat(values, ", "), #values, col_name
end

function M.build_cell_yank_text(tab, row, col)
  local _, val = M.get_resultset_cell(tab, row, col)
  val = M.clipboard_text(val)
  return val, M.yank_preview_text(val)
end

function M.apply_cell_highlight(enabled, dataset_buffer, row, col, meta, col_starts)
  if enabled then
    sql_highlights.highlight_cell(dataset_buffer, row, col, meta, nil, col_starts)
  else
    sql_highlights.clear_cell_highlight(dataset_buffer)
  end
end

function M.toggle_cell_highlight(dataset_buffer, row, col, meta, col_starts)
  sql_state.highlight_cell = not sql_state.highlight_cell
  M.apply_cell_highlight(sql_state.highlight_cell, dataset_buffer, row, col, meta, col_starts)
  return sql_state.highlight_cell
end

return M
