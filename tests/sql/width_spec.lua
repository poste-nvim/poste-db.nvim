local width = require("poste-db.width")
local format = require("poste-db.format")
local config = require("poste-db.config")

-- सिंधु घाटी = 10 codepoints: 5 base letters + 5 combining marks.
-- strdisplaywidth() folds ALL of them to 0 (even the Mc spacing marks
-- ि U+093F, ा U+093E, ी U+0940) and reports 5; the terminal paints 8 cells.

describe("width.display_width (terminal mode)", function()
  before_each(function()
    config.config.width_mode = "terminal"
  end)
  after_each(function()
    config.config.width_mode = nil
  end)

  it("counts Devanagari spacing marks that strdisplaywidth hides", function()
    assert.equals(vim.fn.strdisplaywidth("सिंधु घाटी"), 5)
    assert.equals(8, width.display_width("सिंधु घाटी"))
  end)

  it("leaves CJK at strdisplaywidth", function()
    assert.equals(8, width.display_width("中华文明"))
  end)

  it("handles ASCII via the fast path", function()
    assert.equals(5, width.display_width("hello"))
  end)

  it("keeps Mn non-spacing marks at zero width", function()
    assert.equals(4, width.display_width("cafe" .. vim.fn.nr2char(0x0301)))
  end)

  it("measures a string-initial Mc mark as 1", function()
    assert.equals(1, width.display_width(vim.fn.nr2char(0x093F)))
  end)

  it("tolerates nil and non-strings", function()
    assert.equals(0, width.display_width(nil))
    assert.equals(2, width.display_width(42))
  end)
end)

describe("width.truncate (terminal mode)", function()
  before_each(function()
    config.config.width_mode = "terminal"
  end)
  after_each(function()
    config.config.width_mode = nil
  end)

  it("keeps a string whose corrected width fits", function()
    assert.equals("सिंधु घाटी", width.truncate("सिंधु घाटी", 8))
  end)

  it("cuts at terminal width without splitting UTF-8", function()
    local r = width.truncate("सिंधु घाटी", 5)
    assert.equals(5, width.display_width(r))
    assert.equals("सिंधु घ", r)
  end)

  it("lets a non-spacing mark ride free with its base", function()
    assert.equals("e" .. vim.fn.nr2char(0x0301), width.truncate("e" .. vim.fn.nr2char(0x0301), 1))
  end)
end)

describe("width nvim mode (default)", function()
  local data = {
    type = "resultset",
    total_rows = 1,
    results = { {
      columns = {
        { name = "name_native", type = "text" },
        { name = "n", type = "integer" },
      },
      rows = { { "सिंधु घाटी", "1" } },
    } },
  }

  before_each(function()
    config.config.width_mode = "nvim"
  end)
  after_each(function()
    config.config.width_mode = nil
  end)

  it("measures with plain strdisplaywidth", function()
    assert.equals(5, width.display_width("सिंधु घाटी"))
    assert.equals(8, width.display_width("中华文明"))
    assert.equals(5, width.display_width("hello"))
  end)

  it("truncates by vim's per-char cell widths", function()
    assert.equals("सिंध", width.truncate("सिंधु घाटी", 4))
  end)

  it("keeps every bordered line self-consistent", function()
    local layout = format.plan_resultset_layout(data)
    local lines = format.render_page(layout, 1, 50)
    local border_w
    for _, l in ipairs(lines) do
      if l:find("│", 1, true) then
        border_w = border_w or width.display_width(l)
        assert.equals(border_w, width.display_width(l))
      end
    end
  end)
end)

describe("format_dataset with a Devanagari cell (terminal mode)", function()
  local data = {
    type = "resultset",
    total_rows = 1,
    results = { {
      columns = {
        { name = "name_native", type = "text" },
        { name = "n", type = "integer" },
      },
      rows = { { "सिंधु घाटी", "1" } },
    } },
  }
  local layout, lines, meta

  before_each(function()
    config.config.width_mode = "terminal"
    layout = format.plan_resultset_layout(data)
    lines, meta = format.render_page(layout, 1, 50)
  end)
  after_each(function()
    config.config.width_mode = nil
  end)

  it("sizes the column for the painted width, not strdisplaywidth", function()
    -- col 1 is the row-number column, col 2 is name_native
    assert.is_true(meta.col_widths[2] >= 8 + 2)
  end)

  it("renders every bordered line at the same terminal width", function()
    local widths = {}
    for _, l in ipairs(lines) do
      if l:find("│", 1, true) then
        widths[#widths + 1] = width.display_width(l)
      end
    end
    -- header + one data row (top/bottom borders use ─ only)
    assert.is_true(#widths >= 2)
    for _, w in ipairs(widths) do
      assert.equals(widths[1], w)
    end
  end)

  it("ends data rows with the right border aligned to the header", function()
    local header, row
    for _, l in ipairs(lines) do
      if l:find("name_native", 1, true) then header = l end
      if l:find("सिंधु", 1, true) then row = l end
    end
    assert.truthy(header and row)
    assert.truthy(vim.endswith(row, "│"))
    assert.equals(width.display_width(header), width.display_width(row))
  end)
end)

describe("width.truncate_ellipsis", function()
  it("leaves a string that fits alone", function()
    assert.equals("hello", width.truncate_ellipsis("hello", 10))
    assert.equals("hello", width.truncate_ellipsis("hello", 5))
  end)

  it("reserves a cell for the ellipsis so the result never exceeds the budget", function()
    local out = width.truncate_ellipsis(string.rep("x", 20), 6)
    assert.equals(6, width.display_width(out))
    assert.equals("xxxxx…", out)
  end)

  it("never splits a multibyte character", function()
    -- 10 CJK glyphs = 20 cells; a budget of 7 cells keeps 3 glyphs + "…"
    local out = width.truncate_ellipsis(string.rep("字", 10), 7)
    assert.equals(7, width.display_width(out))
    assert.equals("字字字…", out)
    -- strcharpart round-trips only a well-formed string
    assert.equals(out, vim.fn.strcharpart(out, 0, vim.fn.strchars(out)))
  end)

  it("degrades to the ellipsis alone, then to empty, on a sub-cell budget", function()
    -- the three copies of this loop disagreed here: one returned "" for
    -- max < 1, the others fell through to the loop
    assert.equals("…", width.truncate_ellipsis("hello", 1))
    assert.equals("", width.truncate_ellipsis("hello", 0))
    assert.equals("", width.truncate_ellipsis("hello", -3))
  end)

  it("handles nil", function()
    assert.equals("", width.truncate_ellipsis(nil, 8))
  end)
end)
