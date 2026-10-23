--- Dataset edit commit — DML generation, transactional commit, SQL logging.

local editor = require("poste-db.editor")
local sql_format = require("poste-db.format")
local sql_buffer = require("poste-db.buffer")
local const = require("poste-db.constants")
local dml = require("poste-db.dml")
local exec = require("poste-db.edit_commit.exec")
local log = require("poste-db.edit_commit.log")
local util = require("poste-db.util")

local M = {}
M.generate_update = dml.generate_update
M.generate_insert = dml.generate_insert
M.generate_delete = dml.generate_delete
M.generate_dml = dml.generate_dml

---------------------------------------------------------------------------
-- SQL Log
---------------------------------------------------------------------------
function M.format_log_entry(entry) return log.format_log_entry(entry) end
function M.write_log(entry) return log.write_log(entry) end
function M.set_log_path(path) return log.set_log_path(path) end

---------------------------------------------------------------------------
-- Commit / Rollback
---------------------------------------------------------------------------

--- Generate combined DML and return as single SQL string.
--- @param es table edit_state
--- @param tab table Tab state
--- @param dialect string Dialect
--- @return string|nil combined SQL (nil when nothing survived)
--- @return table summary
--- @return string[] skipped reasons for refused statements
function M.generate_combined_dml(es, tab, dialect)
  local stmts, skipped = dml.generate_dml(es, tab, dialect)
  if #stmts == 0 then
    return nil, { updates = 0, inserts = 0, deletes = 0 }, skipped
  end

  local sql_parts = {}
  local summary = { updates = 0, inserts = 0, deletes = 0 }
  for _, s in ipairs(stmts) do
    table.insert(sql_parts, s.sql)
    if s.type == "update" then summary.updates = summary.updates + 1
    elseif s.type == "insert" then summary.inserts = summary.inserts + 1
    elseif s.type == "delete" then summary.deletes = summary.deletes + 1
    end
  end

  return table.concat(sql_parts, "\n"), summary, skipped
end

--- Re-execute original SELECT and refresh the dataset in-place.
--- Bypasses run_sql_request() to avoid cursor-position-dependent buffer parsing.
--- @param tab table Tab state with original_sql, src_file, src_buf
function M.refresh_dataset(tab)
  local state = require("poste-db.state")
  local statement = require("poste-db.statement")

  local sql = tab.original_sql
  if not sql or sql == "" then
    vim.notify("No original SQL to re-execute", vim.log.levels.WARN, { title = "PosteDb" })
    return
  end

  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found", vim.log.levels.ERROR)
    return
  end

  local conn = (tab.layout and tab.layout._conn_name) or state.context.connection or ""
  local db = ""
  if tab.layout then
    local layout_db = tab.layout._database or tab.layout.database
    if layout_db and layout_db ~= "" then db = layout_db end
  end
  if db == "" then db = state.context.database or "" end

  local conn_url = nil
  if conn and conn ~= "" then
    local connections = require("poste-db.connections")
    conn_url = connections.resolve_connection_url(conn)
  end

  -- Strip directives and ### markers from SQL, since original_sql
  -- may contain the full buffer content (-- @connection, ###, etc.)
  local sql_lines = vim.split(sql, "\n", { plain = true })
  local clean_sql_lines = {}
  for _, line in ipairs(sql_lines) do
    local trimmed = line:match("^%s*(.*)$")
    if trimmed ~= "" and not trimmed:match("^%-%-") and not const.is_section_marker(trimmed) then
      table.insert(clean_sql_lines, line)
    end
  end

  -- Clear PK cache so the new layout gets primary_key info re-introspected
  editor.clear_pk_cache()

  local clean_sql = table.concat(clean_sql_lines, "\n")
  local exec_run = require("poste-db.exec_run")

  local job_id = exec_run.run_async(clean_sql, {
    src_file = tab.src_file,
    conn_url = conn_url,
    database = db,
    mode = "greedy",
    log = false, -- journaling happens in execute_commit with edit_summary
  }, {
    on_response = function(parsed)
      vim.schedule(function()
        local lines, meta, layout = sql_format.format_dataset(parsed)
        if layout then
          local table_name = statement.extract_table_name(sql)
          if table_name then meta.table_name = table_name end
        end

        -- Pass the fresh resultset explicitly: render_dataset otherwise falls
        -- back to state.last_response.body, which only the sql_runner request
        -- path updates — after an R-refresh, cell preview (K) / yank / sort
        -- would read the pre-refresh rows while the buffer shows new ones.
        local data = util.decode_dataset_body(parsed)

        local sql_runner = require("poste-db.sql_runner")
        sql_buffer.render_dataset(lines, meta, {
          exec_seq = sql_runner.get_exec_seq(),
          layout = layout,
          data = data,
          original_sql = tab.original_sql,
          src_file = tab.src_file,
          src_buf = tab.src_buf,
        })
      end)
    end,
    on_error = function(message)
      vim.schedule(function()
        vim.notify("Refresh failed: " .. message, vim.log.levels.ERROR, { title = "PosteDb" })
      end)
    end,
  })

  if not job_id or job_id <= 0 then
    vim.notify("Failed to start refresh job", vim.log.levels.ERROR, { title = "PosteDb" })
  end
end

---------------------------------------------------------------------------
-- Commit / Rollback execution
---------------------------------------------------------------------------

--- Commit all pending edits by generating and executing DML.
function M.commit_edits()
  local D = require("poste-db.dataset")
  local state = require("poste-db.state")
  local tab = D.T()
  if not tab or not tab.edit_state or not tab.edit_state.dirty then
    vim.notify("No changes to commit", vim.log.levels.INFO, { title = "PosteDb" })
    return
  end

  -- Guard: warn if no primary key for UPDATE/DELETE (but don't block — use all-column WHERE)
  local es = tab.edit_state
  local has_updates = not vim.tbl_isempty(es.modified_cells)
  local has_deletes = not vim.tbl_isempty(es.deleted_rows)
  if (has_updates or has_deletes) and tab.layout then
    local pk_cols = {}
    for _, col in ipairs(tab.layout.columns) do
      if col.primary_key then table.insert(pk_cols, col.name) end
    end
    if #pk_cols == 0 then
      vim.notify("No primary key info — WHERE will use all column values", vim.log.levels.WARN, { title = "PosteDb" })
    end
  end

  local dialect = tab.layout and tab.layout.dialect or "postgres"

  -- Ensure primary key info is available so generated WHERE uses PK columns
  -- (introspection may have been skipped or the cache cleared after refresh).
  local column = require("poste-db.editor.column")
  column.ensure_primary_key(tab)

  local sql, summary, skipped = M.generate_combined_dml(es, tab, dialect)
  if skipped and #skipped > 0 then
    -- each line names what was refused and why (`update row 3 skipped: no WHERE
    -- target …`, or one whole-batch line when the result set has no table name);
    -- the count stays out of the header because a batch-level refusal is one line
    -- for several edits
    vim.notify("Some edits were not committed:\n"
      .. table.concat(skipped, "\n"), vim.log.levels.WARN, { title = "PosteDb" })
  end
  if not sql then
    vim.notify(skipped and #skipped > 0
        and "Nothing to commit — every edit was skipped (see warning)"
        or "No changes to commit", vim.log.levels.INFO, { title = "PosteDb" })
    return
  end

  -- Execute via poste CLI
  local binary = state.find_poste_binary()
  if not binary then
    vim.notify("Poste binary not found", vim.log.levels.ERROR)
    return
  end

  local connection = tab.layout and tab.layout._conn_name or state.context.connection or ""
  local table_name = tab.layout and tab.layout.table_name or ""

  -- Resolve database: layout._database → layout.database → context → connections.json default
  local database = ""
  if tab.layout then
    local layout_db = tab.layout._database or tab.layout.database
    if layout_db and layout_db ~= "" then database = layout_db end
  end
  if database == "" then
    database = state.context.database or ""
  end
  if database == "" and connection ~= "" then
    local config = require("poste-db.connections").get_connection_config(connection)
    if config and config.database and config.database ~= "" then
      database = config.database
    end
  end
  local src_file = tab.src_file or ""

  -- poste run needs a FILE for env.json discovery
  if src_file == "" then
    src_file = vim.fn.tempname() .. ".sql"
  end

  local conn_url = nil
  if connection and connection ~= "" then
    local connections = require("poste-db.connections")
    local resolved, resolve_err = connections.resolve_connection_url(connection)
    if not resolved then
      -- Fail closed: a nil URL reaches exec-file without --connection and the
      -- binary would commit the batch against its own default connection.
      vim.notify(string.format(
        "Commit refused — cannot resolve connection '%s': %s",
        connection, resolve_err or "unknown error"),
        vim.log.levels.ERROR, { title = "PosteDb" })
      return
    end
    conn_url = resolved
  end

  local sql_content = sql
  local start_time = vim.uv.now()
  local exec_run = require("poste-db.exec_run")

  -- Transactional commit: exec-file wraps the batch in BEGIN/COMMIT and
  -- rolls back on the first failed statement (summary.rolled_back=true).
  -- Dialects without transaction semantics (clickhouse) keep the old
  -- per-statement greedy behavior — partial application is possible there.
  local transactional = const.supports_transactions(dialect)
  local exec_mode = transactional and "transaction" or "greedy"

  local job_id = exec_run.run_async(sql_content, {
    src_file = src_file,
    conn_url = conn_url,
    database = database,
    mode = exec_mode,
    log = false, -- this function journals the commit with edit_summary itself
  }, {
    on_response = function(resp)
      local elapsed = vim.uv.now() - start_time

      local body = exec.decode_body(resp)
      local errors = exec.collect_statement_errors(body)
      local kind, detail = exec.commit_outcome(summary, body, errors)

      if kind == "rolled_back" or kind == "error" then
        local prefix
        if kind == "rolled_back" then
          prefix = "Commit failed — rolled back, no changes applied:\n"
        else
          prefix = transactional
            and "Commit failed — rolled back, no changes applied:\n"
            or "Commit failed (partial changes may have been applied):\n"
        end
        vim.notify(prefix .. detail:sub(1, 500), vim.log.levels.ERROR, { title = "PosteDb" })
        log.write_log({
          source = "dataset_commit",
          table_name = table_name,
          connection = connection,
          dialect = dialect,
          database = database,
          sql = sql,
          status = "error",
          elapsed_ms = elapsed,
          edit_summary = summary,
          rolled_back = kind == "rolled_back",
          error_msg = detail:sub(1, 500),
        })
        return
      end

      -- Success, or PARTIAL: every statement ran, but fewer rows changed than
      -- the edit set expected (the row was concurrently changed or deleted).
      -- A partial commit must not be journaled as a plain success: the WARN
      -- notification scrolls away, and the journal is what `<leader>l` shows
      -- later — a "success" row there would rewrite history and hide the fact
      -- that some edits never landed. `detail` rides along as the entry's
      -- error text (truncated on write) so the expanded row explains itself.
      local affected = exec.count_affected_rows(body)

      local msg = string.format("Committed: %d update(s), %d insert(s), %d delete(s) (%d row(s) affected)",
        summary.updates, summary.inserts, summary.deletes, affected)
      if kind == "partial" then
        msg = msg .. " — " .. detail
      end
      if not transactional then
        msg = msg .. " [no transaction support — committed per-statement]"
      end
      vim.notify(msg, kind == "partial" and vim.log.levels.WARN or vim.log.levels.INFO, { title = "PosteDb" })
      log.write_log({
        source = "dataset_commit",
        table_name = table_name,
        connection = connection,
        dialect = dialect,
        database = database,
        sql = sql,
        status = kind == "partial" and "partial" or "success",
        elapsed_ms = elapsed,
        edit_summary = summary,
        affected_rows = affected,
        mode = exec_mode,
        error_msg = kind == "partial" and detail:sub(1, 500) or nil,
      })
      -- Clear edit state and refresh dataset in-place
      require("poste-db.editor").reset_edit_state(tab.edit_state)
      tab.edit_state = nil
      M.refresh_dataset(tab)
    end,
    on_error = function(message)
      local elapsed = vim.uv.now() - start_time
      vim.notify("Commit: " .. message, vim.log.levels.ERROR, { title = "PosteDb" })
      log.write_log({
        source = "dataset_commit",
        table_name = table_name,
        connection = connection,
        dialect = dialect,
        database = database,
        sql = sql,
        status = "error",
        elapsed_ms = elapsed,
        edit_summary = summary,
        error_msg = message:sub(1, 500),
      })
    end,
  })

  if not job_id or job_id <= 0 then
    vim.notify("Failed to start poste exec-file job", vim.log.levels.ERROR, { title = "PosteDb" })
  end
end

return M
