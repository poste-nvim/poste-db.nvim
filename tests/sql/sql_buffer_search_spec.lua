--- Pure span helper behind the dataset search substring highlight: the
--- matched characters inside a cell get an fg extmark layered over the
--- cell-wide Search tint.
local search = require("poste-db.buffer.search")

describe("buffer_search match_span", function()
  local span = search._test.match_span

  it("finds the query at the start, middle and end of a cell", function()
    assert.same({ 1, 3 }, { span("alice", "ali") })
    assert.same({ 5, 7 }, { span("  alice ", "ice") })
    assert.same({ 3, 4 }, { span("blog", "og") })
  end)

  it("is case-insensitive (matches compute_matches)", function()
    assert.same({ 1, 3 }, { span("ALICE", "ali") })
    assert.same({ 1, 3 }, { span("alice", "ALI") })
  end)

  it("returns a byte span for multibyte content", function()
    -- 数据库 = 9 bytes, so "db" sits at bytes 10..11
    assert.same({ 10, 11 }, { span("数据库db", "db") })
  end)

  it("returns nil when the query does not appear", function()
    assert.is_nil(span("alice", "bob"))
    -- rendered text can drift from the raw value (truncation) — the caller
    -- falls back to the whole-cell highlight
    assert.is_nil(span("1,234…", "3456"))
  end)

  it("returns nil for empty inputs", function()
    assert.is_nil(span("", "x"))
    assert.is_nil(span("cell", ""))
    assert.is_nil(span(nil, "x"))
    assert.is_nil(span("cell", nil))
  end)
end)

describe("buffer_search step_history", function()
  local step = search._test.step_history
  -- most-recent-first: index 1 is the newest entry
  local hist = { "foo", "bar", "baz" }

  it("moves from free text (idx 0) to the most recent entry on <Up>", function()
    assert.same({ "foo", 1 }, { step(hist, 0, 1) })
  end)

  it("walks older on repeated <Up>", function()
    local t, i = step(hist, 1, 1)
    assert.same({ "bar", 2 }, { t, i })
    t, i = step(hist, 2, 1)
    assert.same({ "baz", 3 }, { t, i })
  end)

  it("clamps at the oldest entry", function()
    assert.same({ nil, 3 }, { step(hist, 3, 1) })
  end)

  it("walks newer on <Down> and signals restore at idx 0", function()
    local t, i = step(hist, 3, -1)
    assert.same({ "bar", 2 }, { t, i })
    t, i = step(hist, 2, -1)
    assert.same({ "foo", 1 }, { t, i })
    t, i = step(hist, 1, -1)
    assert.same({ nil, 0 }, { t, i }) -- caller restores the original text
  end)

  it("does nothing on <Down> while already at free text", function()
    assert.same({ nil, 0 }, { step(hist, 0, -1) })
  end)

  it("no-ops on empty history", function()
    assert.same({ nil, 0 }, { step({}, 0, 1) })
    assert.same({ nil, 0 }, { step({}, 0, -1) })
  end)
end)

describe("buffer_search record_search", function()
  local rec = search._test.record_search

  before_each(function()
    search.search_history = {}
  end)

  it("stores most-recent-first", function()
    rec("alice")
    rec("bob")
    assert.same({ "bob", "alice" }, search.search_history)
  end)

  it("dedups by re-inserting at the front", function()
    rec("alice")
    rec("bob")
    rec("alice")
    assert.same({ "alice", "bob" }, search.search_history)
  end)

  it("ignores nil and empty", function()
    rec(nil)
    rec("")
    assert.same({}, search.search_history)
  end)
end)

describe("buffer_search search_text_of", function()
  local text_of = search._test.search_text_of

  it("renders a JSON/JSONB cell as the compact JSON the renderer shows", function()
    -- tostring on a table is a pointer address; searching for text visibly
    -- inside a JSONB cell must match what is on screen
    assert.equals('{"a":1}', text_of({ a = 1 }))
    assert.equals("[1,2]", text_of({ 1, 2 }))
  end)

  it("falls back to inspect when a table cannot be encoded", function()
    local cyc = {}
    cyc.self = cyc
    assert.equals(vim.inspect(cyc), text_of(cyc))
  end)

  it("keeps the old scalar shapes", function()
    assert.equals("", text_of(nil))
    assert.equals("", text_of(vim.NIL))
    assert.equals("42", text_of(42))
    assert.equals("true", text_of(true))
    assert.equals("alice", text_of("alice"))
  end)
end)

describe("buffer_search same_value", function()
  local same = search._test.same_value

  it("compares two separately-decoded JSON cells by content", function()
    -- the filter value and a matching row come from different json.decode
    -- calls, so pointer equality kept only the row the filter was taken from
    assert.is_true(same({ a = 1 }, { a = 1 }))
    assert.is_true(same({ 1, "x" }, { 1, "x" }))
    assert.is_false(same({ a = 1 }, { a = 2 }))
    assert.is_false(same({ a = 1 }, { b = 1 }))
  end)

  it("keeps plain == for scalars — a number is not its text", function()
    assert.is_true(same(5, 5))
    assert.is_false(same(5, "5"))
    assert.is_true(same("x", "x"))
    assert.is_true(same(vim.NIL, vim.NIL))
  end)
end)

describe("buffer_search compute_matches", function()
  local compute = search._test.compute_matches

  it("skips a non-table row instead of raising mid-search", function()
    -- The render path (format.row_cells) reads a malformed row as empty; the
    -- search pass used to ipairs into it and raise, killing the whole
    -- search for a hand-built or skewed response.
    local tab = {
      rows_source = { { "alpha", "1" }, "garbage", { "beta", "2" } },
      view_indices = nil,
      page_size = 50,
      search_matches = {},
      search_matches_by_page = {},
    }
    local ok = pcall(compute, tab, "a")
    assert.is_true(ok, "a non-table row must not raise")
    -- "alpha" and "beta" both contain an `a`; the garbage row must contribute
    -- nothing AND still occupy its view position, so beta keeps row = 3.
    assert.equals(2, tab.search_total_matches)
    assert.same({ { row = 1, col = 1 }, { row = 3, col = 1 } }, tab.search_matches)
  end)
end)
