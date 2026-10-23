--- SQL request session lifecycle (Phase 2b / F5).
---
--- Each `run_sql_request()` creates a fresh Session at entry and clears
--- request-scoped dataset/response state. Connection/database context is
--- intentionally persistent across runs.

local M = {}

--- @param meta? table  { buf, line, file }
--- @return table
function M.new(meta)
  return {
    response = nil,
    dataset = nil,
    meta = meta or {},
  }
end

--- Begin a fresh SQL session; clears request-scoped dataset state.
--- @param meta? table
--- @return table
function M.begin(meta)
  local state = require("poste-db.state")
  local session = M.new(meta)

  -- Request-scoped clear (connection/database context intentionally kept)
  state.last_response = nil
  state.last_dataset = nil
  state.cell = { row = 1, col = 1 }

  return session
end

return M
