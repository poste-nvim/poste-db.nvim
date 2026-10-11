local statement = require("poste-db.statement")
local D = require("poste-db.dataset")

describe("statement extract_label", function()
  it("takes the comment directly above the statement", function()
    local buf = { "-- get users", "SELECT * FROM users;" }
    assert.equals("get users", statement.extract_label(buf, 2))
  end)

  it("skips directive comments but keeps the plain comment above them", function()
    local buf = { "-- get users", "-- @connection pg-dev", "SELECT * FROM users;" }
    assert.equals("get users", statement.extract_label(buf, 3))
  end)

  it("skips blank lines between comment and statement", function()
    local buf = { "-- get users", "", "SELECT * FROM users;" }
    assert.equals("get users", statement.extract_label(buf, 3))
  end)

  it("returns nil when a code line sits directly above", function()
    local buf = { "SELECT 1;", "SELECT 2;" }
    assert.is_nil(statement.extract_label(buf, 2))
  end)

  -- The trailing comment of the previous statement is on a code line, so it
  -- must NOT be picked up as a label.
  it("ignores trailing comments on the previous statement line", function()
    local buf = { "SELECT 1; -- first", "", "SELECT 2;" }
    assert.is_nil(statement.extract_label(buf, 3))
  end)

  it("returns nil for an empty comment", function()
    local buf = { "--", "SELECT 1;" }
    assert.is_nil(statement.extract_label(buf, 2))
  end)

  it("falls back to the enclosing ### block header name", function()
    local buf = { "### users list", "SELECT * FROM users;" }
    assert.equals("users list", statement.extract_label(buf, 2))
  end)

  it("does not cross a ### marker into the previous block", function()
    local buf = { "### previous", "SELECT 1;", "### users list", "SELECT * FROM users;" }
    assert.equals("users list", statement.extract_label(buf, 4))
  end)

  it("truncates long labels with an ellipsis", function()
    local long = string.rep("x", 60)
    local buf = { "-- " .. long, "SELECT 1;" }
    local label = statement.extract_label(buf, 2)
    -- 37 cells + ASCII "..." via util.ellipsize (the old hand-rolled cut
    -- appended a 3-byte UTF-8 … and split glyphs on CJK labels)
    assert.equals(40, #label)
    assert.equals("...", label:sub(-3))
    assert.equals(37, #label:sub(1, -4))
  end)

  it("handles indented comments", function()
    local buf = { "    -- get users", "SELECT * FROM users;" }
    assert.equals("get users", statement.extract_label(buf, 2))
  end)

  it("caps a ### block header at the same budget as a comment label", function()
    local long = string.rep("y", 60)
    local buf = { "### " .. long, "SELECT 1;" }
    local label = statement.extract_label(buf, 2)
    assert.equals(40, #label)
    assert.equals("...", label:sub(-3))
  end)

  it("caps a ### header without splitting a multibyte character", function()
    -- 30 CJK glyphs = 90 bytes: the byte-cut this replaced stopped inside a
    -- 3-byte character and put invalid UTF-8 into the sidebar.
    local buf = { "### " .. string.rep("字", 30), "SELECT 1;" }
    local label = statement.extract_label(buf, 2)
    assert.is_not_nil(label)
    assert.is_true(vim.fn.strdisplaywidth(label) <= 40)
    -- no U+FFFD: a byte-level cut left a half character behind and the
    -- sidebar rendered the replacement glyph
    assert.is_nil(label:find("\239\191\189", 1, true))
    -- whole characters only: strcharpart round-trips a well-formed string
    assert.equals(label, vim.fn.strcharpart(label, 0, vim.fn.strchars(label)))
    assert.equals("...", label:sub(-3))
    assert.is_true(vim.fn.strchars(label) > 1)
  end)
end)

describe("dataset history", function()
  before_each(function()
    D.history = {}
    D.active_history = 0
    D.tabs = {}
    D.active_tab_idx = 0
    D.buf_label_count = {}
    D.max_history = 20
  end)

  it("format_elapsed uses 分:秒.毫秒 with 2-digit minutes", function()
    assert.equals("00:00.000", D.format_elapsed(0))
    assert.equals("00:00.123", D.format_elapsed(123))
    assert.equals("00:01.234", D.format_elapsed(1234))
    assert.equals("01:15.432", D.format_elapsed(75432))
    assert.equals("00:00.000", D.format_elapsed(nil))
    assert.equals("00:02.000", D.format_elapsed("2000"))
  end)

  it("format_wallclock renders 时:分:秒.毫秒 from sec/nsec", function()
    local sec = os.time(os.date("*t")) -- local wall seconds
    local t = os.date("*t", sec)
    assert.equals(string.format("%02d:%02d:%02d.%03d", t.hour, t.min, t.sec, 456),
      D.format_wallclock(sec, 456000000))
    assert.equals(string.format("%02d:%02d:%02d.%03d", t.hour, t.min, t.sec, 7),
      D.format_wallclock(sec, 7000000))
    assert.equals(string.format("%02d:%02d:%02d.%03d", t.hour, t.min, t.sec, 0),
      D.format_wallclock(sec, 0))
  end)

  it("now_wall returns a wall-clock timestamp with sec and nsec", function()
    local ts = D.now_wall()
    assert.is_number(ts.sec)
    assert.is_number(ts.nsec)
    assert.is_true(ts.sec > 0)
    assert.is_true(ts.nsec >= 0 and ts.nsec < 1000000000)
  end)

  it("new_entry creates an active entry and swaps the tabs pointer", function()
    local entry = D.new_entry({ label = "get users", src_buf = 1, src_file = "test.sql" })
    assert.equals(1, D.history_count())
    assert.equals(1, D.active_history)
    assert.same(entry, D.active_entry())
    assert.same(entry.tabs, D.tabs) -- pointer swap
    -- allocation lands in the entry's tabs
    local tab = D.alloc_tab(1)
    assert.same(tab, entry.tabs[1])
    assert.same(tab, D.tabs[1])
  end)

  it("switch_entry preserves each entry's tabs and last_tab", function()
    local e1 = D.new_entry({ label = "one" })
    D.alloc_tab(1)
    D.active_tab_idx = 1
    local e2 = D.new_entry({ label = "two" })
    D.alloc_tab(1)
    D.alloc_tab(2)
    D.active_tab_idx = 2

    D.switch_entry(1)
    assert.same(e1, D.active_entry())
    assert.same(e1.tabs, D.tabs)
    assert.equals(1, D.active_tab_idx) -- e1.last_tab captured before switching away
    assert.same(e1.tabs[1], D.tabs[1])

    D.switch_entry(2)
    assert.same(e2, D.active_entry())
    assert.equals(2, D.active_tab_idx)
    assert.equals(2, #D.tabs)
  end)

  it("evicts the oldest entry beyond max_history, keeping the active one", function()
    D.set_max_history(3)
    local e1 = D.new_entry({ label = "1" })
    local e2 = D.new_entry({ label = "2" })
    D.new_entry({ label = "3" })
    local e4 = D.new_entry({ label = "4" })
    assert.equals(3, D.history_count())
    -- e4 shifted from index 4 to index 3 after eviction
    assert.equals(3, D.active_history)
    assert.same(e2, D.history[1])
    assert.same(e4, D.active_entry())
    assert.is_nil(D.history[e1])
  end)

  it("delete_entry fixes up the active pointer", function()
    D.new_entry({ label = "1" })
    local e2 = D.new_entry({ label = "2" })
    D.switch_entry(1)
    D.delete_entry(1)
    assert.equals(1, D.history_count())
    assert.equals(1, D.active_history)
    assert.same(e2, D.active_entry())
    assert.same(e2.tabs, D.tabs)
  end)

  it("delete_entry blanks state when history becomes empty", function()
    D.new_entry({ label = "only" })
    D.delete_entry(1)
    assert.equals(0, D.history_count())
    assert.equals(0, D.active_history)
    assert.same({}, D.tabs)
  end)

  it("delete_entry keeps the active request when an older one is removed", function()
    D.new_entry({ label = "1" })
    D.new_entry({ label = "2" })
    local e3 = D.new_entry({ label = "3" })
    assert.equals(3, D.active_history)
    D.delete_entry(1)
    -- e3 slid from slot 3 to slot 2 and must still be the one on screen
    assert.equals(2, D.history_count())
    assert.equals(2, D.active_history)
    assert.same(e3, D.active_entry())
    assert.same(e3.tabs, D.tabs)
  end)

  it("delete_entry keeps the active request when a middle one is removed", function()
    D.new_entry({ label = "1" })
    D.new_entry({ label = "2" })
    local e3 = D.new_entry({ label = "3" })
    D.delete_entry(2)
    assert.equals(2, D.active_history)
    assert.same(e3, D.active_entry())
  end)

  it("delete_entry leaves the active request alone when a newer one is removed", function()
    local e1 = D.new_entry({ label = "1" })
    D.new_entry({ label = "2" })
    D.new_entry({ label = "3" })
    D.switch_entry(1)
    D.delete_entry(3)
    assert.equals(1, D.active_history)
    assert.same(e1, D.active_entry())
  end)

  it("delete_entry clamps to the new last entry when the tail was active", function()
    D.new_entry({ label = "1" })
    local e2 = D.new_entry({ label = "2" })
    D.new_entry({ label = "3" })
    D.delete_entry(3)
    assert.equals(2, D.active_history)
    assert.same(e2, D.active_entry())
  end)

  it("next_label_number counts per buffer", function()
    assert.equals(1, D.next_label_number(11))
    assert.equals(2, D.next_label_number(11))
    assert.equals(1, D.next_label_number(22))
  end)

  it("fallback_label builds basename_N from the source file", function()
    local label = statement.fallback_label("/path/to/test.sql", 11)
    assert.equals("test_1", label)
    assert.equals("test_2", statement.fallback_label("/path/to/test.sql", 11))
    assert.equals("blog_1", statement.fallback_label("/other/blog.sqlite", 22))
  end)
end)

describe("dataset history sidebar keymaps", function()
  -- Regression for the `refresh` global-nil bug in activate()/delete_current()
  -- and for the floating-window sweep in header.close()/clear_panel() that
  -- used to close the sidebar. Runs against real headless windows.
  local buffer_mod = require("poste-db.buffer")
  local history

  local function make_env()
    D.history = {}
    D.active_history = 0
    D.tabs = {}
    D.active_tab_idx = 0
    D.dataset_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = D.dataset_buffer })
    vim.cmd("botright 6split")
    D.dataset_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(D.dataset_window, D.dataset_buffer)
    D.dataset_tabpage = vim.api.nvim_get_current_tabpage()
    history = require("poste-db.buffer.history")
  end

  local function add_entry(label)
    local e = D.new_entry({ label = label, src_buf = 1, src_file = "test.sql" })
    local t = D.alloc_tab(1)
    t.padded = { "  │ id │" }
    t.meta = { type = "resultset", row_count = 0, data_start_line = 1, table_name = "t", total_rows = 0 }
    t.cursor = { row = 1, col = 1 }
    return e
  end

  local function invoke_map(lhs)
    local map = vim.fn.maparg(lhs, "n", false, true)
    assert.is_table(map)
    assert.is_function(map.callback)
    map.callback()
  end

  after_each(function()
    if history then
      pcall(history.close)
    end
    if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
      pcall(vim.api.nvim_win_close, D.dataset_window, true)
    end
    if D.dataset_buffer and vim.api.nvim_buf_is_valid(D.dataset_buffer) then
      pcall(vim.api.nvim_buf_delete, D.dataset_buffer, { force = true })
    end
    D.dataset_window = nil
    D.dataset_buffer = nil
    D.history = {}
    D.active_history = 0
    D.tabs = {}
    D.active_tab_idx = 0
  end)

  it("<CR> activates the entry under the cursor (newest-first display)", function()
    make_env()
    local e1 = add_entry("get users")
    local e2 = add_entry("orders_1")
    history.open()
    -- newest entry is on top: line 1 = orders_1 (entry 2)
    vim.api.nvim_win_set_cursor(history.win(), { 1, 0 })
    invoke_map("<CR>")
    assert.equals(2, D.active_history)
    assert.same(e2, D.active_entry())
    -- <CR> closes the sidebar after activating; reopen before the next pick
    history.open()
    vim.api.nvim_win_set_cursor(history.win(), { 2, 0 })
    invoke_map("<CR>")
    assert.equals(1, D.active_history)
    assert.same(e1, D.active_entry())
  end)

  it("d deletes the entry under the cursor and fixes the active pointer", function()
    make_env()
    local e1 = add_entry("get users")
    add_entry("orders_1")
    history.open()
    -- delete the newest (top) entry via `d`
    vim.api.nvim_win_set_cursor(history.win(), { 1, 0 })
    invoke_map("d")
    assert.equals(1, D.history_count())
    assert.equals(1, D.active_history)
    assert.same(e1, D.active_entry())
    -- delete the remaining entry
    vim.api.nvim_win_set_cursor(history.win(), { 1, 0 })
    invoke_map("d")
    assert.equals(0, D.history_count())
    assert.equals(0, D.active_history)
  end)

  it("j/k move the selection within history bounds", function()
    make_env()
    add_entry("one")
    add_entry("two")
    history.open()
    vim.api.nvim_win_set_cursor(history.win(), { 1, 0 })
    invoke_map("j")
    assert.equals(2, vim.api.nvim_win_get_cursor(history.win())[1])
    invoke_map("k")
    assert.equals(1, vim.api.nvim_win_get_cursor(history.win())[1])
    -- bounds: j beyond last stays at last, k beyond first stays at first
    invoke_map("k")
    assert.equals(1, vim.api.nvim_win_get_cursor(history.win())[1])
  end)

  it("q closes the sidebar", function()
    make_env()
    add_entry("one")
    history.open()
    assert.is_true(history.is_open())
    invoke_map("q")
    assert.is_false(history.is_open())
  end)

  it("sidebar uses a square border and a History title", function()
    make_env()
    add_entry("one")
    history.open()
    local cfg = vim.api.nvim_win_get_config(history.win())
    assert.same("┌", cfg.border[1])
    assert.same("└", cfg.border[7])
    local title = cfg.title
    if type(title) == "table" then title = table.concat(vim.tbl_flatten(title)) end
    assert.equals("History", title)
    assert.same("left", cfg.title_pos)
  end)

  it("sidebar survives clear_panel and header.close floating-window sweeps", function()
    make_env()
    add_entry("one")
    history.open()
    assert.is_true(history.is_open())
    buffer_mod.clear_panel(1)
    assert.is_true(history.is_open())
    require("poste-db.buffer.header").close()
    assert.is_true(history.is_open())
  end)
end)
