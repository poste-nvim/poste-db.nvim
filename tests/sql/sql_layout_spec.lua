local layout = require("poste-db.layout")

describe("layout.word_wrap", function()
  it("wraps at spaces within the display width", function()
    local lines = layout.word_wrap("the quick brown fox", 10)
    assert.are_same({ "the quick", "brown fox" }, lines)
  end)

  it("keeps CJK within the width by counting 2 columns per char", function()
    -- 5 CJK chars = 10 columns; width 6 fits three of them per line
    local lines = layout.word_wrap("中文测试文本", 6)
    for _, line in ipairs(lines) do
      assert.truthy(vim.fn.strdisplaywidth(line) <= 6)
    end
  end)

  it("never splits a multi-byte character", function()
    local lines = layout.word_wrap("中文abc中文", 4)
    for _, line in ipairs(lines) do
      assert.equals(vim.fn.strchars(line), #line - select(2, line:gsub("[\128-\191]", "")))
    end
  end)

  it("returns the text untouched when it fits", function()
    assert.are_same({ "short" }, layout.word_wrap("short", 80))
  end)
end)

describe("layout.dynamic_line truncation", function()
  -- The truncate paths used to budget in CHARACTERS, so CJK text (2 columns
  -- per char) overflowed container_width. A result may UNDER-fill by one
  -- column (the next CJK char does not fit the budget), but must never
  -- exceed it.
  local function assert_fits(line, width)
    assert.truthy(vim.fn.strdisplaywidth(line) <= width,
      string.format("width %d exceeds container %d: %s", vim.fn.strdisplaywidth(line), width, line))
  end

  it("right-truncates ASCII as before", function()
    local line = layout.dynamic_line({ text = "abcdefghij", container_width = 8 })
    assert.equals(8, vim.fn.strdisplaywidth(line))
    assert.equals("abcde..." , vim.trim(line))
  end)

  it("right-truncation never overflows for CJK text", function()
    local line = layout.dynamic_line({ text = "中文测试文本中文测试文本", container_width = 10 })
    assert_fits(line, 10)
    assert.truthy(line:find("%.%.%."))
  end)

  it("left-truncation never overflows for CJK text", function()
    local line = layout.dynamic_line({ text = "中文测试文本中文测试文本", container_width = 10, truncate_at = "left" })
    assert_fits(line, 10)
    assert.truthy(line:find("%.%.%."))
  end)

  it("mid-truncation never overflows for CJK text", function()
    for _, w in ipairs({ 8, 9, 10, 11, 15 }) do
      local line = layout.dynamic_line({ text = "中文测试文本中文测试文本", container_width = w, truncate_at = "mid" })
      assert_fits(line, w)
    end
  end)

  it("an ellipsis as wide as the container collapses to the pad width", function()
    local line = layout.dynamic_line({ text = "中文测试", container_width = 3, ellipsis = "..." })
    assert_fits(line, 3)
  end)

  it("short text is padded to the container width, not truncated", function()
    local line = layout.dynamic_line({ text = "ok", container_width = 6 })
    assert_fits(line, 6)
    assert.equals("ok    ", line)
  end)
end)

describe("layout helpers", function()
  it("pad and cell measure display width", function()
    assert.equals("中文  ", layout.pad("中文", 6))
    assert.equals(vim.fn.strdisplaywidth(layout.cell("中文", 6)), 6)
  end)

  it("space_between fills the gap between two ends", function()
    local line = layout.space_between("left", "right", { width = 12 })[1]
    assert.equals(12, vim.fn.strdisplaywidth(line))
  end)

  it("progress renders current/total with a label", function()
    local parts = layout.progress(5, 10, { bar_width = 10 })
    assert.truthy(parts[1]:find("5/10 50%%"))
  end)

  it("progress clamps a current greater than total to 100%%", function()
    -- current > total used to draw more fill cells than the bar width and a
    -- "150%" label; the bar must cap at full and never report over 100%.
    local parts = layout.progress(15, 10, { bar_width = 20 })
    assert.truthy(parts[1]:find("15/10 100%%"), parts[1])
    local bar = parts[1]:match("^(.-) 15/10")
    assert.truthy(bar, "bar segment missing")
    assert.equals(20, vim.fn.strdisplaywidth(bar))
  end)

  it("keymaps strips the trailing separator but keeps an empty line whole", function()
    local with_entries = layout.keymaps({ mapping = { { key = "q", label = "quit" } } })
    assert.equals("    [q quit]", with_entries.lines[1])
    local empty = layout.keymaps({ mapping = {} })
    assert.equals("    ", empty.lines[1])
  end)
end)
