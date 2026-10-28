--- SQL execution context management.
--- Handles connection → database context resolution and status display.
local state = require("poste-db.state")

local const = require("poste-db.constants")
local lex = require("poste-db.lex")

local M = {}

---------------------------------------------------------------------------
-- Shared detect-command builder
---------------------------------------------------------------------------

--- The argv for `poste context detect <offset> [--dialect D]` — the one
--- place the flag contract lives. `generic` is the binary's default
--- (schema.md), so it is not spelled out; a nil/empty dialect means the
--- caller has no connection config to read it from. Consumers today:
--- completion/init (async, cached), nav/handlers and introspect/init
--- (synchronous go-to-definition paths).
--- @param binary string path to the poste binary
--- @param offset number 0-based byte offset into the detect payload
--- @param dialect string|nil connection dialect ("generic", "postgres", …)
--- @return string[]
function M.detect_command(binary, offset, dialect)
  local cmd = { binary, "context", "detect", tostring(offset) }
  if dialect and dialect ~= "" and dialect ~= "generic" then
    cmd[#cmd + 1] = "--dialect"
    cmd[#cmd + 1] = dialect
  end
  return cmd
end

---------------------------------------------------------------------------
-- Context resolution
---------------------------------------------------------------------------

--- Resolve the SQL execution context from the current buffer.
--- Scans file header for @connection/@database directives, then scans
--- the cursor's ### block for USE statements and block-level overrides.
--- The last USE statement before the cursor wins (JetBrains behavior).
--- Directives (`-- @…`) and USE lines inside a `/* … */` region are ignored:
--- the region may have opened lines above, so both phases carry the
--- block-comment depth down line by line (`lex.block_comment_depth_after`).
--- A directive that declares no name (whitespace-only value) is ignored too, so
--- it cannot clear the level above it — `constants.directive_value`.
--- @param buf number Buffer handle (default: current buffer)
--- @return table context { connection = string|nil, database = string|nil }
--- Resolve the buffer-position part of the context: file-level directives
--- (before the first ###) then the cursor's ### block (directives + USE).
--- Pure in the buffer content: the runtime fallbacks live in
--- resolve_full_context, not here.
---
--- Full-buffer scan (get_lines + two linear walks), and per-update callers
--- like semantic_diagnostics resolve it once per statement — so the result
--- is cached per buffer|changedtick|line. Cache hits return a fresh copy:
--- callers may mutate the returned table. Bulk-evicted past a bound; a dead
--- buffer's keys simply never hit again.
--- @param buf number Buffer handle (default: current buffer)
--- @param limit_line number|nil Line to resolve at (default: cursor)
--- @return table context { connection = string|nil, database = string|nil }
local _resolve_cache = {}
local _resolve_cache_n = 0
local _RESOLVE_CACHE_MAX = 64

function M.resolve_context(buf, limit_line)
  buf = buf or vim.api.nvim_get_current_buf()
  local cursor_line = limit_line or vim.fn.line(".")

  local ok_tick, tick = pcall(vim.api.nvim_buf_get_changedtick, buf)
  local cache_key = ok_tick and (buf .. "|" .. tick .. "|" .. cursor_line) or nil
  if cache_key then
    local hit = _resolve_cache[cache_key]
    if hit then
      return { connection = hit.connection, database = hit.database }
    end
  end

  -- Phase 1: Scan file header (before first ###) for global defaults
  local connection = nil
  local database = nil
  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local header_depth = 0
  for i, line in ipairs(all_lines) do
    if const.is_section_marker(line) then break end
    if header_depth == 0 then
      local conn_match = const.directive_value(line, const.DIRECTIVE_CONNECTION)
      if conn_match then connection = conn_match end
      local db_match = const.directive_value(line, const.DIRECTIVE_DATABASE)
      if db_match then database = db_match end
    end
    header_depth = lex.block_comment_depth_after(line, header_depth)
  end

  -- Phase 2: Scan cursor's ### block for USE statements and block-level overrides
  local block_start = lex.find_block_for_line(all_lines, cursor_line)
  local block_lines = vim.api.nvim_buf_get_lines(buf, block_start - 1, cursor_line, false)

  local block_depth = 0
  for i, line in ipairs(block_lines) do
    if block_depth == 0 then
      local conn_match = const.directive_value(line, const.DIRECTIVE_CONNECTION)
      if conn_match then connection = conn_match end
      local db_match = const.directive_value(line, const.DIRECTIVE_DATABASE)
      if db_match then database = db_match end

      local use_db = lex.find_use_database(line)
      if use_db then database = use_db end
    end
    block_depth = lex.block_comment_depth_after(line, block_depth)
  end

  local result = { connection = connection, database = database }
  if cache_key then
    _resolve_cache[cache_key] = result
    _resolve_cache_n = _resolve_cache_n + 1
    if _resolve_cache_n > _RESOLVE_CACHE_MAX then
      _resolve_cache = {}
      _resolve_cache_n = 0
    end
  end
  return { connection = result.connection, database = result.database }
end

--- Resolve the full context chain: buffer scan → connections.toml default.
--- Priority: block-level > USE > file-level > runtime connection > connections.toml default
--- Does NOT fall back to state.context.database — context is position-determined.
--- @param buf number Buffer handle (default: current buffer)
--- @return table context { connection = string|nil, database = string|nil }
function M.resolve_full_context(buf, limit_line)
  buf = buf or vim.api.nvim_get_current_buf()

  local ctx = M.resolve_context(buf, limit_line)

  -- Fallback to runtime state for connection (set by :PosteDbConnection or execution)
  local state_sql = state
  local conn = ctx.connection or (state_sql and state_sql.context and state_sql.context.connection)

  -- Database: buffer scan → connections.toml default
  local db = ctx.database
  if not db and conn then
    local connections = require("poste-db.connections")
    local config = connections.get_connection_config(conn)
    if config and config.database and config.database ~= "" then
      db = config.database
    end
  end

  return { connection = conn, database = db, raw = ctx }
end

--- Update context from a SQL response (e.g., USE statement).
--- @param response table Parsed response object
function M.handle_use_statement(response)
  if not response or not response.body then return end

  local ok, body = pcall(vim.json.decode, response.body)
  if not ok or type(body) ~= "table" then return end

  if body.type == "use" and body.database_name then
    state.context.database = body.database_name
    state.log("INFO", "SQL context database updated: " .. body.database_name)
  end
end

--- Get status text for the statusline.
--- @return string Status text like "[db: conn/database]"
function M.get_status_text()
  local ctx = state.context
  local conn = ctx.connection
  local db = ctx.database

  if not conn and not db then
    return ""
  end

  if conn and db then
    return string.format("[db: %s/%s]", conn, db)
  elseif conn then
    return string.format("[db: %s]", conn)
  else
    return string.format("[db: ?/%s]", db)
  end
end

--- Get status text for cursor position in a SQL buffer.
--- Resolves context at cursor line: @connection → @database/USE → connections.toml default.
--- @param buf number|nil Buffer handle (default: current buffer)
--- @return string Status text like "[my-blog/inventory]" or ""
function M.get_cursor_status_text(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ctx = M.resolve_full_context(buf)
  if not ctx.connection then return "" end
  if ctx.database then
    return string.format("%s/%s", ctx.connection, ctx.database)
  end
  return ctx.connection
end

return M
