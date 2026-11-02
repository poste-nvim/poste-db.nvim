--- Highlight groups and extmark application for SQL dataset buffer.
local theme = require("poste-db.highlights.theme")
local render = require("poste-db.highlights.render")

local M = {}

function M.setup()
  theme.setup()
end

M.apply_dataset_highlights = render.apply_dataset_highlights
M.find_cell_range = render.find_cell_range
M.find_cell_ranges = render.find_cell_ranges
M.highlight_cell = render.highlight_cell
M.clear_cell_highlight = render.clear_cell_highlight
M.apply_edit_highlights = render.apply_edit_highlights
M.clear_edit_highlights = render.clear_edit_highlights

return M
