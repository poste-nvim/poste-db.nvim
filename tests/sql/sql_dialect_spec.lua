--- dialect.lua — the single dialect resolution chain
--- (### header → connection config → g:poste_db_dialect → filetype).
--- diagnostics.lua and syntax.lua used to carry byte-identical copies and
--- source_format.resolve_dialect a fork that dropped the g:poste_db_dialect
--- step, so formatters silently ignored the user's global dialect.
local source_format = require("poste-db.source_format")

local saved_ctx = package.loaded["poste-db.context"]
local saved_conn = package.loaded["poste-db.connections"]

describe("dialect resolution chain", function()
  local buf

  after_each(function()
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.g.poste_db_dialect = nil
    package.loaded["poste-db.context"] = saved_ctx
    package.loaded["poste-db.connections"] = saved_conn
    package.loaded["poste-db.dialect"] = nil
  end)

  --- Install this test's stubs, then (re)load dialect.lua: the module binds
  --- context/connections as upvalues at load time, so stubs must be in
  --- package.loaded BEFORE the require (LEARNINGS #21).
  local function fresh_dialect(ctx_mod, conn_mod)
    package.loaded["poste-db.context"] = ctx_mod
    package.loaded["poste-db.connections"] = conn_mod
    package.loaded["poste-db.dialect"] = nil
    return require("poste-db.dialect")
  end

  local function new_buf()
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "poste_sql"
    return buf
  end

  it("the ### dialect header wins, lowercased", function()
    local buf_ = new_buf()
    vim.api.nvim_buf_set_lines(buf_, 0, -1, false, { "### dialect MySQL", "select 1" })
    local dialect = fresh_dialect(
      { resolve_context = function() return { connection = "ignored" } end },
      { get_connection_config = function() return { dialect = "postgres" } end })
    assert.equals("mysql", dialect.dialect_for_buf(buf_))
  end)

  it("the connection config decides when there is no header", function()
    local buf_ = new_buf()
    vim.api.nvim_buf_set_lines(buf_, 0, -1, false, { "select 1" })
    local dialect = fresh_dialect(
      { resolve_context = function() return { connection = "pg-main" } end },
      { get_connection_config = function() return { dialect = "Postgres" } end })
    assert.equals("postgres", dialect.dialect_for_buf(buf_))
  end)

  it("g:poste_db_dialect applies when connection and header say nothing", function()
    local buf_ = new_buf()
    vim.api.nvim_buf_set_lines(buf_, 0, -1, false, { "select 1" })
    local dialect = fresh_dialect(
      { resolve_context = function() return {} end },
      { get_connection_config = function() return nil end })
    vim.g.poste_db_dialect = "ClickHouse"
    assert.equals("clickhouse", dialect.dialect_for_buf(buf_))
  end)

  it("source_format honors g:poste_db_dialect too", function()
    -- The drift this module exists to fix: the formatter chain skipped the
    -- global option entirely and handed formatters "" (their default
    -- dialect) while diagnostics read the same option fine.
    local buf_ = new_buf()
    vim.api.nvim_buf_set_lines(buf_, 0, -1, false, { "select 1" })
    fresh_dialect(
      { resolve_context = function() return {} end },
      { get_connection_config = function() return nil end })
    vim.g.poste_db_dialect = "mysql"
    assert.equals("mysql", source_format.resolve_dialect(buf_))
  end)

  it("poste_sqlite filetype is the last fallback, else nil", function()
    local buf_ = new_buf()
    vim.api.nvim_buf_set_lines(buf_, 0, -1, false, { "select 1" })
    local dialect = fresh_dialect(
      { resolve_context = function() return {} end },
      { get_connection_config = function() return nil end })
    vim.bo[buf_].filetype = "poste_sqlite"
    assert.equals("sqlite", dialect.dialect_for_buf(buf_))

    local plain = vim.api.nvim_create_buf(false, true)
    vim.bo[plain].filetype = "markdown"
    assert.is_nil(dialect.dialect_for_buf(plain))
    vim.api.nvim_buf_delete(plain, { force = true })
  end)
end)
