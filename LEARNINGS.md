# LEARNINGS

> A record of agent mistakes. Every entry comes from something that actually
> happened in this repo (starting with the 2026-08 architecture-refactor
> sessions), not generic best practice. Scan it before touching anything —
> do not make the same mistake twice.
>
> Companion harnesses: `.opencode/skills/sql-audit-harness/` (evidence
> rules), `sql-refactor-harness` (shells/Lua traps), `sql-architecture-harness`
> (primitive entry points).

## 1. Audit hearsay is not evidence

**What happened**: several "dead code / smell" conclusions from a subagent
audit turned out wrong on re-check —

- `format.format_number` was judged dead; `sql_format_bigint_spec` covers it;
- `state._hide_header_float` / `_hide_row_numbers` were judged "written but
  never read, dead state" — they are **user-settable hide switches** set from
  the outside ("read but never written" ≠ dead);
- `nav_cell.toggle_cell_highlight` has zero production callers but has tests —
  a test-only surface whose removal is a product decision, not cleanup;
- the cursor dual source of truth (`tab.cursor` vs `sql_state.cell`) was
  judged "structural drift"; enumerating every reader/writer found only 3
  dual-write sites, all correctly synced — the conclusion was revised to
  won't-do.

**Rule**: subagent output = hypothesis. Anything acted on or written into a
report must be re-verified by your own grep + code reading, marked
verified / inferred. When deeper reading overturns a conclusion, amend the
record explicitly — never silently rewrite it.

## 2. Distrust a 0-hit grep before trusting it

**What happened**: a shell loop ran `grep -c "$m\."` where `$m` was `D\.`,
making the real pattern `D\.\.` — 0 hits → judged the `dataset` require
unused → deleted it → `D.T()` raised `attempt to index global 'D' (a nil
value)` at runtime. The full suite caught it; grep alone would not have.

**Rule**: before deleting anything justified by a 0-hit grep, print the
pattern and eyeball it against the real call shapes (`D.T()` needs `D\.T`;
check `M.x`, local aliases, method calls, and `_test` exposure separately),
then run `tests/run.sh` after the deletion. Grep is necessary, not
sufficient.

## 3. Demoting `M.x` to a local: check every call site's lexical position

**What happened**: `format.lua` demoted `M.normalize_type` to a local, but
`is_numeric_column` (~line 180) called it before the definition (~line 438)
→ `attempt to call global 'normalize_type' (a nil value)`, 2 suite failures.
This is the AGENTS.md "local function forward declaration" rule's variant —
the trap only bites when definition and call are hundreds of lines apart.

**Rule**: before `M.x` → local, grep every call site; if any call precedes
the definition, either forward-declare `local x` or move the whole definition
above the first use.

## 4. `and f() or f` is not a ternary

**What happened**: `db_browser/theme.lua`'s first draft wrote
`type(spec) == "function" and spec() or spec`; operations' spec functions
return nil BY DESIGN ("defined = skip") → `and spec()` was nil → the
expression fell back to `spec` itself (a function) → the function reached
`nvim_set_hl` → `Expected Lua table`, and the whole require chain exploded
with the error reported at the OUTERMOST require — nearly impossible to
locate.

**Rule**: when the middle value can be nil/false, the and-or idiom is
forbidden; write an explicit if. Require errors in a dependency chain report
at the outermost require — when you see "loop or previous error loading
module 'X'", the real error is inside X's loading, not at the site
referencing it.

## 5. Refactoring must clean up: a leftover shell means the job is not done

**What happened**: past refactors left empty shells that this round cleaned
up — the empty `invalidate_sep_cache()` plus 4 ritual calls, `clear_panel`'s
ignored parameter, the 173-line zero-reference `context_client.lua` module,
`HEADER_LINES = 0` threaded through 29 pointless subtractions. The shells
show that "extract the seam" and "delete the old path" were treated as two
separate jobs.

**Rule**: extract the seam and delete the old shell in the SAME commit. When
picking a seam, first ask: is its old shell still there?

## 6. Merging duplicate implementations = choosing behavior for someone else; spell out the delta

**What happened** (all deliberate and recorded in commits/reports):

- two `format_bytes` outputs differed (`kB`/2 decimals vs `KB`/1 decimal) →
  unified on one;
- four completion-fetch scaffolds had different exit semantics → unified on
  ensure_columns' version, which also fixed the other three's latent defect
  ("job exits 0 with empty stdout → callback hangs forever");
- flash's highlight groups merged into the unified theme gained user-override
  support it never had.

**Rule**: deduplication is not a pure move. List every behavior delta (output
format, failure value, new capability) in the commit message; user-visible
output changes (e.g. `kB`→`KB`) must be declared explicitly.

## 7. Moving code between modules: enumerate the closure captures first

**What happened** (a done-right example): when `sql_runner`'s two ~200-line
`on_response`/`on_error` closures moved to `sql_runner/response.lua`, every
captured upstream variable was listed first as an explicit `deps` table
(live state like `exec_seq` passed as a getter) — the move was text-level
with zero behavior risk.

**Rule**: before a cross-module move, write down every upstream variable the
closure captures and turn each into a deps field or parameter. The capture
list IS the function's dependency manifest; afterwards, delete requires the
donor module no longer needs.

## 8. `package.loaded` stub capture timing

**What happened** (a done-right example): `sql_sql_runner_spec` stubs
`poste.state`, `poste.indicators` etc. BEFORE requiring `poste-db.sql_runner`.
A new module split out of sql_runner with top-level requires of those modules
captures the same stubs — but a top-level require of an UNstubbed module
(e.g. `poste-db.context`) really loads. The latter was deliberately kept as a
lazy in-function require.

**Rule**: before adding a top-level require to a module that some spec stubs,
check what that spec stubs and whether the stub is installed before the
require. Unstubbed dependencies go lazy, inside the function body.

## 9. UX-visible framework migrations are not done in headless sessions

**What happened** (a done-right example): retiring `forms.lua` into
`forms_advanced` would have swapped operations' three dialogs for another
form framework — focus, editing flow and cancel semantics had no test
coverage, and something headless tests cannot exercise does not count as
verified. Deferred, with the migration path documented in the report.

**Rule**: a refactor that changes user-visible UX needs a "real session"
verification step. A green headless suite ≠ shippable. If real verification
is impossible, defer and document — do not force the migration.

## 10. Coexisting with the user's uncommitted work

**What happened**: the session started with user WIP in the worktree
(sql_runner indicator logic), and mid-session NEW user edits appeared
(connections.toml, mysql-test.sql).

**Rule**: `git status` before touching anything; user WIP becomes its own
commit (honestly described), your refactor batches get their own commits —
never one mixed diff. New user edits may appear mid-session — when wrapping
up, if you find changes you do not recognize, leave them alone.

## 11. tree-sitter false-positive filters: one construct has several recovery shapes

**What happened**: adding mssql/clickhouse false-positive filters to
`ts_stmt.find_error_nodes`, the single construct
`STRING_AGG(x, ', ') WITHIN GROUP (ORDER BY y)` left THREE different ERROR
shapes on the tree depending on context: ① `GROUP (ORDER BY y) AS z` (the
head swallowed by the invocation, with a multi-column select); ②
`STRING_AGG(x, ', ') WITHIN` (invocation + orphan WITHIN, on the last
column); ③ the fragment `o.status` (a qualified column inside a pseudo
`GROUP (...)` invocation; the existing bare-word filter only matched
`^[%w_]+$` and missed it). The first filter covered ① only; the suite
produced ②③. Also, `syntax.lua`'s un-reddening is a HAND-WRITTEN MIRROR of
`find_error_nodes` (`KNOWN_CONSTRUCT_MARKERS` + `CONSTRUCT_KEYWORDS`) — a
new filter not synced there means "diagnostic gone but still red"; the
missing OFFSET/FETCH coloring happened exactly because `CONSTRUCT_KEYWORDS`
lacked those words.

**Rule**: before adding a false-positive filter, run a probe script (headless
nvim parses the target SQL, dumps every ERROR node's text/parent/ancestor
chain) and give each shape its own rule; pair every filter with two tests
(the false positive swallowed + a real error `SELECT * FORM users` still
reported). Sync `syntax.lua`'s two tables in the same change; for changes
involving structural decisions (prev/next sibling), verify in both
directions at least once — temporarily stash the fix, run the new test,
confirm it actually catches the original bug.

## 12. A seed script's ordering bug is invisible on first init

**What happened**: `playground/init/clickhouse/01-playground.sql` INSERTs into
`events_raw` BEFORE creating the `TO events_daily` materialized view — a TO
type MV only aggregates inserts made AFTER its creation, so first init is
silent but `events_daily` stays empty forever (`countMerge(cnt)` returns 0
rows). The same file has a second ordering trap: the top-level DROP list
omits `events_raw`, so first init is fine and the re-run dies with
TABLE_ALREADY_EXISTS.

**Rule**: after landing a new dialect's seeds, immediately run
`docker exec -i ... < seed.sql` against the real container TWICE (not just
the first init) and spot-check every table's row count > 0; when the seed
involves MV/CTAS/trigger-style "data-driven" objects, treat the
create-object vs load-data ordering as an explicit test point.

## 13. gsub literal finds must pesc; characterization tests use whole-string equals

**What happened**: adding characterization tests to the extracted
`copy_ddl.lua` caught three latent bugs at once: ① `rename_seq_reference`
(copy_ddl.lua:93) fed `nextval('...')` straight into `gsub` as a pattern —
parens are magic characters, it NEVER matched, and copied tables kept a
DEFAULT pointing at the old sequence (same-server copies survived on the old
sequence's existence while the counter drifted; cross-server DDL failed
outright); ② `rename_routine_in_def`'s mysql branch (copy_ddl.lua:159) took
`sub(1, open)` one backtick too many and hand-concatenated another, producing
`` ``proc_copy`` `` — MySQL parses doubled backticks as an escaped literal
backtick, invalid DDL; ③ `prepare_table_ddl` re-prefixed the schema on an
already schema-qualified nextval reference, `CREATE SEQUENCE
"public"."public".…` inconsistent with the rewritten DEFAULT. All three
survived a long time in production because nothing tested the code before
the split, and ①③'s damage shapes ("old value still there" / "one extra
prefix") raise no error.

**Rule**: when a `gsub/gmatch/match` needle contains `(` `)` `'` `%` `-` etc.,
it must go through `vim.pesc` (escape `%%` on the replacement side);
asserting "the rewrite took effect" must assert the OLD value is GONE
(`select(2, gsub(...))` counting or whole-string equals), not just that the
new value matches — `matches("``proc_copy`\\(`")` let ②'s doubled backticks
through. When adding tests to "pure functions", prefer whole-string equals;
substring matches are for loose smoke checks only.

## 14. MySQL seed mojibake = the init connection's charset, not a plugin read bug

**What happened**: everything under `playground/init/mysql/` (cinema worst)
showed Chinese/Japanese/Cyrillic as mojibake in the dataset. The bytes read
via `docker exec ... mysql` were double-encoded: the character U+5916 (`E5A496`) stored as
`C3A5C2A4E28093`. Root cause: the official mysql image's `/entrypoint.sh`
calls its `docker_process_sql` client WITHOUT `--default-character-set`, so
the client's default session `character_set_client` = latin1 (MySQL's latin1
= cp1252; `0x96` maps a UTF-8 Chinese byte to `–` before any `SET NAMES`),
and the seed's UTF-8 bytes went through a latin1→utf8mb4
"interpret once, store converted" = double-encoded into the database. The
files and the databases were utf8mb4 to no effect. poste's sqlx connection
defaults to utf8mb4 and faithfully reads the bad bytes back, so the mojibake
lives in the database, not the read path.

**Rule**: any seed file under `playground/init/mysql|mariadb/` containing
non-ASCII MUST start with `SET NAMES utf8mb4;` (pure ASCII, before any
multibyte byte stream). After landing a new dialect's seeds, rerun fully per
#12 and spot-check one multibyte row:
`SELECT HEX(name_zh)>0 AND name_zh=CONVERT(name_zh USING utf8mb4) ...`.

---

## 15. BINARY column mojibake lives in the Rust value conversion, not the Lua side

**What happened**: `game_achievements.hidden_hid` (`BINARY(16)`) displayed as
a string of `�` in the dataset. The data itself was fine (`HEX(hidden_hid)`
in the mysql CLI reads `8885031DAE8A11F19D8C669C27760320`). Root cause: the
Rust CLI's `mysql_value_to_json` (`poste.nvim/crates/poste-cli/src/
{exec_file,session}.rs` plus `poste-exec/src/sql_executor/{mysql,value}.rs`)
runs `Vec<u8>` through `String::from_utf8_lossy`, so BINARY's invalid UTF-8
bytes were replaced with U+FFFD on the Rust side — the JSON carried the
damage out and Lua could never recover the bytes. Fix Rust, not Lua. The
fix: a `mysql_binary_to_hex` branch for
BINARY/VARBINARY/TINYBLOB/MEDIUMBLOB/BLOB/LONGBLOB, emitting uppercase hex
per MySQL's `HEX()` convention.

**The label is not the data** (2026-10-30). That branch keyed on the
driver's type name alone, and MySQL 8 sets the `BINARY` flag on *text*
columns: `SHOW DATABASES`, `SHOW TABLES` and every `information_schema`
string column collate `utf8mb3_bin`/`utf8mb4_0900_ai_ci` but still report
`Flags: ... BINARY`, which sqlx renames to `VARBINARY`/`BINARY`/`BLOB`. So
every database and table name arrived hexed — `show databases` answered
`696E666F726D6174696F6E5F736368656D61` instead of `information_schema`, and
`describe` hexed its `Type`/`Key`/`Default` cells too. No encoding bug: the
BLOB label just lied. The fix is `mysql_binary_cell_to_json`: hex only when
the bytes are not text (invalid UTF-8, or a NUL from `BINARY(n)` padding),
otherwise emit the decoded string. Both halves matter — a `utf8mb4_bin`
column is text, a `BINARY(16)` UUID is not. Regression tests
`metadata_text_columns_are_not_hexed` and `real_binary_payloads_still_hex`
pin each side. Note how this reached a user at all: the release tag lags the
fix — `v0.1.3` predates `203c4f2`, so only a locally built debug binary
shows it.

**Rule**: poste plugins' queries default to `poste session`
(`poste-db/executor.lua`'s `prefer_session=true`); the session path is the
live converter and exec-file is the fallback (visual selections also go
through exec-file). Changing one means changing the other; both now call the
single `poste-exec/src/sql_values.rs` copy (the old
`sql_executor/mysql.rs` duplicate went away with the shared-loop refactor).
Verification: feed the binary
`{"seq":1,"sql":"SELECT hidden_hid FROM cinema.game_achievements LIMIT 3;"}`
directly and check the returned JSON's `hidden_hid` equals `HEX(hidden_hid)`,
then run `show databases` and check it answers names, not hex; after
changing, `cargo build` to rebuild `poste.nvim/target/debug/poste`
(the plugin resolves the binary by rtp directory, no install needed).

## 16. Devanagari overwrites the dataset's right border: strdisplaywidth folds Mc marks

**What happened**: `सिंधु घाटी` (10 code points) measured 5 cells under
`strdisplaywidth` while the terminal painted 8 — vim's composing table does
not distinguish Mn non-spacing marks (ं ु, 0 cells on both sides, harmless)
from Mc spacing marks (ि ा ी, 1 cell each in the terminal), so every cell
containing an Indic Mc mark under-padded and the trailing `│` was painted
over, shifting every later column. CJK-safe truncation could not help: this
is not "measured 1, painted 2" (same-source skew) but vim 0 vs terminal 1 —
`strdisplaywidth` itself is the wrong oracle.

**Rule**: width/truncation in the dataset rendering path goes through
`lua/poste-db/width.lua` (`display_width`/`truncate`, switching between
terminal and nvim oracles per `width_mode`), never a direct
`vim.fn.strdisplaywidth`. The `MC_FOLDED` range table is the product of
probing "Unicode Mc ∧ this nvim's folding" — Mc that vim does not fold is
already counted 1 by itself, "fixing" it again would double-count; nvim
bundling a newer Unicode table requires regenerating it. The regression test
is `tests/sql/width_spec.lua` (invariant: every line containing `│` has equal
display_width). Note `l:sub(-1)` grabs the LAST BYTE of `│` (0x82), not a
character — assert borders with `vim.endswith`.

**The two drawing paths (2026-09-13, verified on Ghostty 1.3.1)**: nvim
paints the same line two ways — a full-line fresh draw/scroll-in paints
linearly while the cursor tracks the TERMINAL's advance (Ghostty counts Mc as
1); cursor/highlight-triggered PARTIAL repaints position by nvim's own grid
absolute coordinates (Mc folded to 0). Each padding satisfies one path and
breaks the other: pad by vim width → fresh draws drift right 3 cells (the
original bug: the border is painted over); pad by the corrected width →
repaints shift left 3 cells ("indented"). Pure padding cannot win, so it
landed as `setup({ width_mode = "nvim" | "terminal" })` (default nvim, consistent
with cursor/navigation/repaints; terminal gets fresh draws right). Lesson: an
A/B probe table only validates the fresh-draw path — "looks aligned" does not
mean every path agrees; identify which drawing the user is looking at before
judging. The real fix lives upstream (nvim's width table folding Mc) or in a
GUI client (where the grid is the only truth). Also: text copied out to the
terminal is folded by the receiver's renderer, so "misaligned on paste" is an
illusion — do not draw conclusions from it.

---

## Plenary harness: `after_each` registered outside a describe → directory mode silently drops files (2026-09-14)

**What happened**: three new specs (e.g. `sql_exec_run_log_spec.lua`) wrote
`after_each(...)` at file top level, outside any describe. Run alone via
`PlenaryBustedFile` everything passed, with only a trailing
`Error in command line: busted.lua:147: bad argument #1 to 'insert'`
(`table.insert(current_after_each[#current_description], fn)` with
`#current_description` nil outside a describe); but under `tests/run.sh`'s
`PlenaryBustedDirectory`, the child process died from that error BEFORE
reporting — "Scheduling:" printed, the "Testing:" line never came, 84 files
ran as 81, and `run.sh` only exited 1 with zero failures in the body — very
easy to misread as all-green.

**Rule**: `before_each`/`after_each` go INSIDE the `describe` block (all
existing specs do this; see `tests/sql/sql_executor_spec.lua`). When
accepting directory-mode results, check three things: `grep -c '^Testing:'`
== the spec file count, per-file `Failed :` all 0, and `run.sh` exit code 0 —
the exit code alone or one green line is not enough. Also, ERROR-level
`vim.notify` fired outside a test's lifecycle goes down the error channel and
kills the harness: specs that drive async callbacks (e.g.
`sql_db_browser_introspect_log_spec.lua`) must stub `vim.notify` and `vim.wait`
within the test's lifetime to drain `vim.schedule`, preventing cross-test
leaks and late-callback crashes.

---

## A top-level ERROR sibling splits statement boundaries too, not just diagnostics (2026-09-23)

**What happened**: `LIMIT 1, 10` (MySQL/SQLite/ClickHouse's
`LIMIT offset,count` pagination) parses in tree-sitter-sql as a `limit 1`
statement plus a TOP-LEVEL ERROR sibling `, 10`. Adding the dialect filter to
`find_error_nodes` and the un-reddening matcher per #11 fixed diagnostics —
but the top-level ERROR sibling was ALSO read as a statement: `ts_stmt.lua`'s
`find_stmt_span` binary-searches "the last span starting ≤ the line", so a
cursor on the LIMIT line extracted and executed `, 10;` as the current
statement; `find_all_stmt_lines` counted it as a statement start, producing
duplicate start lines on single-line writes. Diagnostics got fixed; execution
was still broken. Most known false positives (INTERVAL, digit prefixes,
WITHIN GROUP) are NESTED errors; only top-level siblings split spans, which
is why the trap had not surfaced — the `; USE` cascade and ClickHouse ALTER
DELETE predicates are top-level siblings too and were equally affected.

**Rule**: when adding a "top-level ERROR sibling"-style filter, align the
shape test at all three consumers: `find_error_nodes` (diagnostics,
dialect-gated), `build_span_list` (current-statement span — MERGE into the
previous span, do not skip), `get_top_level_stmts` (statement start lines —
skip). The probe must dump top-level children as well as ERROR text, to tell
a nested ERROR from a sibling first; probe both with and without a trailing
`;` — without one the ERROR swallows the NEXT statement (`, 10 SELECT 2`),
and the anchored match must keep reporting that.

## 19. Rewriting Lua sources with a script: it is not done until luacheck passes

**What happened**: adding `{ title = "PosteDb" }` to 117 `vim.notify` calls,
the first script draft located calls by "find `vim.notify(` + balance
parentheses" — it also matched `vim.notify(…, INFO/WARN)` in DOCSTRING
comments, and the balancing ran from the comment to somewhere far away,
flattening whole files to one line (source_format.lua lost 451 lines,
-7420 total). The second draft fixed comment detection, but `scan_calls`
returned an `end` already past the closing paren and the caller did
`end+1`, generating `vim.notify(..., LEVEL), { title = ... })` — the title
landed OUTSIDE the call, still a syntax error. Both were caught by the
abnormal deletion counts in `git diff --stat`.

**Rule**: a script that batch-rewrites source must (1) be a full-file lexer
state machine (code/string/long-string/comment/block-comment), not "find +
balance"; (2) self-check each rewrite — re-lexing the output must yield
exactly itself; (3) immediately after apply, run `luacheck` + a `loadfile`
syntax sweep over the whole tree, before tests; (4) `git status` must be
clean before starting, and when reverting,
`git checkout -- <files>` reverts the set the script touched — be careful
not to roll back manual fixes living in the same files (this incident had to
replay manual fixes twice).

## 20. Deduplicating autocmd callbacks by content equivalence: per-instance registration via instance closures is a dead end

**What happened**: adding ColorScheme invalidation to `statusline.lua`'s
per-connection highlight cache, the drop callback was written as an instance
closure (`callback = function() hl_cache = {} end`, rebinding the module
local). The spec environment reloads this module (the mini-wiring test does
`package.loaded[...] = nil` then require), and in practice: after a reload
the new instance registered via `nvim_create_autocmd` with no error and the
same group id, but `nvim_get_autocmds` shows EXACTLY ONE handler forever —
this Neovim dedupes content-equivalent (constant-folded equal) callbacks,
silently dropping the later registration. So whether `clear = true` (the
last instance's clear removes every earlier instance's handler; old caches
never invalidate) or `clear = false` (only the first instance's cache ever
invalidates), part of the caches stayed stale after `:colorscheme` forever.
Isolated single runs and manual probes could not reproduce it; only running
the reload test BEFORE the cache test in the same file reproduced it
reliably.

**Rule**: state that must survive reloads cannot live in instance closures —
invalidation handles belong somewhere reload survives (`vim.g` counters /
epochs preferred), each cache entry carries an epoch checked at read time,
and the handler only bumps. Before writing a test that depends on autocmd
registration ordering, count actual registrations with `nvim_get_autocmds`
— do not trust `create_autocmd`'s return value; an "passes alone, flakes in
the full run" failure should first be suspected against earlier tests'
registrations/state in the same file.

## 21. Hoisting a require in a "stubbed module": the full gate stays green, single-file runs explode

**What happened**: round 57 hoisted `nav/handlers.lua`'s
`require("poste-db.context")` from the function body to module top level
(alongside the new `context.detect_command`). `sql_nav_spec.lua` uses
`stub_module("poste-db.context", ...)` to replace `package.loaded` INSIDE the
test body, but the spec file already `require("poste-db.nav")` at the top —
the top-level require made handlers capture the REAL module at that moment
and the stub never landed. More insidious: the FULL `tests/run.sh` stayed
GREEN (other specs loaded the real `poste-db.context` earlier, so
`stub_module`'s save/restore was saving and restoring the real module —
behavior coincidentally identical), while
`tests/run_one.sh tests/sql/sql_nav_spec.lua` alone went red. The same day
had a second variant: `sql_nav_spec`'s fallback stub for `poste-db.util` was
a hand-written fake module (`{ clean_nil = ... }`), and once nav/detect
started calling `util.unquote_ident` it nil-indexed — again only on
single-file runs (in the full run util was already loaded, so the fallback
branch never executed).

**Rule**: (1) before adding a top-level require to a module that some spec
stubs via `package.loaded`, grep that module's spec for
`stub_module`/`package.loaded`; the convention is that handler layers keep
lazy requires, with the reason documented in the file header comment.
(2) A leaf module's fallback stub should fall back to the REAL module
(`saved or require(...)`), never a hand-written fake — a fake becomes a nil
index the day the real module grows a new function. (3) Any change touching
require structure MUST be accepted with a single-file run of the affected
spec; a green full run does not count (the two environments are not
equivalent in `package.loaded` pre-fill — `tests/run_one.sh`'s header comment
records another instance).

## 22. Lua negative indices count from the end: `s:sub(1, cut)` must clamp cut non-negative first

**What happened**: `util.utf8_safe_cut` (`lua/poste-db/util.lua`) did a plain
`s:sub(1, cut)` when the budget exceeded the string length. With a caller
passing `max_bytes = -1`, `#s <= max_bytes` was false and `while cut > 0`
skipped, so `("abc"):sub(1, -1)` — per Lua semantics — returned `"ab"`:
negative indices count from the END, so -1 means "drop the last character",
not "take nothing". The caller asked for truncation and got back nearly the
whole string, with no error anywhere (found in the 2026-10-19 review; fixed
by returning the empty string for `max_bytes <= 0`).

**Rule**: any `string.sub`/`string.byte` positional argument that can go
negative (from computation, config, or external input) must be clamped to a
legal range first. Sibling traps: `s:sub(i, j)` with `j < i` returns ""
(harmless) and `("abc"):sub(2, -2)` returns `"b"` (turning "the middle part"
into "drop both ends"). When auditing this class, look specifically for
`sub(1, <variable>)` where the variable has no lower-bound guard.

## 23. Before declaring dead code, derive every alias from the require lines — do not guess alias names

**What happened**: in the 2026-10-24 review, a subagent judged
`constants.lua`'s `M.TITLE = M.PLUGIN_TITLE` alias "zero usage". Re-checking
found 12+ uses in the `buffer/` subtree — all as `C.TITLE`, because those
files write `local C = require("poste-db.constants")`. The subagent grepped
`const.TITLE` / `constants.TITLE` (guessed alias names); this repo binds the
same module under at least four aliases (`C`, `const`, `constants`,
`core_util`; `state` also has `sql_state`/`poste_state`).

**Rule**: before declaring an `M.x` export dead, run
`grep -rn 'require("poste-db.<mod>")' lua/` to get EVERY bound local name,
then grep `alias.x` for each. Guessing alias names searches only a subset of
the symbol space; the harness's "grep both shapes" local-alias instruction
translates to exactly this step.

## 24. Backticks in a commit message get eaten by shell command substitution

**What happened**: in the 2026-10-28 review session, commit messages written
inline as `git commit -m "..."` contained code references like
`` `visual_sel_end or #buf_lines` `` — zsh executed them as command
substitution ("command not found") and the commit STILL SUCCEEDED with those
spans silently deleted from the message (three messages were damaged; only a
verbatim `git log` comparison caught it).

**Rule**: when a commit message contains backticks (or `$`, `!`), do not use
inline `-m`. Write the message to a temp file and use
`git commit -F <file>`; or verify with `git log -1 --format=%B` word by word
after committing instead of trusting the exit code.

## 25. A guard with a release path but no set path: write the test before the guard, not after

**What happened**: in the 2026-10-30 audit session, the `commit_edits`
in-flight guard (edit_commit/init.lua) was written as a `commit_in_flight`
module-local with clears in `on_response`, `on_error` and the failed-start
branch — but the `commit_in_flight = true` assignment before `run_async` was
never written. Every clearing site was in place; the guard simply never
engaged. The spec written for the guard ("refuses a second dispatch while a
commit is in flight") caught it on the first suite run.

**Rule**: a boolean guard needs BOTH transitions spelled in the same edit —
grep the flag name after writing it and count the assignments, not just the
reads (`grep -c "flag = true"` alongside the clears). A guard test that
exercises the blocked path is what makes the missing set observable; write it
in the same change, and trust its red over a green suite that never reaches
the branch.

## 26. `os.date("!*t")` carries `isdst = false`, and `os.time` honours it

**What happened**: the round-5 fix for DST-wrong timestamps (format.lua) first
computed the local offset as `at - os.time(os.date("!*t", at))`. For a July
instant in Berlin that returned +3600 instead of +7200: `os.date("!*t")`
returns a table with `isdst = false`, and `os.time` *reads* that field, so the
summer instant was interpreted as standard time. A second error (adding the
offset again before `os.date`) cancelled it for UTC values but not for
`+02:00` ones, so a naive spot-check looked right.

**Rule**: when converting between local and UTC with `os.time`/`os.date`,
always `t.isdst = nil` before feeding a table back to `os.time`, and remember
`os.date(fmt, epoch)` already renders local. Verify with
`TZ=Europe/Berlin` on a **summer and a winter** value plus a `+HH:MM` string —
one value in one zone cannot distinguish "correct" from "two errors cancelling".

## 27. Cache the payload, not the fact that you fetched it

**What happened**: `editor/column.lua`'s `pk_cache` was keyed
`conn:db:table` and stored `true`. The metadata it fetched (primary_key /
default / enum_values) is written onto a *layout*, and a second dataset for the
same table is a new layout — so the cache hit returned before touching it and
that dataset had no primary key. Commits then used the all-column WHERE
("may update several rows") and the PK column became editable again.

**Rule**: a cache key that names a *resource* must store the resource's data,
not a "done" flag, whenever the consumer is a fresh object per call. Grep the
cache name and ask, for every hit path, "what does the caller receive?" — a hit
that returns nothing is a hit that silently skips the work.

---

*Latest: 2026-10-30 round-5 audit session (#26 isdst trap, #27 cache the
payload). When adding an entry, keep the format: what happened (with file:line)
→ the rule (an executable check to run).*
