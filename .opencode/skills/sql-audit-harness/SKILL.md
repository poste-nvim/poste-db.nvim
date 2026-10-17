---
name: sql-audit-harness
description: >
  Evidence rules for code audits and architecture reviews. Use when
  reviewing code, hunting smells, writing findings reports, or acting on
  a subagent's audit output.
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
metadata:
  trigger: audit|code review|code smell|findings report|architecture review|verify claims|subagent audit|dead code check
---

# SQL Audit Harness

Subagent audit output is a hypothesis, not evidence. Every claim you act
on or write into a report must survive your own verification.

## Evidence rules

- Every report claim carries `file:line` AND was independently verified by
  you (grep + read the site). Never relay a subagent's claim verbatim.
- Mark each claim `verified` (you grepped and read it) or `inferred`
  (hearsay). Readers must be able to tell which.
- A report describing completed work is written or amended AFTER the work,
  against the actual diff. (A draft once recorded the wrong direction of a
  formatting unification because it was written before the code.)
- When deeper reading contradicts an earlier finding, amend the report with
  an explicit revision note — do not silently edit or quietly drop it. Model:
  an audit's "state dual source" item was revised to won't-do once every
  writer/reader of both sides had been enumerated; the review itself was
  archived in 75382cc, the revision RULE is what survives here.

## Dead-code rules

"Dead" requires ALL of: zero production callers, zero test references, not
part of a `_test` export surface, and not user-settable state.

- "Read but never written" is not dead — it may be a toggle users set
  externally. (`state._hide_header_float` / `_hide_row_numbers` are exactly
  this; `highlight_cell` and `format_number` looked dead to an audit but
  have tests.) Check `sql_state_spec.lua` and test files before deleting.
- A deletion justified by a 0-hit grep needs the grep itself sanity-checked:
  print the pattern and eyeball it against the real usage forms. A shell
  loop once turned `D\.` into `D\.\.`, matched nothing, and deleted a live
  require — the suite caught it, grep alone would not have.
- Grep both shapes of every symbol: `M.x` export, local alias, method call,
  and `_test` exposure.
- After every deletion batch, run `tests/run.sh`. Grep is necessary, not
  sufficient.

## State-duality rules

- Before proposing to unify a "dual source of truth", enumerate every
  writer and every reader of both sides. If the sync points (save/apply,
  reset, clamp) cover all writers, the duality is contained — recommend
  won't-do with the evidence instead of churning working sync code.

## Report layout

- Findings first with evidence tables; roadmap with per-phase acceptance
  criteria and completion status; explicit "not done and why" section.
  See `docs/dev/sql/architecture-review.md` for the shape.
