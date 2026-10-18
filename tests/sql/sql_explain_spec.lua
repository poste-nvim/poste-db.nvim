local explain = require("poste-db.explain")

describe("explain", function()
  describe("wrap_sql", function()
    it("wraps with the dialect's plan-only form", function()
      assert.equals("EXPLAIN SELECT 1", explain.wrap_sql("postgres", "SELECT 1;"))
      assert.equals("EXPLAIN select 1", explain.wrap_sql("mysql", "select 1"))
      assert.equals("EXPLAIN SELECT 1", explain.wrap_sql("clickhouse", "SELECT 1;"))
      assert.equals("EXPLAIN QUERY PLAN SELECT 1", explain.wrap_sql("sqlite", "SELECT 1;"))
    end)

    it("treats nil dialect as postgres", function()
      assert.equals("EXPLAIN SELECT 1", explain.wrap_sql(nil, "SELECT 1"))
    end)

    it("rejects dialects without a plan-only EXPLAIN", function()
      local wrapped, err = explain.wrap_sql("mssql", "SELECT 1")
      assert.is_nil(wrapped)
      assert.truthy(err:find("mssql"))
    end)

    it("strips one trailing semicolon and rejects multi-statement text", function()
      assert.equals("EXPLAIN SELECT 1", explain.wrap_sql("postgres", "  SELECT 1 ;  "))
      local wrapped, err = explain.wrap_sql("postgres", "SELECT 1; SELECT 2;")
      assert.is_nil(wrapped)
      assert.truthy(err:find("single statement"))
    end)

    -- The single-statement check used to be a plain `find(";")`, so it also
    -- counted separators that are part of the statement's own text.
    it("ignores semicolons inside quoted literals", function()
      assert.equals("EXPLAIN SELECT 'a;b'", explain.wrap_sql("postgres", "SELECT 'a;b'"))
      assert.equals("EXPLAIN SELECT \"a;b\" FROM `t;x`",
        explain.wrap_sql("mysql", 'SELECT "a;b" FROM `t;x`'))
      -- a doubled quote is an escaped quote inside the literal, not its close
      assert.equals("EXPLAIN SELECT 'it''s; ok'", explain.wrap_sql("postgres", "SELECT 'it''s; ok'"))
      assert.equals("EXPLAIN SELECT '$x;'", explain.wrap_sql("postgres", "SELECT '$x;'"))
    end)

    it("ignores semicolons in comments and dollar-quoted bodies", function()
      assert.equals("EXPLAIN SELECT 1 -- note; end",
        explain.wrap_sql("postgres", "SELECT 1 -- note; end"))
      assert.equals("EXPLAIN SELECT 1 /* a;b */", explain.wrap_sql("postgres", "SELECT 1 /* a;b */"))
      local plpgsql = "CREATE FUNCTION f() AS $$ BEGIN SELECT 1; END; $$ LANGUAGE plpgsql"
      assert.equals("EXPLAIN " .. plpgsql, explain.wrap_sql("postgres", plpgsql))
      -- $1 placeholders are not dollar-quote tags
      assert.equals("EXPLAIN SELECT $1, $2", explain.wrap_sql("postgres", "SELECT $1, $2"))
    end)

    it("still rejects a real statement break after quoted text", function()
      for _, sql in ipairs({
        "SELECT 'a'; SELECT 2",
        "INSERT INTO t VALUES ('a;b', 'c'); INSERT INTO t VALUES (1)",
        "SELECT $$ a $$ ; SELECT 2",
        "SELECT ';'; SELECT 2",
      }) do
        local wrapped, err = explain.wrap_sql("postgres", sql)
        assert.is_nil(wrapped, sql)
        assert.truthy(err:find("single statement"), sql)
      end
    end)

    it("rejects a break a trailing-backslash literal hides from one reading", function()
      -- postgres closes `'C:\path\'` at the final quote, so the `; SELECT`
      -- after it is real — but the backslash reading escapes that quote and
      -- hides the break inside a phantom literal. The refusal gate runs both
      -- readings; either one seeing a separator refuses (over-flag, never
      -- under).
      local wrapped, err = explain.wrap_sql("postgres", "SELECT 'C:\\path\\'; SELECT 2")
      assert.is_nil(wrapped)
      assert.truthy(err:find("single statement"))
      -- ... while the single statement itself still wraps
      assert.equals("EXPLAIN SELECT 'C:\\path\\' FROM t",
        explain.wrap_sql("postgres", "SELECT 'C:\\path\\' FROM t"))
    end)

    it("rejects empty statements", function()
      local wrapped, err = explain.wrap_sql("postgres", "   ")
      assert.is_nil(wrapped)
      assert.truthy(err:find("no statement"))
    end)
  end)
end)
