-- Tests for lua/poste-db/snippets.lua
-- Built-in + custom snippet registration, category/dialect routing,
-- and completion-item generation.

local snippets = require("poste-db.snippets")

describe("snippets", function()
  before_each(function()
    snippets.setup({})
  end)

  describe("setup", function()
    it("registers a custom string snippet as a raw template", function()
      snippets.setup({ snippets = { myq = "SELECT ${1:col} FROM ${2:tbl};" } })
      assert.same({ label = "myq", snippet = "SELECT ${1:col} FROM ${2:tbl};" }, snippets.resolve("myq"))
    end)

    it("registers a custom table snippet and forces its trigger", function()
      snippets.setup({ snippets = { q = { label = "q query", snippet = "select 1;" } } })
      assert.equals("q query", snippets.resolve("q").label)
      assert.equals("select 1;", snippets.resolve("q").snippet)
    end)

    it("keeps all built-in snippets when no custom snippets given", function()
      snippets.setup({})
      assert.same("create_table", snippets.snippets["ct"].category)
      assert.same("select_from", snippets.snippets["sf"].category)
    end)

    it("routes a custom trigger to a built-in category by category name", function()
      snippets.setup({ snippets = { mkct = "create_table" } })
      assert.same("create_table", snippets.snippets["mkct"].category)
      assert.matches("^CREATE TABLE", snippets.resolve("mkct", "postgres").snippet)
    end)

    it("overrides a built-in trigger category", function()
      snippets.setup({ snippets = { ct = "create_database" } })
      assert.same("create_database", snippets.snippets["ct"].category)
      assert.matches("^CREATE DATABASE", snippets.resolve("ct", "mysql").snippet)
    end)

    it("registers a custom category with per-dialect variants", function()
      snippets.setup({ snippets = { boom = {
        default = "CREATE DATABASE ${1:db};",
        postgres = "CREATE DATABASE ${1:db} ENCODING 'UTF8';",
      } } })
      assert.matches("ENCODING", snippets.resolve("boom", "postgres").snippet)
      assert.matches("^CREATE DATABASE ${1:db};$", snippets.resolve("boom", "mysql").snippet)
    end)
  end)

  describe("dialect routing", function()
    it("routes create_database per dialect", function()
      assert.matches("CHARACTER SET", snippets.resolve("cdb", "mysql").snippet)
      assert.matches("CHARACTER SET", snippets.resolve("cdb", "mariadb").snippet)
      assert.matches("ENCODING", snippets.resolve("cdb", "postgres").snippet)
      assert.matches("^ATTACH DATABASE", snippets.resolve("cdb", "sqlite").snippet)
    end)

    it("routes create_table id column per dialect", function()
      assert.matches("AUTO_INCREMENT", snippets.resolve("ct", "mysql").snippet)
      assert.matches("SERIAL", snippets.resolve("ct", "postgres").snippet)
      assert.matches("AUTOINCREMENT", snippets.resolve("ct", "sqlite").snippet)
      assert.matches("IDENTITY%(1,1%)", snippets.resolve("ct", "mssql").snippet)
      assert.matches("ENGINE = MergeTree", snippets.resolve("ct", "clickhouse").snippet)
    end)

    it("spells the postgres alter_modify_column type change as TYPE, not SET", function()
      -- `ALTER COLUMN c SET <type>` is not postgres SQL (the type change is
      -- `ALTER COLUMN c TYPE t`); the old template produced a syntax error
      -- on every expansion.
      assert.matches("ALTER COLUMN ${2:column_name} TYPE ${3:INTEGER};",
        snippets.resolve("colu", "postgres").snippet)
      assert.not_matches("SET ${", snippets.resolve("colu", "postgres").snippet)
      -- The other dialects keep their working shapes.
      assert.matches("MODIFY COLUMN", snippets.resolve("colu", "mysql").snippet)
      assert.matches("MODIFY COLUMN", snippets.resolve("colu", nil).snippet)
    end)

    it("falls back to default template when dialect has no variant", function()
      assert.matches("^INSERT INTO", snippets.resolve("ins", "postgres").snippet)
      assert.matches("^INSERT INTO", snippets.resolve("ins", "sqlite").snippet)
      assert.matches("^INSERT INTO", snippets.resolve("ins", "mysql").snippet)
    end)

    it("falls back to default template when dialect is nil", function()
      assert.matches("^INSERT INTO", snippets.resolve("ins").snippet)
    end)
  end)

  describe("get_completion_items", function()
    it("returns an empty table for a non-matching prefix", function()
      assert.same({}, snippets.get_completion_items("zzz"))
    end)

    it("returns every built-in snippet for an empty prefix", function()
      local items = snippets.get_completion_items("")
      assert.equals(15, #items)
    end)

    it("filters by prefix", function()
      local items = snippets.get_completion_items("ct")
      local triggers = {}
      for _, item in ipairs(items) do
        table.insert(triggers, item.insertText)
      end
      table.sort(triggers)
      assert.same({ "ct", "cte" }, triggers)
    end)

    it("treats pattern-magic chars in the prefix literally", function()
      -- Regression: the prefix was interpolated into a find pattern, so a
      -- typed `sf(` raised "malformed pattern" instead of matching nothing.
      assert.same({}, snippets.get_completion_items("sf("))
      assert.same({}, snippets.get_completion_items("%f"))
    end)

    it("builds blink-compatible items with snippet data", function()
      local items = snippets.get_completion_items("sf")
      local item = items[1]
      assert.equals("select * from", item.label)
      assert.equals("sf", item.insertText)
      assert.equals("sf", item.filterText)
      assert.equals("zzzsf", item.sortText)
      assert.equals(14, item.kind)
      assert.matches("^SELECT", item.documentation)
      assert.is_true(item.data.snippet)
      assert.equals("sf", item.data.trigger)
      assert.truthy(item.data.body:find("SELECT * FROM", 1, true))
    end)

    it("routes item body by dialect", function()
      local items = snippets.get_completion_items("cdb", "postgres")
      assert.equals(1, #items)
      assert.matches("ENCODING", items[1].data.body)
    end)

    it("matches custom snippets too", function()
      snippets.setup({ snippets = { foo = "SELECT 1" } })
      local items = snippets.get_completion_items("foo")
      assert.equals(1, #items)
      assert.equals("foo", items[1].insertText)
    end)
  end)
end)