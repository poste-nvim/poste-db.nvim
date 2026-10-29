-- Tests for lua/poste-db/db_browser/operations.lua
-- Pure SQL-template and node-helper tests (no real DB / no UI).

local operations = require("poste-db.db_browser.operations")
local t = operations._test

local function table_node(overrides)
  local base = {
    node_type = "table",
    name = "users",
    meta = { schema = "public", database = "blog" },
  }
  return vim.tbl_extend("force", base, overrides or {})
end

local function column_node(overrides)
  local base = {
    node_type = "column",
    name = "email",
    meta = { col_type = "VARCHAR", nullable = true },
  }
  return vim.tbl_extend("force", base, overrides or {})
end

describe("db_browser operations safe_str", function()
  it("returns nil for nil / vim.NULL", function()
    assert.is_nil(t.safe_str(nil))
    assert.is_nil(t.safe_str(vim.NULL))
  end)

  it("stringifies other values", function()
    assert.equals("text", t.safe_str("text"))
    assert.equals("42", t.safe_str(42))
    assert.equals("true", t.safe_str(true))
  end)
end)

describe("db_browser operations get_columns_from_node", function()
  it("returns nil when node has no column children", function()
    assert.is_nil(t.get_columns_from_node(table_node({ children = {} })))
    assert.is_nil(t.get_columns_from_node(table_node({ children = { { node_type = "index", name = "ix" } } })))
  end)

  it("extracts column name/type/pk/nullable", function()
    local cols = t.get_columns_from_node(table_node({
      children = {
        { node_type = "column", name = "id",   meta = { col_type = "INT4", is_pk = true,  nullable = false } },
        { node_type = "column", name = "bio",  meta = { col_type = "TEXT" } },
        { node_type = "column", name = "flag", meta = { col_type = "BOOL", nullable = false } },
        { node_type = "index",  name = "ix_id" },
      },
    }))
    assert.same({
      { name = "id",   col_type = "INT4", is_pk = true,  nullable = false },
      { name = "bio",  col_type = "TEXT", is_pk = false, nullable = true },
      { name = "flag", col_type = "BOOL", is_pk = false, nullable = false },
    }, cols)
  end)

  it("defaults col_type to TEXT, is_pk to false and nullable to true when meta is empty", function()
    local cols = t.get_columns_from_node(table_node({ children = { { node_type = "column", name = "c", meta = {} } } }))
    assert.same({ { name = "c", col_type = "TEXT", is_pk = false, nullable = true } }, cols)
  end)
end)

describe("db_browser operations qualified_table_ref", function()
  it("quotes bare table for mysql/sqlite", function()
    assert.equals("`users`", t.qualified_table_ref(table_node(), "mysql"))
    assert.equals('"users"', t.qualified_table_ref(table_node(), "sqlite"))
  end)

  it("prefixes the schema for postgres", function()
    assert.equals('"public"."users"', t.qualified_table_ref(table_node(), "postgres"))
  end)

  it("ignores the schema for non-postgres dialects", function()
    assert.equals("`users`", t.qualified_table_ref(table_node(), "mysql"))
  end)

  -- A schema node's name comes from an introspection row, so "there is no
  -- schema here" arrives as `""`, and a JSON null as `vim.NIL` — both truthy.
  -- The generator trusted any truthy name and joined the prefix anyway: `""`
  -- passes through ident.quote as the empty name, so the ref became `."users"`,
  -- a syntax error on Postgres for every statement built from it; and the null
  -- reached `name:gsub` as a userdata, raising inside the menu action.
  it("drops a schema name that names nothing", function()
    for _, blank in ipairs({ "", vim.NIL, 42 }) do
      assert.equals('"users"',
        t.qualified_table_ref(table_node({ meta = { schema = blank, database = "blog" } }), "postgres"))
    end
  end)
end)

describe("db_browser operations build_directive_lines", function()
  it("starts with a blank line and offset 2 when no directives", function()
    local lines, offset = t.build_directive_lines(table_node({ meta = {} }), nil)
    assert.same({ "" }, lines)
    assert.equals(2, offset)
  end)

  it("emits connection then database headers in order", function()
    local lines, offset = t.build_directive_lines(table_node(), "prod")
    assert.same({ "", "-- @connection prod", "-- @database blog" }, lines)
    assert.equals(4, offset)
  end)

  -- `-- @database ` with a blank value selects nothing (constants.directive_value
  -- answers nil for it): a line of noise in the generated file that reads as a
  -- target. A null name made the concat raise instead.
  it("emits no header for a name that names nothing", function()
    local lines, offset = t.build_directive_lines(
      table_node({ meta = { schema = "public", database = "" } }), "")
    assert.same({ "" }, lines)
    assert.equals(2, offset, "the cursor stays on the first statement line")

    local with_conn, with_offset = t.build_directive_lines(
      table_node({ meta = { schema = "public", database = vim.NIL } }), "prod")
    assert.same({ "", "-- @connection prod" }, with_conn)
    assert.equals(3, with_offset)
  end)
end)

describe("db_browser operations build_alter_column_sql (postgres)", function()
  it("emits TYPE change plus optional SET NOT NULL / SET DEFAULT / COMMENT", function()
    local sql = t.build_alter_column_sql(table_node(), column_node(), {
      col_type = "TEXT", nullable = false, default_val = "''", comment_val = "note",
    }, "postgres")
    assert.same({
      'ALTER TABLE "public"."users" ALTER COLUMN "email" TYPE TEXT;',
      'ALTER TABLE "public"."users" ALTER COLUMN "email" SET NOT NULL;',
      [[ALTER TABLE "public"."users" ALTER COLUMN "email" SET DEFAULT '';]],
      [[COMMENT ON COLUMN "public"."users"."email" IS 'note';]],
    }, sql)
  end)

  it("skips SET NOT NULL when nullable and SET DEFAULT when empty default", function()
    local sql = t.build_alter_column_sql(table_node(), column_node(), {
      col_type = "VARCHAR(255)", nullable = true, default_val = nil, comment_val = nil,
    }, "postgres")
    assert.same({ 'ALTER TABLE "public"."users" ALTER COLUMN "email" TYPE VARCHAR(255);' }, sql)
  end)

  it("emits DROP DEFAULT for an emptied Default field", function()
    -- BEHAVIOR CHANGE (2026-10-30 audit): an emptied Default field used to
    -- bind `SET DEFAULT ''` — silently replacing e.g. DEFAULT now() with the
    -- empty string. A cleared field means the user wants the default GONE.
    local sql = t.build_alter_column_sql(table_node(), column_node(), {
      col_type = "TEXT", nullable = true, default_val = "", comment_val = nil,
    }, "postgres")
    assert.equals([[ALTER TABLE "public"."users" ALTER COLUMN "email" DROP DEFAULT;]], sql[2])
  end)

  it("escapes single quotes inside comments", function()
    local sql = t.build_alter_column_sql(table_node(), column_node(), {
      col_type = "TEXT", nullable = true, default_val = nil, comment_val = "it's",
    }, "postgres")
    assert.equals([[COMMENT ON COLUMN "public"."users"."email" IS 'it''s';]], sql[2])
  end)

  it("quotes the bare table when no schema is known", function()
    local sql = t.build_alter_column_sql(table_node({ meta = {} }), column_node(), {
      col_type = "TEXT", nullable = true, default_val = nil, comment_val = nil,
    }, "postgres")
    assert.equals('ALTER TABLE "users" ALTER COLUMN "email" TYPE TEXT;', sql[1])
  end)
end)

describe("db_browser operations build_alter_column_sql (mysql)", function()
  it("emits a single MODIFY COLUMN statement", function()
    local sql = t.build_alter_column_sql(table_node(), column_node(), {
      col_type = "INT", nullable = false, default_val = "0", comment_val = "zero",
    }, "mysql")
    assert.same({ "ALTER TABLE `users` MODIFY COLUMN `email` INT NOT NULL DEFAULT 0 COMMENT 'zero';" }, sql)
  end)

  it("omits the DEFAULT clause for an emptied field (MODIFY drops it)", function()
    -- MySQL has no inline DROP DEFAULT on MODIFY: redefining the column
    -- without a DEFAULT clause removes the existing default. The old shape
    -- bound `DEFAULT ''` instead.
    local sql = t.build_alter_column_sql(table_node(), column_node(), {
      col_type = "INT", nullable = true, default_val = "", comment_val = nil,
    }, "mysql")
    assert.same({ "ALTER TABLE `users` MODIFY COLUMN `email` INT;" }, sql)
  end)
end)

describe("db_browser operations build_alter_column_sql (dialect spellings)", function()
  it("clickhouse uses MODIFY COLUMN plus COMMENT COLUMN", function()
    local sql = t.build_alter_column_sql(table_node(), column_node(), {
      col_type = "String", nullable = true, default_val = nil, comment_val = "note",
    }, "clickhouse")
    assert.same({
      'ALTER TABLE `users` MODIFY COLUMN `email` String;',
      [[ALTER TABLE `users` COMMENT COLUMN `email` 'note';]],
    }, sql)
  end)

  it("mssql drops the TYPE keyword and comments the DEFAULT constraint", function()
    local sql = t.build_alter_column_sql(table_node(), column_node(), {
      col_type = "NVARCHAR(100)", nullable = false, default_val = "0", comment_val = nil,
    }, "mssql")
    assert.same({
      "ALTER TABLE [users] ALTER COLUMN [email] NVARCHAR(100) NOT NULL;",
      "-- DEFAULT needs a separate named constraint:",
      "-- ALTER TABLE [users] ADD CONSTRAINT DF_email DEFAULT 0 FOR [email];",
    }, sql)
  end)

  it("sqlite cannot alter types in place — guidance comments only", function()
    local sql = t.build_alter_column_sql(table_node(), column_node(), {
      col_type = "TEXT", nullable = true, default_val = nil, comment_val = nil,
    }, "sqlite")
    assert.same({
      "-- SQLite does not support ALTER COLUMN TYPE directly.",
      "-- Recreate users to change email to TEXT.",
    }, sql)
  end)
end)
describe("db_browser operations new_query", function()
  it("quotes USE with the dialect of the browsed connection", function()
    -- Regression: new_query read an undefined `dialect` global, so the USE
    -- statement fell back to double quotes even on backtick dialects.
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "-- existing" })
    local node = { node_type = "database", name = "mydb", meta = { connection = "dev" } }
    local context = {
      source_buf = src,
      root_nodes = { { name = "dev", meta = { dialect = "mysql" } } },
    }
    operations.new_query(node, context)
    local use_line
    for _, l in ipairs(vim.api.nvim_buf_get_lines(src, 0, -1, false)) do
      if l:match("^USE ") then use_line = l end
    end
    assert.equals("USE `mydb`;", use_line)
    vim.api.nvim_buf_delete(src, { force = true })
  end)
end)

describe("db_browser operations new_table_ref", function()
  -- `Name` in the New Table form is typed, so it can arrive as a qualified
  -- reference. quote_ref splits it, and the browsed schema must then not be
  -- prepended again — that emitted `"analytics"."analytics"."events"`, naming
  -- a table that does not exist.
  it("splits a typed qualifier instead of prepending the schema again", function()
    assert.equals('"analytics"."events"', t.new_table_ref("analytics.events", "analytics", "postgres"))
  end)

  it("prepends the browsed schema for a bare name", function()
    assert.equals('"analytics"."events"', t.new_table_ref("events", "analytics", "postgres"))
  end)

  it("leaves the prefix to the connection for mysql and sqlite", function()
    assert.equals("`analytics`.`events`", t.new_table_ref("analytics.events", "analytics", "mysql"))
    assert.equals("`events`", t.new_table_ref("events", "analytics", "mysql"))
    -- sqlite has no schema clause to qualify with
    assert.equals('"events"', t.new_table_ref("events", "analytics", "sqlite"))
  end)

  it("still qualifies a name whose own dots are not a prefix", function()
    -- `my..table` is one table, so no split happens and the schema still has to
    -- go in front — testing for "contains a dot" instead dropped it here.
    assert.equals('"analytics"."my..table"', t.new_table_ref("my..table", "analytics", "postgres"))
  end)
end)

describe("db_browser operations update_template", function()
  --- Insert the template into a scratch buffer and return its SQL body (the
  --- `-- @…` directive header is not part of what is being asserted).
  local function render(node)
    local src = vim.api.nvim_create_buf(false, true)
    local ok, err = pcall(operations.update_template, node, { source_buf = src })
    local lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
    vim.api.nvim_buf_delete(src, { force = true })
    assert.is_true(ok, tostring(err))
    for i, l in ipairs(lines) do
      if l:match("^UPDATE ") then return table.concat(lines, "\n", i) end
    end
    return "<no UPDATE line in:\n" .. table.concat(lines, "\n") .. ")"
  end

  local function table_with(columns)
    local children = {}
    for _, c in ipairs(columns) do
      table.insert(children, { node_type = "column", name = c[1], meta = { is_pk = c[2] } })
    end
    return table_node({ meta = { dialect = "postgres" }, children = children })
  end

  it("separates SET assignments with commas and drops the last one", function()
    assert.equals([[UPDATE "users"
SET
  "name" = 'val',
  "bio" = 'val'
WHERE "id" = ?;
]], render(table_with({ { "id", true }, { "name", false }, { "bio", false } })))
  end)

  it("keeps the SET keyword when the key is the only column", function()
    -- Regression: the trailing comma was stripped from whichever line came
    -- last, so with no non-PK columns that line was the bare `SET` — and the
    -- template started with `SE`.
    local sql = render(table_with({ { "id", true } }))
    assert.is_nil((sql .. "\n"):match("\nSE\n"))
    assert.equals([[UPDATE "users"
SET
  "id" = ?
WHERE "id" = ?;
]], sql)
  end)

  it("emits every key column in the WHERE clause", function()
    assert.equals([[UPDATE "users"
SET
  "name" = 'val'
WHERE "a" = ? AND "b" = ?;
]], render(table_with({ { "a", true }, { "b", true }, { "name", false } })))
  end)
end)

describe("db_browser operations insert_template", function()
  local function table_with(columns)
    local children = {}
    for _, c in ipairs(columns) do
      table.insert(children, { node_type = "column", name = c[1], meta = { is_pk = c[2] } })
    end
    return table_node({ meta = { dialect = "postgres" }, children = children })
  end

  local function render(node)
    local src = vim.api.nvim_create_buf(false, true)
    local ok, err = pcall(operations.insert_template, node, { source_buf = src })
    local lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
    vim.api.nvim_buf_delete(src, { force = true })
    assert.is_true(ok, tostring(err))
    for i, l in ipairs(lines) do
      if l:match("^INSERT INTO") then return l end
    end
    return "<no INSERT line in:\n" .. table.concat(lines, "\n") .. ")"
  end

  it("leaves the serial key out of the column list", function()
    assert.equals('INSERT INTO "users" ("name", "bio")',
      render(table_with({ { "id", true }, { "name", false }, { "bio", false } })))
  end)

  it("falls back to the key columns for a junction table", function()
    -- With every column part of the key the skip-everything list came out
    -- empty: `INSERT INTO "users" ()`, which no engine parses.
    assert.equals('INSERT INTO "users" ("a", "b")',
      render(table_with({ { "a", true }, { "b", true } })))
  end)
end)

describe("db_browser operations select_star", function()
  --- Run `fn` with the cursor parked on `line` of a throwaway window, which is
  --- what leaf rows resolve their table through.
  local function at_line(line, fn)
    local view = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(view, 0, -1, false, { "1", "2", "3", "4", "5" })
    local win = vim.api.nvim_open_win(view, true, {
      relative = "editor", width = 30, height = 5, row = 0, col = 0,
    })
    vim.api.nvim_win_set_cursor(win, { line, 0 })
    local ok, err = pcall(fn)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(view, { force = true })
    assert.is_true(ok, tostring(err))
  end

  local function first_sql_line(src, prefix)
    for _, l in ipairs(vim.api.nvim_buf_get_lines(src, 0, -1, false)) do
      if l:find(prefix, 1, true) then return l end
    end
    return "<no SELECT line in:\n" .. table.concat(vim.api.nvim_buf_get_lines(src, 0, -1, false), "\n") .. ")"
  end

  it("resolves a column row to the table above it in the line map", function()
    local tbl = table_node({ meta = { schema = "app", database = "blog", dialect = "postgres" } })
    local col = column_node()
    local src = vim.api.nvim_create_buf(false, true)
    at_line(4, function()
      operations.select_star(col, { source_buf = src, line_to_node = { [3] = tbl, [4] = col } })
    end)
    assert.equals('SELECT * FROM "app"."users" LIMIT 100;', first_sql_line(src, "SELECT"))
    vim.api.nvim_buf_delete(src, { force = true })
  end)

  it("keeps the view row it was called on", function()
    -- A view is a `table` node tagged meta.table_type = "VIEW". There is no
    -- "view" node type in the browser, so a view row must be used as-is rather
    -- than re-resolved to whatever table sits above it.
    local view = table_node({
      name = "active_users",
      meta = { schema = "app", database = "blog", dialect = "postgres", table_type = "VIEW" },
    })
    local src = vim.api.nvim_create_buf(false, true)
    at_line(1, function()
      operations.select_star(view, { source_buf = src, line_to_node = {} })
    end)
    assert.equals('SELECT * FROM "app"."active_users" LIMIT 100;', first_sql_line(src, "SELECT"))
    vim.api.nvim_buf_delete(src, { force = true })
  end)
end)

describe("db_browser operations rename header", function()
  -- rename assembled the `-- @connection` / `-- @database` header inline while
  -- every other generator went through ops_sql.build_directive_lines, so it kept
  -- emitting both lines for a node whose connection/database were blank — a
  -- directive that selects nothing, inserted ahead of the statement the user
  -- asked for. It now shares the one header builder.
  local saved_notify

  before_each(function()
    saved_notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    vim.notify = saved_notify
  end)

  --- Answer vim.ui.input with `new_name`, then hand back the source buffer.
  local function rename(node, context, new_name)
    local saved_input = vim.ui.input
    vim.ui.input = function(_, cb) cb(new_name) end
    local ok, err = pcall(operations.rename, node, context)
    vim.ui.input = saved_input
    assert.is_true(ok, tostring(err))
    return context.source_buf
  end

  --- The lines appended after the seed line, blank separator included.
  local function tail(src)
    return vim.api.nvim_buf_get_lines(src, 1, -1, false)
  end

  it("writes no directive lines for names the node does not have", function()
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "-- seed" })
    local node = table_node({ meta = { schema = "public", database = "", connection = "" } })
    rename(node, { source_buf = src, line_to_node = {}, root_nodes = {} }, "members")
    assert.same({ "", 'ALTER TABLE "public"."users" RENAME TO "members";', "" }, tail(src))
    vim.api.nvim_buf_delete(src, { force = true })
  end)

  it("still names the target when the node does have one", function()
    local src = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src, 0, -1, false, { "-- seed" })
    local node = table_node({ meta = { schema = "public", database = "blog", connection = "prod" } })
    rename(node, { source_buf = src, line_to_node = {}, root_nodes = {} }, "members")
    assert.same({
      "",
      "-- @connection prod",
      "-- @database blog",
      'ALTER TABLE "public"."users" RENAME TO "members";',
      "",
    }, tail(src))
    vim.api.nvim_buf_delete(src, { force = true })
  end)
end)

--- The DDL float's failure path and the names its command carries: what the
--- user reads, and what the journal keeps, has to be the reason the process
--- gave — not just its exit code.
describe("db_browser operations show_ddl failure reporting", function()
  local sql_log = require("poste-db.sql_log")
  local cli = require("poste-db.cli")
  local path, opts, cmd, saved_run, saved_connections, saved_notify

  local function arg_value(flag)
    for i, v in ipairs(cmd or {}) do
      if v == flag then return cmd[i + 1] end
    end
    return nil
  end

  local function read_entries()
    local out = {}
    for _, l in ipairs(vim.fn.readfile(path)) do
      table.insert(out, vim.json.decode(l))
    end
    return out
  end

  before_each(function()
    path = vim.fn.tempname() .. ".jsonl"
    sql_log.set_log_path(path)
    opts = nil
    cmd = nil
    saved_run = cli.run_async
    cli.run_async = function(c, cb)
      cmd = c
      opts = cb
      return 1
    end
    saved_connections = package.loaded["poste-db.connections"]
    package.loaded["poste-db.connections"] = {
      resolve_connection_url = function() return "pg://u:pw@h/db" end,
    }
    -- ERROR notifies print through the error channel in a headless run and
    -- crash plenary's harness when they land after the test ended.
    saved_notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    -- Drain before restoring the stub: the failure notify is `vim.schedule`d,
    -- and letting it land on the real handler prints mid-next-test.
    vim.wait(100, function() return false end)
    vim.notify = saved_notify
    cli.run_async = saved_run
    package.loaded["poste-db.connections"] = saved_connections
    sql_log.set_log_path(nil)
    if path and vim.fn.filereadable(path) == 1 then vim.fn.delete(path) end
  end)

  local function ddl_node()
    return table_node({ meta = { schema = "public", database = "blog", connection = "pg-dev" } })
  end

  it("journals the stderr text of a rejected fetch", function()
    operations.show_ddl(ddl_node(), {})
    opts.on_stderr({ 'relation "users" does not exist' })
    opts.on_exit(1)

    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("error", entries[1].status)
    assert.equals('relation "users" does not exist', entries[1].error)
    assert.equals("pg-dev", entries[1].connection)
    -- The URL is argv, not something the journal should carry.
    assert.is_nil(entries[1].sql:find("pg://", 1, true))
  end)

  it("journals the exit code when the process said nothing", function()
    operations.show_ddl(ddl_node(), {})
    opts.on_stderr({ "" })
    opts.on_exit(3)

    local entries = read_entries()
    assert.equals(1, #entries)
    assert.equals("exit 3", entries[1].error)
  end)

  -- The names come straight off a listing row: `""` is a server's way of
  -- saying "this connection's own database" and a JSON null decodes to
  -- vim.NIL. Both are truthy, and the CLI applies `--database` as
  -- replace_database_in_url — the DDL then described a table in whichever
  -- database the stripped URL pointed at, not the one the user clicked.
  it("carries only the names a node actually has", function()
    operations.show_ddl(table_node({
      meta = { schema = "", database = "", connection = "pg-dev" },
    }), {})
    assert.equals("users", arg_value("--table"))
    assert.is_nil(arg_value("--schema"))
    assert.is_nil(arg_value("--database"))

    operations.show_ddl(ddl_node(), {})
    assert.equals("public", arg_value("--schema"))
    assert.equals("blog", arg_value("--database"))
  end)

  it("keeps a JSON null name out of the command instead of raising", function()
    operations.show_ddl(table_node({
      meta = { schema = vim.NIL, database = vim.NIL, connection = "pg-dev" },
    }), {})
    assert.equals("users", arg_value("--table"))
    assert.is_nil(arg_value("--schema"))
    assert.is_nil(arg_value("--database"))
  end)
end)
