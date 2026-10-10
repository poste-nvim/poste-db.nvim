local saved_state = package.loaded["poste-db.state"]
local saved_select = package.loaded["poste-db.select"]
local saved_const = package.loaded["poste-db.constants"]
local saved_connections = package.loaded["poste-db.connections"]

local state_stub = { context = { connection = nil, database = nil }, log = function() end }

package.loaded["poste-db.connections"] = {
  get_connection_config = function(name)
    return { database = "default_db" }
  end,
}
package.loaded["poste-db.state"] = state_stub
package.loaded["poste-db.select"] = { select = function() end }

local context = require("poste-db.context")

describe("context resolve_context", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  after_each(function()
    package.loaded["poste-db.state"] = state_stub
    state_stub.context = { connection = nil, database = nil }
  end)

  it("returns nil for empty buffer", function()
    local buf = make_buf({})
    local ctx = context.resolve_context(buf, 1)
    assert.same({ connection = nil, database = nil }, ctx)
  end)

  it("reads @connection from file header", function()
    local buf = make_buf({ "-- @connection analytics", "select 1" })
    local ctx = context.resolve_context(buf, 2)
    assert.equals("analytics", ctx.connection)
    assert.is_nil(ctx.database)
  end)

  it("reads @database from file header", function()
    local buf = make_buf({ "-- @connection analytics", "-- @database blog", "select 1" })
    local ctx = context.resolve_context(buf, 3)
    assert.equals("analytics", ctx.connection)
    assert.equals("blog", ctx.database)
  end)

  it("header scan stops at ### marker but block-level scan still reads overrides", function()
    local buf = make_buf({ "-- @connection analytics", "###", "-- @connection other", "select 1" })
    local ctx = context.resolve_context(buf, 4)
    assert.equals("other", ctx.connection)
  end)

  it("reads USE statement before cursor", function()
    local buf = make_buf({ "use blog", "select 1" })
    local ctx = context.resolve_context(buf, 1)
    assert.equals("blog", ctx.database)
  end)

  it("reads USE statement with quotes", function()
    local buf = make_buf({ "use `my-db`", "select 1" })
    local ctx = context.resolve_context(buf, 1)
    assert.equals("my-db", ctx.database)
  end)

  it("last USE statement before cursor wins", function()
    local buf = make_buf({ "use blog", "select 1", "use analytics", "select 2" })
    local ctx = context.resolve_context(buf, 3)
    assert.equals("analytics", ctx.database)
  end)

  it("block-level @connection overrides file header", function()
    local buf = make_buf({ "-- @connection analytics", "###", "-- @connection blog", "select 1" })
    local ctx = context.resolve_context(buf, 4)
    assert.equals("blog", ctx.connection)
  end)

  -- A commented-out `USE` still switched the database: the scanner read each
  -- line in isolation and block comments are invisible to it. Sending the
  -- statement under the cursor to that database is the wrong-answer class.
  it("ignores a USE inside a multi-line block comment", function()
    local buf = make_buf({
      "use blog",
      "/*",
      "use analytics",
      "*/",
      "select 1",
    })
    local ctx = context.resolve_context(buf, 5)
    assert.equals("blog", ctx.database)
  end)

  it("ignores a block-commented directive in the header", function()
    local buf = make_buf({ "/*", "-- @connection analytics", "*/", "select 1" })
    local ctx = context.resolve_context(buf, 4)
    assert.is_nil(ctx.connection)
  end)

  it("resumes reading after a block comment closes", function()
    local buf = make_buf({
      "/* hidden */",
      "use blog",
      "select 1",
    })
    local ctx = context.resolve_context(buf, 3)
    assert.equals("blog", ctx.database)
  end)

  it("still reads directives inside line comments", function()
    local buf = make_buf({ "-- @connection analytics", "select 1" })
    local ctx = context.resolve_context(buf, 2)
    assert.equals("analytics", ctx.connection)
  end)

  it("a directive that names nothing declares nothing", function()
    -- `-- @database   ` (blanks after the word — a placeholder line an editor
    -- left untrimmed) matched `%s+(.+)` and `vim.trim` emptied the capture, so
    -- the block ran against the server's default database while the file said
    -- `blog`. The CLI skips such a line (extract_connection_directive trims and
    -- tests for empty), and the editor now reads the same file the same way.
    local buf = make_buf({
      "-- @connection analytics", "-- @database blog", "###",
      "-- @database   ", "select 1",
    })
    local ctx = context.resolve_context(buf, 5)
    assert.equals("analytics", ctx.connection)
    assert.equals("blog", ctx.database)
  end)

  it("a nameless block-level @connection keeps the file-level one", function()
    local buf = make_buf({
      "-- @connection analytics", "###", "-- @connection \t", "select 1",
    })
    local ctx = context.resolve_context(buf, 4)
    assert.equals("analytics", ctx.connection)
  end)
end)

describe("context get_status_text", function()
  before_each(function()
    package.loaded["poste-db.state"] = state_stub
    state_stub.context = { connection = nil, database = nil }
  end)

  after_each(function()
    package.loaded["poste-db.state"] = state_stub
  end)

  it("returns empty string when no conn or db", function()
    assert.equals("", context.get_status_text())
  end)

  it("returns [db: conn/db] when both present", function()
    state_stub.context.connection = "analytics"
    state_stub.context.database = "blog"
    assert.equals("[db: analytics/blog]", context.get_status_text())
  end)

  it("returns [db: conn] when only connection", function()
    state_stub.context.connection = "analytics"
    assert.equals("[db: analytics]", context.get_status_text())
  end)

  it("returns [db: ?/db] when only database", function()
    state_stub.context.database = "blog"
    assert.equals("[db: ?/blog]", context.get_status_text())
  end)
end)

describe("context get_cursor_status_text", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  before_each(function()
    package.loaded["poste-db.state"] = state_stub
    package.loaded["poste-db.connections"] = {
      get_connection_config = function(name)
        return { database = "default_db" }
      end,
    }
  end)

  it("returns empty string when no connection", function()
    local buf = make_buf({ "select 1" })
    assert.equals("", context.get_cursor_status_text(buf))
  end)

  it("returns connection/db from resolve_full_context", function()
    local buf = make_buf({ "-- @connection analytics", "-- @database blog", "select 1" })
    assert.equals("analytics/blog", context.get_cursor_status_text(buf))
  end)

  it("falls back to connections config database when no @database directive", function()
    local buf = make_buf({ "-- @connection analytics", "select 1" })
    local text = context.get_cursor_status_text(buf)
    assert.matches("analytics", text)
  end)
end)

describe("context resolve_full_context", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  before_each(function()
    state_stub.context = { connection = nil, database = nil }
  end)
  after_each(function()
    state_stub.context = { connection = nil, database = nil }
  end)

  it("a nameless block directive does not mask the runtime connection", function()
    -- :PosteDbConnection chose this connection; the placeholder directive line
    -- names nothing, so it must not clear the choice — with an empty string
    -- there the statement ran on whatever the server considered default.
    state_stub.context.connection = "runtime-conn"
    local buf = make_buf({ "###", "-- @connection   ", "select 1" })
    local full = context.resolve_full_context(buf, 3)
    assert.equals("runtime-conn", full.connection)
  end)
end)

describe("context handle_use_statement", function()
  before_each(function()
    state_stub.context = { connection = nil, database = nil }
  end)

  it("does nothing for nil response", function()
    context.handle_use_statement(nil)
    assert.is_nil(state_stub.context.database)
  end)

  it("does nothing for response without body", function()
    context.handle_use_statement({})
    assert.is_nil(state_stub.context.database)
  end)

  it("updates database from USE response", function()
    context.handle_use_statement({
      body = vim.json.encode({ type = "use", database_name = "blog" }),
    })
    assert.equals("blog", state_stub.context.database)
  end)

  after_each(function()
    package.loaded["poste-db.state"] = saved_state
    package.loaded["poste-db.select"] = saved_select
    package.loaded["poste-db.constants"] = saved_const
    package.loaded["poste-db.connections"] = saved_connections
  end)
end)


describe("context.detect_command", function()
  it("builds the bare detect argv and the dialect flag", function()
    assert.same({ "poste", "context", "detect", "12" }, context.detect_command("poste", 12, nil))
    assert.same({ "poste", "context", "detect", "12" }, context.detect_command("poste", 12, ""))
    -- generic is the binary's default; spelling it out buys nothing
    assert.same({ "poste", "context", "detect", "12" }, context.detect_command("poste", 12, "generic"))
    assert.same({ "poste", "context", "detect", "12", "--dialect", "mysql" },
      context.detect_command("poste", 12, "mysql"))
  end)
end)
