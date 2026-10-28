--- Item 49: where a yank-register paste lands. The `p` keymap resolves the
--- target from the node under the cursor, and the cursor is usually on a table
--- or a column rather than on the database it belongs to. The resolution walked
--- up to the enclosing database *or connection*, then used the connection only
--- for the sqlite case — so for a table under a sqlite connection it addressed
--- the CLI with the table's own name.
local browser = require("poste-db.db_browser.init")
local t = browser._test

local function chain(dialect)
  local conn = { node_type = "connection", name = dialect == "sqlite" and "lite" or "pg-main",
    meta = { dialect = dialect }, children = {}, expanded = false }
  local db = { node_type = "database", name = "blog",
    meta = { database = "blog", connection = conn.name }, parent = conn, children = {}, expanded = false }
  local schema = { node_type = "schema", name = "public", parent = db, children = {}, expanded = false }
  local table_ = { node_type = "table", name = "posts", parent = schema, children = {}, expanded = false }
  local column = { node_type = "column", name = "id", parent = table_, children = {}, expanded = false }
  conn.children = { db }
  db.children = { schema }
  schema.children = { table_ }
  table_.children = { column }
  return conn, db, schema, table_, column
end

--- The sqlite tree hangs tables directly off the connection: no database, no
--- schema node in between.
local function sqlite_chain()
  local conn = { node_type = "connection", name = "lite", meta = { dialect = "sqlite" },
    children = {}, expanded = false }
  local table_ = { node_type = "table", name = "posts", parent = conn, children = {}, expanded = false }
  local column = { node_type = "column", name = "id", parent = table_, children = {}, expanded = false }
  conn.children = { table_ }
  return conn, table_, column
end

local function entry(kind, dialect)
  return { kind = kind, name = kind == "database" and "blog" or "posts",
    conn = "pg-main", db = "blog", dialect = dialect or "postgres" }
end

describe("db_browser paste target resolution", function()
  it("a database node is its own target", function()
    local _, db = chain("postgres")
    local target = t.resolve_paste_target(db, entry("table"))
    assert.equals(db, target.node)
    assert.equals("pg-main", target.conn)
    assert.equals("blog", target.db)
    assert.is_false(target.is_sqlite_conn)
  end)

  it("a node under a database targets that database", function()
    local _, db, _, table_, column = chain("postgres")
    for _, node in ipairs({ table_, column }) do
      local target = t.resolve_paste_target(node, entry("table"))
      assert.equals(db, target.node, node.name .. " must resolve to its database")
      assert.equals("pg-main", target.conn)
      assert.equals("blog", target.db)
    end
  end)

  it("a table under a sqlite connection targets the connection, by name", function()
    -- The defect: the walk-up found the connection but only the *dialect* was
    -- kept from it, so `conn` fell back to the node under the cursor — a table
    -- name handed to the CLI as a connection, which rejected it.
    local conn, table_, column = sqlite_chain()
    for _, node in ipairs({ conn, table_, column }) do
      local target = t.resolve_paste_target(node, entry("table"))
      assert.equals("lite", target.conn, node.node_type .. " must address the connection")
      assert.is_true(target.is_sqlite_conn)
      -- sqlite: the connection *is* the database, so no db name goes out.
      assert.equals(nil, target.db)
    end
  end)

  it("a non-sqlite connection takes a whole-database yank as a clone target", function()
    local conn = chain("postgres")
    local target = t.resolve_paste_target(conn, entry("database"))
    assert.equals(conn, target.clone_conn)
    assert.equals("pg-main", target.conn)
    assert.is_false(target.is_sqlite_conn)
  end)

  it("the same connection refuses a single table", function()
    local conn = chain("postgres")
    assert.equals(nil, t.resolve_paste_target(conn, entry("table")),
      "nothing around the cursor can take a table paste")
  end)

  it("an orphan node with no ancestors is refused", function()
    local orphan = { node_type = "table", name = "posts", children = {}, expanded = false }
    assert.equals(nil, t.resolve_paste_target(orphan, entry("table")))
  end)

  it("the dialect comes from the cursor's node, else the database, else the yank", function()
    local _, db, _, table_ = chain("postgres")
    table_.meta = { dialect = "mysql" }
    assert.equals("mysql", t.resolve_paste_target(table_, entry("table", "mysql")).dialect)
    table_.meta = nil
    db.meta.dialect = "mysql"
    assert.equals("mysql", t.resolve_paste_target(table_, entry("table", "mysql")).dialect)
    db.meta.dialect = nil
    assert.equals("postgres", t.resolve_paste_target(table_, entry("table", "postgres")).dialect)
  end)

  it("a table under a sqlite connection takes the TARGET connection's dialect", function()
    -- Neither a table node nor (absent) target_db carries meta.dialect, so the
    -- chain fell through to entry.dialect — the SOURCE's dialect — and a
    -- postgres yank pasted onto sqlite passed copy.lua's dialect-mismatch
    -- guard while running postgres catalog/DDL SQL against the sqlite
    -- connection. The walk-up's connection node must win before the yank.
    local conn, table_ = sqlite_chain()
    local target = t.resolve_paste_target(table_, entry("table", "postgres"))
    assert.equals("sqlite", target.dialect)
  end)
end)
