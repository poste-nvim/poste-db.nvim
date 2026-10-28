local toml = require("poste-db.toml")

describe("toml.parse", function()
  it("parses a simple key=value", function()
    local res, err = toml.parse('key = "value"')
    assert.is_nil(err)
    assert.equals("value", res.key)
  end)

  it("parses [section] with key=value", function()
    local res = toml.parse('[section]\nkey = "value"')
    assert.equals("value", res.section.key)
  end)

  it("parses numeric values", function()
    local res = toml.parse('port = 5432')
    assert.equals(5432, res.port)
  end)

  it("parses boolean values", function()
    local res = toml.parse('enabled = true')
    assert.is_true(res.enabled)
  end)

  it("strips inline comments from string values", function()
    local res = toml.parse('password = "abc123" # this is a comment')
    assert.equals("abc123", res.password)
  end)

  it("handles inline comments with # inside strings", function()
    local res = toml.parse('name = "str#value" # comment')
    assert.equals("str#value", res.name)
  end)

  it("parses single-quoted strings", function()
    local res = toml.parse("name = 'raw string'")
    assert.equals("raw string", res.name)
  end)

  it("handles escape sequences in double-quoted strings", function()
    local res = toml.parse('text = "line1\\nline2"')
    assert.equals("line1\nline2", res.text)
  end)

  it("does not re-process backslashes produced by an earlier unescape step", function()
    -- sequential gsubs turned the literal backslash + 'n' of \tables into a
    -- newline (the \\n → \n double-substitution), mangling Windows paths
    local res = toml.parse('path = "D:\\\\tables\\\\notes"')
    assert.equals("D:\\tables\\notes", res.path)
    local wal = toml.parse('mode = "\\\\new"') -- \\n must stay backslash + n
    assert.equals("\\new", wal.mode)
  end)

  it("rejects unknown escape sequences instead of storing them verbatim", function()
    -- TOML makes an unknown escape an error. The old reading stored `a\qb`
    -- verbatim, and `\uXXXX` — the TOML spelling for non-ASCII — was stored
    -- raw too, so a password written that way silently differed from the
    -- real one. The behavior change is deliberate: fail closed.
    local res, err = toml.parse('v = "a\\qb"')
    assert.is_nil(res)
    assert.truthy(err)
  end)

  it("decodes \\uXXXX and \\UXXXXXXXX escapes", function()
    local res = toml.parse('v = "\\u0041\\U0001F600"')
    assert.equals("A" .. vim.fn.nr2char(0x1F600), res.v)
  end)

  it("rejects a malformed \\u escape", function()
    local res, err = toml.parse('v = "\\u00"')
    assert.is_nil(res)
    assert.truthy(err)
  end)

  it("rejects garbage after a string's real closing quote", function()
    -- `"a" "b"` passed the last-byte check and stored `a" "b`; `"a\"` ended
    -- on its escaped quote and stored `a\`.
    local res1, err1 = toml.parse('v = "a" "b"')
    assert.is_nil(res1)
    assert.truthy(err1)
    local res2, err2 = toml.parse('v = "a\\"')
    assert.is_nil(res2)
    assert.truthy(err2)
    local res3, err3 = toml.parse("v = 'a' 'b'")
    assert.is_nil(res3)
    assert.truthy(err3)
  end)

  it("rejects a bare value carrying whitespace", function()
    -- `k = 1 2` used to store the string "1 2".
    local res, err = toml.parse("k = 1 2")
    assert.is_nil(res)
    assert.truthy(err)
  end)

  it("treats a backslash in a literal string as a plain character", function()
    -- literal strings ('…') have no escapes: 'a\' ends at that quote, so a
    -- trailing comment after it must still be stripped (the escape-skip used
    -- to swallow the closing quote and fail the parse)
    local res, err = toml.parse("password = 'a\\' # comment")
    assert.is_nil(err)
    assert.equals("a\\", res.password)
  end)

  it("parses content saved with a UTF-8 BOM", function()
    local res = toml.parse("\xEF\xBB\xBF[section]\nkey = \"value\"")
    assert.equals("value", res.section.key)
  end)

  it("skips comment lines", function()
    local res = toml.parse('# this is a comment\nkey = "value"')
    assert.equals("value", res.key)
  end)

  it("skips blank lines", function()
    local res = toml.parse('\n\nkey = "value"\n\n')
    assert.equals("value", res.key)
  end)

  it("errors on unclosed double-quoted string", function()
    local res, err = toml.parse('key = "unclosed')
    assert.is_nil(res)
    assert.matches("Unclosed", err or "")
  end)

  it("parses multiple sections", function()
    local content = '[pg]\nhost = "localhost"\n\n[mysql]\nhost = "127.0.0.1"\n'
    local res = toml.parse(content)
    assert.equals("localhost", res.pg.host)
    assert.equals("127.0.0.1", res.mysql.host)
  end)

  it("handles inline comment with # that looks like a value", function()
    local res = toml.parse('password = "abc#123" # comment')
    assert.equals("abc#123", res.password)
  end)

  it("handles real-world connections.toml snippet", function()
    local content = [[
[pg-dev]
dialect = "postgres"
host = "localhost"
port = 5432
database = "blog"
user = "{{DB_USER}}"
password = "{{DB_PASS}}"

[mysql-dev]
dialect = "mysql"
host = "127.0.0.1"
port = 3306
database = "inventory"
]]
    local res = toml.parse(content)
    assert.equals("postgres", res["pg-dev"].dialect)
    assert.equals("localhost", res["pg-dev"].host)
    assert.equals(5432, res["pg-dev"].port)
    assert.equals("mysql", res["mysql-dev"].dialect)
    assert.equals("inventory", res["mysql-dev"].database)
  end)

  -- Round 39 recorded the shape: a quoted key carrying a dot is legal TOML
  -- (ONE name), but the dotted-key check looked at the raw key text and
  -- rejected it. The fix belongs here (the vendor source) before the
  -- poste-redis copy re-syncs.
  it("accepts a fully-quoted key that contains a dot", function()
    local res, err = toml.parse('"my.key" = "v"')
    assert.is_nil(err)
    assert.equals("v", res["my.key"])
  end)

  it("accepts a single-quoted key that contains a dot", function()
    local res, err = toml.parse("'my.key' = 'v'")
    assert.is_nil(err)
    assert.equals("v", res["my.key"])
  end)

  it("unquotes escape sequences in a double-quoted key", function()
    local res, err = toml.parse('"a\\"b" = 1')
    assert.is_nil(err)
    assert.equals(1, res['a"b'])
  end)

  it("accepts a quoted key that contains an equals sign", function()
    -- `"a=b" = 1` is legal TOML; the plain find cut the line at the
    -- quote-inner `=` and stored the mangled halves (`"a` = `b" = 1`)
    -- with no error anywhere.
    local res, err = toml.parse('["t"]\n"a=b" = 1')
    assert.is_nil(err)
    assert.equals(1, res.t["a=b"])
    local res2, err2 = toml.parse("'a=b' = 2")
    assert.is_nil(err2)
    assert.equals(2, res2["a=b"])
  end)

  it("accepts an inline-table key that contains an equals sign", function()
    -- the pair split had the same plain-find cut, and the swallowed
    -- key-parse error stored the entry under tostring(nil)
    local res, err = toml.parse('env = { "A=B" = "x" }')
    assert.is_nil(err)
    assert.equals("x", res.env["A=B"])
  end)

  it("fails closed on an unterminated quote in a key=value line", function()
    -- the top-level scan never finds an `=` outside the open quote, so the
    -- line is a plain invalid line instead of a mangled store
    local _, err = toml.parse('password "x = 1')
    assert.matches("Invalid key=value line", err)
  end)

  it("rejects an inline-table entry whose key fails to parse", function()
    -- `{"uncl = 1}`: the unterminated quote means no top-level `=` — the
    -- entry must not land under tostring(nil) either way
    local _, err = toml.parse('v = { "uncl = 1 }')
    assert.matches("Invalid inline table entry", err)
  end)

  it("still rejects unquoted dotted keys", function()
    local _, err = toml.parse("a.b = 1")
    assert.matches("Dotted keys", err)
  end)

  it("still rejects a quoted dotted key like \"a\".\"b\" (that IS a dotted key)", function()
    local _, err = toml.parse('"a"."b" = 1')
    assert.matches("Dotted keys", err)
  end)

  it("reads a quoted header name as one section", function()
    -- The old first-`]` scan stored `["my conn"]` as a section literally
    -- named `"my conn"` (quotes included), and `["a]b"]` was cut at the `]`
    -- inside the quotes.
    local res, err = toml.parse('["my conn"]\nport = 5432')
    assert.is_nil(err)
    assert.equals(5432, res["my conn"].port)
    local res2, err2 = toml.parse('["a]b"]\nport = 1')
    assert.is_nil(err2)
    assert.equals(1, res2["a]b"].port)
  end)

  it("rejects a quoted header with trailing text before the bracket", function()
    local _, err = toml.parse('["a" x]')
    assert.matches("Invalid table header", err)
  end)

  it("rejects an unterminated quoted header", function()
    local _, err = toml.parse('["a]')
    assert.matches("Invalid table header", err)
  end)

  it("unquotes a quoted header that sits behind whitespace inside the brackets", function()
    -- `[ 'local' ]` is legal TOML: the fast quote check only inspects the
    -- character right after `[`, so the unquoted path used to store the name
    -- WITH its quote characters and the connection never resolved
    -- (synced with poste-redis toml.lua)
    local res, err = toml.parse("[ 'local' ]\nport = 1")
    assert.is_nil(err)
    assert.equals(1, res["local"].port)
    assert.is_nil(res["'local'"])
    local res2, err2 = toml.parse('[ "my conn" ]\nport = 2')
    assert.is_nil(err2)
    assert.equals(2, res2["my conn"].port)
  end)

  it("keeps a bare name whose ends merely look like quotes", function()
    local res, err = toml.parse('[a"]\nport = 1')
    assert.is_nil(err)
    assert.equals(1, res['a"'].port)
  end)

  it("reads TOML numeric underscores as numbers", function()
    -- `port = 64_000` is a legal integer; plain tonumber rejected the `_`
    -- and the value silently degraded to a STRING
    local res, err = toml.parse('k1 = 1_000\nk2 = -1_0\nk3 = 0x1_f\nk4 = 1.5_5')
    assert.is_nil(err)
    assert.equals(1000, res.k1)
    assert.equals(-10, res.k2)
    assert.equals(31, res.k3)
    assert.equals(1.55, res.k4)
  end)

  it("keeps bare words that merely contain an underscore as strings", function()
    local res = toml.parse('k1 = _10\nk2 = foo_bar')
    assert.equals("_10", res.k1)
    assert.equals("foo_bar", res.k2)
  end)

  it("rejects a second header on an unquoted header line", function()
    -- `[a] [b]` used to register `a` and silently swallow `[b]`, so every
    -- key after it landed in the wrong connection
    local _, err = toml.parse('[a] [b]\nx = 1')
    assert.matches("Invalid table header", err)
  end)

  it("still accepts a comment after an unquoted header", function()
    local res, err = toml.parse('[pg] # the dev one\nhost = "h"')
    assert.is_nil(err)
    assert.equals("h", res.pg.host)
  end)

  it("accepts a comment after a quoted header", function()
    -- the quoted path's tail check ended two chars short of EOL, so the
    -- closing `]` landed in the tail and every trailing comment on a
    -- quoted header died as "Invalid table header" — while the unquoted
    -- path right beside it accepted one
    local res, err = toml.parse('["pg-dev"] # the dev one\nhost = "h"')
    assert.is_nil(err)
    assert.equals("h", res["pg-dev"].host)
    local res2, err2 = toml.parse("['pg2']#tight comment\nx = 1")
    assert.is_nil(err2)
    assert.equals(1, res2.pg2.x)
  end)

  it("still rejects trailing text after a quoted header", function()
    local _, err = toml.parse('["a"] ["b"]')
    assert.matches("Invalid table header", err)
  end)

  it("rejects triple-quoted strings instead of unquoting them into garbage", function()
    -- the single-line path used to strip the outer quotes of `"""x"""`
    -- into the value `""x""` — a silent corruption of whatever secret or
    -- host was written that way
    local res, err = toml.parse('a = """x"""')
    assert.is_nil(res)
    assert.matches("Multi%-line strings are not supported", err)
    local res2, err2 = toml.parse("a = '''x'''")
    assert.is_nil(res2)
    assert.matches("Multi%-line strings are not supported", err2)
  end)
end)

describe("toml inline containers", function()
  it("parses an inline table into a real table", function()
    local res = toml.parse('[c]\ntunnel = { to = "jump@bastion", port = 2222, key = "~/.ssh/id" }')
    local tunnel = res.c.tunnel
    assert.is_table(tunnel)
    assert.equals("jump@bastion", tunnel.to)
    assert.equals(2222, tunnel.port)
    assert.equals("~/.ssh/id", tunnel.key)
  end)

  it("parses inline arrays and keeps commas inside strings", function()
    local res = toml.parse('[c]\nlist = ["a,b", "c"]\nempty = []\nnums = [1, 2, 3]')
    assert.same({ "a,b", "c" }, res.c.list)
    assert.same({}, res.c.empty)
    assert.same({ 1, 2, 3 }, res.c.nums)
  end)

  it("nests inline tables and arrays", function()
    local res = toml.parse('[c]\nx = { a = { b = 1 }, list = [ true ] }')
    assert.equals(1, res.c.x.a.b)
    assert.same({ true }, res.c.x.list)
  end)

  it("reports an unclosed inline container instead of stringifying it", function()
    local parsed, err = toml.parse('a = { to = "x"')
    assert.is_nil(parsed)
    assert.equals("Unclosed inline table", err)
    local p2, e2 = toml.parse('a = [1, 2')
    assert.is_nil(p2)
    assert.equals("Unclosed inline array", e2)
  end)

  it("feeds the documented tunnel shape to tunnel.normalize_cfg", function()
    local tunnel_mod = require("poste-db.tunnel")
    local res = toml.parse('[c]\ntunnel = { to = "jump@bastion", port = 2222 }')
    local cfg, err = tunnel_mod.normalize_cfg(res.c.tunnel)
    assert.is_nil(err)
    assert.equals("jump@bastion", cfg.dest)
    assert.equals(2222, cfg.port)
  end)

  it("rejects [[array-of-tables]] instead of making a \"[name\" section", function()
    local res, err = toml.parse('[[srv]]\nurl = "mysql://h/db"')
    assert.is_nil(res)
    assert.equals("Array-of-tables headers ([[name]]) are not supported", err)
  end)

  it("rejects dotted keys instead of storing a flat \"a.b\"", function()
    -- `tunnel.to = "h"` read as key "tunnel.to" never reached
    -- tunnel.normalize_cfg, so the connection looked fine and failed at use
    local res, err = toml.parse('[srv]\ntunnel.to = "h"')
    assert.is_nil(res)
    assert.equals("Dotted keys (a.b = …) are not supported: tunnel.to", err)
  end)

  it("keeps dotted section names: the header is the connection name", function()
    local res, err = toml.parse('[my-app.prod]\ndialect = "redis"')
    assert.is_nil(err)
    assert.equals("redis", res["my-app.prod"].dialect)
  end)

  it("does not echo the offending text for a malformed value line", function()
    -- the line may be a mistyped `password "s3cret"`; the old message
    -- printed it verbatim into :PosteDbHealth / the notify popup
    local res, err = toml.parse('password "s3cret-value"')
    assert.is_nil(res)
    assert.falsy(err:find("s3cret%-value", 1, false))
  end)

  -- Fail-closed on malformed inline containers: each of these used to be
  -- silently dropped (a nil value stores nothing), so the consumer failed in
  -- a place far from the typo — the same reasoning as the triple-quote and
  -- double-header errors above.
  it("rejects a missing value after '=' instead of storing nothing", function()
    local res, err = toml.parse('password =')
    assert.is_nil(res)
    assert.matches("Missing value", err)
    local res2, err2 = toml.parse('password = # oops')
    assert.is_nil(res2)
    assert.matches("Missing value", err2)
  end)

  it("rejects a double comma inside an inline array", function()
    local res, err = toml.parse('ips = ["h1",, "h2"]')
    assert.is_nil(res)
    assert.matches("double comma", err)
  end)

  it("rejects a double comma inside an inline table", function()
    local res, err = toml.parse('t = { a = 1,, b = 2 }')
    assert.is_nil(res)
    assert.matches("double comma", err)
  end)

  it("still accepts a trailing comma in inline containers", function()
    local res, err = toml.parse('[c]\nlist = [1, 2,]\ntbl = { a = 1, }')
    assert.is_nil(err)
    assert.same({ 1, 2 }, res.c.list)
    assert.same({ a = 1 }, res.c.tbl)
  end)

  it("rejects unbalanced brackets in an inline container", function()
    -- `[1]2]` ends in `]` so the unclosed-array check passes; the old split
    -- kept consuming closers and stored the garbage string "1]2" with no
    -- error anywhere — a typo'd config that silently misparsed. (Synced from
    -- poste-redis/toml.lua.)
    local res, err = toml.parse('ips = [1]2]')
    assert.is_nil(res)
    assert.matches("Unbalanced brackets", err)
    local res2, err2 = toml.parse('t = { a = [1 }')
    assert.is_nil(res2)
    assert.matches("Unbalanced brackets", err2)
  end)

  it("rejects an inline table entry with a missing key or value", function()
    local res, err = toml.parse('t = { = 1 }')
    assert.is_nil(res)
    assert.matches("Invalid inline table entry", err)
    local res2, err2 = toml.parse('t = { a = }')
    assert.is_nil(res2)
    assert.matches("Invalid inline table entry", err2)
    -- a comment-only value never reaches the entry check: the comment strip
    -- eats the closing brace first, which still errors (fail closed)
    local res3, err3 = toml.parse('t = { a = # c }')
    assert.is_nil(res3)
    assert.matches("Unclosed inline table", err3)
  end)
end)
