local route = require("poste-db.nav.route")

describe("nav_route", function()
  it("routes connection directives", function()
    local target = route.resolve_definition_route("-- @connection analytics")
    assert.same({ kind = "connection", conn_name = "analytics" }, target)
  end)

  it("routes database directives", function()
    local target = route.resolve_definition_route("-- @database blog")
    assert.same({ kind = "database", db_name = "blog" }, target)
  end)

  it("does not route a directive that names nothing", function()
    -- `gd` on `-- @connection   ` used to ask for the definition of a
    -- connection whose name is the empty string; the line declares no target,
    -- so the call falls through to the word under the cursor (none here).
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    vim.api.nvim_set_current_buf(buf)

    assert.is_nil(route.resolve_definition_route("-- @connection   "))
    assert.is_nil(route.resolve_definition_route("-- @database\t"))
  end)

  it("routes table words when a connection context exists", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "authors" })
    vim.api.nvim_set_current_buf(buf)

    local target = route.resolve_definition_route("authors")
    assert.same({ kind = "table", table_name = "authors" }, target)
  end)

  it("returns nil with no word under the cursor", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    vim.api.nvim_set_current_buf(buf)

    assert.is_nil(route.resolve_definition_route(""))
  end)
end)
