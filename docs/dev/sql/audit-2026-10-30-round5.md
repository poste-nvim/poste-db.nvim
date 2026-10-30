# Audit — 2026-10-30 (round 5)

Three read-only subagent audits ran in parallel over areas the previous rounds
had already covered, so the yield came from *deeper* reading (unusual data,
lifecycle races, hot paths) rather than new territory. Per
`sql-audit-harness`, every finding below was re-verified by hand — read the
site, then ran it headless where a run was possible — before any fix was
applied. One subagent claim did not survive that step and is recorded in
§4 so the next round does not chase it.

Scope: statement/ts_stmt/dml/format/source_format/toml/export/import/highlights
(A), buffer/editor/db_browser/layout (B), session/exec_run/sql_runner/
connections/config/state/commands/log_viewer/completion/install (C).

Result: 132 spec files green (`tests/run.sh`, 0 failures), luacheck clean
apart from the long-standing `explain.lua` empty-branch note.

## 1. Fixed — data loss and wrong values

1. **The browser's `<CR>` silently discarded uncommitted dataset edits** (P1).
   `buffer/init.lua:631` reset the active entry's tabs — and with them
   `edit_state` — for any `render_dataset` call that did not pass
   `keep_tabs`, while every other view-replacing path (run, tab/history
   switch, page change, sort, search) refuses while edits are pending.
   `db_browser/actions.lua:239` and the AI result render both took that path:
   an edit made in the dataset vanished without a word when the user clicked a
   table in the browser. The dirty guard now sits at the reset itself, so it
   covers all callers.
2. **Importing a JSON file of the wrong shape raised a bare Lua error** (P2).
   `import/format.lua` collected keys from every element it found and then
   `table.sort`ed them: `[{"a":1},[2,3]]` (a shape API dumps produce) mixed
   string and numeric keys and raised "attempt to compare string with number"
   from inside the preview — the dialog never opened. `[[1,2],[3,4]]` became
   numeric column names and raised in the column mapper. Both are now
   `"Expected array of objects"`, checked once up front.
3. **Import rounded decimals a double cannot hold** (P2). `coerce_value`'s
   guard only checked magnitude (`< 2^53`), which is an *integer* guarantee:
   `0.1234567890123456789` passed it and reached a `numeric(30,19)` column as
   `0.12345678901234568`, silently. A literal with a real fractional part now
   stays text past 15 significant digits (integers keep the magnitude rule, so
   `4503599627370496` still coerces).
4. **Timestamps rendered an hour off across a DST boundary** (P2).
   `format.local_utc_offset` measured the offset at "now" and applied it to
   every value, leaving `off(now) - off(value)` behind: a July
   `timestamptz` viewed in October rendered an hour early in Berlin, and the
   reverse in spring. Two traps were involved — the offset must be read *at the
   value's instant*, and `os.date("!*t")`'s `isdst = false` must be dropped
   before `os.time` or every summer value is read as standard time.
5. **A lone `;` line became a phantom statement** (P3). `find_stmt_lines` let a
   `;`-only line open a statement and close it in the same pass, shifting every
   later index by one. The result→statement mapping then read `";"` as the SQL:
   no table name, so a whole result set lost its DML editing. A `;` line still
   closes the statement above it.
6. **`FROM a x, b y` returned `a`** (P3). `last_part`'s comma check ran from the
   end of the table name, so the alias hid the comma and a two-table result
   handed the DML builder a table the SELECT never targeted alone. The check
   now skips an optional alias (and `AS alias`) first, matching the documented
   "ambiguous → nil" rule.
7. **TOML duplicate keys were accepted, last one winning** (P3). The parser is
   fail-closed for every other malformed shape; a repeated key silently picked
   the later spelling — in a connections file, a half-commented password
   rotation connects with a credential the user cannot see. Now an error naming
   the key (never the value).
8. **The dataset's NULL highlight never matched** (P4). `highlights/render.lua`
   scanned for `(NULL)`, which only appears in editor prompts; the renderer
   spells missing values `<null>` / `<default>`. Both are matched now.

## 2. Fixed — state, lifecycle, perf

9. **`pk_cache` cached "already queried", not the metadata** (P2). The key is
   `conn:db:table` but the PK/default/enum flags live on a *layout*, so the
   second dataset for a table skipped introspection entirely: commits fell back
   to the all-column WHERE ("may update several rows") and the PK column turned
   editable again. The cache now stores the parsed metadata and applies it to
   whichever layout asks (parse and apply split, which also removes the
   layout-mutation-in-parser smell).
10. **The winbar cache had bypass writers** (P2). `buffer/init.lua` skips the
    option write when the text is unchanged, but `editor/nav.lua` (four sites)
    and `buffer/search.lua` wrote the option directly. The cache then described
    text the window no longer showed, and the next identical build skipped the
    write: a committed dataset kept advertising `=~1`, and a cleared search
    kept advertising its filter. All writes go through the new
    `buffer.refresh_winbar(meta)`.
11. **`o` on a paginated result queued a row nobody could see** (P2).
    `editor/nav.lua`'s `rerender_dataset_page` rendered `tab.page` with
    `tab.page_size` regardless of `pagination_enabled`, so (a) with paging off
    the view was cut down to its first page — `o` on a 120-row table left 70
    rows on the layout and off the screen — and (b) the appended row, which
    always lands at the END, was on a page that was never drawn. The render now
    honours paging state, `insert_row` jumps to the page holding the new row,
    and `layout.total_rows` moves with the row set so the winbar count follows.
12. **`state.log` wrote every statement to a world-readable, unbounded file**
    (P3). `M.log` had no level gate and `io.open` used the umask: DEBUG lines
    carrying the first 300 bytes of every statement accumulated in a `0644`
    file. A `log_level` option (default `WARN`) now gates it and the file is
    created `0600`, the same armor `exec_run.write_temp_file` already had.
13. **DDL cache invalidation used the focused buffer's connection** (P2).
    `sql_runner/response.lua:82` called `clear_cache()` with no argument, which
    resolves the *current* buffer — two lines above a `sem.invalidate` that
    correctly uses `state.context`. A DDL whose response landed after a file
    switch dropped the wrong connection's cache and left the DDL'd one stale.
14. **`state.context.database` survived a connection switch** (P2). Completion
    then asked the new connection for the old one's database and keyed its
    cache on a `<conn>/<db>` pair that does not exist. `apply_connection` clears
    it, and `sql_runner` drops it when the resolved connection changes (a `USE`
    on the same connection still survives).
15. **`handle_error` raised on a closed buffer** (P3). `resolve_full_context`
    raises "Invalid buffer id", which aborted the whole scheduled callback —
    no `last_error` (the AI "ask about this error" payload), no ✘ indicator, no
    error panel. The buffer-independent half is written first, and the paint
    half is skipped when the buffer is gone.
16. **`file_exec` kept one run record with no run token** (P3). `cancel()`
    only set `S.cancelled`, and `M.run` reset it — so a cancelled job's late
    `on_stdout`/`on_exit` wrote into the *next* run: mixed results, a bogus
    journal entry for the new file, and `S.is_running` forced false under it.
    A `run_id` captured by the closures closes it.
17. **`log_viewer.render` built every summary row twice** (P3, 44.8 ms/1000
    rows). `build_lines` concatenated `summary_parts(entry)` and
    `apply_highlights` recomputed it — plus read the line back out of the buffer
    — purely to get highlight offsets. The parts are passed through now.
18. **`syntax.highlight_line` rebuilt 80 keywords per line** (P3). Called once
    per rendered log line in the detail view; the table and its lookup map are
    module-level now.
19. **`completion` extracted the SQL block before consulting its cache** (P3).
    Extraction did one `nvim_buf_get_lines` per line in each direction (~10k
    API calls on a 5k-line buffer, on the per-keystroke path) and ran before the
    cache lookup, so a hit paid it too. One bulk read, and the lookup moved
    ahead of it.
20. **`wrap_text` was still O(n²)** (P3). The comment claimed the quadratic
    term was gone; only the per-character nvim round-trips were. Each round
    re-measured the whole remaining line. Measured: 400k chars 1004 ms → 5.3 ms
    (400k → 5.3, 100k → 1.5, output byte-identical). Two changes: the loop is
    driven by a bounded window (`width * 4 + 4` bytes) and `width.truncate` got
    an ASCII fast path (one byte = one cell, no per-char `strdisplaywidth`),
    which keeps the `e` + combining-mark case on the general path.

## 3. Docs and comments corrected against the code

- `README.md` and `doc/poste-db.txt` described `o` as "Insert row below"; the
  implementation appends to the end of the table (and now jumps to it).
- `README.md`'s `colu` row still advertised the invalid postgres
  `ALTER COLUMN ... SET` that round 4 replaced with `... TYPE`.
- `help.lua` labelled the dataset `a` key "Ask AI about the last error"; it is
  bound to `ai.ask_view()` (the error action lives on the error buffer).
- `log_level` documented in `doc/poste-db.txt` (new option).
- Comments rewritten where they described behavior the code no longer had:
  `wrap_text`'s "no more O(n²)", `pk_cache`'s shape, the render-guard site, the
  `sql_runner` context write, `clear_cache`'s argument.

## 4. Verified — claims that did not survive

- **"A `null` column type crashes the whole result set"** (subagent A, P3,
  citing `format.lua:198`). Reproduced headless: `format_dataset` renders it
  fine. `cell_to_string`'s `col.type:upper()` is only reached for string/blob
  cells *and* a decoded `null` never arrives there in the resultset envelope
  the binary sends. Not a defect; no change made. (Worth keeping in mind: a
  plausible `file:line` is not evidence.)
- **"`vim.json.decode` of `null` in a column makes `normalize_type` raise"** —
  same run, same result: it does not raise.
- **`render_dataset` builds the winbar twice per render** — still true, still
  cache-guarded, still deferred (round 4 §5); collapsing it means reworking
  `finalize_rendered_page`'s contract with its other callers.

## 5. Not done, and why

- **`rerender_dataset_page` still ignores `view_indices`** (P3). A filtered or
  sorted dataset snaps back to raw row order after `o`/`dd`, because the
  re-render path was written before the filtered view existed. Fixing it means
  also inserting into / removing from `view_indices` and re-deriving the page
  from the view — a dedicated change, not a rider on this round. The truncation
  half (the severe one) is fixed.
- **Postgres columns still carry no `pk`/`key`** — cross-repo, round 4 §5
  stands: the fix belongs in poste.nvim's Rust `list_columns`.
- **No per-request watchdog on the session transport** — round 4 §5 stands.
- **Copy conflict probes stay one round-trip per item** — round 4 §5 stands.

## 6. Test surface

New file `tests/sql/sql_round5_regressions_spec.lua` (22 assertions):
statement `;`-line and aliased-comma cases, TOML duplicate key (and the same key
in different sections still allowed), JSON shape rejection (heterogeneous,
array-of-arrays, scalars, and a ragged object array still parsing), decimal
precision both ways, `wrap_text` character preservation / width budget /
multibyte, `state.log` level gate + `0600` mode, the `<null>`/`<default>`
extmark scan, and the dataset render guard (dirty refuses, clean replaces).

`tests/sql/sql_editor_row_mapping_spec.lua` gained the paging half: the append
jumps to the page holding the new row, and a pagination-off dataset keeps every
row (plus `layout.total_rows` following the row set). Its fixture now declares
`pagination_enabled = true`, which a two-page tab always implied.
