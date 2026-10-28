--- SQL Dataset buffer — core: state, keymaps, tab switching, render, close.
local D = require("poste-db.dataset")
local C = require("poste-db.constants")
local sql_state = require("poste-db.state")

local config = require("poste-db.config")
local sql_highlights = require("poste-db.highlights")
local render = require("poste-db.buffer.render")

local M = {}

--- Target height for the dataset window after editor/window resizes.
--- nvim freely redistributes window heights on resize; a terminal shrink can
--- squeeze the dataset split down to just its winbar. Re-apply the
--- configured share of the editor, never smaller than the current height
--- (a user-enlarged dataset survives), never below a visible floor, and
--- never at the cost of the SQL file window's last rows.
--- @param current number current dataset window height
--- @param editor_lines number current editor height (vim.o.lines)
--- @return number target height
local function compute_dataset_height(current, editor_lines)
  local target = math.max(
    current,
    math.floor(editor_lines * C.DATASET_HEIGHT_RATIO),
    C.DATASET_MIN_HEIGHT
  )
  return math.min(target, math.max(editor_lines - 4, 1))
end

--- Raise the dataset window when a resize left it smaller than its target.
--- Monotone: never shrinks the dataset (manual enlargement is respected).
local function ensure_dataset_visible()
  if not D.dataset_window or not vim.api.nvim_win_is_valid(D.dataset_window) then
    return
  end
  local current = vim.api.nvim_win_get_height(D.dataset_window)
  local target = compute_dataset_height(current, vim.o.lines)
  if target > current then
    pcall(vim.api.nvim_win_set_height, D.dataset_window, target)
  end
end

--------------------------------------------------------------------------------
-- Buffer creation + keymaps
--------------------------------------------------------------------------------

function M.get_error_buffer()
  if D.error_buffer and vim.api.nvim_buf_is_valid(D.error_buffer) then
    return D.error_buffer
  end
  D.error_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = D.error_buffer })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = D.error_buffer })
  vim.api.nvim_set_option_value("swapfile", false, { buf = D.error_buffer })
  vim.api.nvim_set_option_value("modifiable", false, { buf = D.error_buffer })
  vim.api.nvim_buf_set_name(D.error_buffer, "poste://error")

  local opts = { buffer = D.error_buffer, noremap = true, silent = true }
  local k = config.get_keymap("sql_dataset", "close", "q")
  if k then vim.keymap.set("n", k, function() M.close() end, opts) end
  k = config.get_keymap("sql_dataset", "ask_ai", "a")
  if k then vim.keymap.set("n", k, function() require("poste-db.ai").ask_last_error() end, opts) end

  return D.error_buffer
end

function M.get_dataset_buffer()
  if D.dataset_buffer and vim.api.nvim_buf_is_valid(D.dataset_buffer) then
    return D.dataset_buffer
  end

  D.dataset_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = D.dataset_buffer })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = D.dataset_buffer })
  vim.api.nvim_set_option_value("swapfile", false, { buf = D.dataset_buffer })
  vim.api.nvim_set_option_value("modifiable", false, { buf = D.dataset_buffer })
  vim.api.nvim_buf_set_name(D.dataset_buffer, "poste://dataset")
  vim.bo[D.dataset_buffer].filetype = "poste_dataset"

  local opts = { buffer = D.dataset_buffer, noremap = true, silent = true }

  local k = config.get_keymap("sql_dataset", "close", "q")
  if k then vim.keymap.set("n", k, function() M.close() end, opts) end
  k = config.get_keymap("sql_dataset", "move_left", "h")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").move_cell(0, -1) end, opts) end
  k = config.get_keymap("sql_dataset", "move_down", "j")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").move_cell(1, 0) end, opts) end
  k = config.get_keymap("sql_dataset", "move_up", "k")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").move_cell(-1, 0) end, opts) end
  k = config.get_keymap("sql_dataset", "move_right", "l")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").move_cell(0, 1) end, opts) end
  k = config.get_keymap("sql_dataset", "prev_page", "H")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.page").prev_page() end, opts) end
  k = config.get_keymap("sql_dataset", "next_page", "L")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.page").next_page() end, opts) end
  k = config.get_keymap("sql_dataset", "first_col", "0")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").goto_first_col() end, opts) end
  k = config.get_keymap("sql_dataset", "last_col", "$")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").goto_last_col() end, opts) end
  k = config.get_keymap("sql_dataset", "first_row", "gg")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").goto_first_row() end, opts) end
  k = config.get_keymap("sql_dataset", "last_row", "G")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").goto_last_row() end, opts) end
  k = config.get_keymap("sql_dataset", "preview_cell", "K")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").preview_cell() end, opts) end
  k = config.get_keymap("sql_dataset", "yank_cell", "yy")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").yank_cell() end, opts) end
  k = config.get_keymap("sql_dataset", "yank_column", "yc")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").yank_column() end, opts) end
  k = config.get_keymap("sql_dataset", "sort_column", "s")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").sort_by_current_col() end, opts) end
  k = config.get_keymap("sql_dataset", "toggle_raw_mode", "<leader>gp")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.nav").toggle_raw_mode() end, opts) end
  k = config.get_keymap("sql_dataset", "next_tab", "<Tab>")
  if k then vim.keymap.set("n", k, function() M.next_tab() end, opts) end
  k = config.get_keymap("sql_dataset", "prev_tab", "<S-Tab>")
  if k then vim.keymap.set("n", k, function() M.prev_tab() end, opts) end
  k = config.get_keymap("sql_dataset", "rerun", "R")
  if k then
    vim.keymap.set("n", k, function()
      local tab = D.T()
      if not tab or not tab.original_sql then return end
      if tab.edit_state and tab.edit_state.dirty then
        require("poste-db.editor").rollback_edits()
      else
        vim.schedule(function()
          require("poste-db.edit_commit").refresh_dataset(tab)
        end)
      end
    end, opts)
  end
  k = config.get_keymap("sql_dataset", "goto_first_page", "<leader>hh")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.page").goto_first_page() end, opts) end
  k = config.get_keymap("sql_dataset", "goto_last_page", "<leader>ll")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.page").goto_last_page() end, opts) end
  k = config.get_keymap("sql_dataset", "toggle_pagination", "<leader>pa")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.page").toggle_pagination() end, opts) end
  k = config.get_keymap("sql_dataset", "find_column", "<leader>fc")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.search").find_column() end, opts) end
  k = config.get_keymap("sql_dataset", "filter_by_cell", "<leader>ce")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.search").filter_by_current_cell() end, opts) end
  k = config.get_keymap("sql_dataset", "show_search", "<leader>/")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.search").show_search() end, opts) end
  k = config.get_keymap("sql_dataset", "clear_filter_search", "<leader>cr")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.search").clear_filter_search() end, opts) end
  k = config.get_keymap("sql_dataset", "next_search", "n")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.search").next_search_match() end, opts) end
  k = config.get_keymap("sql_dataset", "prev_search", "N")
  if k then vim.keymap.set("n", k, function() require("poste-db.buffer.search").prev_search_match() end, opts) end

  -- Export
  k = config.get_keymap("sql_dataset", "export", "E")
  if k then vim.keymap.set("n", k, function() require("poste-db.export").run() end, opts) end

  -- Edit keymaps
  k = config.get_keymap("sql_dataset", "edit_cell", "i")
  if k then vim.keymap.set("n", k, function() require("poste-db.editor").edit_cell() end, opts) end
  k = config.get_keymap("sql_dataset", "edit_cell_replace", "cc")
  if k then vim.keymap.set("n", k, function() require("poste-db.editor").edit_cell() end, opts) end
  k = config.get_keymap("sql_dataset", "delete_row", "dd")
  if k then vim.keymap.set("n", k, function() require("poste-db.editor").delete_row() end, opts) end
  k = config.get_keymap("sql_dataset", "insert_row", "o")
  if k then vim.keymap.set("n", k, function() require("poste-db.editor").insert_row() end, opts) end
  k = config.get_keymap("sql_dataset", "commit_edits", "<leader>w")
  if k then vim.keymap.set("n", k, function() require("poste-db.edit_commit").commit_edits() end, opts) end

  k = config.get_keymap("sql_dataset", "show_sql", "gs")
  if k then
    vim.keymap.set("n", k, function()
      require("poste-db.buffer.nav_ui").show_dataset_sql()
    end, opts)
  end

  k = config.get_keymap("sql_dataset", "help", "g?")
  if k then
    vim.keymap.set("n", k, function() require("poste-db.help").open() end, opts)
  end

  -- Request history (JetBrains-style sidebar)
  k = config.get_keymap("sql_dataset", "history_toggle", "<leader>ph")
  if k then
    vim.keymap.set("n", k, function() require("poste-db.buffer.history").toggle() end, opts)
  end
  k = config.get_keymap("sql_dataset", "history_next", "<leader>n")
  if k then
    vim.keymap.set("n", k, function() M.history_next() end, opts)
  end
  k = config.get_keymap("sql_dataset", "history_prev", "<leader>b")
  if k then
    vim.keymap.set("n", k, function() M.history_prev() end, opts)
  end
  k = config.get_keymap("sql_dataset", "ask_ai", "a")
  if k then
    vim.keymap.set("n", k, function() require("poste-db.ai").ask_view() end, opts)
  end

  -- Prevent dataset buffer from being replaced in its window
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = D.dataset_buffer,
    callback = function()
      if not D.dataset_window then return end
      local win = vim.api.nvim_get_current_win()
      if win ~= D.dataset_window then return end
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(win) then return end
        if not vim.api.nvim_buf_is_valid(D.dataset_buffer) then return end
        local buf = vim.api.nvim_win_get_buf(win)
        -- Allow the plugin's own error buffer (rendered for failed queries);
        -- only revert user-initiated buffer swaps back to the dataset buffer.
        if buf ~= D.dataset_buffer and buf ~= D.error_buffer then
          vim.api.nvim_win_set_buf(win, D.dataset_buffer)
        end
      end)
    end,
  })

  -- BufWriteCmd: :w triggers commit
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = D.dataset_buffer,
    callback = function()
      local tab = D.T()
      if tab and tab.edit_state and tab.edit_state.dirty then
        require("poste-db.edit_commit").commit_edits()
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = D.dataset_buffer,
    callback = function()
      vim.schedule(function()
        if not M.is_open() then
          require("poste-db.buffer.header").close()
          sql_highlights.clear_cell_highlight(D.dataset_buffer)
        end
      end)
    end,
  })

  return D.dataset_buffer
end

--------------------------------------------------------------------------------
-- Tab switching
--------------------------------------------------------------------------------

local function save_active_tab_state()
  local tab = D.T()
  if not tab then return end
  tab.cursor = { row = sql_state.cell.row, col = sql_state.cell.col }
  if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
    tab.leftcol = vim.api.nvim_win_call(D.dataset_window, function()
      return vim.fn.winsaveview().leftcol
    end)
  end
end

local function apply_tab_state(tab)
  sql_state.cell.row = tab.cursor.row
  sql_state.cell.col = tab.cursor.col
  if tab.data then sql_state.last_dataset = tab.data end
end

--- Render the currently active tab (D.T()) into the dataset window.
--- No guards, no state saving — callers decide what to switch away from.
local _last_winbar_text = nil

--- Set the dataset winbar, skipping the option write when the text is
--- unchanged: the render pipeline builds it twice (finalize_rendered_page,
--- then render_dataset), and nvim_set_option_value on winbar is not free.
local function set_dataset_winbar(text)
  if text == _last_winbar_text then return end
  _last_winbar_text = text
  if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
    pcall(vim.api.nvim_set_option_value, "winbar", text or "", { win = D.dataset_window })
  end
end

local function render_active_tab()
  local tab = D.T()
  if not tab then return end
  require("poste-db.buffer.header").close()
  apply_tab_state(tab)

  if not D.dataset_window or not vim.api.nvim_win_is_valid(D.dataset_window) then return end

  if tab.padded then
    vim.api.nvim_set_option_value("modifiable", true, { buf = D.dataset_buffer })
    vim.api.nvim_buf_set_lines(D.dataset_buffer, 0, -1, false, tab.padded)
    vim.api.nvim_set_option_value("modifiable", false, { buf = D.dataset_buffer })
    sql_highlights.apply_dataset_highlights(D.dataset_buffer, tab.padded, tab.meta)
  end

  vim.api.nvim_win_set_buf(D.dataset_window, D.dataset_buffer)

  pcall(vim.api.nvim_win_call, D.dataset_window, function()
    vim.fn.winrestview({ leftcol = tab.leftcol or 0 })
  end)

  local meta = tab.meta
  if meta and meta.type == "resultset" and meta.row_count > 0 then
    local line_idx = (meta.data_start_line or 1) + tab.cursor.row - 1
    pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { line_idx, 0 })
    local cs = tab.buffer_col_starts and tab.buffer_col_starts[line_idx]
    sql_highlights.highlight_cell(D.dataset_buffer, tab.cursor.row, tab.cursor.col, meta, nil, cs)
  end

  if tab.header_text then
    require("poste-db.buffer.header").update()
  end

  set_dataset_winbar(require("poste-db.buffer.nav").build_status_winbar(meta))

  require("poste-db.buffer.search").apply_search_highlights()
end

local function switch_tab(idx)
  if not D.tabs[idx] then return end
  -- Block tab switch if current tab has dirty edits
  local current = D.T()
  if current and current.edit_state and current.edit_state.dirty then
    vim.notify(C.EDIT_CONFLICT_MSG, vim.log.levels.WARN, { title = C.TITLE })
    return
  end
  save_active_tab_state()
  D.active_tab_idx = idx
  render_active_tab()
end

function M.next_tab()
  if #D.tabs < 2 then return end
  local idx = D.active_tab_idx + 1
  if idx > #D.tabs then idx = 1 end
  switch_tab(idx)
end

function M.prev_tab()
  if #D.tabs < 2 then return end
  local idx = D.active_tab_idx - 1
  if idx < 1 then idx = #D.tabs end
  switch_tab(idx)
end

function M.tab_count()
  return #D.tabs
end

--------------------------------------------------------------------------------
-- Request history switching (JetBrains-style sidebar)
--------------------------------------------------------------------------------

--- Switch to a history entry and render its last-active tab (or blank the
--- panel for entries with no result tabs). Blocks on dirty edits, matching
--- tab-switch semantics.
--- @param idx number 1-based history index
--- Blank the dataset panel (nothing left to show): empty body, reset winbar,
--- drop search/cell extmarks. Shared by switch_history_entry (entry with no
--- result tabs) and delete_history_entry (last entry removed) — the delete
--- path used to keep the stale winbar advertising "N rows · P:x/y" over a
--- blank panel.
local function blank_dataset_panel()
  require("poste-db.buffer.header").close()
  if D.dataset_buffer and vim.api.nvim_buf_is_valid(D.dataset_buffer) then
    pcall(require("poste-db.buffer.search").apply_search_highlights)
    for _, ns_name in ipairs({ "poste_db_dataset_cell", "poste_db_dataset_cursorline" }) do
      vim.api.nvim_buf_clear_namespace(D.dataset_buffer,
        vim.api.nvim_create_namespace(ns_name), 0, -1)
    end
    vim.api.nvim_set_option_value("modifiable", true, { buf = D.dataset_buffer })
    vim.api.nvim_buf_set_lines(D.dataset_buffer, 0, -1, false, { "" })
    vim.api.nvim_set_option_value("modifiable", false, { buf = D.dataset_buffer })
  end
  set_dataset_winbar(require("poste-db.buffer.nav").build_status_winbar(nil))
end

function M.switch_history_entry(idx)
  local current = D.T()
  if current and current.edit_state and current.edit_state.dirty then
    vim.notify(C.EDIT_CONFLICT_MSG, vim.log.levels.WARN, { title = C.TITLE })
    return
  end
  save_active_tab_state()
  local entry = D.switch_entry(idx)
  if not entry then return end
  local tab_idx = entry.last_tab
  if tab_idx < 1 or not entry.tabs[tab_idx] then tab_idx = 1 end
  if entry.tabs[tab_idx] then
    D.active_tab_idx = tab_idx
    render_active_tab()
  else
    -- Entry with no result tabs (empty/error request): blank the panel
    blank_dataset_panel()
  end
  require("poste-db.buffer.history").refresh()
end

--- Next request in history (without opening the sidebar).
function M.history_next()
  local n = D.history_count()
  if n < 2 then return end
  local idx = D.active_history + 1
  if idx > n then idx = 1 end
  M.switch_history_entry(idx)
end

--- Previous request in history (without opening the sidebar).
function M.history_prev()
  local n = D.history_count()
  if n < 2 then return end
  local idx = D.active_history - 1
  if idx < 1 then idx = n end
  M.switch_history_entry(idx)
end

--- Delete a history entry; if the active entry was deleted, switch to the
--- entry now at the same index (or blank the panel when history is empty).
--- @param idx number 1-based history index
function M.delete_history_entry(idx)
  local n = D.history_count()
  if idx < 1 or idx > n then return end
  local was_active = (idx == D.active_history)
  D.delete_entry(idx)
  if n == 1 then
    -- history now empty: blank the panel
    blank_dataset_panel()
  elseif was_active then
    M.switch_history_entry(math.min(idx, D.history_count()))
  end
  require("poste-db.buffer.history").refresh()
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

local function finalize_rendered_page(tab, padded, meta)
  tab.padded = padded
  tab.meta = meta
  render.build_column_start_maps(tab, meta)

  local is_err = meta and meta.type == "error"
  local buf = is_err and M.get_error_buffer() or M.get_dataset_buffer()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, padded)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  sql_highlights.apply_dataset_highlights(buf, padded, meta)

  if tab.edit_state and tab.edit_state.dirty then
    sql_highlights.apply_edit_highlights(buf, tab)
  end

  set_dataset_winbar(require("poste-db.buffer.nav").build_status_winbar(meta))

  require("poste-db.buffer.search").apply_search_highlights()
end

local function render_dataset_layout(tab, lines, meta)
  local layout = tab.layout
  tab.rows_source = tab.rows_source or layout.rows
  tab.row_number_mode = tab.row_number_mode or "source"
  if not layout._conn_name then
    local conn_name = sql_state.context.connection
    if conn_name and conn_name ~= "" then layout._conn_name = conn_name end
  end
  if not layout._database then
    local db_name = sql_state.context.database
    if db_name and db_name ~= "" then layout._database = db_name end
  end
  if not layout._conn_name and tab.data and tab.data.connection then
    layout._conn_str = tab.data.connection
  end

  local padded, new_meta = render.normalize_rendered_page(tab, lines, meta)
  finalize_rendered_page(tab, padded, new_meta)
end

--- Process rendered table lines and write to buffer. Shared by
--- render_dataset and buffer_page.refresh_page. Handles header
--- extraction, padding, buffer write, highlights, winbar.
function M.apply_rendered_page(tab, lines, meta)
  local padded, new_meta = render.normalize_rendered_page(tab, lines, meta)
  finalize_rendered_page(tab, padded, new_meta)
end

--- Create the bottom split on first render (or after the old window's
--- tabpage died) and point it at the rendered buffer, restoring the source
--- window's view.
local function ensure_dataset_window(buf, is_error)
  if not D.dataset_window or not vim.api.nvim_win_is_valid(D.dataset_window)
      or (D.dataset_tabpage and vim.api.nvim_win_get_tabpage(D.dataset_window) ~= D.dataset_tabpage) then
    local src_win = vim.api.nvim_get_current_win()
    local src_view = vim.fn.winsaveview()
    local height = math.floor(vim.o.lines * C.DATASET_HEIGHT_RATIO)
    vim.cmd("botright " .. height .. "split")
    D.dataset_window = vim.api.nvim_get_current_win()
    D.dataset_tabpage = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_win(src_win)
    vim.fn.winrestview(src_view)
  end

  vim.api.nvim_win_set_buf(D.dataset_window, is_error and M.get_error_buffer() or buf)
  pcall(vim.api.nvim_win_call, D.dataset_window, function()
    vim.fn.winrestview({ leftcol = 0 })
  end)
end

--- Window-local options for the dataset split; the error variant wraps long
--- messages instead of scrolling horizontally.
local function apply_dataset_win_options(win, is_error)
  if is_error then
    vim.api.nvim_set_option_value("wrap", true, { win = win })
    vim.api.nvim_set_option_value("cursorline", false, { win = win })
    vim.api.nvim_set_option_value("conceallevel", 0, { win = win })
    vim.api.nvim_set_option_value("number", true, { win = win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = win })
    vim.api.nvim_set_option_value("signcolumn", "auto", { win = win })
    pcall(vim.api.nvim_set_option_value, "statuscolumn", "", { win = win })
    vim.api.nvim_set_option_value("foldcolumn", "0", { win = win })
    vim.api.nvim_set_option_value("foldenable", false, { win = win })
  else
    vim.api.nvim_set_option_value("wrap", false, { win = win })
    vim.api.nvim_set_option_value("sidescrolloff", 0, { win = win })
    vim.api.nvim_set_option_value("cursorline", false, { win = win })
    vim.api.nvim_set_option_value("cursorcolumn", false, { win = win })
    vim.api.nvim_set_option_value("conceallevel", 0, { win = win })
    vim.api.nvim_set_option_value("number", false, { win = win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = win })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
    pcall(vim.api.nvim_set_option_value, "statuscolumn", "", { win = win })
    vim.api.nvim_set_option_value("foldcolumn", "0", { win = win })
    vim.api.nvim_set_option_value("foldenable", false, { win = win })
  end
end

--- Rotate all four render autocmds: re-registering without deleting the
--- previous id leaks one global autocmd per render.
local function register_dataset_autocmds()
  if D.resize_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.resize_autocmd_id)
    D.resize_autocmd_id = nil
  end
  if D.scroll_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.scroll_autocmd_id)
    D.scroll_autocmd_id = nil
  end
  if D.vimresized_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.vimresized_autocmd_id)
    D.vimresized_autocmd_id = nil
  end
  if D.winclose_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.winclose_autocmd_id)
    D.winclose_autocmd_id = nil
  end
  if D.dataset_buffer then
    D.resize_autocmd_id = vim.api.nvim_create_autocmd("WinResized", {
      callback = function()
        require("poste-db.buffer.header").update()
        ensure_dataset_visible()
      end,
    })
    -- Whole-editor resize (terminal grew/shrunk): re-apply the dataset's
    -- share so the split cannot collapse to just its winbar.
    D.vimresized_autocmd_id = vim.api.nvim_create_autocmd("VimResized", {
      callback = function()
        ensure_dataset_visible()
      end,
    })
    D.scroll_autocmd_id = vim.api.nvim_create_autocmd("WinScrolled", {
      buffer = D.dataset_buffer,
      callback = function()
        require("poste-db.buffer.header").update()
      end,
    })
    D.winclose_autocmd_id = vim.api.nvim_create_autocmd("WinClosed", {
      callback = function()
        vim.schedule(function()
          require("poste-db.buffer.header").update()
        end)
      end,
    })
  end
end

--- Initial cursor: errors park on line 1; resultsets focus the first cell
--- (unless a sort re-render should keep the cursor untouched).
local function place_dataset_cursor(tab, meta, is_error)
  if is_error then
    pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { 1, 0 })
  elseif not tab.is_sorting then
    if meta and meta.type == "resultset" and meta.row_count > 0 then
      sql_state.cell.row = 1
      sql_state.cell.col = 1
      pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { meta.data_start_line, 0 })
      local cs = tab.buffer_col_starts and tab.buffer_col_starts[meta.data_start_line]
      sql_highlights.highlight_cell(D.dataset_buffer, 1, 1, meta, nil, cs)
    else
      pcall(vim.api.nvim_win_set_cursor, D.dataset_window, { 1, 0 })
    end
  end
end

function M.render_dataset(lines, meta, opts)
  opts = opts or {}
  local tab_idx = opts.tab_index or 1
  local is_error = meta and meta.type == "error"

  if opts.exec_seq then
    local sql_runner = require("poste-db.sql_runner")
    if opts.exec_seq < sql_runner.get_exec_seq() then
      return
    end
  end

  if tab_idx == 1 and not opts.keep_tabs then
    -- Clear the active request's tabs (history entry stays; its fresh tabs
    -- table is reused, or a new entry is auto-created for legacy callers).
    D.reset_active_entry_tabs()
  end

  require("poste-db.buffer.header").close()

  local tab = D.alloc_tab(tab_idx)
  D.active_tab_idx = tab_idx

  local buf = M.get_dataset_buffer()

  if tab.is_sorting then  -- luacheck: ignore 542
  else
    tab.sort = nil
    tab.original_rows = nil
  end

  if meta and meta.type == "resultset" then
    local data = opts.data
    if not data then
      if opts.keep_tabs then
        data = tab.data
      else
        local ok, d = pcall(vim.json.decode, sql_state.last_response and sql_state.last_response.body or "{}")
        if ok then data = d end
      end
    end
    if data then
      tab.data = data
      sql_state.last_dataset = data
    end
  end

  if not tab.is_sorting then
    tab.cursor = { row = 1, col = 1 }
  end

  -- Layout-aware path: store layout, render current page. All resultset
  -- renders arrive with a layout (format_dataset/format_resultset provide
  -- one); non-resultset pages (error/affected/use/raw) just normalize+write.
  if opts.layout and meta and meta.type == "resultset" then
    tab.layout = opts.layout
    tab.rows_source = tab.rows_source or opts.layout.rows
    tab.view_indices = opts.view_indices or nil
    tab.row_number_mode = opts.row_number_mode or "source"

    -- Store original SQL for JOIN detection
    if opts.original_sql then
      tab.original_sql = opts.original_sql
    end

    -- Store source file path for PK introspection (poste needs a real file for connections.toml discovery)
    if opts.src_file then
      tab.src_file = opts.src_file
    end
    -- Store source buffer handle for rerun after commit
    if opts.src_buf then
      tab.src_buf = opts.src_buf
    end

    -- Store connection name & database for dataset operations (commit, refresh, PK introspection)
    -- These persist even if sql_state.context is cleared later
    local conn_name = sql_state.context.connection
    if conn_name and conn_name ~= "" then
      tab.layout._conn_name = conn_name
    end
    local db_name = sql_state.context.database
    if db_name and db_name ~= "" then
      tab.layout._database = db_name
    end
    -- Also try to get from data response (full connection string → extract name later)
    if not tab.layout._conn_name and tab.data and tab.data.connection then
      tab.layout._conn_str = tab.data.connection
    end

    -- Sync table_name from meta to layout if missing
    if meta.table_name and (not tab.layout.table_name or tab.layout.table_name == "") then
      tab.layout.table_name = meta.table_name
    end

    -- The row set can shrink under a filter without any paginated math running,
    -- so the count is recomputed on both branches — a stale one leaves the
    -- winbar pointing at pages that aren't there.
    local total_for_pagination = meta.total_rows or meta.row_count
    local pages = D.apply_page_bounds(tab, total_for_pagination)
    if tab.pagination_enabled and pages > 1 then
      tab.visible_rows = tab.page_size
    else
      tab.visible_rows = meta.row_count
    end

    render_dataset_layout(tab, lines, meta)
  else
    M.apply_rendered_page(tab, lines, meta)
  end

  ensure_dataset_window(buf, is_error)

  apply_dataset_win_options(D.dataset_window, is_error)

  if not is_error then
    local winbar_text = require("poste-db.buffer.nav").build_status_winbar(meta)
    if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
      pcall(vim.api.nvim_set_option_value, "winbar", winbar_text or "", { win = D.dataset_window })
    end

    if tab.header_text then
      require("poste-db.buffer.header").update()
    end
  end

  if not is_error then
    register_dataset_autocmds()
  end

  place_dataset_cursor(tab, meta, is_error)

  if not is_error then
    vim.api.nvim_set_option_value("sidescrolloff", 5, { win = D.dataset_window })
  end

  local history = require("poste-db.buffer.history")
  if history.is_open() then history.refresh() end
end

--------------------------------------------------------------------------------
-- Panel clear / Close
--------------------------------------------------------------------------------

function M.clear_panel()
  -- Keep the active history entry's tabs; only blank the visible panel so
  -- results can stream in. (Tab tables are reset by the request starter /
  -- render_dataset via D.reset_active_entry_tabs().)
  -- header.close() sweeps the anchored floats (keeping the request-history
  -- sidebar open across executions) and closes the header float; the inline
  -- copy of the same sweep this used to run first was dead weight.
  require("poste-db.buffer.header").close()
  if D.dataset_buffer and vim.api.nvim_buf_is_valid(D.dataset_buffer) then
    vim.api.nvim_set_option_value("modifiable", true, { buf = D.dataset_buffer })
    vim.api.nvim_buf_set_lines(D.dataset_buffer, 0, -1, false, { "" })
    vim.api.nvim_set_option_value("modifiable", false, { buf = D.dataset_buffer })
  end
end

function M.close()
  if D.resize_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.resize_autocmd_id)
    D.resize_autocmd_id = nil
  end
  if D.vimresized_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.vimresized_autocmd_id)
    D.vimresized_autocmd_id = nil
  end
  if D.scroll_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.scroll_autocmd_id)
    D.scroll_autocmd_id = nil
  end
  if D.winclose_autocmd_id then
    pcall(vim.api.nvim_del_autocmd, D.winclose_autocmd_id)
    D.winclose_autocmd_id = nil
  end
  -- No keep_history on teardown: the history sidebar belongs to the dataset
  -- window and goes with it.
  require("poste-db.buffer.header").close_anchored_windows(false)
  require("poste-db.buffer.header").close()
  if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
    vim.api.nvim_win_close(D.dataset_window, true)
    D.dataset_window = nil
  end
  sql_highlights.clear_cell_highlight(D.dataset_buffer)
  require("poste-db.buffer.history").close()
  D.tabs = {}
  D.active_tab_idx = 0
  D.history = {}
  D.active_history = 0
end

function M.is_open()
  return D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window)
end

M._test = {
  compute_dataset_height = compute_dataset_height,
  ensure_dataset_visible = ensure_dataset_visible,
  set_header = function(header)
    local tab = D.alloc_tab(1)
    tab.header_text = header
    tab.header_index = header and require("poste-db.buffer.header").build_header_index("  " .. header) or nil
  end,
  reset = function()
    D.tabs = {}
    D.active_tab_idx = 0
    D.history = {}
    D.active_history = 0
    D.buf_label_count = {}
  end,
  tab_count = function() return #D.tabs end,
  active_tab_idx = function() return D.active_tab_idx end,
  create_tab = function(idx, overrides)
    local tab = D.alloc_tab(idx)
    if overrides then
      for k, v in pairs(overrides) do tab[k] = v end
    end
    return tab
  end,
  get_tab = function(idx)
    local t = D.tabs[idx]
    if not t then return nil end
    return {
      meta = t.meta,
      sort = t.sort,
      original_rows = t.original_rows,
      is_sorting = t.is_sorting,
      data = t.data,
      cursor = { row = t.cursor.row, col = t.cursor.col },
      leftcol = t.leftcol,
      header_text = t.header_text,
      header_index = t.header_index,
      has_padded = t.padded ~= nil,
    }
  end,
  set_active = function(idx)
    local old = D.active_tab_idx
    D.active_tab_idx = idx
    return old
  end,
  normalize_rendered_page = function(tab, lines, meta)
    return render.normalize_rendered_page(tab, lines, meta)
  end,
}

return M
