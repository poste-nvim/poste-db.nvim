--- Dataset cell editor — orchestration module.
--- Re-exports the sub-module surface consumers actually call; the sub-modules
--- (cell.lua value ops, column.lua PK introspection, nav.lua interactive
--- editing) are the real implementations and use each other directly.

local cell = require("poste-db.editor.cell")
local column = require("poste-db.editor.column")
local nav = require("poste-db.editor.nav")

local M = {}

-- Re-export cell functions -------------------------------------------------
M.is_numeric_type          = cell.is_numeric_type
M.is_integer_type          = cell.is_integer_type
M.is_boolean_type          = cell.is_boolean_type
M.is_date_type             = cell.is_date_type
M.is_uuid_type             = cell.is_uuid_type
M.is_text_type             = cell.is_text_type
M.is_json_column           = cell.is_json_column
M.is_boolean_column        = cell.is_boolean_column
M.is_enum_column           = cell.is_enum_column
M.is_editable_field        = cell.is_editable_field
M.parse_value              = cell.parse_value
M.validate_value           = cell.validate_value
M.create_edit_state        = cell.create_edit_state
M.track_cell_edit          = cell.track_cell_edit
M.track_row_delete         = cell.track_row_delete
M.track_row_add            = cell.track_row_add
M.has_pending_changes      = cell.has_pending_changes
M.count_pending_changes    = cell.count_pending_changes
M.pending_changes_text     = cell.pending_changes_text
M.reset_edit_state         = cell.reset_edit_state
M.format_json_input        = cell.format_json_input
M.parse_json_input         = cell.parse_json_input

-- Re-export column functions ------------------------------------------------
-- has_join comes from cell.lua: the live edit guard (nav.lua) uses the cell
-- implementation, and column.lua carried a divergent weaker copy.
M.has_join                 = cell.has_join
M.ensure_primary_key       = column.ensure_primary_key
M.clear_pk_cache           = column.clear_pk_cache

-- Re-export nav functions ---------------------------------------------------
M.edit_cell                = nav.edit_cell
M.delete_row               = nav.delete_row
M.insert_row               = nav.insert_row
M.rollback_edits           = nav.rollback_edits

return M
