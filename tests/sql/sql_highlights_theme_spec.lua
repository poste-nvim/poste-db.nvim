--- Two silent-drop bugs in the dataset highlight setup:
--- 1. `apply_highlight_overrides` only applies names present in its list, so a
---    group written to the terminal outside that list ignored `config.highlights`.
--- 2. `fg_of` treated fg==0 (pure black) as "missing" and substituted the
---    fallback palette, because 0 is truthy in Lua.
local state = require("poste-db.state")
local theme = require("poste-db.highlights.theme")

describe("highlights theme overrides", function()
  local saved_overrides

  before_each(function()
    saved_overrides = state.config.highlights
  end)

  after_each(function()
    state.config.highlights = saved_overrides
  end)

  it("lets config.highlights override the filter/search active groups", function()
    state.config.highlights = {
      PosteDbDatasetFilterActive = { fg = 0x112233, bold = true },
      PosteDbDatasetSearchActive = { fg = 0x445566 },
    }
    theme.setup()

    local filter = vim.api.nvim_get_hl(0, { name = "PosteDbDatasetFilterActive" })
    local search = vim.api.nvim_get_hl(0, { name = "PosteDbDatasetSearchActive" })
    assert.equals(0x112233, filter.fg)
    assert.equals(0x445566, search.fg)
  end)

  it("keeps a linked group's pure-black foreground instead of falling back", function()
    vim.api.nvim_set_hl(0, "PosteDbSpecBlackFg", { fg = 0x000000 })
    assert.equals(0, theme._test.fg_of("PosteDbSpecBlackFg", 0xabcdef))
  end)
end)
