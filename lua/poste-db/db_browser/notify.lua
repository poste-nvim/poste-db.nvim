--- Non-blocking notification facade for DB Browser.
---
--- `vim.notify(…, INFO/WARN)` writes to the message area, which parks a
--- "Press ENTER" prompt before the next command. db_browser's routine feedback
--- goes through this module instead so it never blocks the user: INFO/WARN are
--- shown as auto-dismissing flash floats. ERROR stays on `vim.notify` so real
--- failures remain visible in the message area.

local flash = require("poste-db.db_browser.flash")
local const = require("poste-db.constants")

local M = {}

--- Routine / informational feedback — never blocks.
---@param msg string
function M.info(msg)
  flash.flash(msg, 2)
end

--- Warning feedback — never blocks.
---@param msg string
function M.warn(msg)
  flash.flash(msg, 3)
end

--- Genuine failures stay blocking (message area, needs ENTER to dismiss).
---@param msg string
function M.error(msg)
  vim.notify(msg, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
end

return M