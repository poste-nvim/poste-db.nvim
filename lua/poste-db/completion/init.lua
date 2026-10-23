--- SQL completion — orchestrator.
---
--- Provides completion for blink.cmp and nvim-cmp by:
--- 1. Calling the Rust CLI for context detection (full ### block)
--- 2. Falling back to plain keyword/function items when that fails
--- 3. Dispatching to the correct completion source (columns/tables/keywords)
local state = require("poste-db.state")
local data = require("poste-db.completion.data")
local ctx = require("poste-db.completion.ctx")
local debug = require("poste-db.completion.debug")
local const = require("poste-db.constants")
local handlers = require("poste-db.completion.handlers")
local compat = require("poste-db.compat")

local M = {}

-- Cache last context detect result to avoid re-spawning the binary
-- when the SQL text + offset + dialect haven't changed.
-- Keyed by bufnr|changedtick|offset|dialect for automatic invalidation.
local _ctx_cache = {}

---------------------------------------------------------------------------
-- Deep clean helper (vim.NIL → nil)
---------------------------------------------------------------------------

local function deep_clean(t)
  for k, v in pairs(t) do
    if v == vim.NIL then
      t[k] = nil
    elseif type(v) == "table" then
      deep_clean(v)
    end
  end
end

---------------------------------------------------------------------------
-- Block extraction
---------------------------------------------------------------------------

--- The `--dialect` the Rust CLI should parse `buf`'s SQL as.
--- Resolution walks buffer directives → connection config, so it is a full
--- buffer scan: callers resolve it once per completion and pass it along
--- rather than re-deriving it at every use (see `get_items`).
local function get_dialect_flag(bufnr, cursor_line)
  if not cursor_line or cursor_line < 1 then cursor_line = vim.fn.line(".") end
  local ok_ctx, resolved_ctx = pcall(data.resolve_current_context, bufnr, cursor_line)
  if ok_ctx and resolved_ctx and resolved_ctx.connection then
    local ok_conn, conn_mod = pcall(require, "poste-db.connections")
    if ok_conn then
      local conn = conn_mod.get_connection_config(resolved_ctx.connection)
      if conn and conn.dialect then
        return conn.dialect
      end
    end
  end
  return "generic"
end

local function extract_sql_block(bufnr, line_before, cursor_line)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local block_start = 1
  if cursor_line > 1 then
    for i = cursor_line - 1, 1, -1 do
      if const.is_section_marker(vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or "") then
        block_start = i + 1
        break
      end
    end
  end

  local block_end = total_lines
  for i = cursor_line + 1, total_lines do
    if const.is_section_marker(vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or "") then
      block_end = i - 1
      break
    end
  end

  if block_start > cursor_line or cursor_line > block_end then
    return nil
  end

  local block_lines = vim.api.nvim_buf_get_lines(bufnr, block_start - 1, block_end, false)
  local sql_text = table.concat(block_lines, "\n")

  local before_lines = vim.api.nvim_buf_get_lines(bufnr, block_start - 1, cursor_line - 1, false)
  table.insert(before_lines, line_before)
  local offset = #table.concat(before_lines, "\n")

  return sql_text, offset
end

local function cache_key(bufnr, cursor_line, line_before, dialect)
  local changedtick = vim.api.nvim_buf_get_var(bufnr, "changedtick")
  return string.format("%d|%d|%d|%s|%s", bufnr, changedtick, cursor_line, line_before or "", dialect)
end

local CTX_CACHE_MAX = 10
local _ctx_cache_keys = {}

local function trim_ctx_cache()
  if #_ctx_cache_keys <= CTX_CACHE_MAX then return end
  local n = #_ctx_cache_keys - CTX_CACHE_MAX
  for _ = 1, n do
    local key = table.remove(_ctx_cache_keys, 1)
    _ctx_cache[key] = nil
  end
end

---------------------------------------------------------------------------
-- Rust context detection via async vim.system
---------------------------------------------------------------------------

--- Turn the finished `context detect` run into a cached, callback-shaped
--- context. `result` is what vim.system hands on_exit; a failing or
--- unparsable result is reported as `callback(nil)` so the caller can fall
--- back. Runs on a normal event-loop tick, never in a fast-event context.
local function store_rust_context(result, ckey, callback)
  if result.code ~= 0 or not result.stdout then callback(nil); return end

  local ok, parsed = pcall(vim.json.decode, result.stdout)
  if not ok or not parsed or type(parsed) ~= "table" then callback(nil); return end

  debug.set_rust_raw(result.stdout)
  deep_clean(parsed)

  _ctx_cache[ckey] = parsed
  table.insert(_ctx_cache_keys, ckey)
  trim_ctx_cache()
  if compat.opt("debug") then
    state.log("INFO", string.format("Rust context: type=%s, prefix='%s', tables=%d",
      tostring(parsed.ctx_type), tostring(parsed.prefix or ""),
      parsed.tables and #parsed.tables or 0))
  end
  callback(parsed)
end

--- Detect context via the Rust CLI. Calls callback(rust_ctx) with nil when the
--- CLI is unavailable or rejects the input, so the caller can fall back.
--- A cache hit calls back synchronously; a miss calls back from the process'
--- exit handler, i.e. after this function has already returned.
--- Uses _ctx_cache to avoid re-running the binary on repeated calls.
--- `dialect` is resolved once per completion by the caller and reused here for
--- both the CLI flag and the cache key, so the two can never disagree.
local function try_rust_context_async(bufnr, line_before, cursor_line, callback, dialect)
  local ok_ft, ft = pcall(function() return vim.bo[bufnr].filetype end)
  if not ok_ft or (ft ~= "poste_sql" and ft ~= "poste_sqlite") then callback(nil); return end

  local sql_text, offset = extract_sql_block(bufnr, line_before, cursor_line)
  if not sql_text then callback(nil); return end

  if compat.opt("debug") then
    local char_at_cursor = offset <= #sql_text and sql_text:sub(offset + 1, offset + 1) or "N/A"
    local ctx_start = math.max(1, offset - 4)
    local ctx_end = math.min(#sql_text, offset + 6)
    local context = offset <= #sql_text and sql_text:sub(ctx_start, ctx_end) or "N/A"
    state.log("INFO", string.format("DEBUG: offset=%d char='%s' ctx='%s' line_before_len=%d",
      offset, char_at_cursor, context:gsub("\n", "\\n"), #line_before))
  end

  -- The dialect is part of the cache key, so a caller that did not pass one
  -- still has to resolve it before the lookup.
  dialect = dialect or get_dialect_flag(bufnr, cursor_line)
  local ckey = cache_key(bufnr, cursor_line, line_before, dialect)
  if _ctx_cache[ckey] then
    callback(_ctx_cache[ckey])
    return
  end

  local binary = data.find_binary()
  if not binary then callback(nil); return end

  local cmd = { binary, "context", "detect", tostring(offset) }
  if dialect ~= "generic" then
    table.insert(cmd, "--dialect"); table.insert(cmd, dialect)
  end

  local ok_sys = pcall(vim.system, cmd, { stdin = sql_text, text = true, timeout = 2000 },
    function(result)
      -- on_exit runs in a fast-event context (the process handle's callback),
      -- where a blocking call such as `vim.wait` is an error instead of a
      -- park. Deferring lets the whole downstream pipeline, including the
      -- cache-miss introspection jobs, run as if it were called normally.
      vim.schedule(function() store_rust_context(result, ckey, callback) end)
    end)
  if not ok_sys then callback(nil) end
end

---------------------------------------------------------------------------
-- Main entry (async)
---------------------------------------------------------------------------

--- Detect completion context for the SQL at cursor.
--- Calls callback(ctx_type, ctx_data, rust_ctx) where:
---   - ctx_type/ctx_data come from Rust (preferred) or Lua fallback
---   - rust_ctx is the raw Rust response (nil if Rust was not used/failed)
local function detect_context_async(bufnr, line_before, cursor_line, callback, dialect)
  if compat.opt("legacy_completion") == true then
    callback("keyword", nil, nil)
    return
  end

  try_rust_context_async(bufnr, line_before, cursor_line, function(rust_ctx_raw)
    if rust_ctx_raw then
      callback(rust_ctx_raw.ctx_type, rust_ctx_raw.ctx_data, rust_ctx_raw)
    elseif compat.opt("legacy_completion") ~= "rust" then
      callback("keyword", nil, nil)
    else
      callback(nil, nil, nil)
    end
  end, dialect)
end

local function get_items(bufnr, line_before, cursor_line, callback, dialect)
  local prefix = line_before:match("[%w_]*$") or ""
  -- Resolved once: it scans the whole buffer for @connection/@database and
  -- then reads the connection's dialect, and every stage below needs it.
  dialect = dialect or get_dialect_flag(bufnr, cursor_line)

  debug.begin()
  debug.set("line_before", line_before)
  debug.set("prefix", prefix)
  local _cb = callback
  callback = function(items)
    debug.set("items", items)
    debug.flush()
    _cb(items)
  end

  if handlers.handle_directives(line_before, callback) then
    return
  end

  detect_context_async(bufnr, line_before, cursor_line, function(ctx_type, ctx_data, rust_ctx)
    local rust_functions = (rust_ctx and rust_ctx.functions) or nil

    debug.set("ctx_type", ctx_type)
    debug.set("ctx_data", ctx_data)
    if rust_ctx and rust_ctx.tables then
      debug.set("tables", rust_ctx.tables)
    end
    handlers.dispatch({
      bufnr = bufnr,
      line_before = line_before,
      cursor_line = cursor_line,
      prefix = prefix,
      dialect = dialect,
      rust_functions = rust_functions,
    }, ctx_type, ctx_data, rust_ctx, callback)
  end, dialect)
end

---------------------------------------------------------------------------
-- blink.cmp interface
---------------------------------------------------------------------------

function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

function M:enabled()
  local ft = vim.bo.filetype
  return ft == "poste_sql" or ft == "poste_sqlite"
end

function M:get_trigger_characters()
    return { ".", " ", "@", "(", "," }
end

function M:get_keyword_length(blink_ctx)
  if not blink_ctx or not blink_ctx.cursor then return 0 end
  local col = blink_ctx.cursor[2]
  local line = blink_ctx.line or ""
  local before = line:sub(1, col)
  local prefix = before:match("[%w_]*$") or ""
  return #prefix
end

local completion_gen = 0

--- First item per label wins: the same name can arrive from more than one
--- source (a Rust column list plus the keyword fallback). Returns the kept
--- items *and* the label set, so a caller that appends more items afterwards
--- can keep deduplicating against the same set.
local function dedupe_by_label(items)
  local seen, deduped = {}, {}
  for _, item in ipairs(items) do
    if not seen[item.label] then
      seen[item.label] = true
      table.insert(deduped, item)
    end
  end
  return deduped, seen
end

function M:get_completions(blink_ctx, callback)
  completion_gen = completion_gen + 1
  local my_gen = completion_gen

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line, cursor_col, line
  if blink_ctx and blink_ctx.cursor then
    -- cursor[1] is a 1-indexed line (nvim_win_get_cursor) and cursor[2] is a
    -- 0-indexed byte column, so sub(1, col) is exactly the text left of the
    -- cursor.
    cursor_line = blink_ctx.cursor[1]
    cursor_col = blink_ctx.cursor[2]
    line = blink_ctx.line or ""
  else
    -- Stand-in for a caller that passes no ctx. col(".") is 1-indexed and
    -- names the character *at* the cursor, so it needs the -1 to mean the
    -- same thing as blink's column — otherwise `line_before` swallows the
    -- character under the cursor and the offset is one short of the word
    -- being typed.
    cursor_line = vim.fn.line(".")
    cursor_col = vim.fn.col(".") - 1
    line = vim.api.nvim_get_current_line()
  end
  local line_before = line:sub(1, cursor_col)

  if compat.opt("debug") then
    state.log("INFO", string.format("SQL completion triggered: line_before='%s'", line_before))
  end

  local prefix = line_before:match("[%w_]*$") or ""
  local dialect = get_dialect_flag(bufnr, cursor_line)

  get_items(bufnr, line_before, cursor_line, function(items)
    if my_gen ~= completion_gen then return end
    local deduped, seen = dedupe_by_label(items)
    -- Append snippet items when prefix matches a trigger word
    if #prefix > 0 then
      local snippets = require("poste-db.snippets")
      for _, sitem in ipairs(snippets.get_completion_items(prefix, dialect)) do
        if not seen[sitem.label] then
          seen[sitem.label] = true
          table.insert(deduped, sitem)
        end
      end
    end
    -- Apply custom kind_icon from poste-db state.icons
    local icons = require("poste-db.state").icons
    if next(icons) then
      local ok, types = pcall(require, "blink.cmp.types")
      if ok and types and types.CompletionItemKind then
        for _, item in ipairs(deduped) do
          local kind_name = type(item.kind) == "number" and types.CompletionItemKind[item.kind]
          if kind_name then
            item.kind_icon = icons[kind_name] or icons[item.kind]
          end
        end
      end
    end
    if compat.opt("debug") then
      state.log("INFO", string.format("SQL completion: %d items (deduped from %d)", #deduped, #items))
    end
    debug.set("blink_items", #deduped)
    debug.set("blink_incomplete", true)
    debug.flush()
    callback({ is_incomplete_forward = true, is_incomplete_backward = true, items = deduped })
  end, dialect)
end

function M:resolve(item, callback) callback(item) end

--- Drop the caret onto a fresh `-- @database` line and pre-fill the
--- `-- @connection` line the user just picked. Used when the completion menu
--- stands in for the connection picker under a `-- @` directive.
--- The database line is written *without* its trailing space and the space is
--- fed in as a keystroke instead: that one keystroke is what opens the menu
--- again, and writing both left the directive with two spaces on the screen.
local function insert_directive_pair(conn_name)
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.fn.line(".")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local indent = (lines[lnum] or ""):match("^(%s*)") or ""
  local db_line = indent .. "-- @" .. const.DIRECTIVE_DATABASE
  table.insert(lines, lnum, indent .. "-- @" .. const.DIRECTIVE_CONNECTION .. " " .. conn_name)
  lines[lnum + 1] = db_line
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { lnum + 1, #db_line })
  vim.cmd("startinsert!")
  vim.fn.feedkeys(vim.api.nvim_replace_termcodes(" ", true, false, true), "n")
end

function M:execute(exec_ctx, item, callback, default_impl)
  if item.data and item.data.snippet then
    vim.schedule(function()
      local line = vim.api.nvim_get_current_line()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      local before = line:sub(1, col)
      local word = before:match("([%w_]+)$")
      if not word then
        if default_impl then default_impl() end
        callback()
        return
      end
      local word_start = col - #word + 1
      local new_line = line:sub(1, word_start - 1) .. line:sub(col + 1)
      vim.api.nvim_buf_set_lines(0, vim.fn.line(".") - 1, vim.fn.line("."), false, { new_line })
      vim.api.nvim_win_set_cursor(0, { vim.fn.line("."), word_start - 1 })
      vim.snippet.expand(item.data.body)
    end)
    callback()
    return
  end
  if item.data and item.data.directive_fallback then
    vim.schedule(function() insert_directive_pair(item.data.conn_name) end)
    callback()
    return
  end
  if default_impl then default_impl() end
  callback()
end

---------------------------------------------------------------------------
-- nvim-cmp interface
---------------------------------------------------------------------------

M.source = {}
function M.source.new() return setmetatable({}, { __index = M.source }) end
function M.source:is_available()
  local ft = vim.bo.filetype
  return ft == "poste_sql" or ft == "poste_sqlite"
end
function M.source:get_trigger_characters() return { ".", " ", "@", "(", "," } end
function M.source:execute(entry, callback)
  local item = (type(entry.get_completion_item) == "function" and entry:get_completion_item()) or entry.completion_item
  if not item then callback(); return end
  if item.data and item.data.directive_fallback then
    vim.schedule(function() insert_directive_pair(item.data.conn_name) end)
    callback()
    return
  end
  callback()
end
function M.source:complete(params, callback)
  local line_before = params.context.cursor_before_line or ""
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.fn.line(".")
  get_items(bufnr, line_before, cursor_line, function(items)
    local deduped = dedupe_by_label(items)
    debug.set("cmp_items", #deduped)
    debug.flush()
    callback({ items = deduped, isIncomplete = false })
  end)
end

----------------------------------------------------------------------
-- Re-exports for test access and external callers
---------------------------------------------------------------------------

--- Cache helpers are on the data module; re-export for tests that
--- access them via `require("poste-db.completion").cache_tables()`.
M.cache_tables = data.cache_tables
M.cache_columns = data.cache_columns
M.resolve_current_context = data.resolve_current_context

---------------------------------------------------------------------------
-- Toggle: legacy-only mode for regression comparison
---------------------------------------------------------------------------

function M.toggle_legacy()
  local current = compat.opt("legacy_completion")
  if current == nil then
    compat.set("legacy_completion", true)
    vim.notify("PosteDb completion: Legacy Lua-only mode (Rust disabled)", vim.log.levels.WARN)
  elseif current == true then
    compat.set("legacy_completion", "rust")
    vim.notify("PosteDb completion: Rust strict mode (no Lua fallback)", vim.log.levels.WARN)
  else
    compat.set("legacy_completion", nil)
    vim.notify("PosteDb completion: Rust first, Lua never overrides (default)", vim.log.levels.INFO)
  end
end

---------------------------------------------------------------------------
-- Test interface
---------------------------------------------------------------------------

M._test = {
  detect_context_async = detect_context_async,
  resolve_current_context = data.resolve_current_context,
  conn_key = data.conn_key,
  get_items = get_items,
  try_rust_context_async = try_rust_context_async,
  get_tables_and_alias = ctx.get_tables_and_alias,
}

return M
