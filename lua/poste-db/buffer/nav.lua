--- Dataset cell navigation --- cursor movement, header float, raw mode, sort, yank.
local D = require("poste-db.dataset")
local C = require("poste-db.constants")
local sql_state = require("poste-db.state")

local sql_highlights = require("poste-db.highlights")
local nav_state = require("poste-db.buffer.nav_state")
local header = require("poste-db.buffer.header")
local cell = require("poste-db.buffer.nav_cell")
local preview = require("poste-db.buffer.nav_preview")
local raw_mode = require("poste-db.buffer.nav_raw")
local sort_helper = require("poste-db.buffer.nav_sort")
local M = {}

local preview_win = nil

-- Helper: get pre-computed column positions for a data row
local function get_col_starts(tab, row)
  if not tab or not tab.buffer_col_starts or not tab.meta then return nil end
  local line_idx = (tab.meta.data_start_line or 1) + row - 1
  return tab.buffer_col_starts[line_idx]
end

------------------------------------------------------------------------------
-- Trace helpers (opt-in via sql_state._trace)
------------------------------------------------------------------------------
local T_items = {}
local function T_clear() T_items = {} end
local function T_mark(label)
  if not sql_state._trace then return end
  T_items[#T_items + 1] = { label = label, t = vim.fn.reltime() }
end
local function T_report()
  if not sql_state._trace or #T_items == 0 then return end
  local t0 = T_items[1].t
  local total = vim.fn.reltimefloat(vim.fn.reltime(t0)) * 1000
  local lines = {}
  for i, ti in ipairs(T_items) do
    local step = i == 1 and 0 or vim.fn.reltimefloat(vim.fn.reltime(T_items[i - 1].t, ti.t)) * 1000
    local cum  = vim.fn.reltimefloat(vim.fn.reltime(t0, ti.t)) * 1000
    lines[#lines + 1] = string.format("  %s: %7.3fms (+%.3f)", ti.label, cum, step)
  end
  lines[#lines + 1] = string.format("  total: %7.3fms", total)
  local msg = table.concat(lines, "\n")
  T_clear()
  sql_state.log("TRACE", "move_cell trace:\n" .. msg)
end

local function focus_cell(tab, row, col, update_header)
  T_mark("position_cursor")
  sql_state.cell.row = row
  sql_state.cell.col = col
  local line = M.position_cursor(row, col)
  T_mark("highlight_cell")
  sql_highlights.highlight_cell(D.dataset_buffer, row, col, tab.meta, line, get_col_starts(tab, row))
  if update_header then
    T_mark("header_update")
    header.update()
  end
end

function M.move_cell(drow, dcol)
  local tab = D.T()
  if not tab or not tab.meta or tab.meta.type ~= "resultset" then return end
  -- No cells to focus in an empty resultset (matches the render-side
  -- row_count > 0 guards); focusing would crash the cursor placement.
  if (tab.meta.row_count or 0) == 0 or (tab.meta.col_count or 0) == 0 then return end

  if sql_state._trace then T_clear() end
  T_mark("move_cell")

  local row = sql_state.cell.row + drow
  local col = sql_state.cell.col + dcol

  row = math.max(1, math.min(row, tab.meta.row_count or 0))
  col = math.max(1, math.min(col, tab.meta.col_count or 0))

  focus_cell(tab, row, col, false)
  T_mark("header_update")
  if dcol ~= 0 then
    header.update()
  end
  T_mark("done")
  T_report()
end

function M.goto_first_col()
  local tab = D.T()
  if not tab or not tab.meta then return end
  focus_cell(tab, sql_state.cell.row, 1, true)
end

function M.goto_last_col()
  local tab = D.T()
  if not tab or not tab.meta then return end
  local last = tab.meta.col_count or 1
  focus_cell(tab, sql_state.cell.row, last, true)
end

function M.goto_first_row()
  local tab = D.T()
  if not tab or not tab.meta then return end
  focus_cell(tab, 1, sql_state.cell.col, false)
end

function M.goto_last_row()
  local tab = D.T()
  if not tab or not tab.meta then return end
  -- Same guard move_cell applies: an empty resultset has no rows to focus,
  -- and `row_count or 1` let a 0 fall through to a border-row line index.
  if (tab.meta.row_count or 0) == 0 then return end
  focus_cell(tab, tab.meta.row_count, sql_state.cell.col, false)
end

function M.position_cursor(row, col)
  local tab = D.T()
  if not tab or not tab.meta or not D.dataset_window then return "" end
  if not vim.api.nvim_win_is_valid(D.dataset_window) then return "" end

  local line_idx = (tab.meta.data_start_line or 1) + row - 1
  local buf = vim.api.nvim_win_get_buf(D.dataset_window)
  local last_col = tab.meta.col_count or 0

  -- Use pre-computed column byte/display offsets when available (O(1), no │ scan)
  local col_starts = tab.buffer_col_starts and tab.buffer_col_starts[line_idx]
  local target_col, target_disp, line, ranges
  if col_starts and col_starts[col + 1] then
    local tc = col_starts[col + 1]
    target_col = tc.ext_start
    target_disp = tc.disp_start
    T_mark("  pos:col_starts_lookup")
  else
    -- No mapped cell at this position (empty resultsets, short rows) —
    -- fall back to scanning the rendered line so target_disp stays a number.
    T_mark("  pos:get_line_fallback")
    line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
    T_mark("  pos:find_cell_ranges")
    ranges = sql_highlights.find_cell_ranges(line, col + 1, last_col + 1)
    target_col = ranges and ranges.target.cursor_col or 0
    target_disp = vim.fn.strdisplaywidth(line:sub(1, target_col))
    T_mark("  pos:strdisp_fallback")
  end

  T_mark("  pos:winsaveview")
  local saved = vim.fn.winsaveview()
  local saved_leftcol = saved.leftcol
  local win_width = vim.api.nvim_win_get_width(D.dataset_window)

  local left_margin = 2
  local right_margin = 3
  local target_on_screen = target_disp >= math.max(0, saved_leftcol - left_margin)
    and target_disp < saved_leftcol + win_width - right_margin

  T_mark("  pos:cursor_set")
  if target_on_screen then
    local saved_sso = vim.api.nvim_get_option_value("sidescrolloff", { win = D.dataset_window })
    if saved_sso and saved_sso > 0 then
      vim.api.nvim_set_option_value("sidescrolloff", 0, { win = D.dataset_window })
    end
    pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { line_idx, target_col })
    if saved_sso and saved_sso > 0 then
      vim.api.nvim_set_option_value("sidescrolloff", saved_sso, { win = D.dataset_window })
    end
  else
    pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { line_idx, target_col })
  end

  -- Left-align to the buffer start when at the first data column so the
  -- row-number column (left padding + `#` cell) scrolls back into view.
  if col == 1 then
    local v = vim.fn.winsaveview()
    if v.leftcol ~= 0 then
      v.leftcol = 0
      vim.fn.winrestview(v)
    end
  end

  -- Right-align the last column when:
  -- 1. Cursor is on the last column (prevents sidescrolloff from pushing it left)
  -- 2. Moving right off-screen and remaining columns (target..last) fit in the window
  if last_col > 0 then
    local last_right
    if col_starts then
      local lc = col_starts[last_col + 1]
      if lc then
        last_right = lc.disp_end + 1
      end
    elseif ranges and ranges.last then
      last_right = vim.fn.strdisplaywidth(line:sub(1, ranges.last.ext_end + 3))
    end
    if last_right then
      local remaining_width = last_right - target_disp
      local should_right_align = col == last_col
        or (not target_on_screen and target_disp >= saved_leftcol and remaining_width <= win_width)
      if should_right_align then
        local v = vim.fn.winsaveview()
        local new_leftcol = math.max(0, last_right - win_width)
        if new_leftcol ~= v.leftcol then
          v.leftcol = new_leftcol
          vim.fn.winrestview(v)
        end
      end
    end
  end

  T_mark("  pos:done")
  return line or ""
end

function M.preview_cell()
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_set_current_win(preview_win)
    return
  end

  local tab = nav_state.get_resultset_data_tab()
  if not tab then return end
  local row = sql_state.cell.row
  local col = sql_state.cell.col

  local res, raw_val = cell.get_resultset_cell(tab, row, col)
  if not res then return end
  local text, ft = cell.pretty_print(raw_val)

  local col_name = res.columns[col] and res.columns[col].name or "?"

  local float_buf, win = preview.open_preview_float(col_name, text, ft)
  if not float_buf then return end

  preview_win = win

  local close_fn = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    preview_win = nil
  end
  preview.set_preview_keymaps(float_buf, close_fn)
end

function M.yank_cell()
  local tab = nav_state.get_resultset_data_tab()
  if not tab then return end
  local row = sql_state.cell.row
  local col = sql_state.cell.col
  local text, preview_text = cell.build_cell_yank_text(tab, row, col)
  vim.fn.setreg('"', text)
  vim.fn.setreg('+', text)
  vim.notify(string.format('Yanked to clipboard: %s', preview_text), vim.log.levels.INFO, { title = C.TITLE })
end

function M.yank_column()
  local tab = nav_state.get_resultset_data_tab()
  local col = sql_state.cell.col
  local result, count, col_name = cell.build_column_yank_text(tab, col)
  if not result then return end
  vim.fn.setreg('"', result)
  vim.fn.setreg('+', result)
  vim.notify(string.format('Yanked %d values from "%s"', count, col_name), vim.log.levels.INFO, { title = C.TITLE })
end

function M.sort_by_current_col()
  local tab = nav_state.get_resultset_data_tab()
  if not tab then return end
  if nav_state.is_dirty(tab) then
    vim.notify(C.EDIT_CONFLICT_MSG, vim.log.levels.WARN, { title = C.TITLE })
    return
  end
  local data = tab.data
  if not data or not data.results or #data.results == 0 then return end

  local col = sql_state.cell.col
  local lines, meta, render_opts = sort_helper.prepare_current_col_sort(tab, data, D.active_tab_idx, col)
  if not lines then return end

  tab.is_sorting = true
  local buffer = require("poste-db.buffer")
  buffer.render_dataset(lines, meta, render_opts)
  tab.is_sorting = false
  require("poste-db.buffer.search").recompute_after_view_change()
  M.move_cell(0, 0)
end

--- Delegates to buffer_nav_ui.build_status_winbar with current dataset context.
function M.build_status_winbar(meta)
  return require("poste-db.buffer.nav_ui").build_status_winbar(meta, D.T(), #D.tabs, D.active_tab_idx)
end

M.toggle_raw_mode = raw_mode.toggle

M._test = {
  build_header_index = header.build_header_index,
  slice_header_to_win = header.slice_header_to_win,
}

return M
