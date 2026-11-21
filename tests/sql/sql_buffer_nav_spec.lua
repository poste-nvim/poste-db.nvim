local D = require("poste-db.dataset")
local nav = require("poste-db.buffer.nav")
local ui = require("poste-db.buffer.nav_ui")
local state = require("poste-db.state")

describe("buffer_nav helpers", function()
  before_each(function()
    D.tabs = {}
    D.active_tab_idx = 0
  end)

  it("build_header_index records UTF-8 separator byte positions", function()
    local idx = nav._test.build_header_index("  │ id │ name │")
    local seps = {}
    for _, entry in ipairs(idx) do
      if entry.sep then
        seps[#seps + 1] = entry.bs
      end
    end
    assert.same({ 3, 10, 19 }, seps)
  end)

  it("build_status_winbar includes the main status fragments", function()
    local tab = D.alloc_tab(1)
    tab.sort = { col = 2, ascending = false }
    tab.pagination_enabled = true
    tab.page = 2
    tab.num_pages = 3
    tab.layout = {}
    tab.filter_active = true
    tab.filter_col_name = "status"
    tab.filter_val = "open"
    tab.search_text = "needle"
    tab.search_matches = { { row = 1, col = 1 }, { row = 2, col = 2 } }
    tab.search_idx = 2
    tab.edit_state = { dirty = false }
    D.active_tab_idx = 1

    local meta = {
      type = "resultset",
      total_rows = 12,
      total_execution_time_ms = 7,
      table_name = "posts",
      columns = {
        [2] = { name = "title" },
      },
      connection = "postgres://user:pass@localhost:5432/blog?sslmode=require",
    }
    tab.meta = meta

    local text = ui.build_status_winbar(meta, tab, #D.tabs, D.active_tab_idx)

    assert.truthy(text:find("12 rows", 1, true))
    assert.truthy(text:find("title ↓", 1, true))
    assert.truthy(text:find("P:2/3", 1, true))
    assert.truthy(text:find("filter: status=open", 1, true))
    assert.truthy(text:find("search: needle (2/2)", 1, true))
  end)
end)

describe("buffer_nav horizontal scroll", function()
  before_each(function()
    D.tabs = {}
    D.active_tab_idx = 0
    if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
      pcall(vim.api.nvim_win_close, D.dataset_window, true)
    end
    D.dataset_window = nil
    require("poste-db.buffer.header").close()
    state.cell = { row = 1, col = 1 }
  end)

  it("slices the header with separators only at their true screen positions", function()
    local full = "  │ # │ id    │ 姓名   │ 备注    │"
    local idx = nav._test.build_header_index(full)
    local function seps(text)
      local out = {}
      for _, c in ipairs(nav._test.build_header_index(text)) do
        if c.sep then out[#out + 1] = c.ds end
      end
      return out
    end

    for _, leftcol in ipairs({ 0, 6, 7, 14, 15, 22, 26 }) do
      local text = nav._test.slice_header_to_win(leftcol, 20, full, idx)
      local expected = {}
      for _, c in ipairs(idx) do
        if c.sep and c.ds >= leftcol and c.ds < leftcol + 20 then
          expected[#expected + 1] = c.ds - leftcol
        end
      end
      local actual = seps(text)
      assert.same(
        expected,
        actual,
        string.format("leftcol=%d: slice separators %s, expected %s",
          leftcol, table.concat(actual, ","), table.concat(expected, ","))
      )
    end
  end)

  it("restores the row-number column when scrolling back to the first column", function()
    local saved_columns = vim.o.columns
    vim.o.columns = 40

    local format = require("poste-db.format")
    local buffer = require("poste-db.buffer")
    local body = vim.json.encode({
      type = "resultset",
      total_rows = 50,
      results = {
        {
          columns = {
            { name = "id", type = "INTEGER" },
            { name = "name", type = "TEXT" },
            { name = "desc", type = "TEXT" },
            { name = "note", type = "TEXT" },
            { name = "data", type = "TEXT" },
          },
          rows = {
            { 1, "alice", "aaaaaaaaaaaaaaaaaaaaaaaaaaaa", "c", "d" },
          },
        },
      },
      connection = "postgres://localhost:5432/db",
      database = "db",
      dialect = "postgres",
    })
    local data = vim.json.decode(body)
    local layout = format.plan_resultset_layout(data)
    local lines, meta = format.render_page(layout, 1, 50)
    buffer.render_dataset(lines, meta, { layout = layout, data = data })

    local win = D.dataset_window
    assert.is_not_nil(win)
    vim.api.nvim_set_current_win(win)

    -- Scroll right until the window actually scrolls horizontally.
    for _ = 1, 6 do nav.move_cell(0, 1) end
    local scrolled = vim.api.nvim_win_call(win, vim.fn.winsaveview).leftcol
    assert.is_true(scrolled > 0, "expected window to have scrolled horizontally")

    -- Scroll back to the first data column.
    for _ = 1, 10 do nav.move_cell(0, -1) end
    local leftcol = vim.api.nvim_win_call(win, vim.fn.winsaveview).leftcol
    assert.equals(0, leftcol, "leftcol must return to 0 so the row-number column is visible")
    assert.equals(1, state.cell.col)

    vim.o.columns = saved_columns
  end)

  it("keeps the cursor near the right edge while scrolling right", function()
    local saved_columns = vim.o.columns
    vim.o.columns = 60

    local format = require("poste-db.format")
    local buffer = require("poste-db.buffer")
    local cols = {}
    local row = {}
    for i = 1, 30 do
      cols[i] = { name = "c" .. i, type = "TEXT" }
      row[i] = "val" .. i .. string.rep("x", i)
    end
    local body = vim.json.encode({
      type = "resultset",
      total_rows = 1,
      results = {
        {
          columns = cols,
          rows = { row },
        },
      },
      connection = "postgres://localhost:5432/db",
      database = "db",
      dialect = "postgres",
    })
    local data = vim.json.decode(body)
    local layout = format.plan_resultset_layout(data)
    local lines, meta = format.render_page(layout, 1, 1)
    buffer.render_dataset(lines, meta, { layout = layout, data = data })

    local win = D.dataset_window
    assert.is_not_nil(win)
    vim.api.nvim_set_current_win(win)

    local tab = D.T()
    local col_starts = tab.buffer_col_starts[tab.meta.data_start_line]
    local function cursor_screen_col()
      local v = vim.fn.winsaveview()
      return col_starts[state.cell.col + 1].disp_start - v.leftcol
    end

    -- Walk right across the middle of the table (remaining columns still do
    -- not fit in the window), where the cursor used to snap back to the left
    -- edge on every scroll boundary.
    local prev_screen = cursor_screen_col()
    for _ = 1, 23 do
      nav.move_cell(0, 1)
      local screen = cursor_screen_col()
      assert.is_true(
        screen - prev_screen > -20,
        string.format("cursor teleported back to the left edge (screen col %d -> %d)", prev_screen, screen)
      )
      prev_screen = screen
    end

    assert.equals(24, state.cell.col)
    local scrolled = vim.api.nvim_win_call(win, vim.fn.winsaveview).leftcol
    assert.is_true(scrolled > 0, "expected the window to have scrolled horizontally")

    vim.o.columns = saved_columns
  end)

  it("keeps the header float aligned with data columns for multibyte names", function()
    local saved_columns = vim.o.columns
    vim.o.columns = 50

    local format = require("poste-db.format")
    local buffer = require("poste-db.buffer")
    local cols = {}
    local row = {}
    for i, name in ipairs({ "id", "姓名", "备注", "data", "extra", "订单号", "金额", "状态", "时间" }) do
      cols[i] = { name = name, type = "TEXT" }
      row[i] = "v" .. i .. string.rep("x", i)
    end
    local body = vim.json.encode({
      type = "resultset",
      total_rows = 1,
      results = {
        {
          columns = cols,
          rows = { row },
        },
      },
      connection = "postgres://localhost:5432/db",
      database = "db",
      dialect = "postgres",
    })
    local data = vim.json.decode(body)
    local layout = format.plan_resultset_layout(data)
    local lines, meta = format.render_page(layout, 1, 1)
    buffer.render_dataset(lines, meta, { layout = layout, data = data })

    local win = D.dataset_window
    assert.is_not_nil(win)
    vim.api.nvim_set_current_win(win)

    local tab = D.T()
    local cs = tab.buffer_col_starts[tab.meta.data_start_line]
    local win_width = vim.api.nvim_win_get_width(win)

    local function check_alignment(leftcol)
      pcall(vim.api.nvim_win_call, win, function()
        vim.fn.winrestview({ leftcol = leftcol })
      end)
      require("poste-db.buffer.header").update()
      local float_text = vim.api.nvim_buf_get_lines(
        require("poste-db.buffer.header")._test.float_buf(), 0, 1, false)[1]
      assert.is_not_nil(float_text, "header float must exist after scroll")

      local float_seps = {}
      for _, c in ipairs(nav._test.build_header_index(float_text)) do
        if c.sep then float_seps[#float_seps + 1] = c.ds end
      end

      -- Data row: each cell's leading │ sits at value start - 2 (two spaces
      -- of left padding plus the separator), in screen coordinates.
      local data_seps = {}
      for col = 1, tab.meta.col_count do
        local screen = cs[col].disp_start - 2 - leftcol
        if screen >= 0 and screen < win_width then
          data_seps[#data_seps + 1] = screen
        end
      end

      for _, s in ipairs(data_seps) do
        assert.is_true(
          vim.tbl_contains(float_seps, s),
          string.format("leftcol=%d: header float separator missing at screen col %d (float: %s, data: %s)",
            leftcol, s, table.concat(float_seps, ","), table.concat(data_seps, ","))
        )
      end
      for i, s in ipairs(float_seps) do
        local trailing = i == #float_seps and not vim.tbl_contains(data_seps, s)
        if not trailing then
          assert.is_true(
            vim.tbl_contains(data_seps, s),
            string.format("leftcol=%d: header float separator misplaced at screen col %d (float: %s, data: %s)",
              leftcol, s, table.concat(float_seps, ","), table.concat(data_seps, ","))
          )
        end
      end
      assert.is_true(#float_seps <= #data_seps + 1,
        string.format("leftcol=%d: header float has unexpected extra separators (float: %s, data: %s)",
          leftcol, table.concat(float_seps, ","), table.concat(data_seps, ",")))
    end

    -- Sweep viewport positions so multibyte columns straddle the window
    -- edges, where byte-vs-display drift used to break the alignment.
    for _, leftcol in ipairs({ 0, 8, 15, 22, 26, 30, 40, 55 }) do
      check_alignment(leftcol)
    end

    vim.o.columns = saved_columns
  end)
end)

describe("buffer_nav empty resultset", function()
  before_each(function()
    D.tabs = {}
    D.active_tab_idx = 0
    if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
      pcall(vim.api.nvim_win_close, D.dataset_window, true)
    end
    D.dataset_window = nil
    require("poste-db.buffer.header").close()
    state.cell = { row = 1, col = 1 }
  end)

  it("move_cell and position_cursor survive a 0-row resultset", function()
    local format = require("poste-db.format")
    local buffer = require("poste-db.buffer")
    local body = vim.json.encode({
      type = "resultset",
      total_rows = 0,
      results = {
        {
          columns = {
            { name = "day", type = "DATE" },
            { name = "event", type = "TEXT" },
            { name = "n", type = "BIGINT" },
          },
          rows = {},
        },
      },
      connection = "clickhouse://localhost:18123/playground",
      database = "playground",
      dialect = "clickhouse",
    })
    local data = vim.json.decode(body)
    local layout = format.plan_resultset_layout(data)
    local lines, meta = format.render_page(layout, 1, 50)
    assert.equals(0, meta.row_count or 0, "fixture must render 0 rows")
    buffer.render_dataset(lines, meta, { layout = layout, data = data })

    assert.is_not_nil(D.dataset_window)

    -- h/j/k/l on an empty table used to crash in position_cursor
    -- ("attempt to compare number with nil" on the col_starts lookup).
    local ok, err = pcall(nav.move_cell, 0, 1)
    assert.is_true(ok, "move_cell right crashed on empty resultset: " .. tostring(err))
    assert.same({ row = 1, col = 1 }, state.cell)

    assert.has_no_errors(function()
      nav.move_cell(0, -1)
      nav.move_cell(1, 0)
      nav.move_cell(-1, 0)
    end)

    -- goto_* handlers reach position_cursor directly, past the move_cell guard.
    assert.has_no_errors(function() nav.position_cursor(1, 2) end)

    -- gg used to focus the placeholder border line: move_cell and
    -- goto_last_row guard row_count==0 but goto_first_row did not.
    local win = D.dataset_window
    local before = vim.api.nvim_win_get_cursor(win)
    assert.has_no_errors(function() nav.goto_first_row() end)
    assert.same(before, vim.api.nvim_win_get_cursor(win))
  end)
end)

describe("buffer_nav column name guard", function()
  it("falls back to ? when a response has rows but no columns", function()
    -- K on a hand-made/truncated response used to index nil here.
    assert.equals("?", nav._test.column_name({ rows = { { 1 } } }, 1))
  end)

  it("uses the column name when present", function()
    assert.equals("id", nav._test.column_name({ columns = { { name = "id" } } }, 1))
    assert.equals("?", nav._test.column_name({ columns = {} }, 1))
  end)
end)
