local detect = require("poste-db.nav.detect")

describe("nav_detect", function()
  it("extracts the SQL block around the current line", function()
    local info = detect.extract_sql_block({
      "### query",
      "select",
      "from authors",
      "### other",
    }, 2, "select", 6)

    assert.same({
      block_start = 2,
      block_end = 3,
      offset = 5,
      sql_text = "select\nfrom authors",
    }, info)
  end)

  it("resolves dot_column aliases to a table target", function()
    local target = detect.resolve_detected_table_target({
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
end)

-- nav/handlers.lua extends the cursor column forward to the first non-word
-- character, so `end_col` is the 0-based index just past the word under the
-- cursor ("select u.name" with the cursor on name → end_col = 13).
describe("nav_detect alias prefix", function()
  local parsed = {
    ctx_type = "column",
    tables = {
      { name = "comments", alias = "c" },
      { name = "posts", alias = "u" },
    },
  }
  local ctx = { connection = "conn", database = "blog" }

  it("resolves the prefix alias when the cursor sits on the column", function()
    local target = detect.resolve_detected_table_target(parsed, "select u.name from x", 13, "name", ctx)

    assert.same({
      action = "navigate_to_table",
      database = "blog",
      table_name = "posts",
      column_name = "name",
    }, target)
  end)

  it("falls back to the first table for an unknown prefix instead of guessing", function()
    local target = detect.resolve_detected_table_target(parsed, "select z.name from x", 13, "name", ctx)

    assert.same({
      action = "navigate_to_table",
      database = "blog",
      table_name = "comments",
      column_name = "name",
    }, target)
  end)
end)

-- The after-dot word is only the column when the cursor word ends right
-- before a dot (cursor on the alias of `alias.column`). A comma, space or
-- paren after the word means the cursor word IS the column; the old
-- unconditional scan stole the next token, so `SELECT p.title,o.x` with
-- the cursor on title navigated to column "o".
describe("nav_detect column word scan", function()
  local parsed = {
    ctx_type = "dot_column",
    ctx_data = "p",
    tables = { { name = "posts", alias = "p" } },
  }
  local ctx = { connection = "conn", database = "blog" }

  it("keeps the cursor column when a comma without space follows", function()
    -- "SELECT p.title,o.x": `title` ends at 0-based col 14, "," is next.
    local target = detect.resolve_detected_table_target(parsed, "SELECT p.title,o.x", 14, "title", ctx)

    assert.same("title", target.column_name)
  end)

  it("still reads the column after the dot when the cursor sits on the alias", function()
    -- "SELECT p.title": `p` ends at 0-based col 8, "." is next.
    local target = detect.resolve_detected_table_target(parsed, "SELECT p.title", 8, "p", ctx)

    assert.same("title", target.column_name)
  end)

  it("applies the same guard inside an INSERT column list", function()
    local ins = {
      ctx_type = "insert_column",
      ctx_data = "t",
      tables = { { name = "t" } },
    }
    -- "INSERT INTO t (a,b)": `a` ends at 0-based col 16, "," is next.
    local target = detect.resolve_detected_table_target(ins, "INSERT INTO t (a,b)", 16, "a", ctx)

    assert.same("a", target.column_name)
  end)
end)

-- Detect responses carry the source spelling of a name (`` `users` `` from a
-- MySQL buffer); matching against the bare cword only works after the strip,
-- and navigation targets get the bare name so introspection args are not
-- double-quoted. (Today's binary answers with bare names already — both
-- sides strip so a future quoting binary cannot break them unevenly.)
describe("nav_detect quoted names", function()
  it("matches a backticked table name against a bare cword", function()
    local target = detect.resolve_detected_table_target({
      ctx_type = "table",
      tables = { { name = "`posts`", alias = "p" } },
    }, "select * from posts", 18, "posts", { connection = "c", database = "blog" })

    assert.same({
      action = "navigate_to_table",
      database = "blog",
      table_name = "posts",
      column_name = nil,
    }, target)
  end)

  it("resolves a quoted alias to the stripped table name", function()
    local target = detect.resolve_detected_table_target({
      ctx_type = "dot_column",
      ctx_data = "p",
      tables = { { name = "`posts`", alias = "`p`" } },
    }, "p.title", 1, "title", { connection = "c", database = "blog" })

    assert.same("posts", target.table_name)
  end)
end)

-- The introspect sibling (introspect/context.lua) stopped folding the dotted
-- prefix into the database in the 2026-10-30 round; this copy still did, so
-- `gd` on postgres's `app.users` went looking for a database called `app`.
-- The prefix now rides on `schema`, and nav/handlers decides per dialect
-- whether it is a database (MySQL) or a schema inside the current one.
describe("nav_detect dotted prefix", function()
  local ctx = { connection = "conn", database = "blog" }

  it("hands a matched table's prefix back as schema, not as the database", function()
    local target = detect.resolve_detected_table_target({
      ctx_type = "table",
      tables = { { name = "users", schema = "app" } },
    }, "select * from app.users", 22, "users", ctx)
    assert.same({
      action = "navigate_to_table",
      database = "blog",
      schema = "app",
      table_name = "users",
    }, target)
  end)

  it("does the same for a schema_table context and a resolved alias", function()
    local st = detect.resolve_detected_table_target({
      ctx_type = "schema_table",
      ctx_data = "app",
      tables = { { name = "users", schema = "app" } },
    }, "app.users", 9, "users", ctx)
    assert.equals("blog", st.database)
    assert.equals("app", st.schema)

    local col = detect.resolve_detected_table_target({
      ctx_type = "column",
      tables = { { name = "users", alias = "u", schema = "app" } },
    }, "select u.name", 13, "name", ctx)
    assert.equals("blog", col.database)
    assert.equals("app", col.schema)
    assert.equals("users", col.table_name)
    assert.equals("name", col.column_name)
  end)

  it("leaves schema unset for an unqualified table", function()
    local target = detect.resolve_detected_table_target({
      ctx_type = "table",
      tables = { { name = "users", schema = "" } },
    }, "select * from users", 18, "users", ctx)
    assert.is_nil(target.schema)
    assert.equals("blog", target.database)
  end)
end)

describe("constants.dotted_prefix_is_database", function()
  local const = require("poste-db.constants")
  it("is true for the dialects without a schema layer", function()
    assert.is_true(const.dotted_prefix_is_database("mysql"))
    assert.is_true(const.dotted_prefix_is_database("mariadb"))
    assert.is_true(const.dotted_prefix_is_database("clickhouse"))
  end)
  it("is false where the prefix is a schema inside the database", function()
    assert.is_false(const.dotted_prefix_is_database("postgres"))
    assert.is_false(const.dotted_prefix_is_database("mssql"))
    assert.is_false(const.dotted_prefix_is_database("sqlite"))
    assert.is_false(const.dotted_prefix_is_database(nil))
  end)
end)
