-- explain() opens the plan in the dataset panel — the same view a normal query
-- uses — instead of an introspection float. Stub the display seam and the
-- transport, then assert render_dataset receives a resultset render.
local render_calls = {}
local entry_calls = {}

package.loaded["poste-db.state"] = {
  find_poste_binary = function() return "/usr/bin/poste" end,
  context = {},
}
package.loaded["poste-db.context"] = {
  resolve_full_context = function()
    return { connection = "prod", database = "inventory" }
  end,
}
package.loaded["poste-db.connections"] = {
  get_connection_config = function() return { dialect = "mysql" } end,
  resolve_connection_url = function() return "mysql://u:p@host/inventory" end,
}
package.loaded["poste-db.statement"] = {
  extract_stmt_at_cursor = function() return "SELECT 1" end,
  extract_label = function() return nil end,
}
package.loaded["poste-db.dataset"] = {
  now_wall = function() return { sec = 0, nsec = 0 } end,
  new_entry = function(meta)
    entry_calls[#entry_calls + 1] = meta
    return {}
  end,
}
package.loaded["poste-db.exec_run"] = {
  run_sql = function()
    return {
      body = vim.json.encode({
        type = "resultset",
        results = { { columns = { { name = "id" } }, rows = { { 1 } } } },
        total_rows = 1,
      }),
    }
  end,
  first_error = function() return nil end,
}
package.loaded["poste-db.format"] = {
  format_dataset = function()
    return { "TABLE" }, { type = "resultset" }, { rows = {} }
  end,
}
package.loaded["poste-db.buffer"] = {
  render_dataset = function(lines, meta, opts)
    render_calls[#render_calls + 1] = { lines = lines, meta = meta, opts = opts }
  end,
}

local explain = require("poste-db.explain")

describe("explain dataset rendering", function()
  before_each(function()
    render_calls = {}
    entry_calls = {}
    package.loaded["poste-db.exec_run"].first_error = function() return nil end
  end)

  it("opens the plan through the dataset panel, not a float", function()
    explain.explain()
    assert.equals(1, #render_calls)
    local call = render_calls[1]
    assert.same({ "TABLE" }, call.lines)
    assert.equals("resultset", call.meta.type)
    assert.is_not_nil(call.opts.layout)
    -- The decoded body rides along as opts.data so cell preview / yank / sort
    -- read these rows rather than state.last_response.
    assert.equals("resultset", call.opts.data.type)
    assert.equals("EXPLAIN SELECT 1", call.opts.original_sql)
    -- ... and it starts its own request, so the plan never lands in the
    -- previous request's history slot.
    assert.equals(1, #entry_calls)
    assert.equals("EXPLAIN", entry_calls[1].label)
  end)

  it("notifies instead of rendering when the server rejects the EXPLAIN", function()
    package.loaded["poste-db.exec_run"].first_error = function() return "syntax error" end
    local notified
    local orig_notify = vim.notify
    vim.notify = function(msg) notified = msg end
    local ok = pcall(explain.explain)
    vim.notify = orig_notify
    assert.is_true(ok)
    assert.equals(0, #render_calls)
    assert.equals(0, #entry_calls)
    assert.truthy(notified and notified:find("syntax error"))
  end)
end)
