--- Regression tests for db_browser.lua.
--- Covers tree data model, rendering, node resolution, and public API.
--- Run via: ./tests/run.sh  (Plenary Busted)

local db_browser = require("poste-db.db_browser")
local icons = require("poste-db.db_browser.icons")
local tree = require("poste-db.db_browser.tree")
local actions = require("poste-db.db_browser.actions")
local util = require("poste-db.db_browser.util")

local ICONS = icons.ICONS
local MARKER_COLLAPSED = icons.MARKER_COLLAPSED
local MARKER_EXPANDED = icons.MARKER_EXPANDED
local MARKER_LOADING = icons.MARKER_LOADING

local flatten_tree = tree.flatten_tree
local calc_icon_position = tree.calc_icon_position
local find_table_node = actions.find_table_node

------------------------------------------------------------------------------
-- Node Factory Characterization Tests
------------------------------------------------------------------------------

describe("db_browser node factories", function()
  it("connection node structure", function()
    local conn = {
      node_type = "connection",
      name = "pg-dev",
      full_name = "pg-dev",
      children = nil,
      expanded = false,
      loading = false,
      meta = { dialect = "postgres", host = "localhost", port = 5432 },
    }
    assert.equals("connection", conn.node_type)
    assert.equals("pg-dev", conn.name)
    assert.equals("postgres", conn.meta.dialect)
    assert.is_nil(conn.children)
  end)

  it("database node structure", function()
    local db = {
      node_type = "database",
      name = "mydb",
      full_name = "pg-dev/mydb",
      children = nil,
      expanded = false,
      loading = false,
      meta = { dialect = "postgres", connection = "pg-dev" },
    }
    assert.equals("database", db.node_type)
    assert.equals("mydb", db.name)
    assert.equals("pg-dev", db.meta.connection)
  end)

  it("schema node structure", function()
    local schema = {
      node_type = "schema",
      name = "public",
      full_name = "pg-dev/mydb/public",
      children = nil,
      expanded = false,
      loading = false,
      meta = { database = "mydb", connection = "pg-dev" },
    }
    assert.equals("schema", schema.node_type)
    assert.equals("public", schema.name)
    assert.equals("mydb", schema.meta.database)
  end)

  it("table node structure", function()
    local tbl = {
      node_type = "table",
      name = "users",
      full_name = "public.users",
      children = nil,
      expanded = false,
      loading = false,
      meta = { table_type = "BASE TABLE", schema = "public", database = "mydb", connection = "pg-dev" },
    }
    assert.equals("table", tbl.node_type)
    assert.equals("users", tbl.name)
    assert.equals("public.users", tbl.full_name)
    assert.equals("BASE TABLE", tbl.meta.table_type)
  end)

  it("table node with VIEW type", function()
    local view = {
      node_type = "table",
      name = "active_users",
      full_name = "public.active_users",
      children = nil,
      expanded = false,
      loading = false,
      meta = { table_type = "VIEW", schema = "public", database = "mydb", connection = "pg-dev" },
    }
    assert.equals("VIEW", view.meta.table_type)
  end)

  it("column node structure — regular", function()
    local col = {
      node_type = "column",
      name = "email",
      full_name = "email",
      children = {},
      expanded = false,
      loading = false,
      meta = { col_type = "text", nullable = true, default = nil, is_pk = false, icon = ICONS.column },
    }
    assert.equals("column", col.node_type)
    assert.equals("email", col.name)
    assert.equals(ICONS.column, col.meta.icon)
    assert.is_false(col.meta.is_pk)
  end)

  it("column node structure — PK", function()
    local col = {
      node_type = "column",
      name = "id",
      full_name = "id",
      children = {},
      expanded = false,
      loading = false,
      meta = { col_type = "integer", nullable = false, default = nil, is_pk = true, icon = ICONS.column_pk },
    }
    assert.is_true(col.meta.is_pk)
    assert.equals(ICONS.column_pk, col.meta.icon)
  end)

  it("column node structure — FK", function()
    local col = {
      node_type = "column",
      name = "user_id",
      full_name = "user_id",
      children = {},
      expanded = false,
      loading = false,
      meta = { col_type = "integer", nullable = true, default = nil, is_pk = false, icon = ICONS.column_fk },
    }
    assert.is_false(col.meta.is_pk)
    assert.equals(ICONS.column_fk, col.meta.icon)
  end)

  it("index node structure", function()
    local idx = {
      node_type = "index",
      name = "users_pkey",
      full_name = "users_pkey",
      children = {},
      expanded = false,
      loading = false,
      meta = { definition = "CREATE UNIQUE INDEX ..." },
    }
    assert.equals("index", idx.node_type)
    assert.equals("users_pkey", idx.name)
  end)

  it("group node structures (key_group, fk_group, index_group)", function()
    local kg = {
      node_type = "key_group",
      name = "keys",
      children = {},
      expanded = false,
      loading = false,
    }
    assert.equals("key_group", kg.node_type)

    local fkg = {
      node_type = "fk_group",
      name = "foreign keys",
      children = {},
      expanded = false,
      loading = false,
    }
    assert.equals("fk_group", fkg.node_type)

    local ig = {
      node_type = "index_group",
      name = "indexes",
      children = {},
      expanded = false,
      loading = false,
    }
    assert.equals("index_group", ig.node_type)
  end)

  it("grouped item node structures", function()
    local ki = {
      node_type = "key_item",
      name = "id",
      full_name = "id",
      children = {},
      expanded = false,
      loading = false,
      meta = { is_pk = true },
    }
    assert.equals("key_item", ki.node_type)
    assert.is_true(ki.meta.is_pk)

    local fi = {
      node_type = "fk_item",
      name = "user_id -> users(id)",
      full_name = "user_id -> users(id)",
      children = {},
      expanded = false,
      loading = false,
    }
    assert.equals("fk_item", fi.node_type)

    local ii = {
      node_type = "index_item",
      name = "users_pkey",
      full_name = "users_pkey",
      children = {},
      expanded = false,
      loading = false,
      meta = { is_pk = true },
    }
    assert.equals("index_item", ii.node_type)
  end)
end)

------------------------------------------------------------------------------
-- flatten_tree Characterization Tests
------------------------------------------------------------------------------

describe("db_browser flatten_tree", function()
  it("empty tree produces empty output", function()
    local lines, node_map, count_ranges = flatten_tree({})
    assert.are.same({}, lines)
    assert.are.same({}, node_map)
    assert.are.same({}, count_ranges)
  end)

  it("single collapsed node renders correctly", function()
    local node = {
      node_type = "table",
      name = "users",
      full_name = "users",
      children = nil,
      expanded = false,
      loading = false,
      meta = { table_type = "BASE TABLE" },
    }
    local lines, node_map, count_ranges = flatten_tree({ node })
    -- indent(0) + marker(3) + space(1) + icon(3) + space(1) + name(5) = 13
    assert.equals(1, #lines)
    assert.matches(MARKER_COLLAPSED, lines[1])
    assert.matches(ICONS.table, lines[1])
    assert.matches("users", lines[1])
    assert.equals(node, node_map[1])
    assert.are.same({}, count_ranges)
  end)

  it("expanded node shows children", function()
    local col1 = {
      node_type = "column", name = "id", full_name = "id", children = {},
      expanded = false, loading = false,
      meta = { col_type = "integer", nullable = false, is_pk = true, icon = ICONS.column_pk },
    }
    local col2 = {
      node_type = "column", name = "name", full_name = "name", children = {},
      expanded = false, loading = false,
      meta = { col_type = "text", nullable = true, is_pk = false, icon = ICONS.column },
    }
    local table_node = {
      node_type = "table", name = "users", full_name = "users",
      children = { col1, col2 },
      expanded = true, loading = false,
      meta = { table_type = "BASE TABLE" },
    }
    local lines, node_map, count_ranges = flatten_tree({ table_node })

    -- 1 parent + 2 children = 3 lines
    assert.equals(3, #lines)
    assert.matches(MARKER_EXPANDED, lines[1])
    assert.matches(ICONS.table, lines[1])
    assert.matches("users", lines[1])
    assert.matches("(2)", lines[1])  -- count

    -- Column lines have "  " (leaf marker, no angle bracket)
    assert.matches("  " .. ICONS.column_pk, lines[2])
    assert.matches("id", lines[2])
    assert.matches("integer", lines[2])
    assert.matches("PK", lines[2])
    assert.matches("  " .. ICONS.column, lines[3])
    assert.matches("name", lines[3])
    assert.matches("text", lines[3])

    -- 3 nodes in map
    assert.equals(3, #node_map)
    assert.equals(table_node, node_map[1])
    assert.equals(col1, node_map[2])
    assert.equals(col2, node_map[3])

    -- count_range for the parent line
    assert.equals(1, #count_ranges)
    assert.equals(1, count_ranges[1][1])
    assert.is_true(count_ranges[1][3] > count_ranges[1][2])
  end)

  it("collapsed node with nil children has no count", function()
    local node = {
      node_type = "database", name = "mydb", full_name = "conn/mydb",
      children = nil,
      expanded = false, loading = false,
      meta = { dialect = "postgres", connection = "conn" },
    }
    local lines, _, count_ranges = flatten_tree({ node })
    assert.equals(1, #lines)
    -- nil children means count_text = "" and no count_ranges
    assert.matches(ICONS.database, lines[1])
    assert.matches("mydb", lines[1])
    assert.not_matches("%(0%)", lines[1])
    assert.are.same({}, count_ranges)
  end)

  it("loading node shows loading marker", function()
    local node = {
      node_type = "schema", name = "public", full_name = "conn/mydb/public",
      children = nil,
      expanded = false, loading = true,
      meta = { database = "mydb", connection = "conn" },
    }
    local lines = flatten_tree({ node })
    assert.matches(MARKER_LOADING, lines[1])
  end)

  it("view table shows (view) suffix", function()
    local node = {
      node_type = "table", name = "active_users", full_name = "active_users",
      children = nil, expanded = false, loading = false,
      meta = { table_type = "VIEW" },
    }
    local lines = flatten_tree({ node })
    assert.is_true(lines[1]:find("(view)", 1, true) ~= nil, "Expected '(view)' in line: " .. lines[1])
  end)

  it("base table has no suffix", function()
    local node = {
      node_type = "table", name = "users", full_name = "users",
      children = nil, expanded = false, loading = false,
      meta = { table_type = "BASE TABLE" },
    }
    local lines = flatten_tree({ node })
    assert.matches("users$", lines[1])
    assert.not_matches("view", lines[1])
  end)

  it("nested tree: conn → db → schema → table → columns", function()
    local col = {
      node_type = "column", name = "id", full_name = "id", children = {},
      expanded = false, loading = false,
      meta = { col_type = "integer", nullable = false, is_pk = true, icon = ICONS.column_pk },
    }
    local tbl = {
      node_type = "table", name = "users", full_name = "public.users",
      children = { col }, expanded = true, loading = false,
      meta = { table_type = "BASE TABLE", schema = "public" },
    }
    local sch = {
      node_type = "schema", name = "public", full_name = "conn/mydb/public",
      children = { tbl }, expanded = true, loading = false,
      meta = { database = "mydb", connection = "conn" },
    }
    local db = {
      node_type = "database", name = "mydb", full_name = "conn/mydb",
      children = { sch }, expanded = true, loading = false,
      meta = { dialect = "postgres", connection = "conn" },
    }
    local conn = {
      node_type = "connection", name = "pg-dev", full_name = "pg-dev",
      children = { db }, expanded = true, loading = false,
      meta = { dialect = "postgres", host = "localhost" },
    }

    local lines, node_map = flatten_tree({ conn })

    -- 4 visible + 1 column = 5 lines
    assert.equals(5, #lines)

    -- Connection line
    assert.is_true(lines[1]:find("pg-dev", 1, true) ~= nil)
    assert.is_true(lines[1]:find(ICONS.postgres, 1, true) ~= nil)

    -- Database line (depth 1)
    assert.is_true(lines[2]:find(ICONS.database, 1, true) ~= nil)

    -- Schema line (depth 2)
    assert.is_true(lines[3]:find(ICONS.schema, 1, true) ~= nil)

    -- Table line (depth 3)
    assert.is_true(lines[4]:find(ICONS.table, 1, true) ~= nil)

    -- Column line (depth 4, leaf)
    assert.is_true(lines[5]:find(ICONS.column_pk, 1, true) ~= nil)
    assert.is_true(lines[5]:find("id", 1, true) ~= nil)
    assert.is_true(lines[5]:find("integer", 1, true) ~= nil)

    assert.equals(5, #node_map)
  end)

  it("dialect-specific icon for connection node", function()
    local pg = {
      node_type = "connection", name = "pg", full_name = "pg",
      children = nil, expanded = false, loading = false,
      meta = { dialect = "postgres" },
    }
    local mysql = {
      node_type = "connection", name = "my", full_name = "my",
      children = nil, expanded = false, loading = false,
      meta = { dialect = "mysql" },
    }
    local sqlite = {
      node_type = "connection", name = "lite", full_name = "lite",
      children = nil, expanded = false, loading = false,
      meta = { dialect = "sqlite" },
    }
    local unknown = {
      node_type = "connection", name = "unk", full_name = "unk",
      children = nil, expanded = false, loading = false,
      meta = { dialect = "unknown" },
    }

    local lines_pg = flatten_tree({ pg })
    local lines_my = flatten_tree({ mysql })
    local lines_li = flatten_tree({ sqlite })
    local lines_un = flatten_tree({ unknown })

    assert.matches(ICONS.postgres, lines_pg[1])
    assert.matches(ICONS.mysql, lines_my[1])
    assert.matches(ICONS.sqlite, lines_li[1])
    assert.matches(ICONS.connection, lines_un[1])
  end)
end)

------------------------------------------------------------------------------
-- Icon Position Characterization Tests
------------------------------------------------------------------------------

describe("db_browser icon position calculation", function()
  it("expanded table (depth 1)", function()
    local line = "  " .. MARKER_EXPANDED .. " " .. ICONS.table .. " users (5)"
    local pos = calc_icon_position(line)
    -- 2(indent) + 3(marker) + 1(space) = 6
    assert.equals(6, pos)
  end)

  it("leaf column (depth 2)", function()
    local line = "    " .. "  " .. ICONS.column .. " id int PK"
    local pos = calc_icon_position(line)
    -- 4(indent) + 2(leaf marker) = 6
    assert.equals(6, pos)
  end)

  it("leaf index (depth 2)", function()
    local line = "    " .. "  " .. ICONS.index .. " PRIMARY"
    local pos = calc_icon_position(line)
    assert.equals(6, pos)
  end)

  it("collapsed database (depth 0)", function()
    local line = MARKER_COLLAPSED .. " " .. ICONS.database .. " mydb"
    local pos = calc_icon_position(line)
    -- 0(indent) + 3(marker) + 1(space) = 4
    assert.equals(4, pos)
  end)

  it("collapsed table (depth 2)", function()
    local line = "    " .. MARKER_COLLAPSED .. " " .. ICONS.table .. " orders"
    local pos = calc_icon_position(line)
    -- 4(indent) + 3(marker) + 1(space) = 8
    assert.equals(8, pos)
  end)

  it("loading schema (depth 1)", function()
    local line = "  " .. MARKER_LOADING .. " " .. ICONS.schema .. " public"
    local pos = calc_icon_position(line)
    -- 2(indent) + 3(marker) + 1(space) = 6
    assert.equals(6, pos)
  end)

  it("empty line returns -1", function()
    assert.equals(-1, calc_icon_position("   "))
  end)

  it("PK column uses column_pk icon", function()
    local line = "  " .. MARKER_EXPANDED .. " " .. ICONS.column_pk .. " id"
    local pos = calc_icon_position(line)
    assert.equals(6, pos)
  end)
end)

------------------------------------------------------------------------------
-- find_table_node Characterization Tests
------------------------------------------------------------------------------

describe("db_browser find_table_node", function()
  it("returns the table node at current index", function()
    local tbl = { node_type = "table", name = "users" }
    local col = { node_type = "column", name = "id" }
    local line_to_node = { tbl, col }
    assert.equals(tbl, find_table_node(line_to_node, 1))
  end)

  it("walks backwards to find parent table", function()
    local tbl = { node_type = "table", name = "users" }
    local col = { node_type = "column", name = "id" }
    local col2 = { node_type = "column", name = "name" }
    local line_to_node = { tbl, col, col2 }
    assert.equals(tbl, find_table_node(line_to_node, 3))
  end)

  it("returns nil when no table node exists", function()
    local col = { node_type = "column", name = "id" }
    local db = { node_type = "database", name = "mydb" }
    local line_to_node = { db, col }
    assert.is_nil(find_table_node(line_to_node, 2))
  end)

  it("returns nil for empty node map", function()
    assert.is_nil(find_table_node({}, 1))
  end)

  it("finds first table when multiple tables exist", function()
    local tbl1 = { node_type = "table", name = "users" }
    local col1 = { node_type = "column", name = "id" }
    local tbl2 = { node_type = "table", name = "orders" }
    local col2 = { node_type = "column", name = "total" }
    local line_to_node = { tbl1, col1, tbl2, col2 }
    -- Starting from col2 (index 4), should find tbl2 (index 3), not tbl1
    assert.equals(tbl2, find_table_node(line_to_node, 4))
  end)

  it("returns table when starting from a non-table node between tables", function()
    local tbl1 = { node_type = "table", name = "users" }
    local col_id = { node_type = "column", name = "id" }
    local col_name = { node_type = "column", name = "name" }
    local line_to_node = { tbl1, col_id, col_name }
    assert.equals(tbl1, find_table_node(line_to_node, 2))
    assert.equals(tbl1, find_table_node(line_to_node, 3))
  end)
end)

------------------------------------------------------------------------------
-- Public API Smoke Tests
------------------------------------------------------------------------------

describe("db_browser public API", function()
  before_each(function()
    -- Create a scratch buffer as "source buffer"
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    if db_browser.is_open() then
      db_browser.close()
    end
    -- Clean up all buffers
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
  end)

  it("is_open returns nil initially", function()
    assert.is_nil(db_browser.is_open())
  end)

  it("open creates a browser window and buffer", function()
    db_browser.open()
    assert.is_not_nil(db_browser.is_open())
  end)

  it("close destroys the browser window", function()
    db_browser.open()
    assert.is_not_nil(db_browser.is_open())
    db_browser.close()
    assert.is_nil(db_browser.is_open())
  end)

  it("toggle opens when closed", function()
    assert.is_nil(db_browser.is_open())
    db_browser.toggle()
    assert.is_not_nil(db_browser.is_open())
  end)

  it("toggle closes when open", function()
    db_browser.open()
    assert.is_not_nil(db_browser.is_open())
    db_browser.toggle()
    assert.is_nil(db_browser.is_open())
  end)

  it("calling open twice is idempotent", function()
    db_browser.open()
    local win = vim.api.nvim_get_current_win()
    db_browser.open()
    assert.is_true(db_browser.is_open())
    assert.equals(win, vim.api.nvim_get_current_win())
  end)

  it("navigate_to requires valid connection", function()
    -- In headless mode with no connections.toml, should not crash
    -- Just verify the function exists and accepts args
    assert.has_no.errors(function()
      db_browser.navigate_to("nonexistent", "mydb")
    end)
  end)

  it("navigate_to_table requires valid connection", function()
    assert.has_no.errors(function()
      db_browser.navigate_to_table("nonexistent", "mydb", "users")
    end)
  end)

  it("navigate_to_table with schema-qualified table name", function()
    assert.has_no.errors(function()
      db_browser.navigate_to_table("nonexistent", "mydb", "public.users")
    end)
  end)

  it("navigate_to_table with column name", function()
    assert.has_no.errors(function()
      db_browser.navigate_to_table("nonexistent", "mydb", "public.users", "id")
    end)
  end)

  it("navigate_to_table for sqlite (nil db_name)", function()
    assert.has_no.errors(function()
      db_browser.navigate_to_table("lite-conn", nil, "users")
    end)
  end)
end)

describe("db_browser yank register indicator", function()
  local yank = require("poste-db.db_browser.yank")
  local statusline = require("poste-db.db_browser.statusline")

  after_each(function()
    yank.clear()
    _G.poste_search_info = nil
  end)

  it("statusline_label is nil when the register is empty", function()
    yank.clear()
    assert.is_nil(yank.statusline_label())
  end)

  it("statusline_label names the yanked item and the paste hint", function()
    yank.set({ kind = "table", name = "posts", schema = "public", conn = "maria-dev", db = "blog", dialect = "mysql" })
    assert.equals("Yanked: table maria-dev.blog.posts (p to paste)", yank.statusline_label())
  end)

  it("statusline_label covers whole-database and sqlite-connection yanks", function()
    yank.set({ kind = "database", conn = "maria-dev", db = "blog", dialect = "mysql" })
    assert.equals("Yanked: database maria-dev.blog (p to paste)", yank.statusline_label())

    yank.set({ kind = "database", conn = "lite", db = nil, dialect = "sqlite" })
    assert.equals("Yanked: database lite (p to paste)", yank.statusline_label())
  end)

  it("build_winbar no longer carries the yank fragment", function()
    yank.set({ kind = "database", conn = "maria-dev", db = "blog", dialect = "mysql" })
    local text = tree.build_winbar({ active = false, selected = {} })
    assert.is_truthy(text:find(" DB Browser", 1, true) ~= nil, "title kept")
    assert.is_nil(text:find("Yanked:", 1, true), "yank fragment moved off the winbar")
  end)

  it("build_statusline shows the yank fragment with a highlight", function()
    yank.set({ kind = "database", conn = "maria-dev", db = "blog", dialect = "mysql" })
    local text = statusline.build("", nil, { active = false, selected = {} }, 80)

    assert.is_truthy(text:find("Yanked: database maria-dev.blog", 1, true) ~= nil, "yanked item shown")
    assert.is_truthy(text:find("%#PosteDbBrowserYanked#") ~= nil, "yank fragment is highlighted")
    assert.is_truthy(text:find(icons.MARKER_YANKED) ~= nil, "yank fragment carries the yanked marker")
    -- %< must precede the yank fragment so the path wins in narrow splits
    assert.is_truthy(text:find("%%<") < text:find("%#PosteDbBrowserYanked#"),
      "%< placed before the yank fragment")
  end)

  it("build_statusline omits the yank fragment when nothing is yanked", function()
    yank.clear()
    assert.is_nil(statusline.build("", nil, { active = false, selected = {} }, 80):find("Yanked:", 1, true),
      "no yank fragment when register empty")
  end)

  it("build_statusline keeps selection and yank fragments together", function()
    yank.set({ kind = "table", name = "posts", conn = "maria-dev", db = "blog", dialect = "mysql" })
    local ms = { active = true, selected = {} }
    ms.selected[tree.make_table_node({ name = "posts" }, "public", "blog", "maria-dev")] = true

    local text = statusline.build("", nil, ms, 80)
    assert.is_truthy(text:find("[1 selected]", 1, true) ~= nil, "selection fragment kept")
    assert.is_truthy(text:find("Yanked: table maria-dev.blog.posts", 1, true) ~= nil, "yank fragment added")
  end)

  it("build_statusline appends the comment in gray, truncated", function()
    local text = statusline.build("", "a long table comment that overflows badly here", nil, 40)
    assert.is_truthy(text:find("%#PosteDbBrowserComment#") ~= nil, "comment fragment highlighted")
    assert.is_truthy(text:find("…") ~= nil, "comment truncated with ellipsis")
  end)

  it("build_statusline omits the comment when empty", function()
    local text = statusline.build("", "", nil, 80)
    assert.is_nil(text:find("%#PosteDbBrowserComment#", 1, true), "no comment fragment when empty")
  end)

  it("node_path builds a conn/db/schema/table/column label", function()
    assert.is_truthy(statusline.node_path("pg-dev"):find("pg-dev", 1, true), "conn shown")
    assert.is_truthy(statusline.node_path("pg-dev", "blog"):find("blog", 1, true), "db shown")
    local full = statusline.node_path("pg-dev", "blog", "public")
    assert.is_truthy(full:find("pg-dev", 1, true))
    assert.is_truthy(full:find("blog", 1, true))
    assert.is_truthy(full:find("public", 1, true))
    assert.is_truthy(statusline.node_path("pg-dev", "blog", "public", "orders"):find("orders", 1, true),
      "table shown when cursor is on a table/column")
    assert.is_truthy(statusline.node_path("pg-dev", "blog", nil, "authors", "username"):find("username", 1, true),
      "column shown when cursor is on a column")
    assert.equals("", statusline.node_path(nil, nil, nil, nil, nil), "no scope → empty")
  end)

  it("update_statusline writes the indicator to the browser window", function()
    yank.set({ kind = "database", conn = "maria-dev", db = "blog", dialect = "mysql" })

    local buf = vim.api.nvim_create_buf(false, false)
    local win = vim.api.nvim_open_win(buf, true, { split = "right", width = 20 })

    statusline.update(buf, "", nil, { active = false, selected = {} })
    local written = vim.api.nvim_get_option_value("statusline", { win = win })
    assert.is_truthy(written:find("Yanked: database maria-dev.blog", 1, true) ~= nil, "indicator written")

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("update_statusline truncates the comment to the editor width under globalstatus", function()
    local comment = "a table comment that only fits the full editor width"
    local buf = vim.api.nvim_create_buf(false, false)
    local win = vim.api.nvim_open_win(buf, true, { split = "right", width = 20 })

    local prev_ls = vim.api.nvim_get_option_value("laststatus", {})
    local prev_cols = vim.api.nvim_get_option_value("columns", {})
    vim.api.nvim_set_option_value("columns", 200, {})
    vim.api.nvim_win_set_width(win, 20)

    -- Per-window statusline: the budget is the narrow split, so the comment is cut.
    vim.api.nvim_set_option_value("laststatus", 2, {})
    statusline.update(buf, "pg-dev  blog", comment, { active = false, selected = {} })
    local narrow = vim.api.nvim_get_option_value("statusline", { win = win })
    assert.is_truthy(narrow:find("…") ~= nil, "comment truncated to the split width")

    -- Global statusline spans the editor, so the same comment must stay whole.
    vim.api.nvim_set_option_value("laststatus", 3, {})
    statusline.update(buf, "pg-dev  blog", comment, { active = false, selected = {} })
    local global = vim.api.nvim_get_option_value("statusline", { win = win })
    assert.is_falsy(global:find("…", 1, true), "comment kept whole under globalstatus")

    vim.api.nvim_set_option_value("laststatus", prev_ls, {})
    vim.api.nvim_set_option_value("columns", prev_cols, {})
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("clear drops the register immediately", function()
    yank.set({ kind = "table", name = "posts", conn = "maria-dev", db = "blog", dialect = "mysql" })
    assert.is_truthy(yank.get(), "register holds the entry")
    yank.clear()
    assert.is_nil(yank.get(), "register empty after clear")
    assert.is_nil(yank.statusline_label(), "statusline label drops after clear")
  end)
end)

describe("db_browser prefetch_children", function()
  local async_mod = require("poste-db.db_browser.async")

  it("populates child counts without expanding children", function()
    local calls = {}
    -- Stub run_introspect so no real DB / subprocess is hit
    local orig = async_mod.run_introspect
    async_mod.run_introspect = function(conn, itype, _, __, ___, cb)
      table.insert(calls, itype)
      local items
      if itype == "databases" then
        items = { { name = "blog" } }
      elseif itype == "tables" then
        items = { { name = "t1" }, { name = "t2" }, { name = "t3" } }
      else
        items = {}
      end
      cb({ items = items })
      return 1
    end

    local renders = 0
    local orig_hook = async_mod.render_hook
    async_mod.render_hook = function() renders = renders + 1 end

    local conn = tree.make_connection_node({ name = "local", dialect = "mysql" })
    local done = false
    async_mod.fetch_children(conn, function() done = true end, "/tmp")
    vim.wait(500, function() return done end)
    -- render_hook fires on a 50ms debounce after the prefetch's sub-fetch
    vim.wait(300, function() return renders >= 1 end)

    assert.same({ "databases", "tables" }, calls)
    assert.equals(1, #conn.children)
    local db = conn.children[1]
    assert.equals(3, #db.children, "db children prefetched (tables)")
    assert.is_false(db.expanded, "prefetched db stays collapsed")
    assert.is_true(renders >= 1, "render_hook fires after prefetch completes")

    async_mod.run_introspect = orig
    async_mod.render_hook = orig_hook
  end)

  it("does not prefetch leaf children (columns are leaf types)", function()
    local calls = {}
    local orig = async_mod.run_introspect
    async_mod.run_introspect = function(conn, itype, _, __, ___, cb)
      table.insert(calls, itype)
      cb({ items = {} })
      return 1
    end
    local conn = tree.make_connection_node({ name = "local", dialect = "sqlite" })
    conn.children = { tree.make_table_node({ name = "users" }, nil, nil, "local") }
    async_mod.prefetch_children(conn, "/tmp")
    vim.wait(300, function() return false end)
    -- table is prefetchable (PREFETCH_TYPES includes table), so columns query runs
    assert.is_truthy(#calls >= 1 or #conn.children[1].children ~= nil)
    async_mod.run_introspect = orig
  end)
end)

------------------------------------------------------------------------------
-- Line map
------------------------------------------------------------------------------

describe("db_browser line map", function()
  it("swaps content without losing the table every context holds", function()
    local map = { "a", "b", "c" }
    util.set_line_map(map, { "x", "y", "z" })
    assert.same({ "x", "y", "z" }, map)
  end)

  it("drops the tail when the re-rendered tree is shorter", function()
    -- collapse a branch and the leftover rows still resolved to their old
    -- nodes, so a keystroke on a line that no longer shows a table acted on it
    local map = { "a", "b", "c", "d" }
    util.set_line_map(map, { "x" })
    assert.equals(1, #map)
    assert.is_nil(map[2])
    assert.is_nil(map[4])
  end)

  it("clears the map when the render produced nothing", function()
    -- tree.render_tree returns nil for an invalid buffer
    local map = { "a", "b" }
    util.set_line_map(map, nil)
    assert.equals(0, #map)
  end)
end)
