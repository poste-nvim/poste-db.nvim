--- DB Browser tree introspection journaling — the "expand a database node and
--- the connection times out" case must land in sql_log.jsonl.
local saved_async = package.loaded["poste-db.async"]
local saved_connections = package.loaded["poste-db.connections"]
local saved_state = package.loaded["poste-db.state"]
local saved_tree = package.loaded["poste-db.db_browser.tree"]

local async_opts = nil
local async_cmd = nil

package.loaded["poste-db.async"] = {
  run = function(cmd, opts)
    async_cmd = cmd
    async_opts = opts
    return { cancel = function() end }
  end,
}
package.loaded["poste-db.connections"] = {
  resolve_connection_url = function(name)
    if name == "missing" then return nil, "not found" end
    return "pg://u:pw@h/db"
  end,
}
package.loaded["poste-db.state"] = {
  log = function() end,
}
-- Stub the tree module: requiring the real one pulls in theme/highlights,
-- which need full plugin state the bare stubs above can't provide.
package.loaded["poste-db.db_browser.tree"] = {}

local sql_log = require("poste-db.sql_log")
package.loaded["poste-db.db_browser.async"] = nil
local browser_async = require("poste-db.db_browser.async")

local path


--- Drain pending vim.schedule callbacks inside the live test, so the
--- scheduled notifies/callbacks error nowhere and leak into nothing.
local function flush()
  vim.wait(100, function() return false end)
end

local function read_entries()
  local out = {}
  for _, l in ipairs(vim.fn.readfile(path)) do
    table.insert(out, vim.json.decode(l))
  end
  return out
end

local function arg_value(cmd, flag)
  for i, v in ipairs(cmd or {}) do
    if v == flag then return cmd[i + 1] end
  end
  return nil
end

describe("db_browser run_introspect journaling", function()
  local saved_notify
  before_each(function()
    path = vim.fn.tempname() .. ".jsonl"
    sql_log.set_log_path(path)
    async_opts = nil
    async_cmd = nil
    -- ERROR-level notifies from run_introspect's scheduled callbacks print
    -- via the error channel in headless runs and crash plenary's harness
    -- when they land outside a live test.
    saved_notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    vim.notify = saved_notify
    sql_log.set_log_path(nil)
    if path and vim.fn.filereadable(path) == 1 then vim.fn.delete(path) end
    flush()
  end)

  it("journals a successful listing with the connection name", function()
    local called = false
    browser_async.run_introspect("pg-dev", "tables", nil, nil, "app", function() called = true end)

    async_opts.on_data({ vim.json.encode({ items = { { name = "users" } } }) })
    async_opts.on_exit(0)
    vim.wait(500, function() return called end)

    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("browser", entries[1].source)
    assert.equals("success", entries[1].status)
    assert.equals("pg-dev", entries[1].connection)
    assert.equals("app", entries[1].database)
    assert.equals("introspect tables db=app", entries[1].sql)
    flush()
  end)

  it("journals a connection timeout (on_error) as an error entry", function()
    local cb_result = "unset"
    browser_async.run_introspect("pg-dev", "tables", nil, nil, "app", function(r) cb_result = r end)
    async_opts.on_error("Timeout after 15000ms")
    vim.wait(500, function() return cb_result == nil end)

    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("browser", entries[1].source)
    assert.equals("error", entries[1].status)
    assert.equals("Timeout after 15000ms", entries[1].error)
    assert.equals("pg-dev", entries[1].connection)
    flush()
  end)

  it("journals a non-zero exit with stderr as the error text", function()
    browser_async.run_introspect("pg-dev", "databases", nil, nil, nil, function() end)
    async_opts.on_stderr({ "password authentication failed" })
    async_opts.on_exit(2)

    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("error", entries[1].status)
    assert.equals("password authentication failed", entries[1].error)
    assert.equals("introspect databases", entries[1].sql)
    flush()
  end)

  it("journals an unresolvable connection without starting a job", function()
    browser_async.run_introspect("missing", "tables", nil, nil, nil, function() end)

    assert.is_nil(async_opts)
    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("error", entries[1].status)
    assert.equals("not found", entries[1].error)
    flush()
  end)

  -- The names handed to run_introspect come straight off a tree node, i.e. out
  -- of the binary's listing rows: `""` is "this connection's own database" and
  -- a JSON null decodes to vim.NIL. Both are truthy. An empty `--database` is
  -- applied as replace_database_in_url, so the listing/DDL/columns came back
  -- for a different database than the node the user clicked; a null raised in
  -- the journal line's concatenation before any job started.
  it("keeps an unnamed database out of the introspect argv and the journal", function()
    browser_async.run_introspect("pg-dev", "tables", "", "", "", function() end)

    assert.is_nil(arg_value(async_cmd, "--database"))
    assert.is_nil(arg_value(async_cmd, "--schema"))
    assert.is_nil(arg_value(async_cmd, "--table"))
    async_opts.on_exit(1)
    flush()
    local entries = read_entries()
    assert.equals(1, #entries)
    assert.is_nil(entries[1].database)
    assert.equals("introspect tables", entries[1].sql)
  end)

  it("survives a JSON null name instead of starting nothing", function()
    local called = false
    browser_async.run_introspect("pg-dev", "columns", nil, vim.NIL, vim.NIL, function() called = true end)

    assert.is_nil(arg_value(async_cmd, "--database"))
    assert.is_nil(arg_value(async_cmd, "--table"))
    async_opts.on_data({ vim.json.encode({ items = {} }) })
    async_opts.on_exit(0)
    vim.wait(500, function() return called end)
    assert.is_true(called)
    flush()
  end)

  it("still passes a name that names something", function()
    browser_async.run_introspect("pg-dev", "columns", "app", "users", "blog", function() end)

    assert.equals("app", arg_value(async_cmd, "--schema"))
    assert.equals("users", arg_value(async_cmd, "--table"))
    assert.equals("blog", arg_value(async_cmd, "--database"))
    async_opts.on_exit(1)
    flush()
  end)
  after_each(function()
    package.loaded["poste-db.async"] = saved_async
    package.loaded["poste-db.connections"] = saved_connections
    package.loaded["poste-db.state"] = saved_state
    package.loaded["poste-db.db_browser.tree"] = saved_tree
  end)
end)

