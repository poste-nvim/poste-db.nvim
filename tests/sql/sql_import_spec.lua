-- Tests for lua/poste-db/import.lua
-- Pure function tests (parsing, mapping, coercion, detection).

-- Enable test-only exports in import.lua
_G._TEST = true
local import = require("poste-db.import")

-- Mock table columns matching typical database introspection output
local TABLE_COLS = {
  { name = "id",       col_type = "INT4",     is_pk = true,  nullable = false, extra = "auto_increment" },
  { name = "name",     col_type = "VARCHAR",  is_pk = false, nullable = true },
  { name = "email",    col_type = "VARCHAR",  is_pk = false, nullable = true },
  { name = "age",      col_type = "INT4",     is_pk = false, nullable = true },
  { name = "active",   col_type = "BOOLEAN",  is_pk = false, nullable = true },
}

describe("CSV parsing", function()
  it("parses simple CSV with header", function()
    local result, err = import._parse_csv_for_test("name,email,age\nAlice,alice@x.com,30\nBob,bob@y.com,25")
    assert.is_nil(err)
    assert.same({ "name", "email", "age" }, result.columns)
    assert.equals(2, #result.rows)
    assert.same({ "Alice", "alice@x.com", "30" }, result.rows[1])
    assert.same({ "Bob", "bob@y.com", "25" }, result.rows[2])
  end)

  it("handles quoted fields with commas", function()
    local csv = 'name,desc\nAlice,"hello, world"\nBob,"foo,bar,baz"'
    local result = import._parse_csv_for_test(csv)
    assert.same({ "Alice", "hello, world" }, result.rows[1])
    assert.same({ "Bob", "foo,bar,baz" }, result.rows[2])
  end)

  it("handles escaped quotes", function()
    local csv = 'name,note\nAlice,"she said ""hi"""'
    local result = import._parse_csv_for_test(csv)
    assert.same({ "Alice", 'she said "hi"' }, result.rows[1])
  end)

  it("skips empty lines", function()
    local csv = "a,b\n1,2\n\n3,4\n\n"
    local result = import._parse_csv_for_test(csv)
    assert.equals(2, #result.rows)
  end)

  it("reports column count mismatch", function()
    local csv = "a,b\n1,2\n3,4,5"
    local result, err = import._parse_csv_for_test(csv)
    assert.is_nil(result)
    assert.is_not_nil(err)
    assert.truthy(err:find("Row 3"))
  end)

  it("returns error for empty input", function()
    local result, err = import._parse_csv_for_test("")
    assert.is_nil(result)
    assert.is_not_nil(err)
    assert.truthy(err:find("No data"))
  end)

  it("strips BOM", function()
    local bom = "\239\187\191"
    local csv = bom .. "name,age\nAlice,30"
    local result = import._parse_csv_for_test(csv)
    assert.same({ "Alice", "30" }, result.rows[1])
  end)

  it("normalizes \\r\\n line endings", function()
    local csv = "name,age\r\nAlice,30\r\nBob,25\r\n"
    local result = import._parse_csv_for_test(csv)
    assert.equals(2, #result.rows)
    assert.same({ "Alice", "30" }, result.rows[1])
  end)

  it("keeps a CRLF inside a quoted field as the cell's data", function()
    -- RFC 4180: a quoted CRLF is part of the field. csv_escape quotes it on
    -- export precisely so it survives; the blanket \r\n rewrite the parser
    -- used to run changed that value to a bare \n on re-import.
    local csv = 'name,bio\n"Alice","line1\r\nline2"\n'
    local result = import._parse_csv_for_test(csv)
    assert.equals(1, #result.rows)
    assert.same({ "Alice", "line1\r\nline2" }, result.rows[1])
  end)
end)

describe("TSV parsing", function()
  it("parses TSV with header", function()
    local tsv = "name\temail\tage\nAlice\talice@x.com\t30\nBob\tbob@y.com\t25"
    local result = import._parse_tsv_for_test(tsv)
    assert.same({ "name", "email", "age" }, result.columns)
    assert.same({ "Alice", "alice@x.com", "30" }, result.rows[1])
  end)

  it("reports column count mismatch", function()
    local tsv = "a\tb\n1\t2\n3"
    local result, err = import._parse_tsv_for_test(tsv)
    assert.is_nil(result)
    assert.is_not_nil(err)
  end)

  it("keeps empty leading/trailing cells as columns", function()
    -- The old line-level trim deleted the empty edge columns, so these rows
    -- failed with "expected 3 columns, got 2" (or silently misaligned when
    -- every row shared the empty cell).
    local tsv = "a\tb\tc\n\tx\ty\n1\t2\t"
    local result = import._parse_tsv_for_test(tsv)
    assert.same({ "", "x", "y" }, result.rows[1])
    assert.same({ "1", "2", "" }, result.rows[2])
  end)
end)

describe("JSON parsing", function()
  it("parses array of objects", function()
    local json = '[{"name":"Alice","age":30},{"name":"Bob","age":25}]'
    local result = import._parse_json_for_test(json)
    -- Keys sorted alphabetically: age, name
    assert.same({ "age", "name" }, result.columns)
    assert.same({ "30", "Alice" }, result.rows[1])
    assert.same({ "25", "Bob" }, result.rows[2])
  end)

  it("collects all unique keys across objects", function()
    local json = '[{"b":2,"a":1},{"a":3,"b":4,"c":5}]'
    local result = import._parse_json_for_test(json)
    -- All three keys must be present (order is non-deterministic due to pairs())
    assert.equals(3, #result.columns)
    local seen = {}
    for _, k in ipairs(result.columns) do seen[k] = true end
    assert.is_true(seen["a"])
    assert.is_true(seen["b"])
    assert.is_true(seen["c"])
  end)

  it("handles null values as vim.NIL", function()
    local json = '[{"name":"Alice","email":null}]'
    local result = import._parse_json_for_test(json)
    local name_idx, email_idx
    for i, k in ipairs(result.columns) do
      if k == "name" then name_idx = i end
      if k == "email" then email_idx = i end
    end
    assert.is_not_nil(name_idx)
    assert.is_not_nil(email_idx)
    assert.equals("Alice", result.rows[1][name_idx])
    assert.equals(vim.NIL, result.rows[1][email_idx])
  end)

  it("imports a bare object as one row (it IS the data, not an error)", function()
    -- was "returns error for non-array JSON": a pasted API response
    -- `{"key":"val"}` now imports exactly like `[{"key":"val"}]`
    local result, err = import._parse_json_for_test('{"key":"val"}')
    assert.is_nil(err)
    assert.same({ "key" }, result.columns)
    assert.equals(1, #result.rows)
    assert.equals("val", result.rows[1][1])
  end)

  it("serializes nested objects and arrays as JSON text, not pointer strings", function()
    local json = '[{"id":1,"meta":{"tags":["a","b"]}}]'
    local result = import._parse_json_for_test(json)
    local meta_idx
    for i, k in ipairs(result.columns) do
      if k == "meta" then meta_idx = i end
    end
    local v = result.rows[1][meta_idx]
    assert.is_not_nil(v:find('"tags"'))
    assert.is_nil(v:find("table:"))
  end)
end)

describe("format detection", function()
  it("detects from file extension", function()
    assert.equals("csv", import._detect_format_for_test("", "/path/data.csv"))
    assert.equals("tsv", import._detect_format_for_test("", "/path/data.tsv"))
    assert.equals("json", import._detect_format_for_test("", "/path/data.json"))
  end)

  it("heuristics: JSON content", function()
    local json = '[{"a":1}]'
    assert.equals("json", import._detect_format_for_test(json, nil))
  end)

  it("heuristics: CSV vs TSV by delimiter count", function()
    local csv = "a,b,c\n1,2,3"
    assert.equals("csv", import._detect_format_for_test(csv, nil))
    local tsv = "a\tb\tc\n1\t2\t3"
    assert.equals("tsv", import._detect_format_for_test(tsv, nil))
  end)

  it("sniffs delimiter-less text as a one-column CSV", function()
    -- A copied spreadsheet column has no delimiter; refusing it made the
    -- clipboard import path dead for the most common paste.
    assert.equals("csv", import._detect_format_for_test("hello world", nil))
    assert.equals("csv", import._detect_format_for_test("name\nAlice\nBob", nil))
  end)

  it("returns nil for empty or whitespace-only content", function()
    assert.is_nil(import._detect_format_for_test("", nil))
    assert.is_nil(import._detect_format_for_test("  \n\t\n", nil))
  end)
end)

describe("column mapping", function()
  it("maps by exact name match (case-insensitive)", function()
    local parsed_cols = { "Name", "EMAIL", "Age" }
    local col_map, unmatched, missing = import._build_column_map_for_test(parsed_cols, TABLE_COLS)
    assert.equals(3, #col_map)
    assert.equals(0, #unmatched)
    assert.equals(2, #missing)  -- id, active
    -- Name → name (table col 2)
    assert.equals("name", col_map[1].table_col.name)
    assert.equals(2, col_map[1].table_idx)
    -- EMAIL → email (table col 3)
    assert.equals("email", col_map[2].table_col.name)
    assert.equals(3, col_map[2].table_idx)
    -- Age → age (table col 4)
    assert.equals("age", col_map[3].table_col.name)
    assert.equals(4, col_map[3].table_idx)
  end)

  it("reports unmatched import columns", function()
    local parsed_cols = { "Name", "UnknownCol" }
    local col_map, unmatched = import._build_column_map_for_test(parsed_cols, TABLE_COLS)
    assert.equals(1, #col_map)
    assert.same({ "UnknownCol" }, unmatched)
  end)

  it("reports unmatched table columns", function()
    local parsed_cols = { "Name" }
    local _, _, missing = import._build_column_map_for_test(parsed_cols, TABLE_COLS)
    -- id, email, age, active (all but name)
    assert.equals(4, #missing)
  end)

  it("returns empty map for no matches", function()
    local parsed_cols = { "Foo", "Bar" }
    local col_map, unmatched = import._build_column_map_for_test(parsed_cols, TABLE_COLS)
    assert.equals(0, #col_map)
    assert.equals(2, #unmatched)
  end)
end)

describe("value coercion", function()
  it("coerces integers", function()
    assert.equals(42, import._coerce_value_for_test("42", "INT4"))
    assert.equals(0, import._coerce_value_for_test("0", "INT4"))
    assert.equals(-1, import._coerce_value_for_test("-1", "INT4"))
  end)

  it("returns nil for empty string", function()
    assert.is_nil(import._coerce_value_for_test("", "VARCHAR"))
  end)

  it("returns vim.NIL for NULL markers", function()
    assert.equals(vim.NIL, import._coerce_value_for_test("NULL", "VARCHAR"))
    assert.equals(vim.NIL, import._coerce_value_for_test("(NULL)", "VARCHAR"))
  end)

  it("coerces booleans", function()
    assert.is_true(import._coerce_value_for_test("true", "BOOLEAN"))
    assert.is_true(import._coerce_value_for_test("TRUE", "BOOLEAN"))
    assert.is_true(import._coerce_value_for_test("1", "BOOLEAN"))
    assert.is_false(import._coerce_value_for_test("false", "BOOLEAN"))
    assert.is_false(import._coerce_value_for_test("FALSE", "BOOLEAN"))
    assert.is_false(import._coerce_value_for_test("0", "BOOLEAN"))
  end)

  it("passes strings through", function()
    assert.equals("hello", import._coerce_value_for_test("hello", "VARCHAR"))
    assert.equals("alice@x.com", import._coerce_value_for_test("alice@x.com", "VARCHAR"))
  end)
end)

describe("import flow integration", function()
  it("full flow: CSV to table (happy path)", function()
    local csv = "name,email,age,active\nAlice,alice@x.com,30,true\nBob,bob@y.com,25,false"
    local tcols = {
      { name = "id",     col_type = "INT4",    is_pk = true,  nullable = false, extra = "auto_increment" },
      { name = "name",   col_type = "VARCHAR", is_pk = false, nullable = true },
      { name = "email",  col_type = "VARCHAR", is_pk = false, nullable = true },
      { name = "age",    col_type = "INT4",    is_pk = false, nullable = true },
      { name = "active", col_type = "BOOLEAN", is_pk = false, nullable = true },
    }

    local parsed = import._parse_csv_for_test(csv)
    local col_map, _, _ = import._build_column_map_for_test(parsed.columns, tcols)
    local valid, bad = import._validate_and_type_for_test(parsed.rows, col_map)

    assert.equals(0, #bad)
    assert.equals(2, #valid)

    -- Row 1: Alice,30,true → aligned to table columns
    -- id (col 1) = nil (auto), name (col 2) = "Alice", email (col 3) = "alice@x.com",
    -- age (col 4) = 30, active (col 5) = true
    assert.is_nil(valid[1][1])
    assert.equals("Alice", valid[1][2])
    assert.equals("alice@x.com", valid[1][3])
    assert.equals(30, valid[1][4])
    assert.is_true(valid[1][5])
  end)

  it("marks row bad when PK column has null value", function()
    local csv = "id,name\n,NoId\n2,HasId"
    local tcols = {
      { name = "id",   col_type = "INT4",    is_pk = true, nullable = false, extra = "" },
      { name = "name", col_type = "VARCHAR", is_pk = false, nullable = true },
    }

    local parsed = import._parse_csv_for_test(csv)
    local col_map, _, _ = import._build_column_map_for_test(parsed.columns, tcols)
    local valid, bad = import._validate_and_type_for_test(parsed.rows, col_map)

    assert.equals(1, #valid)
    assert.equals(1, #bad)
    assert.equals(2, bad[1].row_idx)  -- row 2 in the CSV (original = line 2)
  end)

  it("skips auto-increment PK even when null (not an error)", function()
    local csv = "id,name\n,Alice"
    local tcols = {
      { name = "id",   col_type = "INT4",    is_pk = true, nullable = false, extra = "auto_increment" },
      { name = "name", col_type = "VARCHAR", is_pk = false, nullable = true },
    }

    local parsed = import._parse_csv_for_test(csv)
    local col_map, _, _ = import._build_column_map_for_test(parsed.columns, tcols)
    local valid, bad = import._validate_and_type_for_test(parsed.rows, col_map)

    assert.equals(1, #valid)
    assert.equals(0, #bad)
    -- id should be nil → generate_insert skips it → DB auto-generates
    assert.is_nil(valid[1][1])
  end)
end)
