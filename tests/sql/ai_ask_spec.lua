describe("poste-db.ai ask entry points", function()
  local ai = require("poste-db.ai")
  local state_sql = require("poste-db.state")

  before_each(function()
    state_sql.last_error = nil
    state_sql.last_dataset = nil
  end)

  after_each(function()
    pcall(function() require("poste-ai.chat.window").close() end)
    pcall(function() require("poste-ai.chat.scope").clear() end)
    state_sql.last_error = nil
    state_sql.last_dataset = nil
  end)

  it("prefills the chat with the failed sql + error and scopes the target", function()
    if not ai.available() then
      pending("poste-ai.nvim not on rtp")
      return
    end
    state_sql.last_error = {
      message = 'relation "missing" does not exist',
      sql = "SELECT * FROM missing",
      connection = "my-blog", database = "blog", at = os.time(),
    }
    ai.ask_last_error()
    local window = require("poste-ai.chat.window")
    local text = window.input_text()
    assert.truthy(text:find("This SQL failed"))
    assert.truthy(text:find("SELECT %* FROM missing"))
    assert.truthy(text:find('relation "missing" does not exist'))
    local scope = require("poste-ai.chat.scope")
    assert.are.same({ connection = "my-blog", database = "blog" }, scope.snapshot())
    window.close()
  end)

  it("builds a markdown table from the last resultset", function()
    if not ai.available() then
      pending("poste-ai.nvim not on rtp")
      return
    end
    state_sql.last_dataset = {
      type = "resultset",
      results = { {
        columns = { { name = "id" }, { name = "name" } },
        rows = { { 1, "ann" }, { 2, "bob" } },
        original_sql = "SELECT id, name FROM users",
      } },
    }
    ai.ask_resultset()
    local text = require("poste-ai.chat.window").input_text()
    assert.truthy(text:find("Help me interpret this result set"))
    assert.truthy(text:find("| id | name |"))
    assert.truthy(text:find("| 1 | ann |"))
    assert.truthy(text:find("SELECT id, name FROM users"))
    require("poste-ai.chat.window").close()
  end)

  it("truncates long resultsets", function()
    if not ai.available() then
      pending("poste-ai.nvim not on rtp")
      return
    end
    local rows = {}
    for i = 1, 25 do rows[i] = { i, "row" .. i } end
    state_sql.last_dataset = {
      type = "resultset",
      results = { { columns = { { name = "id" }, { name = "label" } }, rows = rows } },
    }
    ai.ask_resultset()
    local text = require("poste-ai.chat.window").input_text()
    assert.truthy(text:find("%(20 of 25 rows shown%)"))
    assert.falsy(text:find("| 21 | row21 |"))
    require("poste-ai.chat.window").close()
  end)

  it("truncates long CJK cell values on a character boundary", function()
    if not ai.available() then
      pending("poste-ai.nvim not on rtp")
      return
    end
    -- "x" + 40 × U+8700 = 121 bytes, so the 57-byte budget lands in the MIDDLE of
    -- a character: the old byte-based sub(1, 57) emitted a half character
    -- (invalid UTF-8) to the provider
    local long = "x" .. string.rep("蜀", 40)
    state_sql.last_dataset = {
      type = "resultset",
      results = { {
        columns = { { name = "name" } },
        rows = { { long } },
        original_sql = "SELECT name FROM t",
      } },
    }
    ai.ask_resultset()
    local text = require("poste-ai.chat.window").input_text()
    local cell
    for l in text:gmatch("[^\n]+") do
      if l:match("^%| x") then cell = l:match("^%| (.-) %|$") break end
    end
    assert.truthy(cell, "truncated CJK cell present")
    local trimmed = cell:gsub("%.%.%.$", "")
    assert.equals(cell .. "", trimmed .. "...", "cell ends with the ellipsis")
    assert.is_true(#trimmed <= 57, "byte budget respected")
    assert.equals(trimmed, vim.fn.iconv(trimmed, "utf-8", "utf-8"),
      "cell must be valid UTF-8 — a byte-based cut emits a half character")
    require("poste-ai.chat.window").close()
  end)

  it("ask_view notifies when there is nothing to ask about", function()
    local window = require("poste-ai.chat.window")
    window.close()
    ai.ask_view()
    assert.is_false(window.is_open())
  end)

  describe("ask_node (db browser)", function()
    it("builds a table mention and prefills the chat", function()
      if not ai.available() then
        pending("poste-ai.nvim not on rtp")
        return
      end
      ai.ask_node({ node_type = "table", name = "users", meta = { connection = "my-blog", database = "blog" } })
      local window = require("poste-ai.chat.window")
      assert.is_true(window.is_open())
      assert.truthy(window.input_text():find("@my%-blog/blog/users "))
      window.close()
    end)

    it("builds a database mention for database nodes", function()
      if not ai.available() then
        pending("poste-ai.nvim not on rtp")
        return
      end
      ai.ask_node({ node_type = "database", name = "blog", meta = { connection = "my-blog" } })
      local window = require("poste-ai.chat.window")
      assert.truthy(window.input_text():find("@my%-blog/blog "))
      window.close()
    end)

    it("notifies on non-mentionable nodes without opening the chat", function()
      local window = require("poste-ai.chat.window")
      window.close()
      ai.ask_node({ node_type = "column", name = "id", meta = { connection = "my-blog" } })
      assert.is_false(window.is_open())
    end)
  end)

  it("ask_view routes to the resultset when one exists", function()
    if not ai.available() then
      pending("poste-ai.nvim not on rtp")
      return
    end
    state_sql.last_dataset = {
      type = "resultset",
      results = { { columns = { { name = "id" } }, rows = { { 1 } } } },
    }
    ai.ask_view()
    local window = require("poste-ai.chat.window")
    assert.is_true(window.is_open())
    assert.truthy(window.input_text():find("Help me interpret"))
    window.close()
  end)
end)
