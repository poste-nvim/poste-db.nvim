--- Item 20: setup() must be idempotent and must read the *merged* config.
local init = require("poste-db.init")
local config = require("poste-db.config")

local function n_autocmds(filter)
  return #vim.api.nvim_get_autocmds(filter)
end

local function clear_filter_mapped()
  return vim.fn.maparg("<leader>cr", "n", false, false) ~= ""
end

describe("poste-db setup idempotence", function()
  local saved_clear_filter

  before_each(function()
    saved_clear_filter = config.config.keymaps.sql_source.clear_filter
  end)

  after_each(function()
    config.merge({ keymaps = { sql_source = { clear_filter = saved_clear_filter } } })
    init.setup()
  end)

  it("does not register the source keymap at module load", function()
    -- requires the map to come from setup(), not from `require("poste-db.init")`
    config.merge({ keymaps = { sql_source = { clear_filter = false } } })
    init.setup()
    assert.is_false(clear_filter_mapped())
  end)

  it("registers the clear-filter keymap from the merged config", function()
    config.merge({ keymaps = { sql_source = { clear_filter = "<leader>cr" } } })
    init.setup()
    assert.is_true(clear_filter_mapped())
  end)

  it("keeps one autocmd per event across repeated setup() calls", function()
    init.setup()
    local grouped = n_autocmds({ group = "PosteDbAutocmds" })
    local file_type = n_autocmds({ event = "FileType" })
    local color_scheme = n_autocmds({ event = "ColorScheme" })
    assert.is_true(grouped >= 4)

    init.setup()
    assert.equals(grouped, n_autocmds({ group = "PosteDbAutocmds" }))
    assert.equals(file_type, n_autocmds({ event = "FileType" }))
    assert.equals(color_scheme, n_autocmds({ event = "ColorScheme" }))
  end)
end)

describe("poste-db config merge", function()
  local saved_formatters

  before_each(function()
    saved_formatters = vim.deepcopy(config.config.sql_formatters)
  end)

  after_each(function()
    config.config.sql_formatters = saved_formatters
  end)

  it("replaces a list-valued option instead of index-merging it", function()
    -- tbl_deep_extend("force") merges arrays by index: the user's shorter
    -- list used to keep the excluded defaults as fallbacks (source_format
    -- picks a formatter from this list) with the new entry duplicated last.
    config.merge({ sql_formatters = { "pg_format" } })
    assert.same({ "pg_format" }, config.config.sql_formatters)
  end)

  it("still deep-merges map-valued options like keymaps", function()
    local saved_run = config.config.keymaps.sql_source.run
    config.merge({ keymaps = { sql_source = { run = "<space>" } } })
    assert.equals("<space>", config.config.keymaps.sql_source.run)
    assert.is_not_nil(config.config.keymaps.sql_source.show_ddl,
      "siblings outside the merge must keep their defaults")
    config.config.keymaps.sql_source.run = saved_run
  end)
end)
