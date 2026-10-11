# poste-db.nvim

Independent SQL plugin for Poste — self-contained since the poste.nvim
family dissolution: the former shared infra (state-lite, cli, util, select,
layout, dialog, indicators, installer) is vendored under `lua/poste-db/`
(vendor source poste.nvim@5b3759e). The `poste` Rust binary (built/released
by poste.nvim) is the only cross-repo contract (schema:
`../poste.nvim/docs/schema.md`).

## Key Facts

- All SQL Lua code lives under `lua/poste-db/` — no runtime dependency on
  poste.nvim or any sibling
- Optional: [poste-ai.nvim](https://github.com/poste-nvim/poste-ai.nvim) on rtp enables the AI chat (`:PosteDbChat`, `<leader>aa`). `lua/poste-db/ai/` must only `pcall(require, "poste-ai")` and silently skip when absent
- `plugin/poste-db.lua` calls `require("poste-db.init").setup()`
- `ftdetect/poste_sql.vim` sets filetypes for `.sql` and `.sqlite`
- Uses the family `poste` Rust binary (from poste.nvim). Which binary you get is resolved by `poste-db.state.find_poste_binary()`: `vim.g.poste_binary` → `$POSTE_BINARY` → poste config → `target/{debug,release}/poste` next to cwd or this repo's lua dir → PATH. Rebuild `../poste.nvim` (`cargo build -p poste-cli`) when testing unreleased Rust changes
- Rust dialect work goes straight into poste.nvim `main` (the old `../poste-for-db` worktree workflow is retired). The Lua side here may advertise a dialect the installed binary does not know yet — if Lua and binary disagree, check which binary you are running first
- `.opencode/skills/sql/` and `.opencode/skills/sql-completion/` for agent context
- Harness order:
  1. `.opencode/skills/sql-preflight-harness/SKILL.md`
  2. one specialized harness if needed — `sql-audit-harness` when auditing/reviewing code or acting on an audit's findings
  3. `sql-test-harness` when adding or hardening tests
  4. `sql-architecture-harness` when the code shape is the problem
  5. `sql-refactor-harness`, `sql-nav-harness`, or `sql-introspect-harness` when the task matches that area

## File Index

See `docs/dev/sql/README.md` for detailed file index.

## Naming Conventions

`poste-db` / `poste_db` = the plugin (modules, config keys, namespaces, provider).
`poste_sql` / `poste_sqlite` = ONLY the SQL **filetype** and the file/hook names
derived from it (`ftdetect/poste_sql.vim`, `after/queries/poste_sql/`, `au FileType poste_sql`).

There is no `lua/poste-sql/` and the plugin is NOT named `poste-sql` anymore.
Never write a new `poste_sql_*` global/namespace/provider — the remaining
`poste_sql_*` globals are deprecated aliases handled by `lua/poste-db/compat.lua`.
The filetype name `poste_sql` itself stays. See
`docs/dev/sql/README.md#naming-conventions--poste-db-vs-poste_sql` for the full table.

## Design Principles

- Zero coupling to HTTP modules — no `require("poste.http.*")`
- State lives in `lua/poste-db/state.lua` (accessed via `require("poste-db.state")`)
- Help in `lua/poste-db/help.lua` (filetype-aware dispatch, sits in this repo)

## Lua Pitfalls

### Local function forward declaration

When function A (e.g. `show_drop_confirm`) calls function B (e.g. `execute_drop`) that is defined
later in the same file, B must be forward-declared:

```lua
local B  -- forward declaration
local function A()
  B()  -- works: B is declared (even if nil at this point)
end
B = function()
  -- body
end
```

Without the forward declaration, `local function B() ... end` creates a new local binding that
is only visible *after* its definition, and A will capture `nil`. This is a Lua lexical scoping
rule — `local` bindings are not hoisted.

The same rule bites when demoting `M.x` to a local: a call site hundreds of lines above the
definition resolves to global `nil` (happened with `format.lua`'s `normalize_type`). Grep every
call site first; forward-declare or move the definition above the first use.

### `and f() or f` is not a ternary

`cond and f() or f` falls back to `f` whenever `f()` returns `nil` or `false` — the middle value
is lost. This passed a raw function to `nvim_set_hl` in `db_browser/theme.lua` when a spec
function legitimately returned nil ("skip this group"). When the middle expression can be
nil/false, write an explicit `if`.

## References

| Want | Go to |
|------|-------|
| **Adding a SQL dialect (aliases or real)** — touchpoint checklist, priorities, pitfalls | `docs/dev/sql/dialect-support.md` |
| **Vendored shared infra (state, cli, util, select, layout, dialog, indicators, installer)** | `lua/poste-db/` — vendor source poste.nvim@5b3759e `lua/poste/` |
| **Binary NDJSON schema contract (the family contract)** | `../poste.nvim/docs/schema.md` |
| **Rust CLI (crates, build system)** | `../poste.nvim/crates/` |
| **AI chat generic layer (chat UI, SSE, markdown, context API)** | `../poste-ai.nvim/lua/poste-ai/` + `docs/dev/sql/ai-chat.md` |
| **Preflight / audit / test / architecture / refactor / nav / introspect harnesses** | `.opencode/skills/` |
| Completion rules | `.opencode/skills/sql-completion/SKILL.md` |
| Build & test | `tests/run.sh` (needs plenary.nvim; optional `../poste-ai.nvim` and a locally built `../poste.nvim` binary — specs stub the transport) |
| Agent learnings | `LEARNINGS.md` |
