--- Tests for format.lua helpers not covered elsewhere: timezone-aware
--- datetime rendering and the translated-SQL footnote.
---
--- Regression for the footnote: the raw original_sql was concatenated into a
--- buffer line, so a multi-line statement produced lines with embedded
--- newlines — nvim_buf_set_lines rejects those and the whole response render
--- aborted with "SQL execution error".

local sql_format = require("poste-db.format")
local width = require("poste-db.width")

--- Local UTC offset (seconds east of UTC), derived independently of the
--- module under test by comparing local and UTC renderings of one instant.
local function utc_offset()
  local now = os.time()
  return os.time(os.date("*t", now)) - os.time(os.date("!*t", now))
end

describe("format format_datetime_local", function()
  local dt = sql_format._test.format_datetime_local

  it("leaves strings without a timezone indicator unchanged", function()
    assert.equals("2026-01-01 12:00:00", dt("2026-01-01 12:00:00"))
    assert.equals("2026-01-01T12:00:00.123456", dt("2026-01-01T12:00:00.123456"))
    assert.equals("", dt(""))
    assert.equals("not a date", dt("not a date"))
  end)

  it("converts a Z (UTC) timestamp to the local wall clock", function()
    -- Regression: the old implementation dropped the offset entirely, so a
    -- `Z` timestamp rendered its UTC fields verbatim regardless of timezone.
    local fields = { year = 2026, month = 1, day = 1, hour = 12, min = 0, sec = 0 }
    local epoch_utc = os.time(fields) + utc_offset()
    local expected = os.date("%Y-%m-%d %H:%M:%S", epoch_utc)
    assert.equals(expected, dt("2026-01-01T12:00:00Z"))
  end)

  it("honors a +hh:mm offset", function()
    local fields = { year = 2026, month = 6, day = 15, hour = 12, min = 0, sec = 0 }
    -- `+05:30` means the fields are 5h30m ahead of UTC.
    local epoch_utc = os.time(fields) + utc_offset() - (5 * 3600 + 30 * 60)
    local expected = os.date("%Y-%m-%d %H:%M:%S", epoch_utc)
    assert.equals(expected, dt("2026-06-15T12:00:00+05:30"))
  end)

  it("honors a -hh:mm offset", function()
    local fields = { year = 2026, month = 6, day = 15, hour = 8, min = 30, sec = 0 }
    local epoch_utc = os.time(fields) + utc_offset() + (4 * 3600 + 30 * 60)
    local expected = os.date("%Y-%m-%d %H:%M:%S", epoch_utc)
    assert.equals(expected, dt("2026-06-15 08:30:00-04:30"))
  end)
end)

describe("format translated-SQL footnote", function()
  it("flattens multi-line original_sql so no rendered line contains a newline", function()
    local data = {
      type = "resultset",
      connection = "mysql://dev",
      database = "db",
      dialect = "mysql",
      total_rows = 1,
      results = { {
        columns = { { name = "id", type = "INT" } },
        rows = { { 1 } },
        row_count = 1,
        original_sql = "SELECT id\nFROM t\nWHERE id > 0",
        translated_sql = "SELECT id FROM t WHERE id > 0",
      } },
    }
    local lines, meta = sql_format.format_dataset({ body = vim.json.encode(data) })
    assert.equals("resultset", meta.type)
    assert.is_true(#lines > 1)
    for i, l in ipairs(lines) do
      assert.truthy(type(l) == "string" and not l:find("\n", 1, true),
        "line " .. i .. " contains a newline")
    end
    assert.truthy(vim.tbl_contains(lines, function(l)
      return l:find("SELECT id FROM t WHERE id > 0", 1, true) ~= nil
    end, { predicate = true }))
  end)

  it("keeps every wrapped footnote row inside the panel width", function()
    local save = vim.o.columns
    vim.o.columns = 80
    local parts = {}
    for i = 1, 40 do parts[i] = "column_" .. i end
    local sql = "SELECT " .. table.concat(parts, ", ")
    local lines = sql_format.format_dataset({ body = vim.json.encode({
      type = "resultset", connection = "mysql://dev", database = "db",
      dialect = "mysql", total_rows = 1,
      results = { {
        columns = { { name = "id", type = "INT" } },
        rows = { { 1 } }, row_count = 1,
        original_sql = sql, translated_sql = sql,
      } },
    }) })
    vim.o.columns = save
    local marker
    for i, l in ipairs(lines) do
      if l:find("⚡", 1, true) then marker = i end
    end
    assert.is_truthy(marker, "no ⚡ footnote row rendered")
    local rows = 0
    for i = marker, #lines do
      -- the marker row, then each continuation carries the 5-cell pad
      if i > marker and lines[i]:sub(1, 5) ~= "     " then break end
      rows = rows + 1
      assert.is_true(width.display_width(lines[i]) <= 76,
        ("footnote row %d is %d cells wide: %s"):format(i,
          width.display_width(lines[i]), lines[i]))
    end
    assert.is_true(rows > 1, "expected the footnote to wrap into several rows")
  end)
end)

describe("format wrap_text (error box)", function()
  it("wraps ASCII at the width boundary", function()
    local wrapped = sql_format._test.wrap_text(string.rep("a", 200), 78)
    assert.equals(3, #wrapped)
    assert.equals(78, #wrapped[1])
    assert.equals(78, #wrapped[2])
    assert.equals(string.rep("a", 44), wrapped[3])
  end)

  it("never splits a multibyte character (valid UTF-8 only)", function()
    -- CJK chars are 3 bytes / 2 display columns: a byte cut at width 78
    -- landed mid-character and put invalid UTF-8 into the buffer.
    local cjk = string.rep("数", 60) -- 120 display columns, 180 bytes
    local wrapped = sql_format._test.wrap_text(cjk, 78)
    assert.is_true(#wrapped >= 2)
    for _, l in ipairs(wrapped) do
      assert.equals(cjk:sub(1, 1), l:sub(1, #cjk:sub(1, 1)), "line kept its character")
      assert.equals(0, vim.fn.strchars(l) - vim.fn.strcharlen(l), "line is char-aligned")
    end
    local recombined = table.concat(wrapped)
    assert.equals(cjk, recombined)
  end)

  it("terminates on a budget narrower than one character", function()
    -- a 2-column glyph cannot fit in 1 cell: the cut must still take it whole
    -- rather than loop forever on an empty prefix
    local wrapped = sql_format._test.wrap_text(string.rep("数", 4), 1)
    assert.equals(4, #wrapped)
    assert.equals(string.rep("数", 4), table.concat(wrapped))
  end)

  it("wraps a mixed ASCII/CJK error message without corrupting it", function()
    local err = "relation 「ユーザーマスタ」 does not exist 数" .. string.rep("x", 100)
    local wrapped = sql_format._test.wrap_text(err, 78)
    assert.equals(err, table.concat(wrapped))
    for _, l in ipairs(wrapped) do
      assert.is_true(vim.fn.strdisplaywidth(l) <= 78)
    end
  end)
end)

describe("format dataset default page size", function()
  local dataset = require("poste-db.dataset")

  local function body(rows)
    return vim.json.encode({
      type = "resultset",
      total_rows = rows,
      results = { {
        columns = { { name = "id", type = "INT" } },
        rows = vim.tbl_map(function(i) return { i } end, vim.fn.range(rows)),
        row_count = rows,
      } },
      connection = "",
      database = "",
      dialect = "postgres",
    })
  end

  before_each(function()
    dataset.set_page_size(50)
  end)

  it("renders the configured default page size for the first page", function()
    dataset.set_page_size(4)
    local _, meta = sql_format.format_dataset({ body = body(10) })
    assert.equals("resultset", meta.type)
    assert.equals(4, meta.row_count)
  end)

  it("falls back to 50 when unconfigured", function()
    local _, meta = sql_format.format_dataset({ body = body(70) })
    assert.equals(50, meta.row_count)
  end)
end)

describe("format bordered table width stability", function()
  local config = require("poste-db.config")
  before_each(function()
    -- The strictest invariant (rows exactly as wide as the border under the
    -- terminal oracle) is only guaranteed in "terminal" mode; pin it so the
    -- test does not float with the configured default.
    config.config.width_mode = "terminal"
  end)
  after_each(function()
    config.config.width_mode = nil
  end)

  -- Regression: rows containing Devanagari/Persian and CJK cells rendered
  -- past the border — strdisplaywidth() folds Indic Mc spacing marks (ि ा ी)
  -- to zero width while the terminal paints each into a real cell, so those
  -- rows were padded short and the trailing │ was overwritten. Line widths
  -- here are measured with width.display_width(), the terminal-consistent
  -- oracle (see lua/poste-db/width.lua and LEARNINGS #16).
  local function civilisations()
    return {
      type = "resultset",
      total_rows = 5,
      results = { {
        columns = {
          { name = "id" }, { name = "id2" }, { name = "id3" }, { name = "name" },
          { name = "native_name" }, { name = "chinese_name" }, { name = "start" },
          { name = "end" }, { name = "writing_system" }, { name = "capital" },
        },
        rows = {
          { 4, 4, 4, "Indus Valley civilization", "सिंधु घाटी", "印度河谷文明", -2600, -1900, "ideographic", "摩亨佐-达罗" },
          { 5, 5, 5, "Persian civilization", "تمدن ایران", "波斯文明", -550, 1979, "alphabet", "波斯波利斯" },
        },
      } },
    }
  end

  it("keeps every rendered line exactly as wide as the table border", function()
    local layout = sql_format.plan_resultset_layout(civilisations())
    local lines = sql_format.render_page(layout, 1, 50)
    -- Terminal-visible width (width.display_width), not strdisplaywidth:
    -- vim folds Indic spacing marks to 0 while the terminal paints them, so
    -- a row can be strdisplaywidth-equal to the border yet 3 cells over.
    local border_w = width.display_width(lines[1])
    for i, l in ipairs(lines) do
      assert.equals(border_w, width.display_width(l),
        "line " .. i .. " must be exactly the border width")
    end
  end)

  it("closes every data row with a right border beneath the border line", function()
    local layout = sql_format.plan_resultset_layout(civilisations())
    local lines, meta = sql_format.render_page(layout, 1, 50)
    local border_w = width.display_width(lines[1])
    assert.matches("┐$", lines[1])
    assert.matches("┘$", lines[#lines])
    for i = meta.data_start_line, meta.data_end_line do
      assert.equals(border_w, width.display_width(lines[i]),
        "data row " .. i .. " must match the border width")
      assert.matches("│$", lines[i], "data row " .. i .. " must end with the right border")
    end
  end)

  it("keeps last-column byte offsets consistent after rebalancing", function()
    local layout = sql_format.plan_resultset_layout(civilisations())
    local lines, meta = sql_format.render_page(layout, 1, 50)
    local last = #layout.col_widths
    for i, starts in ipairs(meta.col_starts) do
      local line = lines[meta.data_start_line + i - 1]
      -- The final separator is 3 bytes after the last cell's end.
      assert.equals(#line, starts[last].ext_end + 3,
        "last column byte end must sit right before the trailing │")
    end
  end)end)

describe("format credential display", function()
  -- The binary echoes resolved connection URLs (never names), so every
  -- user-visible surface that prints them has to redact.
  it("redacts the DSN in the error panel's message and connection line", function()
    local lines = sql_format._test.format_error(
      "auth failed for postgres://u:pw@h:5432/db",
      "postgres://u:pa/ss@h:5432/db?password=hunter2")
    local text = table.concat(lines, "\n")
    assert.is_nil(text:find("hunter2", 1, true))
    assert.is_nil(text:find(":pw@", 1, true))
    assert.is_nil(text:find("pa/ss", 1, true))
    assert.truthy(text:find("Connection: postgres://u:***@h:5432/db?password=***", 1, true))
    assert.truthy(text:find("auth failed for postgres://u:***@h:5432/db", 1, true))
  end)

  it("redacts the DSN in a USE context-switch header", function()
    local lines = sql_format.format_dataset({
      body = vim.json.encode({
        type = "use", database_name = "blog", dialect = "postgres",
        connection = "postgres://u:pw@h:5432/db",
      }),
    })
    assert.equals("  Connection: postgres://u:***@h:5432/db", lines[4])
  end)
end)

describe("format_error non-string error shapes", function()
  -- The seam sits below verdict.error_text, whose structured-error branch
  -- (vim.inspect) guards one caller — but handle_error forwards its raw
  -- message here too, and a non-string there used to raise inside wrap_text
  -- (`#text` on a number, `text .. "\n"` on a table). Same family the
  -- db_browser summaries fixed: a non-string error must render, not raise.
  it("renders a table error as inspect text, not a crash", function()
    local lines = sql_format._test.format_error({ code = "42601" }, "conn")
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("42601", 1, true))
    assert.truthy(text:find("SQL Error", 1, true))
  end)

  it("renders a number error without raising on the length probe", function()
    local lines = sql_format._test.format_error(42601, "conn")
    assert.truthy(table.concat(lines, "\n"):find("42601", 1, true))
  end)

  it("renders nil and vim.NIL as an empty message, not a crash", function()
    for _, shape in ipairs({ nil, vim.NIL }) do
      local lines = sql_format._test.format_error(shape, "conn")
      assert.truthy(table.concat(lines, "\n"):find("SQL Error", 1, true))
    end
  end)

  it("still redacts the DSN inside a structured error's inspect text", function()
    local lines = sql_format._test.format_error(
      { detail = "postgres://u:pw@h:5432/db" }, "conn")
    assert.is_nil(table.concat(lines, "\n"):find(":pw@", 1, true))
  end)
end)

describe("format wrap_line (translated-SQL footnote rows)", function()
  it("keeps the leading indent so the ⚡ row aligns with its continuations", function()
    -- gmatch("%S+") dropped the indent, so the marker row lost the two
    -- columns the caller pads every continuation with
    local rows = sql_format._test.wrap_line("  ⚡ SELECT a b c", 12)
    assert.equals("  ⚡ SELECT", rows[1])
    assert.equals("  a b c", rows[2])
    -- the caller pads continuations with "     " (5 cells): the marker
    -- prefix has to occupy exactly those 5 cells for the rows to line up
    assert.equals(5, width.display_width("  ⚡ "))
  end)

  it("returns a line that already fits untouched", function()
    local rows = sql_format._test.wrap_line("  ⚡ SELECT 1", 40)
    assert.equals(1, #rows)
    assert.equals("  ⚡ SELECT 1", rows[1])
  end)

  it("gives an over-long word its own row instead of an empty one", function()
    -- a single token wider than the width used to emit "" first, which the
    -- footnote renders as a blank row above the marker
    local long = string.rep("x", 30)
    local rows = sql_format._test.wrap_line("  ⚡" .. long, 12)
    assert.equals(1, #rows)
    assert.equals("  ⚡" .. long, rows[1])
  end)
end)

describe("format_dataset affected responses", function()
  local verdict = require("poste-db.verdict")

  local function affected_resp(results, extra)
    return { body = vim.json.encode(vim.tbl_extend("force",
      { type = "affected", results = results }, extra or {})) }
  end

  it("renders a rejected statement as ERROR even when it said nothing", function()
    -- The verdict is the `failed` flag, not the presence of a message: this shape
    -- printed "Query OK" for an INSERT the server turned down.
    local lines, meta = sql_format.format_dataset(affected_resp({
      { failed = true, affected_rows = 0, execution_time_ms = 3 },
    }))
    assert.equals("error", meta.type)
    local text = table.concat(lines, "\n")
    assert.is_nil(text:find("Query OK", 1, true))
    assert.truthy(text:find("ERROR", 1, true))
    assert.truthy(text:find(verdict.UNEXPLAINED_FAILURE, 1, true))
  end)

  it("names the server's message when there is one", function()
    local lines, meta = sql_format.format_dataset(affected_resp({
      { error = "unique constraint failed", affected_rows = 0, execution_time_ms = 1 },
    }))
    assert.equals("error", meta.type)
    assert.truthy(table.concat(lines, "\n"):find("unique constraint failed", 1, true))
  end)

  it("numbers per-statement rows and keeps a success beside a failure", function()
    local lines, meta = sql_format.format_dataset(affected_resp({
      { affected_rows = 2, execution_time_ms = 1 },
      { failed = true, execution_time_ms = 4 },
    }))
    assert.equals("error", meta.type)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("Statement 1: 2 row(s) affected", 1, true))
    assert.truthy(text:find("Statement 2: ERROR", 1, true))
  end)

  it("reports a plain DML as affected rows", function()
    local lines, meta = sql_format.format_dataset(affected_resp({
      { affected_rows = 1, execution_time_ms = 2 },
    }))
    assert.equals("affected", meta.type)
    assert.truthy(table.concat(lines, "\n"):find("1 row(s) affected", 1, true))
  end)
end)
