local saved_poste_util = package.loaded["poste-db.util"]
-- util is a leaf module (no requires, no side effects), so the fallback is
-- the real thing — a hand-rolled fake here went stale the moment
-- nav/detect started calling util.unquote_ident.
package.loaded["poste-db.util"] = saved_poste_util or require("poste-db.util")

local nav = require("poste-db.nav")

describe("nav.goto_definition", function()
  local saved_modules = {}

  local function stub_module(name, mod)
    if saved_modules[name] == nil then
      saved_modules[name] = package.loaded[name]
    end
    package.loaded[name] = mod
  end

  local function make_buf(lines, name)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    if name then
      vim.api.nvim_buf_set_name(buf, name)
    end
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  after_each(function()
    for name, mod in pairs(saved_modules) do
      package.loaded[name] = mod
    end
    saved_modules = {}
    package.loaded["poste-db.util"] = saved_poste_util
  end)

  it("jumps to the matching connection entry in connections.toml", function()
    local function normalize_path(path)
      return (path or ""):gsub("^/private", "")
    end
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local config_path = tmpdir .. "/connections.toml"
    vim.o.swapfile = false
    vim.fn.writefile({
      "[other]",
      "dialect = \"sqlite\"",
      "",
      "[analytics]",
      "dialect = \"postgres\"",
    }, config_path)

    stub_module("poste-db.connections", {
      find_connections_toml = function()
        return config_path
      end,
    })

    local buf = make_buf({
      "-- @connection analytics",
      "select 1",
    }, tmpdir .. "/query.sql")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    nav.goto_definition()

    assert.equals(normalize_path(config_path), normalize_path(vim.api.nvim_buf_get_name(0)))
    assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])
    assert.equals("[analytics]", vim.api.nvim_buf_get_lines(0, 3, 4, false)[1])
    assert.is_not_nil(buf)
  end)

  it("delegates @database jumps to db_browser.navigate_to", function()
    local record = {}

    stub_module("poste-db.context", {
      resolve_full_context = function()
        return { connection = "conn" }
      end,
    })
    stub_module("poste-db.db_browser", {
      navigate_to = function(conn, db)
        record.conn = conn
        record.db = db
      end,
    })

    make_buf({ "-- @database blog" }, vim.fn.tempname() .. ".sql")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    nav.goto_definition()

    assert.same({ conn = "conn", db = "blog" }, record)
  end)

  it("navigates table words through db_browser.navigate_to_table when no binary is available", function()
    local record = {}

    stub_module("poste-db.context", {
      resolve_full_context = function()
        return { connection = "conn", database = "blog" }
      end,
    })
    stub_module("poste-db.completion.data", {
      find_binary = function()
        return nil
      end,
    })
    stub_module("poste-db.db_browser", {
      navigate_to_table = function(conn, db, tbl, col)
        record.conn = conn
        record.db = db
        record.tbl = tbl
        record.col = col
      end,
    })

    make_buf({ "authors" }, vim.fn.tempname() .. ".sql")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    nav.goto_definition()

    assert.same({ conn = "conn", db = "blog", tbl = "authors", col = nil }, record)
  end)
end)

describe("nav._test.resolve_detected_table_target", function()
  it("resolves dot_column aliases to a table target", function()
    local target = nav._test.resolve_detected_table_target({
      ctx_type = "dot_column",
      ctx_data = "p",
      tables = {
        { name = "posts", alias = "p" },
      },
    }, "p.title", 1, "title", {
      connection = "conn",
      database = "blog",
    })

    assert.same({
      action = "navigate_to_table",
      database = "blog",
      table_name = "posts",
      column_name = "title",
    }, target)
  end)

  it("resolves schema_table to a table target carrying its prefix", function()
    -- BEHAVIOR CHANGE (2026-11-02 audit): the prefix used to fold into
    -- `database`, which for postgres sent `gd` to "Database 'blog' not
    -- found". It rides on `schema` now, with the context database kept;
    -- nav/handlers reads it as a database only for MySQL-style dialects.
    -- (introspect/context.lua made the same change on 2026-10-30.)
    local target = nav._test.resolve_detected_table_target({
      ctx_type = "schema_table",
      ctx_data = "blog",
      tables = {
        { name = "authors" },
      },
    }, "authors", 7, "authors", {
      connection = "conn",
      database = nil,
    })

    assert.same({
      action = "navigate_to_table",
      database = nil,
      schema = "blog",
      table_name = "authors",
      column_name = nil,
    }, target)
  end)

  it("resolves schema matches to a direct database navigation", function()
    local target = nav._test.resolve_detected_table_target({
      ctx_type = "table",
      tables = {
        { name = "authors", schema = "blog" },
      },
    }, "blog", 4, "blog", {
      connection = "conn",
      database = nil,
    })

    assert.same({
      action = "navigate_to",
      connection = "conn",
      database = "blog",
    }, target)
  end)
end)
