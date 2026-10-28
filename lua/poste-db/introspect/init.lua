--- SQL introspection utilities — float window display, column info, and DDL.
---
--- Extracted from sql/init.lua to reduce module size.
--- Provides show_table_ddl() and supporting functions.

local state = require("poste-db.state")
local util = require("poste-db.util")
local config = require("poste-db.config")
local context = require("poste-db.context")
local connections = require("poste-db.connections")
local route = require("poste-db.introspect.route")
local detect = require("poste-db.introspect.detect")
local target_resolver = require("poste-db.introspect.target")
local context_resolver = require("poste-db.introspect.context")
local ui = require("poste-db.introspect.ui")
local column = require("poste-db.introspect.column")
local table_helper = require("poste-db.introspect.table")
local preview = require("poste-db.buffer.nav_preview")
local const = require("poste-db.constants")

local M = {}
local show_float_win, show_float_buf = nil, nil

-- Introspection results arrive from async jobs, and show_float REPLACES the
-- previous float: whichever job finished last used to win, so a slow stale
-- answer could overwrite a fresh lookup. Every entry captures a token at
-- start; the async completion shows only while it is still current, and a
-- direct (synchronous) show_float bumps the epoch to retire in-flight jobs.
local float_epoch = 0

function M.next_float_token()
  float_epoch = float_epoch + 1
  return float_epoch
end

function M.show_float_if_current(token, lines, title, ft)
  if token ~= float_epoch then return end
  M.show_float(lines, title, ft)
end

--- The guarded callback handed down the async chain for a token.
local function guarded_show(token)
  return function(lines, title, ft)
    M.show_float_if_current(token, lines, title, ft)
  end
end

--- Wipe the tracked DDL/info float (and its buffer) so repeated look-ups neither
--- stack windows nor leak one preview buffer per call.
local function close_show_float()
  if show_float_win and vim.api.nvim_win_is_valid(show_float_win) then
    pcall(vim.api.nvim_win_close, show_float_win, true)
  end
  if show_float_buf and vim.api.nvim_buf_is_valid(show_float_buf) then
    pcall(vim.api.nvim_buf_delete, show_float_buf, { force = true })
  end
  show_float_win, show_float_buf = nil, nil
end

---------------------------------------------------------------------------
-- Float window
---------------------------------------------------------------------------

--- Show or open a float window with text content.
--- @param lines string[]
--- @param title string
--- @param ft string|nil  filetype (default "sql")
function M.show_float(lines, title, ft)
  float_epoch = float_epoch + 1
  if not lines or #lines == 0 then
    vim.notify("No content to display", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return
  end

  -- The previous float is replaced, not re-focused: looking up a second table
  -- has to render the new DDL, not re-display the stale one.
  close_show_float()

  -- Use the shared cell-preview float: native buffer navigation for scrolling
  -- and editor-anchored sizing, so a small source/dataset window can't squash
  -- the DDL/info popup (same treatment as the dataset K preview).
  local float_buf, win = preview.open_preview_float(title, table.concat(lines, "\n"), ft or "sql")
  if not float_buf or not win then return end

  show_float_win, show_float_buf = win, float_buf
  vim.api.nvim_set_current_win(win)

  local close_fn = function()
    close_show_float()
  end
  local sopts = { buffer = float_buf, noremap = true, silent = true }
  local ck = config.get_keymap("sql_introspect", "close", "q")
  if ck then vim.keymap.set("n", ck, close_fn, sopts) end
  ck = config.get_keymap("sql_introspect", "close_alt", "<Esc>")
  if ck then vim.keymap.set("n", ck, close_fn, sopts) end
end

-- Table DDL
---------------------------------------------------------------------------

--- Show DDL for the table under the cursor in a floating window.
function M.show_table_ddl()
  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found.", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  -- Check if cursor is on a -- @database <name> line → list tables
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local line_text = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1] or ""
  local entry = route.resolve_table_ddl_entry(line_text)
  local directive_action = target_resolver.resolve_directive_action(entry)
  if directive_action and directive_action.kind == "database" then
    local db_name = directive_action.db_name
    local ctx = context.resolve_full_context(buf, line_num)
    local conn = ctx.connection
    if not conn then
      vim.notify("No connection context for database '" .. db_name .. "'", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
      return
    end
    local token = M.next_float_token()
    table_helper.show_database_info(conn, db_name, guarded_show(token))
    return
  end

  if directive_action and directive_action.kind == "connection" then
    local conn_name = directive_action.conn_name
    local conn_cfg = connections.get_connection_config(conn_name)
    if not conn_cfg then
      vim.notify("Connection '" .. conn_name .. "' not found in connections.toml", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
      return
    end
    local token = M.next_float_token()
    ui.show_connection(conn_cfg, conn_name, guarded_show(token))
    return
  end

  local cword = vim.fn.expand("<cword>")
  if not cword or cword == "" then
    vim.notify("No word under cursor", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return
  end
  if route.is_sql_keyword(cword) then
    vim.notify("'" .. cword .. "' is a SQL keyword", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    return
  end

  local ctx = context.resolve_full_context(buf)
  local conn = ctx.connection
  if not conn or conn == "" then
    vim.notify("No SQL connection context. Add -- @connection <name> to the file header.", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local db = ctx.database

  -- Try to detect if cursor is on a column name via Rust context detection
  local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local end_col = util.scan_word_end(line_text, cursor[2])

  local token = M.next_float_token()

  local function detect_target_at(slice_end_col, resolve_after_dot_col)
    local payload = detect.build_detect_payload(all_lines, line_num, slice_end_col)
    if not payload then
      return nil
    end

    -- dialect-aware detection: without this flag the CLI falls back to
    -- generic function filtering, so e.g. MSSQL/MySQL builtins were missing
    -- from completion candidates
    local cc = connections.get_connection_config(conn)
    local args = context.detect_command(binary, payload.offset, cc and cc.dialect or nil)

    local ok_sys, result_obj = pcall(vim.system, args, {
      stdin = payload.sql_text,
      -- Same subcommand completion/init.lua runs per keystroke at 2000ms;
      -- this call blocks the editor, so a wedged binary must not hold the
      -- UI for longer than that precedent.
      timeout = 2000,
    })
    if not ok_sys then return nil end
    local result = result_obj:wait()
    if result.code ~= 0 or not result.stdout or result.stdout == "" then
      return nil
    end
    local out = result.stdout

    local ok, parsed = pcall(vim.json.decode, out)
    if not ok or not parsed then
      return nil
    end

    util.clean_nil(parsed)
    return context_resolver.resolve_detected_target(parsed, cword, db, resolve_after_dot_col)
  end

  -- Check for .column suffix (alias.column → column part)
  local after_dot_col = nil
  local nxt = line_text:sub(end_col + 1, end_col + 1)
  if nxt == "." then
    local cm = line_text:match("^([%w_]+)", end_col + 2)
    if cm then after_dot_col = cm end
  end

  if after_dot_col then
    -- alias.column pattern: resolve alias via context detection
    local detected_target = detect_target_at(end_col + 1 + #after_dot_col, after_dot_col)
    local action = target_resolver.resolve_detected_action(detected_target, db, cword)
    if action and action.kind == "column" and action.parent_table then
      column.show_column_info(conn, action.db or db, action.parent_table, action.column_name, action.parent_schema, guarded_show(token))
      return
    end
  end

  -- Check if cword is a column name (not a table) via context detection
  local detected_target = detect_target_at(end_col, nil)
  local action = target_resolver.resolve_detected_action(detected_target, db, cword)
  if action then
    if action.kind == "list_tables" and action.db then
      table_helper.show_database_tables(conn, action.db, guarded_show(token))
      return
    end
    if action.kind == "column" and action.parent_table then
      column.show_column_info(conn, action.db or db, action.parent_table, action.column_name, action.parent_schema, guarded_show(token))
      return
    end
    if action.kind == "ddl" and action.table_name then
      db = action.db or db
      cword = action.table_name
    end
  end

  -- Fallback: show DDL (table mode)
  table_helper.show_table_ddl(conn, db, cword, guarded_show(token))
end

return M
