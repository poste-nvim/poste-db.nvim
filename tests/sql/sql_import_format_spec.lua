local fmt = require("poste-db.import.format")

describe("import.format.parse_csv", function()
  it("parses rows, keeping empty edge cells", function()
    local res, err = fmt.parse_csv("a,b\n1,2\n,3")
    assert.is_nil(err)
    assert.same({ "a", "b" }, res.columns)
    assert.same({ { "1", "2" }, { "", "3" } }, res.rows)
  end)

  it("honors quoted commas, doubled quotes and CRLF inside quotes", function()
    local res, err = fmt.parse_csv('h1,h2\n"x,y",2\n"3""4","a\r\nb"')
    assert.is_nil(err)
    assert.same({ 'x,y', "2" }, res.rows[1])
    assert.same({ '3"4', "a\r\nb" }, res.rows[2])
  end)

  it("strips a UTF-8 BOM from the header", function()
    local res, err = fmt.parse_csv("\239\187\191h1,h2\n1,2")
    assert.is_nil(err)
    assert.same({ "h1", "h2" }, res.columns)
  end)

  it("treats a lone CR as a row end outside quotes", function()
    local res, err = fmt.parse_csv("h1,h2\r1,2")
    assert.is_nil(err)
    assert.same({ { "1", "2" } }, res.rows)
  end)

  it("skips blank lines entirely", function()
    local res, err = fmt.parse_csv("h1,h2\n\n1,2\n")
    assert.is_nil(err)
    assert.equals(1, #res.rows)
  end)

  -- A stray quote mid-field (an unescaped inch mark: `3" pipe,2`) used to
  -- flip the scanner into quoted mode and swallow the following commas and
  -- newlines into one giant cell — the import then died with a bogus column
  -- count or silently mis-aligned. A quote now only opens a quoted region at
  -- the start of a field; elsewhere it is literal data (python-csv behavior).
  it("keeps a mid-field stray quote as data instead of swallowing the file", function()
    local res, err = fmt.parse_csv('h1,h2\n3" pipe,2')
    assert.is_nil(err)
    assert.same({ { '3" pipe', "2" } }, res.rows)
  end)

  it("does not let a mid-field quote eat the next row", function()
    local res, err = fmt.parse_csv('h1,h2\nx"y,z\n1,2')
    assert.is_nil(err)
    assert.same({ { 'x"y', "z" }, { "1", "2" } }, res.rows)
  end)

  it("keeps quotes literal when a field starts with whitespace", function()
    local res, err = fmt.parse_csv('h1,h2\n "a",2')
    assert.is_nil(err)
    assert.same({ { ' "a"', "2" } }, res.rows)
  end)

  it("reports the row number on a ragged file", function()
    local _, err = fmt.parse_csv("a,b\n1,2,3")
    assert.matches("Row 2: expected 2 columns, got 3", err)
  end)

  it("errors on empty input", function()
    local res, err = fmt.parse_csv("")
    assert.is_nil(res)
    assert.matches("No data rows", err)
  end)

  it("rejects a duplicated header name instead of letting the last one win", function()
    -- the column map used to point both file columns at one table column
    -- and whichever came later silently overwrote the other
    local _, err = fmt.parse_csv("a,a\n1,2")
    assert.matches("Duplicate column 'a' in header", err)
  end)

  it("rejects a case-differing duplicate header name", function()
    -- The mapper pairs file columns to table columns case-insensitively, so
    -- `ID,id` passed the exact-case check and BOTH entries landed on the
    -- same table column with the later file column silently winning.
    local _, err = fmt.parse_csv("ID,id\n1,2")
    assert.matches("Duplicate column 'ID' in header", err)
  end)
end)

describe("import.format.parse_tsv", function()
  it("splits on tabs and keeps trailing empty cells", function()
    local res, err = fmt.parse_tsv("a\tb\t\n1\t2\t")
    assert.is_nil(err)
    assert.same({ "a", "b", "" }, res.columns)
    assert.same({ { "1", "2", "" } }, res.rows)
  end)

  it("normalizes CRLF and skips blank lines", function()
    local res, err = fmt.parse_tsv("a\tb\r\n\r\n1\t2")
    assert.is_nil(err)
    assert.equals(1, #res.rows)
  end)

  it("reports the row number on a ragged file", function()
    local _, err = fmt.parse_tsv("a\tb\n1\t2\t3")
    assert.matches("Row 2: expected 2 columns, got 3", err)
  end)

  it("rejects a duplicated header name", function()
    local _, err = fmt.parse_tsv("a\ta\n1\t2")
    assert.matches("Duplicate column 'a' in header", err)
  end)
end)

describe("import.format.parse_json", function()
  it("builds the column union sorted, filling missing keys with NIL", function()
    local res, err = fmt.parse_json('[{"b":1,"a":2},{"a":3}]')
    assert.is_nil(err)
    assert.same({ "a", "b" }, res.columns)
    assert.same({ "3", vim.NIL }, res.rows[2])
  end)

  it("encodes nested objects as JSON text", function()
    local res, err = fmt.parse_json('[{"a":{"x":1}}]')
    assert.is_nil(err)
    assert.equals('{"x":1}', res.rows[1][1])
  end)

  it("errors on an empty array and a scalar array", function()
    assert.matches("empty", select(2, fmt.parse_json("[]")))
    assert.matches("objects", select(2, fmt.parse_json("[1,2]")))
  end)

  it("imports a bare object as one row (pasted API response)", function()
    local res, err = fmt.parse_json('{"a":1,"b":"x"}')
    assert.is_nil(err)
    assert.same({ "a", "b" }, res.columns)
    assert.same({ "1", "x" }, res.rows[1])
  end)

  it("still errors on a completely empty object", function()
    assert.matches("empty", select(2, fmt.parse_json("{}")))
  end)
end)

describe("import.format.detect_format", function()
  it("trusts the extension first, case-insensitively", function()
    assert.equals("csv", fmt.detect_format("[1]", "/x/y.CSV"))
    assert.equals("tsv", fmt.detect_format("a,b", "/x/y.TsV"))
    assert.equals("json", fmt.detect_format("a,b", "/x/y.json"))
  end)

  it("sniffs JSON by a successful decode", function()
    assert.equals("json", fmt.detect_format('[{"a":1}]', nil))
    assert.not_equals("json", fmt.detect_format("[not json,", nil))
  end)

  it("sniffs tsv only when tabs strictly beat commas", function()
    assert.equals("tsv", fmt.detect_format("a\tb\n1\t2", nil))
    assert.equals("csv", fmt.detect_format("a\tb,c\n1\t2,3", nil))
  end)

  it("returns nil when nothing matches", function()
    assert.is_nil(fmt.detect_format("hello world", nil))
  end)
end)
