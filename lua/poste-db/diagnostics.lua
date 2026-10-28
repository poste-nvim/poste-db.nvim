--- Tree-sitter-based SQL syntax diagnostics.
--- Maps Tree-sitter ERROR nodes to vim.diagnostic entries.
--- On TextChanged/TextChangedI (debounced) and BufWritePost.
--- Also runs semantic diagnostics (table/column existence checks).

local ts_stmt = require("poste-db.ts_stmt")
-- dialect.lua captures the context/connections stubs these specs install, so
-- it must load while they are in package.loaded (see sql_diagnostics_spec).
local dialect = require("poste-db.dialect")
local dml_guard = require("poste-db.dml_guard")

local M = {}

-- One pending timer PER buffer: a single shared `_timer` let buffer B's
-- keystroke cancel buffer A's scheduled diagnostic run (its debounce fired
-- only on the next A event, self-healing but lossy). Dead buffers' timers
-- drop out on the validity check.
local _timers = {}
local DEBOUNCE_MS = 300
local ns = vim.api.nvim_create_namespace("poste_db_diagnostics")
local ns_hl = vim.api.nvim_create_namespace("poste_db_diagnostics_highlight")

--- Resolve the connection dialect for a buffer (lowercase), or nil.
--- The single implementation lives in dialect.lua — this was one of three
--- drifting copies.
--- @param buf number  buffer handle
--- @return string|nil
local function get_dialect(buf)
  return dialect.dialect_for_buf(buf)
end

--- Convert Tree-sitter ERROR nodes to vim.diagnostic entries (0-based).
--- @param errors table[]  error nodes from ts_stmt.find_error_nodes
--- @return table[]  vim.diagnostic-compatible entries
local function to_diag_entries(errors)
  local diags = {}
  for _, err in ipairs(errors) do
    diags[#diags + 1] = {
      lnum = err.lnum - 1,
      col = err.col - 1,
      end_lnum = err.end_lnum - 1,
      end_col = err.end_col - 1,
      severity = vim.diagnostic.severity.ERROR,
      source = "poste-db",
      message = err.text,
    }
  end
  return diags
end

--- Update diagnostics for a buffer using Tree-sitter ERROR nodes.
--- @param buf number  buffer handle
function M.update_diagnostics(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local ft = vim.bo[buf].filetype
  if ft ~= "poste_sql" and ft ~= "poste_sqlite" and ft ~= "sql" then return end

  local errors = ts_stmt.find_error_nodes(buf, get_dialect(buf))
  local diags = to_diag_entries(errors)
  vim.diagnostic.set(ns, buf, diags, { priority = 200 })
  vim.api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)
  for _, d in ipairs(diags) do
    vim.api.nvim_buf_set_extmark(buf, ns_hl, d.lnum, d.col, {
      end_row = d.end_lnum,
      end_col = d.end_col,
      hl_group = "Error",
      hl_mode = "combine",
      priority = 200,
    })
  end

  -- Semantic diagnostics (table/column existence checks)
  local ok_sem, sem = pcall(require, "poste-db.semantic_diagnostics")
  if ok_sem then
    sem.update(buf)
  end

  -- Missing-WHERE lint: purple HINT diagnostics for unfiltered DELETE/UPDATE
  dml_guard.update(buf)
end

--- Debounced update.
--- @param buf number
function M.debounced_update(buf)
  local pending = _timers[buf]
  if pending then
    pending:stop()
    pending:close()
  end
  _timers[buf] = vim.defer_fn(function()
    _timers[buf] = nil
    if not vim.api.nvim_buf_is_valid(buf) then return end
    M.update_diagnostics(buf)
  end, DEBOUNCE_MS)
end

--- Clear diagnostics for a buffer.
--- @param buf number
function M.clear_diagnostics(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.diagnostic.reset(ns, buf)
    vim.api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)
  end
  local ok_sem, sem = pcall(require, "poste-db.semantic_diagnostics")
  if ok_sem then
    sem.clear(buf)
  end
  dml_guard.clear(buf)
end

function M.setup(buf)
  buf = buf or 0
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end

  local group = vim.api.nvim_create_augroup("PosteDbDiagnostics_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.debounced_update(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = buf,
    callback = function()
      M.debounced_update(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    buffer = buf,
    callback = function()
      M.clear_diagnostics(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = buf,
    callback = function()
      M.debounced_update(buf)
    end,
  })

  M.update_diagnostics(buf)
end

M._test = {
  to_diag_entries = to_diag_entries,
  get_dialect = get_dialect,
}

return M
