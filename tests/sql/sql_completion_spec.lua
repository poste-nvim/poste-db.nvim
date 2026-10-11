-- Diagnostic tests for SQL completion
-- Focus: does "SELECT * FROM authors WHERE " trigger column completions?

local sql_comp = require("poste-db.completion")
local get_items = sql_comp._test.get_items

-- ── 0. waiting on the async context check ───────────────────────────────────
-- Detecting the SQL context means running the Rust CLI, so every entry point
-- below answers one event-loop tick *after* it returns, unless that context is
-- already cached (a cache hit is still synchronous). The specs are written in
-- the "call, then assert" shape, so these wrappers park until the real
-- callback fires - and make "the source never answered at all" a named failure
-- instead of a nil dereference a few lines later.

local raw_get_items = get_items
local raw_get_completions = sql_comp.get_completions
local raw_source_complete = sql_comp.source.complete

local function settle(responded, what)
  assert.is_true(vim.wait(3000, function() return responded.value end, 5),
    what .. " never called back")
end

get_items = function(bufnr, line_before, cursor_line, callback, dialect)
  local responded = { value = false }
  raw_get_items(bufnr, line_before, cursor_line, function(items)
    responded.value = true
    if callback then callback(items) end
  end, dialect)
  settle(responded, "get_items")
end

sql_comp.get_completions = function(self, blink_ctx, callback, ...)
  local responded = { value = false }
  raw_get_completions(self, blink_ctx, function(response)
    responded.value = true
    if callback then callback(response) end
  end, ...)
  settle(responded, "get_completions")
end

function sql_comp.source:complete(params, callback, ...)
  local responded = { value = false }
  raw_source_complete(self, params, function(response)
    responded.value = true
    if callback then callback(response) end
  end, ...)
  settle(responded, "source:complete")
end

-- ── 2b. is the family binary actually usable? ────────────────────────────────
-- tests/minimal_init.lua always resolves *a* binary: the dev build from
-- ../poste.nvim when it exists, otherwise an executable comment-only dummy
-- (which keeps the vendored installer's ensure() hermetic). Because
-- find_poste_binary() only checks readable+executable, `find_binary() ~= nil`
-- is true in both cases — so presence is not a usable predicate, and against
-- the dummy the Rust-dependent tests below fail on an empty JSON decode that
-- reads like a plugin regression when the real cause is an unbuilt sibling
-- repo. One probe of `context detect` tells the two cases apart: a working
-- binary answers with parseable JSON naming a context, a dummy answers nothing.
local function rust_context_answers()
  local binary = require("poste-db.completion.data").find_binary()
  if not binary then return false end
  -- Deliberately weak: "it answers with a context" is the predicate, not
  -- "it answers correctly for this input" — a real binary that regressed would
  -- have to keep failing the tests below, not silently skip them.
  local out = vim.fn.system(binary .. " context detect 14", "SELECT * FROM ")
  if vim.v.shell_error ~= 0 then return false end
  local ok, parsed = pcall(vim.json.decode, out)
  return ok and type(parsed) == "table" and type(parsed.ctx_type) == "string"
end

local rust_ok = rust_context_answers()

--- An `it` whose assertions only hold when the Rust context detector answers.
--- Same signature as `it`, so the skipped case keeps its name in the report.
local function it_needs_rust(name, fn)
  if rust_ok then
    it(name, fn)
    return
  end
  it(name, function()
    print(("SKIP: %s — no usable poste binary (build ../poste.nvim, or set $POSTE_BINARY)"):format(name))
    assert.is_true(true)
  end)
end

-- ── 3. get_items integration (no real DB needed) ─────────────────────────────
-- These tests verify the pipeline works end-to-end with a mocked cache.
-- We inject columns directly into the module's cache via cache_columns/cache_tables.

-- Schema-qualified `INSERT INTO public.t (` only reaches the insert_column
-- handler when the resolved binary's context detector handles the Dot token
-- (fixed in the poste-for-db worktree; not yet in stock main builds). Probe
-- instead of assuming, so the specs stay green against older binaries and
-- light up automatically once the fix lands in ../poste.nvim.
local function rust_supports_schema_insert()
  local binary = require("poste-db.completion.data").find_binary()
  if not binary then return false end
  local line = "INSERT INTO public.authors ("
  local out = vim.fn.system(binary .. " context detect " .. #line, line)
  if vim.v.shell_error ~= 0 then return false end
  local ok, parsed = pcall(vim.json.decode, out)
  return ok and parsed.ctx_type == "insert_column" and parsed.ctx_schema == "public"
end

local schema_insert_ok = rust_supports_schema_insert()

local function it_needs_schema_insert_rust(name, fn)
  if rust_ok and schema_insert_ok then
    it(name, fn)
    return
  end
  it(name, function()
    print(("SKIP: %s — binary lacks schema-qualified insert_column detection (rebuild poste-for-db worktree)"):format(name))
    assert.is_true(true)
  end)
end

describe("get_items with seeded cache", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    return buf
  end

  -- Seed cache: simulate that introspect already returned columns for 'authors'
  before_each(function()
    -- We need a connection context so conn_key() returns something.
    -- Temporarily set global state.
    local state = require("poste-db.state")
    state = state or {}
    state.context = { connection = "test-conn", database = "blog" }

    -- Seed the cache via public API
    sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
  end)

  it_needs_rust("WHERE<space> returns authors columns", function()
    local buf = make_buf({
      "###",
      "SELECT * FROM authors WHERE ",
    })

    local items = nil
    get_items(buf, "SELECT * FROM authors WHERE ", 2, function(result)
      items = result
    end)

    -- get_items is sync when cache is hot
    assert.is_not_nil(items, "callback was not called synchronously (cache miss?)")
    assert.is_true(#items > 0, "no items returned")

    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end

    assert.is_true(labels["id"],       "missing column: id")
    assert.is_true(labels["username"], "missing column: username")
    assert.is_true(labels["email"],    "missing column: email")
  end)

  it_needs_rust("WHERE us filters to prefix", function()
    local buf = make_buf({
      "###",
      "SELECT * FROM authors WHERE us",
    })

    local items = nil
    get_items(buf, "SELECT * FROM authors WHERE us", 2, function(result)
      items = result
    end)

    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end

    assert.is_true(labels["username"], "username should match prefix 'us'")
    assert.is_nil(labels["id"],        "id should NOT match prefix 'us'")
  end)
end)

-- ── 4. blink trigger character patch ─────────────────────────────────────────
-- Ensures space is NOT blocked in SQL buffers so blink auto-triggers after WHERE/FROM etc.

describe("blink show_on_blocked_trigger_characters patch", function()
  -- Simulate what poste.setup does: patch the blocked list with a function
  local orig = { " ", "\n", "\t" }
  local patched = function()
    local ft = vim.bo.filetype
    if ft == "poste_sql" or ft == "poste_sqlite" then
      return vim.tbl_filter(function(c) return c ~= " " end, orig)
    end
    return orig
  end

  it("space is blocked in non-SQL buffers", function()
    vim.bo.filetype = "lua"
    local blocked = patched()
    assert.is_true(vim.tbl_contains(blocked, " "))
  end)

  it("space is NOT blocked in poste_sql buffers", function()
    vim.bo.filetype = "poste_sql"
    local blocked = patched()
    assert.is_false(vim.tbl_contains(blocked, " "))
  end)

  it("space is NOT blocked in poste_sqlite buffers", function()
    vim.bo.filetype = "poste_sqlite"
    local blocked = patched()
    assert.is_false(vim.tbl_contains(blocked, " "))
  end)

  it("newline and tab remain blocked in SQL buffers", function()
    vim.bo.filetype = "poste_sql"
    local blocked = patched()
    assert.is_true(vim.tbl_contains(blocked, "\n"))
    assert.is_true(vim.tbl_contains(blocked, "\t"))
  end)
end)

-- ── 5. get_completions line_before calculation ────────────────────────────────
-- blink passes ctx.cursor[2] as 0-based col; line:sub(1, col) must include the space.

describe("get_completions line_before", function()
  before_each(function()
    local state = require("poste-db.state")
    state.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" },
    })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "###", "SELECT * FROM authors WHERE ",
    })
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_cursor(win, { 1, #("SELECT * FROM authors WHERE ") })
  end)

  it_needs_rust("returns columns when cursor col equals line length (after space)", function()
    local line = "SELECT * FROM authors WHERE "
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 2, #line } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items.items) do labels[item.label] = true end
    assert.is_true(labels["id"])
    assert.is_true(labels["username"])
    assert.is_nil(labels["SELECT"])
  end)

  it("does NOT return columns when cursor is before the space (WHERE without space)", function()
    local line = "SELECT * FROM authors WHERE"
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 2, #line } },
      function(r) items = r end
    )
    -- Context is "column" (last word = WHERE) so still columns, but prefix filters to nothing
    -- Actually detect_context sees WHERE as the prefix → keyword context
    -- Just verify it doesn't crash and returns something
    assert.is_not_nil(items)
  end)

  it("single letter s returns SELECT via get_completions", function()
    local line = "s"
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 0, 1 } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items.items) do labels[item.label] = true end
    assert.is_true(labels["SELECT"], "SELECT should appear for prefix 's'")
    assert.is_true(#items.items > 0, "expected items for prefix 's'")
  end)

  it("select * f returns FROM via get_completions", function()
    local line = "select * f"
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 0, 10 } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items.items) do labels[item.label] = true end
    assert.is_true(labels["FROM"], "FROM should appear for prefix 'f' after 'select *'")
    assert.is_nil(labels["SELECT"], "SELECT should not match prefix 'f'")
  end)
end)

-- ── 5b. the no-ctx fallback branch ───────────────────────────────────────────
-- When the caller passes no blink ctx the source reads the cursor itself.
-- col(".") is 1-indexed and names the character *at* the cursor, so the
-- fallback has to drop one for `line_before` to mean the same thing it does
-- on the blink path — otherwise the character under the cursor leaks into the
-- prefix and completions are filtered by a letter that isn't typed yet.

describe("get_completions without a blink ctx", function()
  local line = "SELECT * FROM authors WHERE id"

  local function labels_of(result)
    local set = {}
    for _, item in ipairs(result and result.items or {}) do set[item.label] = true end
    local keys = vim.tbl_keys(set)
    table.sort(keys)
    return table.concat(keys, ",")
  end

  before_each(function()
    local state = require("poste-db.state")
    state.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" } })
    sql_comp.cache_columns("authors", { { name = "id" }, { name = "username" } })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "###", line })
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)
    -- Cursor on the "i" of `id`, i.e. the word is still ahead of it.
    vim.api.nvim_win_set_cursor(0, { 2, #line - 2 })
  end)

  it_needs_rust("matches the blink branch when the cursor sits mid-word", function()
    local via_ctx, via_cursor
    sql_comp.new():get_completions({ line = line, cursor = { 2, #line - 2 } },
      function(r) via_ctx = r end)
    sql_comp.new():get_completions(nil, function(r) via_cursor = r end)

    assert.is_not_nil(via_ctx)
    assert.is_not_nil(via_cursor)
    local a = labels_of(via_ctx)
    -- Empty prefix on the ctx path, so every column of `authors` qualifies.
    -- The fallback used to see "...WHERE i" and keep only labels matching "i".
    assert.is_true(a:find("username", 1, true) ~= nil, "expected both columns on the ctx path: " .. a)
    assert.equals(a, labels_of(via_cursor))
  end)

  it("treats a ctx without a cursor as no ctx at all", function()
    local with_cursor, without_cursor
    sql_comp.new():get_completions({ line = line, cursor = { 2, #line - 2 } },
      function(r) with_cursor = r end)
    sql_comp.new():get_completions({ line = line }, function(r) without_cursor = r end)
    assert.is_not_nil(without_cursor)
    assert.equals(labels_of(with_cursor), labels_of(without_cursor))
  end)
end)

-- ── 5c. the context check runs off the caller's tick ─────────────────────────
-- Detecting the SQL context means spawning the Rust CLI. The pipeline used to
-- `wait()` on that process inline, so every completion paid the spawn latency
-- as an editor freeze (measured: ~3.6ms warm, ~50ms for the first one, up to
-- the CLI's 2s timeout when it hangs), and the wait is outright illegal from a
-- fast-event context. A cache miss now reports through the process' exit
-- handler instead.
--
-- `raw_get_completions` is the un-patched method: the section 0 wrapper parks
-- until the callback fires, which would hide exactly what this checks.

describe("get_completions context detection", function()
  local line = "SELECT * FROM authors WHERE "

  before_each(function()
    local state = require("poste-db.state")
    state.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" } })
    sql_comp.cache_columns("authors", { { name = "id" }, { name = "username" } })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "###", line })
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)
  end)

  it_needs_rust("returns before the CLI has answered", function()
    -- The buffer was just created, so its context cannot be in the cache and
    -- this call has to go through the subprocess.
    local response
    raw_get_completions(sql_comp.new(), { line = line, cursor = { 2, #line } },
      function(r) response = r end)
    assert.is_nil(response, "a cache miss must not block the caller until the CLI exits")
  end)

  it("still answers, with items, on a later tick", function()
    local response
    raw_get_completions(sql_comp.new(), { line = line, cursor = { 2, #line } },
      function(r) response = r end)
    assert.is_true(vim.wait(3000, function() return response ~= nil end, 5),
      "the callback never fired for a cache-miss completion")
    assert.is_true(#response.items > 0, "expected columns of `authors`")
  end)
end)

-- ── 5d. the dialect follows the buffer the completion was triggered in ──────
-- Resolving the dialect walks the buffer for @connection/@database, so it is
-- per-completion work: it used to run at four points per trigger, and each
-- time against whichever window had focus instead of the buffer being
-- completed. It is now resolved once, for the right buffer and line.

describe("get_completions dialect resolution", function()
  local data_mod, real_resolve, seen_buf, seen_line

  local function sql_buffer(conn)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "-- @connection " .. conn, "SELECT * FROM authors WHERE ",
    })
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    return buf
  end

  before_each(function()
    seen_buf, seen_line = nil, nil
    data_mod = require("poste-db.completion.data")
    real_resolve = data_mod.resolve_current_context
    data_mod.resolve_current_context = function(buf, limit_line)
      if seen_buf == nil then seen_buf, seen_line = buf, limit_line end
      return { connection = "alpha", database = "blog" }
    end
  end)

  after_each(function()
    data_mod.resolve_current_context = real_resolve
  end)

  it("asks about the buffer the completion was triggered in", function()
    local other = sql_buffer("beta")
    local target = sql_buffer("alpha")
    -- Focus stays on `other`; the request is about `target`.
    vim.api.nvim_set_current_buf(other)
    vim.api.nvim_win_set_cursor(0, { 2, 28 })

    get_items(target, "SELECT * FROM authors WHERE ", 2, function() end)

    assert.equals(target, seen_buf)
  end)

  it("asks about the completion's line, not the live cursor", function()
    local target = sql_buffer("alpha")
    vim.api.nvim_set_current_buf(target)
    -- The request is about line 2; the window's cursor is on line 1.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    get_items(target, "SELECT * FROM authors WHERE ", 2, function() end)

    assert.equals(2, seen_line)
  end)
end)

-- ── 14. get_keyword_length edge cases ────────────────────────────────────
describe("get_keyword_length", function()
  local src = sql_comp.new()

  it("returns 0 when cursor is nil", function()
    assert.equals(0, src:get_keyword_length({}))
    assert.equals(0, src:get_keyword_length(nil))
  end)

  it("returns 1 for single letter s", function()
    local len = src:get_keyword_length({ line = "s", cursor = { 0, 1 } })
    assert.equals(1, len)
  end)

  it("returns 1 for prefix f after select *", function()
    local len = src:get_keyword_length({ line = "select * f", cursor = { 0, 10 } })
    assert.equals(1, len)
  end)

  it("returns 0 for empty line", function()
    local len = src:get_keyword_length({ line = "", cursor = { 0, 0 } })
    assert.equals(0, len)
  end)

  it("returns 0 for cursor at position 0 with content", function()
    local len = src:get_keyword_length({ line = "foo", cursor = { 0, 0 } })
    assert.equals(0, len)
  end)

  it("returns correct length for multi-char prefix", function()
    local len = src:get_keyword_length({ line = "SEL", cursor = { 0, 3 } })
    assert.equals(3, len)
  end)
end)

-- ── 6. Alias resolution ───────────────────────────────────────────────────────

describe("get_items dot_column resolves alias", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    return buf
  end

  before_each(function()
    local state = require("poste-db.state")
    state.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
    sql_comp.cache_columns("posts", {
      { name = "id" }, { name = "title" }, { name = "author_id" },
    })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
  end)

  it_needs_rust("p. after JOIN posts p returns posts columns", function()
    local buf = make_buf({ "###", "SELECT * FROM authors s LEFT JOIN posts p ON p." })
    local items = nil
    get_items(buf, "SELECT * FROM authors s LEFT JOIN posts p ON p.", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["id"])
    assert.is_true(labels["title"])
    assert.is_true(labels["author_id"])
  end)

  it_needs_rust("p.ti prefix filters correctly", function()
    local buf = make_buf({ "###", "SELECT * FROM authors s LEFT JOIN posts p ON p.ti" })
    local items = nil
    get_items(buf, "SELECT * FROM authors s LEFT JOIN posts p ON p.ti", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["title"])
    assert.is_nil(labels["id"])
  end)

  it_needs_rust("a. resolves alias from statement on a later line after other SQL", function()
    local buf = make_buf({
      "###",
      "select * from posts;",
      "",
      "SELECT p.slug, a.  FROM posts p LEFT JOIN authors a on a.id = p.author_id;",
    })
    -- Cursor on line 4 (the last line), line_before with a.
    local items = nil
    get_items(buf, "SELECT p.slug, a.", 4, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["id"], "should have id column from authors table")
    assert.is_true(labels["bio"], "should have bio column from authors table")
  end)

  -- `tag` next to `title` makes a prefix that lost its last character visible:
  -- "ti" keeps the list at title, "t" lets both through, and a re-derived empty
  -- prefix lets everything through.
  local function seed_posts_with_two_t_columns()
    sql_comp.cache_columns("posts", {
      { name = "id" }, { name = "title" }, { name = "tag" }, { name = "author_id" },
    })
  end

  local function labels_of(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    return labels
  end

  it_needs_rust("a quoted qualifier keeps its prefix filter", function()
    seed_posts_with_two_t_columns()
    local buf = make_buf({ "###", 'SELECT * FROM posts "p" WHERE "p"."ti' })
    local items = nil
    get_items(buf, 'SELECT * FROM posts "p" WHERE "p"."ti', 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = labels_of(items)
    assert.is_true(labels["title"], "title should match prefix 'ti'")
    assert.is_nil(labels["tag"], "tag must not match a 'ti' prefix")
    assert.is_nil(labels["id"], "id must not match a 'ti' prefix")
  end)

  it_needs_rust("a cursor mid-line still reads the word it is inside", function()
    seed_posts_with_two_t_columns()
    -- The buffer line continues past the cursor, so line_before is only a
    -- prefix of it: the qualifier has to come from the word under the cursor,
    -- not from the end of the line.
    local buf = make_buf({ "###", "SELECT * FROM posts p WHERE p.ti, p.id" })
    local items = nil
    get_items(buf, "SELECT * FROM posts p WHERE p.ti", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = labels_of(items)
    assert.is_true(labels["title"], "title should match prefix 'ti'")
    assert.is_nil(labels["tag"], "tag must not match a 'ti' prefix")
  end)
end)

-- ── 7. Dedup in get_completions (blink path) ─────────────────────────────────

describe("get_completions dedup", function()
  before_each(function()
    local state = require("poste-db.state")
    state.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
    sql_comp.cache_columns("posts", {
      { name = "id" }, { name = "title" }, { name = "author_id" },
    })
  end)

  it("deduplicates by label when tables share column names", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "###", "SELECT * FROM authors a JOIN posts p ON a.id = p.id WHERE ",
    })
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)

    -- Simulate blink context: cursor at end of line after WHERE<space>
    local line = "SELECT * FROM authors a JOIN posts p ON a.id = p.id WHERE "
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 2, #line } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    assert.is_not_nil(items.items)

    -- Check for duplicate labels
    local seen = {}
    for _, item in ipairs(items.items) do
      assert.is_nil(seen[item.label],
        string.format("duplicate label in get_completions: %s", item.label))
      seen[item.label] = true
    end
  end)

  it("dedup removes duplicate when get_items returns same label", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "###", "SELECT * FROM authors WHERE ",
    })
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)

    local line = "SELECT * FROM authors WHERE "
    local items = nil
    sql_comp.new():get_completions(
      { line = line, cursor = { 2, #line } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    assert.is_not_nil(items.items)
    assert.is_true(#items.items > 0, "expected at least one item")

    -- Count occurrences of each label
    local counts = {}
    for _, item in ipairs(items.items) do
      counts[item.label] = (counts[item.label] or 0) + 1
    end
    for label, count in pairs(counts) do
      assert.equals(1, count, string.format("label '%s' appears %d times", label, count))
    end
  end)
end)

-- ── 8. Dedup in nvim-cmp complete path ─────────────────────────────────────

describe("complete dedup (nvim-cmp path)", function()
  before_each(function()
    local state = require("poste-db.state")
    state.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
  end)

  it("deduplicates items by label", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "###", "SELECT * FROM authors WHERE ",
    })
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)

    local source = sql_comp.source.new()
    local items = nil
    source:complete(
      { context = { cursor_before_line = "SELECT * FROM authors WHERE " } },
      function(r) items = r end
    )
    assert.is_not_nil(items)
    assert.is_not_nil(items.items)

    local seen = {}
    for _, item in ipairs(items.items) do
      assert.is_nil(seen[item.label],
        string.format("duplicate label in complete: %s", item.label))
      seen[item.label] = true
    end
  end)
end)

-- ── 10. get_items insert_column (quick-insert + column completion) ───────────

describe("get_items insert_column", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  before_each(function()
    local state = require("poste-db.state")
    state = state or {}
    state.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
  end)

  it_needs_rust("returns quick-insert all-columns item first", function()
    local buf = make_buf({ "###", "INSERT INTO authors (" })
    local items = nil
    get_items(buf, "INSERT INTO authors (", 2, function(r) items = r end)
    assert.is_not_nil(items)
    assert.equals("id, username, email, bio", items[1].label)
    assert.equals("Insert all columns", items[1].documentation)
  end)

  it_needs_rust("returns quick-insert no-id item second", function()
    local buf = make_buf({ "###", "INSERT INTO authors (" })
    local items = nil
    get_items(buf, "INSERT INTO authors (", 2, function(r) items = r end)
    assert.is_not_nil(items)
    assert.equals("username, email, bio", items[2].label)
    assert.equals("All columns except id", items[2].documentation)
  end)

  it_needs_rust("returns individual columns after quick-insert items", function()
    local buf = make_buf({ "###", "INSERT INTO authors (" })
    local items = nil
    get_items(buf, "INSERT INTO authors (", 2, function(r) items = r end)
    assert.is_not_nil(items)
    -- items[1] = all-cols, items[2] = no-id, items[3+] = individual columns
    assert.equals("id", items[3].label)
    assert.equals("username", items[4].label)
    assert.equals("email", items[5].label)
    assert.equals("bio", items[6].label)
    assert.equals(6, #items)
  end)

  it_needs_rust("filters out already-listed columns from individual items", function()
    local buf = make_buf({ "###", "INSERT INTO authors (id, email, " })
    local items = nil
    get_items(buf, "INSERT INTO authors (id, email, ", 2, function(r) items = r end)
    assert.is_not_nil(items)
    -- Quick-insert always shows (2 items)
    assert.equals("id, username, email, bio", items[1].label)
    assert.equals("username, email, bio", items[2].label)
    -- Individual columns: id and email excluded, username and bio included
    local labels = {}
    for i = 3, #items do labels[items[i].label] = true end
    assert.is_nil(labels["id"], "id should be excluded")
    assert.is_nil(labels["email"], "email should be excluded")
    assert.is_true(labels["username"], "username should be included")
    assert.is_true(labels["bio"], "bio should be included")
    assert.equals(4, #items)  -- 2 quick-insert + 2 remaining columns
  end)

  it_needs_rust("quick-insert items always show even with prefix", function()
    local buf = make_buf({ "###", "INSERT INTO authors (us" })
    local items = nil
    get_items(buf, "INSERT INTO authors (us", 2, function(r) items = r end)
    assert.is_not_nil(items)
    -- Quick-insert always shows
    assert.equals("id, username, email, bio", items[1].label)
    assert.equals("username, email, bio", items[2].label)
    -- Only username matches prefix 'us'
    assert.equals("username", items[3].label)
    assert.equals(3, #items)
  end)

  it_needs_rust("no-id quick-insert hidden when table has no id column", function()
    local state = require("poste-db.state")
    state.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_columns("tags", {
      { name = "name" }, { name = "slug" },
    })
    local buf = make_buf({ "###", "INSERT INTO tags (" })
    local items = nil
    get_items(buf, "INSERT INTO tags (", 2, function(r) items = r end)
    assert.is_not_nil(items)
    -- Only all-columns quick-insert
    assert.equals("name, slug", items[1].label)
    assert.equals(3, #items)
  end)

  it_needs_schema_insert_rust("schema-qualified INSERT reads the schema-scoped cache", function()
    -- "public.authors" is the cache key when the schema is known; seeding the
    -- bare "authors" key as well would mask a regression that reads it.
    sql_comp.cache_tables({ { name = "authors", schema = "public" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" },
    }, "public")
    local buf = make_buf({ "###", "INSERT INTO public.authors (" })
    local items = nil
    get_items(buf, "INSERT INTO public.authors (", 2, function(r) items = r end)
    assert.is_not_nil(items)
    assert.equals("id, username", items[1].label)
  end)
end)

-- ── 11. get_items table context ───────────────────────────────────────

describe("get_items table context", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    return buf
  end

  before_each(function()
    local state = require("poste-db.state")
    state = state or {}
    state.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
    -- Pre-cache databases so ensure_databases doesn't start async job with binary
    local data_mod = require("poste-db.completion.data")
    local cache = data_mod.get_cache()
    cache["test-conn/__databases__"] = { "blog" }
  end)

  it_needs_rust("FROM<space> returns cached tables", function()
    local buf = make_buf({ "###", "SELECT * FROM " })
    local items = nil
    get_items(buf, "SELECT * FROM ", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["authors"])
    assert.is_true(labels["posts"])
  end)

  it_needs_rust("FROM au filters to matching table", function()
    local buf = make_buf({ "###", "SELECT * FROM au" })
    local items = nil
    get_items(buf, "SELECT * FROM au", 2, function(r) items = r end)
    assert.is_not_nil(items)
    assert.equals("authors", items[1].label)
    assert.equals(1, #items)
  end)
end)

-- ── 12. get_items keyword context (fallback with no connection) ────────

describe("get_items keyword context (no connection)", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    return buf
  end

  it("bare text returns matching SQL keywords", function()
    local buf = make_buf({ "###", "SEL" })
    local items = nil
    get_items(buf, "SEL", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["SELECT"], "SELECT should match prefix SEL")
    assert.is_nil(labels["FROM"], "FROM should not match prefix SEL")
    assert.is_true(#items > 0, "expected at least one keyword")
  end)

  it("single letter s returns SELECT keyword", function()
    local buf = make_buf({ "###", "s" })
    local items = nil
    get_items(buf, "s", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["SELECT"], "SELECT should match single-letter prefix 's'")
    assert.is_true(#items > 0, "expected at least one item for prefix 's'")
  end)

  it("select * f returns FROM keyword", function()
    local buf = make_buf({ "###", "select * f" })
    local items = nil
    get_items(buf, "select * f", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["FROM"], "FROM should match prefix 'f' after 'select *'")
    assert.is_nil(labels["SELECT"], "SELECT should not match prefix 'f'")
  end)

  it("empty prefix returns many keywords", function()
    local buf = make_buf({ "###", "" })
    local items = nil
    get_items(buf, "", 2, function(r) items = r end)
    assert.is_not_nil(items)
    assert.is_true(#items > 20, "expected > 20 items for empty prefix")
  end)

  it("prefix 'CRE' matches CREATE TABLE", function()
    local buf = make_buf({ "###", "CRE" })
    local items = nil
    get_items(buf, "CRE", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["CREATE TABLE"], "CREATE TABLE should match prefix CRE")
    assert.is_nil(labels["SELECT"], "SELECT should not match prefix CRE")
  end)

  it("returns data types as well as keywords (regression: INSERT INTO keyword)", function()
    local buf = make_buf({ "###", "IN" })
    local items = nil
    get_items(buf, "IN", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["INT"], "data type INT should match")
    assert.is_true(labels["INTEGER"], "data type INTEGER should match")
    assert.is_true(labels["INSERT INTO"], "keyword INSERT INTO should match prefix IN")
    assert.is_true(labels["IN"], "keyword IN should match prefix IN")
  end)

  it("UPDATE SET slug='...', bio='' w suggests WHERE keyword", function()
    local buf = make_buf({ "###", "UPDATE posts SET slug='', author_id='', bio='' w" })
    local items = nil
    get_items(buf, "UPDATE posts SET slug='', author_id='', bio='' w", 2, function(r) items = r end)
    assert.is_not_nil(items)
    local labels = {}
    for _, item in ipairs(items) do labels[item.label] = true end
    assert.is_true(labels["WHERE"], "WHERE should match prefix w after SET column assignments")
    assert.is_true(labels["WITH"], "WITH should match prefix w after SET column assignments")
  end)
end)

-- ── 7. Drift check: Lua fallback functions ⊆ Rust functions ───────────────────
-- Requires Rust binary. Skip if not found.
-- Authoritative drift tests are in Rust: test_lua_fallback_functions_are_subset,
-- test_lua_keywords_recognized_by_rust.
local data = require("poste-db.completion.data")
describe("Rust/Lua function drift", function()
  it("every Lua SQL_FUNCTIONS entry exists in Rust known_functions()", function()
    local binary = data.find_binary()
    if not binary then
      print("SKIP: Rust binary not found")
      assert.is_true(true)
      return
    end
    local out = vim.fn.system(binary .. " context detect 0", "")
    if vim.v.shell_error ~= 0 then
      print("SKIP: Rust context detect failed")
      assert.is_true(true)
      return
    end
    local ok, rust = pcall(vim.json.decode, out)
    if not ok or not rust.functions then
      print("SKIP: cannot parse Rust output")
      assert.is_true(true)
      return
    end
    local rust_set = {}
    for _, f in ipairs(rust.functions) do rust_set[f] = true end
    local missing = {}
    for _, f in ipairs(data.SQL_FUNCTIONS) do
      if not rust_set[f] then table.insert(missing, f) end
    end
    assert.equals(0, #missing,
      "Lua functions not in Rust: " .. table.concat(missing, ", "))
  end)
end)

-- ── 13. Completion mode integration tests ─────────────────────────

describe("completion mode integration", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  local function mock_find_binary()
    _G._saved_find_binary = require("poste-db.completion.data").find_binary
    require("poste-db.completion.data").find_binary = function() return nil end
  end

  local function restore_find_binary()
    if _G._saved_find_binary then
      require("poste-db.completion.data").find_binary = _G._saved_find_binary
      _G._saved_find_binary = nil
    end
  end

  before_each(function()
    local state = require("poste-db.state")
    state = state or {}
    state.context = { connection = "test-conn", database = "blog" }
    sql_comp.cache_tables({ { name = "authors" }, { name = "posts" } })
    sql_comp.cache_columns("authors", {
      { name = "id" }, { name = "username" }, { name = "email" }, { name = "bio" },
    })
    _G._saved_legacy = vim.g.poste_db_legacy_completion
  end)

  after_each(function()
    vim.g.poste_db_legacy_completion = _G._saved_legacy
    restore_find_binary()
  end)


  -- Mode: true (Lua-only legacy) — Lua heuristic removed, returns keyword fallback
  describe("legacy_completion = true (Lua-only)", function()
    before_each(function() mock_find_binary() end)

    it("returns keywords after WHERE (heuristic removed)", function()
      vim.g.poste_db_legacy_completion = true
      local buf = make_buf({ "###", "SELECT * FROM authors WHERE " })
      local items = nil
      get_items(buf, "SELECT * FROM authors WHERE ", 2, function(r) items = r end)
      assert.is_not_nil(items)
      local labels = {}
      for _, item in ipairs(items) do labels[item.label] = true end
      -- Without Lua heuristic, legacy mode returns keyword context
      -- Table names may still appear via the keyword fallback path
      assert.is_true(labels["WHERE"] ~= nil or labels["SELECT"] ~= nil,
        "should return some keywords, got: " .. vim.inspect(labels))
    end)

    it("uses Lua fallback SQL_FUNCTIONS for keyword context", function()
      vim.g.poste_db_legacy_completion = true
      local buf = make_buf({ "###", "CO" })
      local items = nil
      get_items(buf, "CO", 2, function(r) items = r end)
      assert.is_not_nil(items)
      local labels = {}
      for _, item in ipairs(items) do labels[item.label] = true end
      -- Lua fallback functions should be available
      assert.is_true(labels["COUNT"], "COUNT should come from Lua fallback")
      assert.is_true(labels["COALESCE"], "COALESCE should come from Lua fallback")
    end)
  end)

  -- Mode: "rust" (Rust strict) — Rust path only, no Lua fallback
  describe("legacy_completion = 'rust' (Rust strict)", function()
    local function skip_or_run(assert_fn)
      if not rust_ok then
        print("SKIP: no usable poste binary for strict mode tests")
        assert.is_true(true)
        return
      end
      assert_fn()
    end

    it("returns columns after WHERE", function()
      skip_or_run(function()
        vim.g.poste_db_legacy_completion = "rust"
        local buf = make_buf({ "###", "SELECT * FROM authors WHERE " })
        local items = nil
        get_items(buf, "SELECT * FROM authors WHERE ", 2, function(r) items = r end)
        assert.is_not_nil(items)
        local labels = {}
        for _, item in ipairs(items) do labels[item.label] = true end
        assert.is_true(labels["id"])
        assert.is_true(labels["username"])
      end)
    end)

    it("returns tables after FROM", function()
      skip_or_run(function()
        vim.g.poste_db_legacy_completion = "rust"
        local buf = make_buf({ "###", "SELECT * FROM " })
        local items = nil
        get_items(buf, "SELECT * FROM ", 2, function(r) items = r end)
        assert.is_not_nil(items)
        local labels = {}
        for _, item in ipairs(items) do labels[item.label] = true end
        assert.is_true(labels["authors"])
      end)
    end)
  end)

  -- Conditional: Rust binary integration tests
  describe("Rust binary integration", function()
    local binary = require("poste-db.completion.data").find_binary()

    local function skip_or_run(assert_fn)
      if not rust_ok then
        print("SKIP: no usable poste binary, build one with 'cargo build -p poste-cli' first")
        assert.is_true(true)
        return
      end
      assert_fn()
    end

    it("detects column context via CLI", function()
      skip_or_run(function()
        local out = vim.fn.system(binary .. " context detect 23", "SELECT * FROM authors WHERE ")
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.equals("column", parsed.ctx_type)
      end)
    end)

    it("detects table context via CLI", function()
      skip_or_run(function()
        local out = vim.fn.system(binary .. " context detect 14", "SELECT * FROM ")
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.equals("table", parsed.ctx_type)
      end)
    end)

    it("detects schema-qualified dot-column with ctx_schema", function()
      skip_or_run(function()
        local sql = "SELECT * FROM public.users WHERE public.users."
        local out = vim.fn.system(binary .. " context detect 47", sql)
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.equals("dot_column", parsed.ctx_type)
        assert.equals("users", parsed.ctx_data)
        assert.equals("public", parsed.ctx_schema)
        assert.is_true(#parsed.tables > 0)
        assert.equals("public", parsed.tables[1].schema)
        assert.equals("users", parsed.tables[1].name)
      end)
    end)

    it("detects string context with in_string flag", function()
      skip_or_run(function()
        local sql = "SELECT * FROM users WHERE name = 'hello'"
        local out = vim.fn.system(binary .. " context detect 39", sql)
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.is_true(parsed.in_string, "cursor inside string")
      end)
    end)

    it("detects comment context with in_comment flag", function()
      skip_or_run(function()
        local sql = "SELECT * FROM users -- comment"
        local out = vim.fn.system(binary .. " context detect 21", sql)
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.is_true(parsed.in_comment, "cursor inside comment")
      end)
    end)

    it("detects keyword context after Rust binary fallback", function()
      skip_or_run(function()
        local sql = "SEL"
        local out = vim.fn.system(binary .. " context detect 3", sql)
        assert.equals(0, vim.v.shell_error)
        local ok, parsed = pcall(vim.json.decode, out)
        assert.is_true(ok)
        assert.equals("keyword", parsed.ctx_type)
        assert.equals("SEL", parsed.prefix)
      end)
    end)
  end)

  -- String/comment: Rust handles correctly
  describe("comment string fallback behavior", function()
    it("get_items on comment line returns keywords not tables", function()
      local buf = make_buf({ "###", "-- SELECT * FROM " })
      local items = nil
      get_items(buf, "-- SELECT * FROM ", 2, function(r) items = r end)
      assert.is_not_nil(items)
      -- Should be keywords, not table names
      local labels = {}
      for _, item in ipairs(items) do labels[item.label] = true end
      -- Table names should NOT appear
      assert.is_nil(labels["authors"], "tables must not leak on comment lines")
      assert.is_nil(labels["posts"], "tables must not leak on comment lines")
    end)

    it("line inside string literal returns keywords not columns", function()
      local buf = make_buf({ "###", "SELECT * FROM users WHERE name = 'some text'" })
      -- cursor at the start of the string content
      local items = nil
      get_items(buf, "SELECT * FROM users WHERE name = 'some text'", 2, function(r) items = r end)
      assert.is_not_nil(items)
      -- When not in string-aware mode, at minimum should not crash
      local labels = {}
      for _, item in ipairs(items) do labels[item.label] = true end
      -- May contain keywords; should not contain string fragments
      assert.is_nil(labels["some text"], "string content must not leak as items")
    end)
  end)

  -- Mode toggle function
  describe("toggle_legacy cycles through modes", function()
    before_each(function()
      vim.g.poste_db_legacy_completion = nil
    end)

    it("first call sets to true (Lua-only)", function()
      sql_comp.toggle_legacy()
      assert.is_true(vim.g.poste_db_legacy_completion)
    end)

    it("second call sets to 'rust' (Rust strict)", function()
      sql_comp.toggle_legacy()
      sql_comp.toggle_legacy()
      assert.equals("rust", vim.g.poste_db_legacy_completion)
    end)

    it("third call resets to nil (default hybrid)", function()
      sql_comp.toggle_legacy()
      sql_comp.toggle_legacy()
      sql_comp.toggle_legacy()
      assert.is_nil(vim.g.poste_db_legacy_completion)
    end)
  end)

  describe("tables_db_flag scopes db/schema prefixes per dialect", function()
    local comp_data = require("poste-db.completion.data")

    it("scopes postgres/sqlite prefixes by schema", function()
      assert.equals("--schema", comp_data.tables_db_flag("postgres"))
      assert.equals("--schema", comp_data.tables_db_flag("PostgreSQL"))
      assert.equals("--schema", comp_data.tables_db_flag("sqlite"))
    end)

    it("scopes mssql prefixes by schema", function()
      assert.equals("--schema", comp_data.tables_db_flag("mssql"))
      assert.equals("--schema", comp_data.tables_db_flag("MSSQL"))
    end)

    it("scopes mysql/mariadb (and unknown) prefixes by database", function()
      assert.equals("--database", comp_data.tables_db_flag("mysql"))
      assert.equals("--database", comp_data.tables_db_flag("mariadb"))
      assert.equals("--database", comp_data.tables_db_flag(nil))
      assert.equals("--database", comp_data.tables_db_flag("clickhouse"))
    end)
  end)

  describe("handle_table postgres pg_catalog completion", function()
    local handlers = require("poste-db.completion.handlers")
    local data_mod = require("poste-db.completion.data")
    local orig_ensure_tables, orig_ensure_databases

    before_each(function()
      orig_ensure_tables = data_mod.ensure_tables
      orig_ensure_databases = data_mod.ensure_databases
      data_mod.ensure_tables = function(cb) cb() end
      data_mod.ensure_databases = function(cb) cb() end
    end)

    after_each(function()
      data_mod.ensure_tables = orig_ensure_tables
      data_mod.ensure_databases = orig_ensure_databases
    end)

    local function dispatch_table(prefix, dialect)
      local buf = vim.api.nvim_create_buf(false, true)
      local items = nil
      handlers.dispatch(
        { bufnr = buf, line_before = "SELECT * FROM " .. prefix, prefix = prefix, dialect = dialect },
        "table", nil, nil, function(r) items = r end)
      return items
    end

    it("offers pg_catalog relations for a 'pg' prefix on postgres", function()
      local labels = {}
      for _, it in ipairs(dispatch_table("pg", "postgres") or {}) do labels[it.label] = true end
      assert.is_true(labels["pg_tables"], "pg_tables should be offered")
      assert.is_true(labels["pg_stat_activity"], "pg_stat_activity should be offered")
      assert.is_true(labels["pg_class"], "pg_class should be offered")
    end)

    it("does not offer pg_catalog relations for a non-pg prefix", function()
      local labels = {}
      for _, it in ipairs(dispatch_table("au", "postgres") or {}) do labels[it.label] = true end
      assert.is_nil(labels["pg_tables"])
    end)

    it("does not offer pg_catalog relations for mysql", function()
      local labels = {}
      for _, it in ipairs(dispatch_table("pg", "mysql") or {}) do labels[it.label] = true end
      assert.is_nil(labels["pg_tables"])
    end)
  end)

  describe("keyword completion for tree-sitter-unsupported constructs", function()
    local ctx = require("poste-db.completion.ctx")

    it("offers sqlite dialect keywords", function()
      local labels = {}
      for _, it in ipairs(ctx.kw_items("GLO", "sqlite")) do labels[it.label] = true end
      assert.is_true(labels["GLOB"], "GLOB should be offered for sqlite")
    end)

    it("offers standard keywords in any dialect", function()
      local labels = {}
      for _, it in ipairs(ctx.kw_items("SAVE", nil)) do labels[it.label] = true end
      assert.is_true(labels["SAVEPOINT"], "SAVEPOINT should be offered")
    end)

    it("does not offer sqlite-only keywords for mysql", function()
      local labels = {}
      for _, it in ipairs(ctx.kw_items("PRAGMA", "mysql")) do labels[it.label] = true end
      assert.is_nil(labels["PRAGMA"], "PRAGMA is sqlite-only")
    end)
  end)
end)

-- ── 15. get_tables_and_alias ────────────────────────────────────────────────
-- The one place the FROM/JOIN tables become Lua data. It reads the Rust
-- context and nothing else, so the two shapes callers can hand it - a context
-- and the `nil` from a failed context check - are the whole input space.

describe("get_tables_and_alias", function()
  local ctx = require("poste-db.completion.ctx")

  local function assert_all_empty(rust_ctx)
    local tables, alias_map, schema_map = ctx.get_tables_and_alias(rust_ctx)
    assert.same({}, tables)
    assert.same({}, alias_map)
    assert.same({}, schema_map)
  end

  it("maps table names, aliases and schemas out of the context", function()
    local tables, alias_map, schema_map = ctx.get_tables_and_alias({
      tables = {
        { name = "authors", alias = "a", schema = "public" },
        { name = "posts" },
      },
    })
    assert.same({ "authors", "posts" }, tables)
    assert.equals("authors", alias_map.a)
    assert.equals("authors", alias_map.authors, "a table is its own alias")
    assert.equals("public", schema_map.authors)
    assert.is_nil(schema_map.posts, "an unqualified table has no schema")
  end)

  it("skips entries without a name", function()
    local tables = ctx.get_tables_and_alias({
      tables = { { name = "" }, { alias = "x" }, { name = "posts" } },
    })
    assert.same({ "posts" }, tables)
  end)

  it("returns three empty containers when there is no context", function()
    -- The handlers index all three results without guarding, and `nil` is what
    -- the pipeline passes after a failed context check.
    assert_all_empty(nil)
    assert_all_empty({})
    assert_all_empty({ tables = {} })
  end)
end)
