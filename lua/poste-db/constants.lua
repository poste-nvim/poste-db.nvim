local M = {}

-- A UTF-8 BOM (U+FEFF). A file saved by a BOM-writing editor (Windows notepad,
-- Neovim with 'bomb' off) keeps it glued to the buffer's first line, where it
-- is invisible but is not `%s` — every anchored `^%s*` matcher below went
-- blind on line 1: the `-- @connection` directive, the directive-comment skip
-- in statement extraction, and the `###` section marker. The Rust CLI strips
-- the same prefix in strip_directives / extract_connection_directive.
local BOM = "\xef\xbb\xbf"

--- Drop a leading BOM (only line 1 of a buffer/file can carry one).
--- @param line string
--- @return string
function M.strip_leading_bom(line)
  if line:sub(1, #BOM) == BOM then
    return line:sub(#BOM + 1)
  end
  return line
end

M.DIRECTIVE_CONNECTION = "connection"
M.DIRECTIVE_DATABASE = "database"
M.DIRECTIVE_PROTOCOL = "protocol"
M.SECTION_MARKER = "###"
M.DIRECTIVE_PREFIX_PATTERN = "^%s*%-%-%s*@"
M.SECTION_MARKER_PATTERN = "^%s*###"
M.PLUGIN_TITLE = "PosteDb"
M.TITLE = M.PLUGIN_TITLE
M.EDIT_CONFLICT_MSG = "You have unsaved edits. Commit or discard them first."
M.RAW_MODE_WINBAR = " Raw Mode "

M.FLOAT_WIDTH_RATIO = 0.7
M.FLOAT_MAX_WIDTH = 120
M.FLOAT_HEIGHT_RATIO = 0.6

--- Dataset split: share of the editor height at creation and on resize.
M.DATASET_HEIGHT_RATIO = 0.4
--- Lower bound the dataset window is kept to so it never collapses to just
--- its winbar after editor/window resizes.
M.DATASET_MIN_HEIGHT = 4


M.INTROSPECT_FLOAT_WIDTH_RATIO = 0.7
M.INTROSPECT_FLOAT_MAX_WIDTH = 100
M.INTROSPECT_FLOAT_WIDTH_PADDING = 4
M.INTROSPECT_FLOAT_HEIGHT_RATIO = 0.5
M.INTROSPECT_FLOAT_MIN_HEIGHT = 3
M.INTROSPECT_FLOAT_EXTRA_HEIGHT = 2

M.EDIT_MAX_ROWS = 5000
M.EDITOR_PAGE_SIZE = 50

M.LOG_MAX_ENTRIES = 1000
M.LOG_TRIM_EVERY = 10
M.HIGHLIGHTS_IMMEDIATE_ROW_LIMIT = 1000
M.YANK_PREVIEW_CHARS = 50

-- vendored from poste.nvim@5b3759e lua/poste/constants.lua — the entries
-- consumed by this plugin's vendored indicators.lua and copy_progress.lua
-- (family dissolution)
M.SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
M.SPINNER_INTERVAL_MS = 100
M.INDICATOR_NS_NAME = "poste_indicator"
M.SIGN_GROUP_NAME = "poste_sg_4a7f"

M.STATUSLINE_TRUNC_WIDTH = 120
M.MAX_COL_WIDTH = 30
M.IMPORT_PREVIEW_HEIGHT_RATIO = 0.6

--- SQL dialects poste-db knows how to connect to. A shared connections.toml
--- may also carry sections for satellite plugins (redis, elasticsearch, ...);
--- poste-db must not enumerate those, only its own set.
M.SUPPORTED_DIALECTS = {
  postgres = true,
  mysql = true,
  mariadb = true,
  sqlite = true,
  mssql = true,
  clickhouse = true,
}

--- Dialects whose engine has no transaction semantics. The Rust exec-file
--- rejects `--mode transaction` for these ("ClickHouse has no transactions"),
--- so edit commit falls back to per-statement greedy execution there.
M.DIALECTS_WITHOUT_TRANSACTIONS = {
  clickhouse = true,
}

--- Dialect-name aliases that normalize to a base dialect before any handling
--- (mariadb precedent). Everything downstream — whitelist checks, URL
--- building, icons, completion, the Rust binary — only ever sees base names,
--- so an alias costs one entry here and nothing else. Values must be keys of
--- SUPPORTED_DIALECTS.
M.DIALECT_ALIASES = {
  mariadb = "mysql",
  postgresql = "postgres",
  cockroachdb = "postgres",
  yugabyte = "postgres",
  ["aurora-postgres"] = "postgres",
  neon = "postgres",
  supabase = "postgres",
  timescaledb = "postgres",
  tidb = "mysql",
  singlestore = "mysql",
  ["aurora-mysql"] = "mysql",
  vitess = "mysql",
  planetscale = "mysql",
}

--- Resolve a dialect alias to its base dialect. Non-strings and unknown
--- names pass through unchanged.
--- @param dialect any
--- @return any
function M.normalize_dialect(dialect)
  if type(dialect) ~= "string" then return dialect end
  return M.DIALECT_ALIASES[dialect] or dialect
end

--- True when the connection dialect is one poste-db can handle. Aliases are
--- accepted (they normalize to a supported base). A nil dialect is allowed
--- (defaults behave like postgres elsewhere).
--- @param dialect any
--- @return boolean
function M.is_sql_dialect(dialect)
  if dialect == nil then return true end
  return M.SUPPORTED_DIALECTS[M.normalize_dialect(dialect)] == true
end

--- True when the dialect can run BEGIN/COMMIT/ROLLBACK. A nil dialect
--- (defaults behave like postgres elsewhere) counts as transactional.
--- @param dialect any
--- @return boolean
function M.supports_transactions(dialect)
  if dialect == nil then return true end
  return not M.DIALECTS_WITHOUT_TRANSACTIONS[M.normalize_dialect(dialect)]
end

--- Connection URL scheme prefixes → base dialect, ordered, first match wins
--- (the prefixes are mutually exclusive, so the order is not load-bearing —
--- but it is the order the Rust mirror reads too).
--- The single source for URL sniffing (session_conn, completion/data,
--- semantic_diagnostics) and, inverted, for URL building in connections.lua.
--- Rust mirror: `Protocol::from_sql_url` in poste.nvim's
--- crates/poste-core/src/request.rs — one chain now (exec_file, session and
--- introspect all call it), pinned by that file's scheme test. A scheme added
--- here and not there fails only when a connection runs.
M.URL_SCHEMES = {
  { "^sqlite:", "sqlite" },
  { "^postgres://", "postgres" },
  { "^postgresql://", "postgres" },
  { "^mysql://", "mysql" },
  { "^mariadb://", "mysql" },
  { "^mssql://", "mssql" },
  { "^clickhouse://", "clickhouse" },
}

--- Sniff the base dialect from a connection URL prefix. nil when the URL
--- does not match any known scheme.
--- @param url string|nil
--- @return string|nil
function M.dialect_from_url(url)
  if type(url) ~= "string" then return nil end
  for _, scheme in ipairs(M.URL_SCHEMES) do
    if url:match(scheme[1]) then return scheme[2] end
  end
  return nil
end

--- Per-dialect default TCP port, used by URL building and display fallbacks.
--- sqlite is file-based and has no port.
M.DIALECT_DEFAULT_PORTS = {
  postgres = 5432,
  mysql = 3306,
  mssql = 1433,
  clickhouse = 8123,
}

--- Default TCP port for a dialect, or nil when it has none (sqlite).
--- @param dialect string|nil
--- @return number|nil
function M.default_port(dialect)
  if dialect == nil then return nil end
  return M.DIALECT_DEFAULT_PORTS[dialect]
end

--- Database-engine built-in schemas/databases holding catalog tables
--- (pg_catalog.pg_tables, mysql.user, ...) whose contents are version-specific
--- and not returned by normal schema introspection. Lowercased keys.
M.SYSTEM_SCHEMAS = {
  pg_catalog = true,
  information_schema = true,
  mysql = true,
  performance_schema = true,
  sys = true,
  pg_toast = true,
  -- SQL Server built-in schemas (sys also exists in MySQL)
  guest = true,
  -- ClickHouse system database (namespace, not a user schema)
  system = true,
}

--- True when `name` looks like a PostgreSQL system catalog relation
--- (pg_tables, pg_stat_activity, ...). pg_catalog is implicitly in the search
--- path, so these resolve even when written without a prefix (`FROM pg_tables`).
--- Unquoted refs fold to lowercase in postgres, so the check is case-insensitive.
--- @param name string|nil
--- @return boolean
function M.is_pg_catalog_name(name)
  return type(name) == "string" and name:lower():match("^pg_[%w_]*$") ~= nil
end

--- True when `name` is a SQLite internal table (sqlite_master,
--- sqlite_sequence, sqlite_stat1..4, ...). These live in the `main` schema and
--- are never returned by introspection. The `sqlite_` prefix is reserved by
--- SQLite (user tables cannot use it), so the check is case-insensitive and
--- needs no dialect gate.
--- @param name string|nil
--- @return boolean
function M.is_sqlite_system_name(name)
  return type(name) == "string" and name:lower():match("^sqlite_%w+$") ~= nil
end

--- Static list of commonly referenced PostgreSQL pg_catalog relations (tables
--- and views), used to complete unqualified references (`FROM pg_tab`).
--- Version-specific and dynamic ones (pg_toast_*, pg_temp_*) are omitted.
M.PG_CATALOG_TABLES = {
  "pg_aggregate", "pg_am", "pg_amop", "pg_amproc", "pg_attrdef",
  "pg_attribute", "pg_auth_members", "pg_authid",
  "pg_available_extension_versions", "pg_available_extensions",
  "pg_cast", "pg_class", "pg_collation", "pg_config", "pg_constraint",
  "pg_conversion", "pg_cursors", "pg_database", "pg_db_role_setting",
  "pg_default_acl", "pg_depend", "pg_description", "pg_enum",
  "pg_event_trigger", "pg_extension", "pg_file_settings",
  "pg_foreign_data_wrapper", "pg_foreign_server", "pg_foreign_table",
  "pg_group", "pg_hba_file_rules", "pg_ident_file_mappings",
  "pg_index", "pg_indexes", "pg_inherits", "pg_init_privs",
  "pg_language", "pg_largeobject", "pg_largeobject_metadata",
  "pg_locks", "pg_matviews", "pg_namespace",
  "pg_notification_queue_usage", "pg_opclass", "pg_operator",
  "pg_opfamily", "pg_partitioned_table", "pg_policy",
  "pg_prepared_statements", "pg_prepared_xacts", "pg_proc",
  "pg_publication", "pg_publication_namespace", "pg_publication_rel",
  "pg_publication_tables", "pg_range", "pg_replication_origin",
  "pg_rewrite", "pg_roles", "pg_rules", "pg_seclabel",
  "pg_sequence", "pg_sequences", "pg_settings", "pg_shadow",
  "pg_shdepend", "pg_shdescription", "pg_shseclabel",
  "pg_stat_activity", "pg_stat_all_indexes", "pg_stat_all_tables",
  "pg_stat_archiver", "pg_stat_bgwriter", "pg_stat_checksums",
  "pg_stat_database", "pg_stat_database_conflicts", "pg_stat_io",
  "pg_stat_progress_analyze", "pg_stat_progress_basebackup",
  "pg_stat_progress_cluster", "pg_stat_progress_copy",
  "pg_stat_progress_create_index", "pg_stat_progress_vacuum",
  "pg_stat_replication", "pg_stat_replication_slots", "pg_stat_slru",
  "pg_stat_ssl", "pg_stat_subscription", "pg_stat_subscription_stats",
  "pg_stat_sys_indexes", "pg_stat_sys_tables",
  "pg_stat_user_functions", "pg_stat_user_indexes", "pg_stat_user_tables",
  "pg_stat_wal", "pg_stat_wal_receiver",
  "pg_stat_xact_all_tables", "pg_stat_xact_sys_tables",
  "pg_stat_xact_user_functions", "pg_stat_xact_user_tables",
  "pg_statio_all_indexes", "pg_statio_all_tables",
  "pg_statio_sys_indexes", "pg_statio_sys_tables",
  "pg_statio_user_indexes", "pg_statio_user_tables",
  "pg_statistic", "pg_statistic_ext", "pg_statistic_ext_data",
  "pg_stats", "pg_stats_ext", "pg_stats_ext_exprs",
  "pg_subscription", "pg_subscription_rel",
  "pg_tables", "pg_tablespace", "pg_timezone_abbrevs",
  "pg_timezone_names", "pg_transform", "pg_trigger",
  "pg_ts_config", "pg_ts_config_map", "pg_ts_dict", "pg_ts_parser",
  "pg_ts_template", "pg_type", "pg_user", "pg_user_mapping",
  "pg_user_mappings", "pg_views",
}

function M.is_section_marker(line)
  return type(line) == "string"
    and M.strip_leading_bom(line):match(M.SECTION_MARKER_PATTERN) ~= nil
end

function M.is_directive_comment(line)
  return type(line) == "string"
    and M.strip_leading_bom(line):match(M.DIRECTIVE_PREFIX_PATTERN) ~= nil
end

function M.match_directive(line, directive_name)
  if type(line) ~= "string" or not directive_name or directive_name == "" then
    return nil
  end
  local pattern = "^%s*%-%-%s*@" .. vim.pesc(directive_name) .. "%s+(.+)"
  return M.strip_leading_bom(line):match(pattern)
end

--- The name a `-- @connection` / `-- @database` line declares, trimmed, or nil
--- when it declares none. `%s+(.+)` accepts a whitespace-only tail, so a line
--- authored as a placeholder (`-- @database   `, with the trailing spaces an
--- editor kept) matched and trimmed to `""` — and callers that treat the match
--- as "this level names something" let that empty string override the
--- file-level directive above it and the runtime connection, running the block
--- against the server's default database instead of the intended one. An empty
--- value is no value, which is also what the CLI does
--- (`extract_connection_directive` in poste.nvim's exec_file.rs: trim, then
--- skip the line when nothing is left), so `:PosteDbRunFile` and the editor now
--- read the same file the same way.
--- Use `match_directive` when the question is "is this a directive line?"
--- (rewriting or removing one — an empty `-- @connection` is still the line to
--- rewrite, and inserting a second one would leave two to choose between).
--- @param line string
--- @param directive_name string
--- @return string|nil
function M.directive_value(line, directive_name)
  local raw = M.match_directive(line, directive_name)
  if not raw then return nil end
  local value = vim.trim(raw)
  if value == "" then return nil end
  return value
end

return M
