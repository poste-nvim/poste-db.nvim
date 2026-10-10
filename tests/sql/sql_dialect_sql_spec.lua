--- Item 13: dialect-correct SQL the DB Browser generates (T-SQL has neither
--- LIMIT nor RENAME TO/COLUMN) and ident.quote-based DDL quoting.
local ops_sql = require("poste-db.db_browser.ops_sql")
local db_create = require("poste-db.db_browser.db_create")

local function table_node(overrides)
  return vim.tbl_extend("force", {
    node_type = "table",
    name = "orders",
    meta = { schema = "public", database = "blog" },
  }, overrides or {})
end

describe("db_browser generated SELECT row cap", function()
  it("uses LIMIT outside T-SQL", function()
    assert.equals('SELECT * FROM "orders" LIMIT 100;',
      ops_sql.select_star_sql('"orders"', "postgres"))
    assert.equals('SELECT * FROM "orders" LIMIT 25;',
      ops_sql.select_star_sql('"orders"', "sqlite", 25))
  end)

  it("uses TOP for mssql, which has no LIMIT clause", function()
    assert.equals("SELECT TOP 100 * FROM [orders];", ops_sql.select_star_sql("[orders]", "mssql"))
  end)
end)

describe("db_browser rename SQL", function()
  it("spells a table rename per dialect", function()
    assert.equals('ALTER TABLE "public"."orders" RENAME TO "purchases";',
      ops_sql.rename_table_sql(table_node(), "purchases", "postgres"))
    assert.equals("RENAME TABLE `orders` TO `purchases`;",
      ops_sql.rename_table_sql(table_node(), "purchases", "mysql"))
    assert.equals('ALTER TABLE "orders" RENAME TO "purchases";',
      ops_sql.rename_table_sql(table_node(), "purchases", "sqlite"))
  end)

  -- Postgres resolves an unqualified name through the session search_path, so
  -- a bare `ALTER TABLE "orders"` renamed (or failed on) whatever `public`
  -- happened to hold — not the schema the browser row came from. Every other
  -- generator here already went through qualified_table_ref; rename was the
  -- odd one out.
  it("targets the browsed schema, like the SELECT template does", function()
    local node = table_node({ meta = { schema = "app", database = "blog" } })
    local ref = ops_sql.qualified_table_ref(node, "postgres")
    assert.equals("ALTER TABLE " .. ref .. ' RENAME TO "purchases";',
      ops_sql.rename_table_sql(node, "purchases", "postgres"))
    assert.equals('ALTER TABLE "app"."orders" RENAME TO "purchases";',
      ops_sql.rename_table_sql(node, "purchases", "postgres"))
    -- sqlite has no schema to qualify with even if a node carries one
    assert.equals('ALTER TABLE "orders" RENAME TO "purchases";',
      ops_sql.rename_table_sql(node, "purchases", "sqlite"))
  end)

  it("renames an mssql table through sp_rename, unquoted and schema-qualified", function()
    assert.equals("EXEC sp_rename 'dbo.orders', 'purchases';",
      ops_sql.rename_table_sql(
        table_node({ meta = { schema = "dbo", database = "blog" } }), "purchases", "mssql"))
    assert.equals("EXEC sp_rename 'orders', 'purchases';",
      ops_sql.rename_table_sql(table_node({ meta = {} }), "purchases", "mssql"))
  end)

  -- The name of a schema node is an introspection row's name, so "no schema"
  -- reads as `""` (and a JSON null as vim.NIL). Both are truthy, and both used
  -- to reach the prefix join: Postgres got `ALTER TABLE ."orders"`, which is a
  -- syntax error rather than a rename, and the null raised on the concat the
  -- sp_rename path needs.
  it("renames from the bare table when the node has no schema name", function()
    local col = { node_type = "column", name = "total", meta = { col_type = "INT" } }
    for _, blank in ipairs({ "", vim.NIL, 0 }) do
      local node = table_node({ meta = { schema = blank, database = "blog" } })
      assert.equals('ALTER TABLE "orders" RENAME TO "purchases";',
        ops_sql.rename_table_sql(node, "purchases", "postgres"))
      assert.equals("EXEC sp_rename 'orders', 'purchases';",
        ops_sql.rename_table_sql(node, "purchases", "mssql"))
      assert.equals('ALTER TABLE "orders" RENAME COLUMN "total" TO "amount";',
        ops_sql.rename_column_sql(node, col, "amount", "postgres"))
    end
  end)

  it("renames a column through sp_rename for mssql", function()
    local col = { node_type = "column", name = "total", meta = { col_type = "INT" } }
    assert.equals("EXEC sp_rename 'dbo.orders.total', 'amount', 'COLUMN';",
      ops_sql.rename_column_sql(
        table_node({ meta = { schema = "dbo", database = "blog" } }), col, "amount", "mssql"))
    assert.equals('ALTER TABLE "app"."orders" RENAME COLUMN "total" TO "amount";',
      ops_sql.rename_column_sql(
        table_node({ meta = { schema = "app", database = "blog" } }), col, "amount", "postgres"))
    assert.equals('ALTER TABLE "public"."orders" RENAME COLUMN "total" TO "amount";',
      ops_sql.rename_column_sql(table_node(), col, "amount", "postgres"))
    assert.equals("ALTER TABLE `orders` CHANGE COLUMN `total` `amount` INT;",
      ops_sql.rename_column_sql(table_node(), col, "amount", "mysql"))
  end)

  it("doubles an apostrophe inside an sp_rename name instead of ending the literal", function()
    local col = { node_type = "column", name = "o'brien", meta = {} }
    assert.equals("EXEC sp_rename 'orders.o''brien', 'name', 'COLUMN';",
      ops_sql.rename_column_sql(table_node({ meta = {} }), col, "name", "mssql"))
  end)

  -- A rename target is a bare name by contract (a rename does not move the
  -- table), so dots inside it are the name's own: `"v1"."2"` would put the
  -- table in a schema called v1, which is not what was typed.
  it("keeps a dot in the new name inside the name", function()
    assert.equals('ALTER TABLE "public"."orders" RENAME TO "v1.2";',
      ops_sql.rename_table_sql(table_node(), "v1.2", "postgres"))
    assert.equals("RENAME TABLE `orders` TO `v1.2`;",
      ops_sql.rename_table_sql(table_node(), "v1.2", "mysql"))
  end)

  it("keeps a dotted source table one identifier", function()
    local node = table_node({ name = "staging.v1" })
    assert.equals('"public"."staging.v1"', ops_sql.qualified_table_ref(node, "postgres"))
    assert.equals('ALTER TABLE "public"."staging.v1" RENAME TO "orders";',
      ops_sql.rename_table_sql(node, "orders", "postgres"))
  end)
end)

describe("db_browser ADD COLUMN", function()
  it("assembles type, NOT NULL and DEFAULT in one statement", function()
    assert.same({ 'ALTER TABLE "app"."orders" ADD COLUMN "note" TEXT NOT NULL DEFAULT \'\';' },
      ops_sql.add_column_sql('"app"."orders"', '"note"', "TEXT", false, "''", "postgres"))
  end)

  -- The browser form used to re-spell this inline (and rebuild the same string
  -- again in a no-op mysql branch), so the SQLite caveat only existed on the
  -- prompt path.
  it("appends the SQLite caveat as its own line, never inside the statement", function()
    assert.same({
      'ALTER TABLE "t" ADD COLUMN "c" INT NOT NULL;',
      "-- SQLite: a NOT NULL added column requires a DEFAULT; add one above.",
    }, ops_sql.add_column_sql('"t"', '"c"', "INT", false, "", "sqlite"))
  end)

  it("stays quiet once a DEFAULT makes the SQLite form legal", function()
    assert.same({ 'ALTER TABLE "t" ADD COLUMN "c" INT NOT NULL DEFAULT 0;' },
      ops_sql.add_column_sql('"t"', '"c"', "INT", false, "0", "sqlite"))
    assert.same({ 'ALTER TABLE "t" ADD COLUMN "c" INT;' },
      ops_sql.add_column_sql('"t"', '"c"', "INT", true, nil, "postgres"))
  end)
end)

describe("db_browser CREATE DATABASE quoting", function()
  it("escapes an embedded double quote instead of ending the identifier", function()
    assert.equals('CREATE DATABASE "a""b";',
      db_create._test.generate_sql({ name = 'a"b' }, "postgres")[1])
  end)

  it("quotes with the dialect's own rule", function()
    assert.equals("CREATE DATABASE IF NOT EXISTS `weird``name`;",
      db_create._test.generate_sql({ name = "weird`name" }, "mysql")[1])
    assert.equals("CREATE DATABASE [db];",
      db_create._test.generate_sql({ name = "db" }, "mssql")[1])
  end)

  it("keeps the postgres OWNER clause quoted", function()
    assert.equals('CREATE DATABASE "blog" OWNER "postgres";',
      db_create._test.generate_sql({ name = "blog", owner = "postgres" }, "postgres")[1])
  end)
end)
