--- SQL column type completion for Modify Column / New Column forms.
--- Requires blink.cmp.

local M = {}

local adapter = require("poste-db.completion.adapter")


--- Dialect-specific type lists
local types = {
  postgres = {
    "smallint", "integer", "bigint", "smallserial", "serial", "bigserial",
    "decimal", "numeric", "real", "double precision", "money",
    "varchar", "character varying", "char", "character", "text",
    "bytea",
    "timestamp", "timestamptz", "timestamp with time zone",
    "timestamp without time zone", "date", "time", "timetz",
    "time with time zone", "time without time zone", "interval",
    "boolean",
    "point", "line", "lseg", "box", "path", "polygon", "circle",
    "cidr", "inet", "macaddr", "macaddr8",
    "bit", "bit varying", "varbit",
    "tsvector", "tsquery",
    "json", "jsonb", "uuid", "xml",
    "int4range", "int8range", "numrange", "tsrange", "tstzrange", "daterange",
    "oid",
  },
  mysql = {
    "tinyint", "smallint", "mediumint", "int", "integer", "bigint",
    "decimal", "numeric", "float", "double", "double precision", "real",
    "bit", "char", "varchar",
    "tinytext", "text", "mediumtext", "longtext",
    "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob",
    "date", "datetime", "timestamp", "time", "year",
    "json", "enum", "set", "boolean", "bool",
    "geometry", "point", "linestring", "polygon",
  },
  sqlite = {
    "integer", "real", "text", "blob", "numeric",
  },
}

--- Shared filtering logic.
local function filter_types(keyword, dialect)
  local list = types[dialect] or types.postgres
  local lowered = keyword:lower()
  -- completion_item_kind is a function; binding it and indexing the binding
  -- raised "attempt to index a function value" on every completion request.
  local kind = adapter.completion_item_kind("TypeParameter")

  local items = {}
  local exact = {}
  local prefix = {}
  local contain = {}

  for _, t in ipairs(list) do
    local tl = t:lower()
    local item = { label = t, kind = kind, insertText = t, word = t }
    if lowered == "" then
      table.insert(items, item)
    elseif lowered == tl then
      table.insert(exact, item)
    elseif vim.startswith(tl, lowered) then
      table.insert(prefix, item)
    elseif tl:find(lowered, 1, true) then
      table.insert(contain, item)
    end
  end

  for _, item in ipairs(exact) do table.insert(items, item) end
  for _, item in ipairs(prefix) do table.insert(items, item) end
  for _, item in ipairs(contain) do table.insert(items, item) end

  return items
end

--- Register the poste-db-types provider into blink.cmp (idempotent).
function M.ensure_registered()
  if adapter.has_provider("poste-db-types") then return end
  adapter.register_source({
    name = "poste-db-types",
    module = "poste-db.db_browser.completion",
    score_offset = 1000,
    min_keyword_length = 0,
    should_show_items = true,
  })
end

function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

function M:enabled() return true end

function M:get_completions(context, callback)
  local dialect = require("poste-db.compat").opt("dialect") or "postgres"
  local keyword = context:get_keyword() or ""
  local items = filter_types(keyword, dialect)
  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

function M:get_trigger_characters() return {} end

----------------------------------------------------------------------
-- Injection (called by forms.lua before vim.ui.input)
----------------------------------------------------------------------

local _enabled = false
local _orig_providers = nil
local _orig_enabled = nil

--- Enable SQL type completion for the next DressingInput buffer.
--- Must call M.cleanup() after the input is done.
function M.enable_for_next_input()
  if _enabled then return end
  _enabled = true
  M.ensure_registered()
  local lib = adapter.get_source_lib()
  if lib then
    _orig_providers = lib.per_filetype_provider_ids["DressingInput"]
    lib.per_filetype_provider_ids["DressingInput"] = { "poste-db-types" }
  end
  -- blink.cmp disables completion for buftype=prompt (DressingInput).
  -- Patch the enabled function to allow DressingInput buffers.
  local cfg = adapter.get_config()
  if cfg and cfg.completion then
    _orig_enabled = cfg.completion.enabled
    cfg.completion.enabled = function()
      if vim.bo.filetype == "DressingInput" then return true end
      if type(_orig_enabled) == "function" then return _orig_enabled() end
      return true
    end
  end
end

--- Clean up after input is done.
function M.cleanup()
  _enabled = false
  local lib = adapter.get_source_lib()
  if lib then
    lib.per_filetype_provider_ids["DressingInput"] = _orig_providers
  end
  _orig_providers = nil
  if _orig_enabled ~= nil then
    local cfg = adapter.get_config()
    if cfg and cfg.completion then
      cfg.completion.enabled = _orig_enabled
    end
    _orig_enabled = nil
  end
end

--- Get type list for a dialect.
function M.get_types(dialect)
  return types[dialect] or types.postgres
end

return M