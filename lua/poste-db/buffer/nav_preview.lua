--- Dataset cell preview --- floating window for cell value inspection.
local M = {}
local const = require("poste-db.constants")
local float_window = require("poste-db.float_window")
local util = require("poste-db.util")

function M.build_preview_lines(text)
  local lines = {}
  for line in util.each_line(text) do
    lines[#lines + 1] = line
  end
  return lines
end

--- Size a preview float for `lines`. Width tracks content (capped), height
--- accounts for soft-wrapped rows, both scaled against the whole editor.
--- Wrapping also applies to pre-wrapped lines (long single-line cells).
---
--- @param lines string[]         Preview content (unsplit lines)
--- @param opts? table            width_ratio/max_width/height_ratio/padding, defaults from constants
--- @return number width, number height
function M.compute_preview_size(lines, opts)
  opts = opts or {}
  local width_ratio = opts.width_ratio or const.FLOAT_WIDTH_RATIO
  local max_width = opts.max_width or const.FLOAT_MAX_WIDTH
  local height_ratio = opts.height_ratio or const.FLOAT_HEIGHT_RATIO
  local width_padding = opts.width_padding or 2

  local width = 0
  for _, line in ipairs(lines or {}) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  if opts.title then
    width = math.max(width, vim.fn.strdisplaywidth(opts.title))
  end
  local max_w = math.min(math.floor((vim.o.columns or 80) * width_ratio), max_width)
  width = math.min(width + width_padding, max_w)

  local inner = math.max(1, width - 2)
  local height = 0
  for _, line in ipairs(lines or {}) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / inner))
  end
  local max_h = math.floor((vim.o.lines or 24) * height_ratio)
  height = math.max(1, math.min(height, max_h))

  return width, height
end

--- Open a cursor-anchored float sized against the editor, not the dataset
--- window. `vim.lsp.util.open_floating_preview` clamps the float to the
--- current window's width and wraps at it, so a long cell squeezed into the
--- narrow split produced a ~2-row tall popup that needed constant scrolling.
function M.open_preview_float(title, text, ft)
  local lines = M.build_preview_lines(text)
  local width, height = M.compute_preview_size(lines, { title = title })

  -- Anchor against the whole editor, not the (possibly small) dataset window,
  -- so the preview isn't squashed to the window's height. Use the cursor's
  -- absolute screen position and always show at least 3 rows of a tall value.
  local winid = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local pos = vim.fn.screenpos(winid, cursor[1], cursor[2])
  local cursor_row = pos and pos.row or 1
  local cursor_col = pos and pos.col or 1

  local MIN_PREVIEW_HEIGHT = 3
  local lines_below = math.max(vim.o.lines - cursor_row, 0)
  local lines_above = math.max(cursor_row - 1, 0)
  local row
  if height <= lines_below then
    row = 1
  else
    local min_h = math.min(height, MIN_PREVIEW_HEIGHT)
    height = math.max(math.min(height, lines_above), min_h)
    row = -height
  end

  -- Keep the float inside the editor when the cursor sits near the right edge.
  local col = 0
  if cursor_col + width > vim.o.columns then
    col = math.max(vim.o.columns - width - cursor_col, -cursor_col)
  end

  local win_opts = {
    relative = "cursor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "rounded",
    title = title,
    title_pos = "left",
    lines = lines,
    syntax = ft,
    buf_options = { bufhidden = "wipe" },
    win_options = {
      wrap = true,
      linebreak = true,
      smoothscroll = true,
      scrolloff = 1,
      cursorline = true,
    },
  }
  local buf, win = float_window.open(win_opts)

  return buf, win
end

function M.set_preview_keymaps(buf, close_fn)
  float_window.bind_keys(buf, {
    { "n", "q", close_fn },
    { "n", "<Esc>", close_fn },
  })
end

return M
