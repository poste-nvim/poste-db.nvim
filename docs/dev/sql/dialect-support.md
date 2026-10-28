# Adding a SQL dialect — design and touchpoint checklist

> Revision notes (against the first draft):
> 1. Priorities re-ordered — "high-value work that fits the existing TCP
>    driver architecture first; anything introducing a new transport (HTTP)
>    concentrated into one phase to amortize the infrastructure; data/connection
>    model mismatches last, deferrable".
> 2. §2 alias mechanism settled: follow the mariadb precedent (Lua-side
>    normalization), zero Rust changes; the "name mapping on the Rust side"
>    plan is retired.
> 3. Fact fix: the official `clickhouse` crate is HTTP-only, not "HTTP +
>    native TCP".
> 4. §3.2 test plan split by transport, removing the contradiction between
>    "HTTP dialects make `dialect_for` return Some" and "HTTP still returns
>    None".
> 5. Lua touchpoint list completed: `SYSTEM_SCHEMAS`, the `ident.lua`/`dml.lua`
>    dialect branches, `dialect_icons`, the `ai/system_prompt.lua` dialect
>    list, and the two-sided `to_url()` sync.
> 6. Container plan corrections: MSSQL arm64/health check, Trino tpcds needs a
>    mounted properties file and tpch is read-only, ClickHouse connection port
>    semantics pinned to HTTP 8123.
> 7. Wording fixes: the URL is BUILT, not parsed; the acceptance criteria's
>    "create db/table" became "list databases/tables".
>
> **Status**: Phase 0 (aliases), Phase 1 (MSSQL), Phase 2 (HTTP transport +
> ClickHouse, including Lua/Rust/containers/playground/diag) evolve directly on
> poste.nvim main (the old `../poste-for-db` worktree flow is retired).

## Background

Dialects poste-db supports today: `postgres` (plus `postgresql` and the PG
family aliases), `mysql` (plus `mariadb` and the MySQL family aliases),
`sqlite`, `mssql`.

Cost distribution (touchpoints verified against the current tree; full list in
the appendix at the end):

- **Lua side** (poste-db.nvim):
  - `constants.lua`: the `SUPPORTED_DIALECTS` allowlist + `SYSTEM_SCHEMAS` +
    the `DIALECT_ALIASES` normalization map + `URL_SCHEMES`/`dialect_from_url`
    sniffing + `DIALECT_DEFAULT_PORTS`
  - `connections.lua`: URL building (consumes `default_port`, scheme-agnostic)
    + `dialect_icons`
  - `ident.lua` / `dml.lua`: dialect branches for identifier quoting and value
    escaping
  - `completion/data.lua`: `tables_db_flag`'s schema/database classification +
    dialect keywords
  - `snippets.lua`: `pick_template` template variants
  - `source_format.lua`: formatter `dialect_map`
  - `ai/system_prompt.lua`: the dialect list prompt
- **Rust side** (poste.nvim, edited directly on main):
  - a `Protocol` enum variant in `poste-core`
  - `sql_connection.rs`'s `ConnectionConfig::to_url()` — **a mirror of Lua's
    `resolve_connection_url`; both sides must move together**
  - driver dispatch (the scheme/dialect chains in `sql_executor/`,
    `exec_file.rs`, `session.rs`, `introspect.rs`)
  - the `Dialect` trait implementation in `sql_dialect.rs` (introspection SQL,
    quoting, ports, type mapping)
- `mariadb` speaks the MySQL wire protocol and is normalized to `mysql` on the
  Lua side (the `DIALECT_ALIASES` precedent).

Architecture note: the `Dialect` trait only encapsulates SQL-dialect
differences (introspection SQL, quoting, ports, type mapping) and is
transport-independent. HTTP is a **transport property**, not grounds to
exclude a dialect from `dialect_for` — SQL-over-HTTP engines like
ClickHouse/Trino can have their own `Dialect` implementations while the
transport layer routes them to the HTTP executor; `dialect_for` still returns
`None` for non-SQL protocols like Redis.

## 1. Priorities

Ordering principle: **high-value work that fits the existing TCP driver
architecture first; anything introducing a new transport (HTTP) concentrated
into one phase to amortize the infrastructure; data/connection model mismatches
last and deferrable.**

| Priority | Dialect | Driver/transport | Effort | Risk | Notes |
|-------|---------|----------|--------|------|------|
| 0 | PG/MySQL compatible family aliases | Reuse existing TCP drivers | ≈0 | none | ✅ landed (§2) |
| 1 | MSSQL / SQL Server | `tiberius` (pure-Rust TCP) | medium | low-mid | ✅ landed. Container pitfalls (arm64 emulation, health check) in §4 |
| 2 | ClickHouse | reqwest, straight HTTP | medium | mid | ✅ landed. **Implementation note**: the official `clickhouse` crate is SELECT-oriented (appends ` FORMAT x` to the SQL, forces `readonly=1`) and cannot run DDL/DML/temp tables/`SET` — so we use reqwest raw HTTP (`default_format=JSON`, meta with column types); this is poste-exec's first HTTP transport and Trino reuses it |
| 3 | Trino | Reuse the reqwest HTTP transport | medium | mid | Mainstream for data-lake federation; Trino only — **Presto is out of scope** (the protocols have diverged; no alias) |
| 4 | DuckDB | `duckdb` crate (links the native libduckdb) | high | high | File mode only (see §4); linking libduckdb is a heavy build and does not match the server connection model. Deferrable; deferring blocks nothing |

## 2. Zero/near-zero-cost dialects (pure aliases, mechanism already landed)

**Mechanism: the mariadb precedent — normalize on the Lua side.**
`constants.lua`'s `DIALECT_ALIASES` (alias → base dialect) +
`connections.lua` normalizing before the allowlist check. **Zero Rust diff** —
by the time anything reaches Rust the alias is already `postgres`/`mysql`.

Design consequences (accepted trade-offs):

- Icons, completion and the AI prompt all present the BASE dialect; an alias
  introduces no dedicated branch anywhere. The ongoing cost of an alias = one
  map entry.
- No display-level provider distinction (e.g. supabase/neon badges) — add a
  `provider` field when a real need shows up.
- After normalization `resolve_connection_url` naturally builds
  `postgres://`/`mysql://`, closing off the "binary scheme fallback silently
  builds an alias into `mysql://`" mis-routing.

### PostgreSQL-compatible family (→ postgres)

cockroachdb, yugabyte, aurora-postgres, neon, supabase, timescaledb
(effectively a pg extension)

### MySQL-compatible family (→ mysql)

tidb, singlestore, aurora-mysql, vitess, planetscale

## 3. Automated tests

A new dialect's tests come in three layers, all inside the existing
`tests/run.sh` setup.

### 3.1 Lua unit tests (no Docker, run with `tests/run.sh`)

Pure stub tests following the existing `tests/sql/*_spec.lua` conventions:

| File | Cases to add |
|------|-----------|
| `sql_constants_spec.lua` | `SUPPORTED_DIALECTS`/`is_sql_dialect`; `DIALECT_ALIASES` normalization assertions; `dialect_from_url` per prefix; `default_port`; new `SYSTEM_SCHEMAS` entries |
| `sql_connections_spec.lua` | **Assert the BUILT URL** (the code path builds; it never parses a user-supplied scheme): new prefixes and default ports correct; aliases resolve to the base protocol URL (guards the binary-fallback mis-routing) |
| `sql_ident_spec.lua` + dml | `ident.quote`/`quote_literal`, `dml.lua` value escaping for the new dialect |
| `sql_completion_spec.lua` | dialect keywords/builtins; `tables_db_flag` classification |
| `sql_snippets_spec.lua` | `pick_template` hitting the new dialect's variants |
| `sql_source_format_spec.lua` | per-formatter `dialect_map` entries |

**`tables_db_flag` classification** (current): postgres/postgresql/sqlite/mssql
→ `--schema`; mysql/mariadb (and unknown) → `--database`.

**`SYSTEM_SCHEMAS`** (consumed by `semantic_diagnostics.lua`): today the pg
family + mysql family + `sys` + `guest`; add `system` for ClickHouse/Trino.

### 3.2 Rust unit tests (poste.nvim crates)

**Split by transport:**

- **TCP-driver dialects (e.g. MSSQL)**: write the `Dialect` impl + test module
  in `crates/poste-exec/src/sql_dialect.rs`, mirroring the existing
  `test_postgres_dialect()` / `test_mysql_dialect()` / `test_sqlite_dialect()`,
  covering every trait method (including `type_mapping`); `dialect_for` asserts
  Some; non-SQL protocols like Redis stay None; introspection SQL snapshot
  assertions
- **SQL-over-HTTP dialects (ClickHouse/Trino)**: implement `Dialect` in
  `sql_dialect.rs` with snapshot tests; `dialect_for` returns Some (the
  dialect is decoupled from transport); the transport-dispatch unit test
  asserts routing to the HTTP executor

### 3.3 Integration tests (Docker required, gated)

- `tests/diag/diag_<dialect>.lua` (modeled on `diag_sql.lua`/`diag_mssql.lua`):
  environment-variable gated (e.g. `MSSQL_TEST_URL` + `POSTE_BINARY`); SKIP
  when unset; runs the full introspection chain plus feature SQL against the
  real container
- Busted unit tests must stay runnable without Docker

### 3.4 Compatible-family aliases

- Lua-side tests only: aliases accepted in `connections.toml`, normalized URLs
  land on `postgres://`/`mysql://`; reuses existing containers

## 4. Docker containers

Append services to `playground/docker-compose.yml` (host ports avoiding the
used 15432/13306/13307/11433/18080/18123/19000):

| Service | Image | Host port | Health check |
|------|------|---------|---------|
| `mssql` ✅ | `mcr.microsoft.com/mssql/server:2022-latest` (**amd64-only**, declare `platform: linux/amd64`) | `11433:1433` | `/opt/mssql-tools18/bin/sqlcmd ... -C -b` (**`-C` is mandatory** to trust the self-signed certificate) |
| `clickhouse` | `clickhouse/clickhouse-server:latest` | `18123:8123` (HTTP — **the connection layer uses only this**) / `19000:9000` (native, spare) | `wget -qO- http://localhost:8123/ping` returns `Ok` |
| `trino` | `trinodb/trino:latest` | `18080:8080` | `curl -f http://localhost:8080/v1/info` with `starting=false` |
| `duckdb` | File mode built by the official CLI (no server process) | no port | File mode has no liveness probe; an HTTP server mode is **explicitly out of scope** |

Initialization differences and pitfalls:

- **MSSQL** (already flattened — see `playground/init/mssql/entrypoint.sh`):
  no official arm64 build, Apple Silicon runs it through Rosetta/QEMU, slow
  start needs `start_period: 120s`; it ignores
  `docker-entrypoint-initdb.d`, so a custom entrypoint starts `sqlservr` then
  loads seeds via sqlcmd; seeds use GO batches (sqlcmd consumes them),
  `GENERATE_SERIES` cannot use an `AS s(n)` column alias (the column name is
  fixed to `value`), and `datetime2` does not support `- integer` arithmetic;
  **seeds replay on every restart (data resets), unlike the other services**
- **ClickHouse**: natively supports `/docker-entrypoint-initdb.d/*.sql`.
  Connection semantics pinned: `clickhouse://user:pass@host:18123/db` goes
  over HTTP 8123
- **Trino**: the image ships only `tpch` (+system) enabled; **tpcds needs
  `etc/catalog/tpcds.properties` mounted**; `tpch` is read-only, so build the
  core tables in the `memory` catalog (CTAS only, lost on restart — a
  post-start script rebuilds them)
- **DuckDB**: an entrypoint script generates the seed `.duckdb` with the
  duckdb CLI (same shape as sqlite's `test.db`); the URL `duckdb:<path>`
  follows the `sqlite:` prefix precedent; the Rust driver is the `duckdb`
  crate (links libduckdb, heavy build)

## 5. Seed data

Seed scripts live in `playground/init/<dialect>/`, following the existing
conventions: single file <8KB, 3-7 lines of hand-written realistic samples plus
bulk generation, dependency-library independent.

- The cross-engine core tables (`users`/`orders`/`order_items`) keep one query
  running identically across containers; Trino is the exception: core tables
  live in the `memory` catalog and are rebuilt at startup, `tpch`/`tpcds` are
  read-only federation
- The README gets a per-dialect table/row-count list (same format as the mssql
  section)

## 6. Playground SQL scripts

`playground/queries/<dialect>.sql`: a header comment listing the dialect's
features + `-- @connection`/`-- @database` headers. **Separate sections with
`--` comments, never `###` lines** (exec-file strips only standalone `###`
lines). Modeled on `mssql.sql`.

## Acceptance criteria (per step)

1. The new dialect can be written into `connections.toml` and connects
2. After connecting, introspection (list databases/tables/columns/indexes)
   works
3. Completion and snippets work for the new dialect
4. `source_format.lua` mapping filled in; formatting runs without error
5. 3.1/3.2 unit tests green without Docker; 3.3 diag green
6. The new docker-compose service passes its health check; seed data in place
7. The playground SQL script runs end to end
8. Compatible-family aliases: zero Rust diff
9. Every Lua touchpoint covered (including `ai/system_prompt.lua`)
10. Both `to_url()` mirrors updated; no silent mis-routing

## Suggested order

1. ~~Aliases~~ ✅
2. ~~MSSQL~~ ✅
3. **HTTP transport + ClickHouse** (next: poste-exec's first HTTP transport)
4. Trino (reuses the HTTP transport)
5. DuckDB (optional, deferred)

Per-step completion bar: 3.1/3.2 tests written first and green → docker service
health check passes → init data in place → playground runs → diag green →
`ai/system_prompt.lua` updated.

---

## Appendix: new-dialect touchpoint checklist (check every box before touching code)

### Lua side (poste-db.nvim)

| # | File | What to change |
|---|------|---------|
| 1 | `constants.lua` | `SUPPORTED_DIALECTS`; the alias into `DIALECT_ALIASES`; the system catalog into `SYSTEM_SCHEMAS`; the prefix into `URL_SCHEMES`; the port into `DIALECT_DEFAULT_PORTS` |
| 2 | `connections.lua` | URL building and display go through `default_port()` (usually zero diff); an icon into `dialect_icons` |
| 3 | `ident.lua` | `quote` identifier-quoting branch; `quote_literal` value escaping |
| 4 | `dml.lua` | dialect branches in the edit-flow DML generation |
| 5 | `completion/data.lua` | `tables_db_flag` (`--schema` vs `--database`) classification |
| 6 | `snippets.lua` | dialect variants into `CATEGORIES` (`pick_template` picks them up automatically) |
| 7 | `source_format.lua` | the sqlfluff / sql-formatter `dialect_map` |
| 8 | `ai/system_prompt.lua` | the dialect-list sentence |
| 9 | specs | `sql_constants` / `sql_connections` (**URL-building assertions, guards silent mis-routing**) / `sql_ident` / `sql_snippets` / `sql_completion` (tables_db_flag) |

### Rust side (edit poste.nvim main directly)

| # | Location | What to change |
|---|------|---------|
| 1 | `poste-core/src/request.rs` | the `Protocol` variant |
| 2 | `poste-exec/src/sql_connection.rs` | `to_url()` dialect branch + the `test_connection` probe. **A mirror of Lua's `resolve_connection_url`; both sides must move together** |
| 3 | `poste-cli/src/exec_file.rs` | scheme→protocol chain + `run_statements` dispatch + `exec_<dialect>` + the summary dialect string |
| 4 | `poste-cli/src/session.rs` | scheme chain + `session_<dialect>` (session semantics are driver-specific: temp tables/transactions — see the batch-path notes in `sql_executor/mssql.rs`) |
| 5 | `poste-cli/src/introspect.rs` | dialect_name chain. **This chain silently falls back to postgres — a new dialect MUST add an explicit branch** |
| 6 | `poste-exec/src/sql_dialect.rs` | the `Dialect` impl + a `dialect_for` branch + snapshot tests (see `test_mssql_dialect`) |
| 7 | `poste-exec/src/sql_executor/{mod.rs,<dialect>.rs}` | driver module + dispatch match + `make_response` protocol name |
| 8 | `poste-exec/src/sql_introspect/{mod.rs,<dialect>.rs}` | introspect driver + dispatch (match the item shape of `postgres.rs`) |
| 9 | `poste-exec/src/sql_ddl.rs` | `DdlGenerator` + a `ddl_for` branch |
| 10 | `poste-cli/src/connection.rs` | the connection-list emoji (cosmetic) |

### Pitfalls MSSQL already paid for (reference for new drivers)

- **TDS temp-table scope**: `CREATE TABLE #t` must go through the batch path
  (`simple_query`); the RPC prepare/execute scope drops the table when it
  exits — see `mssql_execute`'s `is_ddl_stmt` routing
- **MERGE must end with a semicolon**, and statement splitting strips the
  trailing one — the execution layer adds it back
- Transactions need no dedicated API: BEGIN/COMMIT/ROLLBACK go through the
  batch path; the server reports descriptors via ENVCHANGE
- Value conversion: see `mssql_value_to_json` (tiberius `try_get` returns
  `Option<T>` with borrowed `&str`/`&[u8]`; numbers/dates share the fallback
  in `value.rs`)
- HTTP-type dialects: the `clickhouse` crate is HTTP-only (RowBinary over
  HTTP); `Dialect` is decoupled from transport — see the Background section
