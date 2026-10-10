local render = require("poste-db.buffer.render")

describe("buffer_render", function()
  it("normalizes a resultset page with header", function()
    local tab = {}
    local padded, meta = render.normalize_rendered_page(tab, {
      "┌────┐",
      "│ id │",
      "├────┤",
      "│ 1  │",
      "└────┘",
    }, {
      type = "resultset",
      header_line = 2,
      data_start_line = 4,
      data_end_line = 4,
      row_count = 1,
    })

    assert.equals("", padded[1])
    assert.equals("  │ 1  │", padded[#padded])
    assert.equals(2, meta.data_start_line)
    assert.equals(2, meta.data_end_line)
    assert.equals("│ id │", tab.header_text)
  end)

  it("builds buffer column start maps", function()
    local tab = {}
    render.build_column_start_maps(tab, {
      data_start_line = 4,
      col_starts = {
        {
          { ext_start = 1, ext_end = 3 },
          { ext_start = 5, ext_end = 8 },
        },
      },
      col_widths = { 2, 3 },
      header_col_starts = {
        { ext_start = 1, ext_end = 3 },
        { ext_start = 5, ext_end = 8 },
      },
    })

    assert.is_not_nil(tab.buffer_col_starts[4])
    assert.equals(4, tab.buffer_col_starts[4][1].disp_start)
    assert.equals(7, tab.buffer_col_starts[4][1].disp_end)
  end)

  it("inserts the sort indicator without corrupting the header text", function()
    local tab = { sort = { col = 1, ascending = true } }
    local _ = render.normalize_rendered_page(tab, {
      "┌──────────────┐",
      "│ # │ id    │ name   │",
      "├──────────────┤",
      "│ 1 │ 2     │ 3      │",
      "└──────────────┘",
    }, {
      type = "resultset",
      header_line = 2,
      data_start_line = 4,
      data_end_line = 4,
      row_count = 1,
    })
    assert.truthy(tab.header_text:find(" ↑", 1, true))
    assert.is_not_nil(tab.header_index)
    local sep_count = 0
    for _, c in ipairs(tab.header_index) do
      if c.sep then sep_count = sep_count + 1 end
    end
    assert.equals(4, sep_count, "indicator insertion must not eat a column separator")
  end)

  -- A column whose name is the widest thing in it gets exactly one space before
  -- the next `│` (the cell is `" " .. padded_name .. " "`). Overwriting a fixed
  -- two bytes there consumed the separator's first byte, so the header float
  -- showed an orphan UTF-8 continuation where a `│` used to be and every column
  -- to the right shifted out of alignment with the data rows.
  it("stamps a full-width column with the one-cell arrow", function()
    local tab = { sort = { col = 0, ascending = true } }
    local _ = render.normalize_rendered_page(tab, {
      "┌────────────┐",
      "│ id │ name │",
      "├────────────┤",
      "│ 1  │ ab   │",
      "└────────────┘",
    }, {
      type = "resultset",
      header_line = 2,
      data_start_line = 4,
      data_end_line = 4,
      row_count = 1,
    })
    assert.equals("│ id↑│ name │", tab.header_text)
    assert.equals(13, vim.fn.strdisplaywidth(tab.header_text))
    local sep_count = 0
    for _, c in ipairs(tab.header_index) do
      if c.sep then sep_count = sep_count + 1 end
    end
    assert.equals(3, sep_count)
  end)

  it("keeps the same width for a descending full-width multibyte column", function()
    local tab = { sort = { col = 0, ascending = false } }
    local _ = render.normalize_rendered_page(tab, {
      "┌────────────┐",
      "│ 名称 │ ab │",
      "├────────────┤",
      "│ 1  │ 2  │",
      "└────────────┘",
    }, {
      type = "resultset",
      header_line = 2,
      data_start_line = 4,
      data_end_line = 4,
      row_count = 1,
    })
    assert.equals("│ 名称↓│ ab │", tab.header_text)
    assert.equals(13, vim.fn.strdisplaywidth(tab.header_text))
    assert.is_true(pcall(vim.str_utf_pos, tab.header_text))
  end)

  it("leaves the header untouched when the cell has no padding to spend", function()
    -- ext_end lands on a non-space (a hand-built or context-reflowed header):
    -- there is no cell to overwrite, so no arrow is stamped rather than
    -- shifting every separator to the right.
    local tab = { sort = { col = 0, ascending = true } }
    local _ = render.normalize_rendered_page(tab, {
      "┌──────┐",
      "│ id│ x │",
      "├──────┤",
      "│ 1 │ 2 │",
      "└──────┘",
    }, {
      type = "resultset",
      header_line = 2,
      data_start_line = 4,
      data_end_line = 4,
      row_count = 1,
    })
    assert.equals("│ id│ x │", tab.header_text)
  end)
end)
