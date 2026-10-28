local lex = require("poste-db.lex")

describe("lex.find_use_database", function()
  it("reads a plain, lowercase and semicolon'd name", function()
    assert.equals("mydb", lex.find_use_database("USE mydb"))
    assert.equals("mydb", lex.find_use_database("use mydb"))
    assert.equals("mydb", lex.find_use_database("USE mydb;"))
  end)

  it("ignores surrounding whitespace and tabs", function()
    assert.equals("mydb", lex.find_use_database("  USE mydb  "))
    assert.equals("mydb", lex.find_use_database("\tUSE\tmydb\t"))
  end)

  it("returns nil for nil, empty, whitespace-only and bare USE", function()
    assert.is_nil(lex.find_use_database(nil))
    assert.is_nil(lex.find_use_database(""))
    assert.is_nil(lex.find_use_database("   "))
    assert.is_nil(lex.find_use_database("USE"))
  end)

  it("does not match USE as a prefix of a longer word", function()
    assert.is_nil(lex.find_use_database("USER u"))
    assert.is_nil(lex.find_use_database("USEFUL x"))
  end)

  it("stops a bare name at whitespace, so a trailing comment is not part of it", function()
    assert.equals("mydb", lex.find_use_database("USE mydb -- switch"))
  end)

  it("stops a bare name at the semicolon even when a comment follows it", function()
    -- `USE mydb;-- note` used to return "mydb;--" because the `;` strip only
    -- fired at the very end of the token.
    assert.equals("mydb", lex.find_use_database("USE mydb;-- note"))
  end)

  it("returns a quoted name that contains spaces intact", function()
    -- The old `%S+` scan cut at the space inside the quotes and returned "my".
    assert.equals("my db", lex.find_use_database("USE `my db`"))
    assert.equals("my db", lex.find_use_database('USE "my db";'))
    assert.equals("my db", lex.find_use_database("USE 'my db'"))
  end)

  it("reads a MSSQL bracket-quoted name", function()
    -- `USE [My DB]` is the canonical T-SQL spelling; the bare-name scan used
    -- to cut at the space and return "[My"
    assert.equals("My DB", lex.find_use_database("USE [My DB]"))
    assert.equals("master", lex.find_use_database("USE [master];"))
  end)

  it("unwinds a doubled ] inside a bracket-quoted name", function()
    -- T-SQL escapes a literal ] by doubling it
    assert.equals("a]b", lex.find_use_database("USE [a]]b]"))
  end)

  it("returns nil for an unterminated bracket-quoted name", function()
    assert.is_nil(lex.find_use_database("USE [My DB"))
  end)

  it("does not let a block comment become the database name", function()
    -- `USE /* default */ mydb` used to return "/*" + "default*/" verbatim.
    assert.equals("mydb", lex.find_use_database("USE /* default */ mydb"))
    assert.equals("mydb", lex.find_use_database("USE/* inline */mydb"))
  end)

  it("skips several leading comments and returns nil when nothing follows", function()
    assert.equals("mydb", lex.find_use_database("/* a */ /* b */ USE mydb"))
    assert.is_nil(lex.find_use_database("/* only a comment */"))
  end)

  it("does not treat a quote inside a leading comment as a name delimiter", function()
    assert.equals("mydb", lex.find_use_database("/* don't */ USE mydb"))
  end)

  it("returns nil for an unterminated quoted name", function()
    -- The old code stripped the leading quote and returned the rest; a name
    -- whose quotes never close is a half-written line, not a database.
    assert.is_nil(lex.find_use_database('USE "my db'))
  end)

  it("returns nil for a full-line -- comment", function()
    assert.is_nil(lex.find_use_database("-- USE mydb"))
  end)

  it("returns nil when the name sits inside a string on the same line", function()
    assert.is_nil(lex.find_use_database("x = 'USE mydb'"))
  end)
end)

describe("lex.is_comment_or_string", function()
  it("spots line comments, strings and backticks at a byte position", function()
    assert.is_true(lex.is_comment_or_string("SELECT 1 -- hi", 12))
    assert.is_true(lex.is_comment_or_string("SELECT 'a b'", 9))
    assert.is_true(lex.is_comment_or_string("SELECT `a b`", 9))
    -- the quote characters themselves belong to the literal: the region spans
    -- [opener .. closer] inclusive
    assert.is_true(lex.is_comment_or_string("SELECT 'a b'", 8))
    assert.is_true(lex.is_comment_or_string("SELECT 'a b'", 12))
    assert.is_false(lex.is_comment_or_string("SELECT 'a b'", 13))
  end)

  it("handles quote escaping inside strings", function()
    assert.is_true(lex.is_comment_or_string([[SELECT 'a\'b -- x']], 14))
    assert.is_true(lex.is_comment_or_string("SELECT 'it''s -- x'", 15))
  end)

  it("keeps standard-SQL non-nesting block comments", function()
    -- SQL block comments do not nest: the first */ closes them all, so text
    -- after it is code again.
    local s = "/* /* x */ still */ y"
    assert.is_true(lex.is_comment_or_string(s, 7))
    assert.is_false(lex.is_comment_or_string(s, 14))
  end)

  it("answers false for out-of-range and degenerate positions", function()
    assert.is_false(lex.is_comment_or_string("abc", 99))
    assert.is_false(lex.is_comment_or_string("abc", 0))
    assert.is_false(lex.is_comment_or_string("", 1))
  end)
end)

describe("lex.block_comment_depth_after", function()
  it("counts a comment opening and closing on one line", function()
    assert.equals(0, lex.block_comment_depth_after("/* x */ SELECT", 0))
    assert.equals(1, lex.block_comment_depth_after("SELECT /* x", 0))
    assert.equals(0, lex.block_comment_depth_after("rest */ SELECT", 1))
  end)

  it("does NOT nest, matching is_comment_or_string and blank_regions", function()
    -- The three readers must agree on the same text: depth_after used to
    -- nest while the other two closed at the first `*/`, so `/* /* */ */`
    -- was "still in comment" here and plain code there. postgres alone
    -- nests block comments; single-level is the conservative shared rule.
    assert.equals(0, lex.block_comment_depth_after("/* /* nested */ still */ tail", 0))
    assert.equals(1, lex.block_comment_depth_after("/* /* two opens", 0))
  end)

  it("carries depth across lines so a scanner can skip a whole region", function()
    local depth = 0
    depth = lex.block_comment_depth_after("/* start", depth)
    depth = lex.block_comment_depth_after("USE middle -- looks real", depth)
    depth = lex.block_comment_depth_after("*/ USE real", depth)
    assert.equals(0, depth)
  end)

  it("ignores markers inside strings and line comments", function()
    assert.equals(0, lex.block_comment_depth_after("SELECT '/* not a comment */'", 0))
    -- a `--` comments out the rest of the line, so a `/*` after it is data
    -- and must NOT leak depth into the following lines
    assert.equals(0, lex.block_comment_depth_after("SELECT 1 -- /* unterminated", 0))
    assert.equals(0, lex.block_comment_depth_after("SELECT `x/*y`", 0))
  end)

  it("respects backslash escapes in '-strings but not in `-strings", function()
    assert.equals(0, lex.block_comment_depth_after([[SELECT 'it\'s /* x']], 0))
    assert.equals(1, lex.block_comment_depth_after([[SELECT `a\b` /* x]], 0))
  end)

  it("saturates at zero for a stray closer", function()
    assert.equals(0, lex.block_comment_depth_after("x */ y", 0))
  end)
end)

describe("lex.find_block_for_line", function()
  it("starts after the nearest ### marker above the cursor", function()
    local lines = { "### first", "SELECT 1;", "### second", "SELECT 2;" }
    -- the block CONTAINING the cursor starts at the line after its marker
    assert.equals(4, lex.find_block_for_line(lines, 4))
    assert.equals(2, lex.find_block_for_line(lines, 2))
  end)

  it("starts at 1 when no marker exists above", function()
    assert.equals(1, lex.find_block_for_line({ "SELECT 1;", "SELECT 2;" }, 2))
  end)
end)

describe("lex.blank_regions", function()
  it("blanks a single-quoted literal, quotes included", function()
    local out = lex.blank_regions("SELECT 'a,b' FROM t")
    assert.is_nil(out:find("a,b", 1, true))
    assert.truthy(out:find("FROM t", 1, true))
  end)

  it("is length- and newline-preserving", function()
    local src = "SELECT 'a\nb' FROM t\n-- c\n"
    local out = lex.blank_regions(src)
    assert.equals(#src, #out)
    local nl_in, nl_out = 0, 0
    for _ in src:gmatch("\n") do nl_in = nl_in + 1 end
    for _ in out:gmatch("\n") do nl_out = nl_out + 1 end
    assert.equals(nl_in, nl_out)
  end)

  it("keeps '' inside a literal (one quote of data, not the closing quote)", function()
    local out = lex.blank_regions("SELECT 'it''s', 'x' FROM t")
    assert.is_nil(out:find("it", 1, true))
    assert.is_nil(out:find("x'", 1, true))
    assert.truthy(out:find("FROM t", 1, true))
  end)

  it("blanks an unterminated literal through the end", function()
    local out = lex.blank_regions("select * from users where note = 'it''s from bob")
    assert.truthy(out:find("from users", 1, true))
    assert.is_nil(out:find("bob", 1, true))
  end)

  it("a -- inside a literal is data, not a comment", function()
    -- the round-50 held probe: the gsub chain stripped the "comment" first
    -- and the FROM went with it
    local out = lex.blank_regions("SELECT 'a--b' FROM t")
    assert.truthy(out:find("FROM t", 1, true))
  end)

  it("an apostrophe inside a comment opens no phantom literal", function()
    local out = lex.blank_regions("select 1 -- don't\nfrom users")
    assert.truthy(out:find("from users", 1, true))
  end)

  it("blanks block comments, keeping inner newlines", function()
    local out = lex.blank_regions("select/* x\ny */1")
    assert.is_nil(out:find("x", 1, true))
    assert.equals(1, select(2, out:gsub("\n", "")))
    assert.truthy(out:find("select", 1, true))
  end)

  it("blanks a dollar-quoted body", function()
    local out = lex.blank_regions("$$ delete from secret $$ select 1")
    assert.is_nil(out:find("secret", 1, true))
    assert.truthy(out:find("select 1", 1, true))
  end)

  it("keeps double-quoted and backtick regions when asked, blanks them otherwise", function()
    local kept = lex.blank_regions('select * from "my--table"', true)
    assert.truthy(kept:find("my--table", 1, true))
    local blanked = lex.blank_regions('select * from "my--table"')
    assert.is_nil(blanked:find("my--table", 1, true))
    local backticked = lex.blank_regions("select * from `my--table`", true)
    assert.is_true(backticked:find("`my--table`", 1, true) ~= nil)
  end)

  it("an escaped doubled quote inside a kept region stays verbatim", function()
    local out = lex.blank_regions('select * from "a""b"', true)
    assert.equals('"a""b"', out:match('"a""b"'))
  end)
end)
