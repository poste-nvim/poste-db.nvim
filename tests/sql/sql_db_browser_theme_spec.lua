-- Pins db_browser/theme's two subtle behaviors:
--   1. A spec (and a registration) that is a FUNCTION is evaluated per apply
--      (dark/light-aware palettes like icons.lua).
--   2. A spec function that returns nil SKIPS the group. The naive
--      `cond and f() or f` fallback used to pass the raw function to
--      nvim_set_hl here; the explicit `if value then` must not set a group
--      whose function legitimately says "skip" (see AGENTS.md "and f() or f
--      is not a ternary").

local saved_state = package.loaded["poste-db.state"]
local saved_set_hl = vim.api.nvim_set_hl
local saved_create_autocmd = vim.api.nvim_create_autocmd

local set_hl_calls = {}
local override_names = nil

package.loaded["poste-db.state"] = {
  apply_highlight_overrides = function(names) override_names = names end,
}

vim.api.nvim_set_hl = function(ns, name, value)
  set_hl_calls[#set_hl_calls + 1] = { name = name, value = value }
end
vim.api.nvim_create_autocmd = function() return 42 end

package.loaded["poste-db.db_browser.theme"] = nil
local theme = require("poste-db.db_browser.theme")

-- `registrations` is module-local and only grows, so assertions are by
-- membership (and by the value under each name) rather than by call order:
-- every register() re-applies the whole set, which would make order-sensitive
-- checks depend on which tests ran before.
local function applied_names()
  local set = {}
  for _, call in ipairs(set_hl_calls) do set[call.name] = call.value end
  return set
end

local function override_set()
  local set = {}
  for _, name in ipairs(override_names or {}) do set[name] = true end
  return set
end

describe("db_browser theme register/apply", function()
  before_each(function()
    set_hl_calls = {}
    override_names = nil
  end)

  it("sets a plain spec table and a function spec that returns a table", function()
    theme.register({
      Plain = { fg = "red" },
      Fn = function() return { bg = "blue" } end,
    })

    local names = applied_names()
    assert.same({ fg = "red" }, names.Plain)
    assert.same({ bg = "blue" }, names.Fn)
  end)

  it("skips a group whose spec function returns nil", function()
    theme.register({
      Kept = { fg = "green" },
      Skipped = function() return nil end,
    })

    local names = applied_names()
    assert.is_truthy(names.Kept, "the kept spec must be set")
    assert.is_nil(names.Skipped, "the nil-returning spec must not call nvim_set_hl")
  end)

  it("evaluates a function registration to its group map", function()
    theme.register(function()
      return { Dyn = { link = "X" } }
    end)

    local names = applied_names()
    assert.same({ link = "X" }, names.Dyn)
  end)

  it("hands only the applied (non-skipped) names to apply_highlight_overrides", function()
    theme.register({
      A = { fg = "1" },
      Skip = function() return nil end,
      B = { fg = "2" },
    })

    local set = override_set()
    assert.is_truthy(set.A)
    assert.is_truthy(set.B)
    assert.is_nil(set.Skip, "a skipped group must not reach the overrides pass")
  end)
end)

-- Restore at file scope, matching the house convention: theme holds its
-- registrations in a module-local table, so a mid-file restore would let
-- later requires re-apply against the real state module.
package.loaded["poste-db.state"] = saved_state
vim.api.nvim_set_hl = saved_set_hl
vim.api.nvim_create_autocmd = saved_create_autocmd
