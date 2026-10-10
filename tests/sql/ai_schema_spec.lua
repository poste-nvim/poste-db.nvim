describe("poste-db.ai.schema", function()
  local schema = require("poste-db.ai.schema")
  local async = require("poste-db.db_browser.async")

  local calls

  before_each(function()
    schema._test._reset()
    calls = {}
    async.run_introspect = function(conn, kind, _s, table_name, db, cb)
      calls[#calls + 1] = { conn = conn, kind = kind, table = table_name, db = db }
      if kind == "tables" then
        cb({ items = {
          { name = "users", comment = "user accounts" },
          { name = "user", comment = "single user" },
          { name = "orders", comment = nil },
          { name = "products", comment = "goods" },
          { name = "t5", comment = nil }, { name = "t6", comment = nil },
          { name = "t7", comment = nil }, { name = "t8", comment = nil },
        } })
      elseif kind == "columns" then
        local data = {
          users = { { name = "id", type = "int" }, { name = "email", type = "varchar" } },
          products = { { name = "id", type = "int" }, { name = "price", type = "decimal" } },
          user = { { name = "id", type = "int" } },
          orders = { { name = "id", type = "int" } },
        }
        cb({ items = data[table_name] or {} })
      end
    end
  end)

  it("returns nil without a connection binding", function()
    local got = "unset"
    schema._test.auto_context("hello", {}, function(md) got = md end)
    assert.is_nil(got)
    assert.are.equal(0, #calls)
  end)

  it("treats an empty name in the scope as no binding", function()
    -- the last error of a run whose target the envelope did not name carries
    -- `connection = ""` / `database = ""` (exec_run's `or ""`). Introspecting a
    -- connection called "" made the browser fail to resolve it and notify on
    -- every request, and an empty database was forwarded as the override the
    -- CLI applies as a URL rewrite — taking the database off the connection.
    local got = "unset"
    schema._test.auto_context("hello", { connection = "", database = "" }, function(md) got = md end)
    assert.is_nil(got)
    assert.are.equal(0, #calls)

    got = "unset"
    schema._test.auto_context("show users", { connection = "my-blog", database = "" },
      function(md) got = md end)
    assert.are.equal(2, #calls, "one tables listing + one columns expansion")
    assert.is_nil(calls[1].db)
    assert.is_nil(calls[2].db)
    assert.truthy(got:find("Connection `my-blog` (default database)", 1, true))
  end)

  it("lists tables and expands those named in the text", function()
    local got
    schema._test.auto_context("show recent users", { connection = "my-blog", database = "blog" },
      function(md) got = md end)
    assert.truthy(got:find("## Database schema %(auto%)"))
    assert.truthy(got:find("Database `blog` tables:"))
    assert.truthy(got:find("%- users %(user accounts%): id: int, email: varchar"))
    assert.truthy(got:find("%- orders\n"))          -- not in text → plain
    assert.truthy(got:find("%- products %(goods%)"))
    -- calls: one tables listing + one columns expansion
    assert.are.equal(2, #calls)
    assert.are.equal("tables", calls[1].kind)
    assert.are.equal("columns", calls[2].kind)
    assert.are.equal("users", calls[2].table)
  end)

  it("expands a column line with the table comment", function()
    local got
    schema._test.auto_context("users please", { connection = "c", database = "d" },
      function(md) got = md end)
    assert.truthy(got:find("%- users %(user accounts%): id: int, email: varchar"))
  end)

  it("caches the table list; new candidates still expand", function()
    local got
    schema._test.auto_context("show users", { connection = "c", database = "d" }, function(md) got = md end)
    schema._test.auto_context("now products", { connection = "c", database = "d" }, function(md) got = md end)
    local tables_calls = vim.tbl_count(vim.tbl_filter(function(c) return c.kind == "tables" end, calls))
    assert.are.equal(1, tables_calls)               -- listed once
    assert.truthy(got:find("%- products %(goods%): id: int, price: decimal"))
  end)

  it("re-uses cached column lines when a table is mentioned again", function()
    schema._test.auto_context("show users", { connection = "c", database = "d" }, function(md) end)
    -- second request mentions users again: its columns are cached, so no new
    -- introspection — but the rendered block must keep the FULL column line
    -- (it used to degrade to the plain "- users" form because only newly
    -- introspected tables were marked expanded)
    local got
    schema._test.auto_context("users again", { connection = "c", database = "d" }, function(md) got = md end)
    assert.truthy(got:find("%- users %(user accounts%): id: int, email: varchar"))
    local columns_calls = vim.tbl_count(vim.tbl_filter(function(c) return c.kind == "columns" end, calls))
    assert.are.equal(1, columns_calls)              -- only the first request introspected
  end)

  it("respects word boundaries (user vs user_id)", function()
    local got
    schema._test.auto_context("analyze user_id trends", { connection = "c", database = "d" },
      function(md) got = md end)
    assert.truthy(got:find("%- user %(single user%)\n"))  -- plain, not expanded
    local column_calls = vim.tbl_filter(function(c) return c.kind == "columns" end, calls)
    assert.are.equal(0, #column_calls)
  end)

  it("caps the number of expanded tables per request", function()
    local got
    schema._test.auto_context(
      "users user orders products t5 t6 t7 t8 together",
      { connection = "c", database = "d" }, function(md) got = md end)
    local column_calls = vim.tbl_filter(function(c) return c.kind == "columns" end, calls)
    assert.are.equal(schema._test.MAX_EXPAND, #column_calls)
    assert.truthy(got:find("%- t7\n"))
  end)

  it("handles an empty table listing", function()
    async.run_introspect = function(_c, _k, _s, _t, _d, cb) cb({ items = {} }) end
    local got = "unset"
    schema._test.auto_context("anything", { connection = "c", database = "d" }, function(md) got = md end)
    assert.is_nil(got)
  end)
end)
