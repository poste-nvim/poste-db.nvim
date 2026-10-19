# SQL Developer Documentation

> SQL execution engine, completion, UI design

## Module Index

One line per module. Line counts drift — responsibilities are what matter;
see `.opencode/skills/sql-architecture-harness/SKILL.md` for the house rules
(one module, one job; house primitives listed there are seams, not suggestions).

### Entry & wiring

| Module | Role |
|--------|------|
| `init.lua` | `setup()` entry: config merge, highlights, commands, autocmds, AI registration |
| `config.lua` | User config (`M.config`), defaults, keymap lookup |
| `compat.lua` | Legacy `poste_sql_*` globals + `poste_db_*`/`poste_sql_` variable-name fallbacks; deprecation warnings |
| `constants.lua` | **Single source**: supported dialects, `DIALECT_ALIASES`, `URL_SCHEMES`/`dialect_from_url`, `DIALECT_DEFAULT_PORTS`, `SYSTEM_SCHEMAS`, directive parsing helpers; spinner/indicator constants merged from poste.nvim@5b3759e |
| `state.lua` | SQL context (current connection/database binding) + dataset/cell state; + state-lite merged from poste.nvim@5b3759e (`config` singleton, `find_poste_binary`, `apply_highlight_overrides`, `log`) |
| `cli.lua` | VENDORED from poste.nvim@5b3759e `lua/poste/cli.lua` — poste binary wrapper (`run`/`run_json`/`run_async`) |
| `select.lua` | VENDORED from poste.nvim@5b3759e `lua/poste/select.lua` — snacks → float → `vim.ui.select` picker |
| `dialog.lua` | VENDORED from poste.nvim@5b3759e `lua/poste/dialog.lua` — float dialog with backdrop refcount |
| `layout.lua` | VENDORED from poste.nvim@5b3759e `lua/poste/layout.lua` — wrapping/padding/progress/keymap-hint layout |
| `indicators.lua` | VENDORED from poste.nvim@5b3759e `lua/poste/indicators.lua` — sign-column spinner / ✓ / ✘ + eol latency virt-text |
| `install.lua` | VENDORED from poste.nvim@5b3759e `lua/poste/install.lua`, trimmed (no git-tag version sync) — ensures the family poste binary |
| `util.lua` | utf8/color helpers, `width.truncate` bridge; + `clean_nil`/`find_file_upwards`/`ensure_job_data` merged from poste.nvim@5b3759e |
| `health.lua` | `:checkhealth` — nvim version, binary probe + version, connections, parser |
| `autocmds.lua` | Filetype detection, directive highlighting, buffer cleanup wiring |
| `commands.lua` | `:PosteDb*` command definitions |
| `buffer_setup.lua` | Buffer-local setup for poste_sql buffers |

### SQL understanding

| Module | Role |
|--------|------|
| `statement.lua` | Statement boundary detection (Rust binary → tree-sitter → fallback) |
| `ts_stmt.lua` | Tree-sitter statement/query extraction |
| `context.lua` / `lex.lua` | Cursor context resolution; comment/string lexing |
| `explain.lua` | `EXPLAIN` the statement under the cursor (dialect plan form → dataset panel) |
| `source_format.lua` | SQL source formatter for poste_sql buffers (multi-backend: external formatters or built-in) |
| `semantic_diagnostics.lua` | Tree-sitter reference extraction + unknown-object validation (fetches schema via introspect jobs) |
| `syntax.lua` | Treesitter-based highlight queries / digit-prefix fragments / known error constructs |
| `ident.lua` | Identifier quoting (`quote`/`quote_qualified`) + value literals per dialect |
| `width.lua` | Terminal-consistent display width (Indic combining marks that `strdisplaywidth` folds to 0) |

### Execution

| Module | Role |
|--------|------|
| `connections.lua` | connections.toml discovery/parse/cache, env `{{vars}}`, URL building (`resolve_connection_url` — mirror of Rust `to_url()`), picker |
| `toml.lua` | Minimal pure-Lua TOML parser behind `connections.toml` (documented subset: sections, scalars, strings, comments) |
| `tunnel.lua` | SSH tunnel for connections.toml `tunnel` sections (URL only ever sees the local forward end) |
| `executor.lua` | Chooses session vs exec path per connection/operation |
| `diagnostics.lua` | Tree-sitter syntax diagnostics (ERROR nodes → vim.diagnostic), debounced on change/write; fans out to semantic checks |
| `session_conn.lua` | Long-lived `poste session` pool (temp tables, `USE`, session vars persist across `<CR>`); keyed by conn_url, shared across buffers |
| `exec_run.lua` / `file_exec.lua` | One-shot `poste exec-file` runs (editor/file entry) with NDJSON event parsing |
| `sql_runner.lua` | Resultset request path used by the dataset R-refresh flows |
| `sql_runner/response.lua` | Response → statement results mapping, DDL classification |
| `session.lua` | Request-scoped session lifecycle (fresh Session per run, persistent context) |
| `sql_log.lua` | Persistent SQL activity journal (`sql_log.jsonl`) — the single writer behind the `<leader>l` viewer |
| `log.lua` | Log-line redaction (URL passwords/DSN secret keys) shared by the journal, the dataset panel and AI context |
| `async.lua` | jobstart/timeout scaffolding |
| `edit_commit/` | Dataset edit commit: DML generation (`dml.lua`, `dml_guard.lua`), commit/rollback exec, SQL log |
| `table_ops.lua` | Table-level DDL operations from the browser |
| `verdict.lua` | One statement's outcome from an exec envelope — the status flag decides, the message only explains (dependency-free) |
| `types.lua` | Column type classification (numeric-or-not) shared by import mapping, DML generation, cell editing and dataset alignment |

### Dataset UI

| Module | Role |
|--------|------|
| `buffer/` | Dataset buffer: render pipeline (`init`), paging (`page`), search/filter (`search`), keyboard nav (`nav*`), tabs/history (`history`, `header`), render (`render`), nav state (`nav_state`, `nav_ui`, `nav_sort`, `nav_preview`, `nav_raw`) |
| `dataset.lua` | Dataset data model/tab state |
| `format.lua` | Value formatting, column widths, table drawing, pagination planning |
| `highlights/` | Cell highlight extmarks (`render`) + highlight groups (`theme`) |
| `statement_indicator.lua` / `statement.lua` | Sign-column statement indicators |
| `nav/` | Cross-dataset navigation routing (`detect`/`handlers`/`route`) |
| `float_window.lua` | House floating-window primitive — all popups go through `open()`/`open_centered()` |
| `insert_hint.lua` | Debounced INSERT template hint |
| `statusline.lua` | Dataset statusline — since the family dissolution the mini.statusline wiring is scope-guarded (renders only on `poste_db_context` buffers, falls through otherwise; `vim.g.poste_db_statusline_wired` idempotency) |
| `log_viewer.lua` | SQL log browsing/filtering/re-run |
| `help.lua` | Floating keymap help |

### Completion

| Module | Role |
|--------|------|
| `completion/init.lua` | Completion entry + mode handling (hybrid/rust/legacy) |
| `completion/data.lua` | Keyword/function tables, cache + epoch, lazy introspect fetchers (`start_introspect_job` is the house scaffold), `tables_db_flag` |
| `completion/ctx.lua` / `handlers.lua` | Context detection dispatch and per-context item building |
| `completion/adapter.lua` / `register.lua` | blink.cmp integration + provider registration |
| `completion/debug.lua` | On-demand completion debug window |
| `snippets.lua` | SQL snippet definitions for blink.cmp, organized as categories with per-dialect template variants |

### DB browser / import / export / introspect

| Module | Role |
|--------|------|
| `db_browser/init.lua` | Browser tree window + buffer setup |
| `db_browser/operations.lua` | Context-menu dispatch surface (M entry points; helpers/delegations below) |
| `db_browser/ops_sql.lua` | Shared node/SQL-generation helpers for browser operations |
| `db_browser/ops_drop.lua` | Table-drop flows (confirm, batch progress, parent refresh) |
| `db_browser/copy.lua` | Cross-server table clone orchestration (probe → conflict → paste pipeline) |
| `db_browser/copy_ddl.lua` | Pure DDL/result transforms for copy (rename, sequences, quoting) |
| `db_browser/copy_progress.lua` | Copy confirm/progress/summary dialogs (caller-injected jobs) |
| `db_browser/actions.lua` / `context_menu.lua` / `flash.lua` | Tree actions, menu, flash highlight |
| `db_browser/catalog.lua` | Per-dialect catalog SQL (views/triggers/routines/sizes) |
| `db_browser/forms.lua` / `forms_advanced.lua` / `schema_create.lua` / `db_create.lua` | Create/alter form dialogs |
| `db_browser/tree.lua` / `util.lua` | Tree model + expand/refresh primitives |
| `db_browser/icons.lua` / `theme.lua` / `statusline.lua` / `notify.lua` / `yank.lua` / `completion.lua` / `sql_conn.lua` / `async.lua` | Browser support modules |
| `import.lua` + `import/` | CSV/JSON import: parse (`format`), column mapping (`mapping`), preview, execute |
| `export.lua` | Resultset export (csv/tsv/json/markdown/sql) |
| `introspect/` | Table DDL viewer routing (`init` + column/context/detect/exec/helpers/job/route/table/target/ui — each with its own spec) |
| `editor.lua` + `editor/` | Cell editing: value parse/validate (`cell`), column metadata (`column`), grid navigation (`nav`) |

### AI

| Module | Role |
|--------|------|
| `ai/init.lua` | poste-ai.nvim registration (silently absent-safe) |
| `ai/system_prompt.lua` | "db" context system prompt (dialect list lives here) |
| `ai/actions.lua` / `commands.lua` / `mentions.lua` / `schema.lua` / `introspect.lua` | Ask/actions commands, @connection mentions, schema injection |

## Naming Conventions — `poste-db` vs `poste_sql`

> Read this before writing any code. It is the source of truth for which name
> to use, and it is what keeps AI agents from reintroducing `poste_sql_*`
> identifiers.

There are exactly THREE spellings to know, and they mean different things:

| Name | Means | Used for | Examples |
|------|-------|----------|----------|
| `poste-db` | **The plugin** | Repo, module paths, user commands | `lua/poste-db/`, `require("poste-db.state")`, `:PosteDbInfo` |
| `poste_db` | **The plugin, snake_cased** | Lua-config globals, buffer vars, extmark namespaces, completion provider | `g:poste_db_config`, `b:poste_db_context`, `vim.api.nvim_create_namespace("poste_db_dataset")`, `add_source_provider("poste_db")` |
| `poste_sql` / `poste_sqlite` | **The Vim filetype** for SQL buffers this plugin manages | Filetype value and the file/hook names derived from it ONLY | `set filetype=poste_sql`, `ftdetect/poste_sql.vim`, `after/queries/poste_sql/`, `au FileType poste_sql` |

### Rule of thumb

- **`db` → the plugin.** Every new plugin-facing identifier uses `poste-db` or
  `poste_db` (and highlight groups use the `PosteDb*` prefix).
- **`sql` → the filetype only.** `poste_sql` / `poste_sqlite` are reserved for
  the buffer filetype value and the `ftdetect/`/`syntax/`/`ftplugin/`/`after/queries/`
  files named after it. The filetype handling itself lives in this repo
  (`buffer_setup.lua`, `autocmds.lua`, `ftdetect/`) — the value must NOT
  change casually (config surface, ftdetect, queries all key on it).
- Never introduce a new `poste_sql_*`-prefixed global, buffer var, namespace, or
  provider name. The `poste_sql_*` globals that still exist are **deprecated
  aliases** read only by `lua/poste-db/compat.lua` (they log a deprecation
  warning); do not add new readers, do not write them, and treat them as
  migration-only.
- The filetype name `poste_sql` itself is NOT deprecated — only the
  plugin-level `poste_sql_*` API names are.

Cheat sheet for the integration points where both names legitimately meet:

```lua
-- completion provider id (plugin)        → "poste_db"
adapter.register_source({ name = "poste_db", ... })
-- filetype → provider mapping (both)     → filetype is poste_sql, provider is poste_db
adapter.register_filetype("poste_sql", "poste_db")
-- treesitter language registration       → filetype stays poste_sql/poste_sqlite
vim.treesitter.language.register("sql", "poste_sql")
-- conform per-filetype mapping           → key is the filetype
conform.formatters_by_ft["poste_sql"] = ...
-- user config global                     → poste_db
vim.g.poste_db_legacy_completion = "rust"
```

## Self-containment + family contracts

This repo is self-contained since the poste.nvim family dissolution: the
former shared Lua (`poste.state/cli/util/select/layout/dialog/indicators` +
installer) is vendored under `lua/poste-db/` (vendor source
poste.nvim@5b3759e `lua/poste/`, copied verbatim apart from require renames
and source annotations). There is no shared Lua layer any more — the only
cross-repo contracts are:

- **The `poste` binary NDJSON schema** (exec-file, session, introspect, ...)
  — documented in `../poste.nvim/docs/schema.md`. `resolve_connection_url`
  and the Rust `ConnectionConfig::to_url()` are mirror implementations:
  neither may drift alone.
- **Statusline scope discipline** (no shared coordinator any more): the
  mini.statusline wiring in `lua/poste-db/statusline.lua` is scope-guarded —
  it renders only on buffers carrying `poste_db_context` and falls through
  to the captured original everywhere else, so a sibling's wrapper (redis,
  ...) chains with ours instead of fighting over the global hooks. Any new
  wiring MUST keep that guard and the `vim.g.poste_db_statusline_wired`
  idempotency flag; pinned by `tests/sql/sql_statusline_spec.lua`.

## Design Docs

| Document | Description |
|----------|-------------|
| [Dialect Support](./dialect-support.md) | 新增 SQL 方言：优先级、别名机制、三层测试、容器方案、**Lua/Rust 触点清单**（动手前照单全查） |
| [Context Architecture](./context-architecture.md) | SQL completion context detection architecture |
| [Session Design](./session-design.md) | 持久 SQL session 池：问题、路由、生命周期 |
| [AI Chat Integration](./ai-chat.md) | poste-ai.nvim "db" context: @connection mentions, schema injection, SQL code-block execution into the dataset |

---

*SQL developer documentation — Last updated: 2026-10-19 (module index: added the two unlisted modules — diagnostics, log)*
