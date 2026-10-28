--- Edge case tests for SQL completion.
--- Lua heuristic (detect_context / extract_from_tables) removed in P3.
--- Remaining tests cover non-heuristic paths like resolve_current_context.

local sql_comp = require("poste-db.completion")
local resolve_current_context = sql_comp._test.resolve_current_context
local conn_key = sql_comp._test.conn_key

----------------------------------------------------------------------
-- Helper
----------------------------------------------------------------------
local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

----------------------------------------------------------------------
-- resolve_current_context / conn_key edge cases
----------------------------------------------------------------------
describe("resolve_current_context / conn_key", function()
  it("nil conn_key when no connection in buffer or state", function()
    local buf = make_buf({"###", "SELECT * FROM users"})
    vim.api.nvim_set_current_buf(buf)
    local state = require("poste-db.state")
    state.context = nil
    assert.is_nil(conn_key())
  end)

  it("conn_key from state.context", function()
    local state = require("poste-db.state")
    state.context = { connection = "pg-dev", database = "blog" }
    assert.equals("pg-dev/blog", conn_key())
  end)

  it("conn_key works without database", function()
    local state = require("poste-db.state")
    state.context = { connection = "pg-dev", database = nil }
    assert.equals("pg-dev/", conn_key())
  end)

  it("resolve_context reads @connection from buffer header", function()
    local buf = make_buf({
      "-- @connection pg-ecommerce",
      "###",
      "SELECT * FROM users WHERE ",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 3, 1 })
    local ctx = resolve_current_context()
    assert.equals("pg-ecommerce", ctx.connection)
  end)

  it("resolve_context reads @database from buffer header", function()
    local buf = make_buf({
      "-- @connection pg-ecommerce",
      "-- @database analytics",
      "###",
      "SELECT * FROM users WHERE ",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 4, 1 })
    local ctx = resolve_current_context()
    assert.equals("pg-ecommerce", ctx.connection)
    assert.equals("analytics", ctx.database)
  end)
end)

----------------------------------------------------------------------
-- Directive completion (`-- @connection` / `-- @database`)
----------------------------------------------------------------------
describe("directive completion", function()
  local handlers = require("poste-db.completion.handlers")
  local data = require("poste-db.completion.data")
  local orig_conn, orig_db

  local function directives(line)
    local out
    handlers.handle_directives(line, function(items) out = items end)
    return out or {}
  end

  local function labels(items)
    local out = {}
    for _, i in ipairs(items) do out[#out + 1] = i.label end
    table.sort(out)
    return out
  end

  before_each(function()
    orig_conn, orig_db = data.ensure_conn_names, data.ensure_databases
    data.ensure_conn_names = function(cb) cb({ "pg-dev", "pg-blog" }) end
    data.ensure_databases = function(cb) cb({ "blog", "shop" }) end
  end)
  after_each(function()
    data.ensure_conn_names, data.ensure_databases = orig_conn, orig_db
  end)

  it("lists every connection for a bare `-- @connection`", function()
    -- Regression: the bare form matched `@connection$`, which has no capture,
    -- so match() handed the directive word itself back as the filter and no
    -- connection name starts with `@` — the empty list arrived exactly when
    -- the user still had to type the name.
    assert.same({ "pg-blog", "pg-dev" }, labels(directives("-- @connection")))
    assert.same({ "pg-blog", "pg-dev" }, labels(directives("-- @connection ")))
  end)

  it("keeps filtering a typed connection prefix", function()
    assert.same({ "pg-blog" }, labels(directives("-- @connection pg-bl")))
    assert.same({}, labels(directives("-- @connection zz")))
  end)

  it("lists databases for a bare `-- @database`", function()
    assert.same({ "blog", "shop" }, labels(directives("-- @database")))
    assert.same({ "blog" }, labels(directives("-- @database b")))
  end)

  it("does not fire for a word that merely starts with the directive", function()
    -- The branch check had no boundary after the directive word, so a typo
    -- like `-- @connectionX` offered every connection for a directive that
    -- does not exist.
    assert.same({}, labels(directives("-- @connectionX")))
    assert.same({}, labels(directives("-- @databaseX")))
  end)
end)
