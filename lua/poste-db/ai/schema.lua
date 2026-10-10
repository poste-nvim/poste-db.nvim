--- Auto-injected database schema for the AI chat. When the chat scope binds a
--- connection (via /connections, /databases), each request gets a compact
--- context block: the table list (name + comment) always, plus full column
--- lines only for tables whose names appear in the user's text. Cached per
--- connection/database for the editor session — schema changes need a
--- restart (acceptable for prompt building; @mentions stay the precise tool).

local M = {}

local MAX_TABLES = 120
local MAX_EXPAND = 5      -- tables introspected per request
local MAX_CHARS = 6000

local introspect = require("poste-db.ai.introspect").run
local util = require("poste-db.util")

local cache = {}  -- "conn/db" → { tables = { { name, comment } }, columns = { [name] = line }, capped = n }

--- The cache key names the *effective* target: `""` and nil both mean "the
--- connection's default database", and two spellings of one target would hold
--- two entries — the second re-introspecting the tables the first already had.
local function cache_key(scope)
  return (util.named(scope.connection) or "?") .. "/" .. (util.named(scope.database) or "(default)")
end

local function pattern_esc(s)
  return (s:lower():gsub("[%W]", "%%%1"))
end

--- Boundary match so "user" doesn't match inside "user_id".
local function word_in_text(name, text_l)
  local pat = pattern_esc(name)
  return text_l:match("[^%w_]" .. pat .. "[^%w_]") ~= nil
    or text_l:match("^" .. pat .. "[^%w_]") ~= nil
    or text_l:match("[^%w_]" .. pat .. "$") ~= nil
    or text_l == pat
end

local function comment_of(entry, name)
  for _, t in ipairs(entry.tables) do
    if t.name == name then return t.comment end
  end
  return nil
end

--- Render the context block from a cache entry; `expanded` holds the table
--- names whose full column lines should be included.
local function render(entry, expanded, scope)
  local db = util.named(scope.database)
  local md = "## Database schema (auto)\n"
    .. (db and ("Database `" .. db .. "`") or "Connection `" .. scope.connection .. "` (default database)")
    .. " tables:\n"
  for _, t in ipairs(entry.tables) do
    local line
    if expanded[t.name] and entry.columns[t.name] then
      line = entry.columns[t.name]
    else
      line = "- " .. t.name
      if t.comment and t.comment ~= "" then line = line .. " (" .. t.comment .. ")" end
    end
    md = md .. line .. "\n"
  end
  if entry.capped and entry.capped > 0 then
    md = md .. "(+" .. entry.capped .. " more tables not listed)\n"
  end
  md = md .. "Use these names as-is; do not invent tables or columns."
  if #md > MAX_CHARS then
    -- drop expanded column lines (most verbose) until it fits
    for _, t in ipairs(entry.tables) do
      if #md <= MAX_CHARS then break end
      if expanded[t.name] then
        local short = "- " .. t.name
        if t.comment and t.comment ~= "" then short = short .. " (" .. t.comment .. ")" end
        md = md:gsub(vim.pesc(entry.columns[t.name]) .. "\n", short:gsub("%%", "%%%%") .. "\n", 1)
      end
    end
    if #md > MAX_CHARS then md = util.utf8_safe_cut(md, MAX_CHARS) .. "\n(truncated)" end
  end
  return md
end

--- Expand candidate tables (present in the text) whose columns aren't cached
--- yet, then render. Sequential introspection, then cb.
local function expand_and_render(text, scope, entry, cb)
  local text_l = (text or ""):lower()
  -- tables named in the text whose columns are already cached still render
  -- their column lines: `expanded` must include them, or a table mentioned a
  -- second time degraded to its one-line form even though its columns sit
  -- in the cache (defeating the cache's whole purpose)
  local expanded = {}
  for _, t in ipairs(entry.tables) do
    if entry.columns[t.name] and word_in_text(t.name, text_l) then
      expanded[t.name] = true
    end
  end
  local candidates = {}
  for _, t in ipairs(entry.tables) do
    if #candidates >= MAX_EXPAND then break end
    if not entry.columns[t.name] and word_in_text(t.name, text_l) then
      candidates[#candidates + 1] = t.name
    end
  end
  if #candidates == 0 then
    cb(render(entry, expanded, scope))
    return
  end
  local conn = scope.connection
  local db = util.named(scope.database)
  local idx = 0
  local function next_table()
    idx = idx + 1
    local name = candidates[idx]
    if not name then
      cb(render(entry, expanded, scope))
      return
    end
    introspect(conn, "columns", name, db, function(columns)
      entry.columns[name] = require("poste-db.ai.mentions").table_line(
        name, comment_of(entry, name), columns)
      expanded[name] = true
      next_table()
    end)
  end
  next_table()
end

--- poste-ai auto_context contract: cb(md_or_nil) with a schema block for the
--- scoped connection/database. nil when no connection is bound.
--- @param text string user message text
--- @param scope table chat scope snapshot
--- @param cb function(md_or_nil)
function M.auto_context(text, scope, cb)
  local conn = util.named(scope and scope.connection)
  if not conn then cb(nil) return end
  local key = cache_key(scope)
  local entry = cache[key]
  if entry then
    expand_and_render(text, scope, entry, cb)
    return
  end
  introspect(conn, "tables", nil, util.named(scope.database), function(items)
    if not items or #items == 0 then
      cache[key] = { tables = {}, columns = {} }
      cb(nil)
      return
    end
    local tables, capped = {}, 0
    for _, item in ipairs(items) do
      if type(item) == "table" and item.name then
        if #tables < MAX_TABLES then
          tables[#tables + 1] = { name = item.name, comment = item.comment }
        else
          capped = capped + 1
        end
      end
    end
    cache[key] = { tables = tables, columns = {}, capped = capped }
    expand_and_render(text, scope, cache[key], cb)
  end)
end

M._test = {
  auto_context = M.auto_context,
  word_in_text = word_in_text,
  render = render,
  cache_key = cache_key,
  _cache = function() return cache end,
  _reset = function() cache = {} end,
  MAX_EXPAND = MAX_EXPAND,
}

return M
