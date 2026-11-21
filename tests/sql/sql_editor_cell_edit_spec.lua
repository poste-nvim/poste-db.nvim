--- `apply_cell_edit` is where a second edit to the same cell decides which
--- "original value" to keep. The and/or form there treated a boolean `false`
--- as absent and fell back to the row (already holding the first edit's value),
--- so revert restored the wrong thing. The public prompt flow cannot reach
--- that branch in a spec, hence the `_test` seam.
local nav = require("poste-db.editor.nav")

describe("editor apply_cell_edit original value", function()
  local saved_dataset = package.loaded["poste-db.dataset"]
  local saved_buffer = package.loaded["poste-db.buffer"]
  local tab

  before_each(function()
    tab = { layout = { rows = { {} } }, rows_source = {}, meta = nil }
    package.loaded["poste-db.dataset"] = {
      T = function() return tab end,
      dataset_buffer = nil,
    }
    package.loaded["poste-db.buffer"] = {
      refresh_winbar = function() end,
    }
  end)

  after_each(function()
    package.loaded["poste-db.dataset"] = saved_dataset
    package.loaded["poste-db.buffer"] = saved_buffer
  end)

  it("treats a boolean false original as the original when the cell returns to it", function()
    tab.layout.rows[1][1] = false

    nav._test.apply_cell_edit(tab, 1, 1, true)
    nav._test.apply_cell_edit(tab, 1, 1, false)

    -- false -> true -> false is a full revert: no pending modification. The
    -- and/or bug recorded old_val=true on the second edit, so the entry
    -- survived and revert restored true.
    assert.is_nil(tab.edit_state.modified_cells["1:1"])
    assert.is_false(tab.layout.rows[1][1])
    assert.is_false(tab.edit_state.dirty)
  end)

  it("keeps the boolean false original while the cell stays changed", function()
    tab.layout.rows[1][1] = false

    nav._test.apply_cell_edit(tab, 1, 1, true)
    nav._test.apply_cell_edit(tab, 1, 1, "other")

    local rec = tab.edit_state.modified_cells["1:1"]
    assert.is_false(rec.old_val)
    assert.equals("other", rec.new_val)
  end)
end)
