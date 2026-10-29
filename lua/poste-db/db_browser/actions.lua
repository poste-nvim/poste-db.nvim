local icons = require("poste-db.db_browser.icons")
local tree = require("poste-db.db_browser.tree")
local async = require("poste-db.db_browser.async")
local cli = require("poste-db.cli")
local util = require("poste-db.db_browser.util")
local core_util = require("poste-db.util")
local notify = require("poste-db.db_browser.notify")
local ops_sql = require("poste-db.db_browser.ops_sql")
local const = require("poste-db.constants")

local HEADER_LINES = icons.HEADER_LINES

local format_bytes = util.format_bytes

local function deep_clean(t)
  for k, v in pairs(t) do
    if v == vim.NIL then
      t[k] = nil
    elseif type(v) == "table" then
      deep_clean(v)
    end
  end
end

local M = {}

local search_hl_ns = vim.api.nvim_create_namespace("poste_db_browser_search")
local search_char_ns = vim.api.nvim_create_namespace("poste_db_browser_search_char")

-- Search state for / n N navigation
local search_state = {
  matches = {},
  current = 0,
  pattern = "",
  context = nil,
}

-- Fuzzy match: each pattern char must appear in order in text (case-insensitive).
-- Returns true + 1-indexed positions of matched chars, or false.
local function fuzzy_match(text, pattern)
  local ti = 1
  local positions = {}
  local plower = pattern:lower()
  local tlower = text:lower()
  for pi = 1, #plower do
    local pc = plower:sub(pi, pi)
    local found = false
    while ti <= #tlower do
      if tlower:sub(ti, ti) == pc then
        table.insert(positions, ti)
        ti = ti + 1
        found = true
        break
      end
      ti = ti + 1
    end
    if not found then return false end
  end
  return true, positions
end

M.find_table_node = util.find_table_node

local get_connection = util.get_connection
local get_dialect = util.get_dialect
local get_search_dir = util.get_search_dir

local execute_table_select  -- forward declaration

function M.toggle_node(buf_line, context)
  local node = tree.get_node_at_line(context.line_to_node, buf_line)
  if not node then return end

  -- Table node: execute SELECT * directly instead of expanding
  if node.node_type == "table" then
    execute_table_select(node, context)
    return
  end

  if node.node_type == "column" or node.node_type == "index"
      or node.node_type == "key_item" or node.node_type == "fk_item"
      or node.node_type == "index_item" then
    return
  end

  if node.expanded then
    node.expanded = false
    util.render_tree(context)
  else
    if node.children then
      node.expanded = true
      util.render_tree(context)
    else
      util.refresh_subtree(node, context, node.node_type, get_search_dir(context.source_buf))
    end
  end
end

local LEAF_TYPES = {
  column = true, index = true, key_item = true, fk_item = true, index_item = true,
}

local function get_indent(buf, line_nr)
  local text = vim.api.nvim_buf_get_lines(buf, line_nr - 1, line_nr, false)[1] or ""
  local leading = text:match("^%s*") or ""
  return math.floor(#leading / 2)
end

local function find_parent_line(buf, start_line_nr, current_depth, line_to_node, header_lines)
  for line = start_line_nr - 1, header_lines + 1, -1 do
    local parent_depth = get_indent(buf, line)
    if parent_depth < current_depth then
      local idx = line - header_lines
      if idx >= 1 and idx <= #line_to_node and line_to_node[idx] then
        return line
      end
    end
  end
  return nil
end

function M.collapse_or_parent(buf_line, context)
  local node = tree.get_node_at_line(context.line_to_node, buf_line)
  if not node then return end

  local is_leaf = LEAF_TYPES[node.node_type]
  local current_depth = get_indent(context.browser_buf, buf_line)

  if not is_leaf and node.expanded then
    -- Collapse: fold children, stay on this node
    node.expanded = false
    util.render_tree(context)
    -- Keep cursor on the collapsed node
    for i, n in ipairs(context.line_to_node) do
      if n == node then
        vim.api.nvim_win_set_cursor(0, { i + HEADER_LINES, 0 })
        return
      end
    end
  else
    -- Go to parent (leaf, or non-leaf already collapsed)
    local parent_line = find_parent_line(context.browser_buf, buf_line, current_depth, context.line_to_node, HEADER_LINES)
    if parent_line then
      vim.api.nvim_win_set_cursor(0, { parent_line, 0 })
    end
  end
end

function M.expand_or_child(buf_line, context)
  local node = tree.get_node_at_line(context.line_to_node, buf_line)
  if not node then return end

  local is_leaf = LEAF_TYPES[node.node_type]
  if is_leaf then return end

  if not node.expanded then
    -- Expand node directly (don't call toggle_node which executes SELECT on tables)
    if node.children then
      node.expanded = true
      util.render_tree(context)
    else
      -- Same directory as every other fetch: the search dir decides which
      -- connections.toml the CLI picks up, and cwd is only its fallback.
      util.refresh_subtree(node, context, node.node_type, get_search_dir(context.source_buf))
    end
  else
    -- Already expanded → jump to first child (next line)
    local total_lines = vim.api.nvim_buf_line_count(context.browser_buf)
    local next_line = buf_line + 1
    if next_line <= total_lines then
      local next_depth = get_indent(context.browser_buf, next_line)
      local current_depth = get_indent(context.browser_buf, buf_line)
      if next_depth > current_depth then
        vim.api.nvim_win_set_cursor(0, { next_line, 0 })
      end
    end
  end
end

function M.refresh_node(buf_line, context)
  local node = tree.get_node_at_line(context.line_to_node, buf_line)
  if not node then return end
  if node.node_type == "column" or node.node_type == "index"
      or node.node_type == "key_item" or node.node_type == "fk_item"
      or node.node_type == "index_item" then
    return
  end

  util.refresh_subtree(node, context, node.node_type, get_search_dir(context.source_buf))
end

--- Execute SELECT * on a table node and render results in the dataset buffer.
execute_table_select = function(node, context)
  local dialect = get_dialect(node, context.root_nodes)
  local conn = get_connection(node, context.root_nodes)
  local sql = "-- @connection " .. conn .. "\n"
    .. ops_sql.select_star_sql(ops_sql.qualified_table_ref(node, dialect), dialect)
  -- Same config discovery as every other browser fetch (toggle/refresh/
  -- show_table_info use get_search_dir): with the browser open over a SQL
  -- file in another directory, getcwd() read a different connections.toml
  -- than the same node's other actions did.
  local search_dir = get_search_dir(context.source_buf)

  local connections = require("poste-db.connections")
  local url, err = connections.resolve_connection_url(conn)
  if not url then
    vim.notify("Connection '" .. conn .. "' not found: " .. (err or "unknown"), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local exec_run = require("poste-db.exec_run")
  local job_id = exec_run.run_async(sql, {
    src_file = search_dir .. "/browser_select.sql",
    conn_url = url,
    database = node.meta and node.meta.database or nil,
    mode = "greedy",
    log_source = "browser",
    log_extra = { connection = conn },
  }, {
    on_response = function(parsed)
      local sql_format = require("poste-db.format")
      local sql_buffer = require("poste-db.buffer")
      local lines, meta, layout = sql_format.format_dataset(parsed)
      meta = meta or {}
      meta.table_name = node.name
      -- The browser runs the SELECT directly (not through sql_state.context),
      -- so bake its connection/database into the layout: the dataset edit
      -- path needs them for PK introspection / DML-commit.
      if layout then
        layout._conn_name = conn
        if not layout._database then
          layout._database = node.meta and node.meta.database
        end
      end
      -- Pass the fresh resultset explicitly: render_dataset otherwise falls
      -- back to state.last_response.body (only the sql_runner path updates
      -- it), so cell preview (K) / yank / sort would read stale rows.
      local data = core_util.decode_dataset_body(parsed)
      sql_buffer.render_dataset(lines, meta, {
        -- opts.data is the DECODED body (a previous `data = parsed` duplicate
        -- key here was silently overwritten — keep only the decoded value)
        data = data,
        layout = layout,
        original_sql = sql,
        src_file = "poste://db_browser",
        src_buf = context.source_buf,
      })
    end,
    on_error = function(message)
      vim.schedule(function()
        vim.notify("Query failed for '" .. node.name .. "': " .. message, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
      end)
    end,
  })

  if not job_id or job_id <= 0 then
    vim.notify("Failed to start poste job", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
  end
end

local function ensure_expanded(node, search_dir, callback)
  if node.expanded then
    callback()
  elseif node.children then
    node.expanded = true
    callback()
  else
    node.loading = true
    async.fetch_children(node, function()
      node.expanded = true
      callback()
    end, search_dir)
  end
end

local function expand_ancestors(ancestors, search_dir, callback, i)
  i = i or 1
  if i > #ancestors then
    callback()
    return
  end
  ensure_expanded(ancestors[i], search_dir, function()
    expand_ancestors(ancestors, search_dir, callback, i + 1)
  end)
end

local function highlight_match_chars(buf, line_to_node, matches)
  vim.api.nvim_buf_clear_namespace(buf, search_char_ns, 0, -1)
  for _, match in ipairs(matches) do
    for i, n in ipairs(line_to_node) do
      if n == match.node then
        local line_nr = i + HEADER_LINES - 1 -- 0-indexed
        local text = vim.api.nvim_buf_get_lines(buf, line_nr, line_nr + 1, false)[1] or ""
        local name_start = text:find(match.node.name, 1, true)
        if name_start and match.positions then
          for _, pos in ipairs(match.positions) do
            local char_col = name_start + pos - 2
            vim.api.nvim_buf_add_highlight(buf, search_char_ns, "PosteDbBrowserSearchChar",
              line_nr, char_col, char_col + 1)
          end
        end
        break
      end
    end
  end
end

--- The window actually showing the browser buffer. `do_jump` moves the cursor
--- from a `vim.schedule` after an async expand, so window 0 may by then be a
--- code buffer the user switched to — and the jump would scroll that one.
local function browser_win_for(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then return win end
  end
  return nil
end

local function do_jump(index)
  local s = search_state
  if #s.matches == 0 then return end

  index = ((index - 1) % #s.matches) + 1
  s.current = index

  local match = s.matches[index]
  local ctx = s.context
  local search_dir = get_search_dir(ctx.source_buf)

  expand_ancestors(match.ancestors, search_dir, function()
    vim.schedule(function()
      -- Update header with match info
      _G.poste_search_info = { pattern = s.pattern, current = s.current, total = #s.matches }
      util.render_tree(ctx)

      -- Highlight matching chars on all matches
      highlight_match_chars(ctx.browser_buf, ctx.line_to_node, s.matches)

      -- Line-level highlight only on current match
      local win = browser_win_for(ctx.browser_buf)
      for i, n in ipairs(ctx.line_to_node) do
        if n == match.node then
          local target_line = i + HEADER_LINES
          vim.api.nvim_buf_clear_namespace(ctx.browser_buf, search_hl_ns, 0, -1)
          vim.api.nvim_buf_add_highlight(ctx.browser_buf, search_hl_ns, "PosteDbBrowserSearchMatch",
            target_line - 1, 0, -1)
          if win then vim.api.nvim_win_set_cursor(win, { target_line, 0 }) end
          break
        end
      end
    end)
  end)
end

local function walk_tree(nodes, lower, ancestors, matches)
  for _, node in ipairs(nodes) do
    local ok, positions = fuzzy_match(node.name, lower)
    if ok then
      local anc = {}
      for _, a in ipairs(ancestors) do table.insert(anc, a) end
      table.insert(matches, { node = node, ancestors = anc, positions = positions })
    end
    if node.children then
      local new_anc = {}
      for _, a in ipairs(ancestors) do table.insert(new_anc, a) end
      table.insert(new_anc, node)
      walk_tree(node.children, lower, new_anc, matches)
    end
  end
end

function M.search_filter(buf_line, context)
  vim.ui.input({
    prompt = "Search: ",
    buf_options = { filetype = "" },
  }, function(input)
    if not input or input == "" then
      search_state = { matches = {}, current = 0, pattern = "", context = nil }
      _G.poste_search_info = nil
      util.render_tree(context)
      vim.api.nvim_buf_clear_namespace(context.browser_buf, search_hl_ns, 0, -1)
      vim.api.nvim_buf_clear_namespace(context.browser_buf, search_char_ns, 0, -1)
      return
    end

    local lower = input:lower()
    local matches = {}

    walk_tree(context.root_nodes, lower, {}, matches)

    if #matches > 0 then
      search_state = { matches = matches, current = 0, pattern = input, context = context }
      do_jump(1)
      return
    end

    -- No matches in visible tree
    _G.poste_search_info = { pattern = input, current = 0, total = 0 }
    vim.api.nvim_buf_clear_namespace(context.browser_buf, search_hl_ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(context.browser_buf, search_char_ns, 0, -1)
    util.render_tree(context)
  end)
end

function M.search_clear(context)
  local c = context or search_state.context
  if not c then return end
  search_state = { matches = {}, current = 0, pattern = "", context = nil }
  _G.poste_search_info = nil
  util.render_tree(c)
  vim.api.nvim_buf_clear_namespace(c.browser_buf, search_hl_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(c.browser_buf, search_char_ns, 0, -1)
end

function M.search_next()
  if #search_state.matches == 0 then return end
  do_jump(search_state.current + 1)
end

function M.search_prev()
  if #search_state.matches == 0 then return end
  -- current 0 means "searched, never jumped": from there N is the last match.
  -- ((0 - 1 - 1) % n) + 1 would land on the second-to-last and skip it.
  local cur = search_state.current
  do_jump(cur > 0 and cur - 1 or #search_state.matches)
end

function M.show_column_info(buf_line, context)
  local node = tree.get_node_at_line(context.line_to_node, buf_line)
  if not node or node.node_type ~= "column" then
    notify.info("Move cursor to a column")
    return
  end

  local meta = node.meta
  local lines = {}
  local label_width = 10

  local function add(label, value)
    if value ~= nil and value ~= "" and value ~= vim.NIL then
      lines[#lines + 1] = string.format("  %s%s  %s", string.rep(" ", label_width - #label), label, value)
    end
  end

  add("Type",     meta.col_type)
  -- A NULL default (`DEFAULT NULL`) and no default at all are different facts;
  -- the old `tostring()` collapsed the absent one into the word "nil".
  if meta.default == vim.NIL then
    add("Default", "(null)")
  elseif meta.default ~= nil then
    add("Default", tostring(meta.default))
  end
  add("Nullable", meta.nullable == true and "YES" or (meta.nullable == false and "NO" or "?"))
  add("Extra",    meta.extra)
  -- Tested before the concatenation, not inside add(): a NULL comment used to
  -- reach `"'" .. meta.comment` and throw.
  local comment = meta.comment
  if comment ~= nil and comment ~= vim.NIL and comment ~= "" then
    add("Comment", "'" .. tostring(comment) .. "'")
  end
  add("Collation", meta.collation)

  vim.schedule(function()
    local title = "Column Info: " .. node.name
    require("poste-db.introspect").show_float(lines, title, "text")
  end)
end

function M.show_table_info(buf_line, context)
  local idx = buf_line - HEADER_LINES
  local table_node = M.find_table_node(context.line_to_node, idx)
  if not table_node then
    notify.info("Move cursor to a table node")
    return
  end

  local conn = get_connection(table_node, context.root_nodes)
  -- Listing-row names: `""` (the connection's own database) and a JSON null
  -- are both truthy, and an empty `--database` is applied by the CLI as
  -- replace_database_in_url — the table info came back for the wrong target.
  local schema = core_util.named(table_node.meta and table_node.meta.schema)
  local database = core_util.named(table_node.meta and table_node.meta.database)
  local dialect = get_dialect(table_node, context.root_nodes)

  local connections = require("poste-db.connections")
  local url, url_err = connections.resolve_connection_url(conn)
  if not url then
    vim.notify("Table info: " .. (url_err or "unknown error"), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local cmd = { "introspect", "--connection-url", url, "--type", "table_info", "--table", table_node.name }
  if dialect == "postgres" and schema then
    table.insert(cmd, "--schema"); table.insert(cmd, schema)
  end
  if database then
    table.insert(cmd, "--database"); table.insert(cmd, database)
  end

  local sql_log = require("poste-db.sql_log")
  local journal = sql_log.cli_fields(cmd, "browser")
  journal.connection = conn -- friendly name beats the redacted URL here
  local t0 = vim.uv.now()
  local journaled = false
  local function journal_once(status, error_msg)
    if journaled then return end
    journaled = true
    sql_log.record(vim.tbl_extend("force", journal, {
      status = status,
      elapsed_ms = vim.uv.now() - t0,
      error_msg = error_msg,
    }))
  end
  local stderr_buf = {}

  cli.run_async(cmd, {
    on_stdout = function(data)
      data = core_util.ensure_job_data(data)
      if #data == 0 then return end
      local output = table.concat(data, "\n")
      local ok, parsed = pcall(vim.json.decode, output)
      if not ok or type(parsed) ~= "table" then
        vim.schedule(function()
          notify.warn("Table info: failed to parse response")
        end)
        journal_once("error", "failed to parse response")
        return
      end
      deep_clean(parsed)
      local items = parsed.items
      if not items or #items == 0 then
        vim.schedule(function()
          notify.warn("Table info: no data returned")
        end)
        journal_once("error", "no data returned")
        return
      end
      journal_once("success", nil)
      local info = items[1]
      local lines = {}
      table.insert(lines, "Table:  " .. (info.table_name or "?"))
      if info.schema_name then
        table.insert(lines, "Schema: " .. info.schema_name)
      end
      if info.engine then
        table.insert(lines, "Engine: " .. info.engine)
      end
      if info.row_count ~= nil or info.row_count_estimate ~= nil then
        local rc = info.row_count or info.row_count_estimate
        table.insert(lines, "Rows:   " .. tostring(rc))
      end
      if info.data_length ~= nil then
        table.insert(lines, "Data:   " .. format_bytes(info.data_length))
      end
      if info.index_length ~= nil then
        table.insert(lines, "Index:  " .. format_bytes(info.index_length))
      end
      if info.data_size then
        table.insert(lines, "Data:   " .. info.data_size)
      end
      if info.index_size then
        table.insert(lines, "Index:  " .. info.index_size)
      end
      if info.total_size then
        table.insert(lines, "Total:  " .. info.total_size)
      end
      if info.create_time then
        table.insert(lines, "Created: " .. info.create_time)
      end
      if info.update_time then
        table.insert(lines, "Updated: " .. info.update_time)
      end
      if info.collation then
        table.insert(lines, "Collation: " .. info.collation)
      end
      if info.auto_increment then
        table.insert(lines, "Auto-inc:  " .. tostring(info.auto_increment))
      end
      if info.comment and info.comment ~= "" then
        table.insert(lines, "Comment: " .. info.comment)
      end
      vim.schedule(function()
        local title = "Table Info: " .. (info.table_name or "?")
        require("poste-db.introspect").show_float(lines, title, "text")
      end)
    end,
    on_stderr = function(data)
      if not data or #data == 0 then return end
      -- Surfaced live, and kept for the journal line below: an exit code on its
      -- own tells a user reviewing `<leader>l` nothing they can act on.
      for _, l in ipairs(data) do
        if l ~= "" then stderr_buf[#stderr_buf + 1] = l end
      end
      vim.schedule(function()
        notify.warn("Table info: " .. table.concat(data, "\n"))
      end)
    end,
    on_exit = function(code)
      if code ~= 0 then
        vim.schedule(function()
          notify.warn("Table info fetch failed (exit " .. tostring(code) .. ")")
        end)
        local reason = table.concat(stderr_buf, "\n")
        journal_once("error", reason ~= "" and reason or ("exit code " .. tostring(code)))
      end
    end,
  })
end

return M
