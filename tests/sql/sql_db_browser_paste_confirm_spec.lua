--- show_paste_confirm's settle contract: y confirms, and EVERY other way the
--- dialog can go away (n, q, <Esc>, WinLeave) counts as cancel.
describe("db_browser paste confirm", function()
  local copy_progress = require("poste-db.db_browser.copy_progress")

  local source = { conn = "a", db = "blog", dialect = "mysql" }
  local target = { conn = "b", db = "blog", dialect = "mysql" }
  local plan = { { kind = "table", orig = "users", final = "users" } }

  --- Open the confirm dialog and return its buffer (the new buffer that has
  --- the y/n/q keymaps — the backdrop float has none).
  local function open_confirm(on_confirm, on_cancel, use_plan)
    local before = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do before[b] = true end
    copy_progress.show_paste_confirm(source, target, use_plan or plan, nil, on_confirm, on_cancel)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if not before[b] and vim.fn.maparg("q", "n", false, true) ~= "" then
        -- maparg is buffer-local sensitive only via the current buffer; check
        -- this buffer directly instead
        local m = vim.api.nvim_buf_get_keymap(b, "n")
        for _, km in ipairs(m) do
          if km.lhs == "q" and km.callback then return b, km.callback end
        end
      end
    end
    error("paste-confirm dialog buffer not found")
  end

  it("runs on_confirm exactly once on y", function()
    local confirmed, cancelled = 0, 0
    local buf = open_confirm(function() confirmed = confirmed + 1 end,
      function() cancelled = cancelled + 1 end)
    local y_cb
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if km.lhs == "y" then y_cb = km.callback end
    end
    y_cb()
    assert.equals(1, confirmed, "y must confirm exactly once")
    assert.equals(0, cancelled, "confirm must not also cancel")
    assert.is_false(vim.api.nvim_buf_is_valid(buf), "the dialog closes after answering")
  end)

  it("runs on_cancel when the dialog is closed with q", function()
    local confirmed, cancelled = 0, 0
    local buf, q_cb = open_confirm(function() confirmed = confirmed + 1 end,
      function() cancelled = cancelled + 1 end)
    q_cb()
    assert.equals(1, cancelled, "q counts as cancel — exactly once")
    assert.equals(0, confirmed)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("does not double-fire when n closes the dialog", function()
    local cancelled = 0
    local buf = open_confirm(nil, function() cancelled = cancelled + 1 end)
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if km.lhs == "n" then km.callback() end
    end
    assert.equals(1, cancelled, "n must cancel exactly once (close+answer must not stack)")
  end)

  it("lists exactly 8 plan items without an 'and 0 more' line", function()
    -- The tail guard was `i >= 8`, which still fired after the eighth item
    -- had been fully listed: an exactly-8 plan gained "... and 0 more".
    local eight = {}
    for i = 1, 8 do
      eight[i] = { kind = "table", orig = "t" .. i, final = "t" .. i }
    end
    local buf, q_cb = open_confirm(function() end, function() end, eight)
    local joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    q_cb()
    assert.truthy(joined:find("t8", 1, true), "the eighth item is listed")
    assert.falsy(joined:find("and 0 more", 1, true),
      "an exactly-8 plan has no tail to summarize")
  end)

  it("summarizes the tail beyond 8 items as 'and N more'", function()
    local nine = {}
    for i = 1, 9 do
      nine[i] = { kind = "table", orig = "t" .. i, final = "t" .. i }
    end
    local buf, q_cb = open_confirm(function() end, function() end, nine)
    local joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    q_cb()
    assert.truthy(joined:find("and 1 more", 1, true))
  end)
end)
