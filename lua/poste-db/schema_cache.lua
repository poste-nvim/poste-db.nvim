--- Schema cache invalidation --- the one place that knows which caches a DDL
--- statement makes stale.
---
--- Three DDL execution paths exist: the SQL runner's response hook
--- (`sql_runner/response.lua`), browser-side DDL (`db_browser/util.lua`) and
--- AI-chat code blocks (`ai/actions.lua`). Each used to spell the invalidation
--- out inline; the AI path simply forgot it, so a table created or dropped in
--- chat stayed "unknown" to completion, diagnostics and the AI's own auto
--- context for the rest of the session.
---
--- Both requires below are lazy and pcall'd on purpose: specs stub
--- `poste-db.completion.data` / `poste-db.semantic_diagnostics` through
--- `package.loaded`, and an absent optional module must never turn a DDL
--- response into an error.
local M = {}

--- Invalidate the completion and semantic-diagnostics schema caches after a
--- DDL statement. `conn`/`db` are the connection and database the DDL actually
--- ran on — never "the focused buffer's": a response can land after the user
--- switched files, and an AI code block runs against its own resolved target.
---
--- @param conn string|nil connection the DDL ran on
--- @param db string|nil database the DDL ran on (nil invalidates every database of `conn`)
--- @return boolean completion_invalidated
--- @return boolean diagnostics_invalidated
function M.invalidate(conn, db)
  local completion_ok, completion = pcall(require, "poste-db.completion.data")
  if completion_ok and completion.clear_cache then
    completion.clear_cache(conn)
  end

  local diagnostics_ok, diagnostics = pcall(require, "poste-db.semantic_diagnostics")
  if diagnostics_ok and diagnostics.invalidate then
    diagnostics.invalidate(conn, db)
  end

  return completion_ok, diagnostics_ok
end

return M
