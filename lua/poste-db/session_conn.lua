--- Persistent SQL session connection management.
---
--- Each session runs `poste session --connection <url>` as a long-lived
--- process that keeps a database connection open across requests. This lets
--- session variables (`SET @a=1; SELECT @a;`), temporary tables, and `USE db`
--- persist across separate `<CR>` executions.
---
--- Sessions are pooled keyed by `connection_url` + selected database and
--- shared across buffers targeting the same pair.

local state = require("poste-db.state")
local const = require("poste-db.constants")
local verdict = require("poste-db.verdict")
local util = require("poste-db.util")

local M = {}

-- Pool key: connection URL + selected database. A session holds per-database
-- state (USE/SET vars, temp tables, current database), so the same connection
-- with a different @database directive needs its OWN session — reusing the
-- first one silently ran the SQL against the wrong database. \0 cannot occur
-- inside a URL, so the two parts stay unambiguous.
local function pool_key(conn_url, database)
  return conn_url .. "\0" .. (database or "")
end

-- pool[pool_key] = {
--   key         = string,  -- pool_key(conn_url, database)
--   job_id      = number,
--   conn_url    = string,
--   dialect     = string,
--   database    = string,
--   bufs        = { [bufnr] = true },
--   seq         = number,
--   pending     = { [seq] = { on_response = fn, on_error = fn } },
--   buffer      = string,   -- partial stdout line buffer
--   alive       = boolean,
--   created_at  = number,   -- os.time()
--   last_active = number,   -- os.time()
-- }
local pool = {}

-- Mapping connection URL prefix → dialect name (single source in constants).
local function dialect_from_url(url)
  return const.dialect_from_url(url) or "unknown"
end

-- Extract database name from connection URL for display.
local function database_from_url(url)
  if url:match("^sqlite:") then
    -- strip the query string first: `file.sqlite?mode=rwc` names the file,
    -- not a database called "file.sqlite?mode=rwc" (09-08 carry)
    local rest = url:gsub("^sqlite:", ""):gsub("%?.*$", ""):gsub("^/+", "")
    if rest == ":memory:" or rest == "" then return nil end
    local stem = rest:match("([^/]+)%.sqlite$") or rest:match("([^/]+)$")
    return stem
  end
  local scheme_end = url:find("://")
  if scheme_end then
    local after = url:sub(scheme_end + 3)
    local last_slash = after:match(".*()/")
    if last_slash then
      -- strip the query string; and a candidate that still carries `@` is
      -- host info leaked from a `/` inside the password (db-less URL) —
      -- no name is better than a wrong one
      local db = after:sub(last_slash + 1):gsub("%?.*$", "")
      if db ~= "" and not db:find("@", 1, true) then return db end
    end
  end
  return nil
end

--- The database a session talks to, and whether the caller named it.
---
--- `database` is whatever the caller had: an `-- @database` directive, a
--- browser node's `meta.database`, or the SQL envelope's `""` for "unknown"
--- (exec_run normalises it that way). Only a real name counts as explicit —
--- `""` also used to reach `--database`, which the CLI applies as
--- `replace_database_in_url`, i.e. the database was stripped off the URL the
--- session connected with; and a JSON null (`vim.NIL`, lightuserdata) is
--- truthy, so it concatenated into a raise instead of starting a session.
---
--- Both the pool key and the argv are derived here so the two can never
--- disagree: `M.get` looked the pool up with the caller's raw value while
--- `start` stored the session under the URL-inferred name, so for a URL that
--- carries its own database and a buffer with no directive every request
--- missed the pool and forked a second session (losing the SET/USE state the
--- feature exists to keep).
--- @param conn_url string
--- @param database any
--- @return string|nil db, boolean explicit
local function session_target(conn_url, database)
  local named = util.named(database)
  return named or database_from_url(conn_url), named ~= nil
end

-- One wire response aggregating a sequence's per-statement results, shaped
-- like `build_response` so the consumers (sql_runner's SET-prelude filter,
-- dataset rendering, journaling) see the same body either way. `sql` on each
-- result comes from the event; classification mirrors exec_run.build_response
-- (an affected count alone does not make it a non-query).
local function build_sequence_response(session, results)
  local failed = 0
  local total_rows, total_affected, total_ms = 0, 0, 0
  local is_query = false
  for _, r in ipairs(results) do
    if r.failed then failed = failed + 1 end
    if not r.error and not r.failed
      and (r.affected_rows == nil or (r.row_count or 0) > 0 or #(r.columns or {}) > 0) then
      is_query = true
    end
    total_rows = total_rows + (r.row_count or 0)
    if not r.failed and r.affected_rows then
      total_affected = total_affected + r.affected_rows
    end
    total_ms = total_ms + (r.execution_time_ms or 0)
  end
  local has_error = failed > 0
  local body_obj = {
    type = is_query and "resultset" or "affected",
    results = results,
    total_results = #results,
    total_rows = total_rows,
    total_affected = total_affected,
    total_execution_time_ms = total_ms,
    connection = session.conn_url,
    database = session.database or "",
    dialect = session.dialect,
  }
  if has_error then body_obj.has_error = true end
  return {
    status = has_error and "error" or "ok",
    latency_ms = total_ms,
    body = vim.json.encode(body_obj),
    connection = session.conn_url,
    database = session.database,
    dialect = session.dialect,
    results = results,
    has_error = has_error,
  }
end

-- Send a statement LIST as one request per statement on the session's
-- persistent connection, then answer the caller's callbacks once with an
-- aggregated response. The hoisted `SET @var` prelude must travel this way:
-- the session hands each request to MySQL's prepared-statement protocol,
-- which rejects a multi-statement string with a 1064 — and on a session
-- binary before cbd5de3 that error killed the session process, so the
-- executor silently re-ran the whole request on a one-shot exec-file
-- connection where the SET's variable died with the process (the next
-- statement then failed with "column cannot be null" on a fresh session).
-- The requests are sent back to back: the session loop reads stdin and
-- executes serially, so ordering is the wire order.
local function execute_sequence(session, statements, callbacks)
  local total = #statements
  local collector = {
    results = {},   -- [statement index] = that statement's result table
    arrived = 0,
    delivered = false,
    on_response = callbacks.on_response,
    on_sql_error = callbacks.on_sql_error,
    on_error = callbacks.on_error,
  }

  local function deliver(kind, a, b)
    if collector.delivered then return end
    collector.delivered = true
    if kind == "response" then
      if collector.on_response then collector.on_response(build_sequence_response(session, collector.results)) end
    elseif kind == "sql_error" then
      if collector.on_sql_error then collector.on_sql_error(a, b) end
    else
      if collector.on_error then collector.on_error(a) end
    end
  end

  for i, stmt in ipairs(statements) do
    session.seq = session.seq + 1
    session.last_active = os.time()
    local seq = session.seq
    local index = i
    session.pending[seq] = {
      on_response = function(resp)
        collector.results[index] = resp.results[1]
        collector.arrived = collector.arrived + 1
        if collector.arrived < total then return end
        deliver("response")
      end,
      on_sql_error = function(message, resp)
        collector.results[index] = resp and resp.results and resp.results[1] or nil
        deliver("sql_error", message, resp)
      end,
      on_error = function(message)
        deliver("error", message)
      end,
    }
    local payload = vim.json.encode({ seq = seq, sql = stmt }) .. "\n"
    local ok_send, sent = pcall(vim.fn.chansend, session.job_id, payload)
    state.log("DEBUG", string.format("SQL session send seq=%d (sequence %d/%d) chansend=%s",
      seq, i, total, tostring(sent)))
    if not ok_send or type(sent) ~= "number" or sent <= 0 then
      session.pending[seq] = nil
      deliver("error", "SQL session chansend failed")
      return "not_running"
    end
  end
  return "dispatched"
end

local function build_response(event, session)
  local has_err = event.status ~= "ok"
  local aff = util.affected_rows(event.affected_rows)
  -- A rejected statement is never a resultset, even when it carries neither an
  -- affected count nor columns: typed as a query it reached the dataset panel as
  -- "(no results)", which is how a session-routed failure used to look like an
  -- empty answer instead of the `ERROR: …` line `exec_run` produces for the same
  -- event. `exec_run` keeps the same rule through `not r.failed` in its own
  -- classification loop.
  local is_query = aff == nil and not has_err
  local results = { {
    columns = event.columns or {},
    rows = event.rows or {},
    row_count = tonumber(event.row_count) or 0,
    affected_rows = aff,
    execution_time_ms = tonumber(event.execution_time_ms) or 0,
  } }
  if has_err then
    -- The session names its failures, so the fallback is a real string rather
    -- than an empty one: `event.error` can still be JSON null (`vim.NIL`, truthy
    -- in Lua) and would otherwise reach the user as `SQL error: vim.NIL`.
    results[1].error = verdict.error_text(event.error) or "unknown error"
    -- Same verdict-not-text marker as `exec_run.build_response` puts on its
    -- results, so a consumer that reads one statement's outcome sees the same
    -- shape from either transport.
    results[1].failed = true
  end
  if event.sql and event.sql ~= "" then results[1].sql = event.sql end

  local body_obj = {
    type = is_query and "resultset" or "affected",
    results = results,
    total_results = 1,
    total_rows = tonumber(event.row_count) or 0,
    total_affected = (not has_err and aff) or 0,
    total_execution_time_ms = tonumber(event.execution_time_ms) or 0,
    connection = session.conn_url,
    database = session.database or "",
    dialect = session.dialect,
  }
  if has_err then body_obj.has_error = true end

  return {
    status = has_err and "error" or "ok",
    latency_ms = tonumber(event.execution_time_ms) or 0,
    body = vim.json.encode(body_obj),
    connection = session.conn_url,
    database = session.database,
    dialect = session.dialect,
    results = results,
    has_error = has_err,
  }
end

local function process_event(session, event)
  local cb = session.pending[event.seq]
  if cb then
    session.pending[event.seq] = nil
    state.log("DEBUG", "SQL session callback found for seq=" .. tostring(event.seq))
    local resp = build_response(event, session)
    local ok_cb, err = pcall(function()
      if resp.has_error then
        -- build_response already ran event.error through verdict.error_text
        -- (JSON null is the truthy vim.NIL userdata; the raw value would
        -- reach last_error and the notify as "vim.NIL"), so forward the
        -- normalized text consumers already see in the panel.
        if cb.on_sql_error then cb.on_sql_error(resp.results[1].error or "unknown error", resp) end
      else
        if cb.on_response then cb.on_response(resp) end
      end
    end)
    if not ok_cb then
      state.log("ERROR", "SQL session callback error: " .. tostring(err))
    end
  end
end

local function process_line(session, line)
  local ok, event = pcall(vim.json.decode, line)
  if ok and type(event) == "table" and event.type == "result" then
    process_event(session, event)
  end
end

local function on_session_stdout(session, chunks)
  local combined = table.concat(chunks, "")
  state.log("DEBUG", "SQL session stdout (" .. #combined .. " bytes)")
  session.buffer = session.buffer .. combined
  -- Each response from the Rust session is a single JSON line, but Neovim may
  -- deliver it with or without the trailing newline (or split across chunks).
  local pos = 1
  while true do
    -- Try newline-based parsing first
    local nl = session.buffer:find("\n", pos, true)
    if nl then
      local line = session.buffer:sub(pos, nl - 1)
      pos = nl + 1
      if line ~= "" then
        process_line(session, line)
      end
    else
      -- No newline found. Try to parse the remaining buffer as a complete JSON
      -- object (in case Neovim stripped the newline).
      local remaining = session.buffer:sub(pos)
      if remaining ~= "" then
        local ok, event = pcall(vim.json.decode, remaining)
        if ok and type(event) == "table" and event.type == "result" then
          process_event(session, event)
          session.buffer = ""
        elseif ok then
          -- A complete JSON value that is not a result event is a complete
          -- message we don't handle: drop it. Keeping it glued the stale text
          -- onto every later chunk, so the session parsed nothing for the rest
          -- of its life (a mute session with no error anywhere).
          session.buffer = ""
        else
          -- Incomplete data, keep the buffer for the next chunk
          session.buffer = remaining
        end
      else
        session.buffer = ""
      end
      break
    end
  end
end

local function on_session_exit(session, code)
  session.alive = false
  -- Fail all pending requests
  for seq, cb in pairs(session.pending) do
    session.pending[seq] = nil
    if cb.on_error then cb.on_error("SQL session exited (code " .. code .. ")") end
  end
  -- Remove from pool if still referenced
  if pool[session.key] == session then
    pool[session.key] = nil
  end
end

local function start(conn_url, database)
  local binary = state.find_poste_binary()
  if not binary then return nil end

  local db, explicit = session_target(conn_url, database)
  local now = os.time()
  local session = {
    key = pool_key(conn_url, db),
    job_id = nil,
    conn_url = conn_url,
    dialect = dialect_from_url(conn_url),
    database = db,
    bufs = {},
    seq = 0,
    pending = {},
    buffer  = "",
    alive = true,
    created_at = now,
    last_active = now,
  }

  -- Server-side row cap: 0 keeps parity with exec-file (unlimited, the
  -- dataset paginates client-side); opts.session_max_rows cuts a stray
  -- huge SELECT off at the server. Read at session start — recycle a
  -- running session (:PosteDbSessionStop) to pick up a changed value.
  local session_max_rows = require("poste-db.config").config.session_max_rows
  if type(session_max_rows) ~= "number" or session_max_rows < 0 then
    session_max_rows = 0
  end

  local cmd = { binary, "session", "--connection", conn_url,
    "--max-rows", tostring(math.floor(session_max_rows)), "--timeout", "0" }
  -- Only an EXPLICIT database (an @database directive) becomes --database.
  -- The URL-inferred `db` is display/pool-key info: passing it to the binary
  -- rewrites the URL's last path segment via replace_database_in_url, and
  -- for a sqlite file that swap is lossy — `sqlite:///d/test.sqlite`
  -- inferred "test" and re-opened as `sqlite:///d/test`, a fresh EMPTY
  -- database, silently (the same file name is already in the URL anyway).
  -- `session_target` decides what counts as named, so "" cannot get here.
  if explicit then
    table.insert(cmd, "--database"); table.insert(cmd, db)
  end
  local ok_job, job = pcall(vim.fn.jobstart, cmd, {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 then on_session_stdout(session, data) end
    end,
    on_stderr = function(_, data)
      if data then
        for _, l in ipairs(data) do
          if l ~= "" then state.log("WARN", "SQL session stderr: " .. l) end
        end
      end
    end,
    on_exit = function(_, code)
      -- Called directly, not vim.schedule'd: on_exit already runs on the main
      -- loop, and a schedule added mid-vim.wait is not pumped in headless
      -- runs — a dead session would keep its pending requests parked past any
      -- wait that should have seen them fail (the redis sibling's lesson).
      on_session_exit(session, code)
    end,
  })

  -- jobstart raises E475 when the binary vanished between find_poste_binary
  -- and this call; a raise used to blow through M.get into the executor's
  -- caller instead of answering "start_failed" like every other start failure
  local job_id = ok_job and job or -1

  if job_id <= 0 then return nil end
  session.job_id = job_id
  pool[session.key] = session
  return session
end

--- Get the session for a connection_url + database, starting one if needed.
--- The pool is keyed by the *effective* database (session_target), so a caller
--- with no directive finds the session a URL-database start already made.
--- @param conn_url string
--- @param bufnr number|nil buffer that will use this session
--- @param database any database context to connect to (default: from URL)
--- @return table|nil session
function M.get(conn_url, bufnr, database)
  local session = pool[pool_key(conn_url, session_target(conn_url, database))]
  if not session or not session.alive then
    session = start(conn_url, database)
    if not session then return nil end
  end
  if bufnr then session.bufs[bufnr] = true end
  return session
end

--- Send SQL to the session for a connection, executing it on the persistent
--- connection. Starts a session if none exists.
--- @param conn_url string
--- @param sql string
--- @param callbacks table { on_response = fn(parsed), on_error = fn(msg), on_sql_error = fn(msg, parsed?) }
--- @param bufnr number|nil
--- @param database string|nil database context (e.g. from `@database` directive)
--- @param statements string[]|nil when the sql carries a statement prelude
---   (the hoisted `SET @var` lines), the pieces to send as one request each —
---   a multi-statement single request dies in MySQL's prepared-statement
---   protocol with a 1064 (see execute_sequence). Single-statement requests
---   are the common case and keep the plain one-request shape.
--- @return string  "dispatched", "start_failed", or "not_running"
function M.execute(conn_url, sql, callbacks, bufnr, database, statements)
  callbacks = callbacks or {}
  local session = M.get(conn_url, bufnr, database)
  if not session then
    return "start_failed"
  end
  if not session.alive then
    return "not_running"
  end

  if statements and #statements > 1 then
    return execute_sequence(session, statements, callbacks)
  end
  if statements and #statements == 1 then
    sql = statements[1]
  end

  session.seq = session.seq + 1
  session.last_active = os.time()
  local seq = session.seq
  session.pending[seq] = {
    on_response = callbacks.on_response,
    on_error = callbacks.on_error,
    on_sql_error = callbacks.on_sql_error,
  }
  local payload = vim.json.encode({ seq = seq, sql = sql }) .. "\n"
  -- pcall, not just the `sent <= 0` check: chansend THROWS on a dead channel
  -- ("Can't send data to closed stream" / E900) — the process can die after
  -- the alive check and before this write, and an uncaught throw would skip
  -- the pending cleanup and the caller's on_error (synced to
  -- poste-redis/session_conn.lua, whose SELECT path was hardened the same
  -- way first).
  local ok_send, sent = pcall(vim.fn.chansend, session.job_id, payload)
  state.log("DEBUG", string.format("SQL session send seq=%d job=%d chansend=%s", seq, session.job_id, tostring(sent)))
  state.log("DEBUG", "SQL session payload: " .. (sql and sql:sub(1, 300):gsub("\n", "\\n") or "nil"))
  if not ok_send or type(sent) ~= "number" or sent <= 0 then
    session.pending[seq] = nil
    if callbacks.on_error then callbacks.on_error("SQL session chansend failed") end
    return "not_running"
  end
  return "dispatched"
end

--- Close a session by pool key, or every session of a connection URL
--- (any database) when given a bare URL — `:PosteDbSessionStop <arg>` takes
--- whatever `:PosteDbSessionList` shows.
--- @param key_or_url string
function M.stop(key_or_url)
  local targets = {}
  for key, session in pairs(pool) do
    if key == key_or_url or session.conn_url == key_or_url then
      targets[#targets + 1] = key
    end
  end
  for _, key in ipairs(targets) do
    local session = pool[key]
    session.alive = false
    pool[key] = nil
    if session.job_id and vim.fn.jobwait({ session.job_id }, 0)[1] == -1 then
      pcall(vim.fn.chansend, session.job_id, "")
      pcall(vim.fn.chanclose, session.job_id, "stdin")
    end
  end
end

--- Close all sessions.
function M.stop_all()
  -- M.stop() removes possibly several pool keys (one URL, many databases);
  -- deleting keys other than the current one during a pairs() walk is
  -- undefined in Lua, so snapshot the keys first.
  local keys = {}
  for key in pairs(pool) do keys[#keys + 1] = key end
  for _, key in ipairs(keys) do
    M.stop(key)
  end
end

--- Remove a buffer from all sessions; close sessions with no remaining buffers.
--- @param bufnr number
function M.cleanup_buf(bufnr)
  for key, session in pairs(pool) do
    session.bufs[bufnr] = nil
    if not next(session.bufs) then
      M.stop(key)
    end
  end
end

--- List active sessions (for debugging / :PosteDbSessionList).
--- @return { [key] = { conn_url, database, job_id, dialect, created_at, last_active } }
function M.list()
  local out = {}
  for key, session in pairs(pool) do
    out[key] = {
      conn_url = session.conn_url,
      database = session.database,
      job_id = session.job_id,
      dialect = session.dialect,
      created_at = session.created_at,
      last_active = session.last_active,
    }
  end
  return out
end

M._test = {
  dialect_from_url = dialect_from_url,
  database_from_url = database_from_url,
  build_response = build_response,
  build_sequence_response = build_sequence_response,
  on_session_stdout = on_session_stdout,
}

return M