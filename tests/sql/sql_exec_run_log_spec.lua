--- Journaling seam on exec_run: every exec-file invocation lands in
--- sql_log.jsonl exactly once — success, in-band SQL error, or transport
--- failure — unless the caller opts out with opts.log = false.
local saved_cli = package.loaded["poste-db.cli"]
local saved_state = package.loaded["poste-db.state"]

local cli_callbacks = nil

package.loaded["poste-db.cli"] = {
  run_async = function(cmd, cbs)
    cli_callbacks = cbs
    return 1
  end,
}
package.loaded["poste-db.state"] = {
  current_env = "dev",
  log = function() end,
  find_poste_binary = function() return "/tmp/fake-poste" end,
}
-- poste-db.log stays real: the redaction assertions below exercise it.

local sql_log = require("poste-db.sql_log")
package.loaded["poste-db.exec_run"] = nil
local exec_run = require("poste-db.exec_run")

local path

--- Line count of the journal file, 0 while it does not exist yet.
local function entry_count()
  if vim.fn.filereadable(path) ~= 1 then return 0 end
  return #vim.fn.readfile(path)
end

--- Drain pending vim.schedule callbacks inside the live test, so late
--- callbacks neither error into plenary nor leak into the next test's file.
local function flush()
  vim.wait(100, function() return false end)
end

local function read_entries()
  local lines = vim.fn.readfile(path)
  local out = {}
  for _, l in ipairs(lines) do
    table.insert(out, vim.json.decode(l))
  end
  return out
end

describe("exec_run journaling", function()
  before_each(function()
    path = vim.fn.tempname() .. ".jsonl"
    sql_log.set_log_path(path)
    cli_callbacks = nil
  end)

  after_each(function()
    sql_log.set_log_path(nil)
    if path and vim.fn.filereadable(path) == 1 then vim.fn.delete(path) end
  end)

  it("journals a successful run on summary delivery", function()
    local delivered = nil
    exec_run.run_async("SELECT 1;", {
      conn_url = "mysql://root:pass@h/db",
      database = "blog",
    }, {
      on_response = function(resp) delivered = resp end,
    })

    assert.is_not_nil(cli_callbacks)
    cli_callbacks.on_stdout({ vim.json.encode({
      type = "summary", total_time_ms = 42, dialect = "mysql",
      connection = "mysql://root:pass@h/db", database = "blog",
    }) })

    vim.fn.wait(1000, function() return delivered ~= nil end)
    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("exec", entries[1].source)
    assert.equals("SELECT 1;", entries[1].sql)
    assert.equals("success", entries[1].status)
    assert.equals("mysql", entries[1].dialect)
    assert.equals(42, entries[1].elapsed_ms)
    assert.equals("mysql://root:***@h/db", entries[1].connection)
    assert.equals("blog", entries[1].database)
    flush()
  end)

  it("journals an in-band SQL error with the statement error text", function()
    local delivered = nil
    exec_run.run_async("SELECT * FROM missing;", {
      conn_url = "pg://u:pw@h/db",
    }, {
      on_response = function(resp) delivered = resp end,
    })
    cli_callbacks.on_stdout({
      vim.json.encode({ type = "result", seq = 1, status = "error",
        sql = "SELECT * FROM missing;", error = "no such table: missing" }),
      vim.json.encode({ type = "summary", total_time_ms = 3, dialect = "postgres" }),
    })
    vim.fn.wait(1000, function() return delivered ~= nil end)

    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("error", entries[1].status)
    assert.equals("no such table: missing", entries[1].error)
    flush()
  end)

  -- The failure flag and its text are separate fields: `exec_run` counts a
  -- result as failed from `status`, and a binary that sets status without
  -- filling in `error` used to journal a red line with no reason at all.
  it("journals a failure whose result event carries no error text", function()
    local delivered = nil
    exec_run.run_async("SELECT 1;", {
      conn_url = "pg://u:pw@h/db",
    }, {
      on_response = function(resp) delivered = resp end,
    })
    cli_callbacks.on_stdout({
      vim.json.encode({ type = "result", seq = 1, status = "error", sql = "SELECT 1;" }),
      vim.json.encode({ type = "summary", total_time_ms = 3, dialect = "postgres" }),
    })
    vim.fn.wait(1000, function() return delivered ~= nil end)

    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("error", entries[1].status)
    assert.truthy(entries[1].error)
    -- Same sentence as verdict.UNEXPLAINED_FAILURE (panel, AI action, journal
    -- — the journal used to carry a third, drifting wording of its own).
    assert.truthy(entries[1].error:find("without a message", 1, true))
    flush()
  end)

  it("journals a transport failure via on_error (non-zero exit, no summary)", function()
    exec_run.run_async("SELECT 1;", { conn_url = "pg://u:pw@h/db" }, {
      on_error = function() end,
    })
    cli_callbacks.on_stderr({ "connection refused" })
    cli_callbacks.on_exit(1)

    vim.fn.wait(1000, function() return entry_count() >= 1 end)
    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("error", entries[1].status)
    assert.equals("connection refused", entries[1].error)
    flush()
  end)

  it("journals a locally-handled USE statement as a success", function()
    local delivered = nil
    exec_run.run_async("USE app;", {}, {
      on_response = function(resp) delivered = resp end,
    })
    assert.is_not_nil(delivered)

    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("success", entries[1].status)
    assert.equals("USE app;", entries[1].sql)
  end)

  it("skips journaling entirely when opts.log is false", function()
    exec_run.run_async("SELECT 1;", {
      conn_url = "pg://u:pw@h/db",
      log = false,
    }, {
      on_response = function() end,
    })
    cli_callbacks.on_stdout({ vim.json.encode({
      type = "summary", total_time_ms = 1, dialect = "postgres",
    }) })
    cli_callbacks.on_exit(0)
    flush()

    assert.equals(0, entry_count())
  end)
  after_each(function()
    package.loaded["poste-db.cli"] = saved_cli
    package.loaded["poste-db.state"] = saved_state
  end)
end)

