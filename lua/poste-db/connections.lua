--- SQL connection management UI.
--- Provides :PosteDbConnection command to list, select, and test connections.
local cli = require("poste-db.cli")
local state = require("poste-db.state")

local util = require("poste-db.util")
local select_mod = require("poste-db.select")
local const = require("poste-db.constants")

local M = {}

-----------------------------------------------------------------------
-- Get search directory for connections.toml
-----------------------------------------------------------------------
--- Directory connections.toml discovery starts from: the current buffer's
--- directory when it is a real file buffer, cwd otherwise. Pseudo buffers
--- (poste://dataset, poste://db_browser, health://) carry a non-empty but
--- non-file name, so the naive "buffer name wins" rule used to resolve them
--- to "poste:" / "health:" and could read a different connections.toml than
--- the SQL file being edited. Single copy shared by :PosteDbInfo,
--- :checkhealth and completion/data.lua — do not fork it again.
--- @return string
function M.get_search_dir()
  local buf_name = vim.api.nvim_buf_get_name(0)
  if buf_name ~= ""
    and vim.api.nvim_get_option_value("buftype", { buf = 0 }) == "" then
    return vim.fn.fnamemodify(buf_name, ":p:h")
  end
  return vim.fn.getcwd()
end

-----------------------------------------------------------------------
-- Config file discovery
-----------------------------------------------------------------------

local _config_search_cache = {}
local _config_search_cache_mtime = {}

--- Walk up from `search_dir` to find connections.toml. The found path is
--- mtime-cached to avoid a directory traversal on every cursor move.
--- A "not found" result is NEVER served stale: mtime has no answer for a file
--- that did not exist when the cache was written, so a connections.toml created
--- mid-session stayed invisible to every caller (the cache had no invalidation
--- hook at all). The walk-up is a handful of stat()s — re-run it on a miss
--- (same rule poste-redis/poste-es connections.lua document).
--- @param search_dir string Directory to start from
--- @return string|nil Path to connections.toml
function M.find_connections_toml(search_dir)
  local cached = _config_search_cache[search_dir]
  if cached ~= nil then
    if _config_search_cache_mtime[search_dir] == vim.fn.getftime(cached) then
      return cached
    end
  end
  local result = util.find_file_upwards("connections.toml", search_dir)
  if not result then
    _config_search_cache[search_dir] = nil
    _config_search_cache_mtime[search_dir] = nil
    return nil
  end
  _config_search_cache[search_dir] = result
  _config_search_cache_mtime[search_dir] = vim.fn.getftime(result)
  return result
end

local _config_cache = nil
local _config_cache_path = nil
local _config_cache_mtime = nil

-----------------------------------------------------------------------
-- Environment variable resolution (dotenv + env.json + OS env)
-----------------------------------------------------------------------

local _dotenv_cache = {}
local _dotenv_cache_mtime = {}

--- Parse dotenv content: `KEY=VALUE` lines, optional `export` prefix,
--- `#` comments, and single/double quoted values. Also resolves `{{VAR}}`
--- references within values.
--- @param content string
--- @param vars table<string,string> existing vars for recursive substitution
--- @return table<string,string>
local function parse_dotenv(content, vars)
  vars = vars or {}
  for line in content:gmatch("[^\r\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local key, value = trimmed:match("^export%s+([%w_.]+)%s*=%s*(.-)%s*$")
      if not key then
        key, value = trimmed:match("^([%w_.]+)%s*=%s*(.-)%s*$")
      end
      if key then
        value = value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
        vars[key] = value
      end
    end
  end
  for k, v in pairs(vars) do
    vars[k] = M.substitute_vars(v, vars)
  end
  return vars
end

--- Find and parse `.env` walking up from `search_dir` (same discovery as
--- connections.toml). Cached per search_dir with mtime invalidation.
--- @param search_dir string
--- @return table<string,string>
local function load_dotenv(search_dir)
  local path = util.find_file_upwards(".env", search_dir)
  local mtime = path and vim.fn.getftime(path) or nil
  if _dotenv_cache[search_dir] ~= nil and _dotenv_cache_mtime[search_dir] == mtime then
    return _dotenv_cache[search_dir]
  end
  local vars = {}
  if path then
    local ok, data = pcall(vim.fn.readfile, path)
    if ok and data then
      vars = parse_dotenv(table.concat(data, "\n"), vars)
    end
  end
  _dotenv_cache[search_dir] = vars
  _dotenv_cache_mtime[search_dir] = mtime
  return vars
end

--- Keep only scalar entries of an env section, as strings.
--- Mirrors the Rust CLI's `scalar_vars`: numbers and booleans are values (the
--- natural thing to write in a JSON file), while a nested object or array is
--- structure, not a variable. Dropping it is also what keeps resolution
--- alive — a table handed to `gsub`'s replacement raises
--- "invalid replacement value (a table)" and takes the whole config down.
--- @param section table
--- @return table<string,string>
local function scalar_env_vars(section)
  local result = {}
  for k, v in pairs(section) do
    local t = type(v)
    if t == "string" then
      result[k] = v
    elseif t == "number" or t == "boolean" then
      result[k] = tostring(v)
    end
  end
  return result
end

--- Load `env.json` vars for the current environment (matches the Rust
--- binary's `--env` flow: `{ "dev": { ... }, "prod": { ... } }`).  A file
--- without the requested stanza is read as a flat var map, which is what the
--- CLI does — otherwise `poste connection list` resolves a URL the editor
--- claims has no variables at all.
--- @param search_dir string
--- @return table<string,string>
local _env_json_cache = {}
local _env_json_cache_mtime = {}

--- Same mtime-cache shape as load_dotenv below: get_env_vars runs on every
--- statusline evaluation and cursor move, and an uncached readfile+decode of
--- env.json per call made every connection-config read pay file IO. The cache
--- key includes current_env because env.json section selection depends on it.
local function load_env_json_vars(search_dir)
  local path = util.find_file_upwards("env.json", search_dir)
  local mtime = path and vim.fn.getftime(path) or nil
  local cache_key = search_dir .. "#" .. (state.current_env or "dev")
  if _env_json_cache[cache_key] ~= nil and _env_json_cache_mtime[cache_key] == mtime then
    return _env_json_cache[cache_key]
  end
  local vars = {}
  if path then
    local ok, data = pcall(vim.fn.readfile, path)
    if ok and data then
      local ok2, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
      if ok2 and type(parsed) == "table" then
        local envs = parsed.envs or parsed
        local section = envs[state.current_env or "dev"]
        if type(section) ~= "table" then section = envs end
        if type(section) == "table" then vars = scalar_env_vars(section) end
      end
    end
  end
  _env_json_cache[cache_key] = vars
  _env_json_cache_mtime[cache_key] = mtime
  return vars
end

--- Merge all environment sources.
--- Precedence (highest wins): OS environment > `.env` > `env.json`.
--- @param search_dir string
--- @return table<string,string>
function M.get_env_vars(search_dir)
  local vars = {}
  for k, v in pairs(load_env_json_vars(search_dir)) do vars[k] = v end
  for k, v in pairs(load_dotenv(search_dir)) do vars[k] = v end
  -- `vim.fn.environ()` enumerates real OS vars; `pairs(vim.env)` does not.
  for k, v in pairs(vim.fn.environ()) do vars[k] = v end
  return vars
end

--- Substitute `{{VAR}}` references in a string. Unknown references are
--- kept literal, matching Rust's `substitute_vars` behavior.
--- Recursively resolves values that contain further `{{VAR}}` references
--- (up to a max depth to prevent infinite loops).
--- @param s any
--- @param vars table<string,string>
--- @return any
function M.substitute_vars(s, vars, depth)
  if type(s) ~= "string" or not s:find("{{", 1, true) then
    return s
  end
  depth = depth or 0
  if depth >= 10 then return s end
  -- The name is "anything up to the closing brace pair", which is Rust's
  -- `\{\{([^}]+)\}\}`: env.json keys are not limited to identifier characters,
  -- and a reference this side refuses to expand reaches the driver as literal
  -- braces while the CLI resolves the same file.
  local result = (s:gsub("{{(.-)}}", function(name)
    return vars[name] or "{{" .. name .. "}}"
  end))
  if result:find("{{", 1, true) then
    return M.substitute_vars(result, vars, depth + 1)
  end
  return result
end

--- Copy a connection config with `{{VAR}}` references resolved. Nested
--- tables (e.g. `tunnel = { to = "{{BASTION}}" }`) recurse: a literal
--- `{{BASTION}}` reaching tunnel.ensure reads like a tunnel failure that is
--- really a config mistake.
--- @param conn table Connection config (raw values)
--- @param vars table<string,string>
--- @return table Resolved connection config
local function apply_env(conn, vars)
  -- A shared connections.toml can carry top-level scalars (`description = "…"`
  -- above the first section); pairs() over one used to crash every listing.
  if type(conn) ~= "table" then return conn end
  local resolved = {}
  for k, v in pairs(conn) do
    if type(v) == "table" then
      resolved[k] = apply_env(v, vars)
    else
      resolved[k] = M.substitute_vars(v, vars)
    end
  end
  return resolved
end

--- Percent-encode a component for URL building.
--- Encodes every byte outside the RFC 3986 unreserved set.
--- @param s any
--- @return any
local function percent_encode(s)
  if type(s) ~= "string" or s == "" then return s end
  return (s:gsub("[^%w%.%-%_%~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

--- Bracket an IPv6 literal so it is legal in a URL authority (RFC 3986
--- §3.2.2). The drivers enforce it: `postgres://::1:5432/db` is refused as
--- `error with configuration: empty host` before a socket is opened (measured
--- with `poste introspect`), so `host = "::1"` in connections.toml was
--- unusable. Only hex digits plus colons count as an address, so the common
--- mistake of leaving the port in the host field (`localhost:5432`) is not
--- rewritten into something else; an already bracketed host passes through,
--- being the form that worked. Mirror of Rust `sql_connection.rs::url_host`
--- (same documented pair as to_url / build_conn_url).
--- @param host string
--- @return string
local function url_host(host)
  if host:sub(1, 1) == "[" then return host end
  if host:find(":", 1, true) and host:match("^[%x:]+$") then
    return "[" .. host .. "]"
  end
  return host
end

--- Parsed connections.toml shared by get_connection_config and name_for_url.
--- mtime-keyed cache; `false` means the file exists but is broken.
--- @return table|nil
local function cached_parsed_config()
  local search_dir = M.get_search_dir()
  local config_path = M.find_connections_toml(search_dir)
  if not config_path then
    _config_cache = nil
    _config_cache_path = nil
    return nil
  end
  local mtime = vim.fn.getftime(config_path)
  if _config_cache_path ~= config_path or _config_cache_mtime ~= mtime then
    local toml = require("poste-db.toml")
    local parsed, err = toml.parse_file(config_path)
    if not parsed then
      -- Cache the failure (keyed on mtime like the success path): this runs
      -- from the statusline and completion on every redraw/keystroke, and a
      -- broken file would otherwise re-read, re-parse and re-log each time
      -- until it is fixed.
      -- state.log, not poste-db.log: this module is intentionally
      -- stub-isolated in tests and must not grow module dependencies
      state.log("WARN", "connections.toml parse failed: " .. tostring(err))
      _config_cache = false
      _config_cache_path = config_path
      _config_cache_mtime = mtime
      return nil
    end
    _config_cache = parsed
    _config_cache_path = config_path
    _config_cache_mtime = mtime
  end
  if _config_cache == false then return nil end
  return _config_cache
end

--- Get the config for a named connection by reading connections.toml directly.
--- Returns values with `{{var}}` references resolved from .env / env.json / OS env.
--- Caches parsed config to avoid file I/O on every cursor move.
--- @param name string Connection name
--- @return table|nil Connection config or nil
function M.get_connection_config(name)
  local parsed = cached_parsed_config()
  if not parsed then return nil end
  local conn = parsed[name]
  if type(conn) ~= "table" then return nil end
  conn = apply_env(conn, M.get_env_vars(M.get_search_dir()))
  conn.dialect = const.normalize_dialect(conn.dialect)
  return conn
end

--- Assemble the dialect URL for an env-applied, dialect-normalized entry.
--- Shared by resolve_connection_url (name → URL) and name_for_url (URL → name)
--- so the two directions cannot drift. `ensure_tunnel` marks the execution
--- path and may open the ssh tunnel; the display path (false) only reuses an
--- already-active one — a name lookup for the winbar must never open one.
--- @param name string
--- @param conn table
--- @param ensure_tunnel boolean
--- @return string|nil, string|nil url, error_message
local function build_conn_url(name, conn, ensure_tunnel)
  -- Fail loudly for dialects poste-db does not support (a shared
  -- connections.toml may carry redis/elasticsearch/... sections), instead of
  -- building a mysql/postgres URL from their fields.
  if not const.is_sql_dialect(conn.dialect) then
    return nil, ("Connection '%s' has unsupported dialect '%s'"):format(name, tostring(conn.dialect))
  end

  -- Type-gate every field the builder concatenates or string-ops below: the
  -- TOML parser turns `host = [1]` into a real table, and `:sub` / `..` on
  -- it crashed the resolver (completion, the winbar and the browser all
  -- resolve, on every redraw) instead of naming the bad field.
  for _, field in ipairs({ "url", "host", "path", "user", "password", "database" }) do
    local v = conn[field]
    if v ~= nil and type(v) ~= "string" then
      return nil, ("Connection '%s': %s must be a string"):format(name, field)
    end
  end

  -- Use url field directly if present. A `tunnel` section cannot apply to a
  -- raw URL — there is no host/port to rewrite — so fail loudly instead of
  -- silently bypassing the jump host.
  if conn.url and conn.url ~= "" then
    if conn.tunnel then
      return nil, ("Connection '%s': tunnel requires the host/port form, not a raw url"):format(name)
    end
    return conn.url, nil
  end

  -- Build URL from individual fields. sqlite is file-based; every other
  -- whitelisted dialect is scheme://user:pass@host:port/db with the default
  -- port from constants (single source — also consumed by display and
  -- URL-sniffing paths). A section without `dialect` is allowed by the
  -- is_sql_dialect gate (nil "defaults behave like postgres") — make that
  -- default real here, or the scheme concatenation dies on the nil.
  if conn.dialect == "sqlite" then
    -- `path = ""` is an unset path, not a file named "": the `or` fallback
    -- never fired for it and the URL came out `sqlite:?mode=rwc`.
    local path = (conn.path and conn.path ~= "") and conn.path or ":memory:"
    if path == ":memory:" then
      return "sqlite::memory:", nil
    end
    -- Append the create-if-missing flag without corrupting a path that
    -- already carries a query string (09-11 carry): `f.db?cache=shared`
    -- gains `&mode=rwc`; a path that already pins `mode=` is left untouched.
    if path:find("?", 1, true) then
      if not path:find("mode=", 1, true) then
        path = path .. "&mode=rwc"
      end
    else
      path = path .. "?mode=rwc"
    end
    return "sqlite:" .. path, nil
  end

  local scheme = conn.dialect or "postgres"
  local host = conn.host or "localhost"
  -- A `host:port` paste (the connection-string habit) built
  -- `postgres://localhost:5432:5432/db`, which only failed at the binary
  -- with a URL parse error naming nothing; whitespace is equally
  -- un-buildable. Both name the fix here instead — the tunnel path above
  -- also wants a bare address to hand to ssh. (Pure hex+colon still passes:
  -- that is an IPv6 literal for url_host to bracket. A MSSQL named instance
  -- `server\\inst` carries no colon and passes untouched.)
  local host_port = host:match("^([^%s:]+):(%d+)$")
  if host_port then
    return nil,
      ("Connection '%s': host '%s' carries the port — move it to the `port` field"):format(name, host)
  end
  if host:match("%s") then
    return nil, ("Connection '%s': host must not contain whitespace"):format(name)
  end
  local port = conn.port or const.default_port(scheme)
  if conn.port ~= nil then
    -- A quoted `port = "5432"` is legal TOML, and the tunnel path wants a
    -- number; an unreadable one (`port = "{{POSTE_PORT}}"` after a typo'd or
    -- unset var, or 70000) used to be concatenated straight into the URL, so
    -- the driver got `postgres://h:{{POSTE_PORT}}/db`. Refuse it here — the
    -- same rule the Rust store applies to the same file. The value stays out
    -- of the message because `port = "{{POSTE_PASS}}"` is a plausible typo.
    -- Strings read through Rust's f64 grammar (decimal digits, optional sign
    -- / fraction / exponent, surrounding whitespace): LuaJIT's plain tonumber
    -- — even with base 10 — also takes "0x10", and a hex typo sailed into the
    -- URL as port 16 where the Rust parse refuses the same file.
    local n
    if type(conn.port) == "number" then
      n = conn.port
    elseif type(conn.port) == "string" then
      if conn.port:match("^%s*[%+%-]?%d+%.?%d*%s*$")
        or conn.port:match("^%s*[%+%-]?%d+%.?%d*[eE][%+%-]?%d+%s*$") then
        n = tonumber(conn.port)
      end
    end
    if not n or n ~= math.floor(n) or n < 1 or n > 65535 then
      return nil,
        ("Connection '%s': port must be a number between 1 and 65535"):format(name)
    end
    -- An integral float passes the check above and needs no coercion: Neovim's
    -- LuaJIT renders 5432.0 as "5432" when the URL is concatenated below
    -- (pinned by the float-port spec, since 5.4 would render "5432.0").
    port = n
  end
  -- A `tunnel` section forwards host:port through an ssh jump host; the URL
  -- (and thus the Rust binary) only ever sees the local end of the forward.
  if conn.tunnel then
    local local_port, terr
    if ensure_tunnel then
      local tunnel = require("poste-db.tunnel")
      local_port, terr = tunnel.ensure(name, conn.tunnel, host, port)
      if not local_port then
        return nil, ("Connection '%s': %s"):format(name, terr)
      end
    else
      -- Display path: reuse the running tunnel's local end, never open one.
      for _, t in ipairs(require("poste-db.tunnel").status_list()) do
        if t.name == name then local_port = t.port; break end
      end
      if not local_port then
        return nil, ("Connection '%s': tunnel not active"):format(name)
      end
    end
    host, port = "127.0.0.1", local_port
  end
  local db = conn.database or ""
  local auth = ""
  if conn.user and conn.password then
    auth = percent_encode(conn.user) .. ":" .. percent_encode(conn.password) .. "@"
  elseif conn.user then
    auth = percent_encode(conn.user) .. "@"
  end
  -- url_host only here: the tunnel path above wants the bare address to hand
  -- to ssh, and format_connection displays what the file says.
  return scheme .. "://" .. auth .. url_host(host) .. ":" .. port .. "/" .. percent_encode(db), nil
end

--- Resolve a connection name to a URL by reading connections.toml from cwd.
--- Replicates Rust's ConnectionConfig::to_url() logic, resolving `{{var}}`
--- references first.
--- @param name string Connection name
--- @return string|nil, string|nil url, error_message
function M.resolve_connection_url(name)
  local search_dir = M.get_search_dir()
  local config_path = M.find_connections_toml(search_dir)
  if not config_path then
    return nil, "connections.toml not found (searched from " .. search_dir .. ")"
  end
  local toml = require("poste-db.toml")
  local parsed, err = toml.parse_file(config_path)
  if not parsed then return nil, err end
  local conn = parsed[name]
  if not conn then return nil, "Connection '" .. name .. "' not found in " .. config_path end
  conn = apply_env(conn, M.get_env_vars(search_dir))
  conn.dialect = const.normalize_dialect(conn.dialect)
  return build_conn_url(name, conn, true)
end

--- Reverse of resolve_connection_url: the connections.toml name whose resolved
--- URL equals `url`. Display fallback for surfaces that only hold a URL — the
--- Rust binary echoes connection URLs, never names (exec_file.rs), so the
--- dataset winbar/statusline would otherwise degrade to host:port. Never
--- opens a tunnel: tunneled entries only match while their tunnel is running.
--- The parse is shared with get_connection_config's mtime-keyed cache; the
--- per-entry env re-resolution is cheap (dotenv/env.json are mtime-cached too).
--- @param url string
--- @return string|nil name
function M.name_for_url(url)
  if not url or url == "" then return nil end
  local parsed = cached_parsed_config()
  if not parsed then return nil end
  local vars = M.get_env_vars(M.get_search_dir())
  for name, entry in pairs(parsed) do
    if type(entry) == "table" then
      local conn = apply_env(entry, vars)
      conn.dialect = const.normalize_dialect(conn.dialect)
      if build_conn_url(name, conn, false) == url then return name end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Binary discovery
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- List connections
---------------------------------------------------------------------------

--- Fetch connections from connections.toml.
--- @param callback function(connections: table[]) Called with parsed connection list
function M.list_connections(callback)
  local search_dir = M.get_search_dir()
  local config_path = M.find_connections_toml(search_dir)
  if not config_path then
    vim.schedule(function() callback({}) end)
    return
  end
  local toml = require("poste-db.toml")
  local parsed, err = toml.parse_file(config_path)
  if not parsed then
    -- A broken file must not look like "no connections": the picker's next
    -- message advises creating a connections.toml, and the file is right
    -- there. Name the parse error so the typo is fixable from the message.
    vim.notify("connections.toml parse failed: " .. tostring(err),
      vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    vim.schedule(function() callback({}) end)
    return
  end
    local list = {}
    local vars = M.get_env_vars(search_dir)
    for name, conn in pairs(parsed) do
      -- Same convention as name_for_url: only [section] tables are connections.
      if type(conn) ~= "table" then goto continue end
      conn = apply_env(conn, vars)
      conn.dialect = const.normalize_dialect(conn.dialect)
      -- Skip dialects poste-db does not support (satellite sections from a
    -- shared connections.toml, e.g. redis)
    if not const.is_sql_dialect(conn.dialect) then goto continue end
    -- `tunnel` rides along so the picker's 🔒 mark and run_test's
    -- tunnel-routed test can see it; dropping it here made both dead.
    table.insert(list, { name = name, dialect = conn.dialect, host = conn.host, port = conn.port, database = conn.database, path = conn.path, tunnel = conn.tunnel })
    ::continue::
  end
  -- Sorted by name: pairs() walks the toml table in hash order, which flips
  -- as the file is edited — the picker (and every other consumer) would
  -- show a different order per call. poste-redis sorts its picker rows on
  -- the same reasoning.
  table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
  vim.schedule(function() callback(list) end)
end

---------------------------------------------------------------------------
-- Format connection for display
---------------------------------------------------------------------------

local dialect_icons = {
  postgres = "🐘",
  mysql = "🐬",
  mariadb = "🐬",
  sqlite = "📦",
  mssql = "🏛️",
  clickhouse = "🧅",
}

local function format_connection(conn, active_name)
  local icon = dialect_icons[conn.dialect] or "❓"
  local name = conn.name or "?"
  local tunnel_mark = conn.tunnel and " 🔒" or ""
  -- Mark the connection the current buffer context already points at, so the
  -- picker answers "which one am I on?" before the user re-picks blindly.
  local active_mark = (active_name and name == active_name) and "  [active]" or ""

  if conn.dialect == "sqlite" then
    return string.format("%s %s — %s%s%s", icon, name, conn.path or "?", tunnel_mark, active_mark)
  else
    local host = conn.host or "localhost"
    -- tonumber: a quoted `port = "5432"` in connections.toml is a string and
    -- would make %d throw, killing the whole picker
    local port = tonumber(conn.port) or const.default_port(conn.dialect) or 3306
    local db = conn.database or ""
    return string.format("%s %s — %s:%d/%s%s%s", icon, name, host, port, db, tunnel_mark, active_mark)
  end
end

---------------------------------------------------------------------------
-- Select connection
---------------------------------------------------------------------------

--- Open connection picker.
function M.select_connection()
  M.list_connections(function(connections)
    if #connections == 0 then
      vim.notify("No connections found. Create a connections.toml file.", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
      return
    end

    local items = {}
    for _, conn in ipairs(connections) do
      table.insert(items, format_connection(conn, state.context.connection))
    end

    select_mod.select(items, "Select Connection", function(selected)
      if not selected then return end

      -- Find the matching connection
      for i, item in ipairs(items) do
        if item == selected then
          local conn = connections[i]
          M.apply_connection(conn)
          break
        end
      end
    end)
  end)
end

--- Apply a selected connection to the current buffer.
--- Updates @connection directive and sql_state.context.connection.
function M.apply_connection(conn)
  local conn_name = conn.name
  state.context.connection = conn_name

  -- Update or insert @connection directive in the current buffer
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].swapfile = false
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local found = false

  for i, line in ipairs(lines) do
    if const.match_directive(line, const.DIRECTIVE_CONNECTION) then
      -- Update existing directive
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "-- @" .. const.DIRECTIVE_CONNECTION .. " " .. conn_name })
      found = true
      break
    end
    -- Stop searching after first ### marker
    if const.is_section_marker(line) then break end
  end

  if not found then
    -- No existing directive: insert before the first ### section marker, or
    -- append after the last line when the file has no markers (tested
    -- behavior — appending keeps the user's SQL untouched and directive
    -- extraction scans the whole buffer anyway).
    local insert_line = 1
    for i, line in ipairs(lines) do
      if const.is_section_marker(line) then
        insert_line = i
        break
      end
      insert_line = i + 1
    end
    vim.api.nvim_buf_set_lines(buf, insert_line - 1, insert_line - 1, false, {
      "-- @" .. const.DIRECTIVE_CONNECTION .. " " .. conn_name,
      "",
    })
  end

  vim.notify(string.format("Connection set to: %s", conn_name), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
end

---------------------------------------------------------------------------
-- Test connection
---------------------------------------------------------------------------

--- Test a connection by name.
function M.test_connection()
  M.list_connections(function(connections)
    if #connections == 0 then
      vim.notify("No connections found.", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
      return
    end

    local items = {}
    for _, conn in ipairs(connections) do
      table.insert(items, format_connection(conn, state.context.connection))
    end

    select_mod.select(items, "Test Connection", function(selected)
      if not selected then return end

      for i, item in ipairs(items) do
        if item == selected then
          local conn = connections[i]
          M.run_test(conn)
          break
        end
      end
    end)
  end)
end

--- Test a tunneled connection. The Rust `connection test` subcommand reads
--- connections.toml directly and cannot route through the Lua-side tunnel,
--- so probe with a trivial SELECT on the rewritten URL instead.
function M.run_test_via_tunnel(conn)
  vim.notify(string.format("Testing '%s' (via tunnel)...", conn.name), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })

  local url, err = M.resolve_connection_url(conn.name)
  if not url then
    vim.notify(string.format("✗ Connection '%s': %s", conn.name, err or "unresolved"), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local resp = require("poste-db.exec_run").run_sql("SELECT 1", {
    conn_url = url,
    database = conn.database or "",
    log_source = "connection",
    log_extra = { connection = conn.name },
  })
  local ok = resp ~= nil and not resp.has_error
  vim.notify(
    ok and string.format("✓ Connection '%s' OK (via tunnel)", conn.name)
      or string.format("✗ Connection '%s' FAILED (via tunnel)", conn.name), ok and vim.log.levels.INFO or vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
end

--- Run the test for a specific connection.
function M.run_test(conn)
  if conn.tunnel and conn.dialect ~= "sqlite" then
    M.run_test_via_tunnel(conn)
    return
  end

  local search_dir = M.get_search_dir()
  local cmd = { "connection", "test", conn.name, "--path", search_dir }

  vim.notify(string.format("Testing '%s'...", conn.name), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })

  local t0 = vim.uv.now()
  cli.run_async(cmd, {
    on_exit = function(code)
      require("poste-db.sql_log").record({
        source = "connection",
        sql = "connection test " .. conn.name,
        connection = conn.name,
        status = code == 0 and "success" or "error",
        elapsed_ms = vim.uv.now() - t0,
        error_msg = code ~= 0 and ("probe exit code " .. tostring(code)) or nil,
      })
      vim.schedule(function()
        if code == 0 then
          vim.notify(string.format("✓ Connection '%s' OK", conn.name), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
        else
          vim.notify(string.format("✗ Connection '%s' FAILED", conn.name), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
        end
      end)
    end,
  })
end

---------------------------------------------------------------------------
-- Main entry point
---------------------------------------------------------------------------

--- Show the connection management menu.
function M.show_menu()
  local items = {
    "Select connection",
    "Test connection",
  }

  select_mod.select(items, "Connection Manager", function(selected)
    if selected == "Select connection" then
      M.select_connection()
    elseif selected == "Test connection" then
      M.test_connection()
    end
  end)
end

M._test = {
  format_connection = format_connection,
  percent_encode = percent_encode,
}

return M
