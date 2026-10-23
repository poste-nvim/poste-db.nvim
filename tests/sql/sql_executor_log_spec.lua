--- Executor journaling: one entry per request across session and exec-file
--- transports — the internal session→exec-file fallback must not double-log.
local saved_session_conn = package.loaded["poste-db.session_conn"]
local saved_exec_run = package.loaded["poste-db.exec_run"]
local saved_state = package.loaded["poste-db.state"]
local saved_log = package.loaded["poste-db.log"]

local session_callbacks = nil
local session_result = "dispatched"
local exec_run_opts = nil
local exec_run_callbacks = nil

package.loaded["poste-db.state"] = {
  sql = { context = {} },
  current_env = "dev",
  log = function() end,
  find_poste_binary = function() return "/tmp/fake-poste" end,
}
package.loaded["poste-db.log"] = {
  info = function() end,
  warn = function() end,
  error = function() end,
  debug = function() end,
  info_fmt = function() end,
  redact_cmd = function(s) return s end,
  redact_url = function(s) return s end,
}
package.loaded["poste-db.session_conn"] = {
  execute = function(_, _, callbacks, _, _)
    session_callbacks = callbacks
    return session_result
  end,
}
package.loaded["poste-db.exec_run"] = {
  run_async = function(_, opts, callbacks)
    exec_run_opts = opts
    exec_run_callbacks = callbacks
    return 1
  end,
}

local sql_log = require("poste-db.sql_log")
package.loaded["poste-db.executor"] = nil
local executor = require("poste-db.executor")

local path

--- Line count of the journal file, 0 while it does not exist yet.
local function entry_count()
  if vim.fn.filereadable(path) ~= 1 then return 0 end
  return #vim.fn.readfile(path)
end

local function read_entries()
  local out = {}
  for _, l in ipairs(vim.fn.readfile(path)) do
    table.insert(out, vim.json.decode(l))
  end
  return out
end

describe("executor journaling", function()
  before_each(function()
    path = vim.fn.tempname() .. ".jsonl"
    sql_log.set_log_path(path)
    session_callbacks = nil
    session_result = "dispatched"
    exec_run_opts = nil
    exec_run_callbacks = nil
  end)

  after_each(function()
    sql_log.set_log_path(nil)
    if path and vim.fn.filereadable(path) == 1 then vim.fn.delete(path) end
  end)

  it("journals a session-path success with the caller's tags", function()
    local got = nil
    executor.execute({
      sql = "SELECT 1;",
      conn_url = "mysql://root:pass@h/db",
      database = "blog",
      prefer_session = true,
      log_source = "manual_exec",
      log_extra = { connection = "pg-dev" },
      on_response = function(parsed) got = parsed end,
    })
    session_callbacks.on_response({ latency_ms = 10, dialect = "mysql", results = {} })

    assert.is_not_nil(got)
    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("manual_exec", entries[1].source)
    assert.equals("pg-dev", entries[1].connection)
    assert.equals("blog", entries[1].database)
    assert.equals("success", entries[1].status)
    assert.equals("mysql", entries[1].dialect)
    assert.equals(10, entries[1].elapsed_ms)
  end)

  it("journals an in-band SQL error delivered via on_sql_error", function()
    local got_err = nil
    executor.execute({
      sql = "SELECT 1;",
      conn_url = "mysql://root:pass@h/db",
      prefer_session = true,
      on_error = function(msg) got_err = msg end,
    })
    session_callbacks.on_sql_error("Table not found", { dialect = "mysql" })

    assert.equals("Table not found", got_err)
    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("error", entries[1].status)
    assert.equals("Table not found", entries[1].error)
  end)

  it("journals an exec-file transport failure exactly once", function()
    executor.execute({
      sql = "SELECT 1;",
      prefer_session = false,
      on_error = function() end,
    })
    assert.is_false(exec_run_opts.log)
    exec_run_callbacks.on_error("connection refused", "")

    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("error", entries[1].status)
    assert.equals("connection refused", entries[1].error)
  end)

  it("does not double-journal a session failure followed by a successful fallback", function()
    session_result = "start_failed"
    executor.execute({
      sql = "SELECT 1;",
      conn_url = "mysql://root:pass@h/db",
      prefer_session = true,
    })
    exec_run_callbacks.on_response({ latency_ms = 5, dialect = "mysql", results = {} })

    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("success", entries[1].status)
  end)

  it("skips journaling entirely when log=false", function()
    executor.execute({
      sql = "SELECT 1;",
      prefer_session = false,
      log = false,
      on_response = function() end,
      on_error = function() end,
    })
    exec_run_callbacks.on_response({ latency_ms = 5, results = {} })
    exec_run_callbacks.on_error("boom", "")

    assert.equals(0, entry_count())
  end)
  after_each(function()
    package.loaded["poste-db.session_conn"] = saved_session_conn
    package.loaded["poste-db.exec_run"] = saved_exec_run
    package.loaded["poste-db.state"] = saved_state
    package.loaded["poste-db.log"] = saved_log
  end)
end)

