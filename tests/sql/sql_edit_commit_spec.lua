--- Tests for edit_commit/init.lua — dataset refresh data propagation.
--- Regression: after dataset R-refresh, tab.data fell back to the stale
--- state.last_response (set only by the sql_runner request path), so cell
--- preview (K) / yank / sort read pre-refresh rows while the buffer showed
--- the new ones.

local captured = {}

local FRESH_ROWS = { { 1, "old" }, { 11, "new" } }
local FRESH_BODY = {
  type = "resultset",
  results = {
    {
      columns = { { name = "id" }, { name = "name" } },
      rows = FRESH_ROWS,
      row_count = 2,
    },
  },
  total_rows = 2,
}

local state_stub = {
  -- one module since the poste.nvim family dissolution: the old
  -- poste.state `sql` shim nesting is gone, context lives at the top level
  context = { connection = nil, database = nil },
  find_poste_binary = function() return "/tmp/poste" end,
  log = function() end,
}

local function install_stubs()
  package.loaded["poste-db.state"] = state_stub
  package.loaded["poste-db.editor"] = { clear_pk_cache = function() end }
  -- commit_edits calls ensure_primary_key before generating DML; the real one
  -- introspects via the poste binary.
  package.loaded["poste-db.editor.column"] = { ensure_primary_key = function() end }
  package.loaded["poste-db.sql_runner"] = { get_exec_seq = function() return 42 end }
  package.loaded["poste-db.connections"] = {
    resolve_connection_url = function(name) return "mysql://" .. name, nil end,
  }
  package.loaded["poste-db.statement"] = { extract_table_name = function() return nil end }
  -- DML generation is stubbed so commit_edits can be exercised end-to-end
  -- without a real edit_state/table layout.
  package.loaded["poste-db.dml"] = {
    generate_dml = function()
      return { { type = "update", sql = "UPDATE tb SET name = 'x'" } }
    end,
  }
  package.loaded["poste-db.format"] = {
    format_dataset = function(parsed)
      local ok, body = pcall(vim.json.decode, parsed.body)
      return { "│ id │" }, { type = "resultset", row_count = ok and body.results[1].row_count or 0 },
        { rows = ok and body.results[1].rows or {} }
    end,
  }
  package.loaded["poste-db.buffer"] = {
    render_dataset = function(lines, meta, opts)
      captured.lines = lines
      captured.meta = meta
      captured.opts = opts
    end,
  }
  package.loaded["poste-db.exec_run"] = {
    run_async = function(sql, opts, callbacks)
      captured.sql = sql
      local resp = {
        status = "ok",
        latency_ms = 5,
        body = vim.json.encode(FRESH_BODY),
        connection = "mysql://dev",
        database = "db",
        results = FRESH_BODY.results,
      }
      callbacks.on_response(resp)
      return 7
    end,
  }
end

describe("edit_commit refresh_dataset", function()
  before_each(function()
    install_stubs()
    captured.opts = nil
    captured.sql = nil
    require("poste-db.edit_commit").refresh_dataset({
      original_sql = "SELECT * FROM tb;",
      src_file = "test.sql",
      src_buf = 7,
      layout = { _conn_name = "dev", _database = "db" },
    })
    -- refresh_dataset schedules render via vim.schedule; flush the loop.
    vim.wait(100, function() return captured.opts ~= nil end)
  end)

  it("re-executes the original SELECT", function()
    assert.match("SELECT %* FROM tb", captured.sql)
  end)

  it("passes the fresh resultset as render data (not the stale last_response)", function()
    assert.is_not_nil(captured.opts, "render_dataset was not called")
    assert.is_not_nil(captured.opts.data, "refresh must pass opts.data")
    assert.equals("resultset", captured.opts.data.type)
    assert.same(FRESH_ROWS, captured.opts.data.results[1].rows)
    assert.same(FRESH_ROWS, captured.opts.layout.rows)
  end)

  it("keeps layout/original_sql/src routing for the new tab", function()
    assert.equals("SELECT * FROM tb;", captured.opts.original_sql)
    assert.equals("test.sql", captured.opts.src_file)
    assert.equals(7, captured.opts.src_buf)
    assert.equals(42, captured.opts.exec_seq)
  end)
end)
describe("edit_commit commit_edits", function()
  before_each(function()
    install_stubs()
    captured.sql = nil
    captured.commit_opts = nil
    captured.dispatches = nil
    captured.commit_callbacks = nil
    -- The flag a previous test left set must not leak into this one: the
    -- stubs below never deliver a callback, so production's release path
    -- (on_response / on_error) does not run.
    pcall(function() require("poste-db.edit_commit")._test.reset_in_flight() end)
    -- commit_edits dispatches per call, so replace the refresh-path stub.
    package.loaded["poste-db.exec_run"] = {
      run_async = function(sql, opts)
        captured.sql = sql
        captured.commit_opts = opts
        captured.dispatches = (captured.dispatches or 0) + 1
        return 7
      end,
    }
    -- Active tab with a dirty edit_state; layout deliberately carries NO
    -- _conn_name/_database so commit_edits must fall back to the SQL context.
    local D = require("poste-db.dataset")
    D.tabs = { {
      original_sql = "SELECT * FROM tb;",
      src_file = "test.sql",
      src_buf = 7,
      layout = { dialect = "mysql", columns = {}, table_name = "tb" },
      edit_state = {
        dirty = true,
        modified_cells = { ["1:2"] = { col = 2, value = "x" } },
        deleted_rows = {},
        added_rows = {},
        cell_errors = {},
      },
    } }
    D.active_tab_idx = 1
  end)

  after_each(function()
    local D = require("poste-db.dataset")
    D.tabs = {}
    D.active_tab_idx = 0
  end)

  it("dispatches the generated DML via exec-file", function()
    -- Regression: commit_edits read sql_state.context without a local
    -- require, raising "attempt to index a nil value (global 'sql_state')"
    -- once the DML had been generated.
    require("poste-db.edit_commit").commit_edits()
    assert.equals("UPDATE tb SET name = 'x'", captured.sql)
    assert.is_not_nil(captured.commit_opts)
  end)

  it("falls back to the SQL context when the layout has no connection/database", function()
    require("poste-db.edit_commit").commit_edits()
    assert.equals("", captured.commit_opts.database)
    assert.is_nil(captured.commit_opts.conn_url)
  end)

  it("refuses a second dispatch while a commit is in flight", function()
    -- The stub never delivers a callback, so after the first call the batch
    -- is still running: a second <leader>w used to re-dispatch the identical
    -- DML (a plain INSERT then wrote duplicated rows).
    require("poste-db.edit_commit").commit_edits()
    assert.equals(1, captured.dispatches)
    require("poste-db.edit_commit").commit_edits()
    assert.equals(1, captured.dispatches, "the second commit must not dispatch")
  end)

  it("dispatches again once the in-flight commit's flag is released", function()
    require("poste-db.edit_commit").commit_edits()
    assert.equals(1, captured.dispatches)
    -- Production releases the flag through the run's on_response / on_error
    -- (exec_run delivers exactly once per run). The full callback path pulls
    -- in the real exec/log modules, which the stubs above do not cover, so
    -- the release is simulated at the seam the tests exercise.
    require("poste-db.edit_commit")._test.reset_in_flight()
    require("poste-db.edit_commit").commit_edits()
    assert.equals(2, captured.dispatches, "a landed commit releases the flag")
  end)
end)
