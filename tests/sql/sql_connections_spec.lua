
local cli_stub = {}
local state_stub = {
  context = { connection = nil, database = nil },
  log = function() end,  -- merged poste.state surface (state.log caller)
}
local util_stub = { find_file_upwards = function() return nil end }
local select_stub = { select = function() end }

package.loaded["poste-db.cli"] = cli_stub
package.loaded["poste-db.state"] = state_stub
package.loaded["poste-db.util"] = util_stub
package.loaded["poste-db.select"] = select_stub
package.loaded["poste-db.constants"] = require("poste-db.constants")

local toml_parse_calls = {}
package.loaded["poste-db.toml"] = {
  parse_file = function(path)
    table.insert(toml_parse_calls, path)
    if path:match("found") then
      return { primary = { dialect = "postgres", host = "localhost", port = 5432, database = "blog", user = "alice" } }
    end
    return nil, "parse error"
  end,
}

local connections = require("poste-db.connections")

describe("connections find_connections_toml", function()
  local tmpdir

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
  end)

  after_each(function()
    pcall(vim.fn.delete, tmpdir, "rf")
  end)

  it("returns nil when no connections.toml found", function()
    util_stub.find_file_upwards = function() return nil end
    assert.is_nil(connections.find_connections_toml(tmpdir))
  end)

  it("returns path when connections.toml found", function()
    local config_path = tmpdir .. "/connections.toml"
    vim.fn.writefile({ "[test]", "dialect = \"sqlite\"" }, config_path)
    util_stub.find_file_upwards = function() return config_path end
    assert.equals(config_path, connections.find_connections_toml(tmpdir))
  end)

  it("caches results", function()
    local config_path = tmpdir .. "/connections.toml"
    util_stub.find_file_upwards = function() return config_path end
    local first = connections.find_connections_toml(tmpdir)
    util_stub.find_file_upwards = function() return nil end
    assert.equals(first, connections.find_connections_toml(tmpdir))
  end)

  it("discovers a connections.toml created AFTER a miss", function()
    -- the negative result used to be cached as `false` with no mtime to
    -- invalidate and no invalidate() hook, so following the setup docs
    -- (create connections.toml, then USE it) worked only after a restart
    util_stub.find_file_upwards = function() return nil end
    assert.is_nil(connections.find_connections_toml(tmpdir))

    local config_path = tmpdir .. "/connections.toml"
    vim.fn.writefile({ "[test]", "dialect = \"sqlite\"" }, config_path)
    util_stub.find_file_upwards = function() return config_path end
    assert.equals(config_path, connections.find_connections_toml(tmpdir))
  end)
end)

describe("connections get_search_dir", function()
  local saved_cwd, saved_buf

  before_each(function()
    saved_cwd = vim.fn.getcwd()
    saved_buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    vim.api.nvim_set_current_buf(saved_buf)
    vim.fn.chdir(saved_cwd)
  end)

  it("uses the current file buffer's directory", function()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/poste-search/query.sql")
    vim.api.nvim_set_option_value("buftype", "", { buf = buf })
    vim.api.nvim_set_current_buf(buf)
    assert.equals("/tmp/poste-search", connections.get_search_dir())
  end)

  it("falls back to cwd on a pseudo buffer instead of its fake name", function()
    -- poste://dataset / poste://db_browser / health:// carry a non-empty but
    -- non-file name; the old buffer-name rule resolved the search root to
    -- "poste:" / "health:" so the statusline and :checkhealth could read a
    -- different connections.toml than the SQL file being edited.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "poste://dataset")
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_current_buf(buf)
    assert.equals(saved_cwd, connections.get_search_dir())
  end)
end)

describe("connections resolve_connection_url", function()
  local tmpdir
  local saved_cwd

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    saved_cwd = vim.fn.getcwd()
    vim.fn.chdir(tmpdir)
    util_stub.find_file_upwards = function() return tmpdir .. "/connections.toml" end
  end)

  after_each(function()
    vim.fn.chdir(saved_cwd)
    pcall(vim.fn.delete, tmpdir, "rf")
  end)

  it("returns nil when no connections.toml found", function()
    util_stub.find_file_upwards = function() return nil end
    local url, err = connections.resolve_connection_url("primary")
    assert.is_nil(url)
    assert.matches("not found", err or "")
  end)

  it("returns nil when connection not in config", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { other = { dialect = "sqlite" } }
    end
    local url, err = connections.resolve_connection_url("missing")
    assert.is_nil(url)
    assert.matches("not found", err or "")
  end)

  it("rejects unsupported dialect (shared connections.toml)", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { cache = { dialect = "elasticsearch", host = "127.0.0.1", port = 9200 } }
    end
    local url, err = connections.resolve_connection_url("cache")
    assert.is_nil(url)
    assert.matches("unsupported dialect", err or "")
  end)

  it("missing dialect builds a postgres URL (nil-dialect default)", function()
    -- the is_sql_dialect gate allows nil ("defaults behave like postgres"),
    -- but build_conn_url used to concatenate the nil scheme — a section
    -- without a dialect crashed every resolution of it
    package.loaded["poste-db.toml"].parse_file = function()
      return { legacy = { host = "old-db", database = "main" } }
    end
    local url = connections.resolve_connection_url("legacy")
    assert.equals("postgres://old-db:5432/main", url)
  end)

  it("names the port field when the host carries one", function()
    -- the connection-string habit `host = "localhost:5432"` built
    -- `postgres://localhost:5432:5432/db`, which only failed at the binary
    -- with a URL parse error naming nothing (synced with poste-redis)
    package.loaded["poste-db.toml"].parse_file = function()
      return { cache = { dialect = "postgres", host = "localhost:5432", database = "d" } }
    end
    local url, err = connections.resolve_connection_url("cache")
    assert.is_nil(url)
    assert.matches("port", err)
    assert.matches("localhost:5432", err)
  end)

  it("refuses a hex-spelled port string like the Rust mirror does", function()
    -- LuaJIT's plain tonumber accepts "0x10" as 16, so the typo sailed into
    -- the URL and the statement ran against port 16 while the Rust f64 parse
    -- refused the same file — one connection, one reading
    package.loaded["poste-db.toml"].parse_file = function()
      return { cache = { dialect = "postgres", host = "h", port = "0x10", database = "d" } }
    end
    local url, err = connections.resolve_connection_url("cache")
    assert.is_nil(url)
    assert.matches("port must be a number", err)
  end)

  it("still takes a quoted decimal port string", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { cache = { dialect = "postgres", host = "h", port = "5432", database = "d" } }
    end
    local url = connections.resolve_connection_url("cache")
    assert.equals("postgres://h:5432/d", url)
  end)

  it("rejects a host with whitespace", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { cache = { dialect = "postgres", host = "my host", database = "d" } }
    end
    local url, err = connections.resolve_connection_url("cache")
    assert.is_nil(url)
    assert.matches("whitespace", err)
  end)

  it("still accepts a MSSQL named-instance host (no colon)", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { cache = { dialect = "mssql", host = "server\\inst", database = "d" } }
    end
    local url = connections.resolve_connection_url("cache")
    assert.equals("mssql://server\\inst:1433/d", url)
  end)

  it("rejects a non-string field instead of crashing the resolver", function()
    -- the TOML parser turns `host = [1]` into a real table; the builder used
    -- to crash on `:sub` / `..` (completion, the winbar and the browser all
    -- resolve on redraw) instead of naming the bad field
    local shapes = {
      { cache = { dialect = "postgres", host = { "h" } } },
      { cache = { dialect = "postgres", host = "h", user = { "u" } } },
      { cache = { dialect = "postgres", host = "h", password = { "p" } } },
      { cache = { dialect = "postgres", host = "h", database = { "d" } } },
      { cache = { dialect = "postgres", url = { "postgres://h/d" } } },
      { cache = { dialect = "sqlite", path = { "/tmp/x.sqlite" } } },
    }
    for i, parsed in ipairs(shapes) do
      package.loaded["poste-db.toml"].parse_file = function() return parsed end
      local url, err = connections.resolve_connection_url("cache")
      assert.is_nil(url, "shape " .. i .. " returned a url")
      assert.matches("must be a string", err or "", 1, true)
      assert.truthy(err:find("cache", 1, true))
    end
  end)

  it("accepts a quoted port and keeps the numeric form", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return {
        quoted = { dialect = "postgres", host = "h", port = "5433", database = "blog" },
      }
    end
    assert.equals("postgres://h:5433/blog",
      connections.resolve_connection_url("quoted"))
  end)

  it("renders an integral float port as an integer, not 5432.0", function()
    -- `port = 5432.0` is a TOML float and tonumber accepts it. LuaJIT (the
    -- only runtime Neovim ships) renders it as "5432" on concatenation, so
    -- the URL is well-formed; this pins that, because a 5.4 host would build
    -- `postgres://h:5432.0/blog` from the same code
    for _, value in ipairs({ "5432.0", 5432.0 }) do
      package.loaded["poste-db.toml"].parse_file = function()
        return {
          floater = { dialect = "postgres", host = "h", port = value, database = "blog" },
        }
      end
      assert.equals("postgres://h:5432/blog",
        connections.resolve_connection_url("floater"))
    end
  end)

  it("refuses a port that is not a port number instead of building a bad URL", function()
    -- `port = "{{POSTE_PORT}}"` (typo'd / unset var) reached the driver as a
    -- literal host:{{POSTE_PORT}}; an out-of-range integer had the same fate
    for _, value in ipairs({ "{{POSTE_PORT}}", "abc", 70000, 0, "5432.5" }) do
      package.loaded["poste-db.toml"].parse_file = function()
        return { broken = { dialect = "postgres", host = "h", port = value } }
      end
      local url, err = connections.resolve_connection_url("broken")
      assert.is_nil(url, ("port = %s resolved anyway"):format(tostring(value)))
      assert.matches("port must be a number between 1 and 65535", err or "")
      assert.is_nil((err or ""):find("POSTE_PORT", 1, true),
        "the value stays out of the message (it can be a mistyped secret)")
    end
  end)

  it("builds postgres URL from fields", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgres", host = "pg.example.com", port = 5432, database = "blog", user = "alice" } }
    end
    local url = connections.resolve_connection_url("primary")
    assert.equals("postgres://alice@pg.example.com:5432/blog", url)
  end)

  -- An IPv6 literal is only legal in a URL authority once it is bracketed
  -- (RFC 3986 §3.2.2), and the drivers enforce it: `poste introspect` answers
  -- `error with configuration: empty host` for postgres://::1:5432/db — before
  -- it dials anything — while the bracketed form reaches the connect step.
  it("brackets an IPv6 host so the driver can parse the URL", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgres", host = "::1", port = 5432, database = "blog" } }
    end
    assert.equals("postgres://[::1]:5432/blog", connections.resolve_connection_url("primary"))
  end)

  it("brackets nothing that is not an IPv6 literal", function()
    -- already bracketed (the form that worked before), plain names, IPv4, and
    -- a hex-only hostname that has no colon. (`localhost:5432` used to be in
    -- this list asserting the port-in-host paste passed through verbatim; it
    -- is now rejected with a "move it to the `port` field" error instead.)
    for _, host in ipairs({ "[::1]", "db.example.com", "10.0.0.1",
      "abcdef" }) do
      package.loaded["poste-db.toml"].parse_file = function()
        return { primary = { dialect = "postgres", host = host, port = 5432, database = "blog" } }
      end
      assert.equals(("postgres://%s:5432/blog"):format(host),
        connections.resolve_connection_url("primary"), host)
    end
  end)

  it("builds postgres URL with password", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgres", host = "localhost", port = 5432, database = "blog", user = "alice", password = "secret" } }
    end
    local url = connections.resolve_connection_url("primary")
    assert.equals("postgres://alice:secret@localhost:5432/blog", url)
  end)

  it("percent-encodes special chars in user and password", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgres", host = "localhost", port = 5432, database = "blog", user = "alice", password = "p@ss:w/rd%" } }
    end
    local url = connections.resolve_connection_url("primary")
    assert.equals("postgres://alice:p%40ss%3Aw%2Frd%25@localhost:5432/blog", url)
  end)

  it("percent-encodes user when it contains special chars", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgres", host = "localhost", port = 5432, database = "blog", user = "user@example.com", password = "pw" } }
    end
    local url = connections.resolve_connection_url("primary")
    assert.equals("postgres://user%40example.com:pw@localhost:5432/blog", url)
  end)

  it("builds mysql URL", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "mysql", host = "db.example.com", port = 3306, database = "shop", user = "root" } }
    end
    local url = connections.resolve_connection_url("primary")
    assert.equals("mysql://root@db.example.com:3306/shop", url)
  end)

  it("builds sqlite URL from path", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { localdb = { dialect = "sqlite", path = "/data/test.db" } }
    end
    local url = connections.resolve_connection_url("localdb")
    assert.equals("sqlite:/data/test.db?mode=rwc", url)
  end)

  it("sqlite paths with a query string gain mode=rwc via & (or keep an explicit mode)", function()
    -- appending `?mode=rwc` to a path that already had a query produced an
    -- invalid URL (09-11 carry)
    package.loaded["poste-db.toml"].parse_file = function()
      return {
        q = { dialect = "sqlite", path = "data.db?cache=shared" },
        m = { dialect = "sqlite", path = "data.db?mode=ro" },
      }
    end
    assert.equals("sqlite:data.db?cache=shared&mode=rwc", connections.resolve_connection_url("q"))
    assert.equals("sqlite:data.db?mode=ro", connections.resolve_connection_url("m"))
  end)

  it("builds sqlite :memory: URL", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { mem = { dialect = "sqlite" } }
    end
    local url = connections.resolve_connection_url("mem")
    assert.equals("sqlite::memory:", url)
  end)

  it("treats an empty sqlite path as :memory:", function()
    -- `path = ""` is an unset path, not a file named "": the old
    -- `conn.path or ":memory:"` let the empty string through and built the
    -- invalid `sqlite:?mode=rwc`.
    package.loaded["poste-db.toml"].parse_file = function()
      return { mem = { dialect = "sqlite", path = "" } }
    end
    local url = connections.resolve_connection_url("mem")
    assert.equals("sqlite::memory:", url)
  end)

  it("builds mssql URL from fields with default port", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return {
        m1 = { dialect = "mssql", host = "sql.example.com", database = "shop", user = "sa" },
        m2 = { dialect = "mssql", host = "localhost", port = 11433, database = "shop", user = "sa", password = "p@ss" },
      }
    end
    assert.equals("mssql://sa@sql.example.com:1433/shop", connections.resolve_connection_url("m1"))
    assert.equals("mssql://sa:p%40ss@localhost:11433/shop", connections.resolve_connection_url("m2"))
  end)

  it("accepts the postgresql spelling as postgres", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgresql", host = "pg.example.com", database = "blog", user = "alice" } }
    end
    assert.equals("postgres://alice@pg.example.com:5432/blog", connections.resolve_connection_url("primary"))
  end)

  it("builds clickhouse URL with default port", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { ch = { dialect = "clickhouse", host = "ch.example.com", database = "playground", user = "default" } }
    end
    assert.equals("clickhouse://default@ch.example.com:8123/playground", connections.resolve_connection_url("ch"))
  end)

  it("normalizes compat aliases to their base protocol URL", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return {
        crdb = { dialect = "cockroachdb", host = "crdb.example.com", database = "blog", user = "alice" },
        yb = { dialect = "yugabyte", host = "yb.example.com", database = "blog", user = "alice", password = "pw" },
        ps = { dialect = "planetscale", host = "aws.connect.psdb.cloud", database = "shop", user = "root" },
        maria = { dialect = "mariadb", host = "localhost", database = "shop", user = "root" },
      }
    end
    -- Aliases must land on their base protocol URL, never the binary
    -- fallback scheme (the old `postgres or mysql` default).
    assert.equals("postgres://alice@crdb.example.com:5432/blog", connections.resolve_connection_url("crdb"))
    assert.equals("postgres://alice:pw@yb.example.com:5432/blog", connections.resolve_connection_url("yb"))
    assert.equals("mysql://root@aws.connect.psdb.cloud:3306/shop", connections.resolve_connection_url("ps"))
    assert.equals("mysql://root@localhost:3306/shop", connections.resolve_connection_url("maria"))
  end)

  it("uses url field directly when present", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { custom = { dialect = "postgres", url = "postgres://custom@localhost/mydb" } }
    end
    local url = connections.resolve_connection_url("custom")
    assert.equals("postgres://custom@localhost/mydb", url)
  end)

  describe("with a tunnel section", function()
    local saved_parse, saved_tunnel

    before_each(function()
      saved_parse = package.loaded["poste-db.toml"].parse_file
      saved_tunnel = package.loaded["poste-db.tunnel"]
      package.loaded["poste-db.tunnel"] = {
        ensure = function(name, cfg, host, port)
          return 15432
        end,
      }
    end)

    after_each(function()
      package.loaded["poste-db.toml"].parse_file = saved_parse
      package.loaded["poste-db.tunnel"] = saved_tunnel
    end)

    it("rewrites host/port to the tunnel's local end", function()
      package.loaded["poste-db.toml"].parse_file = function()
        return { primary = {
          dialect = "postgres", host = "db.internal", port = 5432,
          database = "blog", user = "alice", tunnel = "jump@bastion",
        } }
      end
      assert.equals("postgres://alice@127.0.0.1:15432/blog",
        connections.resolve_connection_url("primary"))
    end)

    it("passes the connection host/port to tunnel.ensure", function()
      local seen
      package.loaded["poste-db.tunnel"] = {
        ensure = function(name, cfg, host, port)
          seen = { name = name, cfg = cfg, host = host, port = port }
          return 16000
        end,
      }
      package.loaded["poste-db.toml"].parse_file = function()
        return { primary = {
          dialect = "mysql", host = "db.internal", port = 3306,
          database = "shop", user = "root", tunnel = { to = "jump@bastion", port = 2222 },
        } }
      end
      connections.resolve_connection_url("primary")
      assert.same({ name = "primary", cfg = { to = "jump@bastion", port = 2222 },
        host = "db.internal", port = 3306 }, seen)
    end)

    -- Brackets belong to the URL, not to ssh: a tunneled IPv6 host still has
    -- to reach tunnel.ensure as written in the file.
    it("hands tunnel.ensure the bare IPv6 address and brackets only the URL", function()
      local seen_host
      package.loaded["poste-db.tunnel"] = {
        ensure = function(name, cfg, host, port)
          seen_host = host
          return 15433
        end,
      }
      package.loaded["poste-db.toml"].parse_file = function()
        return { primary = {
          dialect = "postgres", host = "::1", port = 5432,
          database = "blog", tunnel = "jump@bastion",
        } }
      end
      assert.equals("postgres://127.0.0.1:15433/blog",
        connections.resolve_connection_url("primary"))
      assert.equals("::1", seen_host)
    end)

    it("propagates tunnel failures", function()
      package.loaded["poste-db.tunnel"] = {
        ensure = function() return nil, "ssh tunnel failed" end,
      }
      package.loaded["poste-db.toml"].parse_file = function()
        return { primary = {
          dialect = "postgres", host = "db.internal", port = 5432,
          database = "blog", tunnel = "jump@bastion",
        } }
      end
      local url, err = connections.resolve_connection_url("primary")
      assert.is_nil(url)
      assert.matches("ssh tunnel failed", err or "")
    end)

    it("expands {{VAR}} inside nested tables like tunnel.to", function()
      -- apply_env used to pass nested tables through substitute_vars
      -- untouched, so tunnel.ensure received the literal "{{POSTE_TEST_BASTION}}"
      -- and the failure read like a tunnel problem instead of a config one.
      vim.env.POSTE_TEST_BASTION = "jump@bastion"
      package.loaded["poste-db.toml"].parse_file = function()
        return { primary = {
          dialect = "postgres", host = "db.internal", port = 5432,
          database = "blog", user = "alice",
          tunnel = { to = "{{POSTE_TEST_BASTION}}" },
        } }
      end
      local seen
      package.loaded["poste-db.tunnel"] = {
        ensure = function(_, cfg) seen = cfg; return 17000 end,
      }
      connections.resolve_connection_url("primary")
      vim.env.POSTE_TEST_BASTION = nil
      assert.same({ to = "jump@bastion" }, seen)
    end)

    it("rejects tunnel combined with a raw url field", function()
      package.loaded["poste-db.toml"].parse_file = function()
        return { custom = {
          dialect = "postgres", url = "postgres://custom@localhost/mydb",
          tunnel = "jump@bastion",
        } }
      end
      local url, err = connections.resolve_connection_url("custom")
      assert.is_nil(url)
      assert.matches("host/port form", err or "")
    end)

    it("ignores tunnel for sqlite file connections", function()
      package.loaded["poste-db.toml"].parse_file = function()
        return { localdb = { dialect = "sqlite", path = "/data/test.db", tunnel = "jump@bastion" } }
      end
      assert.equals("sqlite:/data/test.db?mode=rwc",
        connections.resolve_connection_url("localdb"))
    end)
  end)
end)

describe("connections get_connection_config", function()
  local tmpdir
  local saved_cwd

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    saved_cwd = vim.fn.getcwd()
    vim.fn.chdir(tmpdir)
    util_stub.find_file_upwards = function() return tmpdir .. "/connections.toml" end
  end)

  after_each(function()
    vim.fn.chdir(saved_cwd)
    pcall(vim.fn.delete, tmpdir, "rf")
  end)

  it("returns nil when no connections.toml found", function()
    util_stub.find_file_upwards = function() return nil end
    assert.is_nil(connections.get_connection_config("primary"))
  end)

  it("returns nil when toml parse fails", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return nil, "parse error"
    end
    assert.is_nil(connections.get_connection_config("missing"))
  end)

  it("caches parse failures until the file changes", function()
    -- get_connection_config runs from the statusline on every redraw; a
    -- broken connections.toml must not re-read + re-parse + re-log per call.
    local calls = 0
    package.loaded["poste-db.toml"].parse_file = function()
      calls = calls + 1
      return nil, "parse error"
    end
    assert.is_nil(connections.get_connection_config("primary"))
    assert.is_nil(connections.get_connection_config("primary"))
    assert.equals(1, calls, "second call must be served from the failure cache")
  end)

  it("returns connection config when found", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgres", host = "localhost", port = 5432, database = "blog", user = "alice" } }
    end
    local config = connections.get_connection_config("primary")
    assert.same({ dialect = "postgres", host = "localhost", port = 5432, database = "blog", user = "alice" }, config)
  end)

  it("converts mariadb to mysql dialect", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "mariadb" } }
    end
    local config = connections.get_connection_config("primary")
    assert.equals("mysql", config.dialect)
  end)

  it("returns nil for a top-level scalar, not a string it cannot index", function()
    -- A stale `-- @connection description` directive used to reach
    -- `conn.dialect = …` on a string and throw.
    package.loaded["poste-db.toml"].parse_file = function()
      return { description = "shared file", primary = { dialect = "postgres" } }
    end
    assert.is_nil(connections.get_connection_config("description"))
  end)
end)

describe("connections list_connections", function()
  local tmpdir
  local saved_cwd

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    saved_cwd = vim.fn.getcwd()
    vim.fn.chdir(tmpdir)
    util_stub.find_file_upwards = function() return nil end
  end)

  after_each(function()
    vim.fn.chdir(saved_cwd)
    pcall(vim.fn.delete, tmpdir, "rf")
  end)

  it("calls callback with empty list when no toml found", function()
    local captured
    connections.list_connections(function(list) captured = list end)
    vim.wait(100, function() return captured ~= nil end)
    assert.same({}, captured)
  end)

  it("notifies instead of staying silent when the toml is broken", function()
    -- A parse failure used to answer the same empty list as a missing file,
    -- and the picker then advised creating a connections.toml that exists.
    local config_path = tmpdir .. "/connections.toml"
    vim.fn.writefile({ "[primary", "dialect = \"postgres\"" }, config_path)
    util_stub.find_file_upwards = function() return config_path end
    package.loaded["poste-db.toml"].parse_file = function()
      return nil, "Invalid table header"
    end
    local saved_notify = vim.notify
    local notices = {}
    vim.notify = function(msg, level) notices[#notices + 1] = { msg = msg, level = level } end
    local captured
    connections.list_connections(function(list) captured = list end)
    vim.wait(100, function() return captured ~= nil end)
    vim.notify = saved_notify
    assert.same({}, captured)
    assert.equals(1, #notices)
    assert.truthy(notices[1].msg:find("parse failed", 1, true))
    assert.truthy(notices[1].msg:find("Invalid table header", 1, true))
  end)

  it("calls callback with parsed connections", function()
    local config_path = tmpdir .. "/connections.toml"
    vim.fn.writefile({ "[primary]", "dialect = \"postgres\"" }, config_path)
    util_stub.find_file_upwards = function() return config_path end
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgres" } }
    end
    local captured
    connections.list_connections(function(list) captured = list end)
    vim.wait(100, function() return captured ~= nil end)
    assert.is_not_nil(captured)
    assert.equals(1, #captured)
    assert.equals("primary", captured[1].name)
    assert.equals("postgres", captured[1].dialect)
  end)

  it("skips a top-level scalar above the first section", function()
    local config_path = tmpdir .. "/connections.toml"
    vim.fn.writefile({ "[primary]", "dialect = \"postgres\"" }, config_path)
    util_stub.find_file_upwards = function() return config_path end
    -- toml.parse puts `key = value` lines before any [section] at the root
    package.loaded["poste-db.toml"].parse_file = function()
      return { description = "shared file", primary = { dialect = "postgres" } }
    end
    local captured
    connections.list_connections(function(list) captured = list end)
    vim.wait(100, function() return captured ~= nil end)
    assert.equals(1, #captured)
    assert.equals("primary", captured[1].name)
  end)

  it("skips unsupported dialects from a shared connections.toml", function()
    local config_path = tmpdir .. "/connections.toml"
    util_stub.find_file_upwards = function() return config_path end
    package.loaded["poste-db.toml"].parse_file = function()
      return {
        primary = { dialect = "postgres", host = "localhost" },
        cache = { dialect = "elasticsearch", host = "127.0.0.1" },
      }
    end
    local captured
    connections.list_connections(function(list) captured = list end)
    vim.wait(100, function() return captured ~= nil end)
    assert.is_not_nil(captured)
    assert.equals(1, #captured)
    assert.equals("primary", captured[1].name)
  end)

  it("keeps the tunnel field on the picker rows", function()
    -- format_connection's 🔒 mark and run_test's tunnel routing read
    -- conn.tunnel; the row builder used to drop the field, making both dead
    -- for every row that came through list_connections.
    local config_path = tmpdir .. "/connections.toml"
    vim.fn.writefile({ "[primary]", "dialect = \"postgres\"", "tunnel = \"jump@bastion\"" },
      config_path)
    util_stub.find_file_upwards = function() return config_path end
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgres", tunnel = "jump@bastion" } }
    end
    local captured
    connections.list_connections(function(list) captured = list end)
    vim.wait(100, function() return captured ~= nil end)
    assert.equals("jump@bastion", captured[1].tunnel)
  end)

  it("sorts the list by name regardless of toml table order", function()
    -- pairs() walks the parsed table in hash order, which flips as the file
    -- is edited; the picker would show a different order per call
    local config_path = tmpdir .. "/connections.toml"
    util_stub.find_file_upwards = function() return config_path end
    package.loaded["poste-db.toml"].parse_file = function()
      return {
        zeta = { dialect = "postgres", host = "h" },
        alpha = { dialect = "mysql", host = "h" },
        mid = { dialect = "sqlite", path = "/tmp/x.db" },
      }
    end
    local captured
    connections.list_connections(function(list) captured = list end)
    vim.wait(100, function() return captured ~= nil end)
    assert.same({ "alpha", "mid", "zeta" },
      { captured[1].name, captured[2].name, captured[3].name })
  end)
end)

describe("connections env var resolution", function()
  local tmpdir
  local saved_cwd

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    saved_cwd = vim.fn.getcwd()
    vim.fn.chdir(tmpdir)
    util_stub.find_file_upwards = function(filename)
      if filename == ".env" then
        return tmpdir .. "/.env"
      end
      if filename == "env.json" then
        return tmpdir .. "/env.json"
      end
      return tmpdir .. "/connections.toml"
    end
  end)

  after_each(function()
    vim.env.POSTE_TEST_DB_PASS = nil
    vim.fn.chdir(saved_cwd)
    pcall(vim.fn.delete, tmpdir, "rf")
  end)

  it("substitutes known vars and keeps unknown ones literal", function()
    local vars = { DB_USER = "alice" }
    assert.equals("alice", connections.substitute_vars("{{DB_USER}}", vars))
    assert.equals("alice:secret", connections.substitute_vars("{{DB_USER}}:secret", vars))
    assert.equals("{{DB_PASS}}", connections.substitute_vars("{{DB_PASS}}", vars))
    assert.equals(5432, connections.substitute_vars(5432, vars))
  end)

  it("resolves {{VAR}} from .env in connection config", function()
    vim.fn.writefile({ "POSTE_TEST_DB_PASS=supersecret" }, tmpdir .. "/.env")
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgres", host = "localhost", port = 5432, database = "blog", user = "alice", password = "{{POSTE_TEST_DB_PASS}}" } }
    end
    local config = connections.get_connection_config("primary")
    assert.equals("supersecret", config.password)
  end)

  it("resolves {{VAR}} from .env in resolved URL", function()
    vim.fn.writefile({ "POSTE_TEST_DB_PASS=supersecret" }, tmpdir .. "/.env")
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgres", host = "localhost", port = 5432, database = "blog", user = "alice", password = "{{POSTE_TEST_DB_PASS}}" } }
    end
    local url = connections.resolve_connection_url("primary")
    assert.equals("postgres://alice:supersecret@localhost:5432/blog", url)
  end)

  it("keeps unresolved {{VAR}} literal when .env is missing", function()
    package.loaded["poste-db.toml"].parse_file = function()
      return { primary = { dialect = "postgres", host = "localhost", port = 5432, database = "blog", user = "alice", password = "{{DB_PASS}}" } }
    end
    local url = connections.resolve_connection_url("primary")
    assert.equals("postgres://alice:%7B%7BDB_PASS%7D%7D@localhost:5432/blog", url)
  end)

  it("prefers OS env over .env over env.json", function()
    vim.fn.writefile({ '{"dev": {"POSTE_TEST_DB_PASS": "from-envjson"}}' }, tmpdir .. "/env.json")
    vim.fn.writefile({ "POSTE_TEST_DB_PASS=from-dotenv" }, tmpdir .. "/.env")

    vim.env.POSTE_TEST_DB_PASS = "from-os"
    assert.equals("from-os", connections.get_env_vars(tmpdir).POSTE_TEST_DB_PASS)

    vim.env.POSTE_TEST_DB_PASS = nil
    assert.equals("from-dotenv", connections.get_env_vars(tmpdir).POSTE_TEST_DB_PASS)

    vim.fn.delete(tmpdir .. "/.env")
    -- _dotenv_cache still holds the parsed .env; bypass it with a fresh dir
    local other_dir = tmpdir .. "/nested"
    vim.fn.mkdir(other_dir, "p")
    util_stub.find_file_upwards = function(filename)
      if filename == ".env" then return nil end
      if filename == "env.json" then return tmpdir .. "/env.json" end
      return tmpdir .. "/connections.toml"
    end
    assert.equals("from-envjson", connections.get_env_vars(other_dir).POSTE_TEST_DB_PASS)
  end)

  it("keeps structural env.json entries out of the substitution table", function()
    vim.fn.writefile({
      '{"dev": {"POSTE_TEST_HOST": "h1", "POSTE_TEST_LABELS": {"team": "db"},'
        .. ' "POSTE_TEST_NOTHING": null}}',
    }, tmpdir .. "/env.json")
    local vars = connections.get_env_vars(tmpdir)
    assert.is_nil(vars.POSTE_TEST_LABELS)
    assert.is_nil(vars.POSTE_TEST_NOTHING)
    -- A table reaching gsub's replacement raises
    -- "invalid replacement value (a table)", which used to abort the whole
    -- connection resolution; the reference now stays literal, as the CLI
    -- leaves it when the name is no variable at all.
    assert.equals("h1/{{POSTE_TEST_LABELS}}",
      connections.substitute_vars("{{POSTE_TEST_HOST}}/{{POSTE_TEST_LABELS}}", vars))
  end)

  it("keeps env.json numbers and booleans as usable values", function()
    vim.fn.writefile({
      '{"dev": {"POSTE_TEST_PORT": 5432, "POSTE_TEST_DEBUG": true}}',
    }, tmpdir .. "/env.json")
    local vars = connections.get_env_vars(tmpdir)
    assert.equals("5432", vars.POSTE_TEST_PORT)
    assert.equals("true", vars.POSTE_TEST_DEBUG)
  end)

  it("reads a flat env.json as vars for every environment", function()
    vim.fn.writefile({ '{"POSTE_TEST_FLAT": "flat-value"}' }, tmpdir .. "/env.json")
    assert.equals("flat-value", connections.get_env_vars(tmpdir).POSTE_TEST_FLAT)
  end)

  it("expands a reference whose name is not an identifier", function()
    -- An env.json key may be any string; the CLI's pattern accepts everything
    -- up to the closing braces, so a narrower one here means the editor
    -- hands the driver literal braces on a file the CLI resolves.
    vim.fn.writefile({ '{"dev": {"POSTE_TEST-HYPHENATED": "h1"}}' }, tmpdir .. "/env.json")
    local vars = connections.get_env_vars(tmpdir)
    assert.equals("h1", connections.substitute_vars("{{POSTE_TEST-HYPHENATED}}", vars))
    -- prose that only looks like a reference is still untouched
    assert.equals("{{ not a var }}", connections.substitute_vars("{{ not a var }}", vars))
  end)
end)

describe("connections apply_connection", function()
  local function make_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  before_each(function()
    state_stub.context = { connection = nil, database = nil }
  end)

  it("updates state.context.connection", function()
    connections.apply_connection({ name = "analytics" })
    assert.equals("analytics", state_stub.context.connection)
  end)

  it("updates existing @connection directive", function()
    local buf = make_buf({ "-- @connection old", "select 1" })
    connections.apply_connection({ name = "newconn" })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.equals("-- @connection newconn", lines[1])
  end)

  it("inserts @connection directive at end when none exists and no ### marker", function()
    local buf = make_buf({ "select 1" })
    connections.apply_connection({ name = "newconn" })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.equals("select 1", lines[1])
    assert.equals("-- @connection newconn", lines[2])
  end)

  it("inserts @connection before first ### marker", function()
    local buf = make_buf({ "### query", "select 1" })
    connections.apply_connection({ name = "newconn" })
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.equals("-- @connection newconn", lines[1])
    assert.equals("", lines[2])
    assert.equals("### query", lines[3])
  end)
end)

describe("connections format_connection", function()
  it("renders the host/port/database line for host connections", function()
    local line = connections._test.format_connection({
      name = "pg-dev", dialect = "postgres", host = "db.internal", port = 5432, database = "app",
    })
    assert.equals("🐘 pg-dev — db.internal:5432/app", line)
  end)

  it("coerces a quoted (string) port instead of throwing on %d", function()
    -- a connections.toml `port = "5433"` used to error inside string.format,
    -- killing the whole connection picker
    local line = connections._test.format_connection({
      name = "pg-q", dialect = "postgres", host = "h", port = "5433", database = "app",
    })
    assert.equals("🐘 pg-q — h:5433/app", line)
  end)

  it("renders sqlite paths and the tunnel mark", function()
    local line = connections._test.format_connection({
      name = "lite", dialect = "sqlite", path = "data.db", tunnel = "jump@bastion",
    })
    assert.equals("📦 lite — data.db 🔒", line)
  end)

  it("marks the connection the buffer context points at", function()
    -- the picker must answer "which one am I on?" before the user re-picks
    local line = connections._test.format_connection({
      name = "pg-dev", dialect = "postgres", host = "h", database = "app",
    }, "pg-dev")
    assert.equals("🐘 pg-dev — h:5432/app  [active]", line)
    -- another connection (or no context) renders unchanged
    local other = connections._test.format_connection({
      name = "pg-dev", dialect = "postgres", host = "h", database = "app",
    }, "pg-prod")
    assert.equals("🐘 pg-dev — h:5432/app", other)
    local none = connections._test.format_connection({
      name = "pg-dev", dialect = "postgres", host = "h", database = "app",
    }, nil)
    assert.equals("🐘 pg-dev — h:5432/app", none)
  end)
end)

describe("connections percent_encode", function()
  it("encodes reserved bytes but keeps unreserved characters", function()
    local enc = connections._test.percent_encode
    assert.equals("p%40ss%3Aw%2Frd", enc("p@ss:w/rd"))
    assert.equals("keep_-~.12", enc("keep_-~.12"))
    assert.equals("caf%C3%A9", enc("café"))
  end)
end)

describe("connections name_for_url", function()
  local tmpdir
  local saved_cwd
  local saved_tunnel

  before_each(function()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    saved_cwd = vim.fn.getcwd()
    vim.fn.chdir(tmpdir)
    util_stub.find_file_upwards = function() return tmpdir .. "/connections.toml" end
    package.loaded["poste-db.toml"].parse_file = function()
      return {
        primary = { dialect = "postgres", host = "db.internal", port = 5432, database = "blog", user = "alice", password = "s3cret" },
        mem = { dialect = "sqlite" },
        q = { dialect = "sqlite", path = "f.db?cache=shared" },
        redis = { dialect = "redis", host = "cache.internal", port = 6379 },
        tun = { dialect = "mysql", host = "db.internal", port = 3306, database = "ops", user = "bob", tunnel = { dest = "jump@bastion" } },
      }
    end
    saved_tunnel = package.loaded["poste-db.tunnel"]
    package.loaded["poste-db.tunnel"] = { status_list = function() return {} end }
  end)

  after_each(function()
    vim.fn.chdir(saved_cwd)
    pcall(vim.fn.delete, tmpdir, "rf")
    package.loaded["poste-db.tunnel"] = saved_tunnel
  end)

  it("round-trips resolve_connection_url back to the name", function()
    local url = connections.resolve_connection_url("primary")
    assert.equals("postgres://alice:s3cret@db.internal:5432/blog", url)
    assert.equals("primary", connections.name_for_url(url))
  end)

  it("matches sqlite entries", function()
    assert.equals("mem", connections.name_for_url("sqlite::memory:"))
    -- query-string paths round-trip through the same builder (&mode=rwc)
    assert.equals("q", connections.name_for_url("sqlite:f.db?cache=shared&mode=rwc"))
  end)

  it("never matches non-SQL dialect entries (shared connections.toml)", function()
    assert.is_nil(connections.name_for_url("redis://cache.internal:6379"))
  end)

  it("returns nil for an unknown url", function()
    assert.is_nil(connections.name_for_url("postgres://nobody@nowhere:5432/x"))
  end)

  it("matches a tunneled entry through its active local port", function()
    package.loaded["poste-db.tunnel"] = {
      status_list = function() return { { name = "tun", port = 15432 } } end,
      ensure = function() return 15432 end,
    }
    -- forward resolution yields the same local-end URL the binary saw
    local url = connections.resolve_connection_url("tun")
    assert.equals("mysql://bob@127.0.0.1:15432/ops", url)
    assert.equals("tun", connections.name_for_url(url))
  end)

  it("skips tunneled entries when the tunnel is not running", function()
    assert.is_nil(connections.name_for_url("mysql://bob@127.0.0.1:15432/ops"))
    -- the non-tunneled entries still resolve
    assert.equals("primary", connections.name_for_url(connections.resolve_connection_url("primary")))
  end)

  it("returns nil without a connections.toml", function()
    util_stub.find_file_upwards = function() return nil end
    assert.is_nil(connections.name_for_url("postgres://x@y:1/z"))
  end)
end)
