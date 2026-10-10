local route = require("poste-db.introspect.route")

describe("introspect route", function()
  it("recognizes table ddl directives", function()
    assert.same({ kind = "database", db_name = "blog" }, route.resolve_table_ddl_entry("  -- @database blog"))
    assert.same({ kind = "connection", conn_name = "analytics" }, route.resolve_table_ddl_entry("-- @connection analytics"))
  end)

  it("ignores a directive that names nothing", function()
    -- an empty `-- @database   ` is a placeholder, not a target: introspecting
    -- a database called "" answered "no such database" for a name the user
    -- never wrote
    assert.is_nil(route.resolve_table_ddl_entry("-- @database   "))
    assert.is_nil(route.resolve_table_ddl_entry("-- @connection\t"))
  end)

  it("recognizes sql keywords", function()
    assert.is_true(route.is_sql_keyword("select"))
    assert.is_true(route.is_sql_keyword("SELECT"))
    assert.is_false(route.is_sql_keyword("not_a_keyword"))
  end)
end)
