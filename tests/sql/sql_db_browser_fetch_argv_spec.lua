--- Browser fetch commands carry the names of the node under the cursor.
---
--- Those names arrive straight out of a listing row, where `""` means "this
--- connection's own database" and a JSON null decodes to vim.NIL — both
--- truthy, so both used to be handed to the binary. `--database` is applied
--- as replace_database_in_url, so the fetch read whichever database the
--- stripped URL pointed at rather than the one the user clicked, and a
--- lightuserdata in the argv raised on the way out (the journal line and
--- log.redact_cmd both concatenate).

local saved_cli = package.loaded["poste-db.cli"]
local saved_connections = package.loaded["poste-db.connections"]

package.loaded["poste-db.connections"] = {
  resolve_connection_url = function() return "pg://u:pw@h/blog" end,
}

local cli_stub = { run_async = function() return 1 end, binary = function() return "/fake/poste" end }
package.loaded["poste-db.cli"] = cli_stub

local actions = require("poste-db.db_browser.actions")
local copy = require("poste-db.db_browser.copy")
local icons = require("poste-db.db_browser.icons")
local HEADER_LINES = icons.HEADER_LINES

local cmd

local function capture_async(c, _opts)
  cmd = c
  return 1
end

local function arg_value(flag)
  for i, v in ipairs(cmd or {}) do
    if v == flag then return cmd[i + 1] end
  end
  return nil
end

local function table_node(meta)
  return { node_type = "table", name = "users", meta = meta }
end

--- A table row at line HEADER_LINES + 1 of the browser view.
local function context_for(node)
  return { line_to_node = { [1] = node }, root_nodes = {} }
end

local real_notify = vim.notify

local function stub_notify() vim.notify = function() end end
local function restore_notify() vim.notify = real_notify end

-- The modules keep a reference to cli_stub from require time, so its fields
-- are what a test overrides; installing the table itself keeps the stub honest
-- for anything required later in the file.
local function install_stubs()
  package.loaded["poste-db.cli"] = cli_stub
  package.loaded["poste-db.connections"] = {
    resolve_connection_url = function() return "pg://u:pw@h/blog" end,
  }
end
local function uninstall_stubs()
  package.loaded["poste-db.cli"] = saved_cli
  package.loaded["poste-db.connections"] = saved_connections
end

describe("db_browser actions show_table_info", function()
  before_each(function()
    cmd = nil
    install_stubs()
    cli_stub.run_async = capture_async
    stub_notify()
  end)
  after_each(function()
    cli_stub.run_async = function() return 1 end
    restore_notify()
    uninstall_stubs()
  end)

  it("omits a database the node does not name", function()
    actions.show_table_info(HEADER_LINES + 1, context_for(table_node({
      connection = "pg-dev", schema = "app", database = "",
    })))
    assert.equals("users", arg_value("--table"))
    assert.equals("app", arg_value("--schema"))
    assert.is_nil(arg_value("--database"))
  end)

  it("omits a JSON null schema instead of raising", function()
    actions.show_table_info(HEADER_LINES + 1, context_for(table_node({
      connection = "pg-dev", schema = vim.NIL, database = vim.NIL,
    })))
    assert.is_nil(arg_value("--schema"))
    assert.is_nil(arg_value("--database"))
  end)

  it("still names the schema and database a node has", function()
    actions.show_table_info(HEADER_LINES + 1, context_for(table_node({
      connection = "pg-dev", dialect = "postgres", schema = "app", database = "blog",
    })))
    assert.equals("app", arg_value("--schema"))
    assert.equals("blog", arg_value("--database"))
  end)
end)

describe("db_browser copy introspect_ddl", function()
  local real_jobstart
  before_each(function()
    cmd = nil
    install_stubs()
    real_jobstart = vim.fn.jobstart
    vim.fn.jobstart = function(args, _opts)
      cmd = args
      return 1
    end
    stub_notify()
  end)
  after_each(function()
    vim.fn.jobstart = real_jobstart
    restore_notify()
    package.loaded["poste-db.cli"] = saved_cli
    package.loaded["poste-db.connections"] = saved_connections
  end)

  local function ddl_args(db)
    copy._test.introspect_ddl("pg-dev", db, "users", function() end, function() end)
  end

  it("omits an unnamed source database instead of truncating the argv", function()
    ddl_args("")
    assert.equals("users", arg_value("--table"))
    assert.is_nil(arg_value("--database"))

    -- and a nil used to leave a hole in the table constructor, so the command
    -- ended with a bare `--database` flag and no value for clap to read
    ddl_args(nil)
    assert.equals("users", arg_value("--table"))
    assert.is_nil(arg_value("--database"))
    assert.is_not.equal("--database", cmd[#cmd])
  end)

  it("keeps a JSON null out of the command", function()
    ddl_args(vim.NIL)
    assert.equals("users", arg_value("--table"))
    assert.is_nil(arg_value("--database"))
  end)

  it("still passes the database the source node names", function()
    ddl_args("blog")
    assert.equals("blog", arg_value("--database"))
  end)

  it("passes the source schema on --schema", function()
    -- The binary's postgres DDL arm defaults to `public` without --schema:
    -- the yanked `app.events` fetched public.events's DDL — a same-named
    -- public table was silently recreated and copied in its place, and
    -- without one the paste errored "No DDL found".
    copy._test.introspect_ddl("pg-dev", "blog", "events", function() end, function() end, "app")
    assert.equals("app", arg_value("--schema"))
    assert.equals("events", arg_value("--table"))
  end)

  it("omits --schema when the source carries none", function()
    copy._test.introspect_ddl("pg-dev", "blog", "events", function() end, function() end, nil)
    assert.is_nil(arg_value("--schema"))
    copy._test.introspect_ddl("pg-dev", "blog", "events", function() end, function() end, "")
    assert.is_nil(arg_value("--schema"))
    copy._test.introspect_ddl("pg-dev", "blog", "events", function() end, function() end, vim.NIL)
    assert.is_nil(arg_value("--schema"))
  end)
end)
