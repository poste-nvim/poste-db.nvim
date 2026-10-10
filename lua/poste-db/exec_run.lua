--- SQL execution via `poste exec-file`.
---
--- The Rust CLI replaced the `run` subcommand with `exec-file` (streaming
--- `progress`/`result`/`summary` events, file-based, no `--stdin`). This
--- module wraps `exec-file` — writing the SQL to a temp file, streaming the
--- events — and reconstructs the legacy single-JSON "response" shape that the
--- rest of the SQL plugin consumes (`resp.body` decodes to
--- `{ type, results, has_error, ... }`).
---
--- Depends on poste.nvim shared infra: `poste.cli`, `poste.state`.

local cli = require("poste-db.cli")
local state = require("poste-db.state")
local log = require("poste-db.log")
local sql_log = require("poste-db.sql_log")
local util = require("poste-db.util")
local verdict = require("poste-db.verdict")
local lex = require("poste-db.lex")

----------------------------------------------------------------------------
-- Request journaling
--
-- Every exec-file invocation lands in sql_log.jsonl exactly once, success or
-- failure, unless the caller opts out (`opts.log == false` — used by callers
-- that journal richer entries themselves, e.g. edit commits and imports).
-- `opts.log_source` tags the surface; `opts.log_extra` overrides fields the
-- seam can't know (e.g. the connection *name* instead of its URL).
----------------------------------------------------------------------------

--- Entry fields known at dispatch time, or nil when logging is opted out.
local function journal_base(sql, opts)
  local base = sql_log.seam_base(opts)
  if not base then return nil end
  base.sql = sql
  return base
end

----------------------------------------------------------------------------
-- Temp file
----------------------------------------------------------------------------

--- Remove the `###` section markers that sql_runner's synthetic-block wrapping
--- inserts (the Rust CLI cannot parse them as SQL). `-- @` directives are kept:
--- exec-file strips those itself.
local function strip_section_markers(sql)
  local filtered = {}
  for _, l in ipairs(vim.split(sql, "\n", { plain = true })) do
    if not l:match("^%s*###%s*$") then filtered[#filtered + 1] = l end
  end
  return table.concat(filtered, "\n")
end

--- Write SQL content to a temp `.sql` file (system temp dir). Returns the path.
---
--- `###` section markers (from statement.lua's synthetic-block wrapping) are
--- stripped before exec-file parses the file; the Rust CLI only strips `-- @`
--- directives, and a statement left starting with `###` would be misclassified
--- as a non-query (DML) and rendered as "Query OK".
---
--- Note: the file is deliberately NOT placed next to the source buffer's
--- file — connection resolution happens Lua-side (resolve_connection_url)
--- before exec-file is invoked, so discovery from the temp dir is fine.
local function write_temp_file(sql)
  local lines = vim.split(strip_section_markers(sql), "\n", { plain = true })
  local tmp = vim.fn.tempname() .. ".sql"
  -- Pre-create the file 0600: writefile() would create it with the umask
  -- default (0644 on a typical box), leaving statement text world-readable on
  -- shared hosts. writefile truncates an existing file and keeps its mode.
  local uv = vim.uv or vim.loop
  local ok_open, fd = pcall(uv.fs_open, tmp, "w", tonumber("600", 8))
  if ok_open and fd then uv.fs_close(fd) end
  vim.fn.writefile(lines, tmp)
  return tmp
end

----------------------------------------------------------------------------
-- USE statement detection
----------------------------------------------------------------------------

--- Detect a lone `USE <db>;` statement (exec-file skips USE statements, so we
--- handle context switching without hitting the database).
--- Broader than sql_runner.is_use_stmt (routing): here the matched name is
--- *applied* to state.context.database, so quoted and commented forms must
--- resolve too. Don't unify the two blindly.
--- Case-insensitive like lex.find_use_database and the Rust side — a lowercase
--- `use db;` must not fall through to the database as real SQL (a syntax error
--- on postgres) while the uppercase form switches context.
--- @param sql string
--- @return string|nil database_name
local function detect_use(sql)
  local trimmed = sql:match("^%s*(.*)%s*$") or ""
  -- `[%w_-]`: hyphenated db names (`USE my-db;`, `` USE `my-db`; ``) switch
  -- context like plain identifiers; the plain-identifier class used to miss
  -- them and route the statement into the session as real SQL — a syntax
  -- error on postgres/sqlite (09-12 carry).
  local name = trimmed:match("^[Uu][Ss][Ee]%s+([%w_-]+)%s*;?%s*$")
  if not name then
    name = trimmed:match("^[Uu][Ss][Ee]%s+[\"`]([%w_-]+)[\"`]%s*;?%s*$")
  end
  -- MSSQL's canonical spelling: `USE [My DB];` is valid T-SQL, so left to the
  -- server it EXECUTES while the plugin's context keeps pointing at the old
  -- database — every later query in the buffer runs against a db the user
  -- believes they left. Greedy to the last `]`, then `]]` unwinds to `]`
  -- (the same reading lex.find_use_database applies on the context side).
  if not name then
    local bracketed = trimmed:match("^[Uu][Ss][Ee]%s+(%[.*%])%s*;?%s*$")
    if bracketed then
      name = bracketed:sub(2, -2):gsub("]]", "]")
    end
  end
  -- `USE db -- comment` / `USE db; -- comment`: the capture is required here
  -- — a groupless pattern makes match() return the whole statement, which
  -- then leaks into database_name / state.context.database.
  -- `[^\n]` rather than `.`: Lua's `.` crosses newlines, so `USE db\n-- note\n
  -- SELECT 1` matched too and the whole batch was swallowed as a lone USE
  -- (nothing ran, and the context switched on a statement the user never
  -- meant to execute alone).
  if not name then
    name = trimmed:match("^[Uu][Ss][Ee]%s+([%w_-]+)%s*;?%s*%-%-[^\n]*$")
  end
  if not name then
    local bracketed = trimmed:match("^[Uu][Ss][Ee]%s+(%[.*%])%s*;?%s*%-%-[^\n]*$")
    if bracketed then
      name = bracketed:sub(2, -2):gsub("]]", "]")
    end
  end
  return name
end

----------------------------------------------------------------------------
-- Command construction
----------------------------------------------------------------------------

--- Build `exec-file` args (binary is prepended by cli.run_async).
local function build_cmd(tmpfile, opts)
  local cmd = {
    "exec-file", tmpfile,
    "--env", state.current_env or "dev",
    "--mode", opts.mode or "greedy",
    "--json",
  }
  local timeout = opts.timeout
  if timeout then
    table.insert(cmd, "--timeout"); table.insert(cmd, tostring(timeout))
  end
  -- 0 = unlimited, so client-side dataset pagination keeps working.
  local max_rows = opts.max_rows
  if max_rows == nil then max_rows = 0 end
  table.insert(cmd, "--max-rows"); table.insert(cmd, tostring(max_rows))
  -- Only a name that names something goes on the command line. A blank
  -- `--database` is applied by the CLI as `replace_database_in_url`, i.e. the
  -- statement runs against the connection string with its database stripped
  -- off; `vim.NIL` (a decoded JSON null) is truthy and would be handed to
  -- jobstart as a userdata. See util.named.
  local conn_url = util.named(opts.conn_url)
  local database = util.named(opts.database)
  if conn_url then
    table.insert(cmd, "--connection"); table.insert(cmd, conn_url)
  end
  if database then
    table.insert(cmd, "--database"); table.insert(cmd, database)
  end
  return cmd
end

--- Whether the caller pinned a concrete target for the run.
--- `""` is not a pin: it is what `build_response` writes when the server
--- reported no database, and the round-trip `state.context` → caller → here
--- used to count as one. With `opts.database = ""` the lone-`USE` shortcut was
--- skipped and the statement went to `exec-file`, which filters USE out of a
--- run — so the context never switched and nothing executed.
local function has_target(opts)
  return util.named(opts.conn_url) ~= nil or util.named(opts.database) ~= nil
end

-- Normalize an `affected_rows` value from the event stream (number → number,
-- JSON null → nil).
local function norm_affected(v)
  if v == nil or v == vim.NIL then return nil end
  return tonumber(v)
end

-- The `exec-file` result event carries the SQL text; use its leading keyword to
-- tell a query apart from a DML even when the binary/driver reports
-- `affected_rows` as a number (not null) and omits columns/rows for a SELECT.
-- NB — intentional mirror drift vs the Rust `QueryKinds`
-- (poste-exec/src/sql_exec_common.rs): that list is per-dialect and has no
-- CALL/EXEC entries; this flat fallback list is a superset used ONLY to break
-- ties when reconstructing a legacy response (the Rust event's `affected_rows`
-- null-ness and column/row presence decide first). Never promote this list to
-- an authority; reconcile with QueryKinds only if it ever stops being a
-- last-resort tie-breaker.
local QUERY_PREFIXES = {
  "SELECT", "WITH", "EXPLAIN", "SHOW", "VALUES", "PRAGMA", "DESCRIBE",
  "TABLE", "DESC", "RETURNING", "CALL", "EXEC",
}

--- Strip string literals and comments so keyword detection only sees SQL
--- structure (a `'RETURNING …'` inside a literal must not flip the type).
--- lex.blank_regions is one state machine: the gsub chain this replaced
--- stopped a literal blank at an escaped `''`'s second quote (`'it''s
--- RETURNING x'` leaked its tail and flipped an UPDATE into a query) and
--- knew nothing of dollar-quoted bodies (`$$ … $$ RETURNING`-shaped SQL
--- inside a function body counted the same way).
local function strip_literals_and_comments(sql)
  return lex.blank_regions(sql)
end

local function is_query_sql(sql)
  if not sql or sql == "" then return false end
  -- DML with RETURNING returns rows (pg/sqlite): classify as a query. The
  -- word-boundary check keeps a column like `my_returning_col` from matching;
  -- lowercasing covers the common lowercase style — the old substring find
  -- misclassified lowercase `update … returning` as affected while flipping
  -- anything with an uppercase RETURNING literal into a query.
  local flat = strip_literals_and_comments(sql):lower()
  if flat:find("%f[%w_]returning%f[^%w_]") then return true end
  local head = sql:match("^%s*([A-Za-z]+)")
  head = head and head:upper() or ""
  for _, p in ipairs(QUERY_PREFIXES) do
    if head == p then return true end
  end
  return false
end

----------------------------------------------------------------------------
-- Response reconstruction
----------------------------------------------------------------------------

--- Accumulate `result`/`summary` events into a legacy-shaped resp object.
--- @param conn string resolved connection URL (fallback label)
--- @param shown_db string
local function build_response(events, conn, shown_db)
  local results = {}
  local total_ms = 0
  local dialect = ""
  local connection = conn or ""
  local database = shown_db or ""
  local failed = 0
  local total_rows = 0
  local total_affected = 0
  local rolled_back = false

  for _, ev in ipairs(events) do
    if ev.type == "result" then
      local res = {
        columns = ev.columns or {},
        rows = ev.rows or {},
        row_count = tonumber(ev.row_count) or 0,
        affected_rows = norm_affected(ev.affected_rows),
        execution_time_ms = tonumber(ev.execution_time_ms) or 0,
      }
      -- Text is optional and, over JSON, may arrive as null (`vim.NIL`, which is
      -- truthy and raises when a consumer concatenates it) or empty. Normalise
      -- it here so `res.error` is either a non-empty string or absent, and the
      -- `failed` flag below stays the only verdict.
      local err_text = verdict.error_text(ev.error)
      if err_text then res.error = err_text end
      if ev.sql and ev.sql ~= "" then res.sql = ev.sql end
      -- The event's verdict and its message are two fields, and the message is
      -- optional: keep the verdict on the result. Without it a consumer reading
      -- one statement's outcome has only the text to go on, and a failed
      -- statement that said nothing looks exactly like one that succeeded.
      -- Named `failed`, not `status`, because the per-statement `status` field
      -- in `file_exec` and the progress dialogs is a different shape.
      if ev.status ~= "ok" then res.failed = true end
      table.insert(results, res)
      -- A rejected statement affected nothing, whatever number sits beside it, so
      -- it stays out of the sum: the dataset's per-statement rows show `ERROR`
      -- for it, and a total that counted its rows would contradict them.
      if ev.status == "ok" and res.affected_rows then
        total_affected = total_affected + res.affected_rows
      end
      if ev.status ~= "ok" then failed = failed + 1 end
    elseif ev.type == "summary" then
      total_ms = tonumber(ev.total_time_ms) or 0
      dialect = ev.dialect or dialect
      connection = ev.connection or connection
      database = ev.database or database
      -- exec-file sets rolled_back=true when --mode transaction aborted
      -- with a ROLLBACK after a failed statement.
      rolled_back = ev.rolled_back == true or rolled_back
    end
  end

  -- Match legacy classification: a resultset if any result is a query (has
  -- columns, or returned rows, or no affected_rows), else an affected-rows
  -- response. Keying off column presence (not just affected_rows == nil)
  -- guards against a driver/binary reporting affected_rows as 0 for a SELECT,
  -- which would otherwise be misclassified as an affected/Query OK response.
  -- NB: errors were already counted when their event arrived above; this pass
  -- only decides resultset-vs-affected, it must not re-increment `failed`.
  local is_query = false
  for _, r in ipairs(results) do
    if not r.error and not r.failed
      and (r.affected_rows == nil or (r.row_count or 0) > 0 or #(r.columns or {}) > 0
        or is_query_sql(r.sql or "")) then
      is_query = true
    end
    total_rows = total_rows + (r.row_count or 0)
  end
  local has_error = failed > 0

  local body_obj = {
    type = is_query and "resultset" or "affected",
    results = results,
    total_results = #results,
    total_rows = total_rows,
    total_affected = total_affected,
    total_execution_time_ms = total_ms,
    connection = connection,
    database = database,
    dialect = dialect,
  }
  if has_error then body_obj.has_error = true end
  if rolled_back then body_obj.rolled_back = true end

  return {
    status = has_error and "error" or "ok",
    latency_ms = total_ms,
    body = vim.json.encode(body_obj),
    connection = connection,
    database = database,
    dialect = dialect,
    results = results,
    has_error = has_error,
  }
end

--- First in-band statement error of a delivered response, or nil. A SQL failure
--- arrives as a normal `on_response` callback carrying `has_error` plus, as a
--- rule, a per-result `error` — the job ran, the statement did not — so a caller
--- that notifies only "failed" throws away the one string that says why. When
--- even the string is missing the verdict still has to be reported, hence the
--- fallback from `poste-db.verdict`.
local function first_error(resp)
  for _, r in ipairs(resp and resp.results or {}) do
    local failed, text = verdict.classify(r)
    if failed then return text end
  end
  -- The envelope verdict on its own: a run can report a rejected statement
  -- without any result carrying it, and "no message" is not "no failure".
  if resp and resp.has_error == true then return verdict.UNEXPLAINED_FAILURE end
  return nil
end

---------------------------------------------------------------------------
-- Event decoding
---------------------------------------------------------------------------

--- `jobstart` with buffered stdout delivers each JSON event as its own element
--- of the `data` array (newlines already stripped, with a trailing `""`), so we
--- parse each non-empty element directly rather than reassembling lines.
local function for_each_event(data, on_event)
  if not data then return end
  for _, line in ipairs(data) do
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == "table" then on_event(event) end
    end
  end
end

---------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------

--- Parse a full stdout blob (newline-separated JSON events) into events.
local function parse_lines(output)
  local events = {}
  if not output or output == "" then return events end
  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == "table" then events[#events + 1] = event end
    end
  end
  return events
end

--- Build the legacy-shaped response for a lone USE statement.
local function make_use_response(use_db)
  return {
    status = "ok",
    latency_ms = 0,
    body = vim.json.encode({
      type = "use",
      database_name = use_db,
      is_use_statement = true,
      connection = "",
      dialect = "",
    }),
    connection = "",
    database = use_db,
    dialect = "",
  }
end

--- Run SQL synchronously via `exec-file`, returning a legacy-shaped response
--- (or nil on failure). Calls are blocking — for non-interactive/introspection
--- queries where the caller needs the result inline.
--- @param sql string
--- @param opts table  same as run_async (src_file, conn_url, database, mode, timeout, max_rows)
local function run_sql(sql, opts)
  opts = opts or {}
  local t0 = vim.uv.now()
  local base = journal_base(sql, opts)
  local use_db = detect_use(sql)
  if use_db and not has_target(opts) then
    local resp = make_use_response(use_db)
    sql_log.result(base, resp, vim.uv.now() - t0)
    return resp
  end
  local binary = state.find_poste_binary()
  if not binary then
    sql_log.fail(base, "Poste binary not found", vim.uv.now() - t0)
    return nil
  end
  local tmpfile = write_temp_file(sql)
  local cmd = vim.list_extend({ binary }, build_cmd(tmpfile, opts))
  local ok_sys, result_obj = pcall(vim.system, cmd, { timeout = 30000 })
  if not ok_sys then
    -- Nothing was spawned, so no child can still want the file.
    pcall(vim.fn.delete, tmpfile)
    sql_log.fail(base, "failed to start exec-file", vim.uv.now() - t0)
    return nil
  end
  -- The temp file is exec-file's only input; it must outlive the child.
  -- Unlinking between spawn and wait() races the child's first open() and
  -- fails the run with "file not found" — delete only after wait() returns.
  local result = result_obj:wait()
  pcall(vim.fn.delete, tmpfile)
  if result.code ~= 0 then
    local err = (result.stderr and result.stderr ~= "") and result.stderr
      or ("exec-file exit code " .. tostring(result.code))
    sql_log.fail(base, err, vim.uv.now() - t0)
    return nil
  end
  local events = parse_lines(result.stdout)
  if #events == 0 then
    sql_log.fail(base, "exec-file produced no events", vim.uv.now() - t0)
    return nil
  end
  local resp = build_response(events, opts.conn_url, opts.database)
  sql_log.result(base, resp, vim.uv.now() - t0)
  return resp
end

--- Run SQL asynchronously via `exec-file`.
--- @param sql string SQL content to execute
--- @param opts table
---   - src_file: string|nil  source buffer path (for temp-file placement/discovery)
---   - conn_url: string|nil  resolved connection URL ("--connection")
---   - database: string|nil  database override
---   - mode: "greedy"|"transaction"
---   - timeout, max_rows: number|nil
---   - on_response: function(resp)
---   - on_progress: function(seq, total)|nil
---   - on_error: function(message, stderr)|nil   called when the process itself fails
--- Logging opts (see journal_base): log=false opts out; log_source/log_extra tag.
---
--- Delivery contract: every run reports its outcome exactly once through the
--- callbacks — a SQL failure as `on_response` (has_error), a transport failure
--- as `on_error`. A run that never started (binary missing, jobstart refused
--- the spawn) delivers `on_error` here and returns 1, so a caller must not add
--- its own failure report off the return value; the return is the job id
--- (>0) when a real job runs, 1 when the run was handled inline (a lone USE,
--- or a failed start).
local function run_async(sql, opts, callbacks)
  opts = opts or {}
  callbacks = callbacks or {}
  local on_response = callbacks.on_response
  local on_error = callbacks.on_error

  local t0 = vim.uv.now()
  local base = journal_base(sql, opts)
  if base then
    --- Journal, then deliver. Transport failures (binary missing, job start
    --- failure, non-zero exit without a summary) arrive via on_error; SQL
    --- failures arrive as a normal response with has_error.
    local user_on_response, user_on_error = on_response, on_error
    on_response = function(resp)
      -- Binary-reported execution time when available, wall clock otherwise.
      local elapsed = tonumber(resp and resp.latency_ms) or (vim.uv.now() - t0)
      sql_log.result(base, resp, elapsed)
      if user_on_response then user_on_response(resp) end
    end
    on_error = function(message, stderr)
      sql_log.fail(base, message, vim.uv.now() - t0)
      if user_on_error then user_on_error(message, stderr) end
    end
  end

  -- Lone USE statement: handled locally (exec-file skips USE).
  local use_db = detect_use(sql)
  if use_db and not has_target(opts) then
    local resp = {
      status = "ok",
      latency_ms = 0,
      body = vim.json.encode({
        type = "use",
        database_name = use_db,
        is_use_statement = true,
        connection = opts.conn_url or "",
        dialect = "",
      }),
      connection = opts.conn_url or "",
      database = use_db,
      dialect = "",
    }
    if on_response then on_response(resp) end
    return 1
  end

  local binary = state.find_poste_binary()
  if not binary then
    if on_error then on_error("Poste binary not found", "") end
    return 1
  end

  local tmpfile = write_temp_file(sql)

  local cmd = build_cmd(tmpfile, opts)
  log.info("exec-run cmd: " .. log.redact_cmd(cmd))

  local events = {}
  local stderr_buf = {}
  local summary_seen = false

  local job_id
  -- Set when the spawn is known to have failed; the exit callback a failed
  -- start may have synthesized (cli.run_async calls it synchronously, its
  -- delivery lands later via vim.schedule) must not report the same run twice.
  local start_failed = false

  local function flush_and_deliver()
    local resp = build_response(events, opts.conn_url, opts.database)
    if on_response then on_response(resp) end
  end

  job_id = cli.run_async(cmd, {
    on_stdout = function(data)
      if not data or #data == 0 then return end
      for_each_event(data, function(event)
        if event.type == "result" then
          events[#events + 1] = event
          if callbacks.on_progress then callbacks.on_progress(event.seq, event.total) end
        elseif event.type == "summary" then
          events[#events + 1] = event
          summary_seen = true
          vim.schedule(function()
            pcall(vim.fn.delete, tmpfile)
            flush_and_deliver()
          end)
        end
      end)
    end,
    on_stderr = function(data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(stderr_buf, l) end
      end
    end,
    on_exit = function(code)
      vim.schedule(function()
        pcall(vim.fn.delete, tmpfile)
        if start_failed then return end
        if not summary_seen and on_error then
          local text = table.concat(stderr_buf, "\n")
          -- "exit code 0" as an error message reads like a success — say why
          -- the run counts as failed (same wording as file_exec's journal).
          on_error(text ~= "" and text or ("exec-file exit code " .. code .. " (no summary event)"), text)
        end
      end)
    end,
  })

  -- A run that never started reports through on_error exactly once, here —
  -- whatever the seam (jobstart's -1 fires no callbacks at all, so a caller
  -- keyed on callbacks alone would wait forever; and a caller keyed on the
  -- return value would add a second report to the binary-missing delivery).
  -- Returning 1 (not nil) tells callers "handled inline" so their own
  -- `job_id <= 0` armor stays dormant.
  if not job_id or job_id <= 0 then
    start_failed = true
    pcall(vim.fn.delete, tmpfile)
    if on_error then on_error("Failed to start poste job", "") end
    return 1
  end

  return job_id
end

return {
  run_async = run_async,
  run_sql = run_sql,
  detect_use = detect_use,
  build_response = build_response,
  first_error = first_error,
  for_each_event = for_each_event,
  is_query_sql = is_query_sql,
  strip_section_markers = strip_section_markers,
  write_temp_file = write_temp_file,
}