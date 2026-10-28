--- session_conn pool keying: one session per (connection, database) pair.
--- The pool used to key on the bare connection URL, so two buffers using the
--- same connection with different @database directives shared the first
--- session — the second silently executed against the wrong database.

describe("poste-db.session_conn", function()
  local state = require("poste-db.state")
  local session_conn = require("poste-db.session_conn")

  local jobs
  local real_binary_lookup
  local real_jobstart, real_jobwait, real_chansend

  before_each(function()
    jobs = {}
    real_binary_lookup = state.find_poste_binary
    state.find_poste_binary = function() return "/fake/poste" end
    real_jobstart = vim.fn.jobstart
    vim.fn.jobstart = function(cmd, opts)
      local id = 1000 + vim.tbl_count(jobs)
      jobs[id] = { cmd = cmd, opts = opts }
      return id
    end
    real_jobwait = vim.fn.jobwait
    vim.fn.jobwait = function() return { -1 } end
    real_chansend = vim.fn.chansend
    vim.fn.chansend = function() return 10 end
  end)

  after_each(function()
    session_conn.stop_all()
    state.find_poste_binary = real_binary_lookup
    vim.fn.jobstart = real_jobstart
    vim.fn.jobwait = real_jobwait
    vim.fn.chansend = real_chansend
  end)

  it("pools one session per connection+database pair", function()
    local a = session_conn.get("postgres://h/app", nil, "db1")
    local b = session_conn.get("postgres://h/app", nil, "db2")
    local a_again = session_conn.get("postgres://h/app", nil, "db1")
    assert.are.equal(a, a_again, "same pair must reuse the pooled session")
    assert.are_not.equal(a, b, "a different database must get its own session")
    assert.are.equal(2, vim.tbl_count(jobs))
    assert.are.equal("db1", a.database)
    assert.are.equal("db2", b.database)
  end)

  it("stops every database-scoped session of a connection by bare URL", function()
    session_conn.get("postgres://h/app", nil, "db1")
    session_conn.get("postgres://h/app", nil, "db2")
    session_conn.get("postgres://h/other", nil, nil)
    session_conn.stop("postgres://h/app")
    assert.are.equal(1, vim.tbl_count(session_conn.list()))
  end)

  it("execute dispatches on the requested database's session", function()
    local status = session_conn.execute("postgres://h/app", "SELECT 1", {}, nil, "dbA")
    assert.are.equal("dispatched", status)
    status = session_conn.execute("postgres://h/app", "SELECT 1", {}, nil, "dbB")
    assert.are.equal("dispatched", status)
    assert.are.equal(2, vim.tbl_count(jobs))
  end)

  local function arg_value(cmd, flag)
    for i, v in ipairs(cmd) do
      if v == flag then return cmd[i + 1] end
    end
    return nil
  end

  it("passes opts.session_max_rows to the session command", function()
    local config = require("poste-db.config")
    local saved = config.config.session_max_rows
    config.config.session_max_rows = 500
    local ok, session = pcall(session_conn.get, "postgres://h/capped", nil, "db1")
    config.config.session_max_rows = saved
    assert.is_true(ok)
    assert.equals("500", arg_value(jobs[session.job_id].cmd, "--max-rows"))
  end)

  it("keeps --max-rows unlimited (0) by default and guards bad values", function()
    local config = require("poste-db.config")
    local saved = config.config.session_max_rows
    config.config.session_max_rows = -3
    local a = session_conn.get("postgres://h/guarded", nil, "db1")
    assert.equals("0", arg_value(jobs[a.job_id].cmd, "--max-rows"), "negative caps back to unlimited")
    config.config.session_max_rows = "lots"
    local b = session_conn.get("postgres://h/guarded", nil, "db2")
    assert.equals("0", arg_value(jobs[b.job_id].cmd, "--max-rows"), "non-number falls back to unlimited")
    config.config.session_max_rows = saved
  end)

  it("never passes the URL-inferred database as --database (sqlite file corrupt)", function()
    -- regression: the sqlite stem inferred from the URL was passed as
    -- --database, and the binary's replace_database_in_url swapped it for
    -- the URL's last path segment — `sqlite:///d/test.sqlite` re-opened as
    -- `sqlite:///d/test`, a fresh EMPTY database, silently.
    local a = session_conn.get("sqlite:///d/test.sqlite", nil, nil)
    assert.is_nil(arg_value(jobs[a.job_id].cmd, "--database"))
    -- an EXPLICIT database (an @database directive) still overrides
    local b = session_conn.get("postgres://h/app", nil, "override_db")
    assert.equals("override_db", arg_value(jobs[b.job_id].cmd, "--database"))
    -- pool keying keeps the inferred name for display purposes
    assert.equals("test", a.database)
  end)

  it("does not let an unnamed database become --database", function()
    -- The SQL envelope writes "" for a database it could not name, and a JSON
    -- null decodes to vim.NIL; both are truthy, so both used to reach the
    -- binary as `--database` — the CLI applies it as replace_database_in_url,
    -- so the session connected with the database stripped off the URL — and
    -- vim.NIL raised inside the pool key instead of starting anything.
    local a = session_conn.get("postgres://h/blank", nil, "")
    assert.is_nil(arg_value(jobs[a.job_id].cmd, "--database"))
    assert.equals("blank", a.database, "the URL's own database names the session")

    local b = session_conn.get("postgres://h/nullish", nil, vim.NIL)
    assert.is_nil(arg_value(jobs[b.job_id].cmd, "--database"))
    assert.equals("nullish", b.database)
  end)

  it("reuses one session for a directive-less run and the URL's own database", function()
    -- get() keyed the pool with the caller's raw value while start() stored
    -- the session under the URL-inferred name. With a URL that carries its
    -- own database and a buffer that has no `-- @database`, every statement
    -- missed the pool and forked a SECOND session — losing the SET/USE and
    -- temp-table state the persistent session exists to keep, and leaving the
    -- first one to be reaped.
    local url = "postgres://h/reuse"
    local a = session_conn.get(url, nil, nil)
    local b = session_conn.get(url, nil, nil)
    assert.are.equal(a, b, "a second directive-less run reuses the session")
    assert.are.equal(1, vim.tbl_count(jobs))
    -- the envelope's "" names that same target, not a third one
    local c = session_conn.get(url, nil, "")
    assert.are.equal(a, c)
    assert.are.equal(1, vim.tbl_count(jobs))
  end)

  it("answers start_failed when jobstart raises E475 on a vanished binary", function()
    -- find_poste_binary answered a moment before; the path is gone now.
    -- jobstart raises Vim:E475 instead of returning an error code, and the
    -- raise used to escape M.get into the executor's caller instead of the
    -- "start_failed" answer every other start failure gives.
    vim.fn.jobstart = function()
      error("Vim:E475: /fake/poste is not executable")
    end
    local outcome = session_conn.execute("postgres://h/app", "SELECT 1", {}, nil, "db9")
    assert.equals("start_failed", outcome)
  end)

  it("survives a chansend THROW on a dead channel", function()
    -- chansend does not return -1 on a dead stream, it RAISES ("Can't send
    -- data to closed stream" / E900): the process can die between execute()'s
    -- alive check and the write. The unguarded write skipped the pending
    -- cleanup and the caller's on_error, and callers upstream of execute
    -- (a keymap, a scan loop) saw the raw Lua error instead. (Synced from
    -- poste-redis/session_conn_spec.lua.)
    local session = session_conn.get("postgres://h/app", nil, "db1")
    assert.is_not_nil(session)
    vim.fn.chansend = function()
      error("Can't send data to closed stream")
    end
    local errs = {}
    local outcome = session_conn.execute("postgres://h/app", "SELECT 1", {
      on_response = function() error("on_response must not fire") end,
      on_error = function(msg) errs[#errs + 1] = msg end,
    }, nil, "db1")
    assert.equals("not_running", outcome)
    assert.equals(1, #errs)
    assert.match("chansend failed", errs[1])
    -- the request's pending entry must be gone, or the session looks busy
    -- with a request nothing will ever answer
    assert.equals(0, vim.tbl_count(session.pending))
  end)
end)

describe("session_conn database_from_url", function()
  local session_conn = require("poste-db.session_conn")
  local from_url = session_conn._test.database_from_url

  it("strips the query string from the database name", function()
    -- `db?schema=public` used to display (and pool-key) with the query riding
    -- along; the sqlite variant named a database "file.sqlite?mode=rwc"
    assert.equals("db", from_url("postgres://u:p@h:5432/db?schema=public"))
    assert.equals("file", from_url("sqlite:/tmp/x/file.sqlite?mode=rwc"))
  end)

  it("returns nil rather than password fragments for a db-less url", function()
    -- a `/` inside the password with no db path used to leak `p/ss@h:3306`
    assert.is_nil(from_url("mysql://u:p/ss@h:3306"))
    -- a real db path after a slash-y password still resolves
    assert.equals("blog", from_url("mysql://u:p/ss@h:3306/blog"))
  end)
end)

describe("session_conn build_response", function()
  local session_conn = require("poste-db.session_conn")
  local build = session_conn._test.build_response
  local session = { conn_url = "postgres://h/app", database = "app", dialect = "postgres" }

  it("names a failure whose error field is JSON null", function()
    -- The session transport is a separate builder from exec_run's, and its
    -- `event.error` can be null: `SQL error: vim.NIL` reached the user that way.
    local resp = build({ seq = 1, status = "error", error = vim.NIL, execution_time_ms = 2 }, session)
    assert.equals("error", resp.status)
    assert.is_true(resp.has_error)
    assert.equals("string", type(resp.results[1].error))
    assert.is_true(resp.results[1].failed)
    -- A failure with no affected count and no rows must not become a resultset:
    -- the dataset panel renders that as "(no results)".
    assert.equals("affected", vim.json.decode(resp.body).type)
  end)

  it("keeps real text and stamps the verdict next to it", function()
    local resp = build({ seq = 1, status = "error", error = "deadlock detected",
      affected_rows = vim.NIL, execution_time_ms = 3 }, session)
    assert.equals("deadlock detected", resp.results[1].error)
    assert.is_true(resp.results[1].failed)
    -- An error is never a resultset, whatever the row fields say.
    assert.equals("affected", vim.json.decode(resp.body).type)
  end)

  it("leaves a successful read unflagged and resultset-shaped", function()
    local resp = build({ seq = 1, status = "ok", row_count = 1, affected_rows = vim.NIL,
      columns = { { name = "x" } }, rows = { { 1 } }, execution_time_ms = 1 }, session)
    assert.is_false(resp.has_error)
    assert.is_nil(resp.results[1].failed)
    assert.is_nil(resp.results[1].error)
    local body = vim.json.decode(resp.body)
    assert.equals("resultset", body.type)
    assert.equals(1, body.total_rows)
  end)

  it("reports an INSERT's affected rows without a failure marker", function()
    local resp = build({ seq = 1, status = "ok", affected_rows = 7, execution_time_ms = 1 }, session)
    assert.equals(7, resp.results[1].affected_rows)
    assert.is_nil(resp.results[1].failed)
    assert.equals("affected", vim.json.decode(resp.body).type)
  end)

  it("a read whose driver reports affected_rows still arrives as a resultset", function()
    -- The old single-path rule (`aff == nil`) ignored columns entirely, so a
    -- SELECT with a numeric affected_rows typed "affected" HERE while the
    -- sequence aggregator and exec_run typed the same event "resultset".
    -- The shared verdict.carries_resultset rule lets columns decide first.
    local resp = build({ seq = 1, status = "ok", affected_rows = 0, row_count = 2,
      columns = { { name = "x" } }, rows = { { 1 }, { 2 } }, execution_time_ms = 1 }, session)
    assert.equals(0, resp.results[1].affected_rows)
    assert.equals("resultset", vim.json.decode(resp.body).type)
    assert.equals(2, vim.json.decode(resp.body).total_rows)
  end)
end)

describe("session_conn on_sql_error gets the normalized error text", function()
  -- process_event used to forward the RAW `event.error`: JSON null decoded
  -- to the truthy vim.NIL userdata, so `event.error or "unknown error"` kept
  -- the userdata and last_error/notify rendered "vim.NIL" while the panel
  -- showed the normalized text. The forward must be the same text the panel
  -- gets — resp.results[1].error, already run through verdict.error_text.
  local state = require("poste-db.state")
  local session_conn = require("poste-db.session_conn")

  local jobs
  local real_binary_lookup
  local real_jobstart, real_jobwait, real_chansend

  before_each(function()
    jobs = {}
    real_binary_lookup = state.find_poste_binary
    state.find_poste_binary = function() return "/fake/poste" end
    real_jobstart = vim.fn.jobstart
    vim.fn.jobstart = function(cmd, opts)
      local id = 1000 + vim.tbl_count(jobs)
      jobs[id] = { cmd = cmd, opts = opts }
      return id
    end
    real_jobwait = vim.fn.jobwait
    vim.fn.jobwait = function() return { -1 } end
    real_chansend = vim.fn.chansend
    vim.fn.chansend = function() return 10 end
  end)

  after_each(function()
    session_conn.stop_all()
    state.find_poste_binary = real_binary_lookup
    vim.fn.jobstart = real_jobstart
    vim.fn.jobwait = real_jobwait
    vim.fn.chansend = real_chansend
  end)

  -- Execute first, then take the job id from the pool: `execute` dispatches
  -- against the session its own M.get resolves, and with no database argument
  -- that can be a different pool entry than a bare `get` on a URL whose path
  -- infers a database (get stores under the inferred key, execute looks the
  -- raw nil key up). `list()` returns copies without `seq`, so the test
  -- counts the dispatches itself — after_each's stop_all keeps the pool to
  -- one fresh session per test.
  local dispatches = 0
  before_each(function()
    dispatches = 0
  end)
  local function execute_and_job(sql, callbacks)
    dispatches = dispatches + 1
    local status = session_conn.execute("postgres://h/app", sql, callbacks)
    assert.equals("dispatched", status)
    local found
    for _, s in pairs(session_conn.list()) do found = s end
    return found.job_id, dispatches
  end

  it("delivers 'unknown error' when the binary sends error:null", function()
    local got_msg, got_resp = nil, nil
    local job_id, seq = execute_and_job("SELECT 1", {
      on_sql_error = function(msg, resp) got_msg, got_resp = msg, resp end,
    })

    jobs[job_id].opts.on_stdout(nil, {
      vim.json.encode({
        type = "result", seq = seq, status = "error", error = vim.NIL,
        execution_time_ms = 1,
      }),
    })

    assert.equals("string", type(got_msg), "the userdata must never reach the callback")
    assert.equals("unknown error", got_msg)
    assert.is_true(got_resp.has_error)
  end)

  it("delivers real error text unchanged", function()
    local got_msg = nil
    local job_id, seq = execute_and_job("SELECT 1", {
      on_sql_error = function(msg) got_msg = msg end,
    })

    jobs[job_id].opts.on_stdout(nil, {
      vim.json.encode({
        type = "result", seq = seq, status = "error", error = "deadlock detected",
        execution_time_ms = 1,
      }),
    })

    assert.equals("deadlock detected", got_msg)
  end)

  it("fails pending requests synchronously when the process exits", function()
    -- on_exit must not sit behind vim.schedule: a dead session's pending
    -- requests have to fail inside the same event-loop turn (and the pool
    -- slot must clear) — a schedule added mid-vim.wait is not pumped in
    -- headless runs (the redis sibling's lesson).
    local got_err = nil
    local job_id = execute_and_job("SELECT 1", {
      on_error = function(msg) got_err = msg end,
    })

    jobs[job_id].opts.on_exit(nil, 1)

    assert.is_not_nil(got_err, "the pending request must fail")
    assert.matches("exited %(code 1%)", got_err)
    assert.equals(0, vim.tbl_count(session_conn.list()), "the dead session must leave the pool")
  end)
end)

describe("session_conn multi-statement sequence", function()
  -- The hoisted `SET @var` prelude travels as ONE request per statement: a
  -- multi-statement single request dies in MySQL's prepared-statement
  -- protocol with a 1064, and on a session binary before cbd5de3 the error
  -- killed the session process — the executor then silently re-ran the whole
  -- request on a one-shot exec-file connection where the SET died with the
  -- process, and the next statement failed with "column cannot be null" on
  -- the freshly started session.
  local state = require("poste-db.state")
  local session_conn = require("poste-db.session_conn")

  local jobs, sends
  local real_binary_lookup
  local real_jobstart, real_jobwait, real_chansend

  before_each(function()
    jobs, sends = {}, {}
    real_binary_lookup = state.find_poste_binary
    state.find_poste_binary = function() return "/fake/poste" end
    real_jobstart = vim.fn.jobstart
    vim.fn.jobstart = function(cmd, opts)
      local id = 2000 + vim.tbl_count(jobs)
      jobs[id] = { cmd = cmd, opts = opts }
      return id
    end
    real_jobwait = vim.fn.jobwait
    vim.fn.jobwait = function() return { -1 } end
    real_chansend = vim.fn.chansend
    vim.fn.chansend = function(_, payload)
      sends[#sends + 1] = vim.json.decode(payload)
      return #payload
    end
  end)

  after_each(function()
    session_conn.stop_all()
    state.find_poste_binary = real_binary_lookup
    vim.fn.jobstart = real_jobstart
    vim.fn.jobwait = real_jobwait
    vim.fn.chansend = real_chansend
  end)

  local function exec_sequence(statements, callbacks)
    local session = session_conn.get("postgres://h/app", nil, "db1")
    local status = session_conn.execute("postgres://h/app", table.concat(statements, "\n"),
      callbacks, nil, "db1", statements)
    assert.equals("dispatched", status)
    return session
  end

  it("sends one wire request per statement, each with its own seq", function()
    local session = exec_sequence({ "SET @a = 1;", "SELECT @a;" }, {})
    assert.equals(2, #sends, "one wire request per statement")
    assert.equals("SET @a = 1;", sends[1].sql)
    assert.equals("SELECT @a;", sends[2].sql)
    assert.are_not.equal(sends[1].seq, sends[2].seq)
    assert.equals(2, vim.tbl_count(session.pending), "every statement parks its own pending entry")
  end)

  it("answers once, after the last statement has reported", function()
    local responses = 0
    local got
    local session = exec_sequence({ "SET @a = 1;", "SELECT @a;" }, {
      on_response = function(resp)
        responses = responses + 1
        got = resp
      end,
    })
    jobs[session.job_id].opts.on_stdout(nil, {
      vim.json.encode({ type = "result", seq = sends[1].seq, status = "ok",
        affected_rows = 0, execution_time_ms = 2 }),
    })
    assert.equals(0, responses, "a prelude answer must not deliver the run")

    jobs[session.job_id].opts.on_stdout(nil, {
      vim.json.encode({ type = "result", seq = sends[2].seq, status = "ok",
        affected_rows = 1, execution_time_ms = 3 }),
    })
    assert.equals(1, responses)
    assert.equals(2, #got.results)
    assert.is_false(got.has_error)
    -- same body shape the exec-file transport reconstructs, so consumers
    -- (SET-prelude filter, dataset rendering) see one shape either way
    local body = vim.json.decode(got.body)
    assert.equals("affected", body.type)
    assert.equals(1, body.total_affected)
    assert.equals(5, body.total_execution_time_ms)
  end)

  it("delivers the first statement failure through on_sql_error exactly once", function()
    local sql_errs, responses = {}, 0
    local session = exec_sequence({ "SET @a = 1;", "INSERT INTO t VALUES (1);", "SELECT 1;" }, {
      on_response = function() responses = responses + 1 end,
      on_sql_error = function(msg, resp) sql_errs[#sql_errs + 1] = { msg = msg, resp = resp } end,
    })
    -- one event per stdout call: the wire emits one JSON line per statement
    local events = {
      { type = "result", seq = sends[1].seq, status = "ok",
        affected_rows = 0, execution_time_ms = 1 },
      { type = "result", seq = sends[2].seq, status = "error",
        error = "duplicate key value", execution_time_ms = 2 },
      -- a statement that reports after the failure is history
      { type = "result", seq = sends[3].seq, status = "ok",
        affected_rows = vim.NIL, row_count = 1, execution_time_ms = 1 },
    }
    for _, ev in ipairs(events) do
      jobs[session.job_id].opts.on_stdout(nil, { vim.json.encode(ev) })
    end
    assert.equals(1, #sql_errs, "the failure must reach the caller once")
    assert.matches("duplicate key", sql_errs[1].msg)
    assert.is_true(sql_errs[1].resp.has_error)
    assert.equals(0, responses, "a failed sequence must not answer with a response")
  end)

  it("fails a mid-sequence session death exactly once", function()
    local errs, responses = {}, 0
    local session = exec_sequence({ "SELECT 1;", "SELECT 2;", "SELECT 3;" }, {
      on_response = function() responses = responses + 1 end,
      on_error = function(msg) errs[#errs + 1] = msg end,
    })
    jobs[session.job_id].opts.on_exit(nil, 1)
    assert.equals(1, #errs, "every parked seq fires; the caller must hear it once")
    assert.matches("exited %(code 1%)", errs[1])
    assert.equals(0, responses)
    assert.equals(0, vim.tbl_count(session_conn.list()), "the dead session must leave the pool")
  end)

  it("a dead channel mid-sequence stops the sends and reports not_running", function()
    vim.fn.chansend = function(_, payload)
      sends[#sends + 1] = vim.json.decode(payload)
      if #sends == 2 then
        error("Can't send data to closed stream")
      end
      return #payload
    end
    local errs = {}
    local status = session_conn.execute("postgres://h/app", "SELECT 1;\nSELECT 2;\nSELECT 3;", {
      on_error = function(msg) errs[#errs + 1] = msg end,
    }, nil, "db1", { "SELECT 1;", "SELECT 2;", "SELECT 3;" })
    assert.equals("not_running", status)
    assert.equals(2, #sends, "the statement behind the failed send must not go out")
    assert.equals(1, #errs)
  end)
  it("classifies a sequence with a reading statement as a resultset", function()
    -- A prelude SET (affected count) plus a SELECT (rows, no affected count):
    -- the combined body must carry the resultset shape or the dataset panel
    -- renders the read as an affected-rows "Query OK".
    local got
    local session = exec_sequence({ "SET @a = 1;", "SELECT @a;" }, {
      on_response = function(resp) got = resp end,
    })
    local events = {
      { type = "result", seq = sends[1].seq, status = "ok",
        affected_rows = 0, execution_time_ms = 1 },
      { type = "result", seq = sends[2].seq, status = "ok",
        affected_rows = vim.NIL, row_count = 1, columns = { { name = "@a" } },
        rows = { { 1 } }, execution_time_ms = 1 },
    }
    for _, ev in ipairs(events) do
      jobs[session.job_id].opts.on_stdout(nil, { vim.json.encode(ev) })
    end
    assert.is_not_nil(got)
    local body = vim.json.decode(got.body)
    assert.equals("resultset", body.type)
    assert.equals(1, body.total_rows)
  end)
end)

describe("session_conn build_sequence_response", function()
  local session_conn = require("poste-db.session_conn")
  local build = session_conn._test.build_sequence_response
  local session = { conn_url = "mysql://h/app", database = "app", dialect = "mysql" }

  it("keeps a failed statement's rows out of the affected total", function()
    local resp = build(session, {
      { affected_rows = 1, row_count = 0, execution_time_ms = 2 },
      { affected_rows = 5, row_count = 0, execution_time_ms = 3, failed = true, error = "no such table" },
    })
    assert.equals(2, #resp.results, "both results ride along")
    assert.is_true(resp.has_error)
    local body = vim.json.decode(resp.body)
    assert.equals(1, body.total_affected, "a rejected statement affected nothing")
    assert.equals(5, body.total_execution_time_ms)
  end)
end)

describe("session_conn on_session_stdout line assembly", function()
  local session_conn = require("poste-db.session_conn")
  local feed = session_conn._test.on_session_stdout

  local function mk_session()
    return {
      conn_url = "postgres://h/app", database = "app", dialect = "postgres",
      pending = {}, buffer = "",
    }
  end

  it("a complete non-result JSON line without a trailing newline is discarded", function()
    -- regression: the newline-less tail was kept in `session.buffer` whenever
    -- it decoded as JSON but was not a result event, so every later response
    -- arrived glued to the stale text and never parsed again — the session
    -- went mute for its remaining life. A complete JSON value IS a complete
    -- message; one we don't understand is dropped, not retained.
    local s = mk_session()
    feed(s, { '{"type":"hello","note":"connected"}' })
    assert.equals("", s.buffer, "a decoded non-result tail must not be retained")

    local got
    s.pending[1] = { on_response = function(resp) got = resp end }
    feed(s, { vim.json.encode({ type = "result", seq = 1, status = "ok", affected_rows = 1 }) })
    assert.is_not_nil(got, "the next result must still parse after the junk line")
  end)

  it("an incomplete JSON tail is still kept until the rest arrives", function()
    local s = mk_session()
    feed(s, { '{"type":"result","seq":1,"stat' })
    assert.equals('{"type":"result","seq":1,"stat', s.buffer)
    local got
    s.pending[1] = { on_response = function(resp) got = resp end }
    feed(s, { 'us":"ok"}' })  -- tail completes {"type":"result",...
    assert.is_not_nil(got)
    assert.equals("", s.buffer)
  end)

  it("newline-delimited junk lines stay ignored and results still flow", function()
    local s = mk_session()
    local got
    s.pending[7] = { on_response = function(resp) got = resp end }
    -- chunks are byte fragments: the junk line carries its newline, the
    -- result arrives newline-less behind it
    feed(s, { "not json at all\n" .. vim.json.encode({ type = "result", seq = 7, status = "ok", affected_rows = 0 }) })
    assert.is_not_nil(got)
    assert.equals("", s.buffer)
  end)
end)

describe("session_conn cleanup_buf closes only emptied sessions", function()
  local state = require("poste-db.state")
  local session_conn = require("poste-db.session_conn")

  local real_binary_lookup
  local real_jobstart, real_jobwait, real_chansend

  before_each(function()
    real_binary_lookup = state.find_poste_binary
    state.find_poste_binary = function() return "/fake/poste" end
    real_jobstart = vim.fn.jobstart
    vim.fn.jobstart = function() return 2000 end
    real_jobwait = vim.fn.jobwait
    vim.fn.jobwait = function() return { -1 } end
    real_chansend = vim.fn.chansend
    vim.fn.chansend = function() return 10 end
  end)

  after_each(function()
    session_conn.stop_all()
    state.find_poste_binary = real_binary_lookup
    vim.fn.jobstart = real_jobstart
    vim.fn.jobwait = real_jobwait
    vim.fn.chansend = real_chansend
  end)

  it("a sibling session with live buffers survives one buffer's cleanup", function()
    -- cleanup_buf used to call M.stop(key), whose URL fan-out closed BOTH
    -- sessions of the connection: the sibling still had buffer 9 open, and
    -- its in-flight requests failed with "SQL session exited" while its
    -- SET/temp state died with the process.
    local a = session_conn.get("postgres://h/app", 5, "db1")
    local b = session_conn.get("postgres://h/app", 9, "db2")
    assert.are_not.equal(a, b)

    session_conn.cleanup_buf(5)

    assert.is_nil(session_conn.list()["postgres://h/app\0db1"], "emptied session closes")
    assert.is_not_nil(session_conn.list()["postgres://h/app\0db2"], "sibling with a live buffer stays")
  end)

  it("closing the last buffer of each session empties both", function()
    session_conn.get("postgres://h/app", 5, "db1")
    session_conn.get("postgres://h/app", 9, "db2")
    session_conn.cleanup_buf(5)
    session_conn.cleanup_buf(9)
    assert.are.equal(0, vim.tbl_count(session_conn.list()))
  end)
end)
