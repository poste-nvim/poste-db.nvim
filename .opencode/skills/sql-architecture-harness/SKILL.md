---
name: sql-architecture-harness
description: >
  General harness for keeping SQL Lua code modular, readable, and easy to
  extend. Use when designing new code or when code starts turning into
  spaghetti, nested branching, or mixed responsibilities.
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
metadata:
  trigger: spaghetti|modular|modularity|architecture|refactor structure|nested branches|mixed responsibilities|thin wrapper|pure helper|module boundary|design new code|new feature structure
---

# SQL Architecture Harness

Use this when code shape matters more than the feature.

## Rules

- One module, one job.
- Entry functions should orchestrate, not do everything.
- Keep pure logic away from IO, UI, and global state.
- Split by responsibility, not by line count.
- Turn repeated guards into a shared helper or state module.
- Keep wrappers thin until callers move.
- Avoid another `if` inside already complex code.

## Pattern

1. Find the stable seam.
2. Extract the pure part first.
3. Move one branch or call site.
4. Keep the old entry as a wrapper.
5. Add/update a regression test.
6. Remove the wrapper when callers migrate.

## Smells

- Deep nested `if` / `elseif`.
- UI + command execution + state mutation in one file.
- Repeated `D.T()` / guard checks.
- Large top-to-bottom functions.

## Use the house primitives — do not re-roll them

These seams exist; new code goes through them, and migration candidates
are noted rather than re-implemented:

- Floating windows: `float_window.open()` / `open_centered()` — never
  hand-roll `nvim_open_win` + title-fallback + q/Esc + WinLeave again.
- db_browser highlights: `db_browser/theme.register()` — never hand-roll
  nvim_set_hl + apply_highlight_overrides + ColorScheme autocmd.
- Lazy `poste introspect` fetches (completion): `start_introspect_job` in
  `completion/data.lua` — in-flight dedupe, queued callbacks, epoch guard
  live there.
- db_browser tree refresh: `db_browser/util.refresh_subtree` /
  `render_tree` — the expand/refresh dance has one implementation.
- Identifier quoting: `ident.quote` / `quote_literal`.
- Response handling for SQL execution: `sql_runner/response.lua`.

An external UI framework (nui-components) was evaluated and rejected for
now (2026-08 architecture review, archived in 75382cc): it overlaps the
house primitives above without covering their q/Esc, backdrop-refcount
and ColorScheme-override behavior, and adopting it would change what
users see. Extending the in-house primitives is the default move.

## Know when NOT to unify

- A "dual source of truth" with correct, covering sync points is a
  contained duality, not a smell. Map every writer/reader before proposing
  a unification; if sync covers all writers, recommend won't-do with
  evidence.
- UX-visible framework migrations (retiring `forms.lua`, swapping dialog
  frameworks) change what users see. Headless plenary suites do not cover
  focus, editing, or keyboard flows. Defer with a documented migration
  path and require a real-session verification step — do not ship
  unverifiable UI changes to make a refactor "complete".
