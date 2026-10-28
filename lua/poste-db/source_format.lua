--- SQL source code formatter for poste_sql buffers.
---
--- Supports multiple formatter backends:
---   - sqlfluff       (Python, pip install sqlfluff)
---   - pg_format      (Perl, apt install pgformatter)
---   - sqlfmt         (Go, go install github.com/sqlfmt/sqlfmt@latest)
---   - sql-formatter  (Node.js, npm install -g sql-formatter)
---
--- Auto-detects available formatters and provides:
---   - M.format()        — format buffer or selection
---   - M.format_text()   — format a SQL string
---
--- Optional opt-in integrations (nothing in setup() wires them; call from
--- your config if wanted): M.setup_lazyvim() hooks LazyVim's <leader>cf,
--- M.setup_conform() registers the poste_sql filetypes with conform.nvim,
--- M.auto_format_on_save() formats on BufWritePre.

local config = require("poste-db.config")

local const = require("poste-db.constants")

local M = {}

--- Map of formatter name → detection command and format args
local FORMATTERS = {
  sqlfluff = {
    name = "sqlfluff",
    bin = "sqlfluff",
    args = { "format", "--dialect", "__DIALECT__", "-" },
    pipe_stdin = true,
    supports_dialect = true,
    default_dialect = "ansi",
    dialect_map = {
      mysql = "mysql",
      mariadb = "mysql",
      postgres = "postgres",
      postgresql = "postgres",
      sqlite = "sqlite",
      mssql = "tsql",
      bigquery = "bigquery",
      snowflake = "snowflake",
      redshift = "redshift",
      presto = "presto",
      trino = "trino",
      clickhouse = "clickhouse",
    },
  },
  pg_format = {
    name = "pg_format",
    bin = "pg_format",
    args = { "-" },
    pipe_stdin = true,
    supports_dialect = false,
  },
  sqlfmt = {
    name = "sqlfmt",
    bin = "sqlfmt",
    args = {},
    pipe_stdin = true,
    supports_dialect = false,
  },
  ["sql-formatter"] = {
    name = "sql-formatter",
    bin = "sql-formatter",
    args = { "--language", "__DIALECT__" },
    pipe_stdin = true,
    supports_dialect = true,
    default_dialect = "postgresql",
    dialect_map = {
      mysql = "mysql",
      postgres = "postgresql",
      sqlite = "sqlite",
      mssql = "tsql",
      bigquery = "bigquery",
      db2 = "db2",
      hive = "hive",
      mariadb = "mariadb",
      plsql = "plsql",
      redshift = "redshift",
      snowflake = "snowflake",
      tsql = "tsql",
      trino = "trino",
    },
  },
}

--- Cached detection results: formatter_name → true/false
local _detected = {}

--- Detect whether a formatter is available on the system.
--- Results are cached after first detection.
--- @param name string Formatter key from FORMATTERS
--- @return boolean
function M.detect(name)
  if _detected[name] ~= nil then
    return _detected[name]
  end

  local fmt = FORMATTERS[name]
  if not fmt then
    _detected[name] = false
    return false
  end

  local ok = (vim.fn.executable(fmt.bin) == 1)
  _detected[name] = ok
  return ok
end

--- Force re-detection of all formatters (clear cache).
function M.rediscover()
  _detected = {}
end

--- Get the user-configured formatter priority order (from config).
--- Falls back to the built-in default if not configured.
--- @return string[] List of formatter names in priority order
function M._get_priority()
  local config_formatters = config.config.sql_formatters
  if config_formatters and type(config_formatters) == "table" and #config_formatters > 0 then
    -- Validate that each entry is a known formatter
    local valid = {}
    for _, name in ipairs(config_formatters) do
      if FORMATTERS[name] then
        table.insert(valid, name)
      end
    end
    if #valid > 0 then return valid end
  end
  return { "sqlfluff", "sqlfmt", "sql-formatter", "pg_format" }
end

--- Find the best available formatter for the given dialect.
--- Uses the user-configured priority order from config.sql_formatters.
--- Falls back to the next available formatter if the best one is not installed.
--- @param dialect string|nil SQL dialect (mysql, postgres, sqlite, etc.)
--- @return string|nil Formatter name, or nil if none found
function M.best(dialect)
  dialect = dialect or ""

  local candidates = M._get_priority()

  for _, name in ipairs(candidates) do
    if M.detect(name) then
      local fmt = FORMATTERS[name]
      if fmt.supports_dialect and dialect ~= "" then
        local dm = fmt.dialect_map or {}
        if dm[dialect] then
          return name
        end
        -- Formatter supports dialect but this dialect isn't mapped —
        -- still use it (pass dialect as-is)
        return name
      end
      return name
    end
  end

  return nil
end

--- Build the formatter CLI args, replacing the `__DIALECT__` sentinel with the
--- resolved (or default) dialect.
--- @param fmt table FORMATTERS entry
--- @param dialect string resolved dialect ("" when unknown)
--- @return string[]
local function build_formatter_args(fmt, dialect)
  local has_dialect = dialect ~= ""
  local args = {}
  for _, arg in ipairs(fmt.args) do
    if arg == "__DIALECT__" then
      local dm = fmt.dialect_map or {}
      local d = has_dialect and dialect or (fmt.default_dialect or "ansi")
      table.insert(args, dm[d] or d)
    else
      table.insert(args, arg)
    end
  end
  return args
end

--- List all detected (available) formatters.
--- @return string[]
function M.list_available()
  local available = {}
  for name, _ in pairs(FORMATTERS) do
    if M.detect(name) then
      table.insert(available, name)
    end
  end
  return available
end

--- Resolve the dialect for the current buffer.
--- Delegates to dialect.lua — this was a drifting fork of diagnostics.lua's
--- get_dialect that dropped the g:poste_db_dialect fallback, so formatters
--- ignored the user's global dialect while diagnostics honored it.
--- @param bufnr number|nil Buffer handle (0 = current)
--- @return string Dialect name (lowercase)
function M.resolve_dialect(bufnr)
  bufnr = bufnr or 0
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local ok, dialect = pcall(require, "poste-db.dialect")
  if not ok then return "" end
  return dialect.dialect_for_buf(bufnr) or ""
end

--- Format a SQL string using the specified formatter.
--- Tries the preferred formatter first; if it fails, falls back to the next
--- available formatter in the priority list. This handles cases like sqlfluff
--- failing on MySQL admin commands (SHOW TABLES, DESCRIBE, etc.).
--- @param text string SQL text to format
--- @param opts table|nil Options:
---   - formatter: string|nil  Force a specific formatter name (skip fallback)
---   - dialect:   string|nil  SQL dialect
--- @return string|nil Formatted text, or nil on error
--- @return string|nil Error message (from the last attempted formatter)
function M.format_text(text, opts)
  opts = opts or {}
  local dialect = opts.dialect or ""

  -- Determine which formatters to try
  local candidates
  if opts.formatter then
    -- User forced a specific formatter; try only that one
    if FORMATTERS[opts.formatter] then
      candidates = { opts.formatter }
    else
      return nil, string.format("Unknown formatter: %s", opts.formatter)
    end
  else
    -- Use priority-ordered candidates (only installed ones)
    local priority = M._get_priority()
    candidates = {}
    for _, name in ipairs(priority) do
      if M.detect(name) then
        table.insert(candidates, name)
      end
    end
    if #candidates == 0 then
      return nil, "No SQL formatter found. Install one: sqlfluff, sqlfmt, sql-formatter, or pg_format"
    end
  end

  -- Try each formatter in order until one succeeds.
  -- Uses nested conditionals instead of goto (Lua 5.1/LuaJIT compatibility).
  -- The wait is synchronous on the main loop: the first candidate gets the
  -- full budget, every FALLBACK gets a short one — an installed-but-broken
  -- formatter chain used to stack up to 10s per candidate before the user
  -- saw anything.
  local last_err
  for i, formatter in ipairs(candidates) do
    local fmt = FORMATTERS[formatter]
    if not fmt then
      last_err = string.format("Unknown formatter: %s", formatter)
    else
      local args = build_formatter_args(fmt, dialect)

      -- Run the formatter
      local cmd = fmt.bin

      local ok_sys, sys_obj = pcall(vim.system, { cmd, unpack(args) }, {
        stdin = text,
        timeout = i == 1 and 10000 or 3000,
      })
      if not ok_sys then
        last_err = string.format("Failed to start %s", cmd)
      else
        local result_obj = sys_obj:wait()
        if result_obj.code ~= 0 then
          local err = result_obj.stderr
          if err == "" then err = string.format("Exit code %d", result_obj.code) end
          last_err = string.format("%s: %s", formatter, err)
        else
          local result = result_obj.stdout
          if result ~= "" and not result:match("\n$") then
            result = result .. "\n"
          end
          return result, nil, formatter
        end
      end
    end
  end

  -- All formatters failed
  return nil, last_err or "All formatters failed"
end

--- Format the current buffer (or visual selection).
--- Strategy:
---   1. conform.nvim (if installed + formatters_by_ft configured)
---   2. Poste's built-in format_text() (auto-detects formatter)
--- @param opts table|nil
---   - formatter: string|nil  Force a specific formatter
---   - bufnr:     number|nil  Buffer handle (default: current)
function M.format(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  if ft ~= "poste_sql" and ft ~= "poste_sqlite" then
    vim.notify("PosteDbFormat: not a SQL buffer", vim.log.levels.WARN)
    return
  end

  -- Strategy 1: conform.nvim (if installed and has formatters for this ft)
  local ok_conform, conform = pcall(require, "conform")
  if ok_conform and conform.formatters and conform.formatters_by_ft then
    local ft_formatters = conform.formatters_by_ft[ft]
    if ft_formatters then
      local resolved = type(ft_formatters) == "function" and ft_formatters(bufnr) or ft_formatters
      if type(resolved) == "table" and #resolved > 0 then
        conform.format({ bufnr = bufnr, lsp_format = "never", timeout_ms = 10000 })
        return
      end
    end
  end

  -- Strategy 2: Poste's built-in formatter (auto-detect + fallback)
  -- Determine the range: visual selection or whole buffer
  local start_line, end_line
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\x16" then
    start_line = vim.fn.line("v")
    end_line = vim.fn.line(".")
    if start_line > end_line then start_line, end_line = end_line, start_line end
    -- Exit visual mode
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
      "n", false
    )
  else
    start_line = 1
    end_line = vim.api.nvim_buf_line_count(bufnr)
  end

  -- Get buffer lines
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local text = table.concat(lines, "\n")

  -- Resolve dialect
  local dialect = opts.dialect or M.resolve_dialect(bufnr)

  -- Format (with automatic fallback across available formatters)
  local result, err, used_formatter = M.format_text(text, {
    formatter = opts.formatter,
    dialect = dialect,
  })

  if not result then
    vim.notify(string.format("Format failed: %s", err or "unknown error"), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local result_lines = vim.split(result, "\n", { plain = true })

  -- Trim trailing blank lines from result
  while #result_lines > 0 and result_lines[#result_lines] == "" do
    table.remove(result_lines)
  end

  -- Replace the buffer content
  vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, result_lines)

  -- Restore cursor near original position, ensuring it's within bounds
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local new_row = math.min(cursor[1], total_lines)
  local line_content = vim.api.nvim_buf_get_lines(bufnr, new_row - 1, new_row, false)[1] or ""
  local new_col = math.min(cursor[2], #line_content)
  vim.api.nvim_win_set_cursor(0, { new_row, new_col })

  -- Notify which formatter was used
  local name = used_formatter or opts.formatter or M.best(dialect) or "unknown"
  vim.notify(string.format("Formatted with %s%s", name,
    dialect ~= "" and string.format(" (%s dialect)", dialect) or ""), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
end

--- Format the entire buffer in-place (for :PosteDbFormat command).
function M.format_buffer()
  M.format()
end

--- Show formatting status: available formatters, configured priority, dialect.
--- @param bufnr number|nil Buffer handle
function M.status(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype

  local lines = { "PosteDb Format Status:", "" }

  -- Detected formatters
  table.insert(lines, "Installed formatters:")
  local any = false
  for name, _ in pairs(FORMATTERS) do
    if M.detect(name) then
      table.insert(lines, string.format("  ✓ %s", name))
      any = true
    end
  end
  if not any then
    table.insert(lines, "  (none)")
  end
  table.insert(lines, "")

  -- Configured priority
  local priority = M._get_priority()
  table.insert(lines, "Priority order (from config.sql_formatters):")
  for i, name in ipairs(priority) do
    local installed = M.detect(name) and "✓" or "✗"
    table.insert(lines, string.format("  %d. %s [%s]", i, name, installed))
  end
  table.insert(lines, "")

  -- Dialect for current buffer
  local dialect = M.resolve_dialect(bufnr)
  table.insert(lines, string.format("Current dialect: %s", dialect ~= "" and dialect or "(not set)"))
  table.insert(lines, string.format("Filetype: %s", ft))

  -- Best formatter for this dialect
  local best = M.best(dialect)
  table.insert(lines, string.format("Best formatter: %s", best or "(none available)"))

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
end

---------------------------------------------------------------------------
-- LazyVim format system integration
---------------------------------------------------------------------------

--- Register PosteDb as a LazyFormatter with LazyVim's format system.
--- This is the primary way <leader>cf works if you use LazyVim:
---   LazyVim.format({force=true}) → finds our formatter → calls M.format()
--- @param lazyvim_format LazyVim format module (require("lazyvim.util").format)
local function _register_lazyvim_formatter(lazyvim_format)
  lazyvim_format.register({
    name = "PosteDb",
    primary = true,
    priority = 150, -- higher than conform.nvim (100) so it runs first
    format = function(buf)
      M.format({ bufnr = buf })
    end,
    sources = function(buf)
      if not buf or buf == 0 then buf = vim.api.nvim_get_current_buf() end
      local ft = vim.bo[buf].filetype
      if ft ~= "poste_sql" and ft ~= "poste_sqlite" then
        return {}
      end
      local dialect = M.resolve_dialect(buf)
      local best = M.best(dialect)
      if best then
        return { "PosteDb:" .. best }
      end
      local available = M.list_available()
      if #available > 0 then
        return vim.tbl_map(function(n) return "PosteDb:" .. n end, available)
      end
      return {}
    end,
  })
end

--- Register with LazyVim's format system.
--- Safe to call without LazyVim — uses pcall internally.
--- When LazyVim is installed, registers PosteDb as a LazyFormatter so
--- <leader>cf (LazyVim.format) triggers PosteDb formatting.
function M.setup_lazyvim()
  local ok_lazy, lazyvim_format = pcall(function()
    return require("lazyvim.util").format
  end)
  if ok_lazy and lazyvim_format then
    _register_lazyvim_formatter(lazyvim_format)
  end
  -- LazyVim not installed: silently skip.
  -- Poste still has :PosteDbFormat and the <leader>ff keymap.
end

---------------------------------------------------------------------------
-- conform.nvim integration
---------------------------------------------------------------------------

--- Internal: actually set conform.formatters_by_ft for poste_sql/poste_sqlite.
--- @param conform table conform module
local function _setup_conform_impl(conform)
  -- conform reads the per-filetype mapping from `formatters_by_ft`; writing to
  -- `formatters.by_ft` (as this used to) landed in a slot nothing ever read.
  conform.formatters_by_ft = conform.formatters_by_ft or {}
  for _, ft in ipairs({ "poste_sql", "poste_sqlite" }) do
    if not conform.formatters_by_ft[ft] then
      conform.formatters_by_ft[ft] = function(bufnr)
        local dialect = M.resolve_dialect(bufnr)
        local best = M.best(dialect)
        if best then
          return { best }
        end
        -- No best found; return all detected formatters (conform will try each)
        local detected = {}
        for _, name in ipairs(M._get_priority()) do
          if M.detect(name) then
            table.insert(detected, name)
          end
        end
        return detected
      end
    end
  end
end

--- Register poste_sql and poste_sqlite filetypes for conform.nvim.
--- Safe to call without conform.nvim — uses pcall internally.
--- Supports both:
---   :ConformFormat (standalone conform users)
---   conform as a LazyFormatter inside LazyVim
function M.setup_conform()
  local ok_conform, conform = pcall(require, "conform")
  if ok_conform then
    _setup_conform_impl(conform)
  end
  -- conform not installed: silently skip.
  -- LazyVim users: PosteDb LazyFormatter handles <leader>cf directly.
  -- Other users: use :PosteDbFormat or the <leader>ff keymap.
end

--- Format on save with conform.nvim (if user opts in).
--- @param bufnr number Buffer handle
function M.auto_format_on_save(bufnr)
  local ok_conform, conform = pcall(require, "conform")
  if not ok_conform then return end

  conform.format({
    bufnr = bufnr,
    timeout_ms = 10000,
    async = false,
  })
end

M._test = {
  _get_priority = M._get_priority,
  best = M.best,
  build_formatter_args = build_formatter_args,
  resolve_dialect = M.resolve_dialect,
  format_text = M.format_text,
  formatters = FORMATTERS,
  -- Override the detection cache so availability is deterministic in tests.
  set_detected = function(map) _detected = map or {} end,
  rediscover = M.rediscover,
}

return M
