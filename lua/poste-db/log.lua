local state = require("poste-db.state")

local M = {}

-- Keys whose `key=value` value is a secret when the pair sits in a URL query
-- (or is otherwise unambiguous). Names that double as plausible SQL columns
-- (`token`, `secret`, ...) are only in this broad set, so `SET token=1` in a
-- logged statement survives: the space and ';' delimiters use DSN_KEYS below.
local SECRET_KEYS = {
  password = true, passwd = true, pgpassword = true, saslpassword = true,
  pass = true, pwd = true, secret = true, token = true, accesstoken = true,
  authtoken = true, apikey = true,
}

-- Connection-string keywords (libpq `user=x password=y`, ODBC `Uid=x;Pwd=y`) —
-- safe to redact after a space or ';', which SQL statement text also uses: no
-- plausible assignment there names these columns without a quoted literal.
local DSN_KEYS = {
  password = true, passwd = true, pgpassword = true, saslpassword = true,
  pwd = true,
}

-- The authority of `scheme://userinfo@host` runs to the first '?', '#' or
-- space, so a password that contains '/' is still covered while a path such as
-- `/db?user=a@b` cannot be mistaken for credentials.
local function redact_authority(s)
  if not s:find("://", 1, true) then return s end
  local out, cursor = {}, 1
  local pos = s:find("://", cursor, true)
  while pos do
    table.insert(out, s:sub(cursor, pos + 2))
    local stop = pos + 3
    while stop <= #s and not s:sub(stop, stop):find("[?#%s]") do stop = stop + 1 end
    local region = s:sub(pos + 3, stop - 1)
    local after_at = region:match("^.*@()")
    if after_at and pos > 1 and s:sub(pos - 1, pos - 1):match("[%w%+%.%-]") then
      local userinfo = region:sub(1, after_at - 2)
      local colon = userinfo:find(":", 1, true)
      if colon then region = userinfo:sub(1, colon - 1) .. ":***@" .. region:sub(after_at) end
    end
    table.insert(out, region)
    cursor = stop
    pos = s:find("://", cursor, true)
  end
  table.insert(out, s:sub(cursor))
  return table.concat(out)
end

local function redact_secret_params(s)
  if not s:find("=", 1, true) then return s end
  local function keep(delim, key, eq, val)
    local name = key:lower():gsub("^%-+", "")
    -- A quoted literal is SQL, never a DSN value.
    local q = val:sub(1, 1)
    if q ~= "'" and q ~= '"' and q ~= "`" then
      local broad = delim == "" or delim == "?" or delim == "&"
      if (broad and SECRET_KEYS or DSN_KEYS)[name] then return delim .. name .. eq .. "***" end
    end
    return delim .. key .. eq .. val
  end
  return (s:gsub("([?&;%s]?)([%w_%-%.]+)(%s*=%s*)([^&;#%s]*)", keep))
end

function M.redact_url(str)
  if type(str) ~= "string" then return str end
  return redact_secret_params(redact_authority(str))
end

function M.redact_cmd(cmd)
  local parts = {}
  local skip = false
  for _, v in ipairs(cmd) do
    if skip then
      table.insert(parts, "<redacted>")
      skip = false
    elseif v == "--connection" or v == "--connection-url" then
      table.insert(parts, v)
      skip = true
    else
      table.insert(parts, v)
    end
  end
  return table.concat(parts, " ")
end

local function log(level, msg)
  state.log(level, M.redact_url(msg))
end

function M.info(msg) log("INFO", msg) end
function M.warn(msg) log("WARN", msg) end
function M.error(msg) log("ERROR", msg) end
function M.debug(msg) log("DEBUG", msg) end

function M.info_fmt(fmt, ...)
  local args = { ... }
  for i, v in ipairs(args) do
    if type(v) == "string" then
      args[i] = M.redact_url(v)
    end
  end
  log("INFO", string.format(fmt, unpack(args)))
end

return M