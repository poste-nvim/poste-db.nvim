--- DB Browser top-level connection order — load_connections used to build its
--- nodes straight from pairs() over the parsed toml, so the browser reshuffled
--- every time connections.toml was rewritten (the same churn the connection
--- picker's list_connections already fixed at its source).
local saved_util = package.loaded["poste-db.util"]
local saved_toml = package.loaded["poste-db.toml"]
local saved_state = package.loaded["poste-db.state"]
local saved_tree = package.loaded["poste-db.db_browser.tree"]
local saved_async = package.loaded["poste-db.async"]

local fake_toml = {}

package.loaded["poste-db.util"] = {
  find_file_upwards = function() return "/fake/connections.toml" end,
  named = (saved_util or require("poste-db.util")).named,
}
package.loaded["poste-db.toml"] = {
  parse_file = function() return fake_toml, nil end,
}
package.loaded["poste-db.state"] = { log = function() end }
-- Stub the tree module: the real one pulls in theme/highlights that need
-- full plugin state these bare stubs cannot provide.
package.loaded["poste-db.db_browser.tree"] = {
  make_connection_node = function(entry)
    return { node_type = "connection", name = entry.name }
  end,
}
package.loaded["poste-db.async"] = { run = function() return nil end }

package.loaded["poste-db.db_browser.async"] = nil
local browser_async = require("poste-db.db_browser.async")

--- Drain the vim.schedule load_connections wraps its callback in.
local function flush()
  vim.wait(100, function() return false end)
end

describe("db_browser load_connections", function()
  before_each(function()
    fake_toml = {}
  end)

  it("lists connections in a stable, sorted order", function()
    fake_toml = {
      zeta = { dialect = "postgres" },
      alpha = { dialect = "mysql" },
      mid = { dialect = "sqlite", path = "/tmp/x.sqlite" },
    }
    local nodes
    browser_async.load_connections(function(result) nodes = result end, "/fake/dir")
    flush()
    local names = {}
    for _, n in ipairs(nodes) do names[#names + 1] = n.name end
    assert.same({ "alpha", "mid", "zeta" }, names)
  end)

  it("skips non-SQL satellite sections regardless of order", function()
    fake_toml = {
      cache_redis = { dialect = "redis" },
      main = { dialect = "postgres" },
    }
    local nodes
    browser_async.load_connections(function(result) nodes = result end, "/fake/dir")
    flush()
    local names = {}
    for _, n in ipairs(nodes) do names[#names + 1] = n.name end
    assert.same({ "main" }, names)
  end)
end)

-- Restored at file scope, not after_each: load_connections re-resolves its
-- lazy requires (util/toml) through package.loaded on every call, so a
-- mid-file restore would silently hand the later tests the real modules.
package.loaded["poste-db.util"] = saved_util
package.loaded["poste-db.toml"] = saved_toml
package.loaded["poste-db.state"] = saved_state
package.loaded["poste-db.db_browser.tree"] = saved_tree
package.loaded["poste-db.async"] = saved_async
