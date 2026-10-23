--- Slash commands for the "db" AI context — exposed through poste-ai's
--- command palette (typed "/" in the chat input):
---   /connections  scope the chat to a connection (connections.toml)
---   /databases    further scope it to a database of that connection
--- The chosen binding is displayed above the chat input, persisted per
--- message, injected into the system prompt and used as the default SQL
--- execution target (ai/actions.lua resolve_target).

local const = require("poste-db.constants")
local M = {}

--- Databases hidden from /databases (same skip list as the db browser).
local SKIP_DATABASES = {
  information_schema = true, mysql = true,
  performance_schema = true, sys = true,
  template0 = true, template1 = true,
}

--- /connections — candidates from connections.toml (async).
--- @param prefix string filter by label prefix
--- @param _scope table current chat scope (unused)
--- @param cb function(candidates)
function M.complete_connections(prefix, _scope, cb)
  local connections = require("poste-db.connections")
  connections.list_connections(function(list)
    local items = {}
    local prefix_l = prefix:lower()
    for _, c in ipairs(list or {}) do
      local desc = c.dialect or ""
      if c.host and c.host ~= "" then
        desc = desc .. " " .. c.host
      elseif c.path and c.path ~= "" then
        desc = desc .. " " .. c.path
      end
      if c.name:lower():sub(1, #prefix) == prefix_l then
        items[#items + 1] = { label = c.name, description = desc }
      end
    end
    cb(items)
  end)
end

--- /databases — candidates for the scoped connection via poste introspect.
--- Requires a connection picked with /connections first.
--- @param prefix string filter by label prefix
--- @param scope table current chat scope snapshot
--- @param cb function(candidates)
function M.complete_databases(prefix, scope, cb)
  local conn = scope and scope.connection
  if not conn then
    vim.notify("Pick a connection first with /connections", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    cb({})
    return
  end
  local async = require("poste-db.db_browser.async")
  async.run_introspect(conn, "databases", nil, nil, nil, function(parsed)
    local items = {}
    local prefix_l = prefix:lower()
    if type(parsed) == "table" and type(parsed.items) == "table" then
      for _, item in ipairs(parsed.items) do
        if type(item) == "table" and item.name and not SKIP_DATABASES[item.name]
          and item.name:lower():sub(1, #prefix) == prefix_l then
          items[#items + 1] = { label = item.name, description = conn }
        end
      end
    end
    cb(items)
  end)
end

--- The commands table handed to poste-ai's context contract.
--- @return table
function M.list()
  local icons = require("poste-db.db_browser.icons").ICONS
  return {
    {
      name = "connections",
      desc = "scope this chat to a connection",
      complete = function(prefix, scope, cb) M.complete_connections(prefix, scope, cb) end,
      run = function(item, api)
        if item and item.label then api.set_scope("connection", item.label, icons.connection) end
      end,
    },
    {
      name = "databases",
      desc = "scope this chat to a database within the connection",
      complete = function(prefix, scope, cb) M.complete_databases(prefix, scope, cb) end,
      run = function(item, api)
        if item and item.label then api.set_scope("database", item.label, icons.database) end
      end,
    },
  }
end

M._test = {
  SKIP_DATABASES = SKIP_DATABASES,
  complete_connections = M.complete_connections,
  complete_databases = M.complete_databases,
}

return M
