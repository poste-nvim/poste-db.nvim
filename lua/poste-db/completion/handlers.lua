--- SQL completion context dispatch helpers.
---
--- Extracts the large ctx_type switch from completion.lua so the orchestrator
--- can stay focused on context detection and result deduplication.
local data = require("poste-db.completion.data")
local ctx = require("poste-db.completion.ctx")
local const = require("poste-db.constants")
local state = require("poste-db.state")
local compat = require("poste-db.compat")

local M = {}

local function flush_items(callback, items)
  callback(items)
end

--- The word the cursor is inside, after a `.`.
---
--- Rust already isolated it; re-matching `line_before` here is a second copy of
--- that rule and a narrower one — `[%w_]+%.` cannot see a quoted qualifier, so
--- `"p"."ti` filtered on an empty prefix and listed every column.
local function typed_prefix(rust_ctx, line_before)
  if rust_ctx and rust_ctx.prefix ~= nil then
    return rust_ctx.prefix
  end
  return line_before:match("[%w_]+%.([%w_]*)$") or ""
end

function M.handle_directives(line_before, callback)
  if line_before:match(const.DIRECTIVE_PREFIX_PATTERN .. const.DIRECTIVE_CONNECTION) then
    -- The `%s+(%S*)$` form is the only one that can yield a prefix: matching
    -- the bare `@connection$` has no capture, so match() returns the whole
    -- match — the directive word itself became the filter and no connection
    -- name starts with `@`, which emptied the list on `-- @connection`.
    local cp = line_before:match("@" .. const.DIRECTIVE_CONNECTION .. "%s+(%S*)$") or ""
    data.ensure_conn_names(function(names)
      flush_items(callback, ctx.filter(ctx.make_items(names, 6, "connection: "), cp))
    end)
    return true
  end

  if line_before:match(const.DIRECTIVE_PREFIX_PATTERN .. const.DIRECTIVE_DATABASE) then
    local db_prefix = line_before:match("@" .. const.DIRECTIVE_DATABASE .. "%s+(%S*)$") or ""
    data.ensure_databases(function(names)
      if #names == 0 then
        data.ensure_conn_names(function(conn_names)
          local items = {}
          for _, name in ipairs(conn_names) do
            table.insert(items, {
              label = name,
              kind = 6,
              insertText = "",
              data = { directive_fallback = true, conn_name = name },
              documentation = "connection: " .. name,
            })
          end
          flush_items(callback, ctx.filter(items, db_prefix))
        end)
      else
        flush_items(callback, ctx.filter(ctx.make_items(names, 1, "database: "), db_prefix))
      end
    end)
    return true
  end

  if line_before:match(const.DIRECTIVE_PREFIX_PATTERN .. "%w*$") then
    local partial = line_before:match("@(%w*)$") or ""
    local directives = {
      "@" .. const.DIRECTIVE_CONNECTION,
      "@" .. const.DIRECTIVE_DATABASE,
    }
    local items = {}
    for _, d in ipairs(directives) do
      local name = d:sub(2)
      if ctx.fuzzy_match(name, partial) then
        table.insert(items, { label = d, kind = 14, insertText = d, documentation = "directive" })
      end
    end
    flush_items(callback, items)
    return true
  end

  return false
end

local function handle_connection(line_before, callback)
  local cp = line_before:match("@" .. const.DIRECTIVE_CONNECTION .. "$")
    or line_before:match("@" .. const.DIRECTIVE_CONNECTION .. "%s+(%S*)$")
    or ""
  data.ensure_conn_names(function(names)
    flush_items(callback, ctx.filter(ctx.make_items(names, 6, "connection: "), cp))
  end)
end

local function handle_database(line_before, ctx_data, callback)
  local db_prefix
  if ctx_data == "directive" then
    db_prefix = line_before:match("@" .. const.DIRECTIVE_DATABASE .. "$")
      or line_before:match("@" .. const.DIRECTIVE_DATABASE .. "%s+(%S*)$")
      or ""
  else
    db_prefix = line_before:match("[Uu][Ss][Ee]%s+(%S*)$") or ""
  end
  data.ensure_databases(function(names)
    if ctx_data == "directive" and #names == 0 then
      data.ensure_conn_names(function(conn_names)
        local items = {}
        for _, name in ipairs(conn_names) do
          table.insert(items, {
            label = name,
            kind = 6,
            insertText = "",
            data = { directive_fallback = true, conn_name = name },
            documentation = "connection: " .. name,
          })
        end
        flush_items(callback, ctx.filter(items, db_prefix))
      end)
    else
      flush_items(callback, ctx.filter(ctx.make_items(names, 1, "database: "), db_prefix))
    end
  end)
end

local function handle_dot_column(bufnr, line_before, cursor_line, ctx_data, rust_ctx, callback)
  local col_prefix = typed_prefix(rust_ctx, line_before)
  local _, alias_map, schema_map = ctx.get_tables_and_alias(rust_ctx)
  local real_tbl = alias_map[ctx_data] or ctx_data
  local schema = rust_ctx and rust_ctx.ctx_schema or schema_map[real_tbl]
  data.ensure_columns(real_tbl, schema, function()
    local key = data.conn_key()
    local cache = data.get_cache()
    local cache_tbl_key = schema and (schema .. "." .. real_tbl) or real_tbl
    local cols = cache[key] and cache[key].columns[cache_tbl_key] or {}
    flush_items(callback, ctx.filter(ctx.make_items(cols, 5, "col: "), col_prefix))
  end)
end

local function handle_schema_table(line_before, ctx_data, dialect, rust_ctx, callback)
  local schema_name = ctx_data
  local tbl_prefix = typed_prefix(rust_ctx, line_before)
  data.ensure_tables_for_db(schema_name, function()
    local key = data.conn_key()
    local db_cache_key = key .. "/db:" .. schema_name
    local cache = data.get_cache()
    local tbls = cache[db_cache_key] and cache[db_cache_key].tables or {}
    local items = {}
    for _, t in ipairs(tbls) do
      table.insert(items, {
        label = schema_name .. "." .. t,
        kind = 7,
        insertText = t,
        documentation = "table: " .. schema_name .. "." .. t,
      })
    end
    if #items == 0 then
      items = ctx.kw_items(tbl_prefix, dialect)
    end
    flush_items(callback, ctx.filter(items, tbl_prefix))
  end)
end

local function handle_table(prefix, dialect, callback)
  local pending = 2
  local all_items = {}
  local done = false
  local function flush()
    if done then return end
    done = true
    if #all_items == 0 then
      flush_items(callback, ctx.kw_items(prefix, dialect))
      return
    end
    flush_items(callback, ctx.filter(all_items, prefix))
  end

  -- For postgres, offer pg_catalog relations when the user types an
  -- unqualified `pg_` prefix (`FROM pg_tab`): pg_catalog is implicitly in the
  -- search path, but those tables are never part of the user-schema table
  -- list. Restricted to a `pg` prefix so they don't crowd the full table menu.
  if (dialect == "postgres" or dialect == "postgresql")
    and prefix:match("^[pP][gG]") then
    for _, t in ipairs(const.PG_CATALOG_TABLES) do
      table.insert(all_items, {
        label = t, kind = 7, insertText = t,
        documentation = "table: pg_catalog." .. t,
      })
    end
  end

  data.ensure_tables(function()
    local key = data.conn_key()
    local cache = data.get_cache()
    for _, t in ipairs(cache[key] and cache[key].tables or {}) do
      table.insert(all_items, { label = t, kind = 7, insertText = t, documentation = "table: " .. t })
    end
    pending = pending - 1
    if pending <= 0 then flush() end
  end)
  data.ensure_databases(function(names)
    for _, db in ipairs(names or {}) do
      table.insert(all_items, { label = db, kind = 1, insertText = db, documentation = "database: " .. db })
    end
    pending = pending - 1
    if pending <= 0 then flush() end
  end)
end

local function handle_column(bufnr, line_before, cursor_line, prefix, dialect, rust_functions, rust_ctx, callback)
  local from_tbls, alias_map, schema_map = ctx.get_tables_and_alias(rust_ctx)
  local real_tbls, seen_real = {}, {}
  for _, t in ipairs(from_tbls) do
    local real = alias_map[t] or t
    local schema = schema_map[real]
    local uniq_key = schema and (schema .. "." .. real) or real
    if not seen_real[uniq_key] then
      seen_real[uniq_key] = true
      table.insert(real_tbls, { name = real, schema = schema })
    end
  end

  if compat.opt("debug") then
    state.log("INFO", string.format("DEBUG: column context, %d tables: %s",
      #real_tbls, vim.inspect(real_tbls)))
  end

  if #real_tbls == 0 then
    local items = ctx.kw_items(prefix, dialect)
    vim.list_extend(items, ctx.func_items(prefix, rust_functions))
    flush_items(callback, items)
    return
  end
  local pending = #real_tbls
  local all = {}
  local seen_keys = {}
  local done = false
  local function flush()
    if done then return end
    done = true
    local items = ctx.filter(all, prefix)
    local funcs = ctx.func_items(prefix, rust_functions)
    if compat.opt("debug") then
      state.log("INFO", string.format("DEBUG flush: prefix='%s', %d cols, %d funcs (rust_functions=%s)",
        prefix, #items, #funcs, tostring(rust_functions ~= nil)))
    end
    vim.list_extend(items, funcs)
    if #all == 0 or #prefix > 0 then
      vim.list_extend(items, ctx.kw_items(prefix, dialect))
    end
    flush_items(callback, items)
  end
  for _, tbl_info in ipairs(real_tbls) do
    data.ensure_columns(tbl_info.name, tbl_info.schema, function()
      local key = data.conn_key()
      local cache = data.get_cache()
      local cache_tbl_key = tbl_info.schema and (tbl_info.schema .. "." .. tbl_info.name) or tbl_info.name
      local cols = cache[key] and cache[key].columns[cache_tbl_key] or {}

      for _, col in ipairs(cols) do
        local uniq = cache_tbl_key .. "." .. col
        if not seen_keys[uniq] then
          seen_keys[uniq] = true
          table.insert(all, {
            label = col,
            kind = 5,
            insertText = col,
            filterText = col,
            sortText = "1" .. col,
            documentation = "col: " .. uniq
          })
        end
      end
      pending = pending - 1
      if pending <= 0 then flush() end
    end)
  end
end

-- schema (from rust_ctx.ctx_schema) selects the cache entry and the column
-- lookup; without it, `INSERT INTO public.users (` would read the wrong key.
local function handle_insert_column(line_before, prefix, ctx_data, rust_ctx, callback)
  local tbl = ctx_data
  local schema = rust_ctx and rust_ctx.ctx_schema or nil
  local cache_tbl_key = schema and (schema .. "." .. tbl) or tbl
  local inside = line_before:match("%(([%w_,%s]*)$") or ""
  local seen = {}
  for col in inside:gmatch("([%w_]+)") do
    seen[col:lower()] = true
  end
  data.ensure_columns(tbl, schema, function()
    local key = data.conn_key()
    local cache = data.get_cache()
    local all = cache[key] and cache[key].columns[cache_tbl_key] or {}
    local result = {}
    if #all > 0 then
      local all_csv = table.concat(all, ", ")
      result[#result + 1] = {
        label = all_csv, kind = 8,
        insertText = all_csv,
        documentation = "Insert all columns",
      }
      local no_id = {}
      for _, c in ipairs(all) do
        if c:lower() ~= "id" then no_id[#no_id + 1] = c end
      end
      if #no_id > 0 and #no_id < #all then
        local no_id_csv = table.concat(no_id, ", ")
        result[#result + 1] = {
          label = no_id_csv, kind = 8,
          insertText = no_id_csv,
          documentation = "All columns except id",
        }
      end
    end
    for _, c in ipairs(all) do
      if not seen[c:lower()] and (prefix == "" or ctx.fuzzy_match(c, prefix)) then
        result[#result + 1] = { label = c, kind = 5, insertText = c, documentation = "col: " .. tbl .. "." .. c }
      end
    end
    flush_items(callback, result)
  end)
end

function M.dispatch(opts, ctx_type, ctx_data, rust_ctx, callback)
  local bufnr = opts.bufnr
  local line_before = opts.line_before or ""
  local cursor_line = opts.cursor_line
  local prefix = opts.prefix or ""
  local dialect = opts.dialect
  local rust_functions = opts.rust_functions

  if compat.opt("debug") then
    state.log("INFO", string.format("DEBUG get_items: ctx=%s, prefix='%s', line='%s'",
      tostring(ctx_type), prefix, line_before))
  end

  if ctx_type == "connection" then
    return handle_connection(line_before, callback)
  end

  if ctx_type == "database" then
    return handle_database(line_before, ctx_data, callback)
  end

  if ctx_type == "dot_column" then
    return handle_dot_column(bufnr, line_before, cursor_line, ctx_data, rust_ctx, callback)
  end

  if ctx_type == "schema_table" then
    return handle_schema_table(line_before, ctx_data, dialect, rust_ctx, callback)
  end

  if ctx_type == "table" then
    return handle_table(prefix, dialect, callback)
  end

  if ctx_type == "column" then
    return handle_column(bufnr, line_before, cursor_line, prefix, dialect, rust_functions, rust_ctx, callback)
  end

  if ctx_type == "insert_column" then
    return handle_insert_column(line_before, prefix, ctx_data, rust_ctx, callback)
  end

  if ctx_type == "datatype" then
    return flush_items(callback, ctx.filter(ctx.make_items(data.DATA_TYPES, 25, "type: "), prefix))
  end

  if ctx_type == "string" or ctx_type == "comment" then
    return flush_items(callback, {})
  end

  if line_before:match("^%s*%-%-%s*@") then
    return flush_items(callback, {})
  end

  if compat.opt("legacy_completion") == true then
    data.ensure_tables(function()
      local key = data.conn_key()
      local cache = data.get_cache()
      local tbls = cache[key] and cache[key].tables or {}
      local items = ctx.kw_items(prefix, dialect)
      vim.list_extend(items, ctx.func_items(prefix))
      for _, item in ipairs(ctx.filter(ctx.make_items(tbls, 7, "table: "), prefix)) do
        table.insert(items, item)
      end
      flush_items(callback, items)
    end)
  else
    local items = ctx.kw_items(prefix, dialect)
    vim.list_extend(items, ctx.func_items(prefix, rust_functions))
    flush_items(callback, items)
  end
end

return M
