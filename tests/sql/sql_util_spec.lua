local util = require("poste-db.util")
local width = require("poste-db.width")

describe("util utf8 helpers", function()
  it("utf8_char_bytes returns correct byte widths", function()
    assert.equals(1, util.utf8_char_bytes(0x24))
    assert.equals(2, util.utf8_char_bytes(0xC2))
    assert.equals(3, util.utf8_char_bytes(0xE2))
    assert.equals(4, util.utf8_char_bytes(0xF0))
  end)

  it("width.truncate preserves ASCII strings under limit", function()
    -- was util.truncate_displaywidth, a deprecated forwarder to the same
    -- implementation; the maintained name lives next to the width oracle
    assert.equals("hello", width.truncate("hello", 10))
  end)

  it("width.truncate stops before multibyte overflow", function()
    local s = "a│b"
    assert.equals("a│", width.truncate(s, 2))
  end)

  it("width.truncate handles empty strings", function()
    assert.equals("", width.truncate("", 5))
    assert.equals("", width.truncate(nil, 5))
  end)

  it("utf8_safe_cut keeps short strings unchanged", function()
    assert.equals("abc", util.utf8_safe_cut("abc", 10))
    assert.equals("", util.utf8_safe_cut(nil, 10))
  end)

  it("utf8_safe_cut cuts ASCII exactly at the budget", function()
    assert.equals(string.rep("x", 10), util.utf8_safe_cut(string.rep("x", 20), 10))
  end)

  it("utf8_safe_cut backs the cut off a multibyte character", function()
    -- 数 = 3 bytes: budget 10 would split the 4th character
    local s = string.rep("\u{6570}", 5)
    assert.equals(string.rep("\u{6570}", 3), util.utf8_safe_cut(s, 10))
  end)
end)

describe("util ellipsize", function()
  it("leaves strings that fit untouched", function()
    assert.equals("SELECT 1", util.ellipsize("SELECT 1", 20))
    assert.equals("数数数", util.ellipsize("数数数", 6))  -- exactly 6 cells
  end)

  it("cuts in display cells, never mid-glyph, and appends ...", function()
    -- each 数 is 3 bytes but 2 cells; budget 8 minus the ... reserve leaves
    -- 5 cells = two glyphs, and the old byte-based cut landed mid-glyph
    local out = util.ellipsize("数数数数数", 8)
    assert.equals("数数...", out)
    assert.equals(7, vim.fn.strdisplaywidth(out))  -- 4 cells + 3 dots
  end)

  it("budgets display cells, so the result fits the screen budget", function()
    -- 10 CJK chars = 30 bytes but 20 cells: a byte-length check called for
    -- a cut (and split a glyph); a cell budget of 20 fits without one
    local ten_cjk = string.rep("\u{6570}", 10)
    assert.equals(ten_cjk, util.ellipsize(ten_cjk, 20))
    -- and a 10-cell budget produces a valid, on-budget string
    local out = util.ellipsize(ten_cjk, 10)
    assert.equals("数数数...", out)
    assert.is_true(vim.fn.strdisplaywidth(out) <= 10)
  end)

  it("tolerates nil and tiny budgets", function()
    assert.equals("", util.ellipsize(nil, 10))
    assert.equals("a", util.ellipsize("abcdef", 1))
    assert.equals("ab", util.ellipsize("abcdef", 2))
  end)
end)

describe("util.unquote_ident", function()
  it("strips one matching pair of identifier quotes", function()
    assert.equals("users", util.unquote_ident("`users`"))
    assert.equals("users", util.unquote_ident('"users"'))
    assert.equals("", util.unquote_ident('""'))
  end)

  it("keeps names whose ends merely look like quotes", function()
    -- round-56 toml lesson: only a MATCHING pair quotes; a lone leading or
    -- trailing quote is part of the name.
    assert.equals("`users", util.unquote_ident("`users"))
    assert.equals('users"', util.unquote_ident('users"'))
    assert.equals("`", util.unquote_ident("`"))
  end)

  it("tolerates nil and bare names", function()
    assert.equals("", util.unquote_ident(nil))
    assert.equals("users", util.unquote_ident("users"))
  end)
end)

describe("util.named", function()
  it("passes a real name through", function()
    assert.equals("my-blog", util.named("my-blog"))
    -- a name may be whitespace-shaped SQL text, not padding: only the empty
    -- string itself counts as absent
    assert.equals(" ", util.named(" "))
  end)

  it("reads an empty name as absent", function()
    -- the response envelope normalises an unknown connection/database to ""
    -- (exec_run's `or ""`), and readers that only tested nil took it for a
    -- bound target: the chat scope announced a connection with no name, and a
    -- session started with `--database ""`, which the CLI applies as a URL
    -- rewrite — the statement ran with the database stripped off
    assert.is_nil(util.named(""))
    assert.is_nil(util.named(nil))
  end)

  it("reads any non-string as absent", function()
    assert.is_nil(util.named(42))
    assert.is_nil(util.named(true))
    assert.is_nil(util.named({ "db" }))
    assert.is_nil(util.named(vim.NIL), "JSON null decodes to vim.NIL, a truthy userdata")
    assert.is_nil(util.named(function() return "db" end))
  end)
end)

describe("util.affected_rows", function()
  it("passes a real count through", function()
    assert.equals(0, util.affected_rows(0))
    assert.equals(7, util.affected_rows(7))
  end)

  it("reads a count that arrived as text as a count", function()
    assert.equals(7, util.affected_rows("7"))
  end)

  it("reads no count at all as nil, including a decoded JSON null", function()
    -- vim.NIL is truthy: left alone it reaches the response envelope as
    -- "something was affected" and a SELECT renders as "0 rows affected"
    assert.is_nil(util.affected_rows(nil))
    assert.is_nil(util.affected_rows(vim.NIL))
  end)

  it("reads unparseable text as nil rather than as a number", function()
    assert.is_nil(util.affected_rows(""))
    assert.is_nil(util.affected_rows("nope"))
  end)
end)
