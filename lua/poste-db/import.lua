local sql_state = require("poste-db.state")

local async = require("poste-db.db_browser.async")

local fmt = require("poste-db.import.format")
local mapping = require("poste-db.import.mapping")
local preview = require("poste-db.import.preview")
local execute = require("poste-db.import.execute")
local const = require("poste-db.constants")

local M = {}

local function get_columns_from_node(table_node)
  if not table_node.children or #table_node.children == 0 then return nil end
  local cols = {}
  for _, child in ipairs(table_node.children) do
    if child.node_type == "column" then
      table.insert(cols, {
        name = child.name,
        col_type = child.meta and child.meta.col_type or "TEXT",
        is_pk = child.meta and child.meta.is_pk or false,
        nullable = child.meta and child.meta.nullable ~= false,
        default = child.meta and child.meta.default or nil,
        extra = child.meta and child.meta.extra or "",
      })
    end
  end
  if #cols == 0 then return nil end
  return cols
end

local function fetch_columns_async(node, context, callback)
  local conn = node.meta and node.meta.connection or sql_state.db_browser.connection
  local dir = vim.fn.getcwd()
  if context.source_buf and vim.api.nvim_buf_is_valid(context.source_buf) then
    local buf_name = vim.api.nvim_buf_get_name(context.source_buf)
    if buf_name ~= "" then dir = vim.fn.fnamemodify(buf_name, ":p:h") end
  end

  vim.notify("Loading column info for " .. node.name .. "...", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })

  async.run_introspect(conn, "columns", node.meta and node.meta.schema, node.name,
    node.meta and node.meta.database, function(result)
    if not result or not result.items then
      vim.notify("Failed to load column info for " .. node.name, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
      callback(nil)
      return
    end
    local cols = {}
    for _, item in ipairs(result.items) do
      table.insert(cols, {
        name = item.name,
        col_type = item.type or "TEXT",
        is_pk = item.pk or false,
        nullable = item.nullable ~= false,
        default = item.default,
        extra = item.extra or "",
      })
    end
    callback(cols)
  end, dir)
end

local function get_or_fetch_columns(node, context, callback)
  local cols = get_columns_from_node(node)
  if cols then
    callback(cols)
    return
  end
  fetch_columns_async(node, context, callback)
end

local function get_search_dir(context)
  if context.source_buf and vim.api.nvim_buf_is_valid(context.source_buf) then
    local buf_name = vim.api.nvim_buf_get_name(context.source_buf)
    if buf_name ~= "" then return vim.fn.fnamemodify(buf_name, ":p:h") end
  end
  return vim.fn.getcwd()
end

local function build_table_info(node, context)
  local dialect = "postgres"
  if node.meta and node.meta.dialect then
    dialect = node.meta.dialect
  else
    local conn_name = node.meta and node.meta.connection
    for _, root in ipairs(context.root_nodes) do
      if root.name == conn_name then dialect = root.meta and root.meta.dialect or "postgres"; break end
    end
  end
  return {
    name = node.name,
    schema = node.meta and node.meta.schema,
    database = node.meta and node.meta.database,
    connection = node.meta and node.meta.connection,
    dialect = dialect,
    search_dir = get_search_dir(context),
  }
end

local function pick_source(callback)
  vim.ui.select({
    "From File...",
    "From Clipboard",
  }, {
    prompt = "Import source:",
  }, function(choice)
    if not choice then
      callback(nil)
      return
    end
    if choice == "From Clipboard" then
      callback("clipboard", nil)
    else
      callback("file", nil)
    end
  end)
end

local function read_source(source_type, path)
  if source_type == "clipboard" then
    local content = vim.fn.getreg("+")
    if not content or content == "" then
      return nil, "Clipboard is empty"
    end
    content = content:gsub("\n$", "")
    return content, nil
  end

  if not path then
    return nil, "No file selected"
  end

  local f, err = io.open(path, "r")
  if not f then
    return nil, "Cannot open file: " .. tostring(err)
  end
  local content = f:read("*a")
  f:close()

  if not content or content == "" then
    return nil, "File is empty"
  end

  return content, nil
end

local function process_import(content, filepath, table_info, table_cols)
  local format = fmt.detect_format(content, filepath)
  if not format then
    vim.notify("Could not detect data format (supported: CSV, TSV, JSON)", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local source_label = filepath or "clipboard"

  local parsed, err
  if format == "csv" then
    parsed, err = fmt.parse_csv(content)
  elseif format == "tsv" then
    parsed, err = fmt.parse_tsv(content)
  elseif format == "json" then
    parsed, err = fmt.parse_json(content)
  end

  if not parsed then
    vim.notify(string.format("Parse error (%s): %s", source_label, err or "unknown"), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  if #parsed.rows == 0 then
    vim.notify("No data rows found in " .. source_label, vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return
  end

  local col_map, unmatched_import, unmatched_table = mapping.build_column_map(parsed.columns, table_cols)

  if #col_map == 0 then
    vim.notify("No columns matched between import data and table " .. table_info.name
      .. " (import columns: " .. table.concat(parsed.columns, ", ") .. ")", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  if #unmatched_import > 0 then
    -- The message prints `unmatched_import` as the problem, then used to print
    -- `parsed.columns` under "matched:" — the whole file header again, i.e. the
    -- union of both sets, which reads as "these matched" while the import was
    -- being blocked for exactly those columns.
    local matched = {}
    for _, mc in ipairs(col_map) do
      table.insert(matched, mc.import_name)
    end
    vim.notify("Import blocked: file has columns not in table " .. table_info.name
      .. ": " .. table.concat(unmatched_import, ", ")
      .. " (matched: " .. table.concat(matched, ", ") .. ")", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local valid_rows, bad_rows = mapping.validate_and_type(parsed.rows, col_map)

  preview.show_preview(table_info, #parsed.rows, #valid_rows, bad_rows,
    col_map, unmatched_import, unmatched_table, parsed.columns, parsed.rows, function(action)
    if not action then
      vim.notify("Import cancelled", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
      return
    end

    local rows_to_import = valid_rows
    if action == "skip" and #bad_rows > 0 then
      -- 'skip' and 'proceed' import the same rows (valid_rows never
      -- contained the rejected ones); 'skip' just confirms it out loud.
      vim.notify(string.format("Skipping %d row(s) with validation errors", #bad_rows), vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    end

    -- no callback: execute_import reports success/errors itself
    execute.execute_import(table_info, rows_to_import, col_map, table_cols)
  end)
end

function M.run(table_node, context)
  if table_node.meta and table_node.meta.table_type == "VIEW" then
    vim.notify("Cannot import data into a view", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return
  end

  local table_info = build_table_info(table_node, context)

  get_or_fetch_columns(table_node, context, function(table_cols)
    if not table_cols or #table_cols == 0 then
      vim.notify("Could not determine table columns for " .. table_node.name, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
      return
    end

    pick_source(function(source_type, _)
      if not source_type then return end

      if source_type == "file" then
        local ok, finder = pcall(require, "finder")
        if not ok then
          vim.notify("beyondlex/finder plugin required for file selection", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
          return
        end
        finder.open({
          mode = "both",
          initial_path = (vim.fn.has("mac") == 1 and vim.fn.expand("~/Downloads"))
            or (vim.fn.has("unix") == 1 and vim.fn.expand("~"))
            or vim.fn.expand("~/Desktop"),
          extensions = { "csv", "tsv", "json" },
          on_confirm = function(path)
            if not path then return end
            local content, err = read_source("file", path)
            if not content then
              vim.notify("Import error: " .. tostring(err), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
              return
            end
            process_import(content, path, table_info, table_cols)
          end,
          on_cancel = function() end,
        })
      else
        local content, err = read_source("clipboard")
        if not content then
          vim.notify("Import error: " .. tostring(err), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
          return
        end
        process_import(content, nil, table_info, table_cols)
      end
    end)
  end)
end

if _G._TEST then
  M._parse_csv_for_test = fmt.parse_csv
  M._parse_tsv_for_test = fmt.parse_tsv
  M._parse_json_for_test = fmt.parse_json
  M._detect_format_for_test = fmt.detect_format
  M._build_column_map_for_test = mapping.build_column_map
  M._coerce_value_for_test = mapping.coerce_value
  M._validate_and_type_for_test = mapping.validate_and_type
end

return M
