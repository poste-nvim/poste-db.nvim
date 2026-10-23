--- Tests for executor.lua — session vs exec-file routing.
--- Verifies that session_conn.execute receives the correct SQL
--- (stmt_sql_raw, not buf_content with directives/### markers).

local saved_session_conn = package.loaded["poste-db.session_conn"]
local saved_exec_run = package.loaded["poste-db.exec_run"]
local saved_state = package.loaded["poste-db.state"]
local saved_log = package.loaded["poste-db.log"]
local saved_sql_log = package.loaded["poste-db.sql_log"]

local session_sql = nil
local session_callbacks = nil
local session_result = "dispatched"

local state_stub = {
  sql = { context = { connection = nil, database = nil } },
  current_env = "dev",
  config = { default_max_rows = 0 },
  find_poste_binary = function() return "/tmp/poste" end,
  log = function() end,
}

package.loaded["poste-db.state"] = state_stub
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
  execute = function(conn_url, sql, callbacks, bufnr, database)
    session_sql = sql
    session_callbacks = callbacks
    return session_result
  end,
}
package.loaded["poste-db.exec_run"] = {
  run_async = function() return 1 end,
}
-- Journaling disabled: seam_base(nil) keeps the executor from writing to the
-- real sql_log.jsonl while these routing tests fire its callbacks.
package.loaded["poste-db.sql_log"] = {
  seam_base = function() return nil end,
}

local function fresh_executor()
  package.loaded["poste-db.executor"] = nil
  return require("poste-db.executor")
end

describe("executor session routing", function()
  before_each(function()
    session_sql = nil
    session_callbacks = nil
    session_result = "dispatched"
    package.loaded["poste-db.executor"] = nil
  end)

  it("passes raw SQL to session_conn.execute (not buffer content with directives)", function()
    local executor = fresh_executor()
    local raw_sql = "SELECT * FROM users WHERE id = 1;"
    executor.execute({
      sql = raw_sql,
      conn_url = "mysql://root:pass@localhost:3306/blog",
      database = "blog",
      prefer_session = true,
    })
    assert.equals(raw_sql, session_sql)
  end)

  it("passes SQL with ### markers to session_conn as-is when using prefer_session", function()
    local executor = fresh_executor()
    local raw_sql = "SELECT * FROM users;"
    executor.execute({
      sql = raw_sql,
      conn_url = "mysql://root:pass@localhost:3306/blog",
      database = "blog",
      prefer_session = true,
    })
    assert.is_not_nil(session_sql)
    assert.equals(raw_sql, session_sql)
    assert.is_nil(session_sql:find("###", 1, true))
    assert.is_nil(session_sql:find("-- @connection", 1, true))
  end)

  it("calls session_conn.execute with correct database", function()
    local executor = fresh_executor()
    local call_count = 0
    local captured_db = nil
    local orig = package.loaded["poste-db.session_conn"].execute
    package.loaded["poste-db.session_conn"].execute = function(conn_url, sql, callbacks, bufnr, database)
      captured_db = database
      call_count = call_count + 1
      return "dispatched"
    end
    executor.execute({
      sql = "SELECT 1;",
      conn_url = "mysql://root:pass@localhost:3306/blog",
      database = "inventory",
      prefer_session = true,
    })
    assert.equals(1, call_count)
    assert.equals("inventory", captured_db)
    package.loaded["poste-db.session_conn"].execute = orig
  end)

  it("provides on_sql_error callback that forwards to on_error", function()
    local executor = fresh_executor()
    local sql_error_msg = nil
    executor.execute({
      sql = "SELECT 1;",
      conn_url = "mysql://root:pass@localhost:3306/blog",
      prefer_session = true,
      on_error = function(msg) sql_error_msg = msg end,
    })
    assert.is_not_nil(session_callbacks)
    assert.is_not_nil(session_callbacks.on_sql_error)
    session_callbacks.on_sql_error("Table not found")
    assert.equals("Table not found", sql_error_msg)
  end)

  it("falls back to exec-file when session_conn returns start_failed", function()
    local executor = fresh_executor()
    session_result = "start_failed"
    local exec_file_called = false
    package.loaded["poste-db.exec_run"].run_async = function() exec_file_called = true; return 1 end
    executor.execute({
      sql = "SELECT 1;",
      conn_url = "mysql://root:pass@localhost:3306/blog",
      prefer_session = true,
    })
    assert.is_true(exec_file_called)
  end)

  it("falls back to exec-file once and prevents double fallback", function()
    local executor = fresh_executor()
    session_result = "start_failed"
    local exec_file_count = 0
    package.loaded["poste-db.exec_run"].run_async = function() exec_file_count = exec_file_count + 1; return 1 end
    executor.execute({
      sql = "SELECT 1;",
      conn_url = "mysql://root:pass@localhost:3306/blog",
      prefer_session = true,
    })
    assert.equals(1, exec_file_count)
  end)

  it("calls exec_run directly when prefer_session is false", function()
    local executor = fresh_executor()
    local exec_run_called = false
    local exec_run_sql = nil
    package.loaded["poste-db.exec_run"].run_async = function(sql, opts, callbacks)
      exec_run_called = true
      exec_run_sql = sql
      return 1
    end
    executor.execute({
      sql = "SELECT 1;",
      conn_url = nil,
      prefer_session = false,
    })
    assert.is_true(exec_run_called)
    assert.equals("SELECT 1;", exec_run_sql)
  end)

  it("calls exec_run directly when no conn_url even with prefer_session=true", function()
    local executor = fresh_executor()
    local exec_run_called = false
    package.loaded["poste-db.exec_run"].run_async = function() exec_run_called = true; return 1 end
    executor.execute({
      sql = "SELECT 1;",
      conn_url = nil,
      prefer_session = true,
    })
    assert.is_true(exec_run_called)
  end)

  describe("empty-sql guard", function()
    -- The session transport answers nothing for a blank request (the binary's
    -- parse_request classifies empty/whitespace sql as Blank and skips it —
    -- no wire event), so the request used to sit in session.pending forever
    -- while the caller waited. Both transports now get the same immediate
    -- on_error instead.
    local function run_empty(sql)
      local executor = fresh_executor()
      local session_called, exec_called, errors = false, false, {}
      package.loaded["poste-db.session_conn"].execute = function()
        session_called = true
        return "dispatched"
      end
      package.loaded["poste-db.exec_run"].run_async = function()
        exec_called = true
        return 1
      end
      executor.execute({
        sql = sql,
        conn_url = "sqlite::memory:",
        prefer_session = true,
        on_error = function(msg) errors[#errors + 1] = msg end,
      })
      return session_called, exec_called, errors
    end

    it("refuses an empty string without dispatching anywhere", function()
      local session_called, exec_called, errors = run_empty("")
      assert.is_false(session_called)
      assert.is_false(exec_called)
      assert.equals(1, #errors)
      assert.equals("Empty SQL statement", errors[1])
    end)

    it("refuses a whitespace-only statement the same way", function()
      -- The binary trims before its Blank check, so "  \n\t " is blank there
      -- too; the guard must not let one through to the session.
      local session_called, exec_called, errors = run_empty("  \n\t ")
      assert.is_false(session_called)
      assert.is_false(exec_called)
      assert.equals(1, #errors)
    end)

    it("refuses a nil statement", function()
      local session_called, exec_called, errors = run_empty(nil)
      assert.is_false(session_called)
      assert.is_false(exec_called)
      assert.equals(1, #errors)
    end)
  end)

  after_each(function()
    package.loaded["poste-db.session_conn"] = saved_session_conn
    package.loaded["poste-db.exec_run"] = saved_exec_run
    package.loaded["poste-db.state"] = saved_state
    package.loaded["poste-db.log"] = saved_log
    package.loaded["poste-db.sql_log"] = saved_sql_log
  end)
end)