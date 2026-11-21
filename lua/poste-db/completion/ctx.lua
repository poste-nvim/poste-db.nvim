--- SQL completion — item helpers (post-P3, heuristic logic removed).
--- @deprecated Fallback only when Rust binary is unavailable.
--- Kept for item helpers only: make_items, filter, func_items, kw_items.
local data = require("poste-db.completion.data")

local M = {}

-----------------------------------------------------------------------------
-- Item helpers
-----------------------------------------------------------------------------

--- Fuzzy match: each character of `pattern` must appear in `text` in order
--- (case-insensitive). Empty pattern matches everything. This lets `ie`
--- match both `ies` (prefix) and `item` (subsequence). The implementation is
--- shared with the browser's table search (`util.fuzzy_match`), which also
--- needs the matched positions.
function M.fuzzy_match(text, pattern)
  return require("poste-db.util").fuzzy_match(text, pattern)
end

function M.make_items(names, kind, doc_prefix)
  local items = {}
  for _, n in ipairs(names or {}) do
    table.insert(items, { label = n, kind = kind, insertText = n,
      documentation = doc_prefix and (doc_prefix .. n) or n })
  end
  return items
end

function M.filter(items, prefix)
  if prefix == "" then return items end
  return vim.tbl_filter(function(i)
    return M.fuzzy_match(i.label, prefix)
  end, items)
end

function M.func_items(prefix, funcs)
  local items = {}
  local list = funcs or data.SQL_FUNCTIONS
  for _, fn in ipairs(list) do
    if M.fuzzy_match(fn, prefix) then
      table.insert(items, {
        label = fn,
        kind = 3,
        insertText = fn,
        sortText = "2" .. fn,
        documentation = "function"
      })
    end
  end
  return items
end

function M.kw_items(prefix, dialect)
  local items = {}
  for _, kw in ipairs(data.KEYWORDS) do
    if M.fuzzy_match(kw, prefix) then
      table.insert(items, { label = kw, kind = 14, insertText = kw, sortText = "0" .. kw, documentation = "keyword" })
    end
  end
  -- Include dialect-specific keywords
  if dialect then
    local extra = data.DIALECT_KEYWORDS[dialect] or {}
    for _, kw in ipairs(extra) do
      if M.fuzzy_match(kw, prefix) then
        table.insert(items, { label = kw, kind = 14, insertText = kw, sortText = "0" .. kw, documentation = "keyword" })
      end
    end
  end
  for _, t in ipairs(data.DATA_TYPES) do
    if M.fuzzy_match(t, prefix) then
      table.insert(items, { label = t, kind = 25, insertText = t, sortText = "0" .. t, documentation = "type" })
    end
  end
  return items
end

-----------------------------------------------------------------------------
-- Tables and alias resolution (Rust-only, no Lua heuristic fallback)
-----------------------------------------------------------------------------

--- Tables, aliases and schemas as the Rust context reported them.
--- Takes no buffer or cursor on purpose: `rust_ctx` is the only source, so a
--- caller that has not run the context check has nothing to ask about here.
--- Returns: (from_tbls, alias_map, schema_map), all empty without a context.
function M.get_tables_and_alias(rust_ctx)
  if rust_ctx and rust_ctx.tables and #rust_ctx.tables > 0 then
    local from_tbls, alias_map, schema_map = {}, {}, {}
    for _, t in ipairs(rust_ctx.tables) do
      if t.name and t.name ~= "" then
        table.insert(from_tbls, t.name)
        alias_map[t.name] = t.name
        if t.alias then alias_map[t.alias] = t.name end
        if t.schema then schema_map[t.name] = t.schema end
      end
    end
    return from_tbls, alias_map, schema_map
  end
  return {}, {}, {}
end

return M
