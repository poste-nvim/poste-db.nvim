--- Table-drop flows for the DB Browser: single confirm dialog, batch drop
--- with progress/summary dialogs, and parent-tree refresh afterwards.
--- Extracted from db_browser/operations.lua (the dispatch surface stays on
--- operations.M since context_menu resolves actions by name).
local async = require("poste-db.db_browser.async")
local icons = require("poste-db.db_browser.icons")
local notify = require("poste-db.db_browser.notify")
local util = require("poste-db.db_browser.util")

local ops_sql = require("poste-db.db_browser.ops_sql")
local const = require("poste-db.constants")
local get_dialect = ops_sql.get_dialect
local get_connection_name = ops_sql.get_connection_name
local get_search_dir = ops_sql.get_search_dir
local find_table_node = ops_sql.find_table_node

local HEADER_LINES = icons.HEADER_LINES

local M = {}

--- Drop Table: show confirmation dialog, then execute DROP TABLE.
-----------------------------------------------------------------------------

local execute_drop  -- forward declaration

--- Show a confirmation dialog for dropping a table (red warning text).
local function show_drop_confirm(table_node, qualified, conn, context)
  local dialog = require("poste-db.dialog")
  local layout = require("poste-db.layout")

  local width = 56
  local sql = "DROP TABLE " .. qualified .. ";"

  local lines = {}
  local highlights = {}

  local line_n = 0
  lines[#lines + 1] = "  DANGER: This will permanently drop the table:"
  highlights[#highlights + 1] = { line = line_n, col_start = 2, col_end = #lines[line_n + 1], hl_group = "DiagnosticError" }
  line_n = line_n + 1

  lines[#lines + 1] = "    " .. qualified
  highlights[#highlights + 1] = { line = line_n, col_start = 4, col_end = 4 + #qualified, hl_group = "DiagnosticError" }
  line_n = line_n + 1

  lines[#lines + 1] = ""
  line_n = line_n + 1

  lines[#lines + 1] = "  " .. sql
  line_n = line_n + 1

  lines[#lines + 1] = ""
  line_n = line_n + 1

  local km = layout.keymaps({
    mapping = { { key = "y", label = "Confirm" }, { key = "n", label = "Cancel" } },
    indent = 4,
  })
  lines[#lines + 1] = km.lines[1]
  for _, h in ipairs(km.highlights) do
    highlights[#highlights + 1] = { line = line_n, col_start = h.col_start, col_end = h.col_end, hl_group = h.hl_group }
  end

  local height = #lines + 2
  local dlg = dialog.open({
    title = " Drop Table ",
    width = width,
    height = height,
    border = "rounded",
    backdrop = true,
    close_on_leave = false,
  })
  vim.keymap.set("n", "y", function()
    dlg:close()
    vim.schedule(function()
      execute_drop(table_node, qualified, conn, context)
    end)
  end, { buffer = dlg.buf, noremap = true, silent = true, nowait = true })
  vim.keymap.set("n", "n", function() dlg:close() end, { buffer = dlg.buf, noremap = true, silent = true, nowait = true })
  dlg:update(lines, highlights)
end

--- Execute DROP TABLE and refresh the browser tree.
--- The parameter list must match the confirm dialog's call site: an extra
--- `schema_prefix` here used to eat the context, and the refresh that
--- follows a successful DROP raised on a nil one.
execute_drop = function(table_node, qualified, conn, context)
  local sql_lines = {}
  table.insert(sql_lines, "DROP TABLE " .. qualified .. ";")
  local sql = table.concat(sql_lines, "\n")

  local search_dir = get_search_dir(context)
  local connections = require("poste-db.connections")
  local url, err = connections.resolve_connection_url(conn)
  if not url then
    vim.notify("Drop table failed: " .. (err or "unknown"), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  -- Find parent db/schema node to refresh
  local parent = table_node.parent
  while parent and parent.node_type ~= "database" and parent.node_type ~= "schema" do
    parent = parent.parent
  end

  local database = table_node.meta and table_node.meta.database or nil
  local exec_run = require("poste-db.exec_run")
  local job_id = exec_run.run_async(sql, {
    src_file = search_dir .. "/browser_drop.sql",
    conn_url = url,
    database = database,
    mode = "greedy",
    log_source = "browser",
    log_extra = { connection = conn },
  }, {
    on_response = function(resp)
      vim.schedule(function()
        if resp.has_error then
          -- Say WHY. The DROP usually fails on something the user can act on
          -- (a dependent view, a permission), and that text only exists in
          -- this response — the journal is not where one looks mid-action.
          local reason = exec_run.first_error(resp) or "unknown error"
          vim.notify("Failed to drop table '" .. qualified .. "': " .. reason, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
          return
        end
        notify.info("Dropped table: " .. qualified)
        util.invalidate_completion_cache()
        if parent then
          util.refresh_subtree(parent, context, parent.node_type, search_dir)
        end
      end)
    end,
    on_error = function(message)
      vim.schedule(function()
        vim.notify("Failed to drop table '" .. qualified .. "': " .. message, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
      end)
    end,
  })

  if not job_id or job_id <= 0 then
    vim.notify("Failed to start poste job", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
  end
end

--- Drop a table: confirm dialog, then execute DROP TABLE and refresh tree.
function M.drop_table(node, context)
  local table_node = node
  if node.node_type ~= "table" then
    table_node = find_table_node(context, vim.fn.line(".") - HEADER_LINES)
  end
  if not table_node or table_node.node_type ~= "table" then
    notify.info("Move cursor to a table node")
    return
  end

  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)
  local qualified = ops_sql.qualified_table_ref(table_node, dialect)
  show_drop_confirm(table_node, qualified, conn, context)
end

--- Build qualified name and lookup for a single table node.
local function prepare_drop_item(table_node, context)
  local dialect = get_dialect(table_node, context)
  local conn = get_connection_name(table_node, context)
  local qualified = ops_sql.qualified_table_ref(table_node, dialect)

  local parent = table_node.parent
  while parent and parent.node_type ~= "database" and parent.node_type ~= "schema" do
    parent = parent.parent
  end

  return {
    label = qualified,
    sql = "DROP TABLE " .. qualified .. ";",
    parent = parent,
    conn = conn,
    database = table_node.meta and table_node.meta.database or nil,
    table_node = table_node,
  }
end

-- First definition wins: never clobber a colorscheme-provided group.
local function keep_existing(name, spec)
  return function()
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
    if ok and hl and hl.fg then return nil end
    return spec
  end
end

require("poste-db.db_browser.theme").register({
  PosteDbDropProgress = keep_existing("PosteDbDropProgress", { fg = "#565f89" }),
  PosteDbDropError = keep_existing("PosteDbDropError", { fg = "#f7768e" }),
  PosteDbDropDone = keep_existing("PosteDbDropDone", { fg = "#9ece6a" }),
})

local function start_batch_drop(items, conn_label, search_dir, context)
  local exec_run = require("poste-db.exec_run")
  local connections = require("poste-db.connections")
  local progress_dlg = nil
  local results = {}
  local completed = 0
  local failed = 0
  local errors = {}
  local cancelled = false
  local total = #items

  for _, it in ipairs(items) do
    results[it.label] = { status = "pending" }
  end

  local function render_progress()
    if not progress_dlg then return end
    local lines = {}
    local highlights = {}
    local done = completed + failed
    local pct = total > 0 and math.floor(done / total * 100) or 0
    local bar_len = 20
    -- Same guard as pct: an empty items list would feed string.rep a NaN.
    local filled = total > 0 and math.floor(done / total * bar_len) or 0
    local bar = string.rep("█", filled) .. string.rep("░", bar_len - filled)
    table.insert(lines, "  Connection: " .. conn_label)
    table.insert(lines, "")
    local bar_line = "  " .. bar .. "  " .. done .. "/" .. total .. " (" .. pct .. "%)"
    table.insert(lines, bar_line)
    table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = #bar_line, hl_group = "PosteDbDropProgress" })
    table.insert(lines, "")

    for _, it in ipairs(items) do
      local r = results[it.label]
      if r.status == "done" then
        local line = "  ✓ " .. it.label
        table.insert(lines, line)
        table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = #line, hl_group = "PosteDbDropDone" })
      elseif r.status == "dropping" then
        table.insert(lines, "  ⟳ " .. it.label .. "  (dropping...)")
      elseif r.status == "error" then
        local line = "  ✘ " .. it.label
        table.insert(lines, line)
        table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = #line, hl_group = "PosteDbDropError" })
      else
        table.insert(lines, "  ◻ " .. it.label .. "  (pending)")
      end
    end

    if done == total then
      table.insert(lines, "")
      table.insert(lines, "  Done. " .. completed .. " dropped, " .. failed .. " failed.")
      if failed > 0 then
        table.insert(lines, "  Press [q] to see errors")
      end
    end

    if progress_dlg and progress_dlg.win and vim.api.nvim_win_is_valid(progress_dlg.win) then
      progress_dlg:update(lines, highlights)
    end
  end

  local dialog = require("poste-db.dialog")
  progress_dlg = dialog.open({
    title = "Dropping",
    width = 60,
    height = math.min(math.max(14, 8 + total), 24),
    border = "rounded",
    backdrop = true,
  })
  render_progress()

  local function show_summary()
    if failed == 0 then
      if progress_dlg and progress_dlg.win and vim.api.nvim_win_is_valid(progress_dlg.win) then
        progress_dlg:close()
      end
      return
    end
    local summary_lines = {
      "  Succeeded: " .. completed .. "  |  Failed: " .. failed,
      "",
    }
    -- Sorted: pairs() order reshuffles between runs; the summary reads in a
    -- stable order.
    local names = {}
    for label in pairs(errors) do table.insert(names, label) end
    table.sort(names)
    for _, label in ipairs(names) do
      summary_lines[#summary_lines + 1] = "  ✘ " .. label
      local clean = tostring(errors[label] or ""):gsub("\n", " "):gsub("\r", "")
      for _, chunk in ipairs(util.wrap_utf8(clean, 50)) do
        summary_lines[#summary_lines + 1] = "      " .. chunk
      end
    end
    local height = math.min(math.max(6, 4 + #summary_lines), 24)
    local sdlg = dialog.open({
      title = "Drop Complete",
      width = 60,
      height = height,
      border = "rounded",
      backdrop = false,
    })
    sdlg:update(summary_lines)
    vim.keymap.set("n", "q", function() sdlg:close() end, { buffer = sdlg.buf, noremap = true, silent = true, nowait = true })
  end

  local function refresh_all_parents()
    local seen = {}
    for _, it in ipairs(items) do
      if it.parent and not seen[it.parent] then
        seen[it.parent] = true
        it.parent.children = nil
        it.parent.expanded = false
        it.parent.loading = true
      end
    end
    util.render_tree(context)
    local parents = {}
    for p in pairs(seen) do table.insert(parents, p) end
    local idx = 0
    local function next_refresh()
      idx = idx + 1
      if idx > #parents then return end
      local p = parents[idx]
      async.fetch_children(p, function()
        p.expanded = true
        vim.schedule(function()
          next_refresh()
        end)
      end, search_dir)
    end
    next_refresh()
  end

  local function process_next(idx)
    if cancelled then
      if progress_dlg and progress_dlg.win and vim.api.nvim_win_is_valid(progress_dlg.win) then
        progress_dlg:close()
      end
      return
    end
    if idx > total then
      if progress_dlg and progress_dlg.win and vim.api.nvim_win_is_valid(progress_dlg.win) then
        progress_dlg:close()
      end
      show_summary()
      refresh_all_parents()
      if completed > 0 then util.invalidate_completion_cache() end
      return
    end
    local it = items[idx]
    results[it.label] = { status = "dropping" }
    render_progress()

    local url, err = connections.resolve_connection_url(it.conn)
    if not url then
      results[it.label] = { status = "error" }
      errors[it.label] = err or "unknown"
      failed = failed + 1
      render_progress()
      process_next(idx + 1)
      return
    end

    local job_id = exec_run.run_async(it.sql, {
      src_file = search_dir .. "/browser_batch_drop.sql",
      conn_url = url,
      database = it.database,
      mode = "greedy",
      log_source = "browser",
      log_extra = { connection = it.conn },
    }, {
      on_response = function(resp)
        vim.schedule(function()
          if cancelled then return end
          if resp.has_error then
            results[it.label] = { status = "error" }
            -- The progress dialog's "Press [q] to see errors" promises the
            -- reason; store the server's text rather than a restatement of
            -- the ✘ the row already shows.
            errors[it.label] = exec_run.first_error(resp) or "DROP failed"
            failed = failed + 1
          else
            results[it.label] = { status = "done" }
            completed = completed + 1
          end
          render_progress()
          process_next(idx + 1)
        end)
      end,
      on_error = function(message)
        vim.schedule(function()
          if cancelled then return end
          results[it.label] = { status = "error" }
          errors[it.label] = message
          failed = failed + 1
          render_progress()
          process_next(idx + 1)
        end)
      end,
    })

    if not job_id or job_id <= 0 then
      results[it.label] = { status = "error" }
      errors[it.label] = "Failed to start poste job"
      failed = failed + 1
      render_progress()
      process_next(idx + 1)
    end
  end

  -- Buffer-local like the summary dialog's binding: a global `q` here survived
  -- the drop and hijacked every later window (and macro recording).
  vim.keymap.set("n", "q", function()
    cancelled = true
    if progress_dlg and progress_dlg.win and vim.api.nvim_win_is_valid(progress_dlg.win) then
      progress_dlg:close()
    end
  end, { buffer = progress_dlg.buf, noremap = true, silent = true, nowait = true })

  process_next(1)
end

--- Batch drop tables: confirm dialog, then sequentially drop with progress.
function M.batch_drop_tables(selected_nodes, context)
  local items = {}
  for node in pairs(selected_nodes) do
    if node.node_type == "table" then
      table.insert(items, prepare_drop_item(node, context))
    end
  end
  if #items == 0 then
    notify.info("No table nodes selected")
    return
  end

  table.sort(items, function(a, b) return a.label < b.label end)

  local conn_label = items[1].conn
  local search_dir = get_search_dir(context)

  local lines = {
    "  DANGER: This will permanently drop the following tables:",
    "",
  }
  for _, it in ipairs(items) do
    table.insert(lines, "    " .. it.label)
  end
  table.insert(lines, "")
  table.insert(lines, string.format("  %d table(s) at %s", #items, conn_label))
  table.insert(lines, "")

  local layout = require("poste-db.layout")
  local km = layout.keymaps({
    mapping = { { key = "y", label = "Drop" }, { key = "n", label = "Cancel" } },
    indent = 4,
  })
  table.insert(lines, km.lines[1])
  local height = #lines + 2
  height = math.min(height, 26)

  local dialog = require("poste-db.dialog")
  local dlg = dialog.open({
    title = " Drop Tables ",
    width = 60,
    height = height,
    border = "rounded",
    backdrop = true,
    close_on_leave = false,
  })

  local highlights = {}
  highlights[1] = { line = 0, col_start = 2, col_end = #lines[1], hl_group = "DiagnosticError" }

  vim.keymap.set("n", "y", function()
    dlg:close()
    vim.schedule(function() start_batch_drop(items, conn_label, search_dir, context) end)
  end, { buffer = dlg.buf, noremap = true, silent = true, nowait = true })
  vim.keymap.set("n", "n", function() dlg:close() end, { buffer = dlg.buf, noremap = true, silent = true, nowait = true })
  dlg:update(lines, highlights)
end

M._test = { execute_drop = execute_drop }

return M
