local icons = require("poste-db.db_browser.icons")
local ICONS = icons.ICONS
local DIALECT_ICONS = icons.DIALECT_ICONS
local MARKER_COLLAPSED = icons.MARKER_COLLAPSED
local MARKER_EXPANDED = icons.MARKER_EXPANDED
local MARKER_LOADING = icons.MARKER_LOADING
local MARKER_SELECTED = icons.MARKER_SELECTED
local MARKER_UNSELECTED = icons.MARKER_UNSELECTED
local HEADER_LINES = icons.HEADER_LINES
local hl_ns = icons.hl_ns

local M = {}

--- A JSON `null` decodes to vim.NIL, which is **truthy**, so the `x or ""`
--- fallback used everywhere here lets it straight through — and every later
--- `" " .. meta.col_type` or `meta.extra:lower()` then errors out, which for
--- `flatten_tree` means the whole browser refuses to draw. Collapse a null to
--- the fallback at the node boundary, where the value is still cheap to judge.
--- @param value any decoded JSON value
--- @param fallback any
function M.null_or(value, fallback)
  if value == nil or type(value) == "userdata" then return fallback end
  return value
end

function M.make_connection_node(conn_info)
  return {
    node_type = "connection",
    name = conn_info.name,
    full_name = conn_info.name,
    children = nil,
    expanded = false,
    loading = false,
    meta = {
      dialect = conn_info.dialect,
      host = conn_info.host,
      port = conn_info.port,
      database = conn_info.database,
      path = conn_info.path,
    },
  }
end

function M.make_database_node(item, conn_name, dialect)
  -- The name is null_or'd like every other listing field: a null name decodes
  -- to the truthy vim.NIL, and flatten_tree's `" " .. node.name` (and the
  -- full_name concatenations below, at construction time) would raise — the
  -- whole browser refuses to draw. Same fallback the col_type branch uses.
  local name = M.null_or(item.name, "?")
  return {
    node_type = "database",
    name = name,
    full_name = conn_name .. "/" .. name,
    children = nil,
    expanded = false,
    loading = false,
    meta = { dialect = dialect, connection = conn_name },
  }
end

function M.make_schema_node(item, conn_name, database)
  local name = M.null_or(item.name, "?")
  return {
    node_type = "schema",
    name = name,
    full_name = conn_name .. "/" .. database .. "/" .. name,
    children = nil,
    expanded = false,
    loading = false,
    meta = { database = database, connection = conn_name },
  }
end

function M.make_table_node(item, schema, database, conn_name)
  local name = M.null_or(item.name, "?")
  return {
    node_type = "table",
    name = name,
    full_name = (schema and schema .. "." or "") .. name,
    children = nil,
    expanded = false,
    loading = false,
    meta = {
      table_type = M.null_or(item.type, "BASE TABLE"),
      schema = schema,
      database = database,
      connection = conn_name,
      comment = M.null_or(item.comment, ""),
    },
  }
end

function M.make_column_node(item)
  local icon = ICONS.column
  local is_pk = false
  if item.pk or item.key == "PRI" then
    icon = ICONS.column_pk
    is_pk = true
  elseif item.key == "MUL" or item.is_fk then
    icon = ICONS.column_fk
  end

  return {
    node_type = "column",
    name = item.name,
    full_name = item.name,
    children = {},
    expanded = false,
    loading = false,
    meta = {
      -- col_type/extra/comment reach string operations in flatten_tree and the
      -- info float, so a null has to become the placeholder here. `default` and
      -- `collation` stay as they are: their readers test for vim.NIL, and a NULL
      -- default is a different fact from no default.
      col_type = M.null_or(item.type, "?"),
      nullable = item.nullable,
      default = item.default,
      extra = M.null_or(item.extra, ""),
      comment = M.null_or(item.comment, ""),
      collation = item.collation,
      is_pk = is_pk,
      icon = icon,
    },
  }
end

function M.flatten_tree(nodes, depth, multi_select)
  depth = depth or 0
  multi_select = multi_select or {}
  local lines = {}
  local node_map = {}
  local count_ranges = {}

  for _, node in ipairs(nodes) do
    local indent = string.rep("  ", depth)
    local icon = ICONS[node.node_type] or "  "

    if node.node_type == "connection" and node.meta and node.meta.dialect then
      icon = DIALECT_ICONS[node.meta.dialect] or icon
    end
    if node.node_type == "column" and node.meta and node.meta.icon then
      icon = node.meta.icon
    end
    if node.node_type == "key_item" and node.meta and not node.meta.is_pk then
      icon = ICONS.index
    end
    if node.node_type == "index_item" and node.meta and node.meta.is_pk then
      icon = ICONS.column_pk
    end

    local marker
    if node.node_type == "table" and multi_select.active then
      if multi_select.selected and multi_select.selected[node] then
        marker = MARKER_SELECTED .. " "
      else
        marker = MARKER_UNSELECTED .. " "
      end
    elseif node.node_type == "column" or node.node_type == "index"
        or node.node_type == "key_item" or node.node_type == "fk_item"
        or node.node_type == "index_item" then
      marker = "  "
    elseif node.loading then
      marker = MARKER_LOADING .. " "
    elseif node.expanded then
      marker = MARKER_EXPANDED .. " "
    else
      marker = MARKER_COLLAPSED .. " "
    end

    local suffix = ""
    if node.node_type == "column" and node.meta then
      suffix = " " .. (node.meta.col_type or "?")
      if node.meta.is_pk then
        suffix = suffix .. " PK"
      end
      if node.meta.extra and node.meta.extra:lower():find("auto_increment") then
        suffix = suffix .. " auto_increment"
      end
    end

    local type_suffix = ""
    if node.node_type == "table" and node.meta and node.meta.table_type == "VIEW" then
      type_suffix = " (view)"
    end

    local prefix = indent .. marker .. icon .. " " .. node.name .. type_suffix
    local count_text = ""
    if node.children and #node.children > 0 then
      count_text = " " .. #node.children
    end

    local line = prefix .. suffix .. count_text
    table.insert(lines, line)
    table.insert(node_map, node)

    if count_text ~= "" then
      local col_start = #prefix + #suffix
      table.insert(count_ranges, { #lines, col_start, col_start + #count_text })
    end

    if node.expanded and node.children then
      local line_offset = #lines
      local child_lines, child_map, child_ranges = M.flatten_tree(node.children, depth + 1, multi_select)
      for _, cl in ipairs(child_lines) do table.insert(lines, cl) end
      for _, cn in ipairs(child_map) do table.insert(node_map, cn) end
      for _, cr in ipairs(child_ranges) do
        table.insert(count_ranges, { cr[1] + line_offset, cr[2], cr[3] })
      end
    end
  end

  return lines, node_map, count_ranges
end

--- First non-space byte of `text` (1-based), 0 for an all-space line, plus
--- whether that position starts one of the tree's 3-byte markers. The shared
--- front half of `calc_icon_position` and `apply_highlights`: both must agree
--- on where the icon starts, so the marker list lives here and nowhere else.
local function scan_prefix(text)
  local first_content = 0
  for ci = 1, #text do
    if text:byte(ci) ~= 0x20 then first_content = ci; break end
  end
  if first_content == 0 then return 0, false end
  local first_3 = text:sub(first_content, first_content + 2)
  local is_marker = first_3 == MARKER_EXPANDED or first_3 == MARKER_COLLAPSED
    or first_3 == MARKER_LOADING or first_3 == MARKER_SELECTED
    or first_3 == MARKER_UNSELECTED
  return first_content, is_marker
end

local function calc_icon_position(text)
  local first_content, is_marker = scan_prefix(text)
  if first_content == 0 then return -1 end
  if is_marker then
    return first_content + 3
  else
    return first_content - 1
  end
end

local icon_hl = {
  connection  = "PosteDbBrowserIconConn",
  database    = "PosteDbBrowserIconDb",
  schema      = "PosteDbBrowserIconSchema",
  table       = "PosteDbBrowserIconTable",
  column      = "PosteDbBrowserIconCol",
  index       = "PosteDbBrowserCount",
  key_group   = "PosteDbBrowserIconPk",
  fk_group    = "PosteDbBrowserIconFk",
  index_group = "PosteDbBrowserCount",
  key_item    = "PosteDbBrowserCount",
  fk_item     = "PosteDbBrowserIconFk",
  index_item  = "PosteDbBrowserCount",
}

function M.apply_highlights(buf, line_count, count_ranges, line_to_node, multi_select)
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)

  for _, cr in ipairs(count_ranges or {}) do
    local lnum, col_start, col_end = cr[1], cr[2], cr[3]
    vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteDbBrowserCount",
      lnum + HEADER_LINES - 1, col_start, col_end)
  end

  for i = HEADER_LINES + 1, line_count do
    local node_idx = i - HEADER_LINES
    local node = line_to_node[node_idx]
    if not node then goto continue end

    local text = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""

    local first_content, is_marker = scan_prefix(text)
    if first_content == 0 then goto continue end

    local icon_byte_start
    if is_marker then
      icon_byte_start = first_content + 3
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteDbBrowserMarker",
        i - 1, first_content - 1, first_content + 2)
    else
      icon_byte_start = first_content - 1
    end

    local icon_hl_group = icon_hl[node.node_type]

    if node.node_type == "table" and multi_select and multi_select.active
        and multi_select.selected and multi_select.selected[node] then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteDbBrowserSelected",
        i - 1, 0, -1)
    end

    if node.node_type == "column" and node.meta then
      if node.meta.is_pk then
        icon_hl_group = "PosteDbBrowserIconPk"
      elseif node.meta.icon == ICONS.column_fk then
        icon_hl_group = "PosteDbBrowserIconFk"
      end
    end
    if node.node_type == "key_item" and node.meta and node.meta.is_pk then
      icon_hl_group = "PosteDbBrowserIconPk"
    end
    if node.node_type == "fk_item" then
      icon_hl_group = "PosteDbBrowserIconFk"
    end
    if node.node_type == "index_item" and node.meta then
      icon_hl_group = node.meta.is_pk and "PosteDbBrowserIconPk" or "PosteDbBrowserCount"
    end

    local icon_char = text:sub(icon_byte_start + 1)
    local icon_len = 3
    local first_byte = icon_char:byte(1)
    if first_byte and first_byte < 128 then icon_len = 1 end

    if icon_hl_group then
      vim.api.nvim_buf_add_highlight(buf, hl_ns, icon_hl_group,
        i - 1, icon_byte_start, icon_byte_start + icon_len)
    end

    if node.node_type == "index" or node.node_type == "index_item"
        or node.node_type == "key_item" or node.node_type == "fk_item" then
      local text_start = icon_byte_start + icon_len
      if text_start < #text then
        vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteDbBrowserCount",
          i - 1, text_start, -1)
      end
    end

    if node.node_type == "column" and node.meta then
      local name_pos = text:find(node.name, 1, true)
      if name_pos then
        local name_end = name_pos + #node.name - 1
        local after_name = text:sub(name_end + 1)
        local type_match = after_name:match("^ (%w+)")
        local parens = after_name:match("^ %w+(%([%d,]*%))")
        if type_match then
          local type_end = name_end + 1 + #type_match
          if parens then type_end = type_end + #parens end
          local remaining = text:sub(type_end)
          if remaining:find("^ auto_increment") then
            type_end = type_end + 15
          end
          vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteDbBrowserType",
            i - 1, name_end, type_end)
          if type_end < #text then
            vim.api.nvim_buf_add_highlight(buf, hl_ns, "PosteDbBrowserCount",
              i - 1, type_end, -1)
          end
        end
      end
    end

    ::continue::
  end
end

--- Build the browser winbar: title, search state, and multi-select count.
--- `%<` makes the state parts truncate first so the title always stays visible
--- in narrow splits. The yanked indicator lives on the statusline (see
--- db_browser/statusline.lua) because it is persistent state, not window state.
function M.build_winbar(multi_select)
  local winbar = " DB Browser"
  local si = _G.poste_search_info
  if si and si.pattern ~= "" then
    if si.total == 0 then
      winbar = " Search: " .. si.pattern .. " (0 matches)"
    else
      winbar = " Search: " .. si.pattern .. " (" .. si.current .. "/" .. si.total .. ")"
    end
  end

  if multi_select and multi_select.active then
    local count = 0
    for _ in pairs(multi_select.selected or {}) do
      count = count + 1
    end
    if count > 0 then
      winbar = winbar .. "%#PosteDbBrowserSelected#  [" .. count .. " selected]%*"
    end
  end

  return winbar
end

--- Refresh only the winbar (no tree re-render). Used right after a yank, where
--- the tree content is unchanged.
function M.update_winbar(browser_buf, multi_select)
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end
  local browser_win
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == browser_buf then
      browser_win = win
      break
    end
  end
  if browser_win then
    vim.api.nvim_set_option_value("winbar", M.build_winbar(multi_select), { win = browser_win })
  end
end

function M.render_tree(browser_buf, line_to_node, root_nodes, conn_label, multi_select)
  if not browser_buf or not vim.api.nvim_buf_is_valid(browser_buf) then return end

  local lines, node_map, count_ranges = M.flatten_tree(root_nodes, 0, multi_select)

  M.update_winbar(browser_buf, multi_select)

  vim.api.nvim_set_option_value("modifiable", true, { buf = browser_buf })
  vim.api.nvim_buf_set_lines(browser_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })

  if #lines == 0 then
    vim.api.nvim_set_option_value("modifiable", true, { buf = browser_buf })
    vim.api.nvim_buf_set_lines(browser_buf, 0, -1, false, { "  (no connections found)", "  need: connections.toml" })
    vim.api.nvim_set_option_value("modifiable", false, { buf = browser_buf })
  end

  M.apply_highlights(browser_buf, #lines, count_ranges, node_map, multi_select)

  return node_map
end

function M.get_node_at_line(line_to_node, buf_line)
  local idx = buf_line - HEADER_LINES
  if idx < 1 or idx > #line_to_node then return nil end
  return line_to_node[idx]
end

function M.calc_icon_position(text)
  return calc_icon_position(text)
end

return M