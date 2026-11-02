--- Tests for poste-db/editor/column.lua ensure_primary_key:
--- connection resolution and the refused-lookup vs no-keys cache rule.
---
--- Connection resolution regression: the db-browser ENT path renders a dataset
--- whose layout carries a table_name but no _conn_name, and
--- poste-db.state.context is untouched (the browser runs SQL directly).
--- ensure_primary_key fell back to get_state().sql.context.connection, but
--- poste.state has no `.sql` field, so pressing `i` (edit) on such a dataset
--- crashed with "attempt to index field 'sql' (a nil value)".
---
--- Cache rule regression: a refused metadata query (has_error) used to decode
--- to the same "no rows" body as a table that genuinely has no keys, and the
--- session cache stored it — every later edit on that table skipped the lookup
--- for the rest of the session. A failure must stay uncached.

local column = require("poste-db.editor.column")
local saved = {}

local function stub_state(context)
  local real = package.loaded["poste-db.state"]
  package.loaded["poste-db.state"] = { context = context }
  return function()
    if real then package.loaded["poste-db.state"] = real
    else package.loaded["poste-db.state"] = nil end
  end
end

local function install_stubs()
  saved.exec_run = package.loaded["poste-db.exec_run"]
  saved.connections = package.loaded["poste-db.connections"]
  saved.log = package.loaded["poste-db.log"]
  package.loaded["poste-db.exec_run"] = { run_sql = function() return nil end }
  package.loaded["poste-db.connections"] = {
    resolve_connection_url = function(name) return "postgres://" .. name end,
  }
  package.loaded["poste-db.log"] = { debug = function() end, redact_url = function(u) return u end }
end

--- Install an exec_run stub whose run_sql consults `handler(query)` and records
--- every query. The stub is per-test; install_stubs' nil-returning default is
--- the "no binary / transport dead" shape.
local function stub_exec_run(handler)
  local calls = {}
  package.loaded["poste-db.exec_run"] = {
    run_sql = function(query)
      calls[#calls + 1] = query
      return handler(query)
    end,
    first_error = function() return "permission denied for table users" end,
  }
  return calls
end

--- One ensure_primary_key call sends the PK query *and* the enum query, so the
--- retry assertions count PK queries by their distinguishing table rather than
--- the raw call count.
local function pk_queries(calls)
  local n = 0
  for _, q in ipairs(calls) do
    if q:find("information_schema%.columns", 1, false) then n = n + 1 end
  end
  return n
end

--- A delivered, successful PK body the way exec_run builds it: the legacy
--- envelope (JSON body) plus the flag fields the refused-lookup guard reads.
local function pk_body(is_pk)
  return {
    has_error = false,
    body = vim.json.encode({
      results = { { rows = { { "id", vim.NIL, is_pk } } } },
    }),
  }
end

local function restore_stubs()
  for k, v in pairs(saved) do package.loaded[k] = v end
  column.clear_pk_cache()
end

local function layout_with(extra)
  local l = {
    table_name = "users",
    dialect = "postgres",
    columns = { { name = "id", type = "INT", ctype = "integer" } },
  }
  for k, v in pairs(extra or {}) do l[k] = v end
  return l
end

describe("editor column ensure_primary_key connection resolution", function()
  before_each(function()
    install_stubs()
  end)

  after_each(function()
    restore_stubs()
  end)

  it("no _conn_name and no context connection skips introspection without error", function()
    local restore_state = stub_state({ connection = nil, database = nil })
    local tab = { layout = layout_with(nil) }
    assert.does_not_error(function() column.ensure_primary_key(tab) end)
    assert.falsy(tab.layout.columns[1].primary_key)
    restore_state()
  end)

  it("falls back to poste-db.state.context.connection, not a nil poste.state.sql", function()
    local restore_state = stub_state({ connection = "dev", database = "app" })
    local tab = { layout = layout_with(nil) }
    assert.does_not_error(function() column.ensure_primary_key(tab) end)
    restore_state()
  end)

  it("uses _conn_name carried by the layout even without a SQL context", function()
    local restore_state = stub_state({ connection = nil, database = nil })
    local tab = { layout = layout_with({ _conn_name = "browser_conn", _database = "browser_db" }) }
    assert.does_not_error(function() column.ensure_primary_key(tab) end)
    restore_state()
  end)
end)

--- The refused shape the way exec_run delivers it: the job ran, the statement
--- did not, and the per-statement result carries no rows — textually the same
--- "no keys" payload a keyless table produces. `results` is present (one
--- failed statement), which is exactly why the pre-fix code cached it.
local function refused_response()
  return {
    has_error = true,
    results = { { failed = true } },
    body = vim.json.encode({ type = "affected", results = { { failed = true } }, has_error = true }),
  }
end

describe("editor column refused metadata lookup vs no keys", function()
  before_each(function()
    install_stubs()
  end)

  after_each(function()
    restore_stubs()
  end)

  -- All four tests carry the connection on the layout (`_conn_name`): the
  -- module caches the first `require("poste-db.state")` it sees for its whole
  -- lifetime, and the earlier describe in this file has already pinned it to a
  -- connection-less stub — so the context fallback is unreachable here.

  it("a refused lookup is not cached as no-keys — the next edit retries the query", function()
    local calls = stub_exec_run(refused_response)
    local tab = { layout = layout_with({ _conn_name = "browser_conn", _database = "app" }) }
    column.ensure_primary_key(tab)
    column.ensure_primary_key(tab)
    assert.equals(2, pk_queries(calls))
  end)

  it("a refused lookup leaves the layout's key verdict unset", function()
    stub_exec_run(refused_response)
    local tab = { layout = layout_with({ _conn_name = "browser_conn", _database = "app" }) }
    column.ensure_primary_key(tab)
    assert.falsy(tab.layout.columns[1].primary_key)
  end)

  it("a success after a refused lookup is parsed and then cached", function()
    local refused = true
    local calls = stub_exec_run(function()
      if refused then return refused_response() end
      return pk_body(1)
    end)
    local tab = { layout = layout_with({ _conn_name = "browser_conn", _database = "app" }) }
    column.ensure_primary_key(tab)
    assert.falsy(tab.layout.columns[1].primary_key)
    refused = false
    column.ensure_primary_key(tab)
    assert.equals(2, pk_queries(calls))
    assert.truthy(tab.layout.columns[1].primary_key)
    -- The success is cached: a third edit asks nothing.
    column.ensure_primary_key(tab)
    assert.equals(2, pk_queries(calls))
  end)

  it("a genuine no-keys answer is cached — the next edit asks nothing", function()
    local calls = stub_exec_run(function() return pk_body(0) end)
    local tab = { layout = layout_with({ _conn_name = "browser_conn", _database = "app" }) }
    column.ensure_primary_key(tab)
    assert.falsy(tab.layout.columns[1].primary_key)
    column.ensure_primary_key(tab)
    assert.equals(1, pk_queries(calls))
  end)
end)
--- SQLite's `pragma_table_info` reports `pk` as the column's 1-based position
--- in the key, not a 0/1 flag. Reading it as `== 1` flagged only the first
--- column of a composite key; `dml.build_where` then identified the row by that
--- column alone and the commit rewrote every row sharing it.
describe("editor column composite primary key", function()
  before_each(function()
    install_stubs()
  end)

  after_each(function()
    restore_stubs()
  end)

  local function sqlite_layout()
    return {
      table_name = "t",
      dialect = "sqlite",
      _conn_name = "local",
      columns = {
        { name = "a", type = "INTEGER", ctype = "integer" },
        { name = "b", type = "INTEGER", ctype = "integer" },
        { name = "c", type = "TEXT", ctype = "text" },
      },
    }
  end

  it("flags every column of a sqlite composite key, by key position", function()
    stub_exec_run(function()
      return {
        has_error = false,
        body = vim.json.encode({ results = { { rows = {
          { "a", vim.NIL, 1 }, { "b", vim.NIL, 2 }, { "c", vim.NIL, 0 },
        } } } }),
      }
    end)
    local tab = { layout = sqlite_layout() }
    column.ensure_primary_key(tab)
    assert.is_true(tab.layout.columns[1].primary_key)
    assert.is_true(tab.layout.columns[2].primary_key, "position 2 is still part of the key")
    assert.falsy(tab.layout.columns[3].primary_key)
  end)

  it("reads a position the driver hands back as text", function()
    stub_exec_run(function()
      return {
        has_error = false,
        body = vim.json.encode({ results = { { rows = {
          { "a", vim.NIL, "1" }, { "b", vim.NIL, "2" }, { "c", vim.NIL, "0" },
        } } } }),
      }
    end)
    local tab = { layout = sqlite_layout() }
    column.ensure_primary_key(tab)
    assert.is_true(tab.layout.columns[1].primary_key)
    assert.is_true(tab.layout.columns[2].primary_key)
    assert.falsy(tab.layout.columns[3].primary_key)
  end)
end)
