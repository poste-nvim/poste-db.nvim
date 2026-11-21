--- Schema cache invalidation is shared by three DDL paths. The AI-chat path
--- used to skip it entirely (dropped tables stayed in completion, new tables
--- stayed "not found" to diagnostics), so this spec pins the contract the
--- helper promises to all three callers.
local saved_completion = package.loaded["poste-db.completion.data"]
local saved_sem = package.loaded["poste-db.semantic_diagnostics"]

local schema_cache = require("poste-db.schema_cache")

describe("poste-db.schema_cache", function()
  local cleared, invalidated

  before_each(function()
    cleared = {}
    invalidated = {}
    package.loaded["poste-db.completion.data"] = {
      clear_cache = function(conn) cleared[#cleared + 1] = conn end,
    }
    package.loaded["poste-db.semantic_diagnostics"] = {
      invalidate = function(conn, db)
        invalidated[#invalidated + 1] = { conn, db }
      end,
    }
  end)

  after_each(function()
    package.loaded["poste-db.completion.data"] = saved_completion
    package.loaded["poste-db.semantic_diagnostics"] = saved_sem
  end)

  it("clears the completion cache for the connection the DDL ran on", function()
    schema_cache.invalidate("my-blog", "blog")
    assert.same({ "my-blog" }, cleared)
    assert.same({ { "my-blog", "blog" } }, invalidated)
  end)

  it("passes a nil database through, meaning every db of that connection", function()
    schema_cache.invalidate("my-blog", nil)
    assert.same({ "my-blog" }, cleared)
    assert.same({ { "my-blog", nil } }, invalidated)
  end)

  it("tolerates cache modules without the hook instead of breaking a DDL response", function()
    -- An optional module can resolve to a table that lacks the hook (or the
    -- binary paths that stub it may only carry part of the surface). A DDL
    -- response must not raise because of it.
    package.loaded["poste-db.completion.data"] = {}
    package.loaded["poste-db.semantic_diagnostics"] = {}
    local ok_completion, ok_diag = schema_cache.invalidate("my-blog", "blog")
    assert.is_true(ok_completion)
    assert.is_true(ok_diag)
    assert.same({}, cleared)
    assert.same({}, invalidated)
  end)
end)
