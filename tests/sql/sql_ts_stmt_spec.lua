--- Tests for ts_stmt.lua — Tree-sitter-based statement boundary detection.

local has_sql_parser = require("poste-db.ts_stmt").check_parser()
local ts_stmt = require("poste-db.ts_stmt")

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "poste_sql"
  -- Wait for Tree-sitter to parse
  vim.wait(500, function()
    local ok, p = pcall(vim.treesitter.get_parser, buf, "sql")
    return ok and p ~= nil
  end)
  return buf
end

if not has_sql_parser then
  describe("Tree-sitter SQL parser availability", function()
    it("is skipped when the parser is unavailable", function()
      pending("Tree-sitter SQL parser unavailable in this Neovim environment")
    end)
  end)
  return
end

describe("find_stmt_span", function()
  it("returns correct span for single statement", function()
    local buf = make_buf({ "SELECT 1;", "SELECT 2;" })
    local span = ts_stmt.find_stmt_span(buf, 1)
    assert.same({ 1, 1 }, span)
  end)

  it("returns correct span for second statement", function()
    local buf = make_buf({ "SELECT 1;", "SELECT 2;" })
    local span = ts_stmt.find_stmt_span(buf, 2)
    assert.same({ 2, 2 }, span)
  end)

  it("handles semicolon in string literal", function()
    local buf = make_buf({ "SELECT 'hello;world' AS test;", "SELECT 2;" })
    local span = ts_stmt.find_stmt_span(buf, 1)
    assert.same({ 1, 1 }, span)
  end)

  it("handles dollar-quoted string", function()
    local buf = make_buf({ "SELECT $$abc;def$$;", "SELECT 2;" })
    local span = ts_stmt.find_stmt_span(buf, 2)
    assert.same({ 2, 2 }, span)
  end)

  it("handles multi-statement on same line", function()
    local buf = make_buf({ "SELECT 1; SELECT 2;" })
    local span = ts_stmt.find_stmt_span(buf, 1)
    -- Both statements on the same line are separate statements
    -- The cursor is on line 1, which contains both
    -- Tree-sitter will return the first statement for cursor at line 1
    assert.same({ 1, 1 }, span)
  end)

  it("handles multi-line statement", function()
    local buf = make_buf({ "SELECT *", "FROM users", "WHERE id = 1;", "SELECT 2;" })
    local span = ts_stmt.find_stmt_span(buf, 2)
    assert.same({ 1, 3 }, span)
  end)

  it("folds the LIMIT comma fragment into the statement span", function()
    -- `LIMIT 1, 10` parses as `LIMIT 1` + a top-level ERROR sibling `, 10`.
    -- The fragment is the same statement; the span must cover both, or
    -- running the current statement from the LIMIT line sends `, 10;`.
    local buf = make_buf({ "SELECT id, name", "FROM users", "LIMIT 1, 10;" })
    assert.same({ 1, 3 }, ts_stmt.find_stmt_span(buf, 1))
    assert.same({ 1, 3 }, ts_stmt.find_stmt_span(buf, 3))
  end)

  it("folds a multi-line LIMIT comma fragment into the statement span", function()
    local buf = make_buf({ "SELECT id, name", "FROM users", "LIMIT 1,", "  10;" })
    assert.same({ 1, 4 }, ts_stmt.find_stmt_span(buf, 1))
    assert.same({ 1, 4 }, ts_stmt.find_stmt_span(buf, 4))
  end)

  it("handles CTE (WITH clause)", function()
    local buf = make_buf({ "WITH cte AS (SELECT 1) SELECT * FROM cte;", "SELECT 2;" })
    local span = ts_stmt.find_stmt_span(buf, 1)
    assert.same({ 1, 1 }, span)
  end)

  it("handles INSERT with subquery", function()
    local buf = make_buf({ "INSERT INTO t SELECT * FROM u;", "SELECT 2;" })
    local span = ts_stmt.find_stmt_span(buf, 1)
    assert.same({ 1, 1 }, span)
  end)

  it("handles semicolon in double-quoted identifier", function()
    local buf = make_buf({ "SELECT \"col;name\" FROM users;", "SELECT 2;" })
    local span = ts_stmt.find_stmt_span(buf, 1)
    assert.same({ 1, 1 }, span)
  end)

  it("handles BEGIN/COMMIT transaction block", function()
    local buf = make_buf({ "BEGIN; UPDATE t SET x=1; COMMIT;", "SELECT 1;" })
    local span = ts_stmt.find_stmt_span(buf, 1)
    -- BEGIN/COMMIT is a transaction node
    assert.same({ 1, 1 }, span)
  end)

  it("reflects buffer edits (cache invalidation)", function()
    local buf = make_buf({ "SELECT 1;", "SELECT 2;" })
    assert.same({ 1, 1 }, ts_stmt.find_stmt_span(buf, 1))  -- warm the cache
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "SELECT *", "FROM t;" })
    -- "SELECT *\nFROM t;" is a fresh 2-line statement; the stale { 1, 1 }
    -- span must not be returned after the buffer edit
    assert.same({ 2, 3 }, ts_stmt.find_stmt_span(buf, 2))
    assert.same({ 2, 3 }, ts_stmt.find_stmt_span(buf, 3))
  end)
end)

describe("find_all_stmt_lines", function()
  it("returns all statement start lines", function()
    local buf = make_buf({ "SELECT 1;", "SELECT 2;", "SELECT 3;" })
    local lines = ts_stmt.find_all_stmt_lines(buf, 1, 3)
    assert.same({ 1, 2, 3 }, lines)
  end)

  it("skips blank lines between statements", function()
    local buf = make_buf({ "SELECT 1;", "", "SELECT 2;" })
    local lines = ts_stmt.find_all_stmt_lines(buf, 1, 3)
    assert.same({ 1, 3 }, lines)
  end)

  it("skips comment lines between statements", function()
    local buf = make_buf({ "SELECT 1;", "-- comment", "SELECT 2;" })
    local lines = ts_stmt.find_all_stmt_lines(buf, 1, 3)
    assert.same({ 1, 3 }, lines)
  end)

  it("handles multi-line statements", function()
    local buf = make_buf({ "SELECT *", "FROM users;", "SELECT count(*)", "FROM orders;" })
    local lines = ts_stmt.find_all_stmt_lines(buf, 1, 4)
    assert.same({ 1, 3 }, lines)
  end)

  it("does not split a statement at the LIMIT comma fragment", function()
    -- The `, 10` ERROR sibling must not register as its own statement
    -- (buffer-wide run would execute `, 10;` as a separate chunk).
    local buf = make_buf({ "SELECT id, name", "FROM users", "LIMIT 1, 10;", "SELECT 2;" })
    assert.same({ 1, 4 }, ts_stmt.find_all_stmt_lines(buf, 1, 4))
  end)

  it("does not duplicate the start line for a same-line LIMIT comma fragment", function()
    local buf = make_buf({ "SELECT id, name FROM users LIMIT 1, 10;", "SELECT 2;" })
    assert.same({ 1, 2 }, ts_stmt.find_all_stmt_lines(buf, 1, 2))
  end)

  it("works within a sub-range", function()
    local buf = make_buf({ "SELECT 1;", "SELECT 2;", "SELECT 3;", "SELECT 4;" })
    local lines = ts_stmt.find_all_stmt_lines(buf, 2, 4)
    assert.same({ 2, 3, 4 }, lines)
  end)
end)

describe("find_error_nodes", function()
  it("detects syntax error (FORM instead of FROM)", function()
    local buf = make_buf({ "SELECT * FORM users;" })
    local errors = ts_stmt.find_error_nodes(buf)
    assert.is_true(#errors > 0, "should detect FORM as error")
    assert.equals("Unexpected token: users", errors[1].text)
  end)

  it("returns empty for valid SQL", function()
    local buf = make_buf({ "SELECT * FROM users WHERE id = 1;" })
    local errors = ts_stmt.find_error_nodes(buf)
    assert.same({}, errors)
  end)

  it("does not flag USE statement as error", function()
    local buf = make_buf({ "use inventory;", "SELECT 1;" })
    local errors = ts_stmt.find_error_nodes(buf)
    assert.same({}, errors, "USE is a false positive, should be filtered")
  end)

  it("does not flag CREATE DATABASE with charset/collate followed by USE", function()
    -- Regression: tree-sitter-sql has no USE rule, so after
    -- `CREATE DATABASE ... COLLATE utf8mb4_unicode_ci;` the create_database
    -- `name value` listing swallows `; USE` into a statement-terminator
    -- cascade ERROR node. It must be filtered, not reported as an error.
    local buf = make_buf({
      "CREATE DATABASE IF NOT EXISTS blog CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;",
      "USE blog;",
    })
    local errors = ts_stmt.find_error_nodes(buf)
    assert.same({}, errors, "; USE cascade from create_database should be filtered")
  end)

  it("does not flag SET statement as error", function()
    local buf = make_buf({ "SET NAMES utf8;", "SELECT 1;" })
    local errors = ts_stmt.find_error_nodes(buf)
    assert.same({}, errors, "SET is a false positive, should be filtered")
  end)

  it("does not flag DESC/DESCRIBE as error", function()
    local buf = make_buf({ "desc posts;", "SELECT 1;" })
    local errors = ts_stmt.find_error_nodes(buf)
    assert.same({}, errors, "DESC is a false positive")
  end)

  it("does not flag ANALYZE, KILL, FLUSH, CALL, LOAD, REPAIR, CHECK as error", function()
    local stmts = { "ANALYZE;", "KILL 42;", "FLUSH TABLES;", "CALL p();", "LOAD DATA;", "REPAIR TABLE t;", "CHECK TABLE t;" }
    for _, sql in ipairs(stmts) do
      local buf = make_buf({ sql, "SELECT 1;" })
      local errors = ts_stmt.find_error_nodes(buf)
      assert.same({}, errors, sql .. " should be filtered")
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("suppresses digit-leading identifier fragment for mysql dialect", function()
    local buf = make_buf({ "SELECT * FROM 23_tablename WHERE id = 1;" })
    local errors = ts_stmt.find_error_nodes(buf, "mysql")
    assert.same({}, errors, "23_tablename is one legal unquoted identifier in MySQL")
  end)

  it("suppresses digit-leading identifier fragment for mariadb dialect", function()
    local buf = make_buf({ "SELECT * FROM 2024_log WHERE id = 1;" })
    local errors = ts_stmt.find_error_nodes(buf, "mariadb")
    assert.same({}, errors, "2024_log is one legal unquoted identifier in MariaDB")
  end)

  it("suppresses longer digit prefixes (no length cutoff)", function()
    -- Regression: the old `#text <= 2` cascading filter only hid 1-2 digit
    -- names; 3+ digit prefixes (234, 2024…) surfaced as errors.
    local buf = make_buf({ "SELECT * FROM 2024_log WHERE id = 1;" })
    local errors = ts_stmt.find_error_nodes(buf, "mysql")
    assert.same({}, errors, "2024_log must not be flagged")
  end)

  it("keeps digit-leading diagnostics for postgres dialect", function()
    local buf = make_buf({ "SELECT * FROM 2024_log;" })
    local errors = ts_stmt.find_error_nodes(buf, "postgres")
    assert.is_true(#errors > 0, "unquoted digit-leading identifier must stay an error for PG")
  end)

  it("keeps digit-leading diagnostics when dialect is unknown", function()
    local buf = make_buf({ "SELECT * FROM 2024_log;" })
    local errors = ts_stmt.find_error_nodes(buf)
    assert.is_true(#errors > 0, "digit-leading unquoted identifier must remain an error when dialect is unknown")
  end)

  it("keeps all-digit table name flagged for mysql", function()
    -- `from 234` is an ERROR whose text is "from 234" (not pure digits):
    -- a table cannot consist solely of digits in MySQL either.
    local buf = make_buf({ "SELECT * FROM 234;" })
    local errors = ts_stmt.find_error_nodes(buf, "mysql")
    assert.is_true(#errors > 0, "all-digit table name is invalid in MySQL")
  end)

  it("keeps digit fragment followed by whitespace for mysql", function()
    -- `234 _tablename` = bare all-digit table + alias → still invalid.
    local buf = make_buf({ "SELECT * FROM 234 _tablename;" })
    local errors = ts_stmt.find_error_nodes(buf, "mysql")
    assert.is_true(#errors > 0, "digit fragment is standalone here")
  end)

  it("suppresses numeric INTERVAL quantity for mysql", function()
    -- tree-sitter-sql only parses quoted `INTERVAL '7' DAY`; the numeric form
    -- is legal MySQL date arithmetic.
    local buf = make_buf({ "SELECT DATE_ADD(NOW(), INTERVAL 7 DAY) AS next_week, NOW(), CURDATE(), CURTIME();" })
    local errors = ts_stmt.find_error_nodes(buf, "mysql")
    assert.same({}, errors, "INTERVAL 7 DAY must not be flagged for mysql")
  end)

  it("suppresses numeric INTERVAL quantity for mariadb", function()
    local buf = make_buf({ "SELECT DATE_ADD(NOW(), INTERVAL 1 WEEK);" })
    local errors = ts_stmt.find_error_nodes(buf, "mariadb")
    assert.same({}, errors, "INTERVAL 1 WEEK must not be flagged for mariadb")
  end)

  it("keeps numeric INTERVAL quantity flagged for postgres", function()
    -- The numeric form `INTERVAL 7 DAY` is MySQL-specific and invalid in postgres.
    local buf = make_buf({ "SELECT NOW() + INTERVAL 7 DAY;" })
    local errors = ts_stmt.find_error_nodes(buf, "postgres")
    assert.is_true(#errors > 0, "numeric INTERVAL is invalid in postgres")
  end)

  it("suppresses numeric INTERVAL in INSERT VALUES for mariadb (regression)", function()
    -- `NOW() - INTERVAL 20 DAY` inside an INSERT VALUES clause produces an
    -- ERROR node with text `INTERVAL 20` (parser recovers before the unit
    -- keyword). Must be suppressed for mariadb.
    local buf = make_buf({ "INSERT INTO posts (published_at) VALUES (NOW() - INTERVAL 20 DAY);" })
    local errors = ts_stmt.find_error_nodes(buf, "mariadb")
    assert.same({}, errors, "INTERVAL in INSERT VALUES must not be flagged for mariadb")
  end)

  it("suppresses parenthesized INTERVAL (expr) regardless of dialect", function()
    -- `INTERVAL (i * 2) DAY` is a tree-sitter parser limitation, not a real error.
    local buf = make_buf({ "SELECT NOW() - INTERVAL (i * 2) DAY FROM seq;" })
    local errors = ts_stmt.find_error_nodes(buf, "postgres")
    assert.same({}, errors, "INTERVAL (expr) is a parser limitation, suppressed for all dialects")
  end)

  it("keeps numeric INTERVAL quantity flagged when dialect is unknown", function()
    local buf = make_buf({ "SELECT DATE_ADD(NOW(), INTERVAL 7 DAY);" })
    local errors = ts_stmt.find_error_nodes(buf)
    assert.is_true(#errors > 0, "numeric INTERVAL must remain flagged when dialect is unknown")
  end)

  it("suppresses GROUP_CONCAT SEPARATOR for mysql", function()
    -- tree-sitter-sql does not parse `... SEPARATOR '-'` (MySQL-specific).
    local buf = make_buf({ "SELECT GROUP_CONCAT('a', 'b', 'c' SEPARATOR '-') AS concat_test;" })
    local errors = ts_stmt.find_error_nodes(buf, "mysql")
    assert.same({}, errors, "SEPARATOR must not be flagged for mysql")
  end)

  it("suppresses GROUP_CONCAT SEPARATOR for mariadb", function()
    local buf = make_buf({ "SELECT GROUP_CONCAT('a', 'b', 'c' SEPARATOR '-');" })
    local errors = ts_stmt.find_error_nodes(buf, "mariadb")
    assert.same({}, errors, "SEPARATOR must not be flagged for mariadb")
  end)

  it("keeps GROUP_CONCAT SEPARATOR flagged for postgres", function()
    -- PostgreSQL's string_agg is not expressed with SEPARATOR.
    local buf = make_buf({ "SELECT GROUP_CONCAT('a', 'b', 'c' SEPARATOR '-');" })
    local errors = ts_stmt.find_error_nodes(buf, "postgres")
    assert.is_true(#errors > 0, "SEPARATOR is invalid in postgres")
  end)

  it("suppresses mysql \\G terminator after a recognized statement", function()
    local buf = make_buf({ "SHOW CREATE TABLE posts\\G" })
    local errors = ts_stmt.find_error_nodes(buf, "mysql")
    assert.same({}, errors, "trailing \\G is a client terminator, not SQL")
  end)

  it("suppresses mysql \\G terminator merged into an unknown statement", function()
    local buf = make_buf({ "SHOW TABLE STATUS LIKE 'posts'\\G" })
    local errors = ts_stmt.find_error_nodes(buf, "mysql")
    assert.same({}, errors, "SHOW TABLE STATUS ... \\G must not be flagged for mysql")
  end)

  it("suppresses unknown SHOW variants for mysql", function()
    local buf = make_buf({ "SHOW COLUMNS FROM posts;" })
    local errors = ts_stmt.find_error_nodes(buf, "mysql")
    assert.same({}, errors, "SHOW COLUMNS must not be flagged for mysql")
  end)

  it("keeps SHOW flagged for postgres", function()
    -- SHOW is MySQL-only; the same text is invalid in PostgreSQL.
    local buf = make_buf({ "SHOW TABLE STATUS LIKE 'posts';" })
    local errors = ts_stmt.find_error_nodes(buf, "postgres")
    assert.is_true(#errors > 0, "SHOW must remain flagged for postgres")
  end)

  it("suppresses SQLite PRAGMA statements and their cascades", function()
    local stmts = {
      "PRAGMA journal_mode;",
      "PRAGMA table_info(users);",
      "PRAGMA table_info(users); PRAGMA index_list(users);",
    }
    for _, sql in ipairs(stmts) do
      local buf = make_buf({ sql })
      local errors = ts_stmt.find_error_nodes(buf, "sqlite")
      assert.same({}, errors, sql)
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("suppresses SQLite INSERT OR conflict fragments", function()
    local stmts = {
      "INSERT OR REPLACE INTO users (name, email) VALUES ('a', 'b');",
      "INSERT OR IGNORE INTO t (a) VALUES (1);",
    }
    for _, sql in ipairs(stmts) do
      local buf = make_buf({ sql })
      local errors = ts_stmt.find_error_nodes(buf, "sqlite")
      assert.same({}, errors, sql)
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("suppresses SQLite GLOB operator", function()
    local buf = make_buf({ "SELECT * FROM users WHERE email GLOB '*@gmail.com';" })
    local errors = ts_stmt.find_error_nodes(buf, "sqlite")
    assert.same({}, errors, "GLOB must not be flagged")
  end)

  it("suppresses NATURAL JOIN, SAVEPOINT/RELEASE, EXPLAIN QUERY PLAN, VALUES", function()
    local stmts = {
      "SELECT * FROM orders NATURAL JOIN order_items LIMIT 10;",
      "SAVEPOINT sp1;",
      "RELEASE SAVEPOINT sp1;",
      "EXPLAIN QUERY PLAN SELECT * FROM orders WHERE status = 'pending';",
      "VALUES (1, 'a'), (2, 'b');",
    }
    for _, sql in ipairs(stmts) do
      local buf = make_buf({ sql })
      local errors = ts_stmt.find_error_nodes(buf, "sqlite")
      assert.same({}, errors, sql)
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("keeps real syntax errors intact", function()
    local buf = make_buf({ "SELECT * FORM users;" })
    local errors = ts_stmt.find_error_nodes(buf, "sqlite")
    assert.is_true(#errors > 0, "FORM typo must still be flagged")
  end)

  it("suppresses MariaDB INTERVAL (expr) for mariadb", function()
    local buf = make_buf({ "SELECT NOW() - INTERVAL (i * 2) DAY FROM seq;" })
    local errors = ts_stmt.find_error_nodes(buf, "mariadb")
    assert.same({}, errors, "INTERVAL (expr) must not be flagged for mariadb")
  end)

  it("suppresses MariaDB CREATE OR REPLACE TABLE", function()
    local buf = make_buf({ "CREATE OR REPLACE TABLE test_mariadb (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(100));" })
    local errors = ts_stmt.find_error_nodes(buf, "mariadb")
    assert.same({}, errors, "CREATE OR REPLACE TABLE must not be flagged for mariadb")
  end)

  it("suppresses MariaDB column attribute INVISIBLE", function()
    local buf = make_buf({ "CREATE TABLE t (id INT, c VARCHAR(50) INVISIBLE);" })
    local errors = ts_stmt.find_error_nodes(buf, "mariadb")
    assert.same({}, errors, "INVISIBLE must not be flagged for mariadb")
  end)

  it("suppresses WITHIN GROUP head for PERCENTILE_CONT", function()
    local buf = make_buf({ "SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY total) AS median_total FROM orders;" })
    local errors = ts_stmt.find_error_nodes(buf, "postgres")
    assert.same({}, errors, "PERCENTILE_CONT ... WITHIN GROUP must not be flagged")
  end)

  it("suppresses WITHIN GROUP head and ORDER BY fragment when dialect is unknown", function()
    local buf = make_buf({ "SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY total) AS median_disc FROM orders;" })
    local errors = ts_stmt.find_error_nodes(buf)
    assert.same({}, errors, "neither the WITHIN GROUP head nor the bare total fragment may be flagged")
  end)

  it("suppresses MSSQL SELECT TOP (N) alias.column dot fragments", function()
    local buf = make_buf({
      "SELECT TOP (10) o.id, u.username, o.status, o.total",
      "FROM dbo.orders o",
      "JOIN dbo.users u ON u.id = o.user_id",
      "ORDER BY o.total DESC;",
    })
    local errors = ts_stmt.find_error_nodes(buf, "mssql")
    assert.same({}, errors, "TOP (N) is valid T-SQL; the .id fragment is a parser artifact")
  end)

  it("suppresses paren-less MSSQL SELECT TOP count digits", function()
    local buf = make_buf({ "SELECT TOP 100 o.id FROM dbo.orders o;" })
    local errors = ts_stmt.find_error_nodes(buf, "mssql")
    assert.same({}, errors, "TOP 100 is valid T-SQL")
  end)

  it("suppresses MSSQL OFFSET-FETCH pagination", function()
    local buf = make_buf({
      "SELECT o.id, o.status, o.total",
      "FROM dbo.orders o",
      "ORDER BY o.id",
      "OFFSET 10 ROWS FETCH NEXT 10 ROWS ONLY;",
    })
    local errors = ts_stmt.find_error_nodes(buf, "mssql")
    assert.same({}, errors, "OFFSET-FETCH is valid T-SQL pagination")
  end)

  it("suppresses MSSQL FETCH FIRST without a qualified ORDER BY column", function()
    -- Exercises the OFFSET/FETCH text rule, not the leading-dot rule.
    local buf = make_buf({ "SELECT id FROM dbo.orders o ORDER BY id", "FETCH FIRST 5 ROWS ONLY;" })
    local errors = ts_stmt.find_error_nodes(buf, "mssql")
    assert.same({}, errors, "FETCH FIRST 5 ROWS ONLY is valid T-SQL")
  end)

  it("suppresses MySQL LIMIT offset,count pagination", function()
    -- `LIMIT 1, 10` parses as `limit 1` + a top-level ERROR sibling `, 10`:
    -- tree-sitter-sql only knows `LIMIT n [OFFSET m]`.
    local buf = make_buf({ "SELECT id, name FROM users LIMIT 1, 10;" })
    local errors = ts_stmt.find_error_nodes(buf, "mysql")
    assert.same({}, errors, "LIMIT 1, 10 is valid MySQL pagination")
  end)

  it("suppresses LIMIT offset,count pagination for sqlite", function()
    -- SQLite spells it `LIMIT expr, expr` ≡ `LIMIT expr OFFSET expr`.
    local buf = make_buf({ "SELECT id, name FROM users LIMIT 1, 10;" })
    local errors = ts_stmt.find_error_nodes(buf, "sqlite")
    assert.same({}, errors, "LIMIT 1, 10 is valid SQLite pagination")
  end)

  it("suppresses LIMIT offset,count pagination for clickhouse", function()
    local buf = make_buf({ "SELECT id, name FROM users LIMIT 1, 10;" })
    local errors = ts_stmt.find_error_nodes(buf, "clickhouse")
    assert.same({}, errors, "LIMIT 1, 10 is valid ClickHouse pagination")
  end)

  it("suppresses a multi-line LIMIT comma fragment for mariadb", function()
    -- `LIMIT 1,\n  10` strands the ERROR across rows (`,\n  10`).
    local buf = make_buf({ "SELECT id, name", "FROM users", "LIMIT 1,", "  10;" })
    local errors = ts_stmt.find_error_nodes(buf, "mariadb")
    assert.same({}, errors, "the comma-count fragment is the same pagination clause")
  end)

  it("keeps LIMIT offset,count flagged for postgres", function()
    -- PostgreSQL rejects the comma form; the diagnostic is real there.
    local buf = make_buf({ "SELECT id, name FROM users LIMIT 1, 10;" })
    local errors = ts_stmt.find_error_nodes(buf, "postgres")
    assert.is_true(#errors > 0, "LIMIT offset,count is invalid postgres syntax")
  end)

  it("keeps LIMIT offset,count flagged when dialect is unknown", function()
    local buf = make_buf({ "SELECT id, name FROM users LIMIT 1, 10;" })
    local errors = ts_stmt.find_error_nodes(buf)
    assert.is_true(#errors > 0, "unknown dialect must stay conservative")
  end)

  it("keeps a LIMIT comma fragment that swallows a following statement", function()
    -- Without a `;`, the ERROR absorbs the next statement (`, 10 SELECT 2`):
    -- no longer a pure offset,count fragment, so stay conservative.
    local buf = make_buf({ "SELECT id, name FROM users LIMIT 1, 10", "SELECT 2;" })
    local errors = ts_stmt.find_error_nodes(buf, "mysql")
    assert.is_true(#errors > 0, "a fragment that swallowed the next statement must stay flagged")
  end)

  it("suppresses MSSQL FOR JSON result suffix", function()
    local buf = make_buf({
      "SELECT u.username, o.total",
      "FROM dbo.orders o",
      "JOIN dbo.users u ON u.id = o.user_id",
      "ORDER BY o.id",
      "FOR JSON PATH, INCLUDE_NULL_VALUES;",
    })
    local errors = ts_stmt.find_error_nodes(buf, "mssql")
    assert.same({}, errors, "FOR JSON PATH is valid T-SQL")
  end)

  it("suppresses STRING_AGG ... WITHIN GROUP tail", function()
    local buf = make_buf({
      "SELECT STRING_AGG(o.status, ', ') WITHIN GROUP (ORDER BY o.status) AS statuses",
      "FROM dbo.orders o",
      "GROUP BY o.status;",
    })
    local errors = ts_stmt.find_error_nodes(buf, "mssql")
    assert.same({}, errors, "the GROUP (ORDER BY ...) ERROR head is a WITHIN GROUP artifact")
  end)

  it("keeps real MSSQL syntax errors intact", function()
    local buf = make_buf({ "SELECT * FORM users;" })
    local errors = ts_stmt.find_error_nodes(buf, "mssql")
    assert.is_true(#errors > 0, "FORM typo must still be flagged for mssql")
  end)

  it("suppresses ClickHouse GROUP BY ... WITH TOTALS", function()
    local buf = make_buf({ "SELECT status, count() AS n FROM orders GROUP BY status WITH TOTALS ORDER BY status;" })
    local errors = ts_stmt.find_error_nodes(buf, "clickhouse")
    assert.same({}, errors, "WITH TOTALS is a valid ClickHouse modifier")
  end)

  it("suppresses ClickHouse ORDER BY ... WITH TOTALS", function()
    local buf = make_buf({ "SELECT status FROM orders ORDER BY total DESC WITH TOTALS LIMIT 5;" })
    local errors = ts_stmt.find_error_nodes(buf, "clickhouse")
    assert.same({}, errors, "WITH TOTALS after ORDER BY is valid ClickHouse")
  end)

  it("keeps a truncated WITH for clickhouse", function()
    -- `GROUP BY x WITH` without TOTALS is a real error; the stray-field
    -- sibling check must not suppress it.
    local buf = make_buf({ "SELECT status FROM orders GROUP BY status WITH;" })
    local errors = ts_stmt.find_error_nodes(buf, "clickhouse")
    assert.is_true(#errors > 0, "truncated WITH modifier must stay flagged")
  end)

  it("suppresses ClickHouse ARRAY JOIN", function()
    local buf = make_buf({
      "SELECT id, tag, length(tags) AS tag_count",
      "FROM type_showcase ARRAY JOIN tags AS tag ORDER BY id, tag;",
    })
    local errors = ts_stmt.find_error_nodes(buf, "clickhouse")
    assert.same({}, errors, "ARRAY JOIN is valid ClickHouse")
  end)

  it("suppresses ClickHouse multi-array ARRAY JOIN", function()
    local buf = make_buf({
      "SELECT id, sensor, reading",
      "FROM type_showcase ARRAY JOIN sensors AS sensor, readings AS reading",
      "ORDER BY id, sensor;",
    })
    local errors = ts_stmt.find_error_nodes(buf, "clickhouse")
    assert.same({}, errors, "multi-array ARRAY JOIN is valid ClickHouse")
  end)

  it("suppresses ClickHouse LEFT ARRAY JOIN", function()
    local buf = make_buf({
      "SELECT id, sensor FROM type_showcase LEFT ARRAY JOIN sensors AS sensor ORDER BY id;",
    })
    local errors = ts_stmt.find_error_nodes(buf, "clickhouse")
    assert.same({}, errors, "LEFT ARRAY JOIN is valid ClickHouse (outer + nested ARRAY fragment)")
  end)

  it("suppresses ClickHouse ALTER TABLE DELETE mutation", function()
    local buf = make_buf({ "ALTER TABLE type_showcase DELETE WHERE label = 'second';" })
    local errors = ts_stmt.find_error_nodes(buf, "clickhouse")
    assert.same({}, errors, "ALTER TABLE ... DELETE WHERE is a valid ClickHouse mutation")
  end)

  it("keeps real ClickHouse syntax errors intact", function()
    local buf = make_buf({ "SELECT * FORM users;" })
    local errors = ts_stmt.find_error_nodes(buf, "clickhouse")
    assert.is_true(#errors > 0, "FORM typo must still be flagged for clickhouse")
  end)
end)

local sem_ok, sem = pcall(require, "poste-db.semantic_diagnostics")
if sem_ok and sem._test and sem._test.extract_references_from_node then
  describe("semantic reference extraction (digit-leading identifiers)", function()
    local extract = sem._test.extract_references_from_node

    local function extract_tables(sql)
      local buf = make_buf({ sql })
      local parser = assert(vim.treesitter.get_parser(buf, "sql"))
      local root = parser:parse()[1]:root()
      local stmt = nil
      for child in root:iter_children() do
        if child:type() == "statement" then stmt = child break end
      end
      local refs = extract(stmt, buf)
      local names = {}
      for _, t in ipairs(refs.tables) do names[#names + 1] = t.name end
      return names, refs, buf
    end

    it("rejoins digit fragment from SELECT FROM", function()
      local names = extract_tables("SELECT * FROM 123_abc;")
      assert.same({ "123_abc" }, names, "must look up 123_abc, not the _abc fragment")
    end)

    it("rejoins longer digit prefix (2024_log)", function()
      local names = extract_tables("select * from 2024_log where id = 1;")
      assert.same({ "2024_log" }, names)
    end)

    it("rejoins with AS alias", function()
      local names, refs = extract_tables("select * from 123_abc as t;")
      assert.same({ "123_abc" }, names)
      assert.equal("123_abc", refs.from_tables[1])
    end)

    it("rejoins INSERT INTO target", function()
      local names = extract_tables("insert into 123_abc values (1);")
      assert.same({ "123_abc" }, names)
    end)

    it("rejoins UPDATE target", function()
      local names = extract_tables("update 123_abc set x = 1;")
      assert.same({ "123_abc" }, names)
    end)

    it("does not merge when whitespace separates (234 _tablename)", function()
      local names = extract_tables("select * from 234 _tablename;")
      assert.same({ "_tablename" }, names, "digit fragment is a separate standalone name")
    end)

    it("leaves plain identifiers untouched", function()
      local names = extract_tables("select * from users;")
      assert.same({ "users" }, names)
    end)

    it("extracts schema-qualified catalog tables with their prefix", function()
      local names, refs = extract_tables(
        "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public';"
      )
      assert.same({ "pg_tables" }, names)
      assert.equal("pg_catalog", refs.tables[1].db_prefix)
    end)

    it("rejoins both sides of a JOIN", function()
      local names = extract_tables("select * from 23_tablename join 2024_log l on l.id = x.id;")
      assert.same({ "23_tablename", "2024_log" }, names)
    end)

    it("detects SELECT aliases from AS keyword", function()
      local _, refs = extract_tables("SELECT AVG(metric_01) AS avg_load FROM web_vitals;")
      assert.is_true(refs.select_aliases["avg_load"], "avg_load should be in select_aliases")
    end)

    it("detects multiple SELECT aliases", function()
      local _, refs = extract_tables("SELECT AVG(metric_01) AS avg_load, MAX(metric_05) AS max_ttfb FROM web_vitals;")
      assert.is_true(refs.select_aliases["avg_load"], "avg_load should be in select_aliases")
      assert.is_true(refs.select_aliases["max_ttfb"], "max_ttfb should be in select_aliases")
    end)

    it("does not flag bare column names as SELECT aliases", function()
      local _, refs = extract_tables("SELECT url, COUNT(*) FROM web_vitals;")
      assert.is_nil(refs.select_aliases["url"], "bare column url should not be in select_aliases")
      assert.is_nil(refs.select_aliases["count"], "COUNT should not be in select_aliases")
    end)

    it("records SELECT aliases case-insensitively", function()
      local _, refs = extract_tables("SELECT AVG(metric_01) AS AVG_LOAD FROM web_vitals;")
      assert.is_true(refs.select_aliases["avg_load"], "avg_load (lowercase) should match")
    end)

    it("includes column refs from ORDER BY for SELECT aliases (for validation skip)", function()
      local _, refs = extract_tables("SELECT AVG(metric_01) AS avg_load FROM web_vitals ORDER BY avg_load;")
      local found = false
      for _, col in ipairs(refs.columns) do
        if col.name:lower() == "avg_load" then found = true; break end
      end
      assert.is_true(found, "avg_load should appear in columns (from ORDER BY)")
      assert.is_true(refs.select_aliases["avg_load"], "avg_load should be in select_aliases")
    end)
  end)

  describe("semantic reference extraction (CTEs)", function()
    local extract = sem._test.extract_references_from_node

    local function extract_tables(sql)
      local buf = make_buf({ sql })
      local parser = assert(vim.treesitter.get_parser(buf, "sql"))
      local root = parser:parse()[1]:root()
      local stmt = nil
      for child in root:iter_children() do
        if child:type() == "statement" then stmt = child break end
      end
      local refs = extract(stmt, buf)
      local names = {}
      for _, t in ipairs(refs.tables) do names[#names + 1] = t.name end
      return names, refs, buf
    end

    it("does not flag recursive CTE self-reference", function()
      local names = extract_tables(
        "WITH RECURSIVE seq (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < 3) "
          .. "INSERT INTO authors (username, email, bio) SELECT i, i, i FROM seq;"
      )
      assert.same({ "authors" }, names, "seq is a CTE, only the INSERT target must remain")
    end)

    it("does not flag plain CTE reference but keeps body tables", function()
      local names = extract_tables("WITH x AS (SELECT id FROM users WHERE active) SELECT * FROM x;")
      assert.same({ "users" }, names, "x is a CTE, users in the CTE body is a real table")
    end)

    it("does not flag chained CTE references", function()
      local names = extract_tables(
        "WITH a AS (SELECT 1 AS n), b AS (SELECT n FROM a) SELECT n FROM b;"
      )
      assert.same({}, names, "a and b are CTEs, no real tables in this statement")
    end)
  end)

  describe("semantic reference extraction (ordered-set aggregates)", function()
    local extract = sem._test.extract_references_from_node

    local function extract_refs(sql)
      local buf = make_buf({ sql })
      local parser = assert(vim.treesitter.get_parser(buf, "sql"))
      local root = parser:parse()[1]:root()
      local stmt = nil
      for child in root:iter_children() do
        if child:type() == "statement" then stmt = child break end
      end
      return extract(stmt, buf)
    end

    it("does not extract phantom columns from WITHIN GROUP (ORDER BY ...)", function()
      local refs = extract_refs(
        "SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY total) AS median_total FROM orders;"
      )
      local col_names = {}
      for _, c in ipairs(refs.columns) do col_names[#col_names + 1] = c.name end
      local tbl_names = {}
      for _, t in ipairs(refs.tables) do tbl_names[#tbl_names + 1] = t.name end
      assert.same({ "orders" }, tbl_names, "only the real FROM table may be extracted")
      assert.same({}, col_names, "ORDER/total inside WITHIN GROUP must not become columns")
    end)

    it("still records the SELECT alias of the aggregate", function()
      local refs = extract_refs(
        "SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY total) AS median_disc FROM orders;"
      )
      assert.is_true(refs.select_aliases["median_disc"], "median_disc should be recorded as an alias")
    end)
  end)

  describe("semantic reference extraction (statement still being typed)", function()
    local extract = sem._test.extract_references_from_node

    -- The grammar closes no `statement` until the syntax is complete, so an
    -- unfinished UPDATE arrives as a root-level ERROR. Reading only
    -- `statement` nodes dropped the target table, and every column typed so
    -- far went unchecked -- the table's own columns were then reported
    -- missing on the next edit.
    local function extract_from_roots(sql)
      local buf = make_buf({ sql })
      local parser = assert(vim.treesitter.get_parser(buf, "sql"))
      local tbl_names = {}
      for child in parser:parse()[1]:root():iter_children() do
        for _, t in ipairs(extract(child, buf).tables) do tbl_names[#tbl_names + 1] = t.name end
      end
      return tbl_names
    end

    it("extracts the target of an unfinished UPDATE", function()
      assert.same({ "users" }, extract_from_roots("update users set  where ;"))
      assert.same({ "users" }, extract_from_roots("update users set "))
      assert.same({ "users" }, extract_from_roots("UPDATE users SET "))
    end)

    it("extracts the target from a qualified or aliased UPDATE", function()
      assert.same({ "users" }, extract_from_roots("UPDATE public.users SET "))
      assert.same({ "users" }, extract_from_roots("UPDATE users u SET "))
    end)

    it("does not take the SET/WHERE keyword for a table", function()
      assert.same({}, extract_from_roots("UPDATE SET users;"))
      assert.same({}, extract_from_roots("set names utf8;"))
    end)
  end)

  describe("semantic catalog exemption", function()
    local is_catalog_ref = sem._test.is_catalog_ref

    it("exempts prefixed built-in system schemas for any dialect", function()
      assert.is_true(is_catalog_ref("pg_catalog", "pg_tables", "postgres"))
      assert.is_true(is_catalog_ref("information_schema", "tables", nil))
      assert.is_true(is_catalog_ref("mysql", "user", "mysql"))
      assert.is_true(is_catalog_ref("performance_schema", "events", "mysql"))
    end)

    it("exempts unqualified pg_catalog relations only for postgres", function()
      assert.is_true(is_catalog_ref(nil, "pg_tables", "postgres"))
      assert.is_true(is_catalog_ref(nil, "PG_STAT_ACTIVITY", "postgres"))
      assert.is_false(is_catalog_ref(nil, "pg_tables", "mysql"))
      assert.is_false(is_catalog_ref(nil, "pg_tables", nil), "unknown dialect stays conservative")
    end)

    it("keeps regular user tables validatable", function()
      assert.is_false(is_catalog_ref(nil, "users", "postgres"))
      assert.is_false(is_catalog_ref(nil, "orders", "mysql"))
      assert.is_false(is_catalog_ref("blog", "orders", "postgres"))
    end)

    it("exempts SQLite internal tables without needing a dialect", function()
      assert.is_true(is_catalog_ref(nil, "sqlite_master", "sqlite"))
      assert.is_true(is_catalog_ref(nil, "sqlite_stat1", nil))
      assert.is_false(is_catalog_ref(nil, "users", "sqlite"))
    end)
  end)
end

describe("digit-fragment highlight (syntax.highlight_digit_prefix_fragments)", function()
  local syntax = require("poste-db.syntax")
  --- Byte spans (from, to) covered by digit-fragment extmarks in a buffer.
  local function fragment_spans(buf)
    local ns = vim.api.nvim_create_namespace("poste_db_digit_fragment")
    local spans = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local details = m[4] or {}
      spans[#spans + 1] = { m[3], details.end_col }
    end
    table.sort(spans, function(a, b) return a[1] < b[1] end)
    return spans
  end
  local function name_span(line, name)
    local pos = line:find(name, 1, true) - 1
    return pos, pos + #name
  end

  it("recolors the digit prefix for mysql dialect", function()
    local sql = "SELECT * FROM 123_abc;"
    local buf = make_buf({ sql })
    syntax.highlight_digit_prefix_fragments(buf, "mysql")
    local s, e = name_span(sql, "123_abc")
    assert.same({ { s, e } }, fragment_spans(buf))
  end)

  it("recolors the digit prefix for mariadb dialect", function()
    local sql = "SELECT * FROM 2024_log;"
    local buf = make_buf({ sql })
    syntax.highlight_digit_prefix_fragments(buf, "mariadb")
    local s, e = name_span(sql, "2024_log")
    assert.same({ { s, e } }, fragment_spans(buf))
  end)

  it("recolors both sides of a JOIN", function()
    local sql = "SELECT * FROM 23_tablename JOIN 2024_log l ON l.id = x.id;"
    local buf = make_buf({ sql })
    syntax.highlight_digit_prefix_fragments(buf, "mysql")
    local s1, e1 = name_span(sql, "23_tablename")
    local s2, e2 = name_span(sql, "2024_log")
    assert.same({ { s1, e1 }, { s2, e2 } }, fragment_spans(buf))
  end)

  it("leaves whitespace-separated all-digit names untouched for mysql", function()
    local sql = "SELECT * FROM 234 _tablename;"
    local buf = make_buf({ sql })
    syntax.highlight_digit_prefix_fragments(buf, "mysql")
    assert.same({}, fragment_spans(buf))
  end)

  it("keeps the error color for postgres dialect", function()
    local sql = "SELECT * FROM 123_abc;"
    local buf = make_buf({ sql })
    syntax.highlight_digit_prefix_fragments(buf, "postgres")
    assert.same({}, fragment_spans(buf))
  end)

  it("keeps the error color when dialect is unknown", function()
    local sql = "SELECT * FROM 123_abc;"
    local buf = make_buf({ sql })
    syntax.highlight_digit_prefix_fragments(buf)
    assert.same({}, fragment_spans(buf))
  end)

  it("clears previous extmarks on re-run", function()
    local sql = "SELECT * FROM 123_abc;"
    local buf = make_buf({ sql })
    syntax.highlight_digit_prefix_fragments(buf, "mysql")
    assert.is_true(#fragment_spans(buf) > 0)
    syntax.highlight_digit_prefix_fragments(buf, "postgres")
    assert.same({}, fragment_spans(buf))
  end)
end)

describe("known-error-construct re-highlight (syntax.highlight_known_error_constructs)", function()
  local syntax = require("poste-db.syntax")
  local ns = vim.api.nvim_create_namespace("poste_db_error_construct")

  local function construct_marks(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local kinds = {}
    for _, m in ipairs(marks) do
      kinds[#kinds + 1] = (m[4] or {}).hl_group
    end
    return kinds
  end

  it("recolors a PRAGMA error region as normal + keyword", function()
    local buf = make_buf({ "PRAGMA journal_mode;" })
    syntax.highlight_known_error_constructs(buf)
    local kinds = construct_marks(buf)
    assert.is_true(vim.tbl_contains(kinds, "Normal"), "base must clear the @error red")
    assert.is_true(vim.tbl_contains(kinds, "Statement"), "PRAGMA keyword must be highlighted")
  end)

  it("recolors EXPLAIN QUERY PLAN and a string INSIDE a VALUES cascade", function()
    local buf = make_buf({ "EXPLAIN QUERY PLAN SELECT * FROM o;" })
    syntax.highlight_known_error_constructs(buf)
    local kinds = construct_marks(buf)
    assert.is_true(vim.tbl_contains(kinds, "Normal"))
    assert.is_true(vim.tbl_contains(kinds, "Statement"), "QUERY/PLAN keywords must be highlighted")
  end)

  it("clears marks on re-run when the construct disappears", function()
    local buf = make_buf({ "PRAGMA journal_mode;" })
    syntax.highlight_known_error_constructs(buf)
    assert.is_true(#construct_marks(buf) > 0)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT 1;" })
    vim.wait(500, function() return #(vim.treesitter.get_parser(buf, "sql"):parse()[1]:root():named_children()) > 0 end)
    syntax.highlight_known_error_constructs(buf)
    assert.same({}, construct_marks(buf))
  end)

  it("recolors CREATE OR REPLACE TABLE", function()
    local buf = make_buf({ "CREATE OR REPLACE TABLE test_mariadb (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(100));" })
    syntax.highlight_known_error_constructs(buf)
    local kinds = construct_marks(buf)
    assert.is_true(vim.tbl_contains(kinds, "Normal"))
    assert.is_true(vim.tbl_contains(kinds, "Statement"), "CREATE/OR/REPLACE/TABLE/INT/PRIMARY etc must be highlighted")
  end)

  it("recolors INVISIBLE column attribute", function()
    local buf = make_buf({ "CREATE TABLE t (id INT, c VARCHAR(50) INVISIBLE);" })
    syntax.highlight_known_error_constructs(buf)
    local kinds = construct_marks(buf)
    assert.is_true(vim.tbl_contains(kinds, "Normal"))
    assert.is_true(vim.tbl_contains(kinds, "Statement"), "INVISIBLE keyword must be highlighted")
  end)

  it("recolors the mssql SELECT TOP dot fragment", function()
    local buf = make_buf({ "SELECT TOP (10) o.id FROM dbo.orders o;" })
    syntax.highlight_known_error_constructs(buf)
    assert.is_true(vim.tbl_contains(construct_marks(buf), "Normal"),
      "the .id fragment must not stay @error red")
  end)

  it("recolors the mssql OFFSET-FETCH tail", function()
    local buf = make_buf({
      "SELECT o.id FROM dbo.orders o ORDER BY o.id",
      "OFFSET 10 ROWS FETCH NEXT 10 ROWS ONLY;",
    })
    syntax.highlight_known_error_constructs(buf)
    local kinds = construct_marks(buf)
    assert.is_true(vim.tbl_contains(kinds, "Normal"))
    assert.is_true(vim.tbl_contains(kinds, "Statement"), "OFFSET/FETCH/ROWS keywords must be highlighted")
  end)

  it("recolors the LIMIT comma pagination fragment", function()
    local buf = make_buf({ "SELECT id, name FROM users LIMIT 1, 10;" })
    syntax.highlight_known_error_constructs(buf)
    local kinds = construct_marks(buf)
    assert.is_true(vim.tbl_contains(kinds, "Normal"), "the , 10 fragment must not stay @error red")
    assert.is_true(vim.tbl_contains(kinds, "Number"), "the count literal must render as a number")
  end)

  -- While an UPDATE is being typed the grammar closes no `statement`, so the
  -- whole line is one root-level ERROR and nvim paints it red.
  it("recolors an unfinished UPDATE (UPDATE t SET ▮)", function()
    local buf = make_buf({ "UPDATE users SET " })
    syntax.highlight_known_error_constructs(buf)
    local kinds = construct_marks(buf)
    assert.is_true(vim.tbl_contains(kinds, "Normal"), "the unfinished UPDATE must not stay @error red")
    assert.is_true(vim.tbl_contains(kinds, "Statement"), "UPDATE/SET keywords must be highlighted")
  end)

  it("recolors an unfinished UPDATE with an empty SET/WHERE", function()
    local buf = make_buf({ "update table_name set  where ;" })
    syntax.highlight_known_error_constructs(buf)
    local kinds = construct_marks(buf)
    assert.is_true(vim.tbl_contains(kinds, "Normal"))
    assert.is_true(vim.tbl_contains(kinds, "Statement"))
  end)

  it("keeps a misspelt UPDATE target red", function()
    -- `SET users` parses as the table name here, so the SET clause is not
    -- the unfinished one: the statement is genuinely wrong.
    local buf = make_buf({ "UPDATE SET users;" })
    syntax.highlight_known_error_constructs(buf)
    assert.same({}, construct_marks(buf), "a missing table name must stay @error")
  end)

  it("keeps an invalid SET DEFAULT red", function()
    -- Also one ERROR node, but the SET list was written: this is a mistake,
    -- not a clause still being typed.
    local buf = make_buf({ "UPDATE users SET DEFAULT;" })
    syntax.highlight_known_error_constructs(buf)
    assert.same({}, construct_marks(buf), "SET DEFAULT is a real error")
  end)

  it("does not treat a session SET statement as an unfinished UPDATE", function()
    local buf = make_buf({ "SET SESSION x = 1;" })
    syntax.highlight_known_error_constructs(buf)
    assert.same({}, construct_marks(buf))
  end)
end)

describe("USE/SET boundary detection", function()
  it("finds span for USE statement", function()
    local buf = make_buf({ "use inventory;", "SELECT 1;" })
    local span = ts_stmt.find_stmt_span(buf, 1)
    assert.same({ 1, 1 }, span)
  end)

  it("finds span for SET statement", function()
    local buf = make_buf({ "SET NAMES utf8;", "SELECT 1;" })
    local span = ts_stmt.find_stmt_span(buf, 1)
    assert.same({ 1, 1 }, span)
  end)

  it("includes USE in all statement lines", function()
    local buf = make_buf({ "use inventory;", "SELECT 1;", "SELECT 2;" })
    local lines = ts_stmt.find_all_stmt_lines(buf, 1, 3)
    assert.same({ 1, 2, 3 }, lines)
  end)
end)
