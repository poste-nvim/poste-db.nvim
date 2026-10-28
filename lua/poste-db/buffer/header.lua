--- Dataset header float --- owns the floating header window that follows
--- horizontal scroll, plus the slicing helpers behind it. No poste deps
--- beyond dataset state; all float state is module-local.
local D = require("poste-db.dataset")
local sql_state = require("poste-db.state")

local util = require("poste-db.util")
local width = require("poste-db.width")
local float_window = require("poste-db.float_window")

local M = {}

local float_buf = nil
local float_win = nil
local cache_leftcol = nil
local cache_width = nil
local cache_header = nil

--- Build a per-character display index of a line: byte range + display
--- range per char, with │ marked as separators.
function M.build_header_index(line)
  local sep = "│"
  local sep_len = #sep
  local index = {}
  local disp_pos = 0
  local byte_idx = 1
  while byte_idx <= #line do
    local char_bytes, char_width, is_sep
    if line:sub(byte_idx, byte_idx + sep_len - 1) == sep then
      char_bytes, char_width, is_sep = sep_len, 1, true
    else
      local b = line:byte(byte_idx)
      char_bytes = util.utf8_char_bytes(b)
      if byte_idx + char_bytes - 1 > #line then char_bytes = #line - byte_idx + 1 end
      -- The SAME width oracle the data cells use (width.lua): raw
      -- strdisplaywidth folded Indic Mc marks to 0 in every width mode, and
      -- the manual 0→1 bump then misaligned the float against the grid the
      -- data rows were padded to.
      char_width = width.display_width(line:sub(byte_idx, byte_idx + char_bytes - 1))
      is_sep = false
    end
    index[#index + 1] = { bs=byte_idx, be=byte_idx+char_bytes-1,
                          ds=disp_pos, de=disp_pos+char_width, sep=is_sep }
    disp_pos = disp_pos + char_width
    byte_idx = byte_idx + char_bytes
  end
  return index
end

--- Slice the padded header to the visible viewport, per char. Char-level
--- display math keeps multibyte names and sort indicators aligned; chars
--- straddling the window edges become blanks so no phantom separators
--- appear.
--- @param leftcol number Display-width offset of viewport left edge
--- @param win_width number Viewport width in display columns
--- @param padded_header string Header line with padding (includes D.LEFT_PADDING)
--- @param index table[] Per-char index from build_header_index()
--- @return string Sliced header text
function M.slice_header_to_win(leftcol, win_width, padded_header, index)
  if not padded_header or not index then return D.PADDING_SPACES end
  local right_edge = leftcol + win_width

  local parts = {}
  for _, c in ipairs(index) do
    if c.de <= leftcol then goto continue end
    if c.ds >= right_edge then break end

    local text
    if c.ds < leftcol then
      text = string.rep(" ", math.min(c.de, right_edge) - leftcol)
    elseif c.de > right_edge then
      text = string.rep(" ", right_edge - c.ds)
    else
      text = padded_header:sub(c.bs, c.be)
    end
    parts[#parts + 1] = text

    ::continue::
  end

  if #parts == 0 then return D.PADDING_SPACES end
  return table.concat(parts)
end

--- Close every window anchored to the dataset window. `keep_history` keeps
--- the request-history sidebar (filetype `poste_history`) open — the
--- clear-panel and pre-render sweeps want that; a full teardown does not.
--- The sweep used to be hand-copied three times.
function M.close_anchored_windows(keep_history)
  local win = D.dataset_window
  if win and vim.api.nvim_win_is_valid(win) then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= win then
        local ok, config = pcall(vim.api.nvim_win_get_config, w)
        if ok and config.relative == "win" and config.win == win then
          local wbuf = vim.api.nvim_win_get_buf(w)
          local is_history = vim.api.nvim_buf_is_valid(wbuf)
            and vim.bo[wbuf].filetype == "poste_history"
          if not (keep_history and is_history) then
            pcall(vim.api.nvim_win_close, w, true)
          end
        end
      end
    end
  end
end

--- Close the header float and any other window anchored to the dataset
--- window, then reset the slice cache. The request-history sidebar
--- (filetype `poste_history`) is intentionally kept open.
function M.close()
  M.close_anchored_windows(true)
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    pcall(vim.api.nvim_win_close, float_win, true)
  end
  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    pcall(vim.api.nvim_buf_delete, float_buf, { force = true })
  end
  float_win = nil
  float_buf = nil
  cache_leftcol = nil
  cache_width = nil
  cache_header = nil
end

--- Re-render the header float for the current viewport. Cache-hit when
--- leftcol/width/header text are unchanged, so WinScrolled redraws and the
--- explicit calls after moves are cheap.
function M.update()
  local tab = D.T()
  if not tab or not tab.header_text or not D.dataset_window then return end
  if not vim.api.nvim_win_is_valid(D.dataset_window) then return end
  if sql_state._hide_header_float then M.close(); return end

  local win_width = vim.api.nvim_win_get_width(D.dataset_window)
  if win_width <= 0 then return end

  local leftcol
  if vim.api.nvim_get_current_win() == D.dataset_window then
    leftcol = vim.fn.winsaveview().leftcol
  else
    leftcol = vim.api.nvim_win_call(D.dataset_window, function()
      return vim.fn.winsaveview().leftcol
    end)
  end

  if leftcol == cache_leftcol and win_width == cache_width
     and tab.header_text == cache_header then
    return
  end
  cache_leftcol = leftcol
  cache_width = win_width
  cache_header = tab.header_text

  local padded = D.PADDING_SPACES .. tab.header_text
  local index = tab.header_index or M.build_header_index(padded)
  local text = M.slice_header_to_win(leftcol, win_width, padded, index)

  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = float_buf })
    pcall(vim.api.nvim_buf_set_lines, float_buf, 0, -1, false, { text })
    pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = float_buf })
    if float_win and vim.api.nvim_win_is_valid(float_win) then
      if vim.api.nvim_win_get_width(float_win) ~= win_width then
        vim.api.nvim_win_set_config(float_win, { width = win_width })
      end
      return
    end
  end

  M.close()
  float_buf, float_win = float_window.open({
    lines = { text },
    relative = "win",
    win = D.dataset_window,
    row = 0,
    col = 0,
    width = win_width,
    height = 1,
    border = "none",
    focusable = false,
    zindex = 40,
    enter = false,
    buf_options = { buftype = "nofile", bufhidden = "wipe", swapfile = false },
    win_options = { winhighlight = "Normal:PosteDbDatasetHeader" },
  })
end

M._test = {
  float_buf = function() return float_buf end,
}

return M
