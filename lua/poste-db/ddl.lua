--- DDL classification --- is the first real statement of a blob schema-changing?
---
--- Dependency-free on purpose: the SQL runner uses it to invalidate cache
--- state after a response, and the AI chat uses it to do the same for code
--- blocks it executed. Keeping it in `sql_runner/response.lua` would have made
--- every caller drag in the whole render pipeline (dataset, buffer, format…).
local M = {}

--- True when the first real statement of `sql` is DDL (CREATE/ALTER/DROP/
--- TRUNCATE/RENAME). Leading `-- @connection` directives, `###` section
--- markers, blank lines and comment lines are skipped before inspecting the
--- keyword, because buf_content (and visual blocks) carry that noise.
--- The keyword test is case-insensitive: SQL keywords are not case-sensitive,
--- and the family's own CREATE TABLE template (db_browser/operations.lua)
--- inserts lowercase `create table` — an exact-case match would skip the
--- completion/diagnostics cache invalidation for every statement written
--- from that template.
--- @param sql string|nil
--- @return boolean
function M.is_ddl(sql)
  if not sql then return false end
  for _, ln in ipairs(vim.split(sql, "\n", { plain = true })) do
    local t = ln:match("^%s*(.*)%s*$") or ""
    if t ~= "" and not t:match("^%-%-") and not t:match("^###") then
      local kw = t:lower()
      return kw:match("^create%s") ~= nil
        or kw:match("^alter%s") ~= nil
        or kw:match("^drop%s") ~= nil
        or kw:match("^truncate%s") ~= nil
        or kw:match("^rename%s") ~= nil
    end
  end
  return false
end

return M
