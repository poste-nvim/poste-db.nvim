--- db_browser ops_drop — the single-table DROP and the tree refresh that
--- follows it.
---
--- execute_drop declared a `schema_prefix` parameter its body never used, and
--- the only call site (the confirm dialog's `y`) passes four arguments — so
--- the real context landed in that slot and `context` was nil inside: the
--- DROP ran, then refresh_subtree(nil) raised in util.render_tree and the tree
--- never refreshed. sqlite hides it (a table there has no database/schema
--- ancestor, so the refresh is skipped wholesale), which is why it survived.
local ops_drop = require("poste-db.db_browser.ops_drop")
local util = require("poste-db.db_browser.util")
local notify = require("poste-db.db_browser.notify")

local t = ops_drop._test

local real_refresh = util.refresh_subtree
local real_notify_info = notify.info
local real_exec = package.loaded["poste-db.exec_run"]
local real_conns = package.loaded["poste-db.connections"]
local real_schedule = vim.schedule
local real_vim_notify = vim.notify

local refreshes
local exec_calls

--- A PG/MySQL table: the parent chain reaches a database node, which is the
--- shape that actually refreshes (and the shape that used to crash).
local function table_node()
  local db = { node_type = "database", name = "blog" }
  local node = {
    node_type = "table",
    name = "posts",
    meta = { database = "blog", schema = "public", connection = "maria-dev", table_type = "BASE TABLE" },
    parent = db,
  }
  db.children = { node }
  return node
end

--- A sqlite table hangs straight off the connection node: no database or
--- schema ancestor, so there is nothing to reload.
local function sqlite_table_node()
  return {
    node_type = "table",
    name = "posts",
    meta = { connection = "local", table_type = "BASE TABLE" },
    parent = nil,
  }
end

local function context()
  return {
    browser_buf = vim.api.nvim_create_buf(false, true),
    line_to_node = {},
    root_nodes = {},
    conn_label = "maria-dev",
    multi_select = {},
    source_buf = vim.api.nvim_create_buf(false, true),
  }
end

--- Run the DROP through the captured run_async callbacks the way exec_run
--- delivers them: on_response fires exactly once per run.
local function deliver(resp)
  exec_calls[1].callbacks.on_response(resp)
end

describe("db_browser ops_drop single-table drop", function()
  before_each(function()
    refreshes = {}
    exec_calls = {}
    util.refresh_subtree = function(node, ctx, node_type, search_dir)
      refreshes[#refreshes + 1] = { node = node, context = ctx, node_type = node_type, search_dir = search_dir }
    end
    notify.info = function() end
    package.loaded["poste-db.exec_run"] = {
      run_async = function(sql, opts, callbacks)
        exec_calls[#exec_calls + 1] = { sql = sql, opts = opts, callbacks = callbacks }
        return 7
      end,
      first_error = function() return nil end,
    }
    package.loaded["poste-db.connections"] = {
      resolve_connection_url = function() return "postgres://u:p@h:5432/blog", nil end,
    }
    -- The response hook defers through vim.schedule; run it inline so the
    -- spec stays synchronous and a wrong argument lands on an assertion
    -- instead of disappearing into the event loop.
    vim.schedule = function(fn) fn() end
    -- The failure path reports through vim.notify, which headless echoes as
    -- "Error in command line" and drowns the gate output.
    vim.notify = function() end
  end)

  after_each(function()
    util.refresh_subtree = real_refresh
    notify.info = real_notify_info
    package.loaded["poste-db.exec_run"] = real_exec
    package.loaded["poste-db.connections"] = real_conns
    vim.schedule = real_schedule
    vim.notify = real_vim_notify
  end)

  it("drops the qualified table on the connection", function()
    t.execute_drop(table_node(), '"public"."posts"', "maria-dev", context())
    assert.equals(1, #exec_calls)
    assert.equals('DROP TABLE "public"."posts";', exec_calls[1].sql)
    assert.equals("postgres://u:p@h:5432/blog", exec_calls[1].opts.conn_url)
  end)

  it("refreshes the parent with the browser context after a successful drop", function()
    local ctx = context()
    local node = table_node()
    t.execute_drop(node, '"public"."posts"', "maria-dev", ctx)
    deliver({ has_error = false })

    assert.equals(1, #refreshes, "a successful drop must refresh the parent")
    -- The regression: `context` used to arrive nil (the argument landed in
    -- the unused `schema_prefix` slot), and util.render_tree indexed it.
    assert.equals(ctx, refreshes[1].context, "refresh needs the browser context")
    assert.equals(node.parent, refreshes[1].node)
    assert.equals("database", refreshes[1].node_type)
    assert.is_truthy(refreshes[1].search_dir)
  end)

  it("does not refresh when the drop failed", function()
    t.execute_drop(table_node(), '"public"."posts"', "maria-dev", context())
    deliver({ has_error = true })
    assert.equals(0, #refreshes)
  end)

  it("does not refresh a sqlite table that has no database ancestor", function()
    t.execute_drop(sqlite_table_node(), '"posts"', "local", context())
    deliver({ has_error = false })
    assert.equals(0, #refreshes)
  end)
end)
