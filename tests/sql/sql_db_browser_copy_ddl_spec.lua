-- Tests for lua/poste-db/db_browser/copy_ddl.lua
-- Pure transform helpers (no DB / no UI) — characterization coverage.

local ddl_mod = require("poste-db.db_browser.copy_ddl")

describe("db_browser copy_ddl quote_value", function()
  it("renders NULL for nil / vim.NULL", function()
    assert.equals("NULL", ddl_mod.quote_value(nil))
    assert.equals("NULL", ddl_mod.quote_value(vim.NULL))
  end)

  it("renders numbers and booleans unquoted", function()
    assert.equals("42", ddl_mod.quote_value(42))
    assert.equals("3.5", ddl_mod.quote_value(3.5))
    assert.equals("TRUE", ddl_mod.quote_value(true))
    assert.equals("FALSE", ddl_mod.quote_value(false))
  end)

  it("escapes single quotes in strings", function()
    assert.equals("'it''s'", ddl_mod.quote_value("it's"))
  end)

  it("JSON-encodes tables into a quoted literal", function()
    assert.equals('\'{"a":1}\'', ddl_mod.quote_value({ a = 1 }))
  end)

  it("falls back to NULL when a table cannot be encoded", function()
    assert.equals("NULL", ddl_mod.quote_value({ fn = function() end }))
  end)

  it("doubles backslashes only for the dialects that read them as escapes", function()
    -- Regression: quote_value had no dialect, so a `a\b` value was sent raw —
    -- MySQL/MariaDB/ClickHouse swallowed the next character and stored `ab`.
    assert.equals([['a\\b']], ddl_mod.quote_value("a\\b", "mysql"))
    assert.equals([['a\\b']], ddl_mod.quote_value("a\\b", "mariadb"))
    assert.equals([['a\\b']], ddl_mod.quote_value("a\\b", "clickhouse"))
    assert.equals([['a\b']], ddl_mod.quote_value("a\\b", "postgres"))
    assert.equals([['a\b']], ddl_mod.quote_value("a\\b", "sqlite"))
    assert.equals([['a\b']], ddl_mod.quote_value("a\\b"))
  end)

  it("escapes the JSON encoding of a nested value the same way", function()
    -- json.encode already escapes the backslash; the dialect layer doubles
    -- that pair again, which is what a MySQL literal needs
    assert.equals([['{"s":"a\\\\b"}']], ddl_mod.quote_value({ s = "a\\b" }, "mysql"))
    assert.equals([['{"s":"a\\b"}']], ddl_mod.quote_value({ s = "a\\b" }, "postgres"))
    assert.equals([['{"s":"it''s"}']], ddl_mod.quote_value({ s = "it's" }, "postgres"))
  end)
end)

describe("db_browser copy_ddl result field extraction", function()
  it("prefers affected_rows, then row_count, then ?", function()
    assert.equals("5", ddl_mod.extract_row_count({ affected_rows = 5 }))
    assert.equals("7", ddl_mod.extract_row_count({ row_count = 7 }))
    assert.equals("3", ddl_mod.extract_row_count({ affected_rows = vim.NIL, row_count = "3" }))
    assert.equals("?", ddl_mod.extract_row_count({}))
  end)

  it("formats elapsed or ?", function()
    assert.equals("12ms", ddl_mod.extract_elapsed({ execution_time_ms = 12 }))
    assert.equals("?", ddl_mod.extract_elapsed({}))
    assert.equals("?", ddl_mod.extract_elapsed({ execution_time_ms = vim.NIL }))
  end)

  it("surfaces error over message, nil when clean", function()
    assert.equals("boom", ddl_mod.check_result_error({ results = { { error = "boom", message = "msg" } } }))
    assert.equals("msg", ddl_mod.check_result_error({ results = { { message = "msg" } } }))
    assert.is_nil(ddl_mod.check_result_error({ results = { { row_count = 1 } } }))
    assert.is_nil(ddl_mod.check_result_error({ results = {} }))
    assert.is_nil(ddl_mod.check_result_error(nil))
  end)

  it("scans past the first statement for a rejection", function()
    -- A copy runs a batch (prelude plus several statements); stopping at
    -- results[1] left a later rejection to the caller's coarse envelope sentence.
    assert.equals("permission denied for schema finance",
      ddl_mod.check_result_error({ results = {
        { row_count = 1 },
        { error = "permission denied for schema finance" },
      } }))
    -- `message` is a first-result field: a note on a later statement is not a
    -- failure, and reading it as one would refuse a copy that worked.
    assert.is_nil(ddl_mod.check_result_error({ results = { { row_count = 1 }, { message = "ok" } } }))
  end)

  it("names a flagged statement that carried no text", function()
    local text = ddl_mod.check_result_error({ results = { { failed = true } } })
    assert.truthy(text:find("without a message", 1, true))
  end)

  it("ignores an empty or null error field", function()
    -- An empty string used to reach `on_error("")`: a failure notice with
    -- nothing in it. `vim.NIL` is worse still — callers concatenate it.
    assert.is_nil(ddl_mod.check_result_error({ results = { { error = "" } } }))
    assert.is_nil(ddl_mod.check_result_error({ results = { { error = vim.NIL } } }))
  end)
end)

describe("db_browser copy_ddl extract_schema_from_ddl", function()
  local qualified = 'CREATE TABLE "public"."posts" ('
  local bare = 'CREATE TABLE "posts" ('

  it("reads the schema from a qualified PG header", function()
    assert.equals("public", ddl_mod.extract_schema_from_ddl(qualified, "posts", "postgres"))
  end)

  it("returns nil for a bare header", function()
    assert.is_nil(ddl_mod.extract_schema_from_ddl(bare, "posts", "postgres"))
  end)

  it("returns nil for mysql regardless of the header", function()
    assert.is_nil(ddl_mod.extract_schema_from_ddl(qualified, "posts", "mysql"))
  end)

  it("treats the table name as text, not as a match pattern", function()
    -- Regression: the name was concatenated into the pattern, so `%a` (any
    -- letter) and `.` (any char) matched a *different* table's header — and
    -- the schema came back for a table the copy is not about.
    assert.is_nil(ddl_mod.extract_schema_from_ddl('CREATE TABLE "public"."posts_x" (', "posts%a", "postgres"))
    assert.is_nil(ddl_mod.extract_schema_from_ddl('CREATE TABLE "public"."axb" (', "a.b", "postgres"))
    assert.equals("public", ddl_mod.extract_schema_from_ddl('CREATE TABLE "public"."a.b" (', "a.b", "postgres"))
  end)
end)

describe("db_browser copy_ddl sequence helpers", function()
  it("extracts and dedupes nextval references", function()
    local ddl = "DEFAULT nextval('posts_id_seq'::regclass) , x int DEFAULT nextval('log_seq'::regclass)"
      .. " , y int DEFAULT nextval('posts_id_seq'::regclass)"
    assert.same({ "posts_id_seq", "log_seq" }, ddl_mod.extract_sequences_from_ddl(ddl))
  end)

  it("classifies the sequence column type from the DEFAULT context", function()
    local function ddl_of(col_type)
      return 'CREATE TABLE "posts" (\n  "id" ' .. col_type
        .. " DEFAULT nextval('posts_id_seq'::regclass)\n);"
    end
    assert.equals("bigint", ddl_mod.column_type_for_seq(ddl_of("bigint"), "posts_id_seq"))
    assert.equals("smallint", ddl_mod.column_type_for_seq(ddl_of("smallint"), "posts_id_seq"))
    assert.equals("integer", ddl_mod.column_type_for_seq(ddl_of("integer"), "posts_id_seq"))
    assert.equals("integer", ddl_mod.column_type_for_seq(ddl_of("bigint"), "unknown_seq"))
  end)

  it("renames only the first seq reference", function()
    local ddl = "a int DEFAULT nextval('posts_id_seq'::regclass), b int DEFAULT nextval('posts_id_seq'::regclass)"
    local renamed = ddl_mod.rename_seq_reference(ddl, "posts_id_seq", "posts_copy_id_seq")
    assert.matches("posts_copy_id_seq", renamed)
    assert.equals(1, select(2, renamed:gsub("posts_copy_id_seq", "")))
    assert.equals(1, select(2, renamed:gsub("posts_id_seq", "")))
  end)
end)

describe("db_browser copy_ddl prepare_table_ddl", function()
  it("renames backticked tables on non-postgres without sequence statements", function()
    local ddl = "CREATE TABLE `posts` (\n  `id` bigint DEFAULT nextval('posts_id_seq'::regclass)\n);"
    local out = ddl_mod.prepare_table_ddl(ddl, "posts_copy", "posts", nil, "mysql")
    assert.equals("CREATE TABLE `posts_copy` (\n  `id` bigint DEFAULT nextval('posts_id_seq'::regclass)\n);", out)
  end)

  it("renames quoted tables on postgres when no sequences are present", function()
    local ddl = 'CREATE TABLE "posts" (\n  "title" text\n);'
    local out = ddl_mod.prepare_table_ddl(ddl, "posts_copy", "posts", nil, "postgres")
    assert.equals('CREATE TABLE "posts_copy" (\n  "title" text\n);', out)
  end)

  it("prepends a CREATE SEQUENCE and rewrites the DEFAULT for a bare seq ref", function()
    local ddl = 'CREATE TABLE "posts" (\n  "id" bigint DEFAULT nextval(\'posts_id_seq\'::regclass)\n);'
    local out = ddl_mod.prepare_table_ddl(ddl, "posts_copy", "posts", nil, "postgres")
    assert.equals(
      'CREATE SEQUENCE IF NOT EXISTS "posts_copy_id_seq" AS bigint;\n'
        .. 'CREATE TABLE "posts_copy" (\n  "id" bigint DEFAULT nextval(\'posts_copy_id_seq\'::regclass)\n);',
      out)
  end)

  it("quotes a schema-qualified seq ref once (no doubled schema prefix)", function()
    local ddl = 'CREATE TABLE "public"."posts" (\n  "id" bigint DEFAULT nextval(\'public.posts_id_seq\'::regclass)\n);'
    local out = ddl_mod.prepare_table_ddl(ddl, "posts_copy", "posts", "public", "postgres")
    assert.equals(
      'CREATE SEQUENCE IF NOT EXISTS "public"."posts_copy_id_seq" AS bigint;\n'
        .. 'CREATE TABLE "public"."posts_copy" (\n  "id" bigint DEFAULT nextval(\'public.posts_copy_id_seq\'::regclass)\n);',
      out)
  end)

  it("renames a sequence whose table name holds pattern magic", function()
    -- Regression: the seq rename used the raw table name as a pattern, so
    -- `pct%tbl` matched nothing: the copy got its own CREATE SEQUENCE while
    -- its DEFAULT still pointed at the source sequence, and the two tables
    -- handed out the same ids.
    local ddl = 'CREATE TABLE "pct%tbl" (\n  "id" bigint DEFAULT nextval(\'pct%tbl_id_seq\'::regclass)\n);'
    local out = ddl_mod.prepare_table_ddl(ddl, "pct%tbl_copy", "pct%tbl", nil, "postgres")
    assert.equals(
      'CREATE SEQUENCE IF NOT EXISTS "pct%tbl_copy_id_seq" AS bigint;\n'
        .. 'CREATE TABLE "pct%tbl_copy" (\n  "id" bigint DEFAULT nextval(\'pct%tbl_copy_id_seq\'::regclass)\n);',
      out)
    assert.is_nil(out:find("'pct%tbl_id_seq'", 1, true))
  end)
end)

describe("db_browser copy_ddl dialect_table_exists_sql", function()
  it("uses information_schema + DATABASE() on mysql", function()
    local sql = ddl_mod.dialect_table_exists_sql("mysql", nil, "posts")
    assert.matches("information_schema%.TABLES", sql)
    assert.matches("TABLE_SCHEMA = DATABASE%(%)", sql)
    assert.matches("TABLE_NAME = 'posts'", sql)
  end)

  it("scopes postgres to the schema, defaulting to public", function()
    assert.matches("table_schema = 'app'", ddl_mod.dialect_table_exists_sql("postgres", "app", "posts"))
    assert.matches("table_schema = 'public'", ddl_mod.dialect_table_exists_sql("postgres", nil, "posts"))
  end)

  it("uses sqlite_master for other dialects", function()
    assert.matches("sqlite_master", ddl_mod.dialect_table_exists_sql("sqlite", nil, "posts"))
  end)

  -- The probe runs on every paste. A broken literal does not just fail the
  -- query: the caller fails closed on error, so the collision search then sees
  -- every candidate as taken and never stops bumping suffixes.
  it("doubles an apostrophe in the probed name instead of closing the literal", function()
    assert.equals(
      "SELECT EXISTS (SELECT FROM information_schema.tables"
        .. " WHERE table_schema = 'public' AND table_name = 'it''s')",
      ddl_mod.dialect_table_exists_sql("postgres", "public", "it's"))
  end)

  it("doubles an apostrophe in the schema too", function()
    assert.equals(
      "SELECT EXISTS (SELECT FROM information_schema.tables"
        .. " WHERE table_schema = 'o''b' AND table_name = 'posts')",
      ddl_mod.dialect_table_exists_sql("postgres", "o'b", "posts"))
  end)

  it("escapes the backslash a mysql literal reads as an escape character", function()
    local sql = ddl_mod.dialect_table_exists_sql("mysql", nil, "a\\b")
    assert.is_true(sql:find("TABLE_NAME = 'a\\\\b'", 1, true) ~= nil, sql)
  end)
end)

describe("db_browser copy_ddl rename_routine_in_def", function()
  it("renames a mysql routine without touching the DEFINER clause", function()
    local def = "CREATE DEFINER=`root`@`localhost` PROCEDURE `proc_a`(IN x INT) BEGIN SELECT 1; END"
    local out = ddl_mod.rename_routine_in_def("mysql", def, "proc_a", "proc_copy")
    assert.matches("PROCEDURE `proc_copy`%(", out)
    assert.matches("DEFINER=`root`@`localhost`", out)
  end)

  it("renames a schema-qualified mysql routine name", function()
    local def = "CREATE PROCEDURE `myschema`.`proc_a`() BEGIN END"
    local out = ddl_mod.rename_routine_in_def("mysql", def, "proc_a", "proc_copy")
    assert.equals("CREATE PROCEDURE `myschema`.`proc_copy`() BEGIN END", out)
  end)

  it("renames the routine's own name, not a later body mention", function()
    -- the name precedes the body, so the first `src` after the keyword is the
    -- name even when a statement inside the body references the same string
    local def = "CREATE PROCEDURE `proc_a`() BEGIN SELECT * FROM `proc_a`; END"
    local out = ddl_mod.rename_routine_in_def("mysql", def, "proc_a", "proc_copy")
    assert.equals("CREATE PROCEDURE `proc_copy`() BEGIN SELECT * FROM `proc_a`; END", out)
  end)

  it("renames a mysql name whose backtick the catalog doubled", function()
    -- SHOW CREATE escapes an inner backtick by doubling it, which is exactly
    -- what ident.quote builds — so the name is found and renamed instead of
    -- being silently kept (the paste used to report a copy under the new name
    -- while creating the routine under the old one).
    local def = "CREATE PROCEDURE `a``b`() BEGIN END"
    local out = ddl_mod.rename_routine_in_def("mysql", def, "a`b", "copy")
    assert.equals("CREATE PROCEDURE `copy`() BEGIN END", out)
  end)

  it("renames a schema-qualified postgres function", function()
    local out = ddl_mod.rename_routine_in_def(
      "postgres", "CREATE OR REPLACE FUNCTION public.func_a(int) RETURNS void AS $$ BEGIN END $$ LANGUAGE plpgsql;",
      "func_a", "func_copy")
    assert.equals("CREATE OR REPLACE FUNCTION public.\"func_copy\"(int) RETURNS void AS $$ BEGIN END $$ LANGUAGE plpgsql;", out)
  end)

  it("renames a postgres function name before the parameter list", function()
    local out = ddl_mod.rename_routine_in_def(
      "postgres", "CREATE FUNCTION func_a() RETURNS void AS $$ BEGIN END $$;", "func_a", "func_copy")
    assert.equals("CREATE FUNCTION \"func_copy\"() RETURNS void AS $$ BEGIN END $$;", out)
  end)

  it("anchors on the first routine keyword, not a later mention in the body", function()
    -- pg_get_functiondef output starts with CREATE FUNCTION; a body that says
    -- the word "procedure" must not move the anchor past the real name.
    local def = "CREATE FUNCTION func_a() RETURNS void AS $$ BEGIN RAISE 'not a procedure'; END $$;"
    local out = ddl_mod.rename_routine_in_def("postgres", def, "func_a", "func_copy")
    assert.equals("CREATE FUNCTION \"func_copy\"() RETURNS void AS $$ BEGIN RAISE 'not a procedure'; END $$;", out)
  end)

  -- The catalog quotes a name that needs it, and the paste dialog's target name
  -- is whatever the user typed. Matching only the bare spelling used to leave a
  -- quoted source name unrenamed — the paste then created (with CREATE OR
  -- REPLACE, replaced) the source routine while the summary reported the copy
  -- under the requested name — and a target with a space or upper case went out
  -- bare, which Postgres folds to lower case or rejects outright.
  it("renames a postgres function whose name is quoted", function()
    local out = ddl_mod.rename_routine_in_def("postgres",
      'CREATE OR REPLACE FUNCTION public."Add Two"(integer) RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;',
      "Add Two", "sum_two")
    assert.equals('CREATE OR REPLACE FUNCTION public."sum_two"(integer) RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;', out)
  end)

  it("renames a quoted procedure name too", function()
    local out = ddl_mod.rename_routine_in_def("postgres",
      'CREATE OR REPLACE PROCEDURE public."mixed CASE"(int) AS $$ BEGIN END $$ LANGUAGE sql;',
      "mixed CASE", "other name")
    assert.equals('CREATE OR REPLACE PROCEDURE public."other name"(int) AS $$ BEGIN END $$ LANGUAGE sql;', out)
  end)

  it("keeps a target name that needs quoting as one identifier", function()
    local out = ddl_mod.rename_routine_in_def("postgres",
      "CREATE FUNCTION report() RETURNS void AS $$ SELECT 1 $$;", "report", "My Report")
    assert.equals('CREATE FUNCTION "My Report"() RETURNS void AS $$ SELECT 1 $$;', out)
  end)

  it("matches a source name carrying the quote character itself", function()
    -- pg_get_functiondef doubles an inner double quote, and that is the
    -- spelling ident.quote produces, so the quoted form still matches.
    local out = ddl_mod.rename_routine_in_def("postgres",
      'CREATE FUNCTION "a""b"() RETURNS void AS $$ SELECT 1 $$;', 'a"b', "c")
    assert.equals('CREATE FUNCTION "c"() RETURNS void AS $$ SELECT 1 $$;', out)
  end)

  it("renames when whitespace sits between the name and the parameter list", function()
    local out = ddl_mod.rename_routine_in_def("postgres",
      "CREATE FUNCTION func_a () RETURNS void AS $$ SELECT 1 $$;", "func_a", "func_b")
    assert.equals('CREATE FUNCTION "func_b"() RETURNS void AS $$ SELECT 1 $$;', out)
  end)

  it("quotes an mssql routine name in brackets, not double quotes", function()
    local out = ddl_mod.rename_routine_in_def("mssql",
      "CREATE FUNCTION [dbo].[f_a](@p int) RETURNS int AS BEGIN RETURN 1 END", "f_a", "F b")
    assert.equals("CREATE FUNCTION [dbo].[F b](@p int) RETURNS int AS BEGIN RETURN 1 END", out)
  end)

  it("escapes a target name that carries a backtick for mysql", function()
    local out = ddl_mod.rename_routine_in_def("mysql",
      "CREATE PROCEDURE `proc_a`() BEGIN END", "proc_a", "a`b")
    assert.equals("CREATE PROCEDURE `a``b`() BEGIN END", out)
  end)

  it("leaves the definition alone when the target name is empty", function()
    local def = "CREATE FUNCTION func_a(int) RETURNS void;"
    assert.equals(def, ddl_mod.rename_routine_in_def("postgres", def, "func_a", ""))
    assert.equals(def, ddl_mod.rename_routine_in_def("postgres", def, "func_a", nil))
  end)

  it("does the same for a mysql function whose body mentions procedure", function()
    local def = "CREATE FUNCTION `func_a`() RETURNS int BEGIN SELECT 'a procedure'; END"
    local out = ddl_mod.rename_routine_in_def("mysql", def, "func_a", "func_copy")
    assert.equals("CREATE FUNCTION `func_copy`() RETURNS int BEGIN SELECT 'a procedure'; END", out)
  end)

  it("returns the definition unchanged when no routine keyword is present", function()
    local def = "CREATE TABLE t (id int);"
    assert.equals(def, ddl_mod.rename_routine_in_def("postgres", def, "t", "t_copy"))
  end)
end)
