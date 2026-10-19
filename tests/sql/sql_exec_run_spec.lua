local exec_run = require("poste-db.exec_run")

describe("exec_run", function()
  describe("build_response", function()
    it("classifies a SELECT as resultset and keeps rows", function()
      local resp = exec_run.build_response({
        { type = "result", seq = 1, status = "ok", sql = "SELECT * FROM t",
          row_count = 2, affected_rows = vim.NIL, execution_time_ms = 3,
          columns = { { name = "x", type = "INTEGER" } }, rows = { { 1 }, { 2 } } },
        { type = "summary", total_time_ms = 31, dialect = "sqlite",
          connection = "sqlite::memory:", database = nil },
      }, "sqlite::memory:", "")

      assert.equals("ok", resp.status)
      assert.equals(31, resp.latency_ms)
      local body = vim.json.decode(resp.body)
      assert.equals("resultset", body.type)
      assert.equals(2, body.total_rows)
      assert.equals(1, #body.results)
      assert.equals(2, body.results[1].row_count)
      assert.is_nil(body.results[1].affected_rows)
      assert.same({ 2 }, body.results[1].rows[2])
      assert.equals("sqlite::memory:", resp.connection)
      assert.equals("sqlite", resp.dialect)
    end)

    it("classifies INSERTs as affected and sums affected rows", function()
      local resp = exec_run.build_response({
        { type = "result", seq = 1, status = "ok", sql = "INSERT ...",
          row_count = 0, affected_rows = 1, execution_time_ms = 1 },
        { type = "result", seq = 2, status = "ok", sql = "INSERT ...",
          row_count = 0, affected_rows = 3, execution_time_ms = 1 },
        { type = "summary", total_time_ms = 5, dialect = "postgres",
          connection = "pg://x", database = "app" },
      }, "pg://x", "app")

      local body = vim.json.decode(resp.body)
      assert.equals("affected", body.type)
      assert.equals(4, body.total_affected)
      assert.is_false(resp.has_error)
      assert.equals("ok", resp.status)
    end)

    it("sets has_error when a statement fails", function()
      local resp = exec_run.build_response({
        { type = "result", seq = 1, status = "error", sql = "SELECT * FROM missing",
          error = "no such table: missing", execution_time_ms = 0 },
        { type = "summary", total_time_ms = 9, dialect = "sqlite",
          connection = "sqlite::memory:", database = nil },
      }, "sqlite::memory:", "")

      assert.equals("error", resp.status)
      assert.is_true(resp.has_error)
      local body = vim.json.decode(resp.body)
      assert.is_true(body.has_error)
      assert.equals("no such table: missing", body.results[1].error)
    end)

    it("classifies a SELECT as resultset even if affected_rows is reported as 0", function()
      -- Regression: some drivers/binary versions report affected_rows=0 for a
      -- SELECT; must not be misclassified as an affected/Query OK response.
      local resp = exec_run.build_response({
        { type = "result", seq = 1, status = "ok", sql = "SELECT * FROM t",
          row_count = 5, affected_rows = 0, execution_time_ms = 2,
          columns = { { name = "x", type = "INTEGER" } },
          rows = { { 1 }, { 2 }, { 3 }, { 4 }, { 5 } } },
        { type = "summary", total_time_ms = 7, dialect = "postgres",
          connection = "pg://x", database = "app" },
      }, "pg://x", "app")

      local body = vim.json.decode(resp.body)
      assert.equals("resultset", body.type)
      assert.equals(5, body.total_rows)
    end)

    it("classifies a SELECT as resultset from SQL text even when the result is DML-shaped", function()
      -- MySQL: a binary/driver may emit a SELECT as a DML-shaped result event
      -- (affected_rows as a number, no columns/rows). The SQL keyword must win.
      local resp = exec_run.build_response({
        { type = "result", seq = 1, status = "ok", sql = "select * from merchant ;",
          row_count = 0, affected_rows = 0, execution_time_ms = 4, columns = {}, rows = {} },
        { type = "summary", total_time_ms = 9, dialect = "mysql",
          connection = "mysql://dba:xxx@host:3306/cpm_order_dev", database = "cpm_order_dev" },
      }, "mysql://dba:xxx@host:3306/cpm_order_dev", "cpm_order_dev")

      local body = vim.json.decode(resp.body)
      assert.equals("resultset", body.type)
      assert.is_false(resp.has_error)
    end)

    it("keeps a real DML as affected even with SQL text present", function()
      local resp = exec_run.build_response({
        { type = "result", seq = 1, status = "ok", sql = "update merchant set name = 'x' where id = 1",
          row_count = 0, affected_rows = 1, execution_time_ms = 2, columns = {}, rows = {} },
        { type = "summary", total_time_ms = 5, dialect = "mysql",
          connection = "mysql://dba:xxx@host:3306/cpm_order_dev", database = "cpm_order_dev" },
      }, "mysql://dba:xxx@host:3306/cpm_order_dev", "cpm_order_dev")

      local body = vim.json.decode(resp.body)
      assert.equals("affected", body.type)
      assert.equals(1, body.total_affected)
    end)

    it("propagates rolled_back from the transaction-mode summary", function()
      local resp = exec_run.build_response({
        { type = "result", seq = 1, status = "error", sql = "UPDATE t SET x=1",
          row_count = 0, affected_rows = vim.NIL, execution_time_ms = 1,
          error = "constraint failed" },
        { type = "summary", total_time_ms = 4, dialect = "postgres",
          connection = "pg://x", database = "app", rolled_back = true },
      }, "pg://x", "app")

      assert.equals("error", resp.status)
      assert.is_true(vim.json.decode(resp.body).rolled_back)
    end)

    it("omits rolled_back when the summary does not carry it", function()
      local resp = exec_run.build_response({
        { type = "result", seq = 1, status = "ok", sql = "UPDATE t SET x=1",
          row_count = 0, affected_rows = 1, execution_time_ms = 1 },
        { type = "summary", total_time_ms = 4, dialect = "postgres",
          connection = "pg://x", database = "app" },
      }, "pg://x", "app")

      assert.equals("ok", resp.status)
      assert.is_nil(vim.json.decode(resp.body).rolled_back)
    end)

    it("keeps the verdict on the result when the event carries no message", function()
      -- The producer pairs `status = "error"` with text today, but the two are
      -- separate fields. Without a per-result marker the only thing a consumer
      -- can read is "no message", which is also what a success looks like — and
      -- `type = "affected"` is then rendered as "Query OK".
      local resp = exec_run.build_response({
        { type = "result", seq = 1, status = "error", sql = "DELETE FROM t",
          row_count = 0, affected_rows = 0, execution_time_ms = 1 },
        { type = "summary", total_time_ms = 1, dialect = "mysql",
          connection = "mysql://x", database = "app" },
      }, "mysql://x", "app")

      assert.is_true(resp.has_error)
      local body = vim.json.decode(resp.body)
      assert.equals("affected", body.type)
      assert.is_true(body.results[1].failed)
      assert.is_nil(body.results[1].error)
    end)

    it("does not read a rejected result as a query when it carries columns", function()
      local resp = exec_run.build_response({
        { type = "result", seq = 1, status = "error", sql = "SELECT * FROM missing",
          row_count = 0, affected_rows = vim.NIL, execution_time_ms = 1,
          columns = { { name = "x", type = "INTEGER" } }, rows = {} },
        { type = "summary", total_time_ms = 1, dialect = "postgres",
          connection = "pg://x", database = "app" },
      }, "pg://x", "app")

      -- "affected" is the honest shape here: as a resultset it would render as an
      -- empty table, and the rejection would be invisible.
      assert.equals("affected", vim.json.decode(resp.body).type)
      assert.is_true(resp.results[1].failed)
    end)

    it("drops a null error field instead of storing vim.NIL", function()
      local resp = exec_run.build_response({
        { type = "result", seq = 1, status = "error", sql = "SELECT 1",
          error = vim.NIL, affected_rows = vim.NIL, execution_time_ms = 1 },
        { type = "summary", total_time_ms = 1, dialect = "sqlite",
          connection = "sqlite::memory:", database = nil },
      }, "sqlite::memory:", "")

      -- Callers concatenate the message; `vim.NIL` is truthy userdata, so it had
      -- to stay out of the field rather than reach a `..`.
      assert.is_nil(resp.results[1].error)
      assert.is_true(resp.results[1].failed)
      assert.is_true(resp.has_error)
    end)
  end)

  describe("detect_use", function()
    it("detects a lone USE statement", function()
      assert.equals("inventory", exec_run.detect_use("USE inventory;"))
      assert.equals("inventory", exec_run.detect_use("  USE inventory  "))
    end)

    it("detects an MSSQL bracket-quoted name", function()
      -- `USE [My DB];` is valid T-SQL: left to the server it EXECUTES while
      -- the plugin's context kept pointing at the old database — every later
      -- query ran against a db the user believes they left
      assert.equals("My DB", exec_run.detect_use("USE [My DB];"))
      assert.equals("master", exec_run.detect_use("USE [master]"))
      assert.equals("My DB", exec_run.detect_use("USE [My DB] -- switch"))
    end)

    it("unwinds a doubled ] inside a bracket-quoted name", function()
      assert.equals("a]b", exec_run.detect_use("USE [a]]b];"))
    end)

    it("detects USE with a trailing comment and captures only the db name", function()
      -- Regression: the comment-tail pattern had no capture group, so match()
      -- returned the whole statement and it leaked into database_name.
      assert.equals("mydb", exec_run.detect_use("USE mydb -- switch context"))
      assert.equals("mydb", exec_run.detect_use("USE mydb; -- switch context"))
    end)

    it("does not let a comment tail reach past its own line", function()
      -- Regression: the tail was `%-%-.*$`, and Lua's `.` crosses newlines, so
      -- a whole batch after `USE db` looked like one comment. The batch was
      -- then dropped on the floor while the context switched to `db`.
      assert.is_nil(exec_run.detect_use("USE mydb\n-- note\nSELECT 1"))
      assert.is_nil(exec_run.detect_use("USE mydb -- note\nDELETE FROM t"))
      assert.is_nil(exec_run.detect_use("USE mydb\n\nSELECT 1"))
    end)

    it("detects lowercase use statements (case-insensitive SQL keywords)", function()
      -- A lowercase `use db;` used to fall through: detect_use missed it, the
      -- statement reached the database as real SQL (syntax error on postgres)
      -- while the uppercase form switched the context.
      assert.equals("inventory", exec_run.detect_use("use inventory;"))
      assert.equals("inventory", exec_run.detect_use("Use inventory"))
      assert.equals("mydb", exec_run.detect_use("use mydb -- switch context"))
    end)

    it("detects hyphenated db names (plain and quoted)", function()
      -- `USE my-db;` used to miss the identifier class and reach the session
      -- as real SQL — a syntax error — instead of switching the context.
      assert.equals("my-db", exec_run.detect_use("USE my-db;"))
      assert.equals("my-db", exec_run.detect_use("use my-db"))
      assert.equals("my-db", exec_run.detect_use("USE `my-db`;"))
      assert.equals("my-db", exec_run.detect_use('USE "my-db";'))
      assert.equals("my-db", exec_run.detect_use("USE my-db; -- switch context"))
    end)

    it("ignores non-USE SQL", function()
      assert.is_nil(exec_run.detect_use("SELECT * FROM t"))
      assert.is_nil(exec_run.detect_use("USE inventory\nSELECT 1"))
    end)
  end)

  describe("is_query_sql", function()
    it("classifies DML with RETURNING (any case) as a query", function()
      -- pg/sqlite `update … returning x` returns rows; the classification
      -- used to depend on the keyword being uppercase.
      assert.is_true(exec_run.is_query_sql("update t set x = 1 returning x"))
      assert.is_true(exec_run.is_query_sql("UPDATE t SET x = 1 RETURNING x"))
      assert.is_true(exec_run.is_query_sql("with del as (delete from t returning *) select * from del"))
    end)

    it("does not let identifiers or literals flip the classification", function()
      -- word boundaries keep `my_returning_col` from matching, and literals
      -- are stripped before the keyword scan
      assert.is_false(exec_run.is_query_sql("update t set note = 'RETURNING user'"))
      assert.is_false(exec_run.is_query_sql("update t set my_returning_col = 1"))
      assert.is_false(exec_run.is_query_sql("update t set x = 1 -- RETURNING later"))
      -- the old gsub chain stopped a literal blank at the '' escape's second
      -- quote and leaked the tail — the UPDATE flipped to a query
      assert.is_false(exec_run.is_query_sql("update t set note = 'it''s RETURNING x'"))
      assert.is_false(exec_run.is_query_sql("update t set note = 'a--b RETURNING x'"))
      -- a dollar-quoted body is not the statement's code either
      assert.is_false(exec_run.is_query_sql("update t set body = $$ RETURNING x $$ where id = 1"))
    end)

    it("keeps plain DML as affected", function()
      assert.is_false(exec_run.is_query_sql("insert into t values (1)"))
      assert.is_false(exec_run.is_query_sql("  update t set x = 1"))
    end)
  end)

  describe("for_each_event", function()
    it("decodes jobstart line-split data (newlines stripped, trailing empty)", function()
      local events = {}
      -- jobstart with buffered stdout delivers each event as its own array
      -- element, with no embedded newlines, plus a trailing "".
      local data = {
        '{"type":"progress","seq":1,"total":1,"sql":"SELECT 1"}',
        '{"type":"result","seq":1,"total":1,"status":"ok","sql":"SELECT 1","row_count":1,"affected_rows":null}',
        '{"type":"summary","total":1,"succeeded":1,"failed":0,"total_rows":1,"total_affected":0,"connection":"sqlite::memory:","dialect":"sqlite","mode":"greedy","rolled_back":false}',
        "",
      }
      exec_run.for_each_event(data, function(ev) events[#events + 1] = ev end)
      assert.equals(3, #events)
      assert.equals("result", events[2].type)
      assert.equals(1, events[2].row_count)
      assert.equals("summary", events[3].type)
    end)

    it("ignores non-JSON and empty elements", function()
      local events = {}
      exec_run.for_each_event({ "", "not json", '{"type":"result"}', "" }, function(ev)
        events[#events + 1] = ev
      end)
      assert.equals(1, #events)
      assert.equals("result", events[1].type)
    end)

    it("decodes a single raw blob split by newlines (no trailing empty)", function()
      local events = {}
      local blob = '{"type":"progress"}\n{"type":"summary","total":1,"succeeded":1,"failed":0,"total_rows":1,"total_affected":0,"dialect":"sqlite","mode":"greedy","rolled_back":false}'
      local lines = vim.split(blob, "\n")
      exec_run.for_each_event(lines, function(ev) events[#events + 1] = ev end)
      assert.equals(2, #events)
    end)
  end)

  describe("strip_section_markers", function()
    it("removes ### section markers so exec-file sees clean SQL", function()
      local out = exec_run.strip_section_markers(
        "-- @connection malldev\n###\nselect * from merchant\n###\n"
      )
      assert.equals("-- @connection malldev\nselect * from merchant\n", out)
    end)

    it("keeps non-marker lines (including # in strings) intact", function()
      local out = exec_run.strip_section_markers("select * from t where note = 'a#b';\n")
      assert.equals("select * from t where note = 'a#b';\n", out)
    end)
  end)

  describe("write_temp_file", function()
    local made = {}
    after_each(function()
      for _, p in ipairs(made) do vim.fn.delete(p) end
      made = {}
    end)

    it("creates the statement file 0600, not world-readable", function()
      -- Statement text can carry row data; writefile()'s umask default is 0644.
      local tmp = exec_run.write_temp_file("INSERT INTO t VALUES ('row data');\n")
      made[#made + 1] = tmp
      local uv = vim.uv or vim.loop
      local stat = uv.fs_stat(tmp)
      assert.truthy(stat)
      assert.equals(tonumber("600", 8), stat.mode % 512)
    end)

    it("writes the SQL with the section markers stripped", function()
      local tmp = exec_run.write_temp_file("###\nselect 1;\n")
      made[#made + 1] = tmp
      local lines = vim.fn.readfile(tmp)
      assert.equals("select 1;", lines[1])
      for _, l in ipairs(lines) do
        assert.is_nil(l:match("^%s*###%s*$"))
      end
    end)
  end)

  describe("run_sql temp-file lifecycle", function()
    local saved_binary, made

    before_each(function()
      saved_binary = vim.g.poste_binary
      local dir = vim.fn.tempname() .. ".d"
      vim.fn.mkdir(dir, "p")
      local fake = dir .. "/poste"
      vim.fn.writefile({ "#!/bin/sh" }, fake)
      vim.fn.setfperm(fake, "rwxr-xr-x")
      vim.g.poste_binary = fake
      made = { dir }
    end)

    after_each(function()
      if saved_binary == nil then
        vim.cmd("unlet! g:poste_binary")
      else
        vim.g.poste_binary = saved_binary
      end
      for _, p in ipairs(made) do vim.fn.delete(p, "rf") end
    end)

    it("the temp file is still present when the child reads it", function()
      -- Regression: the temp file used to be deleted right after vim.system
      -- spawned the child and before wait() returned. The file is exec-file's
      -- only input, so unlinking it in that window raced the child's first
      -- open() and could fail the run with "file not found".
      local observed = {}
      local orig_system = vim.system
      vim.system = function(cmd, _opts)
        local tmpfile = vim.iter(cmd):find(function(a) return a:match("%.sql$") end)
        observed.at_spawn = vim.fn.filereadable(tmpfile) == 1
        return {
          wait = function()
            observed.at_wait = vim.fn.filereadable(tmpfile) == 1
            return {
              code = 0,
              stdout = vim.json.encode({ type = "summary", total_time_ms = 1 }),
              stderr = "",
            }
          end,
        }
      end
      local ok, resp = pcall(exec_run.run_sql, "SELECT 1;", { log = false })
      vim.system = orig_system
      assert.is_true(ok)
      assert.truthy(resp)
      assert.is_true(observed.at_spawn)
      assert.is_true(observed.at_wait, "temp file must outlive the child")
    end)

    it("removes the temp file after a failed spawn", function()
      -- vim.system raising means nothing was spawned; the file must not leak.
      local leaked = nil
      local orig_system = vim.system
      vim.system = function(cmd, _opts)
        leaked = vim.iter(cmd):find(function(a) return a:match("%.sql$") end)
        error("spawn failed")
      end
      local ok, resp = pcall(exec_run.run_sql, "SELECT 1;", { log = false })
      vim.system = orig_system
      assert.is_true(ok)
      assert.is_nil(resp)
      assert.truthy(leaked)
      assert.equals(0, vim.fn.filereadable(leaked), "temp file must be cleaned up")
    end)
  end)

  describe("run_sql timeout message", function()
    -- vim.system kills the child with code 124 (the GNU-timeout convention)
    -- when its own ceiling fires. The message used to read "exec-file exit
    -- code 124", which sounds like the statement failed server-side when it
    -- may still be running there; the journal must name the local kill.
    -- run_sql captures sql_log at load time, so the stub is installed before
    -- the module loads (same shape as the failed-start describe below).
    local saved_sql_log, saved_exec_run, saved_binary, saved_system
    local fails, dir_made

    before_each(function()
      saved_sql_log = package.loaded["poste-db.sql_log"]
      saved_exec_run = package.loaded["poste-db.exec_run"]
      saved_binary = vim.g.poste_binary
      saved_system = vim.system
      fails = {}
      -- find_poste_binary runnability-tests the override, so the fake must
      -- exist and be executable (same shape as the lifecycle describe).
      local dir = vim.fn.tempname() .. ".d"
      vim.fn.mkdir(dir, "p")
      local fake = dir .. "/poste"
      vim.fn.writefile({ "#!/bin/sh" }, fake)
      vim.fn.setfperm(fake, "rwxr-xr-x")
      vim.g.poste_binary = fake
      dir_made = dir
      package.loaded["poste-db.sql_log"] = {
        seam_base = function() return { source = "spec" } end,
        fail = function(_base, msg) fails[#fails + 1] = msg end,
        result = function() end,
      }
      package.loaded["poste-db.exec_run"] = nil
    end)

    after_each(function()
      package.loaded["poste-db.sql_log"] = saved_sql_log
      package.loaded["poste-db.exec_run"] = saved_exec_run
      if saved_binary == nil then
        vim.cmd("unlet! g:poste_binary")
      else
        vim.g.poste_binary = saved_binary
      end
      vim.system = saved_system
      if dir_made then vim.fn.delete(dir_made, "rf") end
    end)

    it("names the local kill, not a bare 'exit code 124'", function()
      vim.system = function(_cmd, _opts)
        return { wait = function() return { code = 124, stdout = "", stderr = "" } end }
      end
      local er = require("poste-db.exec_run")
      assert.is_nil(er.run_sql("SELECT 1;", { log_source = "spec" }))
      assert.equals(1, #fails)
      assert.truthy(fails[1]:find("did not finish within 30s", 1, true))
      assert.truthy(fails[1]:find("may still be running server", 1, true))
    end)

    it("keeps stderr first when the child said something", function()
      vim.system = function(_cmd, _opts)
        return { wait = function() return { code = 1, stdout = "", stderr = "boom" } end }
      end
      local er = require("poste-db.exec_run")
      assert.is_nil(er.run_sql("SELECT 1;", { log_source = "spec" }))
      assert.same({ "boom" }, fails)
    end)
  end)

  describe("run_async failed-start delivery", function()
    -- A run that never started must report through on_error exactly once and
    -- return 1 ("handled inline"). The old shape delivered the binary-missing
    -- failure from run_async AND left a nil return that every caller turned
    -- into a second failure report — and a jobstart -1 (binary present, spawn
    -- refused) fired no callback at all, so callers without the id check
    -- (import/execute) waited forever.
    local saved_cli = package.loaded["poste-db.cli"]
    local saved_state = package.loaded["poste-db.state"]

    after_each(function()
      package.loaded["poste-db.cli"] = saved_cli
      package.loaded["poste-db.state"] = saved_state
      -- The next require re-resolves exec_run against the real modules.
      package.loaded["poste-db.exec_run"] = nil
    end)

    --- Load a fresh exec_run wired to stubbed state/cli.
    --- binary: string|nil  what find_poste_binary reports
    --- cli_run: function(cmd, cbs) -> job_id  stands in for cli.run_async
    local function load_exec_run(binary, cli_run)
      package.loaded["poste-db.state"] = { find_poste_binary = function() return binary end }
      package.loaded["poste-db.cli"] = { run_async = function(cmd, cbs) return cli_run(cmd, cbs) end }
      package.loaded["poste-db.exec_run"] = nil
      return require("poste-db.exec_run")
    end

    it("names the no-summary exit instead of a bare 'exit code 0'", function()
      -- A run whose every event failed to decode ends with exit 0 and no
      -- summary — an error message that reads "exit code 0" reports a success
      -- code as the failure. Say why the run counts as failed instead.
      local er = load_exec_run("/fake/poste", function(_cmd, cbs)
        cbs.on_stdout(nil, {})
        cbs.on_exit(0)
        return 7
      end)
      local errors = {}
      er.run_async("SELECT 1;", { log = false }, {
        on_error = function(msg) errors[#errors + 1] = msg end,
      })
      vim.wait(100, function() return #errors > 0 end)

      assert.equals(1, #errors)
      assert.truthy(errors[1]:find("no summary event", 1, true))
      assert.truthy(errors[1]:find("exit code 0", 1, true))
    end)

    it("delivers on_error exactly once when the binary is missing and returns 1", function()
      local er = load_exec_run(nil, function()
        error("cli.run_async must not be reached without a binary")
      end)
      local errors, responses = {}, {}
      local ret = er.run_async("SELECT 1;", { log = false }, {
        on_response = function(resp) responses[#responses + 1] = resp end,
        on_error = function(msg) errors[#errors + 1] = msg end,
      })
      assert.equals(1, #errors, "one failure, one delivery")
      assert.equals("Poste binary not found", errors[1])
      assert.equals(0, #responses)
      assert.equals(1, ret, "handled inline — callers must not add a second report")
    end)

    it("delivers on_error exactly once when jobstart refuses the spawn", function()
      -- The real -1 shape: cli.run_async returns without firing any callback.
      local er = load_exec_run("/fake/poste", function() return -1 end)
      local errors = {}
      local ret = er.run_async("SELECT 1;", { log = false }, {
        on_error = function(msg) errors[#errors + 1] = msg end,
      })
      assert.equals(1, #errors)
      assert.truthy(errors[1]:find("Failed to start", 1, true))
      assert.equals(1, ret)
    end)

    it("swallows the failed start's synthesized exit (single delivery)", function()
      -- cli.run_async's missing-binary branch calls on_exit(-1) synchronously;
      -- its scheduled delivery must not add a second report.
      local er = load_exec_run("/fake/poste", function(_cmd, cbs)
        cbs.on_exit(-1)
        return nil
      end)
      local errors = {}
      local ret = er.run_async("SELECT 1;", { log = false }, {
        on_error = function(msg) errors[#errors + 1] = msg end,
      })
      assert.equals(1, #errors, "the failed-start branch delivered synchronously")
      assert.equals("Failed to start poste job", errors[1])
      assert.equals(1, ret)
      -- Pump the loop: the synthesized exit's scheduled body must stay quiet.
      vim.wait(100, function() return false end)
      assert.equals(1, #errors)
    end)

    it("still delivers a summary response and stays quiet on a clean exit", function()
      local tmpfile
      local er = load_exec_run("/fake/poste", function(cmd, cbs)
        tmpfile = cmd[2] -- exec-file's input file is the second argument
        -- Replay the job's side synchronously; the module's deliveries ride
        -- vim.schedule, pumped by the wait below.
        cbs.on_stdout({
          '{"type":"result","seq":1,"total":1,"status":"ok","sql":"SELECT 1","row_count":1,"affected_rows":null}',
          '{"type":"summary","total_time_ms":2,"dialect":"sqlite"}',
          "",
        })
        cbs.on_exit(0)
        return 42
      end)
      local errors, responses = {}, {}
      local ret = er.run_async("SELECT 1;", { log = false }, {
        on_response = function(resp) responses[#responses + 1] = resp end,
        on_error = function(msg) errors[#errors + 1] = msg end,
      })
      vim.wait(200, function() return #responses > 0 end)
      assert.equals(42, ret, "a real job returns its job id")
      assert.equals(1, #responses)
      assert.equals(0, #errors)
      assert.truthy(tmpfile)
      assert.equals(0, vim.fn.filereadable(tmpfile), "temp file cleaned up after delivery")
    end)
  end)

  describe("unnamed targets", function()
    -- opts.conn_url / opts.database reach the command line as `--connection` /
    -- `--database`. A blank is not a target: the CLI applies `--database ""` as
    -- replace_database_in_url, so the run loses the database off its own
    -- connection string. A JSON null (`vim.NIL`) is worse — truthy, and jobstart
    -- gets a userdata. Both arrive from callers that read the response envelope
    -- (`conn or ""`) or a tree node's meta.
    local saved_cli = package.loaded["poste-db.cli"]
    local saved_state = package.loaded["poste-db.state"]

    after_each(function()
      package.loaded["poste-db.cli"] = saved_cli
      package.loaded["poste-db.state"] = saved_state
      package.loaded["poste-db.exec_run"] = nil
    end)

    --- exec_run wired to a cli that records the argv instead of spawning.
    local function load_capturing(captured)
      package.loaded["poste-db.state"] = { find_poste_binary = function() return "/fake/poste" end }
      package.loaded["poste-db.cli"] = {
        run_async = function(cmd, _cbs)
          captured.cmd = cmd
          return 5
        end,
      }
      package.loaded["poste-db.exec_run"] = nil
      return require("poste-db.exec_run")
    end

    local function arg_value(cmd, flag)
      for i, v in ipairs(cmd or {}) do
        if v == flag then return cmd[i + 1] end
      end
      return nil
    end

    it("passes a named database through", function()
      local captured = {}
      local er = load_capturing(captured)
      er.run_async("SELECT 1;", { conn_url = "pg://h/app", database = "reporting", log = false }, {})
      assert.equals("reporting", arg_value(captured.cmd, "--database"))
      assert.equals("pg://h/app", arg_value(captured.cmd, "--connection"))
    end)

    it("keeps a JSON null name out of the argv", function()
      local captured = {}
      local er = load_capturing(captured)
      local ok = pcall(er.run_async, "SELECT 1;",
        { conn_url = "pg://h/app", database = vim.NIL, log = false }, {})
      assert.is_true(ok, "a userdata argument must never reach cli.run_async")
      assert.is_nil(arg_value(captured.cmd, "--database"))
    end)

    it("keeps a blank name out of the argv", function()
      local captured = {}
      local er = load_capturing(captured)
      er.run_async("SELECT 1;", { conn_url = "", database = "", log = false }, {})
      assert.is_nil(arg_value(captured.cmd, "--database"))
      assert.is_nil(arg_value(captured.cmd, "--connection"))
    end)

    it("still runs a lone USE locally when the caller named a blank database", function()
      -- The USE shortcut is guarded by "did the caller pin a target?". A `""`
      -- used to count as a pin, so the statement went to exec-file — which
      -- filters USE out of a run — and the context never switched.
      local captured = {}
      local er = load_capturing(captured)
      local responses = {}
      local ret = er.run_async("USE other_db;", { conn_url = nil, database = "", log = false }, {
        on_response = function(resp) responses[#responses + 1] = resp end,
      })
      assert.is_nil(captured.cmd, "nothing is dispatched to the binary")
      assert.equals(1, #responses)
      assert.equals("other_db", responses[1].database)
      assert.equals(1, ret)
    end)
  end)
end)

describe("exec_run.first_error", function()
  it("returns the first in-band statement error", function()
    local resp = { results = { { row_count = 0 }, { error = "table t does not exist" } } }
    assert.equals("table t does not exist", exec_run.first_error(resp))
  end)

  it("treats an empty error string as no error", function()
    assert.is_nil(exec_run.first_error({ results = { { error = "" } } }))
  end)

  it("is nil for a response with no results at all", function()
    assert.is_nil(exec_run.first_error({}))
    assert.is_nil(exec_run.first_error(nil))
  end)

  it("reports a flagged statement that carried no text", function()
    local verdict = require("poste-db.verdict")
    assert.equals(verdict.UNEXPLAINED_FAILURE,
      exec_run.first_error({ results = { { row_count = 0 }, { failed = true } } }))
  end)

  it("reports the envelope verdict when no result carries one", function()
    -- `or "unknown error"` at the call site used to be the only thing standing
    -- between a silent rejection and a caller that reported nothing.
    local verdict = require("poste-db.verdict")
    assert.equals(verdict.UNEXPLAINED_FAILURE,
      exec_run.first_error({ has_error = true, results = { { row_count = 0 } } }))
    assert.equals(verdict.UNEXPLAINED_FAILURE, exec_run.first_error({ has_error = true }))
  end)

  it("returns a string for a structured error object", function()
    -- Callers concatenate the result, so a table error had to be rendered here.
    local text = exec_run.first_error({ results = { { error = { code = 42 } } } })
    assert.equals("string", type(text))
    assert.truthy(text:find("42", 1, true))
  end)
end)
