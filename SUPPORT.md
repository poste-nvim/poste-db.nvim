# Troubleshooting & Support

**Before opening an issue, work through this page.** Most reports come down to
one of four causes, and the diagnosis path below pinpoints each in under a
minute. Issues that arrive without `:checkhealth poste-db` and `:PosteDbInfo`
output will be asked to provide them before triage.

---

## 1. Run `:checkhealth poste-db`

This is the single most useful diagnostic. It checks:

- **Neovim version** — the plugin needs ≥ 0.10.0 (`vim.system`, `vim.treesitter.language`).
- **`poste` binary** — whether one was found, which candidate won, and its version.
- **curl** — needed for the binary auto-download.
- **tree-sitter SQL parser** — needed for statement splitting and completion.
- **blink.cmp / nvim-cmp** — whether the `poste_db` completion provider registered.
- **Platform** — whether prebuilt binaries exist for your OS/arch.
- **`connections.toml`** — whether one was discovered from the current buffer.

```vim
:checkhealth poste-db
```

To copy the output to the clipboard for pasting into an issue:

```vim
:redir @+ | checkhealth poste-db | redir END
```

## 2. Run `:PosteDbInfo`

Where `:checkhealth` answers "is it installed?", `:PosteDbInfo` answers
"**which** binary is running and where did it come from?". It reports:

```
poste_binary: /home/you/.local/share/nvim/poste/bin/poste
from:         installed release
built:        2026-09-14 12:30:00
version:      poste 0.4.2 (2026-09-12)
connections:  /path/to/connections.toml
treesitter:   active (installed)
```

The **`from:`** line is the key field. The lookup order is:

1. `vim.g.poste_binary` — highest priority, set in your config
2. `$POSTE_BINARY` — environment variable, seen by CI and headless processes
3. Installed release — `stdpath("data")/poste/bin/poste`, auto-downloaded
4. Local dev build — `target/{debug,release}/poste` next to the plugin or cwd
5. `$PATH` — lowest priority

The installed release **outranks `$PATH`**. If you have a custom build on your
PATH but the plugin keeps using the auto-downloaded one, that's why — set
`vim.g.poste_binary` (or `$POSTE_BINARY`) to force your build.

## 3. Binary / dialect mismatch

**Symptom**: a SQL dialect or alias works in the Lua config but the binary
rejects it, or vice versa. The Lua side may advertise a dialect the stock
`poste` binary does not know yet (unreleased Rust dialect work lives in the
`poste-for-db` worktree, not in the published binary).

**Diagnosis**:

1. `:PosteDbInfo` → note the `version:` line.
2. Check [poste.nvim releases](https://github.com/poste-nvim/poste.nvim/releases)
   — does that version advertise the dialect you need?
3. If you need unreleased dialect work, build the `poste-for-db` worktree and
   point at it:

   ```bash
   cd ../poste-for-db && cargo build          # or: cargo build --release
   ```

   ```lua
   -- then in your config, before setup():
   vim.g.poste_binary = "../poste-for-db/target/debug/poste"
   -- or for headless/CI:
   -- export POSTE_BINARY=/path/to/poste-for-db/target/debug/poste
   ```

4. Restart Neovim and re-run `:PosteDbInfo` to confirm `from:` now names your
   build.

**The binary is the family contract.** If Lua and the binary disagree on a
dialect, the binary is authoritative — the Lua side is a client. See
[`../poste.nvim/docs/schema.md`](https://github.com/poste-nvim/poste.nvim/blob/main/docs/schema.md)
for the NDJSON schema shared across the family.

## 4. Connection problems

**Symptom**: statements fail with connection / auth errors, or `connections.toml`
is reported missing.

- The plugin walks **up** from the SQL buffer's directory looking for
  `connections.toml`. Open the SQL file from the project root, not from
  `~`.
- `{{VAR}}` references in `connections.toml` resolve from a `.env` file
  (same walk-up) or real OS env vars. Unknown references stay literal —
  a typo'd variable name silently becomes that literal string.
- `user` and `password` are percent-encoded automatically; values with `@`,
  `:`, `/`, `%` work as-is.
- For SSH tunnels, `ssh` must be on `$PATH`. `:PosteDbTunnel` lists active
  tunnels; `:PosteDbTunnel <name|--all>` stops them.
- `:checkhealth poste-db` reports whether `connections.toml` was found and
  from where.

## 5. Completion not triggering

- Works with **blink.cmp** (auto-registers the `poste_db` source) or
  **nvim-cmp**. `:checkhealth poste-db` reports which is loaded and whether
  the `poste_db` provider registered.
- Completion is **connection-aware** — it needs a resolved `@connection`
  directive in the buffer (or a `USE database` statement) to introspect the
  schema. Without a connection, only keywords and snippets complete.
- `:PosteDbCmpStatus` shows the live completion state for the current buffer.
- `:PosteDbCmpReload` re-registers the source if blink.cmp's config was
  loaded after the plugin.

## 6. AI chat does not appear

The AI chat is **optional** and requires
[poste-ai.nvim](https://github.com/poste-nvim/poste-ai.nvim) on `runtimepath`.
Without it, `:PosteDbChat` and `<leader>aa` are no-ops (by design — the
plugin silently skips AI features when the dependency is absent).

```lua
-- lazy.nvim
{ "poste-nvim/poste-ai.nvim" }
```

---

## Still stuck?

If none of the above resolved it, [open an issue](../../issues/new/choose) and
paste the full output of:

1. `:checkhealth poste-db`
2. `:PosteDbInfo`
3. `nvim --version | head -1`

The bug report template asks for exactly these — filling it in completely
gets you a response in hours instead of days.
