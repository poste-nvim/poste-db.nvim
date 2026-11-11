-- Request-scoped SQL session lifecycle. `begin` is the seam where a run
-- clears last_response / last_dataset / cell while deliberately leaving the
-- connection/database binding in place — the split that lets a `USE` persist
-- across runs but never leaks one run's resultset into the next.
local session = require("poste-db.session")
local state = require("poste-db.state")

describe("session.new", function()
  it("builds an empty session with no meta", function()
    local s = session.new()
    assert.is_table(s)
    assert.is_nil(s.response)
    assert.is_nil(s.dataset)
    assert.same({}, s.meta)
  end)

  it("preserves the caller's meta", function()
    local s = session.new({ buf = 1, line = 4, file = "/tmp/x.sql" })
    assert.same({ buf = 1, line = 4, file = "/tmp/x.sql" }, s.meta)
  end)
end)

describe("session.begin", function()
  it("clears request-scoped state but keeps the returned meta", function()
    state.last_response = { body = "{}" }
    state.last_dataset = { rows = { 1 } }
    state.cell = { row = 9, col = 9 }

    local s = session.begin({ buf = 7 })

    assert.is_nil(state.last_response)
    assert.is_nil(state.last_dataset)
    assert.same({ row = 1, col = 1 }, state.cell)
    assert.same({ buf = 7 }, s.meta)

    -- restore: other specs in this process rely on the cleared defaults
    state.last_response = nil
    state.last_dataset = nil
    state.cell = { row = 1, col = 1 }
  end)

  it("resets the cell cursor to the top-left corner", function()
    state.cell = { row = 5, col = 3 }
    session.begin()
    assert.same({ row = 1, col = 1 }, state.cell)
  end)
end)
