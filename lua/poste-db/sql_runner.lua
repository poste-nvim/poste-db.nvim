--- SQL execution entry point — supports single-statement (normal mode)
--- and multi-statement (visual selection) execution.
--- Each statement result goes into its own dataset tab.
local state = require("poste-db.state")
local config = require("poste-db.config")
local indicators = require("poste-db.indicators")
local statement = require("poste-db.statement")
local stmt_indicator = require("poste-db.statement_indicator")
local sql_introspect = require("poste-db.introspect")
local sql_buffer = require("poste-db.buffer")
local dml_guard = require("poste-db.dml_guard")
local D = require("poste-db.dataset")
local response = require("poste-db.sql_runner.response")
local const = require("poste-db.constants")

local stmt_indicator_line = response.stmt_indicator_line

local M = {}

-- Execution tracking for callback ordering
local exec_seq = 0
local _vis_active = false
local _vis_start = 0
local _vis_end = 0

-- Pending statusline/indicator debounce, keyed per SQL buffer. A single
-- shared timer would let one buffer's cursor move cancel another buffer's
-- scheduled update.
local _cursor_moved_timers = {}
local CURSOR_MOVED_DEBOUNCE_MS = 100





--- Install keymaps for this SQL buffer (one-time setup).
function M.ensure_sql_keymaps(buf)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if vim.b[buf].poste_db_keymaps_installed then return end
  vim.b[buf].poste_db_keymaps_installed = true

  local keymap_opts = { buffer = buf, noremap = true, silent = true }

  -- Normal mode: execute statement at cursor
  local k = config.get_keymap("sql_source", "run", "<CR>")
  if k then
    vim.keymap.set("n", k, function()
      M.run_sql_request()
    end, keymap_opts)
  end

  -- K: show DDL for table under cursor
  k = config.get_keymap("sql_source", "show_ddl", "K")
  if k then
    vim.keymap.set("n", k, function()
      sql_introspect.show_table_ddl()
    end, keymap_opts)
  end

  -- <leader>ep: EXPLAIN the statement under the cursor (plan-only form)
  k = config.get_keymap("sql_source", "explain", "<leader>ep")
  if k then
    vim.keymap.set("n", k, function()
      require("poste-db.explain").explain()
    end, keymap_opts)
  end

  -- Visual mode: execute selected statements (uses same key as normal run)
  k = config.get_keymap("sql_source", "run", "<CR>")
  if k then
    vim.keymap.set("x", k, function()
      _vis_start = vim.fn.line("v")
      _vis_end = vim.fn.line(".")
      _vis_active = true
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
        "n", false
      )
      M.run_sql_request()
    end, keymap_opts)
  end

  -- g?: show keymap help
  k = config.get_keymap("sql_source", "help", "g?")
  if k then
    vim.keymap.set("n", k, function() require("poste-db.help").open() end, keymap_opts)
  end

  -- <leader>l: toggle SQL execution log
  k = config.get_keymap("sql_source", "toggle_log", "<leader>l")
  if k then
    vim.keymap.set("n", k, function()
      require("poste-db.log_viewer").toggle()
    end, keymap_opts)
  end

  -- Format SQL buffer/selection (default <leader>ff)
  k = config.get_keymap("sql_source", "format", "<leader>ff")
  if k then
    vim.keymap.set("n", k, function()
      local ok, source_format = pcall(require, "poste-db.source_format")
      if ok then source_format.format() end
    end, keymap_opts)
    vim.keymap.set("x", k, function()
      local ok, source_format = pcall(require, "poste-db.source_format")
      if ok then source_format.format() end
    end, keymap_opts)
  end

  -- CursorMoved: update statement boundary highlight synchronously (so it
  -- tracks the cursor on the same redraw, like cursorline) + context indicator
  -- in the statusline (debounced to avoid repeated context resolution churn).
  local augroup = "PosteDbCursorMoved_" .. buf
  pcall(vim.api.nvim_del_augroup_by_name, augroup)
  local group = vim.api.nvim_create_augroup(augroup, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      stmt_indicator.update(buf, vim.fn.line("."))

      local pending = _cursor_moved_timers[buf]
      if pending then
        pending:stop()
        pending:close()
      end
      _cursor_moved_timers[buf] = vim.defer_fn(function()
        _cursor_moved_timers[buf] = nil
        if vim.api.nvim_get_current_buf() ~= buf then return end
        local ok, ctx_mod = pcall(require, "poste-db.context")
        if ok and ctx_mod then
          local ok2, text = pcall(ctx_mod.get_cursor_status_text, buf)
          if ok2 and text then
            vim.b[buf].poste_db_context = text
            vim.cmd("redrawstatus")
          end
        end
      end, CURSOR_MOVED_DEBOUNCE_MS)
    end,
  })

  -- Tree-sitter syntax diagnostics
  local ok_diag, diag = pcall(require, "poste-db.diagnostics")
  if ok_diag then
    diag.setup(buf)
  end
end

--------------------------------------------------------------------------------
-- Main entry point
--------------------------------------------------------------------------------

function M.run_sql_request()
  local src_buf = vim.api.nvim_get_current_buf()

  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found.", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  M.ensure_sql_keymaps(src_buf)

  local buf_lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local file = vim.api.nvim_buf_get_name(src_buf)
  if file == "" then
    file = vim.fn.getcwd() .. "/untitled.sql"
  end

  local is_visual = _vis_active
  _vis_active = false

  local buf_content
  local visual_sel_end
  local stmt_start  -- used for session raw SQL extraction
  local stmt_end  -- used for session raw SQL extraction
  local stmt_lines
  local set_lines  -- preceding SET @var statements found by extract_stmt_at_cursor

  -- The dialect's quote-escape reading keeps the statement map identical to
  -- what exec-file splits this buffer into (resolved once, before either
  -- extraction branch; nil when the buffer carries no dialect hint)
  local ok_sf, source_format = pcall(require, "poste-db.source_format")
  local dialect_for_span = ok_sf and source_format.resolve_dialect(src_buf) or nil

  if is_visual then
    local sel_start = math.min(_vis_start, _vis_end)
    local sel_end = math.max(_vis_start, _vis_end)
    sel_start = math.max(1, sel_start)
    sel_end = math.min(#buf_lines, sel_end)
    visual_sel_end = sel_end
    -- The selection must not cut a statement in half: a fragment (e.g. an
    -- INSERT whose VALUES lines fell outside the selection) fails on the
    -- server with a 1064 that reads like a plugin bug. Cancel paths here sit
    -- before any state clearing, so the previous response/dataset survive.
    local cut = statement.selection_cuts_statement(src_buf, buf_lines, sel_end, dialect_for_span)
    if cut then
      vim.notify(
        "Selection ends mid-statement — extend it to the statement's last line (the `;`), or run it with the cursor on it.",
        vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
      return
    end
    -- NB: statement start lines come back via stmt_lines; indicator and
    -- response placement consume those, not the raw directive count
    buf_content, stmt_lines = statement.extract_visual_block(buf_lines, sel_start, sel_end,
      dialect_for_span)
  else
    local line = vim.fn.line(".")
    -- NB: plain table capture — table.pack is absent on some nvim builds
    -- (0.12 nightly) and .n is never read here.
    local extracted = { statement.extract_stmt_at_cursor(buf_lines, line, src_buf) }
    buf_content = extracted[1]
    stmt_start = extracted[3]
    stmt_end = extracted[4]
    set_lines = extracted[5]
    if not buf_content then return end
    stmt_lines = { stmt_start or 1 }
    stmt_end = stmt_end or stmt_start
  end

  -- Only clear after we confirm there's something to execute
  local tab = D.T()
  if tab and tab.edit_state and tab.edit_state.dirty then
    vim.notify("You have unsaved edits. Commit or discard them first.", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    return
  end

  local sql_context = require("poste-db.context")
  local ctx
  if is_visual then
    local sel_start = math.min(_vis_start, _vis_end)
    ctx = sql_context.resolve_full_context(src_buf, math.max(1, sel_start - 1))
  else
    ctx = sql_context.resolve_full_context(src_buf)
  end

  -- Resolve connection name to URL and pass it directly: Lua owns
  -- connections.toml resolution (mirror rule), the binary only ever sees URLs
  local conn_url = nil
  if ctx.connection and ctx.connection ~= "" then
    local connections = require("poste-db.connections")
    local url, err = connections.resolve_connection_url(ctx.connection)
    if not url then
      -- Cancel path: no state has been mutated yet, so a request that is
      -- still in flight keeps its spinner and its epoch stays valid.
      vim.notify("Connection '" .. ctx.connection .. "' not found: " .. (err or "create a connections.toml in your project root"), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
      return
    end
    conn_url = url
  end

  local db = ctx.database
  if db == vim.NIL then db = nil end
  if db and db == "" then db = nil end

  -- Detect lone USE statement. Intentionally narrower than exec_run.detect_use
  -- (which also matches quoted/commented forms): here a USE only decides
  -- *routing* (session vs one-shot run) — a quoted `USE "db"` is executed by
  -- the session, which applies it persistently. Don't unify the two blindly.
  local function is_use_stmt(s)
    if not s then return false end
    local trimmed = s:match("^%s*(.*)%s*$") or ""
    -- case-insensitive: a lowercase `use db;` must route to exec-file (which
    -- skips it), not into the session as real SQL — a syntax error on postgres.
    -- `[%w_-]`: a hyphenated `USE my-db;` routes like a plain identifier —
    -- the session would only see it as a syntax error (09-12 carry)
    return trimmed:upper():match("^USE%s+([%w_-]+)%s*;?%s*$") ~= nil
  end

  -- Extract raw SQL text for a single statement (without directives/###)
  local stmt_sql_raw
  local sql_statements
  if not is_visual and stmt_start and stmt_end then
    local raw_lines = {}
    if set_lines then
      for _, l in ipairs(set_lines) do raw_lines[#raw_lines + 1] = l end
    end
    for i = stmt_start, stmt_end do
      raw_lines[#raw_lines + 1] = buf_lines[i] or ""
    end
    stmt_sql_raw = table.concat(raw_lines, "\n")
    -- The session transport needs the pieces, not the join: one request per
    -- statement (see session_conn.execute_sequence — a multi-statement
    -- single request dies in MySQL's prepared-statement protocol).
    if set_lines and #set_lines > 0 then
      sql_statements = {}
      for _, l in ipairs(set_lines) do sql_statements[#sql_statements + 1] = l end
      local body_lines = {}
      for i = stmt_start, stmt_end do
        body_lines[#body_lines + 1] = buf_lines[i] or ""
      end
      sql_statements[#sql_statements + 1] = table.concat(body_lines, "\n")
    end
  end

  -- Unfiltered DML guard: a DELETE/UPDATE without a WHERE clause would hit
  -- every row. Confirm once (before any executor side effects) so a stray
  -- `<CR>` cannot wipe a table without an explicit yes.
  if config.config.confirm_unfiltered_dml ~= false then
    local risky = dml_guard.scan_text(stmt_sql_raw or buf_content or "")
    if #risky > 0 then
      local choice = vim.fn.confirm(
        dml_guard.confirm_message(risky),
        "&Yes, execute\n&No, cancel", 2, "Warning")
      if choice ~= 1 then
        vim.notify("Cancelled — statement(s) without a WHERE clause were not executed.",
          vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
        return
      end
    end
  end

  -- Everything below mutates request-scoped state, so it sits after every
  -- cancel path above (no statement at cursor, dirty edits, missing
  -- connection, DML-guard rejection): a cancelled run must keep the previous
  -- response/dataset, must not bump the epoch (that would make the stale-seq
  -- guard in sql_runner/response drop a still-running request's response)
  -- and must not leave an empty history entry behind.
  exec_seq = exec_seq + 1
  local current_seq = exec_seq
  indicators.clear_all(src_buf)

  -- Request history entry (JetBrains-style sidebar): one entry per request.
  -- Created here so the label is captured at request time; elapsed/error are
  -- filled in by on_response/on_error via the captured entry reference.
  local dataset = require("poste-db.dataset")
  local label_start = stmt_start
    or (is_visual and math.max(1, math.min(_vis_start, _vis_end)) or nil) or 1
  local label = statement.extract_label(buf_lines, label_start)
  if not label then
    -- Fallback: <basename>_<per-buffer counter> (e.g. test_1, test_2)
    label = statement.fallback_label(file, src_buf)
  end
  local ts = dataset.now_wall()
  local entry = dataset.new_entry({
    label = label,
    ts_sec = ts.sec,
    ts_nsec = ts.nsec,
    src_buf = src_buf,
    src_file = file,
    stmt_line = stmt_start,
  })
  entry.sql = stmt_sql_raw or buf_content
  sql_buffer.clear_panel()

  -- Set running indicators
  local first_line = stmt_lines[1]
  if not first_line then
    first_line = (is_visual and math.max(_vis_start or 0, _vis_end or 0) > 0)
      and math.min(_vis_start, _vis_end) or 1
  end
  first_line = math.max(1, math.min(first_line, #buf_lines))

  -- Place the running spinner on the same line each statement's completion
  -- indicator will land — the statement's FIRST line — so ✓/✘ replaces the
  -- spinner in place and the sign column stays aligned with the SQL start.
  if is_visual then
    if #stmt_lines > 0 then
      for i, ln in ipairs(stmt_lines) do
        indicators.set_indicator(src_buf, stmt_indicator_line(ln), "running")
      end
    else
      indicators.set_indicator(src_buf, first_line - 1, "running")
    end
  else
    indicators.set_indicator(src_buf, first_line - 1, "running")
  end

  -- Line a whole-block failure lands on (the last statement's starting line
  -- for visual runs), matching where its running spinner sits.
  local block_result_line
  if is_visual then
    local last_start = stmt_lines[#stmt_lines] or first_line
    block_result_line = stmt_indicator_line(last_start)
  else
    block_result_line = first_line - 1
  end

  -- Persist resolved context so it's available for dataset editing (PK introspection etc.)
  if ctx.connection then state.context.connection = ctx.connection end
  if ctx.database then state.context.database = ctx.database end

  -- Fresh SQL session: clears request-scoped dataset/response state (Phase 2b).
  require("poste-db.session").begin({
    buf = src_buf,
    line = vim.fn.line("."),
    file = file,
  })

  -- Route: single non-USE statement with a resolved connection → session
  --         visual selection, USE, or no connection → exec-file
  local use_session = not is_visual and conn_url and stmt_sql_raw and not is_use_stmt(stmt_sql_raw)

  -- Response handling lives in sql_runner/response.lua; every request-scoped
  -- value is passed explicitly so nothing closes over request locals.
  local response_deps = {
    entry = entry,
    current_seq = current_seq,
    get_exec_seq = function() return exec_seq end,
    src_buf = src_buf,
    src_file = file,
    buf_lines = buf_lines,
    buf_content = buf_content,
    stmt_sql_raw = stmt_sql_raw,
    stmt_lines = stmt_lines,
    stmt_end = stmt_end,
    first_line = first_line,
    is_visual = is_visual,
    visual_sel_end = visual_sel_end,
    vis_start = _vis_start,
    vis_end = _vis_end,
    set_lines = set_lines,
    block_result_line = block_result_line,
  }

  local on_response = function(parsed)
    response.handle(response_deps, parsed)
  end

  local on_error = function(message, parsed)
    response.handle_error(response_deps, message, parsed)
  end

  local executor = require("poste-db.executor")
  local conn_name = ctx.connection
  if conn_name == vim.NIL then conn_name = nil end
  executor.execute({
    sql = stmt_sql_raw or buf_content,
    sql_statements = sql_statements,
    conn_url = conn_url,
    database = db,
    mode = "greedy",
    prefer_session = use_session,
    src_buf = src_buf,
    src_file = file,
    log_source = "manual_exec",
    log_extra = { connection = conn_name },
    on_response = on_response,
    on_error = function(message, parsed)
      indicators.set_indicator(src_buf, block_result_line, "error")
      on_error(message, parsed)
    end,
  })
end

function M.get_exec_seq()
  return exec_seq
end

M._test = vim.tbl_extend("force", statement._test, { is_ddl = response.is_ddl })

return M
