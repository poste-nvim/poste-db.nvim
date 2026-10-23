--- SQL code-block execution for the "db" AI context — takes a ```sql block
--- from an AI reply, resolves the target connection, runs it through the
--- regular executor and renders results into the dataset view.
--- Safety: only clearly read-only statements run without confirmation.

local M = {}

local constants = require("poste-db.constants")
local dml_guard = require("poste-db.dml_guard")
local util = require("poste-db.util")

--- Read-only statement keywords (Lua patterns have no alternation, hence the
--- lookup table).
local READONLY_KINDS = {
  select = true, with = true, show = true, explain = true, describe = true,
  desc = true, analyze = true, pragma = true, table = true,
}

--- Write keywords that make a WITH (CTE) statement data-changing.
--- Postgres and SQLite allow WITH ... INSERT/UPDATE/DELETE/MERGE, so a bare
--- `with` kind must not skip the confirm gate. A false positive (one of
--- these words inside a string literal or comment) only costs an extra
--- confirmation — the safe direction.
local WRITE_WORDS = { "insert", "update", "delete", "merge", "replace" }

--- What to tell the chat when the response says a statement failed and carries
--- no text saying so. `exec_run` counts a result as failed from its `status`
--- field, which the binary can set without an `error`, so "no message" is a
--- real shape of the failure — and the alternative was reporting `✓ executed`.
local UNEXPLAINED_FAILURE = "the server reported a failed statement without a message"

--- @param stmt string one statement, with literals/comments already blanked
--- @return boolean
local function statement_is_readonly(stmt)
  local lowered = stmt:lower()
  local kind = lowered:match("^%s*(%a+)")
  if not kind then return false end
  if kind == "with" then
    for _, w in ipairs(WRITE_WORDS) do
      -- %f[%w_]…%f[^%w_] = whole-word match; note Lua's %w excludes `_`,
      -- and identifiers like `last_update` must not read as containing
      -- the write word `update`
      if lowered:find("%f[%w_]" .. w .. "%f[^%w_]") then return false end
    end
    return true
  end
  if kind == "explain" then
    -- EXPLAIN ANALYZE runs the statement it explains
    return not lowered:find("%f[%w_]analyze%f[^%w_]")
  end
  return READONLY_KINDS[kind] == true
end

--- Read-only check for the confirm gate. A block is read-only only when
--- EVERY statement in it is: the executor runs a block greedily, so
--- `SELECT 1; DROP TABLE users` must confirm on the strength of the second
--- statement, not pass on the first. Leading comment lines are blanked, so
--- `-- @connection x\nSELECT 1` (the header append_header writes, and which
--- models copy) still reads as a SELECT.
---
--- The block is scanned under BOTH quote-escape readings and must read
--- read-only under each: the readings disagree about where a literal ends
--- (postgres reads `'C:\path\'` as closed at the final quote; the backslash
--- reading escapes it), and the wrong reading parks the `;DROP TABLE` that
--- follows inside a phantom literal. A gate that runs SQL unconfirmed must
--- over-flag, never under — the same rule `dml_guard.regex_scan` scans by.
--- @param sql string
--- @return boolean
function M.is_readonly(sql)
  local count = 0
  for _, backslash in ipairs({ false, true }) do
    local seen = 0
    for stmt in (dml_guard.strip_non_code(sql, backslash) .. ";"):gmatch("([^;]*)") do
      if stmt:match("%S") then
        seen = seen + 1
        if not statement_is_readonly(stmt) then return false end
      end
    end
    count = math.max(count, seen)
  end
  return count > 0
end

--- Confirm gate used by poste-ai's codeblock action. Read-only statements
--- pass; everything else asks (mirrors the family's destructive-op dialogs).
--- @param sql string
--- @return boolean proceed
function M.confirm_sql(sql)
  if M.is_readonly(sql) then return true end
  local kind = (sql:match("^%s*(%S+)") or "statement"):upper()
  local choice = vim.fn.confirm(
    ("AI wants to execute a %s statement — run it?"):format(kind),
    "&Yes\n&No", 2, "Warning")
  return choice == 1
end

--- True when the block already names a connection with a directive *line*.
--- Anchored on purpose: constants.match_directive, file_exec.lua and the Rust
--- CLI all require the line to start with `-- @`, and an unanchored
--- `text:match("%-%-%s*@connection")` here counted a directive living inside a
--- string literal or a prose comment, dropped the header, and let the block
--- run on the buffer's connection instead of the chat scope's.
--- directive_value rather than match_directive: the question is whether the line
--- *names* a connection, and `-- @connection ` (a model-emitted placeholder)
--- names none — such a line must not swallow the scope header.
--- @param text string
--- @return boolean
local function has_connection_directive(text)
  for line in text:gmatch("[^\r\n]+") do
    if constants.directive_value(line, "connection") then return true end
  end
  return false
end

--- Header directive lines for appending an AI-authored block into a SQL
--- buffer (poste-ai's `ga` action) — binds the block to the chat scope set
--- with /connections and /databases. Nil when no connection is bound or the
--- block already carries a @connection directive (the model may emit one).
--- @param scope table|nil chat scope snapshot
--- @param text string block text
--- @return string[]|nil
function M.append_header(scope, text)
  local conn = util.named(scope and scope.connection)
  if not conn then return nil end
  if text and has_connection_directive(text) then return nil end
  local lines = { "-- @connection " .. conn }
  local db = util.named(scope.database)
  if db then
    lines[#lines + 1] = "-- @database " .. db
  end
  return lines
end

--- Strip a leading `-- @connection x` directive the model may have copied in.
local function strip_directives(sql)
  return (sql:gsub("^%s*%-%-%s*@connection%s+%S+%s*\n?", "")
    :gsub("^%s*%-%-%s*@database%s+%S+%s*\n?", ""))
end

--- Resolve the target connection. Priority: mention refs → the poste-ai chat
--- scope (bound with /connections, /databases) → the current SQL context.
--- Every hop reads through util.named: an empty string is not a bound target,
--- and returning one handed `--database ""` to the binary (a URL rewrite that
--- strips the database) and turned "nothing is bound" into the unhelpful
--- `connection "" not found` instead of the hint below.
--- @param refs table|nil
--- @return string|nil conn, string|nil database, string|nil err
function M.resolve_target(refs)
  for _, ref in ipairs(refs or {}) do
    if ref.type == "context" and ref.context == "db" and type(ref.data) == "table" then
      local conn = util.named(ref.data.connection)
      if conn then return conn, util.named(ref.data.database), nil end
    end
  end
  local ok, poste_ai = pcall(require, "poste-ai")
  if ok then
    local scope = poste_ai.scope and poste_ai.scope() or nil
    local conn = util.named(scope and scope.connection)
    if conn then
      return conn, util.named(scope and scope.database), nil
    end
  end
  local state = require("poste-db.state")
  local conn = util.named(state.context and state.context.connection)
  if conn then
    return conn, util.named(state.context and state.context.database), nil
  end
  return nil, nil, "no target connection — scope with /connections, mention one with @connection/database, or set -- @connection in the SQL buffer"
end

--- Render a parsed legacy response into the dataset view.
function M.render_dataset(parsed, sql)
  local format = require("poste-db.format")
  local sql_buffer = require("poste-db.buffer")
  local lines, meta, layout = format.format_dataset(parsed)
  -- Prefer the decoded resultset (matches db_browser's execute_table_select)
  -- so cell preview (K) / yank / sort read fresh rows; a legacy envelope
  -- without a decodable body carries the rows itself.
  local data = util.decode_dataset_body(parsed) or parsed
  sql_buffer.render_dataset(lines, meta, {
    data = data,
    layout = layout,
    original_sql = sql,
    src_file = "poste://ai_chat",
    src_buf = nil,
  })
end

--- Execute an AI-authored SQL block. Called by poste-ai's codeblock action.
--- @param sql string block text
--- @param refs table mention refs of the user turn
--- @param cb function(err, note)
function M.execute_sql(sql, refs, cb)
  local conn, database, err = M.resolve_target(refs)
  if not conn then cb(err or "no connection", nil) return end

  local connections = require("poste-db.connections")
  local url, url_err = connections.resolve_connection_url(conn)
  if not url then
    cb(("connection %q not found: %s"):format(conn, tostring(url_err)), nil)
    return
  end

  sql = strip_directives(sql)

  local executor = require("poste-db.executor")
  local ok, job_err = pcall(executor.execute, {
    sql = sql,
    conn_url = url,
    database = database,
    mode = "greedy",
    src_file = "poste://ai_chat",
    log_source = "ai_chat",
    log_extra = { connection = conn },
    on_response = function(parsed)
      -- in-band database errors arrive as a normal response: surface them as
      -- a chat error (not a fake success) and retain them for the dataset
      -- view's ask-AI action
      local in_band = nil
      if parsed and parsed.has_error then
        local results = parsed.results
        if not results and type(parsed.body) == "string" then
          local decoded = util.decode_dataset_body(parsed)
          results = decoded and decoded.results or nil
        end
        for _, r in ipairs(results or {}) do
          if r.error and r.error ~= "" then
            in_band = type(r.error) == "string" and r.error or vim.inspect(r.error)
            break
          end
        end
        -- The flag is the failure; the text is only its explanation. Missing
        -- text must not downgrade the outcome back to a success line — this
        -- call answers a chat turn, and "✓ executed" is the worst thing it can
        -- say about a statement the server rejected.
        if not in_band then in_band = UNEXPLAINED_FAILURE end
      end
      vim.schedule(function()
        if in_band then
          require("poste-db.state").last_error = {
            message = in_band,
            sql = sql,
            connection = conn,
            database = database,
            at = os.time(),
          }
          cb("SQL error: " .. in_band, nil)
          return
        end
        local ok_r, render_err = pcall(M.render_dataset, parsed, sql)
        if ok_r then
          cb(nil, "✓ executed against " .. conn .. (database and ("/" .. database) or "")
            .. " — results are in the dataset view")
        else
          cb("dataset render failed: " .. tostring(render_err), nil)
        end
      end)
    end,
    on_error = function(message)
      vim.schedule(function() cb("SQL error: " .. tostring(message), nil) end)
    end,
  })
  if not ok then cb("failed to start execution: " .. tostring(job_err), nil) end
end

M._test = {
  is_readonly = M.is_readonly,
  resolve_target = M.resolve_target,
  strip_directives = strip_directives,
  append_header = M.append_header,
}

return M
