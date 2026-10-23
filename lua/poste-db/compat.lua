--- PosteDb compatibility shims.
---
--- Bridges renamed user-facing globals from the legacy `poste_sql_*` names to
--- the current `poste_db_*` names. `opt()` prefers the new key and falls back
--- to the deprecated old key with a one-time deprecation warning.
---
--- Covered globals:
---   config, debug, legacy_completion, dialect, autoformat

local const = require("poste-db.constants")
local M = {}

local SUPPORTED = {
  config = true,
  debug = true,
  legacy_completion = true,
  dialect = true,
  autoformat = true,
}

local warned = {}

--- Read a PosteDb global. New key `g:poste_db_<name>` wins; falls back to the
--- deprecated `g:poste_sql_<name>` (one-time warning when the old key is used).
--- @param name string  one of the SUPPORTED names
--- @return any  nil when neither key is set
function M.opt(name)
  if not SUPPORTED[name] then
    error("poste-db.compat: unsupported key '" .. tostring(name) .. "'", 2)
  end
  local new_key = "poste_db_" .. name
  local old_key = "poste_sql_" .. name
  if vim.g[new_key] ~= nil then return vim.g[new_key] end
  if vim.g[old_key] ~= nil then
    if not warned[old_key] then
      warned[old_key] = true
      vim.notify(
        string.format("poste-db: `g:%s` is deprecated, use `g:%s`", old_key, new_key),
        vim.log.levels.WARN,
        { title = const.PLUGIN_TITLE }
      )
    end
    return vim.g[old_key]
  end
  return nil
end

--- Write a PosteDb global (new key only; old key is left untouched).
--- @param name string  one of the SUPPORTED names
--- @param value any  nil clears the key
function M.set(name, value)
  if not SUPPORTED[name] then
    error("poste-db.compat: unsupported key '" .. tostring(name) .. "'", 2)
  end
  vim.g["poste_db_" .. name] = value
end

return M