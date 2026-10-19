local D = require("poste-db.dataset")

describe("dataset compute_view_indices", function()
  before_each(function()
    D.tabs = {}
    D.active_tab_idx = 0
  end)

  it("sorts rows by numeric column ascending", function()
    local tab = D.alloc_tab(1)
    tab.rows_source = {
      { 3, false, "c" },
      { 1, true,  "a" },
      { 2, false, "b" },
    }
    tab.sort = { col = 1, ascending = true }

    D.compute_view_indices(tab)

    assert.same({ 2, 3, 1 }, tab.view_indices)
  end)

  it("sorts rows by boolean column descending", function()
    local tab = D.alloc_tab(1)
    tab.rows_source = {
      { "row1", false },
      { "row2", true },
      { "row3", false },
    }
    tab.sort = { col = 2, ascending = false }

    D.compute_view_indices(tab)

    assert.same({ 2, 1, 3 }, tab.view_indices)
  end)

  it("applies filtered_indices before sorting", function()
    local tab = D.alloc_tab(1)
    tab.rows_source = {
      { 30, "z" },
      { 10, "x" },
      { 20, "y" },
    }
    tab.filtered_indices = { 1, 3 }
    tab.sort = { col = 1, ascending = true }

    D.compute_view_indices(tab)

    assert.same({ 3, 1 }, tab.view_indices)
  end)

  it("uses filtered_indices without sort", function()
    local tab = D.alloc_tab(1)
    tab.rows_source = {
      { "row1" },
      { "row2" },
      { "row3" },
    }
    tab.filtered_indices = { 3, 1 }

    D.compute_view_indices(tab)

    assert.same({ 3, 1 }, tab.view_indices)
  end)

  it("sorts numeric strings numerically (bigints arrive as strings)", function()
    local tab = D.alloc_tab(1)
    tab.rows_source = {
      { "100" },
      { "9" },
      { "2084515900853196878" },
    }
    tab.sort = { col = 1, ascending = true }

    D.compute_view_indices(tab)

    assert.same({ 2, 1, 3 }, tab.view_indices)
  end)

  it("sorts rows that are not tables last instead of raising", function()
    -- The render path renders a non-sequence row as empty cells; the sort
    -- used to index it and crash the whole view. They sort like empty cells:
    -- last.
    local tab = D.alloc_tab(1)
    tab.rows_source = {
      { 2 },
      "garbage",
      { 1 },
      42,
    }
    tab.sort = { col = 1, ascending = true }

    D.compute_view_indices(tab)

    assert.same({ 3, 1, 2, 4 }, tab.view_indices)
  end)
end)

describe("dataset default page size", function()
  before_each(function()
    D.tabs = {}
    D.active_tab_idx = 0
    D.set_page_size(50)
  end)

  it("defaults to 50 rows per page", function()
    local tab = D.alloc_tab(1)
    assert.equals(50, tab.page_size)
  end)

  it("honors set_page_size for newly allocated tabs", function()
    D.set_page_size(25)
    local tab = D.alloc_tab(1)
    assert.equals(25, tab.page_size)
  end)

  it("clamps invalid values to a sane minimum", function()
    D.set_page_size(-3)
    assert.equals(1, D.default_page_size)
  end)
end)

describe("dataset hostile inputs", function()
  before_each(function()
    D.tabs = {}
    D.active_tab_idx = 0
    D.set_page_size(50)
  end)

  it("format_wallclock survives a non-numeric timestamp", function()
    -- os.date raises on a string; the history render must not be killable
    -- by one malformed ts (same rule as poste-redis history.build)
    local out = D.format_wallclock("not-a-number", nil)
    assert.is_string(out)
    assert.matches("%d%d:%d%d:%d%d%.%d%d%d", out)
    assert.is_string(D.format_wallclock(nil, "x"))
  end)

  it("apply_page_bounds degrades to one page when page_size is missing", function()
    -- alloc_tab always sets page_size; a hand-built tab must not crash the
    -- render path that only wants sane bounds
    local tab = { page = 9 }
    local pages = D.apply_page_bounds(tab, nil)
    assert.equals(1, pages)
    assert.equals(1, tab.num_pages)
    assert.equals(1, tab.page, "page clamps into the recomputed range")
  end)
end)
