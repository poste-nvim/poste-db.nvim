local saved_connections = package.loaded["poste-db.connections"]
local saved_exec = package.loaded["poste-db.introspect.exec"]
local saved_ui = package.loaded["poste-db.introspect.ui"]

local connections_stub = {}
local exec_stub = {}
local ui_stub = {}

package.loaded["poste-db.connections"] = connections_stub
package.loaded["poste-db.introspect.exec"] = exec_stub
package.loaded["poste-db.introspect.ui"] = ui_stub

local helper = require("poste-db.introspect.table")

describe("introspect table helper", function()
  local saved_notify = vim.notify

  before_each(function()
    package.loaded["poste-db.connections"] = connections_stub
    package.loaded["poste-db.introspect.exec"] = exec_stub
    package.loaded["poste-db.introspect.ui"] = ui_stub
  end)

  after_each(function()
    vim.notify = saved_notify
    package.loaded["poste-db.connections"] = saved_connections
    package.loaded["poste-db.introspect.exec"] = saved_exec
    package.loaded["poste-db.introspect.ui"] = saved_ui
  end)

  it("lists tables for a database", function()
    local captured = nil
    local seen = nil
    connections_stub.resolve_connection_url = function(conn)
      assert.equals("primary", conn)
      return "postgres://user@localhost/blog", nil
    end
    exec_stub.run_json_items_job = function(args, opts)
      captured = { args = args, opts = opts }
      opts.on_items({ { name = "authors", type = "table" } })
    end
    ui_stub.show_table_list = function(items, db_name, show_float)
      seen = { items = items, db_name = db_name, show_float = show_float }
    end

    local show_float = function() end
    helper.show_database_tables("primary", "blog", show_float)

    assert.same({
      "introspect",
      "--connection-url",
      "postgres://user@localhost/blog",
      "--type",
      "tables",
      "--database",
      "blog",
    }, captured.args)
    assert.equals("Table listing", captured.opts.exit_kind)
    assert.same({
      items = { { name = "authors", type = "table" } },
      db_name = "blog",
      show_float = show_float,
    }, seen)
  end)

  it("shows ddl for a table", function()
    local captured = nil
    local seen = nil
    connections_stub.resolve_connection_url = function()
      return "postgres://user@localhost/blog", nil
    end
    exec_stub.run_json_items_job = function(args, opts)
      captured = { args = args, opts = opts }
      opts.on_items({ { ddl = "CREATE TABLE authors (...);" } })
    end
    ui_stub.show_ddl = function(items, cword, show_float)
      seen = { items = items, cword = cword, show_float = show_float }
    end

    local show_float = function() end
    helper.show_table_ddl("primary", "blog", "authors", show_float)

    assert.same({
      "introspect",
      "--connection-url",
      "postgres://user@localhost/blog",
      "--type",
      "ddl",
      "--table",
      "authors",
      "--database",
      "blog",
    }, captured.args)
    assert.equals("DDL introspection", captured.opts.exit_kind)
    assert.same({
      items = { { ddl = "CREATE TABLE authors (...);" } },
      cword = "authors",
      show_float = show_float,
    }, seen)
  end)

  it("passes a postgres schema on --schema, keeping the real context database", function()
    -- The old shape folded the schema into --database, which the CLI applies
    -- as replace_database_in_url — gd on `blog.authors` connected to a
    -- database NAMED blog instead of introspecting schema blog.
    local captured = nil
    connections_stub.resolve_connection_url = function()
      return "postgres://user@localhost/appdb", nil
    end
    connections_stub.get_connection_config = function()
      return { dialect = "postgres" }
    end
    exec_stub.run_json_items_job = function(args, opts)
      captured = { args = args }
      opts.on_items({})
    end
    ui_stub.show_ddl = function() end

    helper.show_table_ddl("primary", "appdb", "authors", function() end, "blog")

    assert.same({
      "introspect",
      "--connection-url",
      "postgres://user@localhost/appdb",
      "--type",
      "ddl",
      "--table",
      "authors",
      "--schema",
      "blog",
      "--database",
      "appdb",
    }, captured.args)
  end)

  it("maps a mysql schema onto --database (a schema IS a database there)", function()
    local captured = nil
    connections_stub.resolve_connection_url = function()
      return "mysql://user@localhost/appdb", nil
    end
    connections_stub.get_connection_config = function()
      return { dialect = "mysql" }
    end
    exec_stub.run_json_items_job = function(args, opts)
      captured = { args = args }
      opts.on_items({})
    end
    ui_stub.show_ddl = function() end

    helper.show_table_ddl("primary", "appdb", "authors", function() end, "blog")

    assert.same({
      "introspect",
      "--connection-url",
      "mysql://user@localhost/appdb",
      "--type",
      "ddl",
      "--table",
      "authors",
      "--database",
      "blog",
    }, captured.args)
  end)
end)
