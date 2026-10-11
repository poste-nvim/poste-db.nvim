# Contributing to poste-db.nvim

Thanks for considering a contribution. The bar is deliberately small: every
change lands with a regression test and a zero-warning lint.

## Setup

```bash
git clone https://github.com/poste-nvim/poste-db.nvim
cd poste-db.nvim

# Test databases (PG 16, MySQL 8, MariaDB, MSSQL, ClickHouse) — optional,
# specs stub the transport, but integration queries need them
cd playground && docker compose up -d && cd ..

# Lua tests (needs plenary.nvim; see "plenary discovery" below)
tests/run.sh
```

CI runs the same two gates on every PR: `luacheck --codes lua plugin
ftplugin tests` (zero warnings is the baseline — any new warning fails the
build) and the plenary suite on nvim stable + nightly.

### plenary discovery

`tests/run.sh` looks for plenary.nvim in a few common lazy/packer locations,
or you can point it directly:

```bash
PLENARY_PATH=/path/to/plenary.nvim tests/run.sh
```

To iterate on one file instead of the whole suite:
`tests/run_one.sh tests/sql/sql_format_spec.lua`. It runs the same nvim
scaffold over a single `PlenaryBustedFile` (a few seconds versus minutes for
the directory run) and needs the same plenary discovery.

## Ground rules

- **A regression test comes with the change.** Smallest test that captures
  the behavior; assert observable results, not internals; one seam at a
  time. Specs stub dependencies via `package.loaded` *before* the require
  (see any file in `tests/sql/` for the pattern) — note that stubbing
  changes what already-loaded modules capture, so require order matters.
- **Zero luacheck warnings.** The config lives in `.luacheckrc`; formatting
  via `.stylua.toml`.
- **Naming:** the plugin is `poste-db` / `poste_db` (modules, config keys,
  namespaces). `poste_sql` / `poste_sqlite` refer *only* to the SQL
  filetype and files derived from it. There is no `lua/poste-sql/`; the
  `poste_sql_*` globals are deprecated aliases handled by
  `lua/poste-db/compat.lua`. See the naming table in
  `docs/dev/sql/README.md`.
- **Secrets never land in the repo.** Connections go through
  `connections.toml` + `{{VAR}}` references resolved from `.env`
  (gitignored). Test fixtures use the `playground/` containers.
- **Commit messages** follow Conventional Commits (`feat(scope): ...`,
  `fix(scope): ...`, `docs: ...`, `refactor: ...`).

## Where things live

| Path | What |
|------|------|
| `lua/poste-db/` | All plugin code; `docs/dev/sql/README.md` is the per-module index |
| `doc/poste-db.txt` | User manual (`:h poste-db`) — user-facing changes land here, not just the README |
| `tests/sql/` | plenary specs; `tests/run.sh` runs the suite, `tests/run_one.sh <file>` one spec |
| `playground/` | Docker test databases + dialect query samples |
| `docs/dev/sql/dialect-support.md` | Adding a SQL dialect — touchpoint checklist |

## Adding a SQL dialect

Start with `docs/dev/sql/dialect-support.md` — it has the priority rules,
the alias mechanism, the three-layer test expectations, and the full
Lua/Rust touchpoint checklist to work through before opening a PR.
