--- Item 21: a second introspect lookup must replace the DDL float, not stack a
--- new one or re-focus the stale one.
local introspect = require("poste-db.introspect")

local function float_wins()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok and cfg.relative and cfg.relative ~= "" then table.insert(out, win) end
  end
  return out
end

local function current_float_text()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  return buf, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

describe("introspect DDL float", function()
  after_each(function()
    for _, win in ipairs(float_wins()) do pcall(vim.api.nvim_win_close, win, true) end
  end)

  it("replaces the open float instead of stacking a second one", function()
    local base = #float_wins()
    introspect.show_float({ "CREATE TABLE a (id int);" }, " ddl: a ", "sql")
    local after_first = #float_wins()
    assert.truthy(after_first > base)

    local old_buf = current_float_text()
    introspect.show_float({ "CREATE TABLE b (id int);" }, " ddl: b ", "sql")

    assert.equals(after_first, #float_wins())
    local buf, text = current_float_text()
    assert.truthy(text:find("CREATE TABLE b", 1, true))
    assert.is_falsy(text:find("CREATE TABLE a", 1, true))
    -- the replaced float's buffer is wiped, not left listed behind the window
    assert.is_false(vim.api.nvim_buf_is_valid(old_buf))
    assert.are_not.equal(old_buf, buf)
  end)

  it("re-opens after the float was closed with its own q binding", function()
    introspect.show_float({ "CREATE TABLE c (id int);" }, " ddl: c ", "sql")
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "q" and m.callback then m.callback() break end
    end
    assert.is_false(vim.api.nvim_win_is_valid(win))

    introspect.show_float({ "CREATE TABLE d (id int);" }, " ddl: d ", "sql")
    local _, text = current_float_text()
    assert.truthy(text:find("CREATE TABLE d", 1, true))
  end)

  it("a stale async completion does not overwrite a newer lookup", function()
    -- show_float REPLACES the previous float, and whichever job finished LAST
    -- used to win: trigger on table a, then on b before a returns, and a's
    -- slow answer could repaint over b's. Entry tokens guard the delivery.
    local token_a = introspect.next_float_token()
    local token_b = introspect.next_float_token()

    introspect.show_float_if_current(token_b, { "CREATE TABLE b (id int);" }, " ddl: b ", "sql")
    local _, text_b = current_float_text()
    assert.truthy(text_b:find("CREATE TABLE b", 1, true), "the current token paints")

    introspect.show_float_if_current(token_a, { "CREATE TABLE a (id int);" }, " ddl: a ", "sql")
    local _, text = current_float_text()
    assert.truthy(text:find("CREATE TABLE b", 1, true), "the stale token is dropped")
    assert.is_falsy(text:find("CREATE TABLE a", 1, true))

    -- A direct show_float (synchronous caller) retires in-flight jobs too.
    introspect.show_float_if_current(token_a, { "CREATE TABLE x" }, " ddl: x ", "sql")
    local _, text_x = current_float_text()
    assert.is_falsy(text_x:find("CREATE TABLE x", 1, true))
  end)
end)
