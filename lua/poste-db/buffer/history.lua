--- Dataset request history sidebar — JetBrains-style list of executed
--- requests. One entry per request (one result set, possibly multi-tab);
--- moving across items switches the rendered dataset.
---
--- Implemented as a floating window anchored to the left edge of the
--- dataset window (v1). Keymaps inside the sidebar:
---   j/k        move selection
---   <CR>       switch to the selected request
---   d          delete the selected request
---   q / <Esc>  close the sidebar

local D = require("poste-db.dataset")
local float_window = require("poste-db.float_window")

local M = {}

local SIDEBAR_WIDTH = 40
local LABEL_COL_WIDTH = 18

local buf = nil
local win = nil
local hl_ns = vim.api.nvim_create_namespace("poste_db_history")

local update_sql_statusline  -- forward declaration (refresh ⇢ update_sql_statusline)

local width = require("poste-db.width")

--- Display width through width.lua (nvim-grid oracle; see LEARNINGS #16 —
--- raw strdisplaywidth folds Indic Mc marks to 0).
local function display_width(s)
  return width.display_width(s or "")
end

--- Truncate a string to `max_width` display cells, reserving one cell for
--- the trailing ellipsis (width.truncate_ellipsis — see lua/poste-db/width.lua).
local truncate_display = width.truncate_ellipsis

--- Build the sidebar lines: `[i] label  time`, active marked with ▸,
--- errors prefixed with ✗. The time column shows the wall-clock moment the
--- request executed (HH:MM:SS.mmm) and is right-aligned to the window's right
--- edge (SIDEBAR_WIDTH); the label is truncated so it never overlaps.
--- Entries are shown newest-first (reverse execution order).
local function build_lines()
  local lines = {}
  local n = #D.history
  for offset = 0, n - 1 do
    local i = n - offset
    local entry = D.history[i]
    local label = truncate_display(entry.label or "?", LABEL_COL_WIDTH)
    local marker = entry.error and "✗" or (i == D.active_history and "▸" or " ")
    local time = D.format_wallclock(entry.ts_sec, entry.ts_nsec)
    local left = string.format("%s[%d] %s", marker, i, label)
    local gap = math.max(1, SIDEBAR_WIDTH - display_width(left) - display_width(time))
    lines[#lines + 1] = left .. string.rep(" ", gap) .. time
  end
  if #lines == 0 then
    lines[1] = "  (no history)"
  end
  return lines
end

--- Display line number → history index (entries render newest-first).
local function line_to_index(lnum)
  return #D.history - lnum + 1
end

--- Re-render the sidebar content and highlights (safe no-op when closed).
--- Also keeps the sidebar's own statusline in sync with the item under the
--- cursor (shows that request's SQL instead of the scratch-buffer default).
function M.refresh()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  update_sql_statusline()
  local lines = build_lines()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  local active_line = D.active_history >= 1 and D.active_history <= #D.history
    and line_to_index(D.active_history) or 0
  if active_line >= 1 and active_line <= #lines then
    vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteDbDatasetSearchCurrent",
      active_line - 1, 0, -1)
  end
  for offset = 0, #D.history - 1 do
    local entry = D.history[#D.history - offset]
    if entry.error then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "DiagnosticError", offset, 0, 1)
    end
    local time = D.format_wallclock(entry.ts_sec, entry.ts_nsec)
    local start = SIDEBAR_WIDTH - display_width(time)
    vim.api.nvim_buf_add_highlight(buf, hl_ns, "Comment", offset, start, -1)
  end
end

local function set_cursor_line(lnum)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local n = D.history_count()
  if n == 0 then return end
  vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(lnum, n)), 0 })
end

local activate  -- forward declaration (move ⇢ activate)

--- Show the SQL of the history item under the cursor in the sidebar's own
--- statusline. Falls back to the default statusline when there's no SQL.
update_sql_statusline = function()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local entry = D.history[line_to_index(lnum)]
  local sql = entry and entry.sql
  -- Under globalstatus the sidebar's statusline spans the full editor width,
  -- so truncate to that; otherwise the float renders its own 40-col bar.
  local bar_width
  if vim.api.nvim_get_option_value("laststatus", {}) >= 3 then
    bar_width = vim.api.nvim_get_option_value("columns", {})
  else
    bar_width = vim.api.nvim_win_get_width(win)
  end
  local nav_ui = require("poste-db.buffer.nav_ui")
  local text = nav_ui.build_sql_statusline(sql, bar_width)
  pcall(vim.api.nvim_set_option_value, "statusline", text, { win = win })
  vim.cmd("redrawstatus")
end

local function move(rel)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  set_cursor_line(cur + rel)
  activate()
end

activate = function()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  require("poste-db.buffer").switch_history_entry(line_to_index(lnum))
  M.refresh()
end

local function delete_current()
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  require("poste-db.buffer").delete_history_entry(line_to_index(lnum))
  M.refresh()
  set_cursor_line(math.min(lnum, D.history_count()))
end

--- Activate the item under the cursor and close the sidebar.
local function activate_and_close()
  activate()
  M.close()
end

--- Open the sidebar (re-focus if already open).
function M.open()
  local dataset_win = D.dataset_window
  if not dataset_win or not vim.api.nvim_win_is_valid(dataset_win) then return end
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    return
  end

  local dh = vim.api.nvim_win_get_height(dataset_win)
  local winbar_rows = vim.api.nvim_get_option_value("winbar", { win = dataset_win }) ~= "" and 1 or 0
  local height = math.max(2, dh - winbar_rows - 3)
  buf, win = float_window.open({
    relative = "win",
    win = dataset_win,
    row = 0,
    col = 0,
    width = SIDEBAR_WIDTH,
    height = height,
    filetype = "poste_history",
    border = "single",
    title = "History",
    title_pos = "left",
    buf_options = { buftype = "nofile", bufhidden = "wipe", swapfile = false },
    -- Highlight the line under the cursor while navigating (j/k); the active
    -- request keeps its own background marker via extmark in refresh().
    win_options = { cursorline = true },
  })

  local km = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "j", function() move(1) end, km)
  vim.keymap.set("n", "k", function() move(-1) end, km)
  vim.keymap.set("n", "<CR>", activate_and_close, km)
  vim.keymap.set("n", "d", delete_current, km)
  vim.keymap.set("n", "q", M.close, km)
  vim.keymap.set("n", "<Esc>", M.close, km)

  M.refresh()
  if D.active_history >= 1 then
    set_cursor_line(line_to_index(D.active_history))
  end
end

function M.toggle()
  if win and vim.api.nvim_win_is_valid(win) then
    M.close()
  else
    M.open()
  end
end

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win = nil
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  buf = nil
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Sidebar buffer handle (for tests).
function M.buf()
  return buf
end

--- Sidebar window handle (for tests).
function M.win()
  return win
end

return M
