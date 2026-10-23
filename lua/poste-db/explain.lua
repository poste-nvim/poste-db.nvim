--- EXPLAIN — run the statement under the cursor through the dialect's
--- EXPLAIN form and render the plan as a dataset table in the dataset panel
--- (the same view a normal query opens).
---
--- The wrappers below are plan-only forms: plain EXPLAIN never executes the
--- statement (postgres/mysql/clickhouse), and EXPLAIN QUERY PLAN neither
--- (sqlite) — so wrapping a write statement is safe. mssql is unsupported:
--- its SET SHOWPLAN_TEXT must run as a separate batch, which exec-file
--- cannot express.

local M = {}

local const = require("poste-db.constants")
-- Reused rather than re-implemented here: it is the repo's one string/comment
-- aware SQL masker, and the DML guard and ai/actions already split statements
-- with it, so EXPLAIN cannot disagree with them about where a statement ends.
local dml_guard = require("poste-db.dml_guard")

local EXPLAIN_PREFIX = {
  postgres = "EXPLAIN ",
  mysql = "EXPLAIN ",
  clickhouse = "EXPLAIN ",
  sqlite = "EXPLAIN QUERY PLAN ",
}

--- `extract_stmt_at_cursor` returns a synthetic block: leading `-- @`
--- directives, a `###` marker, then the statement. EXPLAIN must wrap only
--- the SQL, so strip the leading directives, marker and comment lines.
---
--- Only the LEADING ones. Directives are plugin-owned and must not reach the
--- server, and they sit at the top by construction — but stripping interior
--- `--` lines by shape would corrupt a statement whose string literal spans a
--- newline (`SELECT 'multi\n-- not a comment' FROM t`): the line starts with
--- `--`, yet it is string content, and dropping it takes the closing quote and
--- the rest of the statement with it. Interior comments are harmless to keep —
--- a comment cannot change a plan, and the single-statement check runs on
--- dml_guard's comment/string-aware mask, which already reads them right.
local function clean_stmt(content)
  local out = {}
  local leading = true
  for _, l in ipairs(vim.split(content or "", "\n", { plain = true })) do
    if leading and (l:match("^%s*$")
      or const.is_directive_comment(l)
      or l:match("^%s*###%s*$")
      or l:match("^%s*%-%-")) then
      -- skip the synthetic block's own header: directives, marker, blanks
    else
      leading = false
      out[#out + 1] = l
    end
  end
  return table.concat(out, "\n")
end

--- Wrap a statement in the dialect's EXPLAIN form.
--- @param dialect string|nil base dialect (nil behaves like postgres)
--- @param stmt string
--- @return string|nil wrapped, string|nil error_message
function M.wrap_sql(dialect, stmt)
  local prefix = EXPLAIN_PREFIX[dialect or "postgres"]
  if not prefix then
    return nil, ("EXPLAIN is not supported for dialect '%s'"):format(tostring(dialect))
  end
  local trimmed = stmt:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return nil, "no statement under cursor"
  end
  local inner = trimmed:gsub("%s*;%s*$", "")
  -- exec-file splits the file into statements; an EXPLAIN wrapping several
  -- of them would explain (at best) only the first. Semicolons are counted on
  -- the masked form, because a plain find(";") also matched separators that
  -- are part of this statement's own text — `SELECT 'a;b'`, a `-- note; end`
  -- tail, a PL/pgSQL `$$ … ; … $$` body — and refused a cursor that really
  -- was on a single statement.
  --
  -- The mask runs under BOTH quote-escape readings: they disagree about
  -- where a literal ends (postgres closes `'C:\path\'` at the final quote;
  -- the backslash reading escapes it), and a single reading parks a real
  -- `;` inside a phantom literal, hiding the statement behind it. A refusal
  -- gate over-flags, never under — the rule `dml_guard.regex_scan` unions
  -- its hits by.
  for _, backslash in ipairs({ false, true }) do
    if dml_guard.strip_non_code(inner, backslash):find(";", 1, true) then
      return nil, "EXPLAIN runs a single statement — put the cursor on one statement"
    end
  end
  return prefix .. inner, nil
end

--- EXPLAIN the statement under the cursor and open the plan as a dataset
--- table in the dataset panel.
function M.explain()
  local src_buf = vim.api.nvim_get_current_buf()
  local state = require("poste-db.state")
  if not state.find_poste_binary() then
    vim.notify("Poste binary not found.", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local statement = require("poste-db.statement")
  local buf_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local content = statement.extract_stmt_at_cursor(buf_lines, vim.fn.line("."), src_buf)
  local stmt = clean_stmt(content)
  if stmt:match("^%s*$") then
    vim.notify("No statement under cursor.", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return
  end

  local ctx = require("poste-db.context").resolve_full_context(src_buf)
  local conn = ctx.connection or ""
  local conn_dialect
  if conn ~= "" then
    local cfg = require("poste-db.connections").get_connection_config(conn)
    conn_dialect = cfg and cfg.dialect or nil
  end
  local dialect = conn_dialect or "postgres"

  local sql, err = M.wrap_sql(dialect, stmt)
  if not sql then
    vim.notify(err, vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return
  end

  local database = ctx.database or ""
  local conn_url = nil
  if conn ~= "" then
    conn_url = require("poste-db.connections").resolve_connection_url(conn)
  end

  local exec_run = require("poste-db.exec_run")
  local resp = exec_run.run_sql(sql, {
    src_file = vim.api.nvim_buf_get_name(src_buf),
    conn_url = conn_url,
    database = database,
    log_source = "explain",
    log_extra = { connection = conn ~= "" and conn or nil },
  })

  if not resp then
    vim.notify("EXPLAIN failed (no response)", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end
  -- A rejected EXPLAIN arrives as a normal response carrying a per-result
  -- error; `first_error` is the same reading the sql_runner path uses, so a
  -- plan the server refused never renders as an empty table.
  local plan_err = exec_run.first_error(resp)
  if plan_err then
    vim.notify("EXPLAIN: " .. plan_err, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  -- A plan is an ordinary result set, so it opens where a query result does:
  -- the dataset split, with the dataset's borders, header and column widths.
  -- A wide grid (MySQL's twelve-column EXPLAIN) then scrolls horizontally in
  -- the split instead of wrapping inside a float.
  --
  -- A fresh history entry, like a query run: without one the plan would land
  -- in the previous request's slot (render_dataset resets the active entry's
  -- tabs) and read as that request's result.
  local dataset = require("poste-db.dataset")
  local line_nr = vim.fn.line(".")
  local ts = dataset.now_wall()
  local entry = dataset.new_entry({
    label = statement.extract_label(buf_lines, line_nr) or "EXPLAIN",
    ts_sec = ts.sec,
    ts_nsec = ts.nsec,
    src_buf = src_buf,
    src_file = vim.api.nvim_buf_get_name(src_buf),
    stmt_line = line_nr,
  })
  entry.sql = sql

  local sql_format = require("poste-db.format")
  local lines, meta, layout = sql_format.format_dataset(resp)
  -- Prefer the decoded result set (same as db_browser and the AI actions) so
  -- cell preview (K) / yank / sort read these rows, not state.last_response.
  local data
  if resp.body then
    local ok, decoded = pcall(vim.json.decode, resp.body)
    if ok then data = decoded end
  end
  require("poste-db.buffer").render_dataset(lines, meta or {}, {
    data = data,
    layout = layout,
    original_sql = sql,
    src_file = vim.api.nvim_buf_get_name(src_buf),
    src_buf = src_buf,
  })
end

M._test = {
  clean_stmt = clean_stmt,
}

return M
