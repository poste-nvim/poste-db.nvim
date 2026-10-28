local file_exec = require("poste-db.file_exec")

describe("file_exec", function()
  describe("handle_line", function()
    it("exists as a module", function()
      assert.is_not_nil(file_exec)
      assert.is_not_nil(file_exec.run)
      assert.is_not_nil(file_exec.cancel)
    end)
  end)

  describe("progress window", function()
    it("creates and closes progress window", function()
      -- Test that the module can be loaded without errors
      local ok = pcall(require, "poste-db.file_exec")
      assert.is_true(ok, "file_exec module should load without errors")
    end)
  end)

  describe("cancellation", function()
    it("cancel works without active job", function()
      local ok = pcall(file_exec.cancel)
      assert.is_true(ok, "cancel should not error when no job is running")
    end)
  end)

  describe("run builds an argv list (no shell string)", function()
    local saved, captured, logged, notified

    before_each(function()
      saved = {}
      saved.state = package.loaded["poste-db.state"]
      saved.dialog = package.loaded["poste-db.dialog"]
      saved.layout = package.loaded["poste-db.layout"]
      saved.connections = package.loaded["poste-db.connections"]
      saved.log = package.loaded["poste-db.log"]
      saved.jobstart = vim.fn.jobstart
      saved.readfile = vim.fn.readfile

      package.loaded["poste-db.state"] = {
        current_env = "dev",
        find_poste_binary = function() return "/tmp/bin dir/poste" end,
        log = function() end,
      }
      package.loaded["poste-db.dialog"] = {
        open = function()
          return {
            content_width = 68,
            content_height = 18,
            update = function() end,
            close = function() end,
          }
        end,
      }
      local identity = function(x) return x end
      package.loaded["poste-db.layout"] = {
        cell = identity,
        columns = function() return { lines = {}, highlights = {} } end,
        progress = function() return { "" } end,
        space_between = function() return { "" } end,
        separator = function() return { "" } end,
        dynamic_line = function(t) return t.text or "" end,
      }
      package.loaded["poste-db.connections"] = {
        resolve_connection_url = function(name)
          return "clickhouse://user:secret@localhost:18123/" .. name, nil
        end,
      }
      local real_log = require("poste-db.log")
      logged = {}
      package.loaded["poste-db.log"] = setmetatable({
        info = function(msg) logged[#logged + 1] = msg end,
      }, { __index = real_log })

      captured, notified = nil, nil
      vim.fn.jobstart = function(cmd, opts)
        captured = { cmd = cmd, opts = opts }
        return 42
      end
      vim.notify = function(msg, level) notified = { msg = msg, level = level } end

      -- reload file_exec so its top-level requires pick up the stubs
      package.loaded["poste-db.file_exec"] = nil
    end)

    after_each(function()
      package.loaded["poste-db.state"] = saved.state
      package.loaded["poste-db.dialog"] = saved.dialog
      package.loaded["poste-db.layout"] = saved.layout
      package.loaded["poste-db.connections"] = saved.connections
      package.loaded["poste-db.log"] = saved.log
      package.loaded["poste-db.file_exec"] = nil
      vim.fn.jobstart = saved.jobstart
      vim.fn.readfile = saved.readfile
    end)

    local function fresh()
      return require("poste-db.file_exec")
    end

    it("passes the job a list with binary first and unquoted values", function()
      local fe = fresh()
      fe.run({
        filepath = "/tmp/my file.sql",
        conn = "playground",
        database = "my db",
      })

      assert.is_table(captured.cmd, "jobstart must receive an argv list, not a shell string")
      assert.same({
        "/tmp/bin dir/poste", "exec-file", "/tmp/my file.sql",
        "--env", "dev", "--mode", "greedy",
        "--timeout", "30", "--max-rows", "1000",
        "--json",
        "--connection", "clickhouse://user:secret@localhost:18123/playground",
        "--database", "my db",
      }, captured.cmd)
    end)

    it("drops a vim.NIL database from the argv instead of jobstart-ing a userdata", function()
      -- A browser node whose meta.database is a JSON null decodes to vim.NIL:
      -- truthy and ~= "", so the raw check used to put it on the command line
      -- and jobstart soft-failed on the userdata. Same armor as exec_run.
      local fe = fresh()
      fe.run({ filepath = "/tmp/x.sql", conn = "playground", database = vim.NIL })

      assert.is_table(captured.cmd)
      for i, arg in ipairs(captured.cmd) do
        assert.not_equals("--database", arg,
          "vim.NIL database must not produce a --database flag (index " .. i .. ")")
      end
    end)

    it("falls back to the file's @connection directive", function()
      vim.fn.readfile = function()
        return { "SELECT 1;", "-- @connection directive_conn" }
      end

      local fe = fresh()
      fe.run({ filepath = "/tmp/plain.sql" })

      assert.is_table(captured.cmd)
      local idx = #captured.cmd - 1
      assert.equals("--connection", captured.cmd[idx])
      assert.equals("clickhouse://user:secret@localhost:18123/directive_conn", captured.cmd[idx + 1])
    end)

    it("does not start a job and reports the error on an unresolvable connection", function()
      package.loaded["poste-db.connections"] = {
        resolve_connection_url = function() return nil, "not in connections.toml" end,
      }

      local fe = fresh()
      fe.run({ filepath = "/tmp/x.sql", conn = "nope" })

      assert.is_nil(captured, "no job must be started when connection resolution fails")
      assert.truthy(notified)
      assert.equals(vim.log.levels.ERROR, notified.level)
      assert.matches("not found", notified.msg)
    end)

    it("reports instead of raising when jobstart throws E475 on a vanished binary", function()
      -- find_poste_binary answered a moment before; the path is gone now.
      -- jobstart raises Vim:E475 instead of returning an error code, and the
      -- raise used to skip the -1 branch entirely, leaving S.is_running stuck
      -- true and the progress dialog spinning for the session.
      vim.fn.jobstart = function()
        error("Vim:E475: /tmp/bin dir/poste is not executable")
      end

      local fe = fresh()
      fe.run({ filepath = "/tmp/x.sql", conn = "playground" })

      assert.truthy(notified, "the failure must surface through notify")
      assert.equals(vim.log.levels.ERROR, notified.level)
      assert.matches("Failed to start", notified.msg)

      -- the is_running flag must have been reset: a second run reaches jobstart
      -- instead of being refused as an already-running session
      notified = nil
      vim.fn.jobstart = function(cmd, opts)
        captured = { cmd = cmd, opts = opts }
        return 42
      end
      fe.run({ filepath = "/tmp/x.sql", conn = "playground" })
      assert.is_table(captured, "a run after a raise must not be blocked by a stuck is_running")
    end)

    it("renders a null statement error as 'unknown error', not vim.NIL", function()
      -- `event.error or "unknown error"` never fired for JSON null: vim.NIL
      -- is truthy, and string.format("%s") printed it literally.
      local fe = fresh()
      fe.run({ filepath = "/tmp/x.sql", conn = "playground" })
      -- Each stdout call is one line; the "" element flushes it (the jobstart
      -- line contract the handler implements).
      captured.opts.on_stdout(nil, { vim.json.encode({ type = "progress", seq = 1, total = 1, sql = "SELECT 1" }), "" })
      captured.opts.on_stdout(nil, {
        vim.json.encode({
          type = "result", seq = 1, total = 1, status = "error", sql = "SELECT 1",
          error = vim.NIL, execution_time_ms = 1,
        }),
        "",
      })

      assert.truthy(notified)
      assert.matches("unknown error", notified.msg)
      assert.not_matches("vim%.NIL", notified.msg)
    end)

    it("redacts a DSN echoed by a failed statement", function()
      -- This notify bypasses format_error, whose panel path redacts — the
      -- same rule has to hold here or a driver error leaks the password.
      local fe = fresh()
      fe.run({ filepath = "/tmp/x.sql", conn = "playground" })
      captured.opts.on_stdout(nil, { vim.json.encode({ type = "progress", seq = 1, total = 1, sql = "SELECT 1" }), "" })
      captured.opts.on_stdout(nil, {
        vim.json.encode({
          type = "result", seq = 1, total = 1, status = "error", sql = "SELECT 1",
          error = "connection failed: postgres://user:secretpw@host/db",
          execution_time_ms = 1,
        }),
        "",
      })

      assert.truthy(notified)
      assert.not_matches("secretpw", notified.msg)
    end)

    it("reports a run that ends without a summary event", function()
      -- A dead binary/connection used to just stop the dialog: the journal
      -- recorded the exit, but per-statement failures notified while this
      -- whole-run failure stayed silent.
      local fe = fresh()
      fe.run({ filepath = "/tmp/x.sql", conn = "playground" })
      captured.opts.on_exit(42, 137)
      vim.wait(100, function() return notified ~= nil and notified.msg ~= nil end)

      assert.truthy(notified)
      assert.equals(vim.log.levels.ERROR, notified.level)
      assert.matches("no summary event", notified.msg)
      assert.matches("137", notified.msg)
    end)

    it("redacts the connection URL in the command log", function()
      local fe = fresh()
      fe.run({ filepath = "/tmp/x.sql", conn = "playground" })

      assert.equals(1, #logged)
      assert.matches("ExecFile cmd:", logged[1])
      assert.is_falsy(logged[1]:find("secret", 1, true))
      assert.matches("<redacted>", logged[1])
    end)
  end)

  -- The same anchored rule the Rust CLI applies (crates/poste-cli/src/
  -- exec_file.rs::extract_connection_directive, whose test spells out the two
  -- rejected shapes): a directive is a whole line, because the lines it reads
  -- are also the lines the CLI strips from the SQL body.
  describe("extract_connection_directive", function()
    local function directive_in(lines)
      local saved = vim.fn.readfile
      vim.fn.readfile = function() return lines end
      local ok, got = pcall(function()
        return require("poste-db.file_exec")._test.extract_connection_directive("/x.sql")
      end)
      vim.fn.readfile = saved
      assert.is_true(ok)
      return got
    end

    it("reads a directive line, indented or not", function()
      assert.equals("pg-dev", directive_in({ "-- @connection pg-dev", "SELECT 1;" }))
      assert.equals("pg-dev", directive_in({ "   --@connection pg-dev" }))
      assert.equals("pg-dev", directive_in({ "-- @database blog", "", "-- @connection pg-dev" }))
    end)

    it("ignores a directive-looking comment that is not a directive line", function()
      assert.is_nil(directive_in({ "SELECT 1; -- @connection stray" }))
      assert.is_nil(directive_in({ "/* -- @connection stray */" }))
      assert.is_nil(directive_in({ "SELECT '-- @connection stray' AS note" }))
    end)

    it("needs a value", function()
      assert.is_nil(directive_in({ "-- @connection" }))
      assert.equals("pg-dev", directive_in({ "-- @connection", "-- @connection pg-dev" }))
      -- A line with only blanks after the word carries no name. The Rust CLI
      -- trims the capture and skips it when nothing is left
      -- (exec_file.rs::extract_connection_directive); taking it as a connection
      -- named "" made the editor fail with `Connection '' not found` while the
      -- CLI reported "No connection specified" for the very same file.
      assert.is_nil(directive_in({ "-- @connection   " }))
      assert.is_nil(directive_in({ "-- @connection\t" }))
      assert.equals("pg-dev", directive_in({ "-- @connection   ", "-- @connection pg-dev" }))
    end)
  end)
end)