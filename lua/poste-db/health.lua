local M = {}

local compat = require("poste-db.compat")

local start = vim.health.start or vim.health.report_start
local ok = vim.health.ok or vim.health.report_ok
local warn = vim.health.warn or vim.health.report_warn
local error = vim.health.error or vim.health.report_error

function M.check()
  start("poste-db.nvim")

  -- Neovim version (requires 0.10+ for vim.system, vim.treesitter.language)
  if vim.fn.has("nvim-0.10.0") == 1 then
    ok("Neovim >= 0.10.0")
  else
    error("Neovim >= 0.10.0 required (uses vim.system, vim.treesitter.language)")
  end

  -- Poste binary (vendored state, family dissolution: the binary is
  -- REQUIRED here — exec-file/session are the SQL transport)
  local state = require("poste-db.state")
  local binary, source = state.find_poste_binary()
  if binary then
    -- The source is the actionable half: five candidates can win, and the
    -- installed release outranks a $PATH build the user expects to be used.
    ok("poste binary: " .. binary .. " (from " .. source .. ")")
    local version = state.poste_version(binary)
    if version then ok("poste version: " .. version) end
  else
    -- A startup download may already be running (init.setup deferred it):
    -- "run :PosteDbInstall" for a fetch that is mid-flight chains onto the
    -- same download, so say that instead of erroring.
    if require("poste-db.install").in_progress() then
      warn("poste binary not found YET — a release download is already running; re-run :checkhealth in a moment")
    else
      error("poste binary not found — run :PosteDbInstall to download it, or set vim.g.poste_binary / $POSTE_BINARY")
    end
  end

  -- curl
  if vim.fn.executable("curl") == 1 then
    ok("curl available")
  else
    warn("curl not found — binary auto-download will fail")
  end

  -- SQL tree-sitter parser
  local parser_dir = vim.fn.stdpath("data") .. "/site/parser"
  local ts_ok, _ = pcall(vim.treesitter.get_parser, 0, "sql")
  local ts_file = (vim.fn.filereadable(parser_dir .. "/sql.so") == 1) and "installed" or "missing"
  if ts_ok then
    ok("tree-sitter SQL parser: active (" .. ts_file .. ")")
  else
    warn("tree-sitter SQL parser: unavailable (" .. ts_file .. ") — run :TSInstall sql")
  end

  -- blink.cmp
  local blink_ok = pcall(require, "blink.cmp")
  if blink_ok then
    local providers = {}
    local config_ok, config = pcall(require, "blink.cmp.config")
    if config_ok and config.sources and config.sources.providers then
      for id, _ in pairs(config.sources.providers) do
        table.insert(providers, id)
      end
    end
    local has_poste_db = vim.tbl_contains(providers, "poste_db")
    ok("blink.cmp loaded")
    if has_poste_db then
      ok("  poste_db provider registered")
    else
      warn("  poste_db provider not registered — completion may not work")
    end
  else
    local cmp_ok = pcall(require, "cmp")
    if cmp_ok then
      ok("nvim-cmp loaded")
    else
      warn("no completion engine (blink.cmp or nvim-cmp) — install blink.cmp for completion")
    end
  end

  -- Platform
  local uname = (vim.uv or vim.loop).os_uname()
  local sys = uname.sysname
  local machine = uname.machine
  local supported = false
  if (sys == "Linux" or sys == "Darwin") and (machine == "x86_64" or machine == "aarch64" or machine == "arm64") then
    supported = true
  end
  if sys:find("Windows") and (machine == "x86_64" or machine == "AMD64") then
    supported = true
  end
  if supported then
    ok("platform: " .. sys .. " " .. machine)
  else
    warn("platform: " .. sys .. " " .. machine .. " — may not have prebuilt binaries")
  end

  -- connections.toml discovery
  local buf_name = vim.api.nvim_buf_get_name(0)
  local search_dir = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":h") or vim.fn.getcwd()
  local util = require("poste-db.util")
  local config_path = util.find_file_upwards("connections.toml", search_dir)
  if config_path then
    ok("connections.toml: " .. config_path)
  else
    warn("connections.toml not found (searched from " .. search_dir .. ")")
  end

  -- Legacy completion mode
  local legacy = compat.opt("legacy_completion")
  if legacy then
    ok("legacy completion mode: " .. tostring(legacy))
  end
end

return M