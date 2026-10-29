--- Shared floating-window primitives for poste-db.
--- All scratch floats (previews, dialogs, menus, sidebars) go through
--- open()/open_centered(); window creation, the title fallback and keymap
--- binding live here instead of being re-implemented per call site.
local M = {}
local const = require("poste-db.constants")

--- Open a buffer window, retrying once without title for clients that
--- reject title options. Errors from the retry propagate.
local function open_win(buf, enter, win_opts)
  if win_opts.title == nil then
    return vim.api.nvim_open_win(buf, enter, win_opts)
  end
  local ok, win = pcall(vim.api.nvim_open_win, buf, enter, win_opts)
  if ok then return win end
  local fallback = vim.tbl_extend("force", win_opts, { title = nil, title_pos = nil })
  return vim.api.nvim_open_win(buf, enter, fallback)
end

--- Compute centered editor dimensions for `lines`.
function M.centered_dimensions(lines, opts)
  opts = opts or {}
  local width_ratio = opts.width_ratio or const.FLOAT_WIDTH_RATIO
  local max_width = opts.max_width or const.FLOAT_MAX_WIDTH
  local min_width = opts.min_width or 10
  local width_padding = opts.width_padding or 2
  local height_ratio = opts.height_ratio or const.FLOAT_HEIGHT_RATIO
  local min_height = opts.min_height or 3
  local extra_height = opts.extra_height or 1

  local width = 0
  for _, line in ipairs(lines or {}) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(min_width, math.min(width + width_padding, math.min(math.floor(vim.o.columns * width_ratio), max_width)))

  local height = math.floor(vim.o.lines * height_ratio)
  height = math.max(min_height, math.min((lines and #lines or 0) + extra_height, height))

  return {
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  }
end

--- Legacy centered helper (search prompt). Kept for its option surface
--- (`win_opts` override, `win_opts_apply` callback); new call sites should
--- use M.open().
function M.open_centered(lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local dims = M.centered_dimensions(lines, opts)
  local win_opts = {
    relative = "editor",
    width = dims.width,
    height = dims.height,
    row = dims.row,
    col = dims.col,
    style = "minimal",
    border = opts.border or "rounded",
    title = opts.title,
    title_pos = opts.title_pos or "left",
  }
  if opts.win_opts then
    win_opts = vim.tbl_extend("force", win_opts, opts.win_opts)
  end

  local ok, win = pcall(vim.api.nvim_open_win, buf, true, win_opts)
  if not ok then
    win_opts.title = nil
    win_opts.title_pos = nil
    win = vim.api.nvim_open_win(buf, true, win_opts)
  end

  if opts.winhl then
    vim.api.nvim_set_option_value("winhl", opts.winhl, { win = win })
  end
  if opts.win_opts_apply then
    opts.win_opts_apply(buf, win)
  end

  return buf, win
end

--- Open a scratch floating window.
---
--- opts:
---   lines        string[]        content for the scratch buffer
---   buf          number          reuse this buffer instead of creating one
---   filetype     string          buffer filetype
---   syntax       string          buffer syntax
---   buf_options  table           buffer-local options (applied after content)
---   modifiable   boolean         leave the buffer modifiable (default false)
---   enter        boolean         focus the window (default true)
---   relative     string          "editor" | "win" | "cursor" (default "editor")
---   win          number          anchor window for relative="win"
---   width/height/row/col/anchor/zindex/focusable
---   border       string|boolean  (default "rounded")
---   title        string          (enables the title fallback retry)
---   title_pos    string          (default "left")
---   winhl        string          window highlight
---   win_options  table           window-local options applied after open
---   close_keys   string[]        lhs list bound to close the float
---   close_modes  string[]        modes for close_keys (default { "n" })
---   on_winleave  boolean|function  close on WinLeave, or callback(win)
---
--- Returns buf, win; win is nil when the open failed (caller decides whether
--- to clean up the buffer).
function M.open(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_create_buf(false, true)
  -- A fresh scratch buffer wipes when its last window closes: the close
  -- paths below (on_winleave / close_keys) only close the window, and every
  -- open used to leak one unlisted buffer plus its buffer-local autocmds.
  -- Caller-supplied buffers (opts.buf) keep the caller's own lifecycle —
  -- they may be shown again. The same idiom log_viewer passes via buf_options.
  if not opts.buf then
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  end

  if opts.lines then
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
    if not opts.modifiable then
      vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    end
  end
  if opts.filetype then
    vim.api.nvim_set_option_value("filetype", opts.filetype, { buf = buf })
  end
  if opts.syntax then
    vim.api.nvim_set_option_value("syntax", opts.syntax, { buf = buf })
  end
  for k, v in pairs(opts.buf_options or {}) do
    vim.api.nvim_set_option_value(k, v, { buf = buf })
  end

  local win_opts = {
    relative = opts.relative or "editor",
    style = "minimal",
    border = opts.border ~= nil and opts.border or "rounded",
  }
  if opts.win then win_opts.win = opts.win end
  if opts.anchor then win_opts.anchor = opts.anchor end
  if opts.width then win_opts.width = opts.width end
  if opts.height then win_opts.height = opts.height end
  if opts.row then win_opts.row = opts.row end
  if opts.col then win_opts.col = opts.col end
  if opts.zindex then win_opts.zindex = opts.zindex end
  if opts.focusable ~= nil then win_opts.focusable = opts.focusable end
  if opts.title then
    win_opts.title = opts.title
    win_opts.title_pos = opts.title_pos or "left"
  end

  local ok, win = pcall(open_win, buf, opts.enter ~= false, win_opts)
  if not ok then
    return buf, nil
  end

  if opts.winhl then
    vim.api.nvim_set_option_value("winhl", opts.winhl, { win = win })
  end
  for k, v in pairs(opts.win_options or {}) do
    vim.api.nvim_set_option_value(k, v, { win = win })
  end

  if opts.close_keys then
    local maps = {}
    for _, key in ipairs(opts.close_keys) do
      for _, mode in ipairs(opts.close_modes or { "n" }) do
        maps[#maps + 1] = { mode, key, function()
          pcall(vim.api.nvim_win_close, win, true)
        end }
      end
    end
    M.bind_keys(buf, maps)
  end

  if opts.on_winleave then
    vim.api.nvim_create_autocmd("WinLeave", {
      -- Grouped per open so nothing accumulates ungrouped; buffer-local, so
      -- the bufhidden=wipe above (fresh buffers) also removes it.
      group = vim.api.nvim_create_augroup("PosteDbFloatWinLeave_" .. buf, { clear = true }),
      buffer = buf,
      callback = function()
        if type(opts.on_winleave) == "function" then
          opts.on_winleave(win)
        else
          pcall(vim.api.nvim_win_close, win, true)
        end
      end,
    })
  end

  return buf, win
end

--- Bind a list of { mode, lhs, rhs, opts? } keymaps to a buffer.
function M.bind_keys(buf, maps)
  for _, m in ipairs(maps) do
    vim.keymap.set(m[1], m[2], m[3], m[4] or { buffer = buf, noremap = true, silent = true })
  end
end

return M
