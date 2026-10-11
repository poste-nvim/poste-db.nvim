# Vendored infrastructure

This repo vendors shared modules from
[poste.nvim](https://github.com/beyondlex/poste.nvim) so that `poste-db.nvim`
has **zero runtime dependency** on any sibling plugin. The only cross-repo
contract is the `poste` Rust binary (schema:
[`../poste.nvim/docs/schema.md`](https://github.com/beyondlex/poste.nvim/blob/main/docs/schema.md)).

This file is the **re-vendor baseline**: it records what was vendored, from
which commit, and how to re-vendor when the upstream changes.

## Pin

| Field | Value |
|-------|-------|
| Source repo | `beyondlex/poste.nvim` |
| Source commit | `5b3759e` |
| Vendored on | 2026-09 (family dissolution) |
| Source paths | `lua/poste/{state,cli,util,select,layout,dialog,indicators,install,constants}.lua` |
| Target paths | `lua/poste-db/{state,cli,util,select,layout,dialog,indicators,install,constants}.lua` |

Each vendored module carries a header comment naming the source commit, e.g.
`vendored from poste.nvim@5b3759e lua/poste/cli.lua (family dissolution)`.
That comment is the per-file provenance marker — grep for `poste.nvim@` to
enumerate every vendored touchpoint.

## What was trimmed during vendor

The vendored copies are **not** byte-identical to the upstream. The following
were dropped or narrowed because they only made sense in the multi-protocol
family context:

- `install.lua` — `plugin_tag`, `schedule_version_sync`,
  `installed_version`, and `update` were dropped. The git-tag version sync
  matched the binary against the *plugin checkout's* tag, which is
  meaningless in a sibling repo (sibling tags are not poste.nvim release
  tags). `REPO` stays `beyondlex/poste.nvim` — one binary for the whole
  family.
- `state.lua` — HTTP/Redis context fields removed; SQL-only surface kept.
- `constants.lua` — only the entries consumed by this plugin's vendored
  `indicators.lua` and `copy_progress.lua` were kept.
- Module namespaces renamed `poste.*` → `poste-db.*` throughout.

## Drift policy

The upstream (`poste.nvim`) is the source of truth for these modules. When
deciding whether to re-vendor:

1. **Bug fix in upstream** → re-vendor the affected module. Cherry-pick the
   fix, update the header commit hash, update the pin table above.
2. **New feature in upstream** → only re-vendor if the feature is useful to
   the SQL plugin. Most family-wide features (new protocol modules, HTTP/
   Redis concerns) are irrelevant here.
3. **Breaking change in upstream** → the binary schema is the contract; if
   the schema changes, both the binary and this repo's vendored CLI/state
   code must move together. See "Re-vendor procedure" below.
4. **No change in upstream** → do nothing. Vendored code does not rot on its
   own; it only needs attention when the upstream moves.

## Re-vendor procedure

When re-vendoring a module (e.g. `cli.lua` after an upstream bug fix):

```bash
# 1. Identify the upstream change
cd ../poste.nvim
git log --oneline 5b3759e..HEAD -- lua/poste/cli.lua

# 2. Read the new version
git show HEAD:lua/poste/cli.lua

# 3. Diff against the vendored copy
diff <(git show 5b3759e:lua/poste/cli.lua) \
     /path/to/poste-db.nvim/lua/poste-db/cli.lua
#   ↑ this shows what THIS repo changed on top of the upstream baseline
#   ↑ preserve those changes (namespace rename, trim, SQL-specific edits)

# 4. Apply the upstream change manually, preserving local modifications.
#    Do NOT blindly copy the upstream file over — the namespace rename,
#    trim, and SQL-only edits will be lost.

# 5. Update the header commit hash in the vendored file:
#    "vendored from poste.nvim@<new-commit> lua/poste/cli.lua ..."

# 6. Update the pin table in this file.

# 7. Run tests:
cd /path/to/poste-db.nvim
tests/run.sh
```

## Why not a git submodule?

A submodule would couple this repo's checkout to poste.nvim's tree, which
defeats the purpose: the vendored copies are **deliberately trimmed** and
**namespace-renamed**, so they cannot be a straight checkout of the upstream.
The per-file header comments + this baseline file give the same traceability
without the coupling.

## The binary contract

The `poste` Rust binary is **not** vendored — it is built and released by
`poste.nvim`. `poste-db.nvim` discovers it at runtime via
`state.find_poste_binary()` (see `lua/poste-db/state.lua`) in this order:

1. `vim.g.poste_binary`
2. `$POSTE_BINARY`
3. `stdpath("data")/poste/bin/poste` (auto-downloaded from poste.nvim releases)
4. Local dev build (`target/{debug,release}/poste`)
5. `$PATH`

If the Lua side advertises a dialect the binary does not know yet, the binary
is authoritative. Unreleased Rust dialect work lives in the
`../poste-for-db` worktree (branch `poste-for-db`), kept separate so other
poste.nvim dependents are unaffected; merge into poste.nvim `main` when a
dialect ships. See `SUPPORT.md` § "Binary / dialect mismatch" for the user-
facing diagnosis path.
