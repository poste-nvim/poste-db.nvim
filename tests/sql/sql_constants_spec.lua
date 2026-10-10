local const = require("poste-db.constants")

describe("constants helpers", function()
  it("detects section markers", function()
    assert.is_true(const.is_section_marker("###"))
    assert.is_true(const.is_section_marker("   ### refresh"))
    assert.is_false(const.is_section_marker("-- @connection foo"))
  end)

  it("matches directive values", function()
    assert.equals("analytics", const.match_directive("-- @connection analytics", const.DIRECTIVE_CONNECTION))
    assert.equals("blog", const.match_directive("  -- @database blog", const.DIRECTIVE_DATABASE))
    assert.is_nil(const.match_directive("###", const.DIRECTIVE_CONNECTION))
  end)

  it("tells a directive line apart from the name it declares", function()
    -- `%s+(.+)` accepts a whitespace-only tail, so `-- @connection   ` (the
    -- placeholder line an editor left with its trailing blanks) matched and
    -- trimmed to "". Readers that treated the match as "this level names
    -- something" then ran the block against the server default instead of the
    -- file-level database. An empty value declares nothing: directive_value
    -- answers nil, while match_directive still sees the line — which is what
    -- rewriting one in place needs, so the file does not end up with two
    -- `-- @connection` lines to choose between.
    assert.equals("analytics", const.directive_value("-- @connection analytics", const.DIRECTIVE_CONNECTION))
    assert.equals("analytics", const.directive_value("-- @connection   analytics", const.DIRECTIVE_CONNECTION))
    assert.is_nil(const.directive_value("-- @connection   ", const.DIRECTIVE_CONNECTION))
    assert.is_nil(const.directive_value("-- @database\t\t", const.DIRECTIVE_DATABASE))
    assert.is_nil(const.directive_value("-- @database", const.DIRECTIVE_DATABASE))
    assert.is_nil(const.directive_value(nil, const.DIRECTIVE_DATABASE))
    assert.equals(" ", const.match_directive("-- @connection   ", const.DIRECTIVE_CONNECTION))
    -- the BOM still does not hide the name (strip_leading_bom is shared)
    assert.equals("blog", const.directive_value("\xef\xbb\xbf-- @database blog", const.DIRECTIVE_DATABASE))
  end)

  it("sees line-1 anchors through a leading UTF-8 BOM", function()
    -- A BOM-writing editor glues U+FEFF to the buffer's first line, where it
    -- is not `%s`: the anchored matchers went blind exactly when the directive
    -- or the section marker sat on line 1 (the Rust CLI's
    -- extract_connection_directive had the same hole, fixed in lockstep).
    local bom = "\xef\xbb\xbf"
    assert.equals("analytics", const.match_directive(bom .. "-- @connection analytics", const.DIRECTIVE_CONNECTION))
    assert.is_true(const.is_directive_comment(bom .. "-- @connection analytics"))
    assert.is_true(const.is_section_marker(bom .. "### refresh"))
    -- a BOM mid-line is data and must not manufacture a match
    assert.is_nil(const.match_directive("-- " .. bom .. "@connection analytics", const.DIRECTIVE_CONNECTION))
    assert.is_false(const.is_section_marker("-- " .. bom .. "###"))
    -- non-strings keep refusing
    assert.is_nil(const.match_directive(nil, const.DIRECTIVE_CONNECTION))
    assert.is_false(const.is_section_marker(nil))
    assert.is_false(const.is_directive_comment(nil))
  end)

  it("exposes shared numeric defaults", function()
    assert.equals(0.7, const.FLOAT_WIDTH_RATIO)
    assert.equals(120, const.FLOAT_MAX_WIDTH)
    assert.equals(5000, const.EDIT_MAX_ROWS)
    assert.equals(1000, const.LOG_MAX_ENTRIES)
    assert.equals(50, const.YANK_PREVIEW_CHARS)
  end)

  it("lists built-in system schemas exempt from schema validation", function()
    assert.is_true(const.SYSTEM_SCHEMAS["pg_catalog"])
    assert.is_true(const.SYSTEM_SCHEMAS["information_schema"])
    assert.is_true(const.SYSTEM_SCHEMAS["mysql"])
    assert.is_true(const.SYSTEM_SCHEMAS["performance_schema"])
    assert.is_true(const.SYSTEM_SCHEMAS["sys"])
    assert.is_true(const.SYSTEM_SCHEMAS["guest"], "SQL Server guest schema is exempt")
    assert.is_true(const.SYSTEM_SCHEMAS["system"], "ClickHouse system database is exempt")
    assert.is_nil(const.SYSTEM_SCHEMAS["blog"], "regular databases are not exempt")
  end)

  it("recognizes PostgreSQL catalog relation names", function()
    assert.is_true(const.is_pg_catalog_name("pg_tables"))
    assert.is_true(const.is_pg_catalog_name("pg_stat_activity"))
    assert.is_true(const.is_pg_catalog_name("PG_TABLES"), "unquoted refs fold to lowercase in postgres")
    assert.is_false(const.is_pg_catalog_name("users"))
    assert.is_false(const.is_pg_catalog_name("orders"))
  end)

  it("lists static postgres catalog relations for unqualified completion", function()
    assert.is_true(#const.PG_CATALOG_TABLES > 50, "expected a substantial catalog list")
    for _, t in ipairs(const.PG_CATALOG_TABLES) do
      assert.is_true(const.is_pg_catalog_name(t), t .. " must satisfy the pg_ predicate")
    end
  end)

  it("recognizes SQLite internal table names", function()
    assert.is_true(const.is_sqlite_system_name("sqlite_master"))
    assert.is_true(const.is_sqlite_system_name("sqlite_sequence"))
    assert.is_true(const.is_sqlite_system_name("sqlite_stat1"))
    assert.is_true(const.is_sqlite_system_name("SQLITE_MASTER"), "case-insensitive, reserved prefix")
    assert.is_false(const.is_sqlite_system_name("users"))
    assert.is_false(const.is_sqlite_system_name("sqlite-ish_table"))
  end)

  it("whitelists supported SQL dialects and rejects satellite ones", function()
    assert.is_true(const.is_sql_dialect("postgres"))
    assert.is_true(const.is_sql_dialect("mysql"))
    assert.is_true(const.is_sql_dialect("mariadb"))
    assert.is_true(const.is_sql_dialect("sqlite"))
    assert.is_true(const.is_sql_dialect("mssql"))
    assert.is_true(const.is_sql_dialect("clickhouse"))
    assert.is_true(const.is_sql_dialect(nil), "nil dialect defaults like postgres")
    assert.is_false(const.is_sql_dialect("redis"))
    assert.is_false(const.is_sql_dialect("elasticsearch"))
  end)

  it("classifies transactional dialects (clickhouse is not one)", function()
    assert.is_true(const.supports_transactions("postgres"))
    assert.is_true(const.supports_transactions("mysql"))
    assert.is_true(const.supports_transactions("mariadb"))
    assert.is_true(const.supports_transactions("sqlite"))
    assert.is_true(const.supports_transactions("mssql"))
    assert.is_true(const.supports_transactions(nil), "nil dialect defaults like postgres")
    assert.is_false(const.supports_transactions("clickhouse"))
  end)

  it("normalizes dialect aliases to their base dialect", function()
    assert.equals("mysql", const.normalize_dialect("mariadb"))
    for _, alias in ipairs({ "cockroachdb", "yugabyte", "aurora-postgres", "neon", "supabase", "timescaledb" }) do
      assert.equals("postgres", const.normalize_dialect(alias), alias .. " must normalize to postgres")
    end
    for _, alias in ipairs({ "tidb", "singlestore", "aurora-mysql", "vitess", "planetscale" }) do
      assert.equals("mysql", const.normalize_dialect(alias), alias .. " must normalize to mysql")
    end
    assert.equals("postgres", const.normalize_dialect("postgres"), "base names pass through")
    assert.equals("nosuchdialect", const.normalize_dialect("nosuchdialect"), "unknown names pass through")
    assert.is_nil(const.normalize_dialect(nil))
  end)

  it("every alias maps to a supported base dialect", function()
    for alias, base in pairs(const.DIALECT_ALIASES) do
      assert.is_true(const.SUPPORTED_DIALECTS[base] == true,
        alias .. " aliases " .. base .. " which must be in SUPPORTED_DIALECTS")
    end
  end)

  it("accepts aliases in is_sql_dialect", function()
    assert.is_true(const.is_sql_dialect("cockroachdb"))
    assert.is_true(const.is_sql_dialect("planetscale"))
    assert.is_true(const.is_sql_dialect("timescaledb"))
    assert.is_false(const.is_sql_dialect("redis"))
  end)

  it("accepts the postgresql spelling as a postgres alias", function()
    assert.equals("postgres", const.normalize_dialect("postgresql"))
    assert.is_true(const.is_sql_dialect("postgresql"))
  end)

  it("sniffs the base dialect from a connection URL prefix", function()
    assert.equals("sqlite", const.dialect_from_url("sqlite:/data/app.db?mode=rwc"))
    assert.equals("sqlite", const.dialect_from_url("sqlite::memory:"))
    assert.equals("postgres", const.dialect_from_url("postgres://alice@h:5432/blog"))
    assert.equals("postgres", const.dialect_from_url("postgresql://alice@h/blog"))
    assert.equals("mysql", const.dialect_from_url("mysql://root@h:3306/shop"))
    assert.equals("mysql", const.dialect_from_url("mariadb://root@h/shop"))
    assert.equals("mssql", const.dialect_from_url("mssql://sa@h:1433/playground"))
    assert.equals("clickhouse", const.dialect_from_url("clickhouse://default@h:8123/playground"))
    assert.is_nil(const.dialect_from_url("redis://localhost:6379"), "satellite schemes are not SQL dialects")
    assert.is_nil(const.dialect_from_url("oracle://h/free"))
    assert.is_nil(const.dialect_from_url(nil))
  end)

  it("exposes per-dialect default ports", function()
    assert.equals(5432, const.default_port("postgres"))
    assert.equals(3306, const.default_port("mysql"))
    assert.equals(1433, const.default_port("mssql"))
    assert.equals(8123, const.default_port("clickhouse"))
    assert.is_nil(const.default_port("sqlite"), "sqlite is file-based")
    assert.is_nil(const.default_port("nosuch"))
    assert.is_nil(const.default_port(nil))
  end)
end)
