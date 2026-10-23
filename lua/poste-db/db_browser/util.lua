
local sql_state = require("poste-db.state")
local core_util = require("poste-db.util")
local const = require("poste-db.constants")

local M = {}

function M.get_dialect(node, root_nodes)
  if node.meta and node.meta.dialect then return node.meta.dialect end
  local conn_name = node.meta and node.meta.connection or sql_state.db_browser.connection
  for _, root in ipairs(root_nodes or {}) do
    if root.name == conn_name then
      return root.meta and root.meta.dialect or "postgres"
    end
  end
  return "postgres"
end

function M.get_connection(node)
  if node.node_type == "connection" then return node.name end
  return node.meta and node.meta.connection or sql_state.db_browser.connection
end

function M.get_search_dir(source_buf)
  if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
    local buf_name = vim.api.nvim_buf_get_name(source_buf)
    if buf_name ~= "" then return vim.fn.fnamemodify(buf_name, ":p:h") end
  end
  return vim.fn.getcwd()
end

function M.find_table_node(line_to_node, start_idx)
  for i = start_idx, 1, -1 do
    local n = line_to_node[i]
    if n and n.node_type == "table" then return n end
    if n and (n.node_type == "database" or n.node_type == "schema" or n.node_type == "connection") then break end
  end
  return nil
end

--- Sync line_to_node with a freshly rendered line map, in place so every
--- holder of the table sees the same content. Entries past the new map are
--- dropped: a collapsed tree is shorter than the one it replaced, and the
--- leftover tail kept nodes that are no longer on any line.
function M.set_line_map(line_to_node, new_map)
  for i = 1, math.max(#line_to_node, #(new_map or {})) do
    line_to_node[i] = new_map and new_map[i] or nil
  end
end

--- Re-render the browser tree from `context` and sync the line map.
function M.render_tree(context)
  local tree = require("poste-db.db_browser.tree")
  -- multi_select must ride along: without it the ▣ markers vanish while the
  -- selection itself stays active, so the view lies about what `p` will paste.
  local new_map = tree.render_tree(context.browser_buf, context.line_to_node,
    context.root_nodes, context.conn_label, context.multi_select)
  M.set_line_map(context.line_to_node, new_map)
end

--- Human-readable byte size ("12.3 kB", "4.00 MB", ...). Non-numbers pass
--- through unchanged.
function M.format_bytes(bytes)
  if type(bytes) ~= "number" then return tostring(bytes or "?") end
  if bytes >= 1073741824 then return string.format("%.2f GB", bytes / 1073741824) end
  if bytes >= 1048576 then return string.format("%.2f MB", bytes / 1048576) end
  if bytes >= 1024 then return string.format("%.2f kB", bytes / 1024) end
  return bytes .. " B"
end

--- Split `text` into chunks of at most `chunk_bytes` bytes without splitting
--- a UTF-8 character (the cut backs up over continuation bytes). Server error
--- text is user- and data-supplied and routinely CJK; the byte-chunk loops it
--- replaced split glyphs and put U+FFFD replacement characters into the copy/
--- drop summary dialogs. Empty text wraps to no chunks, like the byte loop.
function M.wrap_utf8(text, chunk_bytes)
  local chunks = {}
  local pos = 1
  while pos <= #text do
    local chunk = core_util.utf8_safe_cut(text:sub(pos), chunk_bytes)
    if chunk == "" then
      -- A budget smaller than one character: keep that character whole
      -- rather than loop forever on an empty cut.
      chunk = text:sub(pos, pos + core_util.utf8_char_bytes(text:byte(pos)) - 1)
    end
    chunks[#chunks + 1] = chunk
    pos = pos + #chunk
  end
  return chunks
end

--- Invalidate `target_node` up to its `node_type` ancestor, then reload that
--- ancestor's children and re-render. Shared by every tree-refresh dance.
function M.refresh_subtree(target_node, context, node_type, search_dir)
  local parent = target_node
  while parent and parent.node_type ~= node_type do
    parent = parent.parent
  end
  if not parent then return end

  parent.children = nil
  parent.expanded = false
  parent.loading = true

  M.render_tree(context)

  local async = require("poste-db.db_browser.async")
  async.fetch_children(parent, function()
    parent.expanded = true
    vim.schedule(function()
      M.render_tree(context)
    end)
  end, search_dir or vim.fn.getcwd())
end

--- Drop the completion schema cache after browser-side DDL. The browser
--- executes outside the SQL runner's response hook, so without this completion
--- keeps offering dropped tables (and misses created ones).
function M.invalidate_completion_cache()
  pcall(function() require("poste-db.completion.data").clear_cache() end)
end

--- Execute a DDL statement through exec_run, report the outcome, and refresh
--- the affected browser subtree. Shared by the create-schema / create-database
--- dialogs.
---
--- opts: { success_msg, fail_prefix, pending_msg, database?, target_node?, node_type }
function M.run_ddl_and_refresh(sql, conn_name, context, opts)
  local notify = require("poste-db.db_browser.notify")
  notify.info(opts.pending_msg)

  local connections = require("poste-db.connections")
  local url, err = connections.resolve_connection_url(conn_name)
  if not url then
    vim.notify(opts.fail_prefix .. " failed: " .. (err or "unknown"), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local exec_run = require("poste-db.exec_run")
  local job_id = exec_run.run_async(sql, {
    conn_url = url,
    database = opts.database or nil,
    mode = "greedy",
    log_source = "browser",
    log_extra = { connection = conn_name },
  }, {
    on_response = function(resp)
      local ok_body, body = pcall(vim.json.decode, resp.body or "{}")
      if not ok_body or type(body) ~= "table" then
        body = {}
      end
      -- verdict.error_text normalizes the non-string family (JSON null is the
      -- truthy vim.NIL userdata — table.concat would raise on it).
      local verdict = require("poste-db.verdict")
      local errors = {}
      if body.results then
        for _, result in ipairs(body.results) do
          local text = verdict.error_text(type(result) == "table" and result.error or nil)
          if text then
            table.insert(errors, text)
          end
        end
      end
      if resp.has_error or body.has_error or #errors > 0 then
        local msg = table.concat(errors, "\n")
        if msg == "" then msg = "Unknown SQL error" end
        vim.notify(opts.fail_prefix .. " failed:\n" .. msg, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
      else
        notify.info(opts.success_msg)
        M.invalidate_completion_cache()
      end
      M.refresh_subtree(opts.target_node, context, opts.node_type)
    end,
    on_error = function(message)
      vim.notify(opts.fail_prefix .. " failed: " .. message, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    end,
  })

  if not job_id or job_id <= 0 then
    vim.notify(opts.fail_prefix .. ": failed to start poste process", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
  end
end

return M