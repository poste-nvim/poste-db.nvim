local state = require("poste-db.state")
local util = require("poste-db.util")
local dialog = require("poste-db.dialog")
local layout = require("poste-db.layout")
local connections = require("poste-db.connections")
local constants = require("poste-db.constants")

local M = {}

local S = {
  job_id = nil,
  dialog = nil,
  is_running = false,
  cancelled = false,
  n_succeeded = 0,
  n_failed = 0,
  total_rows = 0,
  total_affected = 0,
  total = 0,
  results = {},
  start_time = nil,
  filepath = nil,
  conn = nil,
  db = nil,
  mode = nil,
  rolled_back = false,
  stmt_counts = {
    create = 0, alter = 0, drop = 0,
    insert = 0, update = 0, delete = 0, select = 0, other = 0,
  },
}

local MAX_LOG_LINES = 5
local DIALOG_WIDTH = 70
local DIALOG_HEIGHT = 20

local function fmt_time(ms)
  if ms >= 1000 then
    return string.format("%.2fs", ms / 1000)
  end
  return string.format("%dms", ms)
end

local function fmt_elapsed()
  if not S.start_time then return "0s" end
  local elapsed = (vim.uv or vim.loop).now() - S.start_time
  return fmt_time(elapsed)
end

local function fmt_sql(sql, max_len)
  local s = sql:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  max_len = max_len or 50
  return util.ellipsize(s, max_len)
end

local function classify_stmt(sql)
  local s = sql:gsub("%s+", " "):gsub("^%s+", ""):upper()
  if s:find("^CREATE") then return "create" end
  if s:find("^ALTER") then return "alter" end
  if s:find("^DROP") then return "drop" end
  if s:find("^INSERT") then return "insert" end
  if s:find("^UPDATE") then return "update" end
  if s:find("^DELETE") then return "delete" end
  if s:find("^SELECT") then return "select" end
  return "other"
end

local function build_content()
  local d = S.dialog
  if not d then return {}, {} end
  local cw = d.content_width
  local lines = {}
  local highlights = {}
  local conn_label = S.conn or ""
  if S.db then conn_label = conn_label .. " / " .. S.db end

  table.insert(lines, layout.cell("Connection: " .. conn_label, cw))

  local mode_label = S.mode == "transaction" and "Transaction" or "Greedy"
  local stats_text
  if S.rolled_back then
    stats_text = string.format("Mode: %s   Failed: %d   (rolled back: %d)", mode_label, S.n_failed, S.n_succeeded)
  else
    stats_text = string.format("Mode: %s   Succeeded: %d   Failed: %d", mode_label, S.n_succeeded, S.n_failed)
  end
  table.insert(lines, stats_text)

  local succeeded_start = stats_text:find("Succeeded:", 1, true)
  if succeeded_start then
    local num_end = stats_text:find("   ", succeeded_start + 11, true) or #stats_text + 1
    table.insert(highlights, { line = #lines - 1, col_start = succeeded_start - 1, col_end = num_end - 1, hl_group = "PosteDbDatasetSucceeded" })
  end
  local failed_start = stats_text:find("Failed:", 1, true)
  if failed_start then
    local num_end = stats_text:find("   ", failed_start + 8, true) or #stats_text + 1
    table.insert(highlights, { line = #lines - 1, col_start = failed_start - 1, col_end = num_end - 1, hl_group = "PosteDbDatasetFailed" })
  end

  table.insert(lines, "")

  local c = S.stmt_counts
  local cols = layout.columns({
    { title = "DDL", items = {
      string.format("create: %d", c.create),
      string.format("modify: %d", c.alter),
      string.format("drop: %d", c.drop),
    }},
    { title = "DML", items = {
      string.format("insert: %d", c.insert),
      string.format("update: %d", c.update),
      string.format("delete: %d", c.delete),
      string.format("select: %d", c.select),
    }},
  }, { width = cw, title_hl = "Title" })
  for _, l in ipairs(cols.lines) do table.insert(lines, l) end
  for _, h in ipairs(cols.highlights) do table.insert(highlights, h) end

  table.insert(lines, "")

  local bar = layout.progress(S.n_succeeded + S.n_failed, S.total, { bar_width = 20 })[1]
  local elapsed = "Elapsed: " .. fmt_elapsed()
  table.insert(lines, layout.space_between(bar, elapsed, { width = cw })[1])
  table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = cw, hl_group = "PosteCoreProgressBar" })

  local elapsed_start = (#lines[#lines] or 0) > 0 and lines[#lines]:find("Elapsed:", 1, true)
  if elapsed_start then
    table.insert(highlights, { line = #lines - 1, col_start = elapsed_start - 1, col_end = #lines[#lines], hl_group = "PosteDbDatasetConstant" })
  end

  table.insert(lines, layout.dynamic_line({
    text = "File: " .. S.filepath,
    container_width = cw,
    truncate_at = "mid",
  }))
  local file_line = #lines
  local file_label_end = ("File: "):len()
  table.insert(highlights, { line = file_line - 1, col_start = file_label_end, col_end = cw, hl_group = "PosteDbDatasetFilepath" })

  table.insert(lines, layout.separator({ width = cw })[1])

  local start = math.max(1, #S.results - MAX_LOG_LINES + 1)
  for i = start, #S.results do
    local r = S.results[i]
    local icon = r.status == "ok" and "✓" or "✘"
    local prefix = icon .. " (" .. r.seq .. ") "
    local suffix = ""
    if r.status == "ok" and r.row_count > 0 then
      suffix = string.format(" (%d rows, %s)", r.row_count, fmt_time(r.elapsed))
    elseif r.status == "ok" then
      suffix = string.format(" (%s)", fmt_time(r.elapsed))
    end
    local prefix_dw = vim.fn.strdisplaywidth(prefix)
    local suffix_dw = vim.fn.strdisplaywidth(suffix)
    local max_sql_dw = math.max(10, cw - prefix_dw - suffix_dw - 1)
    local sql_display = fmt_sql(r.sql, max_sql_dw)
    local line = prefix .. sql_display .. suffix
    table.insert(lines, layout.cell(line, cw))
    local hl = r.status == "ok" and "PosteDbHistorySuccess" or "PosteDbHistoryError"
    local prefix_bytes = #prefix
    table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = prefix_bytes, hl_group = hl })
    local sql_start = prefix_bytes
    local sql_end = prefix_bytes + #sql_display
    if sql_end > sql_start then
      table.insert(highlights, { line = #lines - 1, col_start = prefix_bytes, col_end = sql_end, hl_group = "PosteDbHistorySQL" })
    end
  end

  while #lines < d.content_height do
    table.insert(lines, "")
  end

  return lines, highlights
end

local function render_progress()
  if not S.dialog then return end
  local lines, highlights = build_content()
  S.dialog:update(lines, highlights)
end

local function create_progress_win()
  if S.dialog then
    S.dialog:update({}, {})
    return
  end
  S.dialog = dialog.open({
    title = "Execute SQL File",
    width = DIALOG_WIDTH,
    height = DIALOG_HEIGHT,
    backdrop = true,
    keymaps = {
      c = function()
        M.cancel()
      end,
    },
    on_close = function()
      S.dialog = nil
    end,
  })
end

--- The file's own `-- @connection` directive, if any.
--- The pattern comes from constants (match_directive, through directive_value)
--- rather than a local copy: the directive must be recognised by the same
--- anchored rule the completion handlers and the Rust CLI
--- (`extract_connection_directive`, which strips the very lines it reads) use,
--- or a `-- @connection` that only looks like one -- trailing a statement,
--- inside a block comment -- would choose the database. directive_value also
--- drops a nameless one, so a placeholder line does not resolve a connection
--- named `''` here while the CLI skips it and says "No connection specified".
--- @param filepath string
--- @return string|nil
local function extract_connection_directive(filepath)
  local ok, content = pcall(vim.fn.readfile, filepath)
  if not ok or not content then return nil end
  for _, line in ipairs(content) do
    local conn = constants.directive_value(line, "connection")
    if conn then return conn end
  end
  return nil
end

--- Build `exec-file` args as an argv list (jobstart's list form — no shell,
--- so values pass through unquoted). Binary is prepended by the caller.
local function build_cmd(filepath, opts)
  local cmd = {
    "exec-file", filepath,
    "--env", state.current_env or "dev",
    "--mode", opts.mode or "greedy",
    "--timeout", tostring(opts.timeout or 30),
    "--max-rows", tostring(opts.max_rows or 1000),
    "--json",
  }
  if opts.conn_url and opts.conn_url ~= "" then
    table.insert(cmd, "--connection"); table.insert(cmd, opts.conn_url)
  end
  if opts.database and opts.database ~= "" then
    table.insert(cmd, "--database"); table.insert(cmd, opts.database)
  end
  return cmd
end

function M.cancel()
  if not S.is_running or not S.job_id then return end
  S.cancelled = true
  vim.fn.jobstop(S.job_id)
  S.is_running = false
  render_progress()
end

--- One journal entry per file run: outcome plus the first statement failure
--- (full per-statement detail stays in the progress dialog). Defined BEFORE
--- handle_line, which calls it — a local defined after its caller resolves
--- to a nil global there (AGENTS.md forward-declaration pitfall).
local function journal_file_summary()
  local first_error
  for _, r in ipairs(S.results) do
    if r.status == "error" then
      first_error = (r.seq and ("[" .. r.seq .. "] ") or "") .. tostring(r.error or "statement failed")
      break
    end
  end
  require("poste-db.sql_log").record({
    source = "run_file",
    sql = "[file] " .. (S.filepath or "?"),
    connection = S.conn or nil,
    database = S.db or nil,
    status = S.n_failed > 0 and "error" or "success",
    elapsed_ms = S.start_time and ((vim.uv or vim.loop).now() - S.start_time) or nil,
    affected_rows = S.total_affected,
    rolled_back = S.rolled_back or nil,
    error_msg = first_error,
  })
end

local function handle_line(line)
  local ok, event = pcall(vim.json.decode, line)
  if not ok or type(event) ~= "table" then return end

  local event_type = event.type
  if event_type == "progress" then
    S.current_sql = event.sql
    S.total = event.total
    render_progress()

  elseif event_type == "result" then
    local seq = event.seq
    local status = event.status
    local row_count = event.row_count or 0
    local elapsed = event.execution_time_ms or 0
    local sql = event.sql or ""
    local stmt_type = classify_stmt(sql)
    S.stmt_counts[stmt_type] = S.stmt_counts[stmt_type] + 1

    if status == "ok" then
      S.n_succeeded = S.n_succeeded + 1
      S.total_rows = S.total_rows + row_count
      table.insert(S.results, {
        status = "ok",
        seq = seq,
        sql = sql,
        row_count = row_count,
        elapsed = elapsed,
      })
    else
      S.n_failed = S.n_failed + 1
      -- verdict.error_text normalizes the non-string family (JSON null is the
      -- truthy vim.NIL userdata — string.format("%s") would print it
      -- literally), and the redact mirrors format_error's panel rule: a
      -- driver error can echo the DSN it failed on. This notify bypasses
      -- format_error, so the redaction has to happen here.
      local error_msg = require("poste-db.log").redact_url(
        require("poste-db.verdict").error_text(event.error) or "unknown error")
      table.insert(S.results, {
        status = "error",
        seq = seq,
        sql = sql,
        row_count = 0,
        elapsed = elapsed,
        error = error_msg,
      })
      vim.notify(string.format("[%d/%d] %s", seq, S.total, error_msg), vim.log.levels.ERROR, { title = "PosteDb" })
    end
    render_progress()

  elseif event_type == "summary" then
    S.total = event.total
    S.n_succeeded = event.succeeded or S.n_succeeded
    S.n_failed = event.failed or S.n_failed
    S.total_rows = event.total_rows or S.total_rows
    S.total_affected = event.total_affected or S.total_affected
    S.rolled_back = event.rolled_back or false
    S.is_running = false
    S.current_sql = nil
    S.summary_seen = true
    journal_file_summary()
    render_progress()
  end
end

function M.run(opts)
  opts = opts or {}
  if S.is_running then
    vim.notify("File execution already in progress", vim.log.levels.WARN, { title = "PosteDb" })
    return
  end
  local filepath = opts.filepath
  local conn = opts.conn
  local db = opts.database
  local mode = opts.mode or "greedy"
  local timeout = opts.timeout or 30
  local max_rows = opts.max_rows or 1000

  if not filepath or filepath == "" then
    vim.notify("No file specified", vim.log.levels.ERROR, { title = "PosteDb" })
    return
  end

  S.job_id = nil
  S.is_running = true
  S.cancelled = false
  S.summary_seen = false
  S.n_succeeded = 0
  S.n_failed = 0
  S.total_rows = 0
  S.total_affected = 0
  S.total = 0
  S.results = {}
  S.start_time = (vim.uv or vim.loop).now()
  S.filepath = filepath
  S.conn = conn
  S.db = db
  S.mode = mode
  S.rolled_back = false
  S.current_sql = nil
  S.stmt_counts = { create = 0, alter = 0, drop = 0, insert = 0, update = 0, delete = 0, select = 0, other = 0 }

  create_progress_win()
  render_progress()

  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found", vim.log.levels.ERROR)
    S.is_running = false
    render_progress()
    require("poste-db.sql_log").record({
      source = "run_file",
      sql = "[file] " .. filepath,
      connection = conn or nil,
      database = db or nil,
      status = "error",
      error_msg = "Poste binary not found",
    })
    return
  end

  local resolved_conn = conn
  if not resolved_conn then
    resolved_conn = extract_connection_directive(filepath)
  end

  local conn_url
  if resolved_conn then
    local url, err = connections.resolve_connection_url(resolved_conn)
    if not url then
      if S.dialog then S.dialog:close(); S.dialog = nil end
      S.is_running = false
      vim.notify("Connection '" .. resolved_conn .. "' not found: " .. (err or "create a connections.toml in your project root"), vim.log.levels.ERROR, { title = "PosteDb" })
      require("poste-db.sql_log").record({
        source = "run_file",
        sql = "[file] " .. filepath,
        connection = resolved_conn,
        database = db or nil,
        status = "error",
        error_msg = err or "connection not found",
      })
      return
    end
    S.conn = resolved_conn
    conn_url = url
  end

  local cmd = vim.list_extend({ binary }, build_cmd(filepath, {
    mode = mode,
    timeout = timeout,
    max_rows = max_rows,
    conn_url = conn_url,
    database = db,
  }))

  local log = require("poste-db.log")
  log.info("ExecFile cmd: " .. log.redact_cmd(cmd))

  local partial = ""
  -- jobstart raises E475 when argv[0] vanished between the lookup above and
  -- this call (a reinstall mid-session, a stale g:poste_binary); unwrapped,
  -- the raise skips every failure path below and leaves the progress dialog
  -- running with S.is_running stuck true for the rest of the session
  local ok_job, job = pcall(vim.fn.jobstart, cmd, {
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data or S.cancelled then return end
      for _, chunk in ipairs(data) do
        if chunk == "" then
          if partial ~= "" then
            handle_line(partial)
            partial = ""
          end
        else
          local combined = partial .. chunk
          local lines = vim.split(combined, "\n")
          partial = table.remove(lines) or ""
          for _, line in ipairs(lines) do
            if line ~= "" then
              handle_line(line)
            end
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then
          state.log("WARN", "ExecFile stderr: " .. l)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 and not S.cancelled then
          state.log("ERROR", "ExecFile exit code " .. code)
        end
        -- A dead binary/connection never delivers a summary — journal the
        -- run so `<leader>l` shows why nothing happened.
        if not S.summary_seen and not S.cancelled then
          S.n_failed = math.max(S.n_failed, 1)
          require("poste-db.sql_log").record({
            source = "run_file",
            sql = "[file] " .. (S.filepath or "?"),
            connection = S.conn or nil,
            database = S.db or nil,
            status = "error",
            elapsed_ms = S.start_time and ((vim.uv or vim.loop).now() - S.start_time) or nil,
            error_msg = "exit code " .. tostring(code) .. " (no summary event)",
          })
          -- A dead binary/connection ends the run silently otherwise: the
          -- dialog just stops, and per-statement failures notify while this
          -- whole-run failure did not. Report it on the same channel.
          vim.notify(
            string.format("SQL file run failed: exit code %s (no summary event)", code),
            vim.log.levels.ERROR, { title = "PosteDb" })
        end
        S.is_running = false
        render_progress()
      end)
    end,
  })

  S.job_id = ok_job and job or -1

  if S.job_id <= 0 then
    vim.notify("Failed to start poste exec-file job", vim.log.levels.ERROR, { title = "PosteDb" })
    S.is_running = false
    render_progress()
    require("poste-db.sql_log").record({
      source = "run_file",
      sql = "[file] " .. (S.filepath or "?"),
      connection = S.conn or nil,
      database = S.db or nil,
      status = "error",
      error_msg = "failed to start exec-file job",
    })
  end
end

--- Internals exposed for the specs.
M._test = {
  extract_connection_directive = extract_connection_directive,
}

return M
