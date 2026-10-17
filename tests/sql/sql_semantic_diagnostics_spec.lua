-- Tests for lua/poste-db/semantic_diagnostics.lua
-- Focus: schema cache invalidation after DDL so newly created tables are no
-- longer reported as "not found". context/connections/state/constants are
-- stubbed so the module loads deterministically without a database.

-- `fake_binary` and `fake_ctx` are read through closures so a test can swap
-- the binary the fetch helpers launch, and the context every statement
-- resolves to, without reloading the module under test.
local fake_binary
local fake_ctx = {}
package.loaded["poste-db.context"] = { resolve_full_context = function() return fake_ctx end }
package.loaded["poste-db.connections"] = {
  resolve_connection_url = function() return "postgres://user@localhost:5432/spec" end,
  get_connection_config = function() return nil end,
}
package.loaded["poste-db.state"] = {
  find_poste_binary = function() return fake_binary end,
  log = function() end,
}
package.loaded["poste-db.constants"] = {
  SYSTEM_SCHEMAS = {},
  is_pg_catalog_name = function() return false end,
  is_sqlite_system_name = function() return false end,
  dialect_from_url = function() return nil end,
}

local sem = require("poste-db.semantic_diagnostics")

local function has(keys, key)
  for _, k in ipairs(keys) do
    if k == key then return true end
  end
  return false
end

-- The cold-cache scenarios below drive `M.update`, which needs the tree-sitter
-- SQL grammar to find any statement at all. `tests/run_one.sh` redirects the
-- XDG dirs, so the grammar is missing there; the same guard the other
-- tree-sitter specs use turns those runs into visible `pending` instead of
-- silently green tests that never fetched.
local has_sql_parser = require("poste-db.ts_stmt").check_parser()

--- Scratch buffer holding one SQL snippet, in a filetype `M.update` accepts.
local function sql_buf(sql)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(sql, "\n"))
  vim.api.nvim_set_option_value("filetype", "sql", { buf = buf })
  return buf
end

--- Messages `M.update` put on that buffer, sorted so `assert.same` is stable.
local function msgs(sql)
  local out = {}
  local buf = sql_buf(sql)
  sem.update(buf)
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.source == "poste-db" then out[#out + 1] = d.message end
  end
  table.sort(out)
  vim.api.nvim_buf_delete(buf, { force = true })
  return out
end

describe("semantic_diagnostics invalidate", function()
  before_each(function()
    sem._test.set_cache("connA/blog", { tables = { "old" } })
    sem._test.set_cache("connA/inventory", { tables = { "stock" } })
    sem._test.set_cache("connB/blog", { tables = { "users" } })
  end)

  after_each(function()
    sem.invalidate(nil)
  end)

  it("drops only the cache entry for the given connection/database", function()
    sem.invalidate("connA", "blog")
    local keys = sem._test.cache_keys()
    assert.is_false(has(keys, "connA/blog"))
    assert.is_true(has(keys, "connA/inventory"))
    assert.is_true(has(keys, "connB/blog"))
  end)

  it("drops every database of the connection when db is nil", function()
    sem.invalidate("connA", nil)
    local keys = sem._test.cache_keys()
    assert.is_false(has(keys, "connA/blog"))
    assert.is_false(has(keys, "connA/inventory"))
    assert.is_true(has(keys, "connB/blog"))
  end)

  it("clears the whole cache when connection is nil", function()
    sem.invalidate(nil, nil)
    assert.same({}, sem._test.cache_keys())
  end)
end)

-- The cold-cache fetch is the only thing that can turn a "no squiggles" buffer
-- into a checked one, and it is gated by a per-buffer in-flight flag. Two
-- measured Neovim behaviours used to leave that flag set forever:
--   * `jobstart()` *throws* E475 ("... is not executable") for a path that is
--     missing or not runnable -- it does not return 0, and no callback fires;
--   * a job that exits 0 without writing to stdout still fires `on_stdout`,
--     but with the single empty line the guards used to `return` on.
-- A stuck flag is silent and permanent: every later update() skips the fetch,
-- so the buffer stays unchecked for the rest of the session even after the
-- binary is restored. Each case below starts broken on purpose and then
-- asserts that a working binary is actually reached. The last two are
-- controls: they settled correctly even before the fix, and they pin the
-- rule that a failed fetch re-arms the next attempt rather than muting it.
describe("semantic_diagnostics fetch failure recovery", function()
  if not has_sql_parser then
    it("is skipped when the parser is unavailable", function()
      pending("Tree-sitter SQL parser unavailable in this Neovim environment")
    end)
    return
  end

  local created = {}

  local function sh(body)
    local path = vim.fn.tempname()
    vim.fn.writefile({ "#!/bin/sh", body }, path)
    local uv = vim.uv or vim.loop
    uv.fs_chmod(path, 493) -- 0o755, the same requirement minimal_init notes
    created[#created + 1] = path
    return path
  end

  local function cached(key)
    return vim.wait(3000, function() return has(sem._test.cache_keys(), key) end)
  end

  -- Each case gets its own connection key (declared before the before_each
  -- that bumps it): an introspect job from a previous case can land late on
  -- a loaded machine, and a shared "connA/blog" key would let that late
  -- good fetch satisfy this case's assert.is_false(cached(...)). A unique
  -- key per case makes a late fetch write a key nobody reads.
  local case_seq = 0

  before_each(function()
    case_seq = case_seq + 1
    sem.invalidate(nil)
    fake_ctx = { connection = "conn" .. case_seq, database = "blog" }
  end)

  -- Every script is made inside an `it` body, so the list only ever holds
  -- files the current test still needs.
  after_each(function()
    sem.invalidate(nil)
    fake_binary = nil
    fake_ctx = {}
    for _, path in ipairs(created) do os.remove(path) end
    created = {}
  end)

  -- One buffer per scenario: the flag under test is keyed by buffer, so a
  -- fresh buffer would hide a leak instead of showing it.
  local cases = {
    {
      name = "the binary path is rejected by jobstart",
      broken = function() return "/nonexistent/poste-spec-binary" end,
    },
    {
      name = "the binary exits 0 without any stdout",
      broken = function() return sh("true") end,
    },
    {
      name = "the binary prints something that is not JSON",
      broken = function() return sh("echo 'not json at all'") end,
    },
    {
      name = "the binary exits non-zero without stdout",
      broken = function() return sh("exit 7") end,
    },
  }

  for _, case in ipairs(cases) do
    it("reaches a working binary again when " .. case.name, function()
      fake_binary = case.broken()
      local buf = sql_buf("SELECT id FROM widget;")
      sem.update(buf)
      assert.is_false(cached(fake_ctx.connection .. "/blog"))

      fake_binary = sh("echo '{\"items\":[{\"name\":\"widget\"}]}'")
      sem.update(buf)
      assert.is_true(cached(fake_ctx.connection .. "/blog"))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end
end)

-- `otherdb.users` and `blog.users` are different tables, so a reference
-- qualified with a database name has to be checked against the schema of the
-- database it names. `M.update` used to keep validating with the *statement's*
-- schema whenever the qualified database was not (yet) cached, which produced
-- a confident wrong answer in both directions: a real column reported as
-- missing, and a typo accepted because it happened to exist locally.
describe("semantic_diagnostics cross-database references", function()
  if not has_sql_parser then
    it("is skipped when the parser is unavailable", function()
      pending("Tree-sitter SQL parser unavailable in this Neovim environment")
    end)
    return
  end

  before_each(function()
    fake_ctx = { connection = "connA", database = "blog" }
    sem.invalidate(nil)
    sem._test.set_cache("connA/blog", {
      tables = { "users", "orders" },
      columns = { users = { "id", "name" }, orders = { "id" } },
    })
    sem._test.set_cache("connA/otherdb", {
      tables = { "users" },
      columns = { users = { "id", "full_name" } },
    })
  end)

  after_each(function()
    sem.invalidate(nil)
    fake_ctx = {}
  end)

  it("accepts a column that exists in the referenced database", function()
    assert.same({}, msgs("SELECT full_name FROM otherdb.users;"))
  end)

  it("reports a column that only exists in the current database", function()
    assert.same({ "Column 'name' not found in table 'users'" },
      msgs("SELECT name FROM otherdb.users;"))
  end)

  it("still reports a table that is missing from the referenced database", function()
    assert.same({ "Table 'orders' not found in database 'otherdb'" },
      msgs("SELECT id FROM otherdb.orders;"))
  end)

  -- An uncached database is not evidence of a typo, so nothing is claimed.
  -- This is a deliberate miss: a prefix may also be a postgres *schema*, which
  -- `--database` cannot introspect at all.
  it("stays silent for a database whose schema was never fetched", function()
    assert.same({}, msgs("SELECT id FROM newdb.accounts;"))
  end)
end)

-- Unquoted identifiers fold to lowercase in postgres and are case-insensitive
-- in MySQL and SQLite, so `USERS` and `users` are the same table. The table
-- *list* was already compared case-insensitively; the per-table column maps
-- were keyed by the name as it happened to be typed, which left both the
-- lookup and the cached entry unable to find the other spelling. The dangerous
-- direction is the fetch: `introspect --table USERS` legitimately returns no
-- rows on postgres, that empty list got cached under "USERS", and every column
-- of the real table was then reported missing until the next invalidation.
describe("semantic_diagnostics table-name case", function()
  if not has_sql_parser then
    it("is skipped when the parser is unavailable", function()
      pending("Tree-sitter SQL parser unavailable in this Neovim environment")
    end)
    return
  end

  before_each(function()
    fake_ctx = { connection = "connA", database = "blog" }
    sem.invalidate(nil)
  end)

  after_each(function()
    sem.invalidate(nil)
    fake_ctx = {}
  end)

  it("finds columns cached under the lowercase name when the SQL shouts", function()
    sem._test.set_cache("connA/blog", {
      tables = { "users" },
      columns = { users = { "id", "name" } },
    })
    assert.same({}, msgs("SELECT USERS.name FROM USERS;"))
    assert.same({ "Column 'zzz' not found in table 'USERS'" },
      msgs("SELECT USERS.zzz FROM USERS;"))
  end)

  it("finds columns cached under a shouted name when the SQL is quiet", function()
    sem._test.set_cache("connA/blog", {
      tables = { "users" },
      columns = { USERS = { "id", "name" } },
    })
    assert.same({}, msgs("SELECT users.name FROM users;"))
    assert.same({ "Column 'zzz' not found in table 'users'" },
      msgs("SELECT users.zzz FROM users;"))
  end)

  -- Both spellings resolve to one list, so the ambiguous merge keeps working
  -- whichever way the file is written.
  it("merges cached column lists that differ only by case", function()
    sem._test.set_cache("connA/blog", {
      tables = { "users" },
      columns = { users = { "id" }, USERS = { "name" } },
    })
    assert.same({}, msgs("SELECT users.id, USERS.name FROM users;"))
  end)

  -- An empty list is what `introspect --type columns` answers for a name the
  -- server does not have, not proof that a real table has no columns. Reading
  -- it as the latter flagged every reference in the statement.
  it("treats a cached empty column list as unknown rather than as no columns", function()
    sem._test.set_cache("connA/blog", {
      tables = { "users" },
      columns = { users = {} },
    })
    assert.same({}, msgs("SELECT zzz, name FROM users;"))
  end)
end)

-- `database.schema.table` is legal in postgres and ClickHouse, and the grammar
-- hands it over as one `object_reference` of five children. Only the shapes
-- with one and three children were destructured, so `blog.public.users` became
-- a table literally named "blog.public.users" and was reported missing from
-- whichever database the statement happened to run against.
--
-- The reading chosen here: the leftmost component is the database (true for
-- postgres, MySQL and ClickHouse alike), the components it skips are schemas,
-- and a schema has no representation in the per-database cache -- so the name
-- is checked against its database with the schema left unchecked. `public`
-- below deliberately holds a *different* users list from `blog`; mistaking the
-- qualifier for the database, or the middle component for the table, would
-- disagree with every case here.
describe("semantic_diagnostics three-part references", function()
  if not has_sql_parser then
    it("is skipped when the parser is unavailable", function()
      pending("Tree-sitter SQL parser unavailable in this Neovim environment")
    end)
    return
  end

  before_each(function()
    fake_ctx = { connection = "connA", database = "blog" }
    sem.invalidate(nil)
    sem._test.set_cache("connA/blog", {
      tables = { "users" },
      columns = { users = { "id", "name" } },
    })
    sem._test.set_cache("connA/public", {
      tables = { "users" },
      columns = { users = { "id", "full_name" } },
    })
  end)

  after_each(function()
    sem.invalidate(nil)
    fake_ctx = {}
  end)

  it("checks the trailing name against the leading database, not the schema", function()
    -- `name` is in blog.users and not in public.users.
    assert.same({}, msgs("SELECT name FROM blog.public.users;"))
    assert.same({ "Column 'full_name' not found in table 'users'" },
      msgs("SELECT full_name FROM blog.public.users;"))
  end)

  it("reports a missing table by its own name, not the whole dotted string", function()
    assert.same({ "Table 'ghost' not found in database 'blog'" },
      msgs("SELECT 1 FROM blog.public.ghost;"))
  end)

  it("applies the same reading to INSERT", function()
    assert.same({}, msgs("INSERT INTO blog.public.users (name) VALUES (1);"))
    assert.same({ "Column 'bogus' not found in table 'users'" },
      msgs("INSERT INTO blog.public.users (bogus) VALUES (1);"))
  end)

  it("says nothing about a database it has not cached", function()
    -- Not fetching on demand is the existing rule for qualified references;
    -- what matters is that `newdb.users` is never checked against blog.
    assert.same({}, msgs("SELECT 1 FROM newdb.users;"))
    assert.same({}, msgs("SELECT full_name FROM newdb.users;"))
    assert.same({}, msgs("SELECT 1 FROM newdb.public.users;"))
  end)

  it("checks a fully qualified column against its table, not its dotted prefix", function()
    -- `blog.users.col` used to be looked up as a table named "blog.users",
    -- which matched nothing, so every typo in it was accepted.
    assert.same({ "Column 'bogus' not found in table 'users'" },
      msgs("SELECT blog.users.bogus FROM users;"))
    assert.same({}, msgs("SELECT blog.users.name FROM users;"))
  end)
end)
