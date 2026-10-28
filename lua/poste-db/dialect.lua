--- Resolve the SQL dialect for a buffer. ONE copy for every consumer.
---
--- diagnostics.lua and syntax.lua used to carry byte-identical get_dialect()
--- copies, and source_format.resolve_dialect a drifting fork that silently
--- dropped the g:poste_db_dialect fallback — formatters then picked their
--- own default dialect while diagnostics honored the user's choice.
---
--- Chain: `### dialect <name>` header → connection config →
--- g:poste_db_dialect → filetype (poste_sqlite → sqlite).
local context = require("poste-db.context")
local connections = require("poste-db.connections")
local sql_state = require("poste-db.state")
local compat = require("poste-db.compat")

local M = {}

--- @param buf number buffer handle
--- @return string|nil dialect lowercase, nil when nothing resolves
function M.dialect_for_buf(buf)
  -- `### dialect <name>` header in the first 20 lines wins
  local lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(20, vim.api.nvim_buf_line_count(buf)), false)
  for _, line in ipairs(lines) do
    local d = line:match("^### dialect%s+(%S+)")
    if d then return d:lower() end
  end

  -- Resolve from the connection config
  local ctx = context.resolve_context(buf)
  local conn = ctx.connection
  if not conn then
    conn = sql_state and sql_state.context and sql_state.context.connection
  end
  if conn then
    local cfg = connections.get_connection_config(conn)
    if cfg and cfg.dialect and cfg.dialect ~= "" then
      return cfg.dialect:lower()
    end
  end

  -- Global dialect option
  local global_dialect = compat.opt("dialect")
  if global_dialect and global_dialect ~= "" then
    return global_dialect:lower()
  end

  -- Filetype
  if vim.bo[buf].filetype == "poste_sqlite" then
    return "sqlite"
  end

  return nil
end

return M
