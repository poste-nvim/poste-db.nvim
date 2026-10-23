local ts_stmt = require("poste-db.ts_stmt")
local state = require("poste-db.state")
local config = require("poste-db.config")
local util = require("poste-db.util")
local const = require("poste-db.constants")

local M = {}

local _disabled = false

local ns = vim.api.nvim_create_namespace("poste_db_boundary")

-- Row tint behind the statement under the cursor, per Normal's darkness. The
-- dark navy keeps default-light text readable on dark themes; the same navy on
-- a light theme puts dark text on a dark row. No fg is set either way — the
-- text keeps the theme's Normal fg.
local BOUNDARY_BG_DARK = 0x24293f
local BOUNDARY_BG_LIGHT = 0xd6e4ff

local function boundary_bg()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
  if util.is_dark_color(normal and normal.bg) then
    return BOUNDARY_BG_DARK
  end
  return BOUNDARY_BG_LIGHT
end

function M.setup()
  -- Deliberately unguarded: init.lua's ColorScheme autocmd re-runs setup() so
  -- a :colorscheme switch re-picks the bg (a first-run guard used to defeat
  -- exactly that and left the previous theme's bg behind).
  vim.api.nvim_set_hl(0, "PosteDbSqlBoundary", { bg = boundary_bg() })
  -- The "gutter" style marks only the number column of the block. It links to
  -- the rectangle so one override recolours both; a `bg` of its own would
  -- drift from whatever theme the user pointed the rectangle at.
  vim.api.nvim_set_hl(0, "PosteDbSqlBoundaryGutter", { link = "PosteDbSqlBoundary" })
  state.apply_highlight_overrides({ "PosteDbSqlBoundary", "PosteDbSqlBoundaryGutter" })
end

-- Last applied span (1-based, inclusive) so cursor moves inside the same
-- statement do zero work: no extmark clear/re-paint, no re-read.
-- Keeps the boundary painting on the same redraw as the cursor, like
-- the native cursorline.
local _last_applied = { buf = nil, s = nil, e = nil }

local function clear_all(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

local function reset_last_applied()
  _last_applied.buf = nil
  _last_applied.s = nil
  _last_applied.e = nil
end

local function paint_background(buf, start, stop)
  for line = start, stop do
    vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      end_row = line + 1,
      end_col = 0,
      hl_group = "PosteDbSqlBoundary",
      hl_eol = true,
      hl_mode = "combine",
    })
  end
end

--- Only the number column of each line — the text itself is left alone, and
--- with it the colours the parser put there.
local function paint_gutter(buf, start, stop)
  for line = start, stop do
    vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      number_hl_group = "PosteDbSqlBoundaryGutter",
    })
  end
end

local function apply_range(buf, start, stop)
  clear_all(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    reset_last_applied()
    return
  end
  -- Don't show boundary for single-line statements
  if start == stop then
    reset_last_applied()
    return
  end

  if config.config.boundary_style == "gutter" then
    paint_gutter(buf, start, stop)
  else
    paint_background(buf, start, stop)
  end
  _last_applied.buf = buf
  _last_applied.s = start + 1
  _last_applied.e = stop + 1
end

local function fetch_and_highlight(buf, cursor_line)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    reset_last_applied()
    return
  end

  local span = ts_stmt.find_stmt_span(buf, cursor_line)

  -- Cursor in a gap (blank/comment region) → no statement → clear any highlight
  if not span then
    clear_all(buf)
    reset_last_applied()
    return
  end

  local s, e = span[1], span[2]

  if s == e then
    local line_text = vim.api.nvim_buf_get_lines(buf, s - 1, s, false)[1] or ""
    if line_text:match("^%s*$") then
      clear_all(buf)
      reset_last_applied()
      return
    end
  end

  local lines = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)
  local has_content = false
  for _, line in ipairs(lines) do
    local trimmed = (line or ""):match("^%s*(.*)$")
    if trimmed ~= "" and not trimmed:match("^%-%-") then
      has_content = true
      break
    end
  end
  if not has_content then
    clear_all(buf)
    reset_last_applied()
    return
  end

  -- Cursor still inside the already-painted span → nothing to repaint
  if _last_applied.buf == buf
    and _last_applied.s == s
    and _last_applied.e == e then
    return
  end

  apply_range(buf, s - 1, e - 1)
end

function M.update(buf, cursor_line)
  if _disabled then return end
  fetch_and_highlight(buf, cursor_line)
end

function M.clear(buf)
  clear_all(buf)
  reset_last_applied()
end

function M.toggle()
  _disabled = not _disabled
  if _disabled then
    M.clear(vim.api.nvim_get_current_buf())
    vim.notify("SQL boundary highlight: OFF", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
  else
    M.update(vim.api.nvim_get_current_buf(), vim.fn.line("."))
    vim.notify("SQL boundary highlight: ON", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
  end
end

vim.api.nvim_create_user_command("PosteDbBoundary", function()
  require("poste-db.statement_indicator").toggle()
end, { desc = "Toggle SQL statement boundary highlight" })

M._test = {
  get_ns = function() return ns end,
  get_last_applied = function() return _last_applied end,
}

return M
