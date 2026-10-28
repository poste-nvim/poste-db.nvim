--- SQL completion debugger.
--- Bottom-split window showing live completion pipeline data:
--- Rust raw JSON, context detection, tables, items, blink.cmp result.

local _win = nil
local _buf = nil
local _enabled = false
local _debounce = nil
local _snap = nil

local function alloc_buf()
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  return b
end

local function open_win(b)
  local prev = vim.api.nvim_get_current_win()
  vim.cmd("vert split")
  local ok = pcall(vim.api.nvim_win_set_buf, 0, b)
  if not ok then
    vim.cmd("q")
    vim.api.nvim_set_current_win(prev)
    return nil
  end
  vim.api.nvim_set_option_value("wrap", true, { win = 0 })
  vim.api.nvim_set_option_value("cursorline", false, { win = 0 })
  vim.wo[0].winfixheight = true
  vim.bo[b].filetype = "poste_db_cmp_debug"
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(prev)
  return w
end

local function close()
  if _win and vim.api.nvim_win_is_valid(_win) then
    vim.api.nvim_win_close(_win, true)
  end
  _win = nil
  _buf = nil
end

local function render()
  if not _enabled then return end
  if not _win or not vim.api.nvim_win_is_valid(_win) then
    if not _buf or not vim.api.nvim_buf_is_valid(_buf) then _buf = alloc_buf() end
    _win = open_win(_buf)
    if not _win then return end
  end

  local lines = {}
  if _snap then
    table.insert(lines, "line_before: " .. (_snap.line_before or "''"))
    table.insert(lines, "prefix: '" .. (_snap.prefix or "") .. "'")
    table.insert(lines, "ctx_type: " .. tostring(_snap.ctx_type))
    if _snap.ctx_data then
      table.insert(lines, "ctx_data: " .. tostring(_snap.ctx_data))
    end

    if _snap.rust_raw then
      table.insert(lines, "")
      table.insert(lines, "--- Rust raw ---")
      local truncated = _snap.rust_raw:len() > 400
        and _snap.rust_raw:sub(1, 400) .. "…" or _snap.rust_raw
      for _, l in ipairs(vim.split(truncated, "\n")) do
        table.insert(lines, "  " .. l)
      end
    end

    if _snap.tables and #_snap.tables > 0 then
      table.insert(lines, "")
      table.insert(lines, "--- Tables ---")
      for _, t in ipairs(_snap.tables) do
        local lbl = t.name or ""
        if t.alias then lbl = lbl .. " AS " .. t.alias end
        if t.schema then lbl = t.schema .. "." .. lbl end
        table.insert(lines, "  " .. lbl)
      end
    end

    local items = _snap.items or {}
    table.insert(lines, "")
    table.insert(lines, "--- Items (" .. #items .. ") ---")
    for i, item in ipairs(items) do
      if i > 30 then
        table.insert(lines, "  … +" .. (#items - 30) .. " more")
        break
      end
      local doc = (item.documentation or "")
      if #doc > 55 then
        -- char-safe cut: column comments (the usual documentation source) are
        -- often CJK and a byte-based sub rendered invalid UTF-8
        doc = require("poste-db.util").utf8_safe_cut(doc, 55) .. "…"
      end
      table.insert(lines, string.format("  %d. %s [%s]", i, item.label, doc))
    end

    if _snap.blink_items then
      table.insert(lines, "")
      table.insert(lines, "--- Blink received: " .. _snap.blink_items .. " items, incomplete=" .. tostring(_snap.blink_incomplete))
    end

    if _snap.cmp_items then
      table.insert(lines, "")
      table.insert(lines, "--- nvim-cmp received: " .. _snap.cmp_items .. " items")
    end
  else
    table.insert(lines, "Waiting for completion trigger...")
    table.insert(lines, "")
    table.insert(lines, "Type in a .sql buffer with this window open.")
    table.insert(lines, "Each keystroke updates the debug data.")
  end

  vim.bo[_buf].modifiable = true
  vim.api.nvim_buf_set_lines(_buf, 0, -1, false, lines)
  vim.bo[_buf].modifiable = false
end

local M = {}

function M.toggle()
  _enabled = not _enabled
  if _enabled then
    vim.notify("SQL completion debug ON", vim.log.levels.INFO)
    render()
  else
    vim.notify("SQL completion debug OFF", vim.log.levels.INFO)
    close()
    _snap = nil
    if _debounce then
      vim.fn.timer_stop(_debounce)
      _debounce = nil
    end
  end
end

function M.begin()
  if not _enabled then return end
  _snap = {}
end

function M.set(key, value)
  if not _enabled or not _snap then return end
  _snap[key] = value
end

function M.set_rust_raw(raw)
  if not _enabled or not _snap then return end
  _snap.rust_raw = raw
end

function M.flush()
  if not _enabled then return end
  if _debounce then vim.fn.timer_stop(_debounce) end
  _debounce = vim.fn.timer_start(50, function()
    _debounce = nil
    vim.schedule(render)
  end)
end

return M
