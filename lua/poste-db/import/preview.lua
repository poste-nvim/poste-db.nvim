local dialog = require("poste-db.dialog")
local const = require("poste-db.constants")

local M = {}

local function build_preview_lines(table_info, total_rows, valid_count, bad_rows,
    col_map, unmatched_import, unmatched_table, parsed_cols, parsed_rows, max_preview_cols)
  local lines = {}
  local function add(l) table.insert(lines, l) end

  add(string.format("Table: %s.%s    Connection: %s (%s)",
    table_info.schema or "(default)", table_info.name,
    table_info.connection, table_info.dialect))
  add("")
  add(string.format("Parsed: %d rows total, %d valid, %d with errors",
    total_rows, valid_count, #bad_rows))

  if parsed_rows and #parsed_rows > 0 then
    add("")
    add("Data preview (first rows):")

    local num_preview_cols = math.min(max_preview_cols, #parsed_cols)
    local has_more_cols = num_preview_cols < #parsed_cols
    local num_preview_rows = math.min(3, #parsed_rows)

    local col_vals = {}
    for ci = 1, num_preview_cols do
      local vals = { parsed_cols[ci] }
      for ri = 1, num_preview_rows do
        local v = parsed_rows[ri][ci]
        local display
        if v == nil or v == vim.NIL then display = "NULL"
        elseif type(v) == "string" then display = v
        else display = tostring(v) end
        table.insert(vals, display)
      end
      table.insert(col_vals, vals)
    end

    local col_widths = {}
    for ci = 1, num_preview_cols do
      local max_w = 0
      for _, val in ipairs(col_vals[ci]) do
        max_w = math.max(max_w, vim.fn.strdisplaywidth(val))
      end
      col_widths[ci] = max_w
    end

    local function pad_val(vals, ri, cw)
      local val = vals[ri]
      local pad = cw - vim.fn.strdisplaywidth(val)
      if pad > 0 then val = val .. string.rep(" ", pad) end
      return val
    end

    local sep_parts = {}
    for ci = 1, num_preview_cols do
      sep_parts[ci] = string.rep("-", col_widths[ci])
    end

    local ext_suffix = ""
    if has_more_cols then ext_suffix = " | ..." end

    local header_cells = {}
    for ci = 1, num_preview_cols do
      table.insert(header_cells, pad_val(col_vals[ci], 1, col_widths[ci]))
    end
    add("  " .. table.concat(header_cells, " | ") .. ext_suffix)

    add("  " .. table.concat(sep_parts, "-|-") .. ext_suffix)

    for ri = 1, num_preview_rows do
      local data_cells = {}
      for ci = 1, num_preview_cols do
        table.insert(data_cells, pad_val(col_vals[ci], ri + 1, col_widths[ci]))
      end
      add("  " .. table.concat(data_cells, " | ") .. ext_suffix)
    end

    if #parsed_rows > 3 then
      add("  ... (" .. (#parsed_rows - 3) .. " more row(s))")
    end
  end

  add("")
  add("Column mapping:")
  -- The two column headers ("file", "table") are the minimum widths, so the
  -- separator row never comes out shorter than the header it underlines.
  local max_import_w = 4
  local max_table_w = 5
  for _, mc in ipairs(col_map) do
    local iw = vim.fn.strdisplaywidth(mc.import_name)
    local tw = vim.fn.strdisplaywidth(mc.table_col.name .. " (" .. mc.table_col.col_type .. ")")
    if iw > max_import_w then max_import_w = iw end
    if tw > max_table_w then max_table_w = tw end
  end
  local sep = "  " .. string.rep("-", max_import_w) .. "-+-" .. string.rep("-", max_table_w)
  local function fmt_row(left, right)
    local l = left .. string.rep(" ", max_import_w - vim.fn.strdisplaywidth(left))
    local r = right .. string.rep(" ", max_table_w - vim.fn.strdisplaywidth(right))
    return "  " .. l .. " | " .. r
  end
  add(fmt_row("file", "table"))
  add(sep)
  local orange_rows = {}
  for i, mc in ipairs(col_map) do
    local tc = mc.table_col
    local right = tc.name .. " (" .. tc.col_type .. ")"
    add(fmt_row(mc.import_name, right))
    if tc and not tc.nullable and not tc.is_pk and (tc.default == nil or tc.default == vim.NIL) then
      table.insert(orange_rows, #lines)
    end
  end

  add(sep)
  if #unmatched_import > 0 then
    add(string.format("  (unmatched: %s)", table.concat(unmatched_import, ", ")))
  end
  if #unmatched_table > 0 then
    local names = {}
    for _, tc in ipairs(unmatched_table) do
      table.insert(names, tc.name)
    end
    add(string.format("  (missing: %s <- DEFAULT)", table.concat(names, ", ")))
  end

  if #bad_rows > 0 then
    add("")
    add("Validation errors:")
    for i = 1, math.min(#bad_rows, 5) do
      for _, err in ipairs(bad_rows[i].errors) do
        add(err)
      end
    end
    if #bad_rows > 5 then
      add(string.format("  ... and %d more row(s) with errors", #bad_rows - 5))
    end
  end

  return lines, orange_rows
end

function M.show_preview(table_info, total_rows, valid_count, bad_rows,
    col_map, unmatched_import, unmatched_table, parsed_cols, parsed_rows, callback)
  local max_preview_cols = 6
  local content, orange_rows = build_preview_lines(table_info, total_rows, valid_count, bad_rows,
    col_map, unmatched_import, unmatched_table, parsed_cols, parsed_rows, max_preview_cols)

  local content_width = 0
  for _, l in ipairs(content) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(l))
  end
  local min_width = 60
  local text_area = math.max(content_width, min_width)
  local width = math.min(text_area + 4, math.floor(vim.o.columns * 0.8))

  local lines = content
  local height = math.min(#lines + 2, math.floor(vim.o.lines * const.IMPORT_PREVIEW_HEIGHT_RATIO))

  -- Forward declaration: the keymap closures must capture the local `d`
  -- upvalue. Declaring `d` only after this table would leave the closures
  -- reading the (nil) global of the same name and crashing on keypress.
  local d
  -- One answer per dialog. dialog.open's own q/<Esc> keymaps and the WinLeave
  -- fallback close through on_close, which must deliver the same callback(nil)
  -- the explicit abort key does: Esc used to end the whole import silently,
  -- with no "Import cancelled" notice. on_close's answer is scheduled, so a
  -- keymap's synchronous answer (close() fires on_close first) wins the race
  -- and the flag makes the late nil a no-op.
  local answered = false
  local function answer(value)
    if answered then return end
    answered = true
    callback(value)
  end
  local keymaps = {
    a = function() d:close(); answer(nil) end,
    A = function() d:close(); answer(nil) end,
    p = function() d:close(); answer("proceed") end,
    P = function() d:close(); answer("proceed") end,
  }
  if #bad_rows > 0 then
    keymaps.s = function() d:close(); answer("skip") end
    keymaps.S = function() d:close(); answer("skip") end
  end

  d = dialog.open({
    title = "Import Preview",
    width = width,
    height = height,
    keymaps = keymaps,
    on_close = function()
      vim.schedule(function() answer(nil) end)
    end,
  })

  local highlights = {}
  local parsed_li = 2
  -- One colour per count on the "Parsed: N rows total, N valid, N with errors"
  -- line. Byte 9 is just past the "Parsed: " prefix; a line that stops matching
  -- that format just yields fewer highlights instead of erroring.
  -- A zero error count is deliberately left uncoloured: red on "0 with errors"
  -- made every clean file look like it had a problem.
  local count_groups = { "Number", "String" }
  if #bad_rows > 0 then table.insert(count_groups, "DiagnosticError") end
  local parsed_text = lines[parsed_li + 1]
  if parsed_text then
    local pos = 9
    for _, group in ipairs(count_groups) do
      local s, e = parsed_text:find("%d+", pos)
      if not s then break end
      table.insert(highlights, { line = parsed_li, col_start = s - 1, col_end = e, hl_group = group })
      pos = e + 1
    end
  end
  for _, li in ipairs(orange_rows) do
    table.insert(highlights, { line = li - 1, col_start = 0, col_end = #content[li], hl_group = "DiagnosticWarn" })
  end

  d:update(lines, highlights)
end

return M
