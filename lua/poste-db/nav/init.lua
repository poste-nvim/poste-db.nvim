local detect = require("poste-db.nav.detect")
local handlers = require("poste-db.nav.handlers")
local route = require("poste-db.nav.route")
local const = require("poste-db.constants")

local M = {}

function M.goto_definition()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""
  local target = route.resolve_definition_route(line_text)
  if not target then
    -- resolve_definition_route only returns nil when <cword> is empty (the
    -- directives and the table word all return before that), so the message
    -- names the real cause — this used to say "add a @connection header",
    -- which the user cannot fix by adding one.
    vim.notify("No word under cursor", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return
  end

  if target.kind == "connection" then
    handlers.handle_connection_directive(buf, target.conn_name)
    return
  end
  if target.kind == "database" then
    handlers.handle_database_directive(buf, line_num, target.db_name)
    return
  end
  if target.kind == "table" then
    local ctx = require("poste-db.context")
    local full_ctx = ctx.resolve_full_context(buf, line_num)
    handlers.handle_table_reference(buf, line_num, line_text, cursor, full_ctx, target.table_name)
  end
end

M._test = {
  resolve_detected_table_target = detect.resolve_detected_table_target,
}

return M
