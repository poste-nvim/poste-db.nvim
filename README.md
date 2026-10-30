# poste-db.nvim

[![CI](https://github.com/poste-nvim/poste-db.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/poste-nvim/poste-db.nvim/actions/workflows/ci.yml)

**Execute SQL from plain-text files. A spreadsheet for your results.**

A self-contained SQL plugin for Neovim: run statements from `.sql` files
against PostgreSQL, MySQL/MariaDB, SQLite, SQL Server or ClickHouse, and get
a keyboard-driven dataset panel — pagination, cell navigation, search, sort,
inline transactional editing — instead of a wall of text.

![poste-db.nvim — SQL buffer + dataset panel](.github/assets/dataset.png)

Part of the [Poste](https://github.com/poste-nvim/poste.nvim) family. The
plugin is fully self-contained (shared infra is vendored); the one shared
piece is the `poste` binary — a usable one is picked up from
`vim.g.poste_binary`, `$POSTE_BINARY`, a local dev build or `PATH`, and only
downloaded from [poste.nvim](https://github.com/poste-nvim/poste.nvim) releases
when none of those exist. "Usable" means readable **and** executable: a file
without the exec bit is skipped rather than picked over a working `PATH` entry.
On Windows each candidate is tried both as spelled and with `.exe` appended,
which is where the installer and cargo actually put the binary.
The download itself never blocks the editor: the archive fetch runs in the
background (`vim.system`), and it is bounded (10s to connect, 180s for the
archive), so a network that black-holes it reports a failed install instead of
hanging a hidden process forever. If the first-setup download failed — an
offline machine, no `curl` — `:PosteDbInstall` retries it at any time
(`:PosteDbInstall v0.4.2` pins a release tag).

Full documentation lives in `doc/poste-db.txt` (`:h poste-db`), with a
[quick reference](docs/user/sql/quick-reference.md) for the everyday keys.
Having trouble? See [SUPPORT.md](SUPPORT.md) — it covers the diagnosis path
for binary, dialect, connection, and completion problems before you open an
issue.

## Features

- **Execute SQL statements** from `.sql` files — PostgreSQL, MySQL/MariaDB, SQLite, SQL Server, ClickHouse, and PG/MySQL-compatible aliases
- **Dataset panel** — Paginated results, cell navigation (hjkl), vim-style search/filter, sorting
![poste-db.nvim — dataset panel](.github/assets/dataset-panel.png)

- **Inline editing** — Edit cells, insert/delete rows, commit as one **transaction** (BEGIN/COMMIT/ROLLBACK) with affected-row verification
- **DB Browser** — Tree view of schemas, tables, columns; context menu with create/import/drop/clone actions and DDL generators
- **SSH tunnels** — Declare a jump host per connection; everything works through `127.0.0.1:<local port>`
- **EXPLAIN** — Dialect-aware query plan as a dataset table (`<leader>ep`)
- **SQL completion** — Keywords, tables, columns, functions, snippets (blink.cmp / nvim-cmp)
- **Semantic diagnostics** — Table/column references validated against the live schema
- **Export/import** — CSV, TSV, JSON, Markdown, SQL INSERT; paste CSV/JSON into a table
- **Multi-result tabs** — Each statement gets its own tab
- **History** — Session request sidebar + persistent execution log viewer
- **AI chat** — Schema-aware chat with guarded SQL execution ([poste-ai.nvim](https://github.com/poste-nvim/poste-ai.nvim))

## Installation

```lua
-- lazy.nvim
{
  "poste-nvim/poste-db.nvim",
  config = function()
    require("poste-db.init").setup()
  end,
}
```

No hard plugin dependencies. SQL completion is provided through blink.cmp
(recommended) or nvim-cmp when either is installed — registration is silent
when neither is, and execution is unaffected.

On first setup the plugin looks for a usable `poste` binary — in
`vim.g.poste_binary`, then `$POSTE_BINARY`, then the install path
(`stdpath("data")/poste/bin/poste`), then a local dev build next to the plugin
or in the current directory, then `PATH` — and only downloads from
poste.nvim releases (SHA256-verified) into that install path when none of those
is runnable. "Runnable" means readable **and** executable, so a
copied-but-not-chmod'ed file cannot mask a working `PATH` entry; on Windows a
candidate also matches `<name>.exe`, which is the file the installer writes and
cargo builds (both spellings work). To use
your own build — e.g. `../poste.nvim/target/debug/poste` with dialect work
that has not shipped yet — set
`vim.g.poste_binary = "/path/to/poste"` (or `export POSTE_BINARY=…` for
headless/CI processes, which never see a `vim.g`) before setup.

**Filetype note** — the plugin claims `*.sql` / `*.sqlite` files with its own
`poste_sql` / `poste_sqlite` filetypes (not the builtin `sql`), so keymaps,
queries and completion arrive without colliding with other SQL plugins. If
your existing config attaches LSP servers, snippets or treesitter queries to
`sql`, retarget those autocommands/patterns at `poste_sql` as well — anything
keyed on the builtin `sql` silently stops applying to `.sql` files once this
plugin loads.

Run `:checkhealth poste-db` to verify the installation. Both it and
`:PosteDbInfo` name the candidate that won (`from: $PATH`, `(from installed
release)`, …) — the install path outranks `PATH`, so that label is the quickest
answer to "why isn't my own build being used".

## Usage

Open a `.sql` file, position the cursor on a statement, press `<CR>`.

```sql
-- @connection pg-dev

SELECT u.name, count(o.id) AS orders
FROM users u JOIN orders o ON o.user_id = u.id
GROUP BY u.name
ORDER BY orders DESC;
```

The result opens in the dataset panel: `h/j/k/l` move the cell cursor,
`H/L` page, `s` sorts, `<leader>/` searches, `K` previews a cell, `yy` yanks
it, `E` exports the whole result set. Every statement gets its own tab
(`<Tab>`/`<S-Tab>` to cycle).

### Connection management

Connections are defined in `connections.toml` (walked up from the SQL file):

```toml
[pg-dev]
dialect = "postgres"
host = "localhost"
port = 5432
database = "myapp"
user = "{{PG_DEV_USER}}"
password = "{{PG_DEV_PASSWORD}}"
```

Sensitive fields support `{{VAR}}` references resolved at runtime from a
`.env` file next to `connections.toml` (same walk-up discovery), with real OS
environment variables taking precedence. Unknown references stay literal, so
plaintext configs keep working. Copy `.env.example` to `.env` and keep `.env`
out of version control — never commit credentials. `user` and `password` are
percent-encoded automatically when building connection URLs, so values
containing `@`, `:`, `/`, `%` etc. work as-is.

Reference in `.sql` files:

```sql
-- @connection pg-dev

SELECT * FROM users WHERE active = true;
```

The `USE database;` statement switches the active database for parsing/completion context.

#### SSH tunnels

Connections behind a bastion declare a jump host directly in the section; the
plugin spawns `ssh -N -L` on first use and everything (execution, browser,
completion, AI) works through the local forward:

```toml
[pg-prod]
dialect = "postgres"
host = "db.internal"
port = 5432
database = "app"
tunnel = "jump@bastion.corp"
# or: tunnel = { to = "jump@bastion.corp", port = 2222, key = "~/.ssh/id_ed25519" }
```

`:PosteDbTunnel` lists active tunnels, `:PosteDbTunnel <name|--all>` stops them.

### Statusline context

The current connection and database are shown in the statusline as `[connection/database]` when `mini.statusline` is installed. The context updates as you move the cursor (respects `@connection`, `@database`, and `USE` statements).

**Per-connection colors** — add a `color = "#ff0000"` / `color = "SkyBlue"` / `link = "WarningMsg"` field to a connection section (hex, CSS named color, or highlight group — auto-detected). Full details: `:h poste-db-statusline`.

### Dataset buffer

| Key | Action |
|-----|--------|
| `h`/`j`/`k`/`l` | Move cell |
| `H`/`L` | Previous/next page |
| `0`/`$` | First/last column |
| `gg`/`G` | First/last row |
| `s` | Sort by column |
| `<leader>/` | Search |
| `<leader>ce` | Filter by cell |
| `K` | Preview cell |
| `yy` / `yc` | Yank cell / column |
| `R` | Re-run query |
| `gs` | Show the SQL of this result |
| `<Tab>`/`<S-Tab>` | Next/previous tab |
| `<leader>ph` | Toggle request history sidebar |
| `E` | Export the result set |
| `a` | Ask AI about this result (or the last error) |

### Dataset editing

| Key | Action |
|-----|--------|
| `i` / `cc` | Enter edit mode |
| `dd` | Delete row |
| `o` | Append a row at the end of the table |
| `<leader>w` | Commit changes as one transaction (BEGIN/COMMIT/ROLLBACK) |

### Export

`E` in the dataset buffer, or `:PosteDbExport [format] [destination] [path]`.
Formats: `csv`, `tsv`, `json`, `md`, `sql` (INSERT statements). Destination:
file or clipboard.

### DB Browser

Press `<leader>db` in a SQL file to open the database tree browser.

![poste-db.nvim — db browser](.github/assets/db-browser.png)

| Key | Action |
|-----|--------|
| `<CR>` | Toggle node expand/collapse |
| `x` | Context menu |
| `i` | Table/column info |
| `/` | Search filter |
| `Tab` | Multi-select toggle |
| `y` / `p` | Yank node / paste-clone (cross-connection) |
| `D` | Batch-drop selected tables |
| `gd` | Open `connections.toml` at this entry |
| `q` | Close |

Context menu (`x`) shows node-specific actions. On **schema/database** nodes, `T` inserts a **CREATE TABLE template** with tab-stop placeholders:

```
create table table_name (
  column_name INTEGER NOT NULL
);
```

Press `<Tab>` to jump between placeholders, `<S-Tab>` to go back.

On **table nodes**, the DDL generators write dialect-aware statements into
your SQL buffer: `ma` add column, `mr` rename column, `md` drop column,
`mt` alter column type.

### EXPLAIN

`<leader>ep` (or `:PosteDbExplain`) shows the query plan of the statement
under the cursor in the dataset panel, like an ordinary query result —
`EXPLAIN` on postgres/mysql/clickhouse, `EXPLAIN QUERY PLAN` on sqlite.
Plan-only forms never execute the statement. A wide plan scrolls
horizontally in the split instead of wrapping.

### AI chat

With [poste-ai.nvim](https://github.com/poste-nvim/poste-ai.nvim) installed,
`:PosteDbChat` opens a schema-aware chat:

![poste-db.nvim — ai chat](.github/assets/ai-chat.png)

- `/connections` / `/databases` scope the conversation
- `@connection/database[/table]` mentions inject schema summaries; tables
  named in your message pull in their columns automatically
- `<leader>aa` asks about a selection; `a` on a dataset tab asks about the
  result set (or the last error, with full context)
- ```sql blocks from the chat can be executed into the dataset view —
  anything not obviously read-only asks for confirmation first

### SQL completion

- **Keywords** — `SELECT`, `FROM`, `WHERE`, `JOIN`, etc.
- **Tables, columns, schemas** — Introspected from your database
- **Functions** — Aggregate and scalar functions per dialect
- **Connection-aware** — Completions reflect the actual schema

Works with **blink.cmp** (auto-registers as the `poste_db` source) or
**nvim-cmp**.

### SQL Snippets

Built-in snippets are organized as **categories**, each with per-dialect
templates picked from the current connection's dialect
(mysql / mariadb / postgres / sqlite, falling back to a `default` template).
A trigger routes to a category: `trigger -> category -> [dialect] -> template`.

Every built-in snippet appears as a completion item when the prefix matches
its trigger word:

| Trigger | Category | Template | Dialect variants |
|---------|----------|----------|------------------|
| `ct` | `create_table` | `create table` | mysql `AUTO_INCREMENT`, postgres `SERIAL`, sqlite `AUTOINCREMENT` |
| `tab` | `create_table_timestamp` | `create table` + `updated_at`/`created_at` | postgres/sqlite drop `ON UPDATE CURRENT_TIMESTAMP` |
| `cdb` | `create_database` | `create database` | mysql `CHARACTER SET`+`COLLATE`, postgres `ENCODING`/`LC_COLLATE`, sqlite `ATTACH DATABASE` |
| `col` | `column` | integer column | postgres/sqlite drop `COMMENT` |
| `colv` | `column_varchar` | varchar column | postgres/sqlite drop `COMMENT`, sqlite uses `TEXT` |
| `sf` | `select_from` | `select * from ... limit 100` | default only |
| `cnt` | `select_count` | `select count(*)` | default only |
| `ins` | `insert` | `insert into ... values` | default only |
| `upd` | `update` | `update ... set ... where` | default only |
| `del` | `delete` | `delete from ... where` | default only |
| `cte` | `cte` | `with ... as` | default only |
| `idx` | `create_index` | `create index` | default only |
| `cola` | `alter_add_column` | `alter table add column` | postgres/sqlite drop `COMMENT` |
| `colu` | `alter_modify_column` | `alter table modify column` | postgres uses `ALTER COLUMN ... TYPE` |
| `uni` | `union_all` | `union all` | default only |

All snippets use **LSP-style syntax** (`${1:placeholder}`, `$0` for exit, `$$` for literal `$`). See `:help vim.snippet` or the [LSP spec](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#snippet_syntax) for details.

**Custom snippets** via `setup()`:

```lua
require("poste-db").setup({
  snippets = {
    -- Simple: trigger word → snippet body
    myq = "SELECT * FROM ${1:table} WHERE ${2:condition};",

    -- Full form: trigger, label, and snippet
    myf = {
      label = "my custom query",
      snippet = "with ${1:cte} as (\n  ${2:select_query}\n)\nselect * from ${1:cte};",
    },

    -- Route a trigger to a built-in category (or override one)
    mkct = "create_table",          -- new trigger for create_table category
    -- ct  = "create_database",     -- override built-in ct

    -- Custom category with per-dialect variants
    mkb = {
      default  = "CREATE DATABASE ${1:db};",
      postgres = "CREATE DATABASE ${1:db} ENCODING 'UTF8';",
    },
  },
})
```

## Supported scope

### Versions

| Component | Requirement | Notes |
|-----------|-------------|-------|
| Neovim | ≥ 0.10.0 | Uses `vim.system`, `vim.treesitter.language` |
| `poste` binary | Any release from [poste.nvim releases](https://github.com/poste-nvim/poste.nvim/releases) | Auto-installed on first setup if none found; see [SUPPORT.md](SUPPORT.md) § "Binary / dialect mismatch" when Lua and binary disagree on a dialect |
| blink.cmp | recommended | Auto-registers the `poste_db` source. nvim-cmp also supported; neither is required. |
| tree-sitter `sql` parser | recommended | `:TSInstall sql`. Without it, statement splitting falls back to the poste binary's splitter and then a Lua `;` scan; treesitter gives better statement/completion/diagnostic boundaries. |
| `ssh` | only for `tunnel` connections | Must be on `$PATH`. |

CI runs luacheck + the plenary suite on **nvim stable + nightly**. Older
Neovim (0.9.x and below) is not tested and will not work — `vim.system` and
the treesitter API used here are 0.10+ surfaces.

### Platforms (prebuilt binaries)

The auto-installer downloads from poste.nvim releases. Prebuilt assets exist
for:

| OS | Arch | Asset suffix |
|----|------|--------------|
| macOS | Apple Silicon | `aarch64-macos` |
| macOS | Intel | `x86_64-macos` |
| Linux | x86_64 | `x86_64-linux` |
| Linux | aarch64 | `aarch64-linux` |
| Windows | x86_64 | `x86_64-windows` |

Other platforms (e.g. Linux armv7, FreeBSD) have no prebuilt binary — build
the `poste` binary from
[poste.nvim](https://github.com/poste-nvim/poste.nvim) source and point
`vim.g.poste_binary` (or `$POSTE_BINARY`) at it.

### SQL dialects

| Dialect | Status | Accepted aliases |
|---------|--------|------------------|
| PostgreSQL | full | `postgresql`, `cockroachdb`, `yugabyte`, `aurora-postgres`, `neon`, `supabase`, `timescaledb` |
| MySQL | full | `tidb`, `singlestore`, `aurora-mysql`, `vitess`, `planetscale` |
| MariaDB | full | normalizes to `mysql` |
| SQLite | full | — |
| SQL Server (T-SQL) | full | `mssql` |
| ClickHouse | full | no transactional edits (engine has no `BEGIN/COMMIT`) |

Aliases normalize to a base dialect before any handling — the binary, URL
builder, completion, and icons only ever see base names. Adding an alias is
one entry in `lua/poste-db/constants.lua`; adding a real dialect is a larger
touch — see [`docs/dev/sql/dialect-support.md`](docs/dev/sql/dialect-support.md).

### What is explicitly NOT supported

- Neovim < 0.10.0
- Vim (not Neovim) — the plugin uses `vim.system`, `vim.uv`, `vim.treesitter`
- The AI chat without [poste-ai.nvim](https://github.com/poste-nvim/poste-ai.nvim) installed (silently skipped — by design)
- Non-prebuilt platforms without a manually-built `poste` binary

If your environment is outside the supported scope, please don't open an
issue asking when it will be supported unless you're also offering to
maintain that port.

## Testing

```bash
# Start test databases (PG 16 on 15432, MySQL 8.0 on 13306)
cd playground && docker compose up -d

# Run Lua tests
tests/run.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contribution guide.

## License

MIT
