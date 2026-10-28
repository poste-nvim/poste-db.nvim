local statement = require("poste-db.statement")

describe("statement find_block_for_line", function()
  it("returns whole buffer when no markers exist", function()
    local buf = { "select 1", "select 2" }
    local s, e = statement._test.find_block_for_line(buf, 1)
    assert.equals(1, s)
    assert.equals(2, e)
  end)

  it("finds block boundaries for a line inside a block", function()
    local buf = { "### query", "select 1", "select 2", "### cleanup", "drop table" }
    local s, e = statement._test.find_block_for_line(buf, 2)
    assert.equals(2, s)
    assert.equals(3, e)
  end)

  it("finds block boundaries for the first line of a block", function()
    local buf = { "### query", "select 1", "### cleanup", "drop table" }
    local s, e = statement._test.find_block_for_line(buf, 2)
    assert.equals(2, s)
    assert.equals(2, e)
  end)

  it("returns nil for lines before the first block", function()
    local buf = { "-- @connection test", "### query", "select 1" }
    local s, e = statement._test.find_block_for_line(buf, 1)
    assert.equals(1, s)
    assert.equals(1, e)
  end)

  it("handles line at end of buffer", function()
    local buf = { "### query", "select 1" }
    local s, e = statement._test.find_block_for_line(buf, 2)
    assert.equals(2, s)
    assert.equals(2, e)
  end)
end)

describe("statement extract_table_name", function()
  it("returns nil for nil input", function()
    assert.is_nil(statement.extract_table_name(nil))
  end)

  it("returns nil for empty string", function()
    assert.is_nil(statement.extract_table_name(""))
  end)

  it("extracts FROM table", function()
    assert.equals("users", statement.extract_table_name("select * from users"))
  end)

  it("extracts UPDATE table", function()
    assert.equals("posts", statement.extract_table_name("update posts set title = 'foo'"))
  end)

  it("extracts INSERT INTO table", function()
    assert.equals("comments", statement.extract_table_name("insert into comments values (1)"))
  end)

  it("extracts FROM table (not JOIN target)", function()
    assert.equals("posts", statement.extract_table_name("select * from posts join authors on authors.id = posts.author_id"))
  end)

  it("returns nil for 2+ JOINs", function()
    assert.is_nil(statement.extract_table_name("select * from posts join authors on authors.id = posts.author_id join comments on comments.post_id = posts.id"))
  end)

  it("a 'join' inside a string literal does not count as a JOIN", function()
    -- two literals containing "join" used to trip join_count >= 2 and return
    -- nil, degrading the label to "result n" (09-12 carry)
    assert.equals("logs", statement.extract_table_name(
      "select * from logs where msg = 'join' and other = 'join again'"))
    -- one real JOIN plus a literal still extracts the FROM table
    assert.equals("logs", statement.extract_table_name(
      "select * from logs join t on t.id = logs.t_id where msg = 'join'"))
    -- doubled-quote escapes stay inside the literal
    assert.equals("logs", statement.extract_table_name(
      "select * from logs where msg = 'it''s a join'"))
  end)

  it("'join' inside an identifier does not count as a JOIN", function()
    -- only the character BEFORE each "JOIN" was checked, so a column list
    -- spelling JOIN inside identifiers counted two JOINs and returned nil
    assert.equals("users", statement.extract_table_name(
      "select joined_at, join_date from users"))
    -- a real JOIN plus identifier hits still extracts the FROM table
    assert.equals("users", statement.extract_table_name(
      "select joined_at from users join accounts on accounts.user_id = users.id"))
  end)

  it("strips backtick quotes", function()
    assert.equals("users", statement.extract_table_name("select * from `users`"))
  end)

  it("strips double-quote quotes", function()
    assert.equals("users", statement.extract_table_name('select * from "users"'))
  end)

  it("handles schema-qualified table names", function()
    assert.equals("users", statement.extract_table_name("select * from public.users"))
  end)

  it("strips mssql bracket quotes", function()
    assert.equals("users", statement.extract_table_name("select * from [users]"))
  end)

  it("strips mssql bracket-qualified names ([db].[table] forms)", function()
    assert.equals("users", statement.extract_table_name("select * from [dbo].[users]"))
    assert.equals("orders", statement.extract_table_name("update [sales].[orders] set x = 1"))
  end)

  it("keeps only the last part of a three-part reference", function()
    -- `db.schema.tbl` and `schema.tbl` cannot be told apart in text, so the
    -- leftovers used to be handed on as the table name: `mydb.public.users`
    -- came back as `public.users`, which ident.quote (rightly) reads as one
    -- name, and the DML targeted a table called `public.users`.
    assert.equals("users", statement.extract_table_name("select * from mydb.public.users"))
    assert.equals("Orders", statement.extract_table_name("update [sales].[Orders] set x = 1"))
  end)

  it("keeps a dot inside a quoted name as part of the name", function()
    -- a table really called `staging.v1`, not `v1` in schema `staging`
    assert.equals("staging.v1", statement.extract_table_name('select * from "staging.v1"'))
    assert.equals("staging.v1", statement.extract_table_name("select * from `staging.v1`"))
    assert.equals("staging.v1", statement.extract_table_name("select * from [staging.v1]"))
    -- the qualifier still comes off, but only up to the quote boundaries: the
    -- last part is `staging.v1` quoted as one name, so its dot stays
    assert.equals("staging.v1", statement.extract_table_name('select * from "public"."staging.v1"'))
  end)

  it("keeps the case of a quoted name, and folds an unquoted one", function()
    -- the quotes are what says "exactly this name"; without them the engines
    -- fold identifiers to lower case, and the result has to match either way
    assert.equals("Users", statement.extract_table_name('update "Users" set x = 1'))
    assert.equals("MixedCase", statement.extract_table_name('SELECT count(*) FROM "MixedCase" x'))
    assert.equals("order_items", statement.extract_table_name("select * from ORDER_ITEMS"))
  end)

  it("reads a quoted name that contains a space", function()
    -- `%S+` stopped the token at the space, so `"Order Items"` read as `order`
    -- — a name that exists and is not the one being queried.
    assert.equals("Order Items", statement.extract_table_name('select * from "Order Items"'))
    assert.equals("Order Items", statement.extract_table_name('select * from "Order Items" where a = 1'))
    assert.equals("Order Items", statement.extract_table_name("select * from [Order Items]"))
    assert.equals("my tbl", statement.extract_table_name("select * from `my tbl`"))
  end)

  it("unescapes a doubled quote inside a name", function()
    -- the name the engine stored has one quote; handing on the doubled form
    -- would make ident.quote escape it a second time
    assert.equals('a"b', statement.extract_table_name('select * from "a""b"'))
    assert.equals("a]b", statement.extract_table_name("select * from [a]]b]"))
  end)

  it("returns nil when the chain does not end in a name", function()
    assert.is_nil(statement.extract_table_name("select * from users."))
    assert.is_nil(statement.extract_table_name("select * from .hidden"))
  end)

  it("ends a bare name at a delimiter glued onto it", function()
    -- no space between the table and its column list, which is how a lot of
    -- generated INSERTs read
    assert.equals("users", statement.extract_table_name("insert into users(a,b) values (1,2)"))
    assert.equals("users", statement.extract_table_name("select * from users;"))
  end)

  it("returns nil for a comma table list", function()
    -- the 2+ JOIN guard above cannot see `FROM a, b`, and picking the first
    -- table would let the DML edit a row of the wrong one
    assert.is_nil(statement.extract_table_name("select * from users,orders"))
    assert.is_nil(statement.extract_table_name("select * from users , orders"))
    assert.is_nil(statement.extract_table_name('select * from "users", orders'))
    assert.is_nil(statement.extract_table_name("update users, orders set x = 1"))
  end)

  it("returns nil for a subquery in the table position", function()
    -- `(select` used to come back as a table name, and the DML builder quoted
    -- it into `"(select"` — a table that does not exist
    assert.is_nil(statement.extract_table_name("select * from (select 1) x"))
  end)

  it("still hands back a CTE name (recorded limitation)", function()
    -- `WITH t AS (...) SELECT * FROM t` points at a row set that exists only
    -- for this query; the extraction has no statement structure to tell that
    -- apart, so `t` comes back as the table. Pinned here so a change is a
    -- decision, not a surprise.
    assert.equals("t", statement.extract_table_name("with t as (select 1) select * from t"))
  end)

  it("keeps a non-ASCII bare name whole", function()
    -- byte-wise scanning must not mistake a UTF-8 continuation byte for a
    -- delimiter
    assert.equals("用户", statement.extract_table_name("select * from 用户 where a = 1"))
  end)

  it("lowercases the result", function()
    assert.equals("users", statement.extract_table_name("select * from USERS"))
  end)

  it("strips inline comments", function()
    assert.equals("users", statement.extract_table_name("select * from users -- comment"))
  end)

  it("strips block comments", function()
    assert.equals("users", statement.extract_table_name("select * from users /* block */"))
  end)

  it("ignores a keyword inside a literal that follows an escaped-quote literal", function()
    -- The old `'([^']|'')*'` blanker stopped its match at the *next*
    -- literal's opening quote once a '' escape had passed, leaving
    -- "note from bob" visible for the keyword scan -> "bob".
    assert.equals("users",
      statement.extract_table_name("SELECT 'it''s', 'note from bob' FROM users;"))
  end)

  it("a fake 'from' inside an UPDATE literal cannot outrank the UPDATE target", function()
    -- The keyword scan tries FROM first; the half-blanked literal supplied
    -- one, and the table became "2024".
    assert.equals("t",
      statement.extract_table_name("update t set a = 'it''s a note from 2024', b = 'x' where id = 1"))
  end)

  it("keeps comma-separated literals out of the way", function()
    assert.equals("users", statement.extract_table_name("SELECT 'a','b' FROM users;"))
    assert.equals("logs", statement.extract_table_name("insert into logs(a) values ('it''s'), ('b')"))
  end)

  it("an unterminated literal blanks the rest instead of leaking keywords", function()
    -- no closing quote anywhere: everything after the opener is string data
    -- as far as the keyword scan is concerned
    assert.equals("users", statement.extract_table_name("select * from users where note = 'it''s from bob"))
  end)

  it("a -- inside a literal no longer eats the FROM (round-50 held probe)", function()
    -- The old pipeline stripped comments BEFORE blanking literals, so the
    -- "comment" consumed `'a--b' FROM t` and the extraction returned nil.
    assert.equals("t", statement.extract_table_name("SELECT 'a--b' FROM t"))
    assert.equals("t", statement.extract_table_name("select * from t where note = 'a--b'"))
  end)

  it("a -- inside a double-quoted or backticked identifier is data", function()
    -- kept verbatim as identifiers; the old comment strip read it as a
    -- comment and the name fell to nil
    assert.equals("my--table", statement.extract_table_name('select * from "my--table"'))
    assert.equals("my--table", statement.extract_table_name("select * from `my--table`"))
  end)

  it("an apostrophe inside a comment opens no phantom literal", function()
    assert.equals("users", statement.extract_table_name("select * from users -- don't"))
    assert.equals("users", statement.extract_table_name("select 1 -- don't\nfrom users"))
  end)

  it("a DELETE inside a dollar-quoted body does not become the table", function()
    -- the function body is not the outer statement's code
    assert.equals("users", statement.extract_table_name("$$ delete from secret $$; select 1 from users"))
    assert.equals("users",
      statement.extract_table_name("$fn$ delete from secret $fn$; select * from users"))
  end)

  it("a single quote inside a kept double-quoted region opens no literal", function()
    -- the `'` sits inside a double-quoted region; the old literal blanker
    -- opened a phantom string there and blanked the rest (nil)
    assert.equals("users", statement.extract_table_name('select "it\'s" from users'))
  end)
end)

describe("statement get_stmt_sql", function()
  it("returns empty string for nil start", function()
    assert.equals("", statement.get_stmt_sql({ "a" }, { 1 }, 2))
  end)

  it("returns single line", function()
    assert.equals("select 1", statement.get_stmt_sql({ "select 1", "select 2" }, { 1 }, 1))
  end)

  it("concatenates multi-line statement", function()
    assert.equals("select 1 select 2", statement.get_stmt_sql({ "select 1", "select 2", "select 3" }, { 1, 3 }, 1))
  end)

  it("stops at next statement line", function()
    assert.equals("select 1", statement.get_stmt_sql({ "select 1", "select 2" }, { 1, 2 }, 1, 2))
  end)

  it("respects max_end parameter", function()
    assert.equals("select 1 select 2", statement.get_stmt_sql({ "select 1", "select 2", "select 3" }, { 1 }, 1, 2))
  end)

  it("without max_end, the last statement truncates to its first line", function()
    -- Pinned semantics: callers that need the full text must pass max_end
    -- (response.lua passes `visual_sel_end or stmt_end or #buf_lines`).
    assert.equals("select *",
      statement.get_stmt_sql({ "select 1;", "select *", "from users;" }, { 1, 2 }, 2))
  end)
end)
describe("statement extract_stmt_at_cursor (Lua ;-heuristic fallback)", function()
  local rust_orig

  before_each(function()
    -- Force the Lua fallback: buf=nil skips Tree-sitter; stub the Rust probe
    -- (resolved dynamically via M.try_rust_stmt_span at call time).
    rust_orig = statement.try_rust_stmt_span
    statement.try_rust_stmt_span = function() return nil end
  end)

  after_each(function()
    statement.try_rust_stmt_span = rust_orig
  end)

  it("keeps the full head of the buffer's first multi-line statement", function()
    -- Regression: stmt_start used to initialize to cursor_line, chopping off
    -- the lines above the cursor when no `;`/directive preceded them.
    local lines = { "SELECT a,", "       b", "FROM t;" }
    local content, _, stmt_start, stmt_end = statement._test.extract_stmt_at_cursor(lines, 2, nil)
    assert.is_not_nil(content)
    assert.equals(1, stmt_start)
    assert.equals(3, stmt_end)
    assert.match("SELECT a,", content)
    assert.match("FROM t;", content)
  end)

  it("starts after top-of-file directives when no `;` precedes the cursor", function()
    local lines = { "-- @connection dev", "", "SELECT a,", "FROM t;" }
    local content, _, stmt_start = statement._test.extract_stmt_at_cursor(lines, 3, nil)
    assert.equals(3, stmt_start)
    assert.match("%-%- @connection dev", content)
    assert.match("SELECT a,", content)
  end)

  it("still pins the start after a preceding semicolon", function()
    local lines = { "SELECT 1;", "SELECT x,", "       y;" }
    local _, _, stmt_start = statement._test.extract_stmt_at_cursor(lines, 3, nil)
    assert.equals(2, stmt_start)
  end)
end)

describe("statement extract_stmt_at_cursor — a cursor on a blank line between statements", function()
  -- The binary maps a blank line to the blank itself (`context stmt` on line
  -- 2 of `SELECT 1;\n\n\nSELECT 2;` answers the 0-based span (1,1)), so the
  -- forward skip to the next statement used to invert the detected span
  -- (stmt_start 4, stmt_end 2): the empty stmt_lines answered `<CR>` with
  -- "nothing to execute" for a buffer that had `SELECT 2;` below the cursor.
  local rust_orig

  before_each(function()
    rust_orig = statement.try_rust_stmt_span
    statement.try_rust_stmt_span = function(_, cursor_line)
      return { cursor_line, cursor_line }  -- the binary's degenerate blank-line span
    end
  end)

  after_each(function()
    statement.try_rust_stmt_span = rust_orig
  end)

  it("executes the next statement instead of reporting nothing", function()
    local lines = { "SELECT 1;", "", "", "SELECT 2;" }
    local content, _, stmt_start, stmt_end = statement._test.extract_stmt_at_cursor(lines, 2, nil)
    assert.is_not_nil(content, "a blank-line cursor above SELECT 2; must still extract it")
    assert.equals(4, stmt_start)
    assert.equals(4, stmt_end)
    assert.match("SELECT 2;", content)
  end)

  it("re-ends the statement past a `;` that sits inside a literal", function()
    local lines = { "SELECT 1;", "", "SELECT 'a;b' AS x;", "SELECT 2;" }
    local content, _, stmt_start, stmt_end = statement._test.extract_stmt_at_cursor(lines, 2, nil)
    assert.is_not_nil(content)
    assert.equals(3, stmt_start)
    assert.equals(3, stmt_end, "the `;` inside the literal must not bound the statement")
    assert.match("SELECT 'a;b' AS x;", content)
  end)
end)

describe("statement try_rust_stmt_span dialect threading", function()
  -- The Rust span is what "run statement under cursor" executes while
  -- exec-file splits the same buffer with the dialect's own quote-escape
  -- reading: the --dialect flag is what keeps the two statements identical
  -- for a MySQL 'it\'s'. Pinned at the CLI-args level; the reading itself is
  -- the binary's contract (find_statement_span_with in poste-core).
  -- statement.lua captured its cli reference at load time, so the stub
  -- mutates the module table (like the statusline spec) instead of swapping
  -- package.loaded.
  local cli = require("poste-db.cli")
  local orig_run_json = cli.run_json
  local seen_args

  before_each(function()
    seen_args = nil
    cli.run_json = function(args)
      seen_args = args
      return { start_line = 0, end_line = 0 }
    end
  end)

  after_each(function()
    cli.run_json = orig_run_json
  end)

  it("passes a resolvable dialect to context stmt", function()
    statement.try_rust_stmt_span({ "SELECT 'it\\'s';", "DELETE FROM t;" }, 2, "mysql")
    assert.equals("context", seen_args[1])
    assert.equals("--dialect", seen_args[4])
    assert.equals("mysql", seen_args[5])
  end)

  it("omits the flag when the dialect is unknown", function()
    statement.try_rust_stmt_span({ "SELECT 1;" }, 1, nil)
    assert.is_nil(seen_args[4])
    statement.try_rust_stmt_ranges({ "SELECT 1;" }, 1, 1, "")
    assert.equals("stmt-ranges", seen_args[2])
    assert.is_nil(seen_args[3])
  end)
end)

describe("statement extract_stmt_at_cursor — the ;-scan is region-blind", function()
  -- The Lua fallback is the only splitter left when neither Tree-sitter nor
  -- the binary answers; a `;` inside a literal/comment used to bound the
  -- statement there and the truncated text went off to execute a syntax error.
  local rust_orig

  before_each(function()
    rust_orig = statement.try_rust_stmt_span
    statement.try_rust_stmt_span = function() return nil end
  end)

  after_each(function()
    statement.try_rust_stmt_span = rust_orig
  end)

  it("a string `;` does not end the statement", function()
    local lines = { "SELECT 'a;b' AS v,", "c FROM t;" }
    local content, _, stmt_start, stmt_end = statement._test.extract_stmt_at_cursor(lines, 1, nil)
    assert.equals(1, stmt_start)
    assert.equals(2, stmt_end, "the statement runs to the real `;` on line 2")
    assert.match("FROM t;", content)
  end)

  it("a comment `;` above the cursor does not pin the start", function()
    local lines = { "SELECT 1 -- done;", "FROM t;" }
    local content, _, stmt_start = statement._test.extract_stmt_at_cursor(lines, 2, nil)
    assert.equals(1, stmt_start, "starts at the statement, not after the comment's `;`")
    assert.match("SELECT 1", content)
  end)
end)

describe("statement selection_cuts_statement", function()
  -- The guard's own decision table, exercised with both span readers stubbed
  -- so it holds in environments without the Tree-sitter sql parser.
  local ts_orig, rust_orig

  before_each(function()
    ts_orig = statement.try_ts_stmt_span
    rust_orig = statement.try_rust_stmt_span
    statement.try_rust_stmt_span = function() return nil end
  end)

  after_each(function()
    statement.try_ts_stmt_span = ts_orig
    statement.try_rust_stmt_span = rust_orig
  end)

  it("is a cut when the statement under the last selected line continues past it", function()
    statement.try_ts_stmt_span = function()
      return { 2, 5 } -- the INSERT spans lines 2..5; the selection ends at 2
    end
    assert.is_true(statement.selection_cuts_statement(nil, {}, 2, nil))
  end)

  it("is not a cut when the selection ends on the statement's last line", function()
    statement.try_ts_stmt_span = function()
      return { 2, 5 }
    end
    assert.is_false(statement.selection_cuts_statement(nil, {}, 5, nil))
  end)

  it("is not a cut when the span belongs to a statement below the selection", function()
    -- the blank-line walk can report the NEXT statement: its start sits below
    -- the selection's end, which says nothing about the selection itself
    statement.try_ts_stmt_span = function()
      return { 9, 9 }
    end
    assert.is_false(statement.selection_cuts_statement(nil, {}, 4, nil))
  end)

  it("falls back to the binary span when Tree-sitter has none", function()
    statement.try_ts_stmt_span = function() return nil end
    statement.try_rust_stmt_span = function(_, cursor_line, _)
      assert.equals(2, cursor_line)
      return { 2, 5 }
    end
    assert.is_true(statement.selection_cuts_statement(nil, {}, 2, "mysql"))
  end)

  it("degrades to nil when neither reader answers", function()
    statement.try_ts_stmt_span = function() return nil end
    assert.is_nil(statement.selection_cuts_statement(nil, {}, 2, nil))
  end)
end)

local has_sql_parser = require("poste-db.ts_stmt").check_parser()

if has_sql_parser then
  describe("statement selection_cuts_statement — real spans", function()
    -- The shapes that make the guard worth having, read by the real
    -- Tree-sitter parser the way a real visual run sees the buffer. The
    -- binary fallback stays stubbed: ts is the production common path, and
    -- spawning the real CLI from a spec would make this env-dependent.
    local rust_orig

    before_each(function()
      rust_orig = statement.try_rust_stmt_span
      statement.try_rust_stmt_span = function() return nil end
    end)

    after_each(function()
      statement.try_rust_stmt_span = rust_orig
    end)

    local function make_buf(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "poste_sql"
      vim.wait(500, function()
        local ok, p = pcall(vim.treesitter.get_parser, buf, "sql")
        return ok and p ~= nil
      end)
      return buf
    end

    it("a selection ending before VALUES cuts the INSERT", function()
      -- the 02:28:55 incident: the selection covered the SET line and the
      -- INSERT's column list; the VALUES lines fell outside it
      local lines = {
        "SET @menuId = (SELECT MAX(id) FROM menu);",
        "INSERT INTO permission (platform, menu_id, title)",
        "VALUES ('ADMIN', @menuId, 'x');",
        "INSERT INTO permission (platform, menu_id, title)",
        "VALUES ('ADMIN', @menuId, 'y');",
      }
      local buf = make_buf(lines)
      assert.is_true(statement.selection_cuts_statement(buf, lines, 2, nil),
        "line 2's statement continues onto line 3")
      assert.is_false(statement.selection_cuts_statement(buf, lines, 3, nil),
        "line 3 is the statement's last line")
      assert.is_false(statement.selection_cuts_statement(buf, lines, 5, nil),
        "an unterminated-looking last statement at the buffer end is not a cut")
    end)

    it("a selection ending on a boundary line between statements does not block the run", function()
      local lines = {
        "SELECT 1;",
        "",
        "SELECT 2;",
      }
      local buf = make_buf(lines)
      -- no span exists at the blank line, so the guard degrades (nil); the
      -- contract the runner leans on is simply "not true → execute"
      assert.is_not_true(statement.selection_cuts_statement(buf, lines, 2, nil),
        "a blank line between statements must not read as a cut")
    end)
  end)
end
