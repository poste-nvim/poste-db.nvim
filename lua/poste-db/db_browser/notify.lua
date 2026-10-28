--- Non-blocking notification facade for DB Browser.
---
--- `vim.notify(…, INFO/WARN)` writes to the message area, which parks a
--- "Press ENTER" prompt before the next command. db_browser's routine feedback
--- goes through this module instead so it never blocks the user: INFO/WARN are
--- shown as auto-dismissing flash floats. ERROR stays on `vim.notify` so real
--- failures remain visible in the message area.

local flash = require("poste-db.db_browser.flash")

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

-- Failures are notified directly with vim.notify(..., ERROR, { title =
-- PLUGIN_TITLE }) at every call site — no facade. Keep it that way until a
-- real M.error with callers lands; the one this file used to carry had none.

return M