--- Row navigation and interactive cell editing (vim.ui dependent).
--- Handles cursor movement, cell editing dialogs, row ops.

local cell = require("poste-db.editor.cell")
local const = require("poste-db.constants")

local M = {}

local D = nil
local function get_dataset()
  if not D then D = require("poste-db.dataset") end
  return D
end

local state = nil
local function get_state()
  if not state then state = require("poste-db.state") end
  return state
end

local function check_edit_guards(tab)
  if not tab or not tab.layout then return false end
  if tab.layout.rows and #tab.layout.rows > const.EDIT_MAX_ROWS then
    vim.notify("Editing is not supported for result sets > " .. const.EDIT_MAX_ROWS .. " rows", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return false
  end
  if tab.original_sql and cell.has_join(tab.original_sql) then
    vim.notify("Editing is not supported for multi-table (JOIN) queries", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return false
  end
  local column = require("poste-db.editor.column")
  column.ensure_primary_key(tab)
  return true
end

---------------------------------------------------------------------------
-- Editable row check
---------------------------------------------------------------------------

--- Check if a row index is a data row (not header/border).
--- @param tab table Tab state
--- @param row_idx number 1-based row WITHIN THE RENDERED PAGE (what
---   `state.cell.row` holds — clamped to `meta.row_count`)
--- @return boolean
function M.is_data_row(tab, row_idx)
  if not tab or not tab.meta then return false end
  local meta = tab.meta
  if meta.type ~= "resultset" then return false end
  if not meta.row_count then return false end
  return row_idx >= 1 and row_idx <= meta.row_count
end

--- Page-visible row → index into `layout.rows` / `rows_source`.
--- The two spaces only coincide on page 1 of an unfiltered, unsorted view;
--- editing a filtered or paged result set used to write the visible index
--- into the source arrays, so the commit targeted a different row than the
--- one on screen.
local function to_source_row(tab, visible_row)
  local fmt = require("poste-db.format")
  return fmt.source_row_of(tab.meta, visible_row) or visible_row
end

---------------------------------------------------------------------------
-- Interactive edit functions (vim.ui dependent)
---------------------------------------------------------------------------

local function ensure_edit_state(tab)
  if not tab.edit_state then
    tab.edit_state = cell.create_edit_state()
  end
  return tab.edit_state
end

--- Redraw the buffer line a source row is displayed on. A source row that is
--- off the current page has no line to fix, which is why this starts from the
--- row rather than from the cursor.
local function render_source_row_line(tab, row_idx)
  local buf = get_dataset().dataset_buffer
  if not (buf and vim.api.nvim_buf_is_valid(buf) and tab.padded and tab.meta) then return end
  local meta = tab.meta
  local fmt = require("poste-db.format")
  local visible = fmt.visible_row_of(meta, row_idx)
  if not (meta.data_start_line and visible) then return end
  local line_idx = meta.data_start_line + visible - 1
  local row = tab.rows_source and tab.rows_source[row_idx] or tab.layout.rows[row_idx]
  if not row then return end
  local new_line = fmt.render_row(row, tab.layout, fmt.row_number_of(meta, visible) or row_idx)
  if not new_line then return end
  if tab.padded[line_idx] then
    tab.padded[line_idx] = "  " .. new_line
  end
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, line_idx - 1, line_idx, false, { "  " .. new_line })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  require("poste-db.highlights").apply_edit_highlights(buf, tab)
end

--- Put back the pending edits of a row that is being deleted.
--- `track_row_delete` forgets the row's `modified_cells` entries, but each edit
--- had already overwritten `rows_source`, and that is the array a DELETE's WHERE
--- is built from. On a table with a primary key it made no difference; on one
--- without, the statement named the row by values no server row holds, so the
--- commit reported success having matched nothing.
local function revert_row_edits(tab, es, row_idx)
  local reverted = false
  for row_key, mod in pairs(es.modified_cells) do
    if tonumber(row_key:match("^(%d+):")) == row_idx then
      if tab.layout.rows[row_idx] then
        tab.layout.rows[row_idx][mod.col] = mod.old_val
      end
      if tab.rows_source and tab.rows_source[row_idx] then
        tab.rows_source[row_idx][mod.col] = mod.old_val
      end
      cell.clear_cell_error(es, row_key)
      reverted = true
    end
  end
  if reverted then render_source_row_line(tab, row_idx) end
end

--- Redraw the whole page from `tab.layout`, for when the row count changed and
--- the lines below the change would otherwise keep their old positions. Returns
--- the new meta, or nil when there is no dataset buffer to draw into.
---
--- The render window follows the tab's own paging state. Passing
--- `tab.page_size` unconditionally (the previous shape) cut a pagination-OFF
--- dataset down to its first page: `o` on a 120-row table left 70 rows on the
--- layout and off the screen, and the winbar went on advertising them.
local function rerender_dataset_page(tab)
  local buf = get_dataset().dataset_buffer
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return nil end
  local fmt = require("poste-db.format")
  local page = tab.page or 1
  local page_size = tab.page_size or const.EDITOR_PAGE_SIZE
  if not tab.pagination_enabled then
    -- Paging off means "the whole set is on screen": one page holding every
    -- row, which is also the page the cursor arithmetic assumes.
    page, page_size = 1, #tab.layout.rows
  end
  local lines, meta = fmt.render_page(tab.layout, page, page_size)
  meta.table_name = tab.meta and tab.meta.table_name
  require("poste-db.buffer").apply_rendered_page(tab, lines, meta)
  require("poste-db.highlights").apply_edit_highlights(buf, tab)
  return meta
end

local function apply_cell_edit(row_idx, col_idx, new_val)
  local tab = get_dataset().T()
  if not tab or not tab.layout then return end
  -- `row_idx` is a SOURCE row (see to_source_row): edit_state keys, layout.rows
  -- and rows_source all live in that space, which dml.generate_dml reads.

  local es = ensure_edit_state(tab)
  local row_key = tostring(row_idx) .. ":" .. tostring(col_idx)

  -- Check if this row is an added row — update data directly, no modified_cell entry
  local is_added = false
  for _, added in ipairs(es.added_rows) do
    if added.row_idx == row_idx then
      is_added = true
      break
    end
  end

  if is_added then
    tab.layout.rows[row_idx][col_idx] = new_val
    es.dirty = #es.added_rows > 0
  else
    local existing = es.modified_cells[row_key]
    local old_val = existing and existing.old_val or tab.layout.rows[row_idx][col_idx]
    cell.track_cell_edit(es, row_key, col_idx, old_val, new_val)
    tab.layout.rows[row_idx][col_idx] = new_val
  end

  -- Also update rows_source so refresh_page shows the edit
  if tab.rows_source and tab.rows_source[row_idx] then
    tab.rows_source[row_idx][col_idx] = new_val
  end

  -- Clear any previous error for this cell
  cell.clear_cell_error(es, row_key)

  render_source_row_line(tab, row_idx)

  -- Update winbar (through buffer.refresh_winbar: a raw option write here
  -- bypasses its unchanged-text cache and leaves the next build thinking the
  -- window still shows the old text)
  if tab.edit_state.dirty then
    require("poste-db.buffer").refresh_winbar(tab.meta)
  end
end

function M.detect_cell_type(col_meta)
  if cell.is_boolean_column(col_meta) then return "boolean" end
  if cell.is_datetime_column(col_meta) then return "datetime" end
  if cell.is_enum_column(col_meta) then return "enum" end
  return "text"
end

local cell_editors = {}

--- Apply what a prompt answered, for every editor that takes typed text.
--- `parse_value` reads the NULL spellings, `''`, the `__expr:` prefix and the
--- number-vs-text decision against the *target column*, and `validate_value`
--- refuses what that column cannot hold — so a bad cell is reported here instead
--- of turning into a server error at commit. The datetime "Custom…" branch used
--- to call `apply_cell_edit` with the prompt's own text, which skipped both
--- steps: clearing that prompt wrote an empty string into a date column, and a
--- typed "(NULL)" was stored as the characters `"(NULL)"`.
local function apply_typed_edit(row_idx, col_idx, col_meta, old_val, input)
  if input == nil then return end
  local new_val = cell.parse_value(input, old_val, col_meta)
  if new_val == nil then return end
  local row_key = tostring(row_idx) .. ":" .. tostring(col_idx)
  local ok, err = cell.validate_value(new_val, col_meta)
  if not ok then
    local tab = get_dataset().T()
    if tab then
      cell.set_cell_error(ensure_edit_state(tab), row_key, err)
    end
    vim.notify("Validation error: " .. err, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end
  local tab = get_dataset().T()
  if tab then
    cell.clear_cell_error(ensure_edit_state(tab), row_key)
  end
  apply_cell_edit(row_idx, col_idx, new_val)
end

--- The picker's "now" candidate, and the text a cleared cell falls back to.
--- One function because the two lists used to disagree: the candidate list had
--- a branch for `time` columns and the "Custom…" pre-fill did not, so editing a
--- `time` cell offered `14:37:17` and then prompted with `2026-09-22 14:37:17`.
local function datetime_now_text(ctype)
  if ctype == "date" then return os.date("%Y-%m-%d") end
  if ctype == "time" then return os.date("%H:%M:%S") end
  return os.date("%Y-%m-%d %H:%M:%S")
end

--- The SQL expression this picker offers, and the only word the prompt will read
--- as one. List and prompt share these two definitions so they cannot disagree
--- about what a word means: typing the entry right above "Custom…" used to come
--- back as "Invalid date format", because only the pick became
--- `__expr:CURRENT_TIMESTAMP` and typed text reached `validate_value`, which
--- wants a leading digit.
local DATETIME_EXPR = "CURRENT_TIMESTAMP"

local function as_datetime_expr(input)
  if not input then return nil end
  if input:upper():match("^%s*(%S+)%s*$") == DATETIME_EXPR then
    return "__expr:" .. DATETIME_EXPR
  end
  return input
end

function cell_editors.boolean(row_idx, col_idx, col_meta, old_val)
  local choices = { "(NULL)", "true", "false" }
  vim.ui.select(choices, {
    prompt = col_meta.name or "value",
    format_item = function(item) return item end,
  }, function(choice)
    if not choice then return end
    local new_val
    if choice == "(NULL)" then
      new_val = vim.NIL
    elseif choice == "true" then
      new_val = true
    else
      new_val = false
    end
    apply_cell_edit(row_idx, col_idx, new_val)
  end)
end

function cell_editors.datetime(row_idx, col_idx, col_meta, old_val)
  local now = datetime_now_text(col_meta.ctype)
  -- `date` and `time` columns get no expression candidate, so their prompt reads
  -- no expression either: `has_expr` is the one condition the two share
  local has_expr = not (col_meta.ctype == "date" or col_meta.ctype == "time")
  local choices
  if has_expr then
    choices = { "(NULL)", now, DATETIME_EXPR }
  else
    choices = { "(NULL)", now }
  end
  table.insert(choices, "Custom…")
  vim.ui.select(choices, {
    prompt = (col_meta.name or "value") .. " (" .. (col_meta.ctype or "") .. ")",
    format_item = function(item) return item end,
  }, function(choice)
    if not choice or choice == "(NULL)" then
      if choice == "(NULL)" then
        apply_cell_edit(row_idx, col_idx, vim.NIL)
      end
      return
    end
    if choice == "Custom…" then
      -- the cell's own text, not the current time: the prompt is for correcting
      -- what is there, and pre-filling a new value made the digits in front of
      -- the one being changed invisible
      local has_value = old_val ~= nil and old_val ~= vim.NIL
      vim.ui.input({
        prompt = (col_meta.name or "value") .. ": ",
        default = has_value and tostring(old_val) or now,
      }, function(input)
        apply_typed_edit(row_idx, col_idx, col_meta, old_val,
          has_expr and as_datetime_expr(input) or input)
      end)
      return
    end
    if choice == DATETIME_EXPR then
      apply_cell_edit(row_idx, col_idx, "__expr:" .. DATETIME_EXPR)
    else
      apply_cell_edit(row_idx, col_idx, choice)
    end
  end)
end

function cell_editors.enum(row_idx, col_idx, col_meta, old_val)
  local choices = {}
  local current_value = (old_val ~= nil and old_val ~= vim.NIL) and tostring(old_val) or nil
  for _, v in ipairs(col_meta.enum_values) do
    local display = v
    if current_value and v == current_value then
      display = v .. " (current)"
      table.insert(choices, 1, { value = v, display = display })
    else
      table.insert(choices, { value = v, display = display })
    end
  end
  if col_meta.default then
    -- `DEFAULT` as an expression, which is what the label promises: the server's
    -- own value for the column. Lua `nil` looked like that choice but is "no
    -- value" downstream — the row table lost the slot and the statement said
    -- `SET col = NULL`, writing NULL into a column that merely has a default.
    -- Reach is enum-only (`enum_values` is filled for MySQL and postgres), both
    -- of which accept `= DEFAULT` in UPDATE and `VALUES (DEFAULT)` in INSERT.
    table.insert(choices, { value = "__expr:DEFAULT", display = "<default>" })
  end
  table.insert(choices, { value = vim.NIL, display = "(NULL)" })
  vim.ui.select(choices, {
    prompt = (col_meta.name or "value") .. "  (i=insert, ENTER=confirm)",
    format_item = function(item) return item.display end,
  }, function(choice)
    if not choice then return end
    apply_cell_edit(row_idx, col_idx, choice.value)
  end)
end

function cell_editors.text(row_idx, col_idx, col_meta, old_val)
  local initial_text
  if cell.is_json_column(col_meta) and type(old_val) == "table" then
    initial_text = cell.format_json_input(old_val)
  else
    initial_text = (old_val == nil or old_val == vim.NIL) and "" or tostring(old_val)
  end
  if not initial_text or initial_text == "" then
    if type(old_val) == "string" then
      local expr = old_val:match("^__expr:(.*)$")
      if expr then initial_text = expr end
    end
  end
  vim.ui.input({
    prompt = (col_meta.name or "value") .. ": ",
    default = initial_text,
  }, function(input)
    apply_typed_edit(row_idx, col_idx, col_meta, old_val, input)
  end)
end

--- Edit the current cell via floating input.
function M.edit_cell()
  local tab = get_dataset().T()
  if not check_edit_guards(tab) then return end

  local cs = get_state()
  local row_idx = cs.cell.row
  local col_idx = cs.cell.col
  local col_meta = tab.layout.columns[col_idx]

  if not M.is_data_row(tab, row_idx) then return end

  if not cell.is_editable_field(col_meta) then
    vim.notify("Cannot edit " .. (col_meta.ctype or "unknown") .. " field", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return
  end

  -- handlers work in source-row space: that is what edit_state keys and
  -- apply_cell_edit record. is_data_row validates the VISIBLE row against
  -- meta.row_count; a refresh between render and edit can leave the mapped
  -- source row outside layout.rows, which used to raise here.
  local src_row = to_source_row(tab, row_idx)
  local row = tab.layout.rows and tab.layout.rows[src_row]
  if not row then return end
  local old_val = row[col_idx]
  local handler = cell_editors[M.detect_cell_type(col_meta)]
  handler(src_row, col_idx, col_meta, old_val)
end

--- Delete the current row.
function M.delete_row()
  local tab = get_dataset().T()
  if not check_edit_guards(tab) then return end

  local cs = get_state()
  local row_idx = cs.cell.row

  if not M.is_data_row(tab, row_idx) then return end

  local es = ensure_edit_state(tab)
  local src_row = to_source_row(tab, row_idx)
  local queued = false
  for _, added in ipairs(es.added_rows) do
    if added.row_idx == src_row then queued = true end
  end
  revert_row_edits(tab, es, src_row)
  cell.track_row_delete(es, src_row)

  if queued then
    -- `dd` on a row `o` only queued cancels it, so its line goes with it: the
    -- row was never on the server, and a line still standing would invite an
    -- edit that has no insert behind it any more
    table.remove(tab.layout.rows, src_row)
    -- The row is gone from the layout, so the paging count goes with it (see
    -- insert_row: this is the other half of the same invariant).
    if tab.layout.total_rows and tab.layout.total_rows > 0 then
      tab.layout.total_rows = tab.layout.total_rows - 1
    end
    for _, added in ipairs(es.added_rows) do
      if added.row_idx > src_row then added.row_idx = added.row_idx - 1 end
    end
    local meta = rerender_dataset_page(tab)
    if meta and get_state().cell.row > meta.row_count then
      get_state().cell.row = math.max(1, meta.row_count)
    end
    require("poste-db.buffer").refresh_winbar(tab.meta)
    vim.notify("Insert cancelled", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    return
  end

  -- Visual feedback: strikethrough the line
  local buf = get_dataset().dataset_buffer
  if buf and vim.api.nvim_buf_is_valid(buf) and tab.padded then
    local sql_highlights = require("poste-db.highlights")
    sql_highlights.apply_edit_highlights(buf, tab)
  end

  -- Update winbar
  require("poste-db.buffer").refresh_winbar(tab.meta)
end

--- Insert a new row at the end of the table.
function M.insert_row()
  local tab = get_dataset().T()
  if not check_edit_guards(tab) then return end

  local es = ensure_edit_state(tab)
  local num_cols = #tab.layout.columns
  local row_data = {}
  for i = 1, num_cols do
    local col_meta = tab.layout.columns[i]
    if col_meta.primary_key and col_meta.ctype and cell.is_integer_type(col_meta.ctype) then
      row_data[i] = "[Auto]"
    else
      row_data[i] = nil
    end
  end

  -- Append to layout rows and track in edit_state
  local new_row_idx = #tab.layout.rows + 1
  tab.layout.rows[new_row_idx] = vim.deepcopy(row_data)
  -- `layout.total_rows` is the count pagination derives from (it comes from
  -- the server), so a local append has to move it too: otherwise the new row
  -- sits past the last page, `refresh_page` renders one row short, and the
  -- winbar keeps advertising the pre-insert count.
  tab.layout.total_rows = (tab.layout.total_rows or (new_row_idx - 1)) + 1
  cell.track_row_add(es, row_data, new_row_idx)

  -- The row lands at the END of the table, which is only the page on screen
  -- when the result does not paginate. Jump to the page that holds it first:
  -- otherwise the re-render draws a page without the new row, `visible` is
  -- nil, and the row the user just asked for is nowhere in sight (with
  -- pagination off the same page_size truncation hid the whole tail).
  if tab.pagination_enabled then
    local page_size = tab.page_size or const.EDITOR_PAGE_SIZE
    if page_size > 0 then
      tab.page = math.max(1, math.ceil(new_row_idx / page_size))
    end
  end

  -- Re-render current page to show the new row
  local meta = rerender_dataset_page(tab)
  if meta then
    -- Move cursor to the new row when this page renders it
    local sql_format = require("poste-db.format")
    local sql_highlights = require("poste-db.highlights")
    local visible = sql_format.visible_row_of(meta, new_row_idx)
    if visible then
      get_state().cell.row = visible
      local line_idx = meta.data_start_line + visible - 1
      pcall(vim.api.nvim_win_set_cursor, get_dataset().dataset_window, { line_idx, 0 })
      sql_highlights.highlight_cell(get_dataset().dataset_buffer, visible,
        get_state().cell.col or 1, meta)
    end
  end

  -- Update winbar
  require("poste-db.buffer").refresh_winbar(tab.meta)

  vim.notify("Row queued for insertion (commit with <leader>w)", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
end

--- Rollback all edits and re-run query.
function M.rollback_edits()
  local tab = get_dataset().T()
  if not tab then return end
  if not tab.edit_state or not tab.edit_state.dirty then
    vim.notify("No pending changes", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    return
  end

  cell.reset_edit_state(tab.edit_state)
  tab.edit_state = nil

  vim.schedule(function()
    require("poste-db.edit_commit").refresh_dataset(tab)
  end)
end

return M
