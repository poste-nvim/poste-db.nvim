local ctx = require("poste-db.introspect.context")

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
