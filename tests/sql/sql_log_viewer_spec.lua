--- Tests for SQL execution log viewer.
local log = require("poste-db.log_viewer")

describe("log viewer _format_time", function()
  it("formats as MM-DD HH:mm:ss", function()
    assert.equals("06-13 10:30:00", log._format_time("2026-06-13T10:30:00"))
  end)

  it("formats another timestamp", function()
    assert.equals("12-25 14:05:22", log._format_time("2025-12-25T14:05:22"))
  end)

  it("handles nil", function()
    assert.equals("??-?? ??:??:??", log._format_time(nil))
  end)

  it("handles non-ISO string", function()
    assert.equals("raw-time", log._format_time("raw-time"))
  end)

  it("handles a non-string ts without indexing it", function()
    -- A corrupt journal line (numeric ts) used to raise here and abort the
    -- whole render; the loader now coerces, and the helper itself stays safe.
    assert.equals("??-?? ??:??:??", log._format_time(1728000000))
    assert.equals("??-?? ??:??:??", log._format_time({}))
  end)
end)

describe("log viewer _preview_sql", function()
  it("returns empty string for nil", function()
    assert.equals("", log._preview_sql(nil, 50))
  end)

  it("returns SQL unchanged when under max length", function()
    assert.equals("SELECT 1", log._preview_sql("SELECT 1", 50))
  end)

  it("truncates with ellipsis when over max length", function()
    local long = string.rep("x", 100)
    local result = log._preview_sql(long, 10)
    -- "…" is 3 bytes in UTF-8
    assert.equals(12, #result)
    assert.equals("…", result:sub(-3))
  end)

  it("shows first line with ellipsis for multi-line SQL", function()
    assert.equals("a…", log._preview_sql("a\nb", 50))
  end)

  it("never splits a multi-byte character (CJK preview)", function()
    -- 15 CJK chars = 45 bytes / 30 display columns. The byte-slicing version
    -- cut at byte 9 and emitted half a character.
    local cjk = string.rep("数", 15)
    -- budget 10 columns: 4 chars (8 cols) + "…" (1 col), next char needs 2
    assert.equals(string.rep("数", 4) .. "…", log._preview_sql(cjk, 10))
  end)
end)

describe("log viewer display-width helpers", function()
  it("_fit_width keeps short text unchanged", function()
    assert.equals("abc", log._fit_width("abc", 10))
  end)

  it("_fit_width truncates CJK on a char boundary with an ellipsis", function()
    local cjk = string.rep("数", 20) -- 40 display columns
    local result = log._fit_width(cjk, 10)
    assert.equals(string.rep("数", 4) .. "…", result)
    assert.equals(9, vim.fn.strdisplaywidth(result))
  end)

  it("_pad_table pads ASCII to the column width", function()
    assert.equals("users     ", log._pad_table("users", 10))
  end)

  it("_pad_table truncates a CJK name on a char boundary", function()
    local cjk = string.rep("数", 15) -- 30 columns / 45 bytes
    local out = log._pad_table(cjk, 10)
    -- 4 chars (8 cols) + "…" (1 col) — one column reserved for the ellipsis
    assert.equals(string.rep("数", 4) .. "…", out)
    assert.equals(9, vim.fn.strdisplaywidth(out))
  end)

  it("_pad_table keeps a CJK name that fits and pads with spaces", function()
    -- 3 chars = 6 columns; width 10 → 4 trailing spaces
    assert.equals(string.rep("数", 3) .. "    ", log._pad_table(string.rep("数", 3), 10))
  end)
end)

describe("log viewer outcome marks", function()
  it("marks a failed entry with ✗ and a partial one with !", function()
    assert.equals("✗", log._status_mark({ status = "error" }))
    assert.equals("!", log._status_mark({ status = "partial" }))
    assert.equals(" ", log._status_mark({ status = "success" }))
    assert.equals(" ", log._status_mark({}), "an entry whose writer stored no status stays unmarked")
  end)

  it("keeps the mark and the hand-numbered column parts in sync", function()
    -- apply_highlights reads these by index (2 = mark, 4 = time, 6 = db,
    -- 8 = duration, 10 = source tag). Insert a part without renumbering and
    -- every column is tinted one slot off while nothing errors.
    local parts = log._summary_parts({
      ts = "2026-06-13T10:30:00", table = "users", status = "partial",
      source = "dataset_commit", sql = "UPDATE users SET name = 'a'",
    }, 10)
    assert.equals(12, #parts)
    assert.equals("!", parts[2])
    assert.equals("06-13 10:30:00", parts[4])
    -- The db segment is asserted by equality now that the width is a parameter:
    -- it used to be `find`, because the padding came out of module state that
    -- whichever `_pad_table` call happened to run last had written.
    assert.equals("users     ", parts[6])
    assert.truthy(parts[10]:find("commit", 1, true))
    assert.truthy(parts[12]:find("UPDATE users", 1, true))
  end)

  it("pads to the width it is given, not the last one written", function()
    log._pad_table("anything", 20)
    local parts = log._summary_parts({
      ts = "2026-06-13T10:30:00", table = "users",
    }, 7)
    assert.equals("users  ", parts[6], "a pinned pad width must not decide another row's column")
  end)

  it("finds partial rows through the filter", function()
    log._set_filter_text("partial")
    assert.is_true(log._filter_matches({ status = "partial" }))
    assert.is_false(log._filter_matches({ status = "success" }))
    log._set_filter_text("")
  end)
end)

describe("log viewer _edit_summary_line", function()
  it("shows which part of the edit set actually landed", function()
    local line = log._edit_summary_line({
      edit_summary = { updates = 2, inserts = 0, deletes = 0 },
      affected_rows = 1,
    })
    assert.truthy(line:find("2 updates"))
    assert.truthy(line:find("1 of 2 row%(s%) affected"))
  end)

  it("leaves the affected count out when the writer recorded none", function()
    local line = log._edit_summary_line({ edit_summary = { updates = 1 } })
    assert.is_nil(line:find("affected"))
  end)

  it("returns nil for an entry with no edit summary", function()
    assert.is_nil(log._edit_summary_line({ sql = "SELECT 1" }))
  end)
end)

describe("log viewer _filter_matches", function()
  it("matches everything when filter is empty", function()
    assert.is_true(log._filter_matches({ table = "posts" }))
  end)

  it("matches by table name", function()
    log._set_filter_text("posts")
    assert.is_true(log._filter_matches({ table = "posts" }))
    assert.is_false(log._filter_matches({ table = "users" }))
    log._set_filter_text("")
  end)

  it("matches by status", function()
    log._set_filter_text("error")
    assert.is_true(log._filter_matches({ status = "error" }))
    assert.is_false(log._filter_matches({ status = "success" }))
    log._set_filter_text("")
  end)

  it("matches by connection", function()
    log._set_filter_text("pg-ecommerce")
    assert.is_true(log._filter_matches({ connection = "pg-ecommerce" }))
    log._set_filter_text("")
  end)

  it("matches by sql content", function()
    log._set_filter_text("DELETE")
    assert.is_true(log._filter_matches({ sql = "DELETE FROM posts" }))
    assert.is_false(log._filter_matches({ sql = "SELECT * FROM posts" }))
    log._set_filter_text("")
  end)

  it("matches by error text", function()
    -- The detail highlight pass already marks filter matches on error lines,
    -- so the reason text is searchable: the old field list filtered on it to
    -- an empty list instead.
    log._set_filter_text("timeout")
    assert.is_true(log._filter_matches({ error = "Timeout after 5000ms" }))
    assert.is_false(log._filter_matches({ sql = "SELECT 1", status = "success" }))
    log._set_filter_text("")
  end)
end)

describe("log viewer _count_detail_lines", function()
  it("counts minimal entry with just meta line", function()
    local entry = { connection = "c1", sql = "SELECT 1" }
    assert.equals(3, log._count_detail_lines(entry))
  end)

  it("counts entry with edit_summary", function()
    local entry = { connection = "c1", sql = "SELECT 1", edit_summary = { updates = 1 } }
    assert.equals(4, log._count_detail_lines(entry))
  end)

  it("counts entry with error", function()
    local entry = { connection = "c1", sql = "SELECT 1", error = "syntax error" }
    assert.equals(4, log._count_detail_lines(entry))
  end)

  it("counts multi-line SQL", function()
    local entry = { connection = "c1", sql = "line1\nline2\nline3" }
    assert.equals(5, log._count_detail_lines(entry))
  end)

  it("counts entry without connection (no meta line)", function()
    local entry = { sql = "SELECT 1" }
    assert.equals(2, log._count_detail_lines(entry))
  end)
end)

describe("log viewer _get_entry_at_line", function()
  before_each(function()
    log._set_entries({
      { table = "posts", connection = "c1", status = "success", sql = "SELECT 1" },
      { table = "users", connection = "c1", status = "error",   sql = "SELECT 2" },
      { table = "tags",  connection = "c2", status = "success", sql = "SELECT 3" },
    })
  end)

  it("returns nil for line 0", function()
    assert.is_nil(log._get_entry_at_line(0))
  end)

  it("returns entry 1 at line 1 (first data row)", function()
    assert.equals(1, log._get_entry_at_line(1))
  end)

  it("returns entry 2 at line 2", function()
    assert.equals(2, log._get_entry_at_line(2))
  end)

  it("returns entry 3 at line 3", function()
    assert.equals(3, log._get_entry_at_line(3))
  end)

  it("returns nil past last entry", function()
    assert.is_nil(log._get_entry_at_line(10))
  end)

  it("returns same entry when on detail lines (expanded)", function()
    log._set_entries({
      { table = "posts", connection = "c1", status = "success", sql = "SELECT 1" },
    })
    log._set_expanded(1, true)
    assert.equals(1, log._get_entry_at_line(2))
    assert.equals(1, log._get_entry_at_line(3))
  end)
end)

describe("log viewer _clean_sql", function()
  it("returns empty string for nil", function()
    assert.equals("", log._clean_sql(nil))
  end)

  it("keeps plain SQL unchanged", function()
    assert.equals("SELECT 1", log._clean_sql("SELECT 1"))
  end)

  it("strips -- @connection directive", function()
    local result = log._clean_sql("-- @connection my-blog\nSELECT 1")
    assert.equals("SELECT 1", result)
  end)

  it("strips -- @database directive", function()
    local result = log._clean_sql("-- @connection my-blog\n-- @database blog\nSELECT 1")
    assert.equals("SELECT 1", result)
  end)

  it("strips ### block markers", function()
    local result = log._clean_sql("-- @connection c\n\n###\nSELECT 1")
    assert.equals("SELECT 1", result)
  end)

  it("preserves multiple SQL statements", function()
    local result = log._clean_sql("-- @connection c\nSELECT 1;\nSELECT 2")
    assert.equals("SELECT 1;\nSELECT 2", result)
  end)

  it("strips leading newline from buffer extraction", function()
    local result = log._clean_sql("\nSELECT * FROM posts")
    assert.equals("SELECT * FROM posts", result)
  end)

  it("strips leading blank line before ###", function()
    local result = log._clean_sql("-- @connection c\n-- @database d\n\n###\nSELECT 1")
    assert.equals("SELECT 1", result)
  end)
end)

describe("log viewer _guess_table", function()
  it("extracts from SELECT", function()
    assert.equals("posts", log._guess_table("SELECT * FROM posts"))
  end)

  it("extracts from SELECT with schema", function()
    assert.equals("posts", log._guess_table("SELECT id, name FROM public.posts"))
  end)

  it("extracts from UPDATE", function()
    assert.equals("users", log._guess_table("UPDATE users SET name = 'x'"))
  end)

  it("extracts from JOIN", function()
    assert.equals("comments", log._guess_table("SELECT * FROM posts JOIN comments ON ..."))
  end)

  it("extracts from INSERT INTO", function()
    assert.equals("logs", log._guess_table("INSERT INTO logs (msg) VALUES ('hello')"))
  end)

  it("extracts from DELETE FROM", function()
    assert.equals("sessions", log._guess_table("DELETE FROM sessions WHERE expires < NOW()"))
  end)

  it("returns nil for no table reference", function()
    assert.is_nil(log._guess_table("BEGIN"))
  end)

  it("handles nil input", function()
    assert.is_nil(log._guess_table(nil))
  end)
end)

describe("log viewer _entry_table", function()
  it("uses entry.table when set", function()
    assert.equals("posts", log._entry_table({ table = "posts", sql = "SELECT 1" }))
  end)

  it("falls back to entry.table_name", function()
    assert.equals("users", log._entry_table({ table_name = "users", sql = "SELECT 1" }))
  end)

  it("guesses from SQL when no table field", function()
    assert.equals("posts", log._entry_table({ sql = "SELECT * FROM posts" }))
  end)

  it("returns nil when nothing matches", function()
    assert.is_nil(log._entry_table({ sql = "BEGIN" }))
  end)
end)

describe("log viewer _normalize_entry", function()
  it("coerces hostile scalar fields to strings", function()
    local e = log._normalize_entry({
      ts = 1728000000, sql = 42, status = true,
      connection = {}, database = vim.NIL, elapsed_ms = "slow",
    })
    assert.equals("1728000000", e.ts)
    assert.equals("42", e.sql)
    assert.equals("true", e.status)
    assert.is_nil(e.connection, "a table field is unreadable as a string and drops")
    assert.is_nil(e.database, "vim.NIL drops too")
    assert.is_nil(e.elapsed_ms, "a non-number elapsed_ms drops rather than rendering as a table address")
  end)

  it("rejects a line that was not an object", function()
    assert.is_nil(log._normalize_entry(42))
    assert.is_nil(log._normalize_entry("sql"))
    assert.is_nil(log._normalize_entry(nil))
  end)

  it("leaves well-formed entries untouched", function()
    local src = { ts = "2026-10-05T10:00:00", sql = "SELECT 1", status = "success", elapsed_ms = 12 }
    assert.same(src, log._normalize_entry(vim.deepcopy(src)))
  end)

  it("keeps the viewer alive over entries that used to crash the render", function()
    -- One corrupt line among good ones: before the seam, format_time indexed
    -- the numeric ts and the whole toggle errored out.
    log._set_entries({
      { ts = 1728000000, sql = "SELECT 1", status = "success" },
      { ts = "2026-10-05T10:00:00", sql = "SELECT 2", status = "success" },
      { ts = "2026-10-05T09:00:00", sql = "SELECT 3", status = "success", error = { code = 1 } },
    })
    -- all three entries survive and resolve by line
    assert.equals(1, log._get_entry_at_line(1))
    assert.equals(3, log._get_entry_at_line(3))
    -- every entry survives and the summary parts build without raising
    local parts = log._summary_parts({ ts = 1728000000, sql = "SELECT 1", table = 7 }, 10)
    assert.equals("string", type(parts[4]))
    assert.truthy(parts[6]:find("7", 1, true))
  end)
end)

describe("log viewer _rerun_lines", function()
  it("prefixes a connection *name* with the directive the runner reads", function()
    assert.same({ "-- @connection blog-db", "SELECT 1;" },
      log._rerun_lines({ connection = "blog-db", sql = "SELECT 1;" }))
  end)

  it("drops a redacted URL, which is not a stanza name", function()
    assert.same({ "SELECT 1;" }, log._rerun_lines({
      connection = "postgres://blog:***@localhost:5432/blog", sql = "SELECT 1;",
    }))
  end)

  it("keeps a multi-line statement one buffer line per line", function()
    assert.same({ "SELECT 1", "FROM t;" }, log._rerun_lines({ sql = "SELECT 1\nFROM t;" }))
  end)

  it("emits a single empty line for an entry with no SQL", function()
    assert.same({ "" }, log._rerun_lines({}))
  end)
end)

describe("log viewer _open_in_sql_buffer", function()
  local start_bufs = #vim.api.nvim_list_bufs()

  it("writes the lines into a fresh listed sql buffer and focuses it", function()
    local b = log._open_in_sql_buffer({ "-- @connection blog-db", "SELECT 1;" })
    assert.equals(b, vim.api.nvim_get_current_buf())
    assert.same({ "-- @connection blog-db", "SELECT 1;" },
      vim.api.nvim_buf_get_lines(b, 0, -1, true))
    assert.equals("sql", vim.bo[b].filetype)
    assert.is_true(vim.bo[b].buflisted, "an unlisted buffer is wiped on quit, SQL and all")
    assert.equals(start_bufs + 1, #vim.api.nvim_list_bufs())
  end)

  it("puts the cursor on the statement, past the directive", function()
    log._open_in_sql_buffer({ "-- @connection blog-db", "SELECT 1;" })
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("puts the cursor on line 1 when there is no directive", function()
    log._open_in_sql_buffer({ "SELECT 1;" })
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  after_each(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b > start_bufs then vim.api.nvim_buf_delete(b, { force = true }) end
    end
  end)
end)

describe("log viewer clear_logs", function()
  local notified = {}
  local real_open, real_notify

  before_each(function()
    notified = {}
    real_open = io.open
    real_notify = vim.notify
    vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
  end)

  after_each(function()
    -- luacheck: ignore 122 (stubbing io.open is the point of the test)
    io.open = real_open
    vim.notify = real_notify
  end)

  it("reports the clear when the file truncate opened", function()
    log.clear_logs()

    assert.equals(1, #notified)
    assert.equals("SQL log cleared", notified[1].msg)
    assert.equals(vim.log.levels.INFO, notified[1].level)
  end)

  it("does not claim success when the log file cannot be written", function()
    -- The in-memory view is always cleared, but the old code reported
    -- "SQL log cleared" even when the truncate never opened the file —
    -- the on-disk log survived while the user believed it gone.
    -- luacheck: ignore 122 (stubbing io.open is the point of the test)
    io.open = function() return nil end
    log.clear_logs()

    assert.equals(1, #notified)
    assert.equals(vim.log.levels.WARN, notified[1].level)
    assert.truthy(notified[1].msg:find("could not be written", 1, true))
  end)
end)

describe("log viewer request_clear", function()
  -- `C` wiped the whole journal on one keypress. The journal is the only
  -- record of what ran (the notify that reported a failure is long gone),
  -- so the keymap now asks first.
  local real_open, real_notify
  local notified

  before_each(function()
    real_open = io.open
    real_notify = vim.notify
    notified = {}
    -- luacheck: ignore 122
    io.open = function(_, mode)
      if mode == "w" then written = (written or 0) + 1; return { write = function() end, close = function() end } end
      return nil
    end
    vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
  end)

  after_each(function()
    -- luacheck: ignore 122
    io.open = real_open
    vim.notify = real_notify
    written = nil
  end)

  local function load_two_entries()
    -- two parsed entries, so the confirm path is the one under test
    log._set_entries({
      { ts = "2026-06-13T10:30:00", source = "exec", sql = "SELECT 1", status = "success" },
      { ts = "2026-06-13T10:31:00", source = "exec", sql = "SELECT 2", status = "error", error = "boom" },
    })
  end

  it("clears without asking when there is nothing to lose", function()
    log._set_entries({})
    log.request_clear()
    assert.equals("SQL log cleared", notified[1].msg)
  end)

  it("does not wipe the journal until the confirm answers yes", function()
    load_two_entries()
    local confirmed, cancelled = false, false
    log.request_clear({
      on_confirm = function() confirmed = true end,
      on_cancel = function() cancelled = true end,
    })
    -- the dialog is open and unanswered: neither callback fired, nothing written
    assert.is_false(confirmed)
    assert.is_false(cancelled)
    assert.is_nil(written)
  end)

  it("clears when the dialog is answered y", function()
    load_two_entries()
    local confirmed = false
    log.request_clear({ on_confirm = function() confirmed = true end })
    vim.api.nvim_feedkeys("y", "x", false)
    assert.is_true(confirmed)
    assert.equals(1, written)
  end)

  it("leaves the journal alone when the dialog is answered n", function()
    load_two_entries()
    local cancelled = false
    log.request_clear({ on_cancel = function() cancelled = true end })
    vim.api.nvim_feedkeys("n", "x", false)
    assert.is_true(cancelled)
    assert.is_nil(written)
    assert.equals("SQL log left untouched", notified[1].msg)
  end)
end)
