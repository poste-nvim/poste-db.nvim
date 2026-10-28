--- Tests for SQL dataset editor: value conversion, validation, edit state, DML generation.
--- Covers UT1-UT11 from dataset-ui-edit-impl.md §5.

local editor = require("poste-db.editor")
local edit_commit = require("poste-db.edit_commit")
local dml = require("poste-db.dml")
local format = require("poste-db.format")

---------------------------------------------------------------------------
-- UT1: parse_value — various input → value conversions
---------------------------------------------------------------------------
describe("parse_value", function()
  it("empty input on non-nil old_val → vim.NIL (NULL)", function()
    local result = editor.parse_value("", "hello")
    assert.equals(vim.NIL, result)
  end)

  it("empty input on nil old_val → nil (no change)", function()
    local result = editor.parse_value("", nil)
    assert.is_nil(result)
  end)

  it("'' (two single quotes) → empty string", function()
    local result = editor.parse_value("''", "old")
    assert.equals("", result)
  end)

  it("(NULL) → vim.NIL", function()
    local result = editor.parse_value("(NULL)", "old")
    assert.equals(vim.NIL, result)
  end)

  it("NULL → vim.NIL", function()
    local result = editor.parse_value("NULL", "old")
    assert.equals(vim.NIL, result)
  end)

  it("pure number '42' → number 42", function()
    local result = editor.parse_value("42", "old")
    assert.equals(42, result)
    assert.equals("number", type(result))
  end)

  it("negative number '-3.14' → number -3.14", function()
    local result = editor.parse_value("-3.14", "old")
    assert.equals(-3.14, result)
  end)

  it("'0' → number 0", function()
    local result = editor.parse_value("0", "old")
    assert.equals(0, result)
  end)

  it("'true' → boolean true", function()
    local result = editor.parse_value("true", "old")
    assert.is_true(result)
  end)

  it("'false' → boolean false", function()
    local result = editor.parse_value("false", "old")
    assert.is_false(result)
  end)

  it("huge bigint '2084515900853196878' → exact string (avoids double corruption)", function()
    local result = editor.parse_value("2084515900853196878", "old")
    assert.equals("string", type(result))
    assert.equals("2084515900853196878", result)
  end)

  it("huge decimal string → exact string (avoids double corruption)", function()
    local result = editor.parse_value("123456789012345678901.50", "old")
    assert.equals("123456789012345678901.50", result)
  end)

  it("small integer still parses to a number", function()
    local result = editor.parse_value("42", "old")
    assert.equals("number", type(result))
    assert.equals(42, result)
  end)

  it("plain string → string", function()
    local result = editor.parse_value("hello world", "old")
    assert.equals("hello world", result)
  end)

  it("string with spaces → string", function()
    local result = editor.parse_value("  spaced  ", "old")
    assert.equals("  spaced  ", result)
  end)

  -- Where a non-finite number comes from: the binary hands an infinite float8
  -- over as the text "Infinity" (it used to arrive as null), and LuaJIT's
  -- `tonumber` spells that a number. So committing such a cell puts math.huge
  -- in the edit state, and the DML builder is what turns it back into a literal.
  it("'Infinity' parses to the number infinity, not the word", function()
    local result = editor.parse_value("Infinity", "old")
    assert.equals("number", type(result))
    assert.equals(math.huge, result)
  end)

  ---------------------------------------------------------------------------
  -- The same inference read against the target column. A `varchar` cell holds
  -- the characters, and the DML layer already writes it that way
  -- (`sql_dml_spec`: "quotes digits heading for a text column"). Inferring a
  -- number here instead handed `validate_value` a number for a text column,
  -- which it rejects — so such a cell could not be saved at all, not even by
  -- pressing ENTER on its own prefilled text.
  ---------------------------------------------------------------------------
  describe("with a known column type", function()
    it("keeps digits as text for a varchar column", function()
      local result = editor.parse_value("42", "42", { ctype = "varchar" })
      assert.equals("string", type(result))
      assert.equals("42", result)
    end)

    it("lets a numeric-looking text cell round-trip through validation", function()
      local col_meta = { ctype = "text" }
      local new_val = editor.parse_value("42", "42", col_meta)
      local ok, err = editor.validate_value(new_val, col_meta)
      assert.is_true(ok, "the unchanged edit must be accepted, got: " .. tostring(err))
    end)

    it("keeps 'true' as text for a text column", function()
      assert.equals("true", editor.parse_value("true", "true", { ctype = "text" }))
    end)

    it("keeps JSON text as text for a text column", function()
      local result = editor.parse_value('{"a":1}', '{"a":1}', { ctype = "varchar" })
      assert.equals("string", type(result))
      assert.equals('{"a":1}', result)
    end)

    it("keeps digits as text for a ClickHouse String column", function()
      assert.equals("42", editor.parse_value("42", "42", { ctype = "string" }))
    end)

    it("still infers a number for a numeric column", function()
      local result = editor.parse_value("42", "42", { ctype = "integer" })
      assert.equals("number", type(result))
      assert.equals(42, result)
    end)

    it("still infers a number for a ClickHouse UInt64 column", function()
      assert.equals(42, editor.parse_value("42", "42", { ctype = "uint64" }))
    end)

    it("still decodes JSON for a jsonb column", function()
      local result = editor.parse_value('{"a":1}', nil, { ctype = "jsonb" })
      assert.equals("table", type(result))
      assert.equals(1, result.a)
    end)

    it("keeps the NULL and expression sentinels working for a text column", function()
      assert.equals(vim.NIL, editor.parse_value("(NULL)", "42", { ctype = "text" }))
      assert.equals(vim.NIL, editor.parse_value("NULL", "42", { ctype = "text" }))
      assert.equals(vim.NIL, editor.parse_value("", "42", { ctype = "text" }))
      assert.equals("", editor.parse_value("''", "42", { ctype = "text" }))
      assert.equals("__expr:now()",
        editor.parse_value("__expr:now()", "42", { ctype = "text" }))
    end)

    it("still keeps a bigint exact when the column is numeric", function()
      assert.equals("2084515900853196878",
        editor.parse_value("2084515900853196878", "0", { ctype = "bigint" }),
        "the digit-preserving path is about double range, not the column family")
    end)

    it("hands the DML builder text, so the literal keeps its quotes", function()
      -- the other layer of the same rule: `quote_val` only writes `'42'` when
      -- the value is still a string, so an inferred number would have gone out
      -- as the integer literal `42` and postgres would reject it for a text
      -- column (`operator does not exist: text = integer`)
      local cols = { { name = "code", ctype = "varchar" },
                     { name = "id", ctype = "integer", primary_key = true } }
      local new_val = editor.parse_value("42", "42", cols[1])
      local sql = dml.generate_update(nil, "t", cols,
        { { col = 1, new_val = new_val } }, { "x", 7 }, "postgres")
      assert.equals([[UPDATE "t" SET "code" = '42' WHERE "id" = 7;]], sql)
    end)
  end)
end)

---------------------------------------------------------------------------
-- UT2: validate_value — type interception
---------------------------------------------------------------------------
describe("validate_value", function()
  local function col(ctype)
    return { ctype = ctype }
  end

  describe("integer types", function()
    it("accepts valid integer", function()
      local ok, err = editor.validate_value(42, col("integer"))
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("accepts integer string parsed to number", function()
      local ok = editor.validate_value(42, col("int"))
      assert.is_true(ok)
    end)

    it("accepts bigint", function()
      local ok = editor.validate_value(9999999, col("bigint"))
      assert.is_true(ok)
    end)

    it("accepts bigint string preserved for precision", function()
      local ok, err = editor.validate_value("2084515900853196878", col("bigint"))
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("accepts integer string for integer column", function()
      local ok = editor.validate_value("42", col("integer"))
      assert.is_true(ok)
    end)

    it("rejects non-numeric string for integer", function()
      local ok, err = editor.validate_value("12abc", col("integer"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)

    it("accepts smallint", function()
      local ok = editor.validate_value(1, col("smallint"))
      assert.is_true(ok)
    end)

    it("rejects float for integer", function()
      local ok, err = editor.validate_value(3.14, col("integer"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)

    it("rejects float for the whole integer family", function()
      -- the guard used to compare the ctype against the single spelling
      -- "integer", so an int8 column (normalized to `bigint`) accepted 3.5 and
      -- the server had to reject the statement instead
      for _, ctype in ipairs({ "int", "bigint", "smallint", "serial", "bigserial" }) do
        local ok, err = editor.validate_value(3.5, col(ctype))
        assert.is_false(ok, "a fraction belongs in no integer column, not in " .. ctype)
        assert.is_not_nil(err)
      end
    end)

    it("accepts a float with no fractional part for an integer column", function()
      -- LuaJIT spells 42.0 as "42": the check reads the value, not its Lua type
      assert.is_true(editor.validate_value(42.0, col("bigint")))
    end)

    it("rejects infinity and NaN for an integer column", function()
      -- `tostring(math.huge)` is "inf", which carries no decimal point, so the
      -- integer guard missed it and the commit went out as `SET seq = 'Infinity'`
      for _, ctype in ipairs({ "integer", "bigint", "smallint" }) do
        for _, val in ipairs({ math.huge, -math.huge }) do
          local ok, err = editor.validate_value(val, col(ctype))
          assert.is_false(ok, ctype .. " has no infinity")
          assert.is_not_nil(err)
        end
        assert.is_false(editor.validate_value(0 / 0, col(ctype)), ctype .. " has no NaN")
      end
    end)

    it("rejects string for integer", function()
      local ok, err = editor.validate_value("abc", col("integer"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)
  end)

  describe("numeric/float types", function()
    it("accepts float for numeric", function()
      local ok = editor.validate_value(3.14, col("numeric"))
      assert.is_true(ok)
    end)

    it("accepts integer for float", function()
      local ok = editor.validate_value(42, col("float"))
      assert.is_true(ok)
    end)

    it("accepts decimal", function()
      local ok = editor.validate_value(99.99, col("decimal"))
      assert.is_true(ok)
    end)

    it("accepts numeric string for decimal", function()
      local ok = editor.validate_value("123456789012345678901.50", col("decimal"))
      assert.is_true(ok)
    end)

    it("accepts real", function()
      local ok = editor.validate_value(1.0, col("real"))
      assert.is_true(ok)
    end)

    it("rejects string for numeric", function()
      local ok, err = editor.validate_value("abc", col("numeric"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)

    it("accepts infinity and NaN for the floating families", function()
      -- round 24's contract, seen from the editor: an infinite float8 cell
      -- arrives as the text "Infinity", LuaJIT reads that as a number, and the
      -- commit writes it back as a literal the server parses
      for _, ctype in ipairs({ "float", "double", "real", "numeric", "decimal" }) do
        assert.is_true(editor.validate_value(math.huge, col(ctype)), ctype .. " holds infinity")
        assert.is_true(editor.validate_value(-math.huge, col(ctype)), ctype .. " holds -infinity")
        assert.is_true(editor.validate_value(0 / 0, col(ctype)), ctype .. " holds NaN")
      end
    end)
  end)

  describe("boolean types", function()
    it("accepts true", function()
      local ok = editor.validate_value(true, col("boolean"))
      assert.is_true(ok)
    end)

    it("accepts false", function()
      local ok = editor.validate_value(false, col("bool"))
      assert.is_true(ok)
    end)

    it("accepts number 1 as boolean", function()
      local ok = editor.validate_value(1, col("boolean"))
      assert.is_true(ok)
    end)

    it("accepts number 0 as boolean", function()
      local ok = editor.validate_value(0, col("boolean"))
      assert.is_true(ok)
    end)

    it("rejects string 'maybe' for boolean", function()
      local ok, err = editor.validate_value("maybe", col("boolean"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)

    it("rejects number 2 for boolean", function()
      local ok = editor.validate_value(2, col("boolean"))
      assert.is_false(ok)
    end)
  end)

  describe("date/timestamp types", function()
    it("accepts ISO date string", function()
      local ok = editor.validate_value("2026-06-13", col("date"))
      assert.is_true(ok)
    end)

    it("accepts ISO datetime string", function()
      local ok = editor.validate_value("2026-06-13T10:30:00", col("timestamp"))
      assert.is_true(ok)
    end)

    it("accepts timestamptz", function()
      local ok = editor.validate_value("2026-06-13T10:30:00+08:00", col("timestamptz"))
      assert.is_true(ok)
    end)

    it("rejects invalid date", function()
      local ok, err = editor.validate_value("notadate", col("date"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)

    it("rejects random string for timestamp", function()
      local ok = editor.validate_value("hello", col("timestamp"))
      assert.is_false(ok)
    end)
  end)

  describe("json/jsonb types", function()
    it("accepts valid JSON object", function()
      local val = { a = 1 }
      local ok = editor.validate_value(val, col("json"))
      assert.is_true(ok)
    end)

    it("accepts valid JSON array", function()
      local val = { 1, 2, 3 }
      local ok = editor.validate_value(val, col("jsonb"))
      assert.is_true(ok)
    end)

    it("accepts string for json (passthrough)", function()
      local ok = editor.validate_value('{"a":1}', col("json"))
      assert.is_true(ok)
    end)

    it("rejects number for json", function()
      local ok, err = editor.validate_value(42, col("json"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)
  end)

  describe("uuid type", function()
    it("accepts valid UUID", function()
      local ok = editor.validate_value("550e8400-e29b-41d4-a716-446655440000", col("uuid"))
      assert.is_true(ok)
    end)

    it("rejects invalid UUID", function()
      local ok, err = editor.validate_value("bad", col("uuid"))
      assert.is_false(ok)
      assert.is_not_nil(err)
    end)

    it("rejects short UUID", function()
      local ok = editor.validate_value("550e8400-e29b-41d4", col("uuid"))
      assert.is_false(ok)
    end)
  end)

  describe("text/varchar/char types", function()
    it("accepts any string for text", function()
      local ok = editor.validate_value("anything goes", col("text"))
      assert.is_true(ok)
    end)

    it("accepts any string for varchar", function()
      local ok = editor.validate_value("hello", col("varchar"))
      assert.is_true(ok)
    end)

    it("accepts any string for char", function()
      local ok = editor.validate_value("x", col("char"))
      assert.is_true(ok)
    end)

    it("accepts empty string", function()
      local ok = editor.validate_value("", col("text"))
      assert.is_true(ok)
    end)
  end)

  ---------------------------------------------------------------------------
  -- The names introspection actually hands over are not the keys of the
  -- editor's own type table: `numeric(10,2)` out of postgres' format_type,
  -- MySQL's `decimal(10,2)`, ClickHouse spelling widths into the name
  -- (`UInt64`, `Float64`). Reading those as "not numeric" made every number an
  -- invalid value, so a `numeric(10,2)` column could not be edited at all. The
  -- DML layer already asks the shared root-word check in `poste-db.types`.
  ---------------------------------------------------------------------------
  describe("parameterized and dialect type names", function()
    it("accepts a number for a parameterized numeric column", function()
      assert.is_true(editor.validate_value(3.5, col("numeric(10,2)")))
      assert.is_true(editor.validate_value(42, col("decimal(10,2)")))
    end)

    it("accepts infinity for a ClickHouse Float64 column", function()
      assert.is_true(editor.validate_value(math.huge, col("float64")))
    end)

    it("rejects a fraction for a width-spelled integer column", function()
      assert.is_false(editor.validate_value(3.5, col("uint64")), "ClickHouse UInt64")
      assert.is_false(editor.validate_value(3.5, col("int32")), "ClickHouse Int32")
    end)

    it("rejects infinity and NaN for a width-spelled integer column", function()
      assert.is_false(editor.validate_value(math.huge, col("int32")))
      assert.is_false(editor.validate_value(0 / 0, col("uint64")))
    end)

    it("still rejects a number for a text column however it is spelled", function()
      assert.is_false(editor.validate_value(42, col("character varying(255)")))
      assert.is_false(editor.validate_value(42, col("string")))
      assert.is_false(editor.validate_value(42, col("fixedstring(8)")))
    end)

    it("checks nothing when introspection gave no type", function()
      -- `types.is_numeric` reads an empty name as numeric on purpose, so the
      -- validator has to stop before that branch or a plain word would become
      -- an invalid value for a column nobody ever typed
      assert.is_true(editor.validate_value(42, col("")))
      assert.is_true(editor.validate_value("hello world", col("")))
      assert.is_true(editor.validate_value("3.5", col("")))
    end)

    it("edits a ClickHouse Nullable(Int32) cell as the integer it wraps", function()
      -- the wrapped name is what the server actually sends, and it reaches this
      -- check through the layout's normalization; `Nullable(...)` says only that
      -- the value may be missing, so the column is still an integer
      local layout = format.plan_resultset_layout({
        type = "resultset",
        total_rows = 1,
        results = { { columns = { { name = "n", type = "Nullable(Int32)" } }, rows = { { 7 } } } },
        connection = "",
        database = "",
        dialect = "clickhouse",
      })
      assert.is_true(editor.validate_value(42, layout.columns[1]))
      assert.is_false(editor.validate_value(3.5, layout.columns[1]), "an integer column, nullable or not")
      assert.is_false(editor.validate_value(math.huge, layout.columns[1]))
    end)
  end)

  describe("NULL values", function()
    it("NULL is always valid", function()
      local ok = editor.validate_value(vim.NIL, col("integer"))
      assert.is_true(ok)
    end)

    it("nil is always valid", function()
      local ok = editor.validate_value(nil, col("uuid"))
      assert.is_true(ok)
    end)
  end)
end)

---------------------------------------------------------------------------
-- UT3: is_editable_field — binary/geometry/etc skip
---------------------------------------------------------------------------
describe("is_editable_field", function()
  it("allows text", function()
    assert.is_true(editor.is_editable_field({ ctype = "text" }))
  end)

  it("allows varchar", function()
    assert.is_true(editor.is_editable_field({ ctype = "varchar" }))
  end)

  it("allows integer", function()
    assert.is_true(editor.is_editable_field({ ctype = "integer" }))
  end)

  it("allows boolean", function()
    assert.is_true(editor.is_editable_field({ ctype = "boolean" }))
  end)

  it("allows json/jsonb", function()
    assert.is_true(editor.is_editable_field({ ctype = "jsonb" }))
  end)

  it("allows uuid", function()
    assert.is_true(editor.is_editable_field({ ctype = "uuid" }))
  end)

  it("allows date/timestamp", function()
    assert.is_true(editor.is_editable_field({ ctype = "timestamp" }))
  end)

  it("blocks binary", function()
    assert.is_false(editor.is_editable_field({ ctype = "binary" }))
  end)

  it("blocks bytea", function()
    assert.is_false(editor.is_editable_field({ ctype = "bytea" }))
  end)

  it("blocks blob", function()
    assert.is_false(editor.is_editable_field({ ctype = "blob" }))
  end)

  it("blocks varbinary", function()
    assert.is_false(editor.is_editable_field({ ctype = "varbinary" }))
  end)

  it("blocks geometry", function()
    assert.is_false(editor.is_editable_field({ ctype = "geometry" }))
  end)

  it("blocks geography", function()
    assert.is_false(editor.is_editable_field({ ctype = "geography" }))
  end)

  it("blocks point", function()
    assert.is_false(editor.is_editable_field({ ctype = "point" }))
  end)

  it("blocks polygon", function()
    assert.is_false(editor.is_editable_field({ ctype = "polygon" }))
  end)

  it("blocks linestring", function()
    assert.is_false(editor.is_editable_field({ ctype = "linestring" }))
  end)

  it("blocks inet", function()
    assert.is_false(editor.is_editable_field({ ctype = "inet" }))
  end)

  it("blocks cidr", function()
    assert.is_false(editor.is_editable_field({ ctype = "cidr" }))
  end)

  it("blocks macaddr", function()
    assert.is_false(editor.is_editable_field({ ctype = "macaddr" }))
  end)

  it("blocks bit", function()
    assert.is_false(editor.is_editable_field({ ctype = "bit" }))
  end)

  it("blocks varbit", function()
    assert.is_false(editor.is_editable_field({ ctype = "varbit" }))
  end)

  it("blocks interval", function()
    assert.is_false(editor.is_editable_field({ ctype = "interval" }))
  end)

  it("blocks tsvector", function()
    assert.is_false(editor.is_editable_field({ ctype = "tsvector" }))
  end)

  it("blocks tsquery", function()
    assert.is_false(editor.is_editable_field({ ctype = "tsquery" }))
  end)

  it("blocks user_defined type", function()
    assert.is_false(editor.is_editable_field({ ctype = "my_type", user_defined = true }))
  end)

  it("allows numeric", function()
    assert.is_true(editor.is_editable_field({ ctype = "numeric" }))
  end)

  it("allows float", function()
    assert.is_true(editor.is_editable_field({ ctype = "float" }))
  end)

  it("blocks a binary type spelled with its width — MySQL's `varbinary(16)`", function()
    -- the exact-name table missed the width MySQL introspection appends, and
    -- the editor offered binary data as an editable text cell
    assert.is_false(editor.is_editable_field({ ctype = "varbinary(16)" }))
    assert.is_false(editor.is_editable_field({ ctype = "bit(1)" }))
  end)

  it("blocks a binary type under a ClickHouse modifier wrapper", function()
    assert.is_false(editor.is_editable_field({ ctype = "Nullable(bytea)" }))
    assert.is_false(editor.is_editable_field({ ctype = "LowCardinality(Nullable(geometry))" }))
  end)

  it("keeps text editable under the same wrappers", function()
    assert.is_true(editor.is_editable_field({ ctype = "character varying(255)" }))
    assert.is_true(editor.is_editable_field({ ctype = "Nullable(String)" }))
  end)

  it("survives a non-string ctype from broken metadata", function()
    assert.is_true(editor.is_editable_field({ ctype = 42 }))
    assert.is_false(editor.is_editable_field({ ctype = nil, primary_key = true }))
  end)
end)

---------------------------------------------------------------------------
-- UT4: edit_state tracking — modified/deleted/added
---------------------------------------------------------------------------
describe("edit_state tracking", function()
  local es

  before_each(function()
    es = editor.create_edit_state()
  end)

  describe("track_cell_edit", function()
    it("marks dirty on first edit", function()
      assert.is_false(es.dirty)
      editor.track_cell_edit(es, "1:2", 2, "old", "new")
      assert.is_true(es.dirty)
    end)

    it("records cell modification", function()
      editor.track_cell_edit(es, "1:2", 2, "old", "new")
      assert.is_not_nil(es.modified_cells["1:2"])
      assert.equals(2, es.modified_cells["1:2"].col)
      assert.equals("old", es.modified_cells["1:2"].old_val)
      assert.equals("new", es.modified_cells["1:2"].new_val)
    end)

    it("tracks multiple different cells", function()
      editor.track_cell_edit(es, "1:1", 1, "a", "b")
      editor.track_cell_edit(es, "1:2", 2, "c", "d")
      assert.is_not_nil(es.modified_cells["1:1"])
      assert.is_not_nil(es.modified_cells["1:2"])
    end)

    it("overwrites same cell edit", function()
      editor.track_cell_edit(es, "1:2", 2, "old", "new1")
      editor.track_cell_edit(es, "1:2", 2, "old", "new2")
      assert.equals("new2", es.modified_cells["1:2"].new_val)
      assert.equals("old", es.modified_cells["1:2"].old_val)
    end)

    it("restores to original removes from modified_cells", function()
      editor.track_cell_edit(es, "1:2", 2, "old", "new")
      editor.track_cell_edit(es, "1:2", 2, "old", "old")
      assert.is_nil(es.modified_cells["1:2"])
      assert.is_false(es.dirty)
    end)
  end)

  describe("track_row_delete", function()
    it("marks deleted row", function()
      editor.track_row_delete(es, 3)
      assert.is_true(es.deleted_rows[3])
      assert.is_true(es.dirty)
    end)

    it("removes modified_cells for deleted row", function()
      editor.track_cell_edit(es, "3:2", 2, "old", "new")
      editor.track_row_delete(es, 3)
      assert.is_nil(es.modified_cells["3:2"])
      assert.is_true(es.deleted_rows[3])
    end)
  end)

  describe("track_row_add", function()
    it("adds a new row", function()
      editor.track_row_add(es, { "a", "b", "c" })
      assert.equals(1, #es.added_rows)
      assert.same({ "a", "b", "c" }, es.added_rows[1].data)
      assert.is_true(es.dirty)
    end)

    it("tracks multiple added rows", function()
      editor.track_row_add(es, { "a" })
      editor.track_row_add(es, { "b" })
      assert.equals(2, #es.added_rows)
    end)
  end)

  describe("has_pending_changes", function()
    it("returns false initially", function()
      assert.is_false(editor.has_pending_changes(es))
    end)

    it("returns true after edit", function()
      editor.track_cell_edit(es, "1:1", 1, "a", "b")
      assert.is_true(editor.has_pending_changes(es))
    end)

    it("returns true after delete", function()
      editor.track_row_delete(es, 1)
      assert.is_true(editor.has_pending_changes(es))
    end)

    it("returns true after add", function()
      editor.track_row_add(es, { "x" })
      assert.is_true(editor.has_pending_changes(es))
    end)
  end)

  describe("count_pending_changes", function()
    -- get_edit_summary (a second counter with different key names) was
    -- removed: nothing but this spec ever called it, and
    -- count_pending_changes already feeds the statusline text.
    it("returns zeros when clean", function()
      local s = editor.count_pending_changes(es)
      assert.equals(0, s.modified)
      assert.equals(0, s.deleted)
      assert.equals(0, s.added)
    end)

    it("counts modifications", function()
      editor.track_cell_edit(es, "1:1", 1, "a", "b")
      editor.track_cell_edit(es, "1:2", 2, "c", "d")
      local s = editor.count_pending_changes(es)
      assert.equals(2, s.modified)
      assert.equals(0, s.deleted)
      assert.equals(0, s.added)
    end)

    it("counts deletes", function()
      editor.track_row_delete(es, 1)
      editor.track_row_delete(es, 2)
      local s = editor.count_pending_changes(es)
      assert.equals(0, s.modified)
      assert.equals(2, s.deleted)
      assert.equals(0, s.added)
    end)

    it("counts adds", function()
      editor.track_row_add(es, { "a" })
      local s = editor.count_pending_changes(es)
      assert.equals(0, s.modified)
      assert.equals(0, s.deleted)
      assert.equals(1, s.added)
    end)
  end)
end)

---------------------------------------------------------------------------
-- UT5: edit_state merge — same cell multiple edits, modify then delete
---------------------------------------------------------------------------
describe("edit_state merge", function()
  local es

  before_each(function()
    es = editor.create_edit_state()
  end)

  it("same cell edited multiple times keeps only first old_val", function()
    editor.track_cell_edit(es, "1:2", 2, "orig", "v1")
    editor.track_cell_edit(es, "1:2", 2, "orig", "v2")
    assert.equals("orig", es.modified_cells["1:2"].old_val)
    assert.equals("v2", es.modified_cells["1:2"].new_val)
  end)

  it("modify then delete removes modified_cells, keeps deleted", function()
    editor.track_cell_edit(es, "3:2", 2, "old", "new")
    editor.track_row_delete(es, 3)
    assert.is_nil(es.modified_cells["3:2"])
    assert.is_true(es.deleted_rows[3])
  end)

  it("delete then modify does not track (row is deleted)", function()
    editor.track_row_delete(es, 3)
    editor.track_cell_edit(es, "3:2", 2, "old", "new")
    assert.is_nil(es.modified_cells["3:2"])
    assert.is_true(es.deleted_rows[3])
  end)

  it("reset clears everything", function()
    editor.track_cell_edit(es, "1:1", 1, "a", "b")
    editor.track_row_delete(es, 2)
    editor.track_row_add(es, { "c" })
    editor.reset_edit_state(es)
    assert.is_false(es.dirty)
    assert.same({}, es.modified_cells)
    assert.same({}, es.deleted_rows)
    assert.same({}, es.added_rows)
    assert.same({}, es.cell_errors)
  end)
end)

---------------------------------------------------------------------------
-- UT6: generate_update — UPDATE SQL generation
---------------------------------------------------------------------------
describe("generate_update", function()
  local columns = {
    { name = "id", ctype = "integer", primary_key = true },
    { name = "name", ctype = "text" },
    { name = "email", ctype = "varchar" },
  }

  it("generates UPDATE with primary key WHERE clause", function()
    local sql = edit_commit.generate_update(
      "public", "users", columns,
      { { col = 2, old_val = "Alice", new_val = "Bob" } },
      { "1" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("UPDATE"))
    assert.is_truthy(sql:match('"public"%."users"'))
    assert.is_truthy(sql:match('"name"'))
    assert.is_truthy(sql:match("Bob"))
    assert.is_truthy(sql:match("WHERE"))
    assert.is_truthy(sql:match('"id"%s*=%s*1'))
  end)

  it("generates UPDATE with all-column WHERE for no PK", function()
    local cols_no_pk = {
      { name = "name", ctype = "text" },
      { name = "email", ctype = "varchar" },
    }
    local sql = edit_commit.generate_update(
      "public", "users", cols_no_pk,
      { { col = 2, old_val = "old@email", new_val = "new@email" } },
      { "Alice", "old@email" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("WHERE"))
  end)

  it("skips row_num column (col=1 is row number)", function()
    local cols_with_rn = {
      { name = "_row_num", ctype = "integer" },
      { name = "id", ctype = "integer", primary_key = true },
      { name = "name", ctype = "text" },
    }
    local sql = edit_commit.generate_update(
      "public", "users", cols_with_rn,
      { { col = 3, old_val = "Alice", new_val = "Bob" } },
      { "1" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match('"name"'))
    assert.is_truthy(sql:match("Bob"))
  end)
end)

---------------------------------------------------------------------------
-- UT7: generate_insert — INSERT SQL generation
---------------------------------------------------------------------------
describe("generate_insert", function()
  local columns = {
    { name = "id", ctype = "integer", primary_key = true },
    { name = "name", ctype = "text" },
    { name = "email", ctype = "varchar" },
  }

  it("generates INSERT with correct columns and values", function()
    local sql = edit_commit.generate_insert(
      "public", "users", columns,
      { "[Auto]", "Charlie", "charlie@test.com" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("INSERT INTO"))
    assert.is_truthy(sql:match('"public"%."users"'))
    assert.is_truthy(sql:match("Charlie"))
    assert.is_truthy(sql:match("charlie@test.com"))
    assert.is_falsy(sql:match("id"))
  end)

  it("skips [Auto] columns", function()
    local sql = edit_commit.generate_insert(
      "public", "users", columns,
      { "[Auto]", "Dave", "dave@test.com" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_falsy(sql:match('"id"'))
    assert.is_truthy(sql:match('"name"'))
    assert.is_truthy(sql:match('"email"'))
  end)

  it("handles all [Auto] columns", function()
    local all_auto = {
      { name = "id", ctype = "integer" },
    }
    local sql = edit_commit.generate_insert(
      "public", "users", all_auto,
      { "[Auto]" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("INSERT INTO"))
  end)
end)

---------------------------------------------------------------------------
-- UT8: generate_delete — DELETE SQL generation
---------------------------------------------------------------------------
describe("generate_delete", function()
  local columns = {
    { name = "id", ctype = "integer", primary_key = true },
    { name = "name", ctype = "text" },
  }

  it("generates DELETE with primary key", function()
    local sql = edit_commit.generate_delete(
      "public", "users", columns,
      { "1" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("DELETE FROM"))
    assert.is_truthy(sql:match('"public"%."users"'))
    assert.is_truthy(sql:match("WHERE"))
    assert.is_truthy(sql:match('"id"%s*=%s*1'))
  end)

  it("generates DELETE with all columns for no PK", function()
    local cols_no_pk = {
      { name = "name", ctype = "text" },
    }
    local sql = edit_commit.generate_delete(
      "public", "users", cols_no_pk,
      { "Alice" },
      "postgres"
    )
    assert.is_not_nil(sql)
    assert.is_truthy(sql:match("DELETE FROM"))
    assert.is_truthy(sql:match("WHERE"))
  end)
end)

---------------------------------------------------------------------------
-- UT9: dialect quoting — three dialects
---------------------------------------------------------------------------
describe("dialect quoting", function()
  local columns = {
    { name = "id", ctype = "integer", primary_key = true },
    { name = "name", ctype = "text" },
  }

  it("postgres uses double quotes", function()
    local sql = edit_commit.generate_delete(
      "public", "users", columns, { "1" }, "postgres"
    )
    assert.is_truthy(sql:match('"public"%."users"'))
    assert.is_truthy(sql:match('"id"%s*=%s*1'))
  end)

  it("mysql uses backticks", function()
    local sql = edit_commit.generate_delete(
      "mydb", "users", columns, { "1" }, "mysql"
    )
    assert.is_truthy(sql:match("`mydb`%.`users`"))
    assert.is_truthy(sql:match("`id`%s*=%s*1"))
  end)

  it("sqlite uses double quotes", function()
    local sql = edit_commit.generate_delete(
      "", "users", columns, { "1" }, "sqlite"
    )
    assert.is_truthy(sql:match('"users"'))
  end)

  it("postgres INSERT uses double quotes", function()
    local sql = edit_commit.generate_insert(
      "public", "users", columns, { "[Auto]", "Alice" }, "postgres"
    )
    assert.is_truthy(sql:match('"name"'))
  end)

  it("mysql INSERT uses backticks", function()
    local sql = edit_commit.generate_insert(
      "mydb", "users", columns, { "[Auto]", "Alice" }, "mysql"
    )
    assert.is_truthy(sql:match("`name`"))
  end)
end)

---------------------------------------------------------------------------
-- UT10: JSON format — formatting and parsing
---------------------------------------------------------------------------
describe("JSON format", function()
  it("is_json_column detects json", function()
    assert.is_true(editor.is_json_column({ ctype = "json" }))
    assert.is_true(editor.is_json_column({ ctype = "jsonb" }))
  end)

  it("is_json_column rejects non-json", function()
    assert.is_false(editor.is_json_column({ ctype = "text" }))
    assert.is_false(editor.is_json_column({ ctype = "integer" }))
  end)

  it("is_boolean_column detects boolean", function()
    assert.is_true(editor.is_boolean_column({ ctype = "boolean" }))
    assert.is_true(editor.is_boolean_column({ ctype = "bool" }))
  end)

  it("is_boolean_column rejects non-boolean", function()
    assert.is_false(editor.is_boolean_column({ ctype = "text" }))
  end)

  it("is_enum_column detects enum with values", function()
    assert.is_true(editor.is_enum_column({ ctype = "USER-DEFINED", enum_values = { "a", "b" } }))
  end)

  it("is_enum_column rejects non-enum", function()
    assert.is_false(editor.is_enum_column({ ctype = "text" }))
    assert.is_false(editor.is_enum_column({ ctype = "USER-DEFINED" }))
  end)

  it("format_json_input formats table to indented string", function()
    local input = { a = 1, b = "hello" }
    local result = editor.format_json_input(input)
    assert.is_truthy(result:match("a"))
    assert.is_truthy(result:match("1"))
  end)

  it("format_json_input keeps quote escapes, so the text re-parses", function()
    -- Regression: the encoder output used to have its `\"` escapes stripped,
    -- which broke the round-trip for any JSON/JSONB value carrying a quote —
    -- the cell editor seeded the input prompt with invalid JSON and even a
    -- no-op edit of such a cell failed to save.
    local input = { note = 'he said "hi" -- ok' }
    local shown = editor.format_json_input(input)
    assert.equals('{"note":"he said \\"hi\\" -- ok"}', shown)
    assert.same(input, editor.parse_json_input(shown))
  end)

  it("format_json_input returns string as-is", function()
    local result = editor.format_json_input('{"a":1}')
    assert.equals('{"a":1}', result)
  end)

  it("parse_json_input decodes valid JSON", function()
    local result = editor.parse_json_input('{"a":1}')
    assert.same({ a = 1 }, result)
  end)

  it("parse_json_input returns nil for invalid JSON", function()
    local result = editor.parse_json_input("{bad}")
    assert.is_nil(result)
  end)
end)

---------------------------------------------------------------------------
-- UT11: SQL log — logging format and accumulation
---------------------------------------------------------------------------
describe("SQL log", function()
  it("format_log_entry creates valid structure", function()
    local entry = edit_commit.format_log_entry({
      source = "dataset_commit",
      table_name = "users",
      connection = "pg-ecommerce",
      dialect = "postgres",
      database = "public",
      sql = 'UPDATE "public"."users" SET "name" = \'Bob\' WHERE "id" = 1',
      status = "success",
      elapsed_ms = 12,
      edit_summary = { updates = 1, inserts = 0, deletes = 0 },
    })
    assert.is_not_nil(entry)
    assert.is_truthy(entry:match('"source"'))
    assert.is_truthy(entry:match('"dataset_commit"'))
    assert.is_truthy(entry:match('"sql"'))
    assert.is_truthy(entry:match('"status"'))
    assert.is_truthy(entry:match('"success"'))
    assert.is_truthy(entry:match('"ts"'))
    assert.is_truthy(entry:match('"elapsed_ms"'))
  end)

  it("format_log_entry handles error status", function()
    local entry = edit_commit.format_log_entry({
      source = "dataset_commit",
      table_name = "users",
      connection = "pg-ecommerce",
      dialect = "postgres",
      database = "public",
      sql = 'INSERT INTO "users" VALUES (1)',
      status = "error",
      elapsed_ms = 5,
      error_msg = "duplicate key",
    })
    assert.is_truthy(entry:match('"error"'))
    assert.is_truthy(entry:match('"duplicate key"'))
  end)

  it("format_log_entry handles manual_exec source", function()
    local entry = edit_commit.format_log_entry({
      source = "manual_exec",
      connection = "my-blog",
      dialect = "mysql",
      database = "blog",
      sql = "SELECT * FROM posts",
      status = "success",
      elapsed_ms = 3,
    })
    assert.is_truthy(entry:match('"manual_exec"'))
  end)
end)

---------------------------------------------------------------------------
-- Additional: edit_cell checks
---------------------------------------------------------------------------
describe("edit guards", function()
  it("is_numeric_type detects integer types", function()
    assert.is_true(editor.is_numeric_type("integer"))
    assert.is_true(editor.is_numeric_type("int"))
    assert.is_true(editor.is_numeric_type("bigint"))
    assert.is_true(editor.is_numeric_type("smallint"))
    assert.is_true(editor.is_numeric_type("numeric"))
    assert.is_true(editor.is_numeric_type("decimal"))
    assert.is_true(editor.is_numeric_type("real"))
    assert.is_true(editor.is_numeric_type("float"))
    assert.is_false(editor.is_numeric_type("text"))
    assert.is_false(editor.is_numeric_type("boolean"))
  end)

  it("type classifiers answer false on a non-string ctype", function()
    -- nil from broken metadata / a number from a weird driver must classify
    -- as "not this category" (the is_json_column guard's answer), not crash
    for _, f in ipairs({ editor.is_numeric_type, editor.is_integer_type,
                         editor.is_boolean_type, editor.is_date_type,
                         editor.is_uuid_type, editor.is_text_type }) do
      assert.is_false(f(nil))
      assert.is_false(f(42))
      assert.is_false(f({}))
    end
  end)

  it("is_date_type detects date types", function()
    assert.is_true(editor.is_date_type("date"))
    assert.is_true(editor.is_date_type("timestamp"))
    assert.is_true(editor.is_date_type("timestamptz"))
    assert.is_false(editor.is_date_type("text"))
    assert.is_false(editor.is_date_type("integer"))
  end)

  it("is_uuid_type detects uuid", function()
    assert.is_true(editor.is_uuid_type("uuid"))
    assert.is_false(editor.is_uuid_type("text"))  end)

  it("count_pending_changes returns correct counts", function()
    local es = editor.create_edit_state()
    editor.track_cell_edit(es, "1:1", 1, "a", "b")
    editor.track_cell_edit(es, "1:2", 2, "c", "d")
    editor.track_row_delete(es, 3)
    editor.track_row_add(es, { "x" })

    local counts = editor.count_pending_changes(es)
    assert.equals(2, counts.modified)
    assert.equals(1, counts.deleted)
    assert.equals(1, counts.added)
  end)

  it("pending_changes_text formats correctly", function()
    local es = editor.create_edit_state()
    editor.track_cell_edit(es, "1:1", 1, "a", "b")
    editor.track_row_delete(es, 2)
    editor.track_row_add(es, { "x" })

    local text = editor.pending_changes_text(es)
    assert.is_truthy(text:match("%+1"))
    assert.is_truthy(text:match("~1"))
    assert.is_truthy(text:match("%-1"))
  end)

  it("pending_changes_text returns nil when clean", function()
    local es = editor.create_edit_state()
    assert.is_nil(editor.pending_changes_text(es))
  end)
end)

describe("has_join", function()
  it("detects real joins in every spelling", function()
    assert.is_true(editor.has_join("SELECT * FROM a JOIN b ON a.id = b.id"))
    assert.is_true(editor.has_join("SELECT * FROM a LEFT JOIN b USING (id)"))
    assert.is_true(editor.has_join("select * from a inner join b on a.x = b.x"))
    assert.is_true(editor.has_join("SELECT * FROM a\n  CROSS JOIN b"))
  end)

  it("does not match column names containing join", function()
    -- join_date/joined_at contain the substring; the bare find blocked
    -- editing with a bogus multi-table warning
    assert.is_false(editor.has_join("SELECT id, join_date, joined_at FROM users"))
    assert.is_false(editor.has_join("SELECT adjoining_room FROM rooms"))
  end)

  it("does not match the word inside string literals", function()
    assert.is_false(editor.has_join("SELECT * FROM events WHERE note = 'join pending'"))
    assert.is_false(editor.has_join('SELECT * FROM events WHERE tag = "left join"'))
  end)

  it("does not match the word inside a comment", function()
    -- the gsub literal-blanker knew nothing about comments: a `-- join`
    -- note after the query blocked cell editing with a bogus multi-table
    -- warning
    assert.is_false(editor.has_join("SELECT * FROM events -- join of a and b\nWHERE id = 1"))
    assert.is_false(editor.has_join("SELECT * FROM events /* left join pending */"))
  end)

  it("does not match a JOIN inside a dollar-quoted body", function()
    assert.is_false(
      editor.has_join("CREATE FUNCTION f() AS $$ DELETE FROM a JOIN b $$ LANGUAGE sql; SELECT 1 FROM events"))
  end)

  it("handles nil", function()
    assert.is_false(editor.has_join(nil))
  end)
end)
