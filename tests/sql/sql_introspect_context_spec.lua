local ctx = require("poste-db.introspect.context")

local function cursor_on(sql, word)
  local init = 1
  while true do
    local start = assert(sql:find(word, init, true), "fixture word missing: " .. word)
    local before = sql:sub(start - 1, start - 1)
    local after = sql:sub(start + #word, start + #word)
    if not before:match("[%w_]") and not after:match("[%w_]") then
      return start + #word - 2
    end
    init = start + 1
  end
end

describe("introspect context", function()
  it("resolves dot_column targets as columns", function()
    local target = ctx.resolve_detected_target({
      ctx_type = "dot_column",
      ctx_data = "p",
      tables = {
        { name = "posts", alias = "p", schema = "blog" },
      },
    }, "title", "blog", "body")

    assert.same({
      kind = "column",
      db = "blog",
      parent_table = "posts",
      parent_schema = "blog",
      column_name = "body",
    }, target)
  end)

  it("resolves schema_table targets as ddl lookups", function()
    -- BEHAVIOR CHANGE (2026-10-30 audit): the schema used to fold into `db`,
    -- which for postgres repointed the connection at a database named like
    -- the schema. The real context database stays in `db`; the schema rides
    -- on `schema` (the argv layer decides --schema vs --database per dialect).
    local target = ctx.resolve_detected_target({
      ctx_type = "schema_table",
      ctx_data = "blog",
    }, "authors", "main")

    assert.same({
      kind = "ddl",
      db = "main",
      schema = "blog",
      table_name = "authors",
    }, target)
  end)

  it("resolves schema_table targets without a context database", function()
    local target = ctx.resolve_detected_target({
      ctx_type = "schema_table",
      ctx_data = "blog",
    }, "authors", nil)

    assert.same({
      kind = "ddl",
      db = nil,
      schema = "blog",
      table_name = "authors",
    }, target)
  end)

  it("resolves schema-qualified tables as list tables targets", function()
    local target = ctx.resolve_detected_target({
      ctx_type = "table",
      tables = {
        { name = "authors", schema = "blog" },
      },
    }, "blog", "main")

    assert.same({
      kind = "list_tables",
      db = "blog",
    }, target)
  end)

  it("resolves table matches as ddl targets", function()
    local target = ctx.resolve_detected_target({
      ctx_type = "table",
      tables = {
        { name = "authors", schema = "blog" },
      },
    }, "authors", "main")

    assert.same({
      kind = "ddl",
      db = "main",
      schema = "blog",
      table_name = "authors",
    }, target)
  end)

  it("resolves non-table columns as column targets", function()
    local target = ctx.resolve_detected_target({
      ctx_type = "column",
      tables = {
        { name = "authors", schema = "blog" },
      },
    }, "name", "main")

    assert.same({
      kind = "column",
      db = "main",
      parent_table = "authors",
      parent_schema = "blog",
      column_name = "name",
    }, target)
  end)
end)

describe("introspect context quoted names", function()
  -- `pick_table_match` compared the unquoted spelling but handed the raw
  -- entry's name to the argv layer, so `K` on `users` in ``FROM `users` ``
  -- asked the binary for a table literally named `users` with its backticks.
  it("hands the bare name to the ddl lookup for a matched quoted table", function()
    local target = ctx.resolve_detected_target({
      ctx_type = "table",
      tables = { { name = "`users`", alias = "", schema = "" } },
    }, "users", "blog")
    assert.equals("ddl", target.kind)
    assert.equals("users", target.table_name)
  end)

  it("and for a table matched through its schema word", function()
    local target = ctx.resolve_detected_target({
      ctx_type = "column",
      tables = { { name = '"Users"', alias = "", schema = "app" } },
    }, "app", "blog")
    assert.equals("ddl", target.kind)
    assert.equals("app", target.schema)
    assert.equals("Users", target.table_name)
  end)
end)

describe("introspect context CREATE TABLE ... LIKE", function()
  it("resolves the source table after LIKE as a DDL target", function()
    local sql = "CREATE TABLE `bak_dr3_20261120_merchant_account` LIKE `merchant_account`;"
    local target = ctx.resolve_create_table_like_source(
      sql, cursor_on(sql, "merchant_account"), "merchant_account", "appdb")

    assert.same({
      kind = "ddl",
      db = "appdb",
      schema = nil,
      table_name = "merchant_account",
    }, target)
  end)

  it("resolves a multiline source table", function()
    local sql = "CREATE TEMPORARY TABLE backup\nLIKE source;"
    local target = ctx.resolve_create_table_like_source(
      sql, cursor_on(sql, "source"), "source", "appdb")

    assert.same({
      kind = "ddl",
      db = "appdb",
      schema = nil,
      table_name = "source",
    }, target)
  end)

  it("keeps a qualified source schema", function()
    local sql = "CREATE TABLE backup LIKE app.source;"
    local target = ctx.resolve_create_table_like_source(
      sql, cursor_on(sql, "source"), "source", "appdb")

    assert.same({
      kind = "ddl",
      db = "appdb",
      schema = "app",
      table_name = "source",
    }, target)
  end)

  it("does not hijack the destination table", function()
    local sql = "CREATE TABLE backup LIKE source;"
    local target = ctx.resolve_create_table_like_source(
      sql, cursor_on(sql, "backup"), "backup", "appdb")

    assert.is_nil(target)
  end)
end)
