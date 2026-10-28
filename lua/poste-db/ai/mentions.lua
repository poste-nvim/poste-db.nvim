--- "@connection/database" mention support for the AI chat.
--- Tokens are validated against connections.toml synchronously (cached parse);
--- schema summaries resolve asynchronously via the poste binary introspection.

local connections = require("poste-db.connections")

local M = {}

local TOKEN = "^([%w%-_]+)/([%w%-_]+)$"
local TOKEN_TABLE = "^([%w%-_]+)/([%w%-_]+)/([%w%-%_%.]+)$"

--- Classify a @token. Returns a ref table or nil (nil lets the generic chat
--- fall back to file mentions).
---   "my-blog/blog"           → { connection, database }
---   "my-blog/blog/schema.t"  → { connection, database, table }
--- @param token string text after the @
--- @return table|nil
function M.match(token)
  -- nil/garbage classifies as "not a db mention" (the generic chat falls
  -- back to file mentions) instead of crashing the completion
  if type(token) ~= "string" then return nil end
  local conn, db, table_part = token:match(TOKEN_TABLE)
  if conn then
    if not connections.get_connection_config(conn) then return nil end
    return { connection = conn, database = db, table = table_part }
  end
  conn, db = token:match(TOKEN)
  if not conn then return nil end
  if not connections.get_connection_config(conn) then return nil end
  return { connection = conn, database = db }
end

local cached_list = nil

--- Drop the cached @-completion candidate list. Invoked from autocmds.lua
--- when a connections.toml is written, so newly added connections show up
--- in @-completion without restarting the session.
function M.invalidate()
  cached_list = nil
end

--- Completion candidates: "connection/defaultdb" for every connection in
--- connections.toml. Cached after the first async fetch.
--- @param _prefix string
--- @param cb function(candidates)
function M.complete(_prefix, cb)
  if cached_list then
    cb(M._candidates(cached_list))
    return
  end
  connections.list_connections(function(list)
    cached_list = list or {}
    cb(M._candidates(cached_list))
  end)
end

function M._candidates(list)
  local out = {}
  for _, conn in ipairs(list) do
    local db = conn.database and conn.database ~= "" and conn.database or "db"
    out[#out + 1] = {
      label = conn.name .. "/" .. db,
      description = (conn.dialect or "") .. (conn.host and (" " .. conn.host) or ""),
    }
  end
  return out
end

local MAX_TABLES_FOR_COLUMNS = 20
local MAX_OUTPUT_CHARS = 12000

local introspect = require("poste-db.ai.introspect").run

local function clean_comment(comment)
  if type(comment) ~= "string" or comment == "" then return nil end
  -- Parenthesized so `gsub`'s second return (the count) cannot leak into a
  -- caller's table constructor.
  return (comment:gsub("%s+", " "))
end

--- "- name (comment): id: int, user_id: int" — comment helps the AI map
--- business semantics to tables/columns.
function M.table_line(name, comment, columns)
  local out = "- " .. name
  local c = clean_comment(comment)
  if c then out = out .. " (" .. c .. ")" end
  if type(columns) == "table" and #columns > 0 then
    local cols = {}
    for _, col in ipairs(columns) do
      if type(col) == "table" and col.name then
        local piece = col.name .. (col.type and (": " .. col.type) or "")
        local cc = clean_comment(col.comment)
        if cc then piece = piece .. " (" .. cc .. ")" end
        cols[#cols + 1] = piece
      end
    end
    out = out .. ": " .. table.concat(cols, ", ")
  end
  return out
end

--- Resolve a mention ref into a markdown schema summary (async).
--- @param ref table { connection, database, table? }
--- @param cb function(md, err)
function M.resolve(ref, cb)
  if type(ref) ~= "table" then cb(nil, "malformed connection mention") return end
  local conn = ref.connection
  local db = ref.database
  if not conn or not db then cb(nil, "malformed connection mention") return end

  -- single-table detail
  if ref.table then
    introspect(conn, "columns", ref.table, db, function(columns)
      if not columns then
        cb(nil, ("could not introspect table %s of %s/%s"):format(ref.table, conn, db))
        return
      end
      local md = ("### Table `%s.%s`\nColumns:\n"):format(db, ref.table)
      for _, col in ipairs(columns) do
        if type(col) == "table" and col.name then
          local piece = "- " .. col.name .. (col.type and (": " .. col.type) or "")
          local cc = clean_comment(col.comment)
          if cc then piece = piece .. " (" .. cc .. ")" end
          md = md .. piece .. "\n"
        end
      end
      cb(md, nil)
    end)
    return
  end

  introspect(conn, "tables", nil, db, function(tables)
    if not tables then
      cb(nil, ("could not list tables of %s/%s (unknown database or unreachable db)"):format(conn, db))
      return
    end

    local conn_cfg = connections.get_connection_config(conn)
    local dialect = conn_cfg and conn_cfg.dialect or ""
    local header = ("### Database `%s/%s` (%s)\nTables (%d):\n"):format(conn, db, dialect, #tables)

    if #tables > MAX_TABLES_FOR_COLUMNS then
      -- table.concat, not repeated concatenation: a database with thousands
      -- of tables copied the growing string once per table, every chat turn.
      local parts = {}
      for _, t in ipairs(tables) do
        parts[#parts + 1] = "- " .. t.name .. "\n"
      end
      parts[#parts + 1] = "(column details available on request — ask for a specific table)\n"
      cb(header .. table.concat(parts), nil)
      return
    end

    -- fetch columns for every table in parallel (capped set)
    local lines = {}
    local remaining = #tables
    if remaining == 0 then cb(header .. "(no tables)", nil) return end
    for idx, t in ipairs(tables) do
      introspect(conn, "columns", t.name, db, function(columns)
        lines[idx] = M.table_line(t.name, t.comment, columns)
        remaining = remaining - 1
        if remaining <= 0 then
          local md = header .. table.concat(lines, "\n") .. "\n"
          if #md > MAX_OUTPUT_CHARS then
            md = require("poste-db.util").utf8_safe_cut(md, MAX_OUTPUT_CHARS)
              .. "\n… (schema truncated)"
          end
          cb(md, nil)
        end
      end)
    end
  end)
end

M._test = {
  match = M.match,
  candidates = M._candidates,
  table_line = M.table_line,
}

return M
