local saved_state = package.loaded["poste-db.state"]
local saved_config = package.loaded["poste-db.config"]
local saved_util = package.loaded["poste-db.util"]
local saved_indicators = package.loaded["poste-db.indicators"]
local saved_statement = package.loaded["poste-db.statement"]
local saved_introspect = package.loaded["poste-db.introspect"]
local saved_format = package.loaded["poste-db.format"]
local saved_buffer = package.loaded["poste-db.buffer"]

-- One module since the poste.nvim family dissolution: the old poste.state
-- and poste-db.state stubs collapse into a single table. Both local names
-- are kept as aliases so the per-test mutations/assertions below stay
-- meaningful.
local poste_state_stub = {
  current_env = "dev",
  find_poste_binary = function() return nil end,
  log = function() end,
  last_response = nil,
  context = { connection = nil, database = nil },
}
local sql_state_stub = poste_state_stub
local config_stub = {
  get_keymap = function() return nil end,
  config = {},
}

package.loaded["poste-db.state"] = poste_state_stub
package.loaded["poste-db.config"] = config_stub
-- dml_guard (a transitive dep of the runner) calls util.ellipsize in its
-- confirm path, so the isolation stub must forward the real helper — an
-- empty table turned every DML-guard rejection into "attempt to call field
-- 'ellipsize' (a nil value)".
package.loaded["poste-db.util"] = {
  ellipsize = (saved_util or require("poste-db.util")).ellipsize,
}
package.loaded["poste-db.indicators"] = { clear_all = function() end, set_indicator = function() end }
package.loaded["poste-db.statement"] = {
  extract_stmt_at_cursor = function() end,
  extract_visual_block = function() end,
  find_stmt_lines = function() end,
  get_stmt_sql = function() return "" end,
  extract_table_name = function() end,
  selection_cuts_statement = function() return false end,
  _test = {},
}
package.loaded["poste-db.introspect"] = { show_table_ddl = function() end }
package.loaded["poste-db.format"] = { format_dataset = function() end, format_error = function() end, plan_resultset_layout = function() end, render_page = function() end, format_resultset = function() end }
package.loaded["poste-db.buffer"] = { clear_panel = function() end, render_dataset = function() end }

local runner = require("poste-db.sql_runner")

describe("sql_runner ensure_sql_keymaps", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.b[buf] = {}
  end)

  it("installs keymaps on first call", function()
    config_stub.get_keymap = function(area, name, default)
      return default
    end
    runner.ensure_sql_keymaps(buf)
    assert.is_true(vim.b[buf].poste_db_keymaps_installed)
  end)

  it("skips if already installed", function()
    vim.b[buf].poste_db_keymaps_installed = true
    local get_keymap_calls = 0
    config_stub.get_keymap = function()
      get_keymap_calls = get_keymap_calls + 1
      return nil
    end
    runner.ensure_sql_keymaps(buf)
    assert.equals(0, get_keymap_calls)
  end)
end)

describe("sql_runner is_ddl", function()
  it("detects DDL with leading @connection directive and ### marker", function()
    assert.is_true(runner._test.is_ddl("-- @connection blog\n###\nCREATE TABLE three_kingdoms_characters (id INT);"))
  end)

  it("detects CREATE/ALTER/DROP/TRUNCATE/RENAME", function()
    assert.is_true(runner._test.is_ddl("CREATE TABLE t (id INT);"))
    assert.is_true(runner._test.is_ddl("ALTER TABLE t ADD COLUMN c INT;"))
    assert.is_true(runner._test.is_ddl("DROP TABLE t;"))
    assert.is_true(runner._test.is_ddl("TRUNCATE TABLE t;"))
    assert.is_true(runner._test.is_ddl("RENAME TABLE a TO b;"))
  end)

  it("detects DDL in any keyword case", function()
    -- The db-browser CREATE TABLE template (db_browser/operations.lua)
    -- inserts lowercase `create table`; the old exact-case match skipped the
    -- completion/diagnostics cache invalidation for every statement written
    -- from it. SQL keywords are not case-sensitive.
    assert.is_true(runner._test.is_ddl("create table t (id INT);"))
    assert.is_true(runner._test.is_ddl("Create Table t (id INT);"))
    assert.is_true(runner._test.is_ddl("drop table t;"))
    assert.is_true(runner._test.is_ddl("-- @connection blog\n###\ncreate table three_kingdoms_characters (id INT);"))
    -- An identifier that merely starts with a keyword prefix is not DDL
    assert.is_false(runner._test.is_ddl("created_at_ts t;"))
    assert.is_false(runner._test.is_ddl("alphabet soup;"))
  end)

  it("rejects DML and reads", function()
    assert.is_false(runner._test.is_ddl("SELECT * FROM t;"))
    assert.is_false(runner._test.is_ddl("INSERT INTO t VALUES (1);"))
    assert.is_false(runner._test.is_ddl("UPDATE t SET c = 1;"))
    assert.is_false(runner._test.is_ddl(nil))
  end)

  it("ignores leading comment and blank lines", function()
    assert.is_true(runner._test.is_ddl("-- note\n\n   DROP TABLE t;"))
    assert.is_false(runner._test.is_ddl("-- note\nSELECT 1;"))
  end)
end)

describe("sql_runner run_sql_request", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "select 1" })
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".sql")
    vim.api.nvim_set_current_buf(buf)
    vim.b[buf] = {}
    sql_state_stub.context = { connection = nil, database = nil }
  end)

  it("notifies when binary not found", function()
    poste_state_stub.find_poste_binary = function() return nil end
    local notified
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end
    runner.run_sql_request()
    assert.is_not_nil(notified)
    assert.matches("not found", notified.msg)
  end)

  it("visual multi-statement: running spinner lands on each statement's first line", function()
    local lines = {
      "-- 创建能力表",
      "CREATE TABLE abilities (",
      "    id INT AUTO_INCREMENT PRIMARY KEY,",
      "    FOREIGN KEY (character_id) REFERENCES characters(id) ON DELETE CASCADE",
      ");",
      "",
      "-- 创建团队表",
      "CREATE TABLE teams (",
      "    id INT AUTO_INCREMENT PRIMARY KEY,",
      ");",
    }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    poste_state_stub.find_poste_binary = function() return "poste" end
    config_stub.get_keymap = function(area, name, default) return default end
    config_stub.config = { confirm_unfiltered_dml = false }

    local stub = package.loaded["poste-db.statement"]
    stub.extract_visual_block = function(src, start_line, end_line)
      return table.concat(lines, "\n"), { 2, 8 }, 0
    end
    stub.extract_label = function() return nil end
    stub.fallback_label = function() return "test_label" end
    stub.get_stmt_sql = function() return "" end

    local indicator_calls = {}
    -- The runner captured `poste.indicators` at require time (the stub set up
    -- at the top of this spec), so mutate that same object to spy on calls.
    local ind_stub = package.loaded["poste-db.indicators"]
    ind_stub.clear_all = function() end
    ind_stub.set_indicator = function(...)
      indicator_calls[#indicator_calls + 1] = { ... }
    end
    package.loaded["poste-db.executor"] = { execute = function() end }

    runner.ensure_sql_keymaps(buf)
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("normal! ggVG")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

    -- Running spinners must sit on the statements' FIRST lines (0-indexed
    -- lines 1 = "CREATE TABLE abilities (" and 7 = "CREATE TABLE teams (")
    -- — the same lines completion will touch — aligned with the SQL start.
    local running_lines = {}
    for _, c in ipairs(indicator_calls) do
      if c[3] == "running" then running_lines[#running_lines + 1] = c[2] end
    end
    table.sort(running_lines)
    assert.same({ 1, 7 }, running_lines, "spinner must land on each statement's first line")
  end)

  it("cancelled run (no statement at cursor) keeps last_response/last_dataset", function()
    poste_state_stub.find_poste_binary = function() return "poste" end
    config_stub.get_keymap = function(area, name, default) return default end
    config_stub.config = {}
    package.loaded["poste-db.statement"].extract_stmt_at_cursor = function() return nil end
    package.loaded["poste-db.executor"] = { execute = function()
      error("executor must not run for a cancelled request")
    end }

    -- A previous request's results must survive the cancel
    poste_state_stub.last_response = { body = "{}" }
    sql_state_stub.last_dataset = { type = "resultset" }

    local begin_calls = 0
    package.loaded["poste-db.session"] = {
      begin = function()
        begin_calls = begin_calls + 1
        return {}
      end,
    }

    runner.run_sql_request()

    assert.equals(0, begin_calls, "cancelled run must not begin a new session")
    assert.same({ body = "{}" }, poste_state_stub.last_response)
    assert.same({ type = "resultset" }, sql_state_stub.last_dataset)
  end)

  it("DML-guard rejection keeps last_response/last_dataset", function()
    poste_state_stub.find_poste_binary = function() return "poste" end
    config_stub.get_keymap = function(area, name, default) return default end
    config_stub.config = {}  -- confirm_unfiltered_dml defaults on
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "DELETE FROM t;" })

    local stmt_stub = package.loaded["poste-db.statement"]
    stmt_stub.extract_stmt_at_cursor = function() return "DELETE FROM t;", nil, 1, 1 end
    stmt_stub.extract_label = function() return "del" end
    stmt_stub.fallback_label = function() return "test_1" end
    package.loaded["poste-db.executor"] = { execute = function()
      error("executor must not run after a DML-guard cancel")
    end }

    poste_state_stub.last_response = { body = "{}" }
    sql_state_stub.last_dataset = { type = "resultset" }

    local begin_calls = 0
    package.loaded["poste-db.session"] = {
      begin = function()
        begin_calls = begin_calls + 1
        return {}
      end,
    }

    local real_confirm = vim.fn.confirm
    local confirm_calls = 0
    vim.fn.confirm = function()
      confirm_calls = confirm_calls + 1
      return 2  -- No, cancel
    end
    runner.run_sql_request()
    vim.fn.confirm = real_confirm

    assert.equals(1, confirm_calls, "guard must ask before executing")
    assert.equals(0, begin_calls, "cancelled run must not begin a new session")
    assert.same({ body = "{}" }, poste_state_stub.last_response)
    assert.same({ type = "resultset" }, sql_state_stub.last_dataset)
  end)

  it("passes the hoisted SET prelude to the executor as separate statements", function()
    -- One request per statement on the session transport: a multi-statement
    -- single request dies in MySQL's prepared-statement protocol with a 1064.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "set @a = 1;", "select @a;" })
    poste_state_stub.find_poste_binary = function() return "poste" end
    config_stub.get_keymap = function(area, name, default) return default end
    config_stub.config = {}
    local stmt_stub = package.loaded["poste-db.statement"]
    stmt_stub.extract_stmt_at_cursor = function()
      return "-- @connection x\n###\nset @a = 1;\nselect @a;", nil, 2, 2, { "set @a = 1;" }
    end
    stmt_stub.extract_label = function() return "lbl" end
    stmt_stub.fallback_label = function() return "test_1" end
    package.loaded["poste-db.session"] = nil

    local executed = {}
    package.loaded["poste-db.executor"] = {
      execute = function(opts) executed[#executed + 1] = opts end,
    }

    vim.fn.cursor(2, 1)
    runner.run_sql_request()

    assert.equals(1, #executed, "clean statement must reach the executor")
    assert.same({ "set @a = 1;", "select @a;" }, executed[1].sql_statements)
  end)

  it("visual selection cutting a statement in half cancels before any run", function()
    poste_state_stub.find_poste_binary = function() return "poste" end
    config_stub.get_keymap = function(area, name, default) return default end
    config_stub.config = { confirm_unfiltered_dml = false }
    local stmt_stub = package.loaded["poste-db.statement"]
    stmt_stub.selection_cuts_statement = function() return true end
    stmt_stub.extract_visual_block = function()
      error("extract_visual_block must not run for a cut selection")
    end
    package.loaded["poste-db.executor"] = { execute = function()
      error("executor must not run for a cut selection")
    end }
    package.loaded["poste-db.session"] = { begin = function()
      error("session must not begin for a cut selection")
    end }

    -- A previous request's results must survive the cancel
    poste_state_stub.last_response = { body = "keep" }

    local notified
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end
    runner.ensure_sql_keymaps(buf)
    vim.cmd("normal! ggVG")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

    assert.is_not_nil(notified, "the cut must be explained")
    assert.matches("mid%-statement", notified.msg)
    assert.same({ body = "keep" }, poste_state_stub.last_response)
  end)

  it("accepted run begins the session and clears request-scoped state", function()    poste_state_stub.find_poste_binary = function() return "poste" end
    config_stub.get_keymap = function(area, name, default) return default end
    config_stub.config = {}

    local stmt_stub = package.loaded["poste-db.statement"]
    stmt_stub.extract_stmt_at_cursor = function() return "SELECT 1", nil, 1, 1 end
    stmt_stub.extract_label = function() return "sel" end
    stmt_stub.fallback_label = function() return "test_1" end

    poste_state_stub.last_response = { body = "stale" }
    sql_state_stub.last_dataset = { type = "resultset" }

    -- Real session module: begin() must clear both request-scoped fields.
    package.loaded["poste-db.session"] = nil

    local executed = {}
    package.loaded["poste-db.executor"] = {
      execute = function(opts) executed[#executed + 1] = opts end,
    }

    runner.run_sql_request()

    assert.equals(1, #executed, "clean SELECT must reach the executor")
    assert.is_nil(poste_state_stub.last_response)
    assert.is_nil(sql_state_stub.last_dataset)
  end)

  after_each(function()
    package.loaded["poste-db.state"] = saved_state
    package.loaded["poste-db.config"] = saved_config
    package.loaded["poste-db.util"] = saved_util
    package.loaded["poste-db.indicators"] = saved_indicators
    package.loaded["poste-db.statement"] = saved_statement
    package.loaded["poste-db.introspect"] = saved_introspect
    package.loaded["poste-db.format"] = saved_format
    package.loaded["poste-db.buffer"] = saved_buffer
  end)
end)

