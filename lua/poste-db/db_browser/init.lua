local config = require("poste-db.config")
local sql_state = require("poste-db.state")

local tree = require("poste-db.db_browser.tree")
local async = require("poste-db.db_browser.async")
local actions = require("poste-db.db_browser.actions")
local util = require("poste-db.db_browser.util")
local HEADER_LINES = require("poste-db.db_browser.icons").HEADER_LINES
local notify = require("poste-db.db_browser.notify")
local yank = require("poste-db.db_browser.yank")
local const = require("poste-db.constants")

local M = {}

local browser_buf = nil
local browser_win = nil
local root_nodes = {}
local line_to_node = {}
local source_buf = nil

local multi_select = {
  active = false,
  source_db = nil,
  selected = {},
}

local statusline = require("poste-db.db_browser.statusline")

local function update_statusline()
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
  -- Enclosing scope of the line under the browser cursor. Nodes carry no
  -- parent pointers; scan line_to_node upward from the cursor line (the same
  -- approach find_target_db uses) to find the nearest connection/database/
  -- schema/table/column. Columns hang under a table, so the scan covers them.
  local conn_name, db_name, schema_name, table_name, column_name = nil, nil, nil, nil, nil
  local comment = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == browser_buf then
      local row = vim.api.nvim_win_get_cursor(win)[1]
      for i = row - HEADER_LINES, 1, -1 do
        local n = line_to_node[i]
        if not n then break end
        if n.node_type == "connection" then
          conn_name = conn_name or n.name
        elseif n.node_type == "database" then
          db_name = db_name or n.name
        elseif n.node_type == "schema" then
          schema_name = schema_name or n.name
        elseif n.node_type == "table" then
          table_name = table_name or n.name
          comment = comment or (n.meta and n.meta.comment)
        elseif n.node_type == "column" then
          column_name = column_name or n.name
          comment = comment or (n.meta and n.meta.comment)
        end
        if conn_name then break end
      end
      break
    end
  end
  local path = statusline.node_path(conn_name, db_name, schema_name, table_name, column_name)
  statusline.update(browser_buf, path, comment, multi_select)
end

--- Drop multi-select entries whose node tables no longer hang off the
--- current tree. Every child refetch REPLACES node.children with fresh
--- tables, so after a refresh the old selected nodes were invisible (the
--- marker check is by identity) while the winbar count and the `p`/`D`
--- keymaps still iterated the stale set. Selections are pruned against
--- reachability from root_nodes; an emptied selection leaves the mode itself
--- alone so the user can exit it deliberately.
local function prune_multi_select()
  if not multi_select.active then return end
  local live = {}
  local function mark(node)
    if node == nil then return end
    live[node] = true
    for _, c in ipairs(node.children or {}) do mark(c) end
  end
  for _, root in ipairs(root_nodes or {}) do mark(root) end
  for node in pairs(multi_select.selected) do
    if not live[node] then multi_select.selected[node] = nil end
  end
end

--- The render context every tree paint goes through. `update_statusline` rides
--- along so util.render_tree (used by refresh_subtree from the paste/drop
--- paths) repaints the statusline exactly like this module's own renders do.
local function render_context()
  return {
    browser_buf = browser_buf,
    line_to_node = line_to_node,
    root_nodes = root_nodes,
    conn_label = sql_state.db_browser.connection or "No connection",
    multi_select = multi_select,
    update_statusline = update_statusline,
  }
end

local function render_tree()
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
  prune_multi_select()
  -- Synced in place, never reassigned: `make_context` hands this same table to
  -- actions, and the search state keeps one across an async jump. Reassigning
  -- the local left every earlier context holding the previous table, so a
  -- render triggered through a stored context updated a map no keymap reads and
  -- the live one kept lines pointing at nodes that were no longer on screen.
  util.render_tree(render_context())
end

local function exit_multi_select()
  if not multi_select.active then return end
  multi_select.active = false
  multi_select.source_db = nil
  multi_select.selected = {}
  render_tree()
end

local function find_db_parent(node)
  while node do
    if node.node_type == "database" then return node end
    node = node.parent
  end
  return nil
end

local function toggle_multi_select_on_table(buf_line)
  local node = tree.get_node_at_line(line_to_node, buf_line)
  if not node or node.node_type ~= "table" then return end

  local db_parent = find_db_parent(node)
  if not db_parent then return end

  if not multi_select.active then
    multi_select.active = true
    multi_select.source_db = db_parent
    multi_select.selected = {}
  elseif multi_select.source_db ~= db_parent then
    return
  end

  if multi_select.selected[node] then
    multi_select.selected[node] = nil
  else
    multi_select.selected[node] = true
  end

  render_tree()

  local total_lines = vim.api.nvim_buf_line_count(browser_buf)
  local next_line = buf_line + 1
  if next_line <= total_lines then
    -- Window 0, not the stored `browser_win`: this runs from a buffer-local
    -- keymap, so the current window is the one the user is tabbing through —
    -- and `browser_win` is whichever window first opened the buffer, which a
    -- closed split or a `:sall` can leave behind.
    vim.api.nvim_win_set_cursor(0, { next_line, 0 })
  end
end

local function get_selected_table_names()
  local names = {}
  for node, _ in pairs(multi_select.selected) do
    table.insert(names, node.name)
  end
  table.sort(names)
  return names
end

local function find_target_db(buf_line)
  local idx = buf_line - HEADER_LINES
  for i = idx, 1, -1 do
    local n = line_to_node[i]
    if n and n.node_type == "database" then return n end
    if n and n.node_type == "connection" then return nil end
  end
  return nil
end

local function get_search_dir()
  return vim.fn.getcwd()
end
M.get_search_dir = get_search_dir

--- Invalidate `node` and refetch its children in place — the one
--- paste/clone/drop on_complete refresh. util.refresh_subtree walks up to the
--- node's own type (the node itself here), so callers hand it the exact node
--- they mean. (actions.refresh_node is the by-line sibling of this.)
local function refresh_tree_node(node)
  util.refresh_subtree(node, render_context(), node.node_type, get_search_dir())
end

local function start_copy(buf_line)
  if not multi_select.active or not next(multi_select.selected) then
    notify.info("No tables selected. Use <Tab> to select tables first.")
    return
  end

  local target_db = find_target_db(buf_line)
  if not target_db then
    notify.info("Move cursor to a target database")
    return
  end

  if target_db == multi_select.source_db then
    notify.warn("Target database is the same as source. Select a different database.")
    return
  end

  local source_conn_name = multi_select.source_db.meta and multi_select.source_db.meta.connection
  local target_conn_name = target_db.meta and target_db.meta.connection

  local src_dialect = util.connection_dialect(source_conn_name, root_nodes)
  local tgt_dialect = util.connection_dialect(target_conn_name, root_nodes)

  if src_dialect ~= tgt_dialect then
    vim.notify(string.format(
      "Cannot copy: dialect mismatch (%s → %s). Both must be the same dialect.",
      src_dialect, tgt_dialect
    ), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local table_names = get_selected_table_names()
  local copy_mod = require("poste-db.db_browser.copy")
  copy_mod.copy_tables({
    conn = source_conn_name,
    db = multi_select.source_db.name,
    dialect = src_dialect,
  }, {
    conn = target_conn_name,
    db = target_db.name,
    dialect = tgt_dialect,
  }, table_names, function()
    exit_multi_select()
    if target_db then
      refresh_tree_node(target_db)
    end
  end)
end

--- Where a yank-register paste lands, resolved from the node under the cursor.
--- A database node is the target, and so is anything nested under it — the
--- cursor rests on a table or a column more often than on the database itself.
--- For sqlite the connection node *is* the database, so the same walk-up has to
--- name the connection; for a non-sqlite connection with a whole-database yank
--- the target is a clone instead (a new database gets created there).
---@param node table the node under the cursor
---@param entry table the yanked register entry
---@return table? nil when nothing around the cursor can take the paste
local function resolve_paste_target(node, entry)
  local target_db, conn_node, clone_conn
  local is_sqlite_conn = false

  if node.node_type == "connection" then
    conn_node = node
  elseif node.node_type == "database" then
    target_db = node
  else
    local cur = node.parent
    while cur do
      if cur.node_type == "connection" then conn_node = cur; break end
      if cur.node_type == "database" then target_db = cur; break end
      cur = cur.parent
    end
  end

  if conn_node then
    if conn_node.meta and conn_node.meta.dialect == "sqlite" then
      is_sqlite_conn = true
    elseif entry.kind == "database" then
      clone_conn = conn_node
    end
  end

  if not target_db and not is_sqlite_conn and not clone_conn then return nil end

  return {
    node = target_db,
    clone_conn = clone_conn,
    is_sqlite_conn = is_sqlite_conn,
    -- The connection the CLI is addressed by. `target_db`'s own is authoritative;
    -- otherwise it is the connection the walk-up landed on — never `node.name`,
    -- which for a table under a sqlite connection is a table name.
    conn = (target_db and target_db.meta and target_db.meta.connection)
      or conn_node.name,
    db = target_db and (target_db.name or (target_db.meta and target_db.meta.database)) or nil,
    -- The paste TARGET's dialect decides the catalog/DDL SQL: only the
    -- connection/database nodes carry meta.dialect, so a table node under a
    -- sqlite connection fell through to entry.dialect — the SOURCE's dialect —
    -- and postgres-flavored SQL ran against sqlite.
    dialect = (node.meta and node.meta.dialect)
      or (target_db and target_db.meta and target_db.meta.dialect)
      or (conn_node and conn_node.meta and conn_node.meta.dialect)
      or entry.dialect,
  }
end

local function make_context()
  local conn_label = sql_state.db_browser.connection or "No connection"
  return {
    browser_buf = browser_buf,
    line_to_node = line_to_node,
    root_nodes = root_nodes,
    source_buf = source_buf,
    conn_label = conn_label,
    multi_select = multi_select,
  }
end

local function setup_browser_buffer()
  if browser_buf and vim.api.nvim_buf_is_valid(browser_buf) then return browser_buf end

  -- Re-render after background prefetch completes so node counts show
  -- without the user expanding each node.
  async.render_hook = render_tree

  browser_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = browser_buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = browser_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = browser_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })
  vim.api.nvim_buf_set_name(browser_buf, "poste://db_browser")

  local opts = { buffer = browser_buf, noremap = true, silent = true }
  local k = config.get_keymap("sql_db_browser", "toggle_node", "<CR>")
  if k then
    vim.keymap.set("n", k, function()
      actions.toggle_node(vim.fn.line("."), make_context())
    end, opts)
  end
  k = config.get_keymap("sql_db_browser", "move_left", "h")
  if k then
    vim.keymap.set("n", k, function()
      actions.collapse_or_parent(vim.fn.line("."), make_context())
    end, opts)
  end
  k = config.get_keymap("sql_db_browser", "move_right", "l")
  if k then
    vim.keymap.set("n", k, function()
      actions.expand_or_child(vim.fn.line("."), make_context())
    end, opts)
  end
  k = config.get_keymap("sql_db_browser", "refresh_node", "r")
  if k then
    vim.keymap.set("n", k, function()
      actions.refresh_node(vim.fn.line("."), make_context())
    end, opts)
  end
  k = config.get_keymap("sql_db_browser", "search_filter", "/")
  if k then
    vim.keymap.set("n", k, function()
      actions.search_filter(vim.fn.line("."), make_context())
    end, opts)
  end
  k = config.get_keymap("sql_db_browser", "close", "q")
  if k then
    vim.keymap.set("n", k, function() M.close() end, opts)
  end
  k = config.get_keymap("sql_db_browser", "search_next", "n")
  if k then
    vim.keymap.set("n", k, function() actions.search_next() end, opts)
  end
  k = config.get_keymap("sql_db_browser", "search_prev", "N")
  if k then
    vim.keymap.set("n", k, function() actions.search_prev() end, opts)
  end

  k = config.get_keymap("sql_db_browser", "context_menu", "x")
  if k then
    local context_menu = require("poste-db.db_browser.context_menu")
    vim.keymap.set("n", k, function()
      local node = tree.get_node_at_line(line_to_node, vim.fn.line("."))
      context_menu.open(node, make_context())
    end, opts)
  end

  k = config.get_keymap("sql_db_browser", "help", "g?")
  if k then
    vim.keymap.set("n", k, function() require("poste-db.help").open() end, opts)
  end

  k = config.get_keymap("sql_db_browser", "ask_ai", "a")
  if k then
    vim.keymap.set("n", k, function()
      local node = tree.get_node_at_line(line_to_node, vim.fn.line("."))
      require("poste-db.ai").ask_node(node)
    end, opts)
  end

  -- Multi-select: Tab toggles selection on table nodes
  k = config.get_keymap("sql_db_browser", "multi_select_toggle", "<Tab>")
  if k then
    vim.keymap.set("n", k, function()
      toggle_multi_select_on_table(vim.fn.line("."))
    end, opts)
  end

  -- Esc: exit multi-select and/or clear search
  k = config.get_keymap("sql_db_browser", "multi_select_exit", "<Esc>")
  if k then
    vim.keymap.set("n", k, function()
      exit_multi_select()
      actions.search_clear(make_context())
    end, opts)
  end

  -- Info: i shows table or column metadata based on cursor position
  k = config.get_keymap("sql_db_browser", "table_info", "i")
  if k then
    vim.keymap.set("n", k, function()
      local buf_line = vim.fn.line(".")
      local node = tree.get_node_at_line(line_to_node, buf_line)
      if node and node.node_type == "column" then
        actions.show_column_info(buf_line, make_context())
      else
        actions.show_table_info(buf_line, make_context())
      end
    end, opts)
  end

  -- Yank: y records a copy source (table, view, database, schema, or sqlite connection)
  k = config.get_keymap("sql_db_browser", "yank_node", "y")
  if k then
    vim.keymap.set("n", k, function()
      local node = tree.get_node_at_line(line_to_node, vim.fn.line("."))
      if not node then return end
      -- util.get_dialect resolves node meta → its connection's root → default;
      -- the inline two-condition root walk this replaced also matched a TABLE
      -- whose name happened to equal a connection's name and took that root's
      -- dialect.
      local entry = yank.from_node(node, util.get_dialect(node, root_nodes))
      if entry then
        yank.set(entry)
        -- Persistent statusline indicator (not a one-shot notify, which would
        -- block on "Press ENTER"); also a brief non-blocking flash.
        update_statusline()
        require("poste-db.db_browser.flash").flash("Yanked " .. (yank.describe() or ""))
      end
    end, opts)
  end

  -- Copy/Paste: p triggers paste from either multi-select or yank register
  k = config.get_keymap("sql_db_browser", "copy_tables", "p")
  if k then
    vim.keymap.set("n", k, function()
      local buf_line = vim.fn.line(".")
      -- Multi-select path (existing behavior)
      if multi_select.active and next(multi_select.selected) then
        start_copy(buf_line)
        return
      end
      -- Yank-register path
      local entry = yank.get()
      if not entry then
        notify.info("Nothing yanked. Use <Tab> to select tables, or press y on a table/view/database to yank.")
        return
      end
      -- Resolve target: the cursor must be on or under a database node (or, for
      -- sqlite, a connection). See resolve_paste_target.
      local node = tree.get_node_at_line(line_to_node, buf_line)
      if not node then return end

      local target = resolve_paste_target(node, entry)
      if not target then
        notify.info("Move cursor to a target database (or sqlite connection) to paste, "
          .. "or to a connection to clone")
        return
      end

      local target_db = target.node
      local clone_conn = target.clone_conn
      local is_sqlite_conn_target = target.is_sqlite_conn
      local target_conn = target.conn
      local target_db_name = target.db
      local target_dialect = target.dialect

      local copy_mod = require("poste-db.db_browser.copy")

      -- Whole-database yank onto a non-sqlite connection → clone into a NEW database.
      if clone_conn and entry.kind == "database" then
        local clone_dialect = (clone_conn.meta and clone_conn.meta.dialect)
          or entry.dialect
        copy_mod.clone_database(entry, { conn = clone_conn.name, dialect = clone_dialect }, {
          on_complete = function()
            -- Consumed: drop the register (and its statusline indicator) now.
            yank.clear()
            update_statusline()
            -- Refresh the connection to surface the new database.
            refresh_tree_node(clone_conn)
          end,
        })
        return
      end

      if entry.kind == "database" then
        -- Enumerate all objects at paste time via catalog.
        local catalog = require("poste-db.db_browser.catalog")
        catalog.enumerate(entry, function(objects, triggers, routines)
          copy_mod.paste_objects(entry, {
            conn = target_conn, db = target_db_name, dialect = target_dialect,
          }, objects, triggers, routines, {
            on_complete = function()
              -- Consumed: drop the register (and its statusline indicator) now.
              yank.clear()
              update_statusline()
              -- Refresh target node display.
              if target_db then
                refresh_tree_node(target_db)
              elseif is_sqlite_conn_target then
                -- Refresh the connection node (sqlite).
                for _, root in ipairs(root_nodes) do
                  if root.name == target_conn then
                    refresh_tree_node(root)
                    break
                  end
                end
              end
            end,
          })
        end, function(err)
          vim.notify("Failed to enumerate objects for paste: " .. tostring(err), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
        end)
      elseif entry.kind == "table" or entry.kind == "view" then
        copy_mod.paste_objects(entry, {
          conn = target_conn, db = target_db_name, dialect = target_dialect,
        }, { entry }, {}, {}, {
          on_complete = function()
            -- Consumed: drop the register (and its statusline indicator) now.
            yank.clear()
            update_statusline()
            if target_db then
              refresh_tree_node(target_db)
            elseif is_sqlite_conn_target then
              for _, root in ipairs(root_nodes) do
                if root.name == target_conn then
                  refresh_tree_node(root)
                  break
                end
              end
            end
          end,
        })
      end
    end, opts)
  end

  -- Multi-select batch drop: D drops all selected tables at source database
  k = config.get_keymap("sql_db_browser", "multi_select_drop", "D")
  if k then
    local ops_mod = require("poste-db.db_browser.operations")
    vim.keymap.set("n", k, function()
      if not multi_select.active or not next(multi_select.selected) then
        return
      end
      ops_mod.batch_drop_tables(multi_select.selected, make_context())
      exit_multi_select()
    end, opts)
  end

  -- Go to definition: gd on connection opens connections.toml at the entry
  k = config.get_keymap("sql_db_browser", "goto_definition", "gd")
  if k then
    vim.keymap.set("n", k, function()
      local node = tree.get_node_at_line(line_to_node, vim.fn.line("."))
      if node and node.node_type == "connection" then
        require("poste-db.db_browser.operations").edit_conn(node, make_context())
      end
    end, opts)
  end

  local table_ops = require("poste-db.table_ops")
  table_ops.register_keymaps(browser_buf, function()
    local buf_line = vim.fn.line(".")
    local idx = buf_line - HEADER_LINES
    local node = util.find_table_node(line_to_node, idx)
    if not node then return nil end
    return {
      table_name = node.name,
      dialect = util.get_dialect(node, root_nodes),
      source_buf = source_buf,
    }
  end)

  -- Keep the statusline's connection/db/schema context in sync with the cursor.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = browser_buf,
    callback = function()
      update_statusline()
    end,
  })

  return browser_buf
end

local function open_window()
  if browser_win and vim.api.nvim_win_is_valid(browser_win) then return browser_win end

  local cfg = config.config.db_browser or {}
  local pos = cfg.split_position or "right"
  local width = cfg.split_width or 40
  local dir = pos == "right" and "botright" or "topleft"
  vim.cmd(dir .. " " .. width .. "vsplit")
  browser_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(browser_win, browser_buf)
  vim.api.nvim_set_option_value("winfixwidth", true, { win = browser_win })
  vim.api.nvim_set_option_value("number", false, { win = browser_win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = browser_win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = browser_win })
  vim.api.nvim_set_option_value("wrap", false, { win = browser_win })
  vim.api.nvim_set_option_value("cursorline", true, { win = browser_win })
  vim.api.nvim_set_option_value("conceallevel", 2, { win = browser_win })
  vim.api.nvim_set_option_value("spell", false, { win = browser_win })
  vim.api.nvim_set_option_value("winbar", " DB Browser", { win = browser_win })

  return browser_win
end

function M.navigate_to(conn_name, db_name)
  source_buf = vim.api.nvim_get_current_buf()
  setup_browser_buffer()
  open_window()

  local search_dir = get_search_dir()
  async.load_connections(function(nodes)
    root_nodes = nodes
    if #root_nodes > 0 then
      sql_state.db_browser.connection = root_nodes[1].name
    end

    local conn_node = nil
    for _, node in ipairs(root_nodes) do
      if node.name == conn_name then conn_node = node; break end
    end
    if not conn_node then
      render_tree()
      notify.warn("Connection '" .. conn_name .. "' not found in connections.toml")
      return
    end

    conn_node.loading = true
    render_tree()
    async.fetch_children(conn_node, function()
      conn_node.expanded = true

      local db_node = nil
      for _, child in ipairs(conn_node.children or {}) do
        if child.node_type == "database" and child.name == db_name then
          db_node = child; break
        end
      end
      if not db_node then
        vim.schedule(function()
          render_tree()
          notify.warn("Database '" .. db_name .. "' not found under '" .. conn_name .. "'")
        end)
        return
      end

      db_node.loading = true
      vim.schedule(function() render_tree() end)
      async.fetch_children(db_node, function()
        db_node.expanded = true
        vim.schedule(function()
          render_tree()
          for i, node in ipairs(line_to_node) do
            if node == db_node then
              local target_line = i + HEADER_LINES
              if vim.api.nvim_win_is_valid(browser_win) then
                vim.api.nvim_set_current_win(browser_win)
                vim.api.nvim_win_set_cursor(browser_win, { target_line, 0 })
              end
              break
            end
          end
        end)
      end, search_dir)
    end, search_dir)
  end, search_dir)
end

function M.navigate_to_table(conn_name, db_name, table_name, column_name)
  source_buf = vim.api.nvim_get_current_buf()
  setup_browser_buffer()
  open_window()

  local schema_name = nil
  local bare_table = table_name
  local dot_idx = table_name:find("%.")
  if dot_idx then
    schema_name = table_name:sub(1, dot_idx - 1)
    bare_table = table_name:sub(dot_idx + 1)
  end

  local search_dir = get_search_dir()
  async.load_connections(function(nodes)
    root_nodes = nodes
    if #root_nodes > 0 then
      sql_state.db_browser.connection = root_nodes[1].name
    end

    local conn_node = nil
    for _, node in ipairs(root_nodes) do
      if node.name == conn_name then conn_node = node; break end
    end
    if not conn_node then
      render_tree()
      notify.warn("Connection '" .. conn_name .. "' not found")
      return
    end

    local dialect = conn_node.meta and conn_node.meta.dialect or "postgres"

    local function position_on_table(table_node, col_name)
      vim.schedule(function()
        render_tree()
        local target_node = table_node
        if col_name and table_node.children then
          for _, child in ipairs(table_node.children) do
            if child.node_type == "column" and child.name == col_name then
              target_node = child; break
            end
          end
        end
        for i, n in ipairs(line_to_node) do
          if n == target_node then
            local target_line = i + HEADER_LINES
            if vim.api.nvim_win_is_valid(browser_win) then
              vim.api.nvim_set_current_win(browser_win)
              vim.api.nvim_win_set_cursor(browser_win, { target_line, 0 })
            end
            break
          end
        end
      end)
    end

    if dialect == "sqlite" then
      conn_node.loading = true
      render_tree()
      async.fetch_children(conn_node, function()
        conn_node.expanded = true
        local found = nil
        for _, child in ipairs(conn_node.children or {}) do
          if child.node_type == "table" and child.name == bare_table then
            found = child; break
          end
        end
        if not found then vim.schedule(function() render_tree() end); return end
        found.loading = true
        vim.schedule(function() render_tree() end)
        async.fetch_children(found, function()
          found.expanded = true
          position_on_table(found, column_name)
        end, search_dir)
      end, search_dir)
      return
    end

    conn_node.loading = true
    render_tree()
    async.fetch_children(conn_node, function()
      conn_node.expanded = true
      local db_node = nil
      for _, child in ipairs(conn_node.children or {}) do
        if child.node_type == "database" and child.name == db_name then
          db_node = child; break
        end
      end
      if not db_node then
        vim.schedule(function() render_tree(); notify.warn("Database '" .. (db_name or "?") .. "' not found") end)
        return
      end

      if dialect == "postgres" then
        local target_schema = schema_name or "public"
        db_node.loading = true
        vim.schedule(function() render_tree() end)
        async.fetch_children(db_node, function()
          db_node.expanded = true
          local schema_node = nil
          for _, child in ipairs(db_node.children or {}) do
            if child.node_type == "schema" and child.name == target_schema then
              schema_node = child; break
            end
          end
          if not schema_node then
            vim.schedule(function() render_tree(); notify.warn("Schema '" .. target_schema .. "' not found") end)
            return
          end
          schema_node.loading = true
          vim.schedule(function() render_tree() end)
          async.fetch_children(schema_node, function()
            schema_node.expanded = true
            local table_node = nil
            for _, child in ipairs(schema_node.children or {}) do
              if child.node_type == "table" and child.name == bare_table then
                table_node = child; break
              end
            end
            if not table_node then
              vim.schedule(function() render_tree(); notify.warn("Table '" .. bare_table .. "' not found") end)
              return
            end
            table_node.loading = true
            vim.schedule(function() render_tree() end)
            async.fetch_children(table_node, function()
              table_node.expanded = true
              position_on_table(table_node, column_name)
            end, search_dir)
          end, search_dir)
        end, search_dir)
      else
        db_node.loading = true
        vim.schedule(function() render_tree() end)
        async.fetch_children(db_node, function()
          db_node.expanded = true
          local table_node = nil
          for _, child in ipairs(db_node.children or {}) do
            if child.node_type == "table" and child.name == bare_table then
              table_node = child; break
            end
          end
          if not table_node then
            vim.schedule(function() render_tree(); notify.warn("Table not found") end)
            return
          end
          table_node.loading = true
          vim.schedule(function() render_tree() end)
          async.fetch_children(table_node, function()
            table_node.expanded = true
            position_on_table(table_node, column_name)
          end, search_dir)
        end, search_dir)
      end
    end, search_dir)
  end, search_dir)
end

function M.open()
  source_buf = vim.api.nvim_get_current_buf()
  setup_browser_buffer()
  open_window()

  local search_dir = get_search_dir()
  async.load_connections(function(nodes)
    root_nodes = nodes
    if #root_nodes > 0 then
      sql_state.db_browser.connection = root_nodes[1].name
    end
    render_tree()
    -- Focus cursor on first connection
    for i, node in ipairs(line_to_node) do
      if node.node_type == "connection" then
        local target_line = i + HEADER_LINES
        if vim.api.nvim_win_is_valid(browser_win) then
          vim.api.nvim_set_current_win(browser_win)
          vim.api.nvim_win_set_cursor(browser_win, { target_line, 0 })
        end
        break
      end
    end
  end, search_dir)
end

function M.close()
  exit_multi_select()
  -- A running search keeps the context it started from: its line map and its
  -- copy of the root list. Rebuilding the tree on the next open invalidates
  -- both, so `n` afterwards would jump through nodes that are no longer on
  -- screen — and the match highlights would stay on the hidden buffer.
  if browser_buf and vim.api.nvim_buf_is_valid(browser_buf) then
    actions.search_clear(make_context())
  end
  if browser_win and vim.api.nvim_win_is_valid(browser_win) then
    vim.api.nvim_win_close(browser_win, true)
    browser_win = nil
  end
end

function M.is_open()
  return browser_win and vim.api.nvim_win_is_valid(browser_win)
end

local function find_refresh_node(nodes, conn_name, db_name)
  for _, conn_node in ipairs(nodes) do
    if conn_node.name == conn_name then
      if db_name then
        if not conn_node.children then return nil end
        for _, db_node in ipairs(conn_node.children) do
          if db_node.name == db_name then
            return db_node
          end
        end
      end
      return conn_node
    end
  end
  return nil
end

function M.refresh_by_conn(conn_name, db_name)
  if not M.is_open() then return end
  local node = find_refresh_node(root_nodes, conn_name, db_name)
  if not node then return end

  refresh_tree_node(node)
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Exposed for tests: drives a render against a scratch buffer, which needs no
--- CLI binary, connection, or window.
M._test = {
  render_tree = render_tree,
  make_context = make_context,
  resolve_paste_target = resolve_paste_target,
  line_map = function() return line_to_node end,
  attach = function(buf, nodes)
    browser_buf = buf
    root_nodes = nodes or {}
    util.set_line_map(line_to_node, {})
  end,
}

return M
