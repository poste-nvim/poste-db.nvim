local ident = require("poste-db.ident")

describe("ident.quote", function()
  it("quotes a simple name with double quotes for postgres", function()
    assert.equals('"users"', ident.quote("users", "postgres"))
  end)

  it("quotes a simple name with backticks for mysql", function()
    assert.equals("`users`", ident.quote("users", "mysql"))
  end)

  it("escapes double quotes inside name for postgres", function()
    assert.equals('"col""name"', ident.quote('col"name', "postgres"))
  end)

  it("escapes backticks inside name for mysql", function()
    assert.equals("`col``name`", ident.quote("col`name", "mysql"))
  end)

  it("returns empty string for nil input", function()
    assert.equals("", ident.quote(nil, "postgres"))
  end)

  it("returns empty string for empty input", function()
    assert.equals("", ident.quote("", "postgres"))
  end)

  it("returns * as-is", function()
    assert.equals("*", ident.quote("*", "postgres"))
  end)

  it("never splits an introspected name on its dots", function()
    -- A table really named `staging.v1` is one table. Quoting it as
    -- `"staging"."v1"` points the statement at `v1` inside schema `staging`,
    -- so the DROP/UPDATE the browser generated for the object on screen would
    -- hit something else (or error). That retargeting is why `quote` and
    -- `quote_ref` are different functions.
    assert.equals('"staging.v1"', ident.quote("staging.v1", "postgres"))
    assert.equals("`staging.v1`", ident.quote("staging.v1", "mysql"))
    assert.equals("[staging.v1]", ident.quote("staging.v1", "mssql"))
    assert.equals("`staging.v1`", ident.quote("staging.v1", "clickhouse"))
  end)

  it("still escapes the dialect's quote char inside a dotted name", function()
    assert.equals('"q""uote.col"', ident.quote('q"uote.col', "postgres"))
    assert.equals("`q``uote.col`", ident.quote("q`uote.col", "mysql"))
    assert.equals("[q]]uote.col]", ident.quote("q]uote.col", "mssql"))
  end)

  -- An empty part means the dots belong to the name itself, not to a schema or
  -- database prefix: `"my..table"` is a real table, and splitting it into
  -- `"my"."table"` would quietly point the statement at a different object.
  it("keeps a name whose own text contains dots in one piece", function()
    assert.equals('"my..table"', ident.quote("my..table", "postgres"))
    assert.equals("`my..table`", ident.quote("my..table", "mysql"))
  end)

  it("keeps a leading or trailing dot inside the name", function()
    assert.equals('".hidden"', ident.quote(".hidden", "postgres"))
    assert.equals('"trailing."', ident.quote("trailing.", "postgres"))
  end)

  it("quotes a simple name with brackets for mssql", function()
    assert.equals("[users]", ident.quote("users", "mssql"))
  end)

  it("escapes closing brackets inside name for mssql", function()
    assert.equals("[col]]name]", ident.quote("col]name", "mssql"))
  end)

  it("quotes a simple name with backticks for clickhouse", function()
    assert.equals("`users`", ident.quote("users", "clickhouse"))
  end)

  it("escapes backticks inside name for clickhouse", function()
    assert.equals("`col``name`", ident.quote("col`name", "clickhouse"))
  end)
end)

describe("ident.quote_ref", function()
  it("quotes each part of a qualified reference separately", function()
    assert.equals('"schema"."table"', ident.quote_ref("schema.table", "postgres"))
  end)

  it("quotes three-part qualified references", function()
    assert.equals('"db"."schema"."table"', ident.quote_ref("db.schema.table", "postgres"))
  end)

  it("does not cap how many parts a qualified reference has", function()
    assert.equals('"a"."b"."c"."d"."e"."f"."g"."h"."i"."j"."k"."l"',
      ident.quote_ref("a.b.c.d.e.f.g.h.i.j.k.l", "postgres"))
  end)

  it("quotes each part of a qualified name with brackets for mssql", function()
    assert.equals("[dbo].[users]", ident.quote_ref("dbo.users", "mssql"))
  end)

  it("escapes each part on its own", function()
    assert.equals('"a"."b""c"', ident.quote_ref('a.b"c', "postgres"))
  end)

  -- The same degenerate-dot rule as `quote`: an empty part is not a qualifier.
  it("keeps degenerate dots inside the name", function()
    assert.equals('"my..table"', ident.quote_ref("my..table", "postgres"))
    assert.equals('".hidden"', ident.quote_ref(".hidden", "postgres"))
    assert.equals('"trailing."', ident.quote_ref("trailing.", "postgres"))
  end)

  it("passes nil, empty and * through unchanged", function()
    assert.equals("", ident.quote_ref(nil, "postgres"))
    assert.equals("", ident.quote_ref("", "postgres"))
    assert.equals("*", ident.quote_ref("*", "postgres"))
  end)
end)

describe("ident.quote_qualified", function()
  it("returns just the table name when no schema", function()
    assert.equals('"users"', ident.quote_qualified(nil, "users", "postgres"))
  end)

  it("returns schema.table when schema provided", function()
    assert.equals('"public"."users"', ident.quote_qualified("public", "users", "postgres"))
  end)

  it("uses backticks for mysql", function()
    assert.equals("`public`.`users`", ident.quote_qualified("public", "users", "mysql"))
  end)

  it("uses brackets for mssql", function()
    assert.equals("[dbo].[users]", ident.quote_qualified("dbo", "users", "mssql"))
  end)
end)

describe("ident.quote_literal", function()
  it("returns NULL for nil", function()
    assert.equals("NULL", ident.quote_literal(nil))
  end)

  it("returns NULL for vim.NIL", function()
    assert.equals("NULL", ident.quote_literal(vim.NIL))
  end)

  it("returns number as-is", function()
    assert.equals("42", ident.quote_literal(42))
  end)

  it("returns boolean as TRUE/FALSE", function()
    assert.equals("TRUE", ident.quote_literal(true))
    assert.equals("FALSE", ident.quote_literal(false))
  end)

  it("wraps string in single quotes and escapes single quotes", function()
    assert.equals("'hello'", ident.quote_literal("hello"))
    assert.equals("'it''s'", ident.quote_literal("it's"))
  end)

  it("escapes backslashes for mysql", function()
    assert.equals("'\\\\'", ident.quote_literal("\\", "mysql"))
  end)

  it("escapes backslashes for clickhouse too", function()
    assert.equals("'\\\\'", ident.quote_literal("\\", "clickhouse"))
    assert.equals("'a\\\\b'", ident.quote_literal("a\\b", "clickhouse"))
  end)

  -- `tostring(math.huge)` is "inf" and `tostring(0/0)` is "nan", which a server
  -- reads as a bare column name. These arrive from the editor: a float8 cell
  -- holding Infinity is now the text "Infinity" (the binary's converter used to
  -- hand it over as null), and LuaJIT's `tonumber` accepts that spelling — so a
  -- committed edit to such a cell reaches here as a real number.
  it("renders a non-finite double as a literal, not as the column named inf", function()
    assert.equals("'Infinity'", ident.quote_literal(math.huge, "postgres"))
    assert.equals("'-Infinity'", ident.quote_literal(-math.huge, "postgres"))
    assert.equals("'NaN'", ident.quote_literal(0 / 0, "postgres"))
  end)

  it("keeps the bare inf/nan that ClickHouse spells as literals", function()
    assert.equals("inf", ident.quote_literal(math.huge, "clickhouse"))
    assert.equals("-inf", ident.quote_literal(-math.huge, "clickhouse"))
    assert.equals("nan", ident.quote_literal(0 / 0, "clickhouse"))
  end)

  it("emits integral numbers in full decimal, fractional ones via tostring", function()
    assert.equals("42", ident.quote_literal(42))
    assert.equals("0", ident.quote_literal(0))
    assert.equals("1.5", ident.quote_literal(1.5, "postgres"))
    assert.equals("-2", ident.quote_literal(-2, "postgres"))
  end)

  -- LuaJIT's `tostring` switches to exponent form once the shortest round-trip
  -- needs ~16 significant digits, and past 1e14 that rounding rewrites a value
  -- the double holds EXACTLY. An id like `123456789012345` (15 digits, under
  -- 2^53 so perfectly representable) came back as `1.2345678901234e+14` — i.e.
  -- 123456789012340 — so an INSERT/UPDATE generated from the row silently
  -- retargeted a different key. `%.0f` keeps the integer intact.
  it("does not corrupt an exact integer id through exponent form", function()
    assert.equals("123456789012345", ident.quote_literal(123456789012345, "postgres"))
    assert.equals("100000000000000", ident.quote_literal(1e14, "mysql"))
    assert.equals("9007199254740991", ident.quote_literal(2 ^ 53 - 1, "postgres"))
    assert.equals("-100000000000000", ident.quote_literal(-1e14, "sqlite"))
    -- the corruption was real: the naive tostring spelling differs from the fix
    assert.is_true(tostring(123456789012345):find("e+") ~= nil)
  end)

  it("keeps a genuinely fractional double's value through tostring", function()
    assert.equals("123456.789", ident.quote_literal(123456.789, "postgres"))
    assert.equals("-0.5", ident.quote_literal(-0.5, "mysql"))
  end)
end)

describe("ident.is_qualified", function()
  -- The caller-side half of quote_ref: "would splitting happen here?" has to
  -- answer exactly what quote_ref does, or a schema prefix gets dropped for a
  -- name whose dots are its own.
  it("says yes to a real qualifier", function()
    assert.is_true(ident.is_qualified("schema.table"))
    assert.is_true(ident.is_qualified("db.schema.table"))
  end)

  it("says no to one name, however it carries dots", function()
    assert.is_false(ident.is_qualified("users"))
    assert.is_false(ident.is_qualified("my..table"))
    assert.is_false(ident.is_qualified(".hidden"))
    assert.is_false(ident.is_qualified("trailing."))
    assert.is_false(ident.is_qualified("*"))
    assert.is_false(ident.is_qualified(""))
    assert.is_false(ident.is_qualified(nil))
  end)
end)
describe("ident quoting of a name that is not a string", function()
  -- A decoded JSON null is the truthy vim.NIL, and `name:gsub` raised on it
  -- inside the browser menu action (see the note on ops_sql.qualified_table_ref,
  -- which fixed it at the CALLER). The primitive now reads any value.
  it("quotes JSON null and nil as no name at all", function()
    assert.equals("", ident.quote(vim.NIL, "postgres"))
    assert.equals("", ident.quote(nil, "postgres"))
    assert.equals("", ident.quote_ref(vim.NIL, "mysql"))
    assert.equals("", ident.quote_ref(nil, "mysql"))
  end)

  it("spells a non-string scalar out instead of raising", function()
    assert.equals('"0"', ident.quote(0, "postgres"))
    assert.equals("`0`", ident.quote(0, "mysql"))
    assert.equals("[0]", ident.quote(0, "mssql"))
    assert.equals('"true"', ident.quote(true, "postgres"))
    assert.equals('"true"', ident.quote_ref(true, "postgres"))
  end)

  it("reads a JSON null schema as unqualified, not as the name \"vim.NIL\"", function()
    -- quote_qualified tested `schema ~= ""`; vim.NIL is neither nil nor ""
    assert.equals('"users"', ident.quote_qualified(vim.NIL, "users", "postgres"))
    assert.equals('"public"."users"', ident.quote_qualified("public", "users", "postgres"))
    assert.equals('"users"', ident.quote_qualified("", "users", "postgres"))
  end)

  it("answers is_qualified without indexing a non-string", function()
    assert.is_false(ident.is_qualified(vim.NIL))
    assert.is_false(ident.is_qualified(0))
    assert.is_false(ident.is_qualified(true))
    assert.is_false(ident.is_qualified({ "x" }))
  end)
end)
