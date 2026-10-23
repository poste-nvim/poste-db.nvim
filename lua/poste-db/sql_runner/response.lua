--- Response handling for sql_runner — result routing, dataset rendering,
--- indicator placement and cache invalidation. Split from run_sql_request's
--- closures; every request-scoped value arrives explicitly via `deps`, so
--- nothing here closes over request locals:
---
---   entry, current_seq, get_exec_seq, src_buf, src_file, buf_lines,
---   buf_content, stmt_sql_raw, stmt_lines, first_line, is_visual,
---   visual_sel_end, vis_start, vis_end, set_lines, block_result_line
local state = require("poste-db.state")
local config = require("poste-db.config")
local indicators = require("poste-db.indicators")
local statement = require("poste-db.statement")
local util = require("poste-db.util")
local sql_format = require("poste-db.format")
local dataset = require("poste-db.dataset")
local sql_buffer = require("poste-db.buffer")
local verdict = require("poste-db.verdict")
local const = require("poste-db.constants")

local M = {}

--- Was this statement failed, and with what text? See `poste-db.verdict`: the
--- flag is the verdict, the message only explains it, and a silent failure is a
--- shape a run can really arrive in.
local classify_result = verdict.classify

--- Compute the indicator line for a statement: the statement's FIRST line
--- (0-based), so the sign-column spinner / ✓ / ✘ sits beside the statement
--- start, aligned with where the user ran it from.
--- @param line_nr number statement start line (inclusive, 1-based)
--- @return number 0-based line index for indicators.set_indicator
function M.stmt_indicator_line(line_nr)
  return line_nr - 1
end

--- True when the first real statement of `sql` is DDL (CREATE/ALTER/DROP/
--- TRUNCATE/RENAME). Leading `-- @connection` directives, `###` section
--- markers, blank lines and comment lines are skipped before inspecting the
--- keyword, because buf_content (and visual blocks) carry that noise.
--- The keyword test is case-insensitive: SQL keywords are not case-sensitive,
--- and the family's own CREATE TABLE template (db_browser/operations.lua)
--- inserts lowercase `create table` — an exact-case match would skip the
--- completion/diagnostics cache invalidation for every statement written
--- from that template.
--- @param sql string|nil
--- @return boolean
function M.is_ddl(sql)
  if not sql then return false end
  for _, ln in ipairs(vim.split(sql, "\n", { plain = true })) do
    local t = ln:match("^%s*(.*)%s*$") or ""
    if t ~= "" and not t:match("^%-%-") and not t:match("^###") then
      local kw = t:lower()
      return kw:match("^create%s") ~= nil
        or kw:match("^alter%s") ~= nil
        or kw:match("^drop%s") ~= nil
        or kw:match("^truncate%s") ~= nil
        or kw:match("^rename%s") ~= nil
    end
  end
  return false
end

--- Handle one executor response: stale-seq guard, DDL cache invalidation,
--- USE handling, SET-prelude filtering, then multi-tab or single-result
--- rendering with per-statement indicator placement.
function M.handle(deps, parsed)
  state.log("DEBUG", "SQL on_response called: latency=" .. tostring(parsed.latency_ms or "?") .. " type=" .. (parsed.dialect or "?"))
  local ok_cb, err_cb = pcall(function()
    local exec_seq_now = deps.get_exec_seq()
    if deps.current_seq < exec_seq_now then
      state.log("DEBUG", "SQL on_response stale: current=" .. tostring(deps.current_seq) .. " exec=" .. tostring(exec_seq_now))
      return
    end
    state.last_response = parsed
    deps.entry.elapsed_ms = tonumber(parsed.latency_ms) or 0

    -- DDL detection: buf_content (and visual blocks) may carry leading
    -- directives (`-- @connection`), `###` section markers, blank and
    -- comment lines, so inspect the first real statement's keyword instead
    -- of anchoring the regex at the start of the whole blob.
    if M.is_ddl(deps.stmt_sql_raw or deps.buf_content) then
      require("poste-db.completion.data").clear_cache()
      -- Semantic diagnostics cache the introspected schema; a DDL may have
      -- created/renamed/dropped tables, so invalidate and re-check so the
      -- new tables are no longer reported as "not found".
      local ok_sem, sem = pcall(require, "poste-db.semantic_diagnostics")
      if ok_sem then
        sem.invalidate(state.context.connection, state.context.database)
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(deps.src_buf) then
            sem.update(deps.src_buf)
          end
        end)
      end
    end

    require("poste-db.context").handle_use_statement(parsed)

    local results = parsed.results or {}
    -- When preceding SET @var statements were pulled in, the first #set_lines
    -- results are SET (affected-rows) responses — skip them since they're
    -- dependencies, not the user-selected statement.
    local prelude_count = (not deps.is_visual and deps.set_lines and #deps.set_lines > 0) and #deps.set_lines or 0
    if prelude_count > 0 and #results > 1 then
      local n = math.min(prelude_count, #results - 1)
      local filtered = {}
      for i = n + 1, #results do filtered[#filtered + 1] = results[i] end
      results = filtered
      parsed.results = results
      -- Re-encode body for consumers that rely on parsed.body
      local decoded = util.decode_dataset_body(parsed)
      if decoded then
        decoded.results = results
        decoded.total_results = #results
        parsed.body = vim.json.encode(decoded)
      end
    end
    local is_multi = #results > 1

    if is_multi then
      local tab_idx = 0
      local hide_empty = config.config.hide_empty_result_tabs ~= false
      for i, result in ipairs(results) do
        local failed, err_text = classify_result(result)
        if failed then
          deps.entry.error = true
          state.last_error = {
            message = err_text,
            sql = statement.get_stmt_sql(deps.buf_lines, deps.stmt_lines, i, deps.visual_sel_end or #deps.buf_lines) or deps.buf_content,
            connection = parsed.connection,
            database = parsed.database,
            at = os.time(),
          }
          tab_idx = tab_idx + 1
          local err_line = deps.stmt_lines[i] or deps.first_line
          indicators.set_indicator(deps.src_buf, M.stmt_indicator_line(err_line), "error")
          local lines = sql_format.format_error(err_text, parsed.connection or "")
          sql_buffer.render_dataset(lines, { type = "error" }, { tab_index = tab_idx, exec_seq = deps.current_seq })
        else
          -- `or deps.stmt_end or #deps.buf_lines`: without a visual selection
          -- visual_sel_end is nil, and get_stmt_sql's no-max_end default
          -- (`stop = start`) truncates a multi-line statement to its first
          -- line, losing e.g. the FROM clause for table-name extraction.
          local sql_text = statement.get_stmt_sql(deps.buf_lines, deps.stmt_lines, i,
            deps.visual_sel_end or deps.stmt_end or #deps.buf_lines)
          local table_name = statement.extract_table_name(sql_text)
          local single_data = {
            type = "resultset",
            results = { result },
            total_rows = tonumber(result.row_count) or 0,
            total_affected = tonumber(result.affected_rows) or 0,
            total_execution_time_ms = tonumber(result.execution_time_ms) or 0,
            connection = result.connection or parsed.connection,
            database = parsed.database,
            dialect = parsed.dialect,
            table_name = table_name,
          }
          local layout = sql_format.plan_resultset_layout(single_data)
          local lines, meta
          if layout then
            tab_idx = tab_idx + 1
            lines, meta = sql_format.render_page(layout, 1, dataset.default_page_size)
            meta.table_name = table_name
          elseif hide_empty then
            -- Skip statements with no result set (SET, USE, etc.) — they
            -- would otherwise clutter the dataset with empty tabs.
            local line_nr = deps.stmt_lines[i] or deps.first_line
            indicators.set_indicator(deps.src_buf, M.stmt_indicator_line(line_nr),
              "success", result.execution_time_ms)
            goto continue
          else
            tab_idx = tab_idx + 1
            lines, meta, layout = sql_format.format_resultset(single_data)
            meta.table_name = table_name
          end
          sql_buffer.render_dataset(lines, meta, {
            tab_index = tab_idx,
            exec_seq = deps.current_seq,
            data = single_data,
            layout = layout,
            original_sql = deps.buf_content,
            src_file = deps.src_file,
            src_buf = deps.src_buf,
          })

          local line_nr = deps.stmt_lines[i] or deps.first_line
          indicators.set_indicator(deps.src_buf, M.stmt_indicator_line(line_nr),
            "success", result.execution_time_ms)
        end
        ::continue::
      end
    else
      -- Single result
      local table_name
      if deps.is_visual then
        local start_ln = math.min(deps.vis_start, deps.vis_end)
        local end_ln = math.max(deps.vis_start, deps.vis_end)
        local vis_lines = {}
        for i = start_ln, end_ln do
          local ln = deps.buf_lines[i]
          if ln then vis_lines[#vis_lines + 1] = ln end
        end
        table_name = statement.extract_table_name(table.concat(vis_lines, " "))
      else
        table_name = statement.extract_table_name(deps.buf_content)
      end
      local lines, meta, layout = sql_format.format_dataset(parsed)
      if table_name then meta.table_name = table_name end
      sql_buffer.render_dataset(lines, meta, {
        exec_seq = deps.current_seq,
        layout = layout,
        original_sql = deps.buf_content,
        src_file = deps.src_file,
        src_buf = deps.src_buf,
      })

      -- The envelope verdict counts too: `has_error` is set from each event's
      -- `status`, so a failure whose text arrived empty would still be a
      -- failure. Reading only `results[1].error` is what painted a green ✓
      -- beside a statement the server rejected silently.
      local has_err, err_text = classify_result(results[1])
      if not has_err and parsed.has_error == true then
        has_err, err_text = true, verdict.UNEXPLAINED_FAILURE
      end
      if has_err then
        deps.entry.error = true
        state.last_error = {
          message = err_text,
          sql = deps.buf_content or "",
          connection = parsed.connection,
          database = parsed.database,
          at = os.time(),
        }
      end
      local result_line = deps.first_line
      if has_err then
        indicators.set_indicator(deps.src_buf, result_line - 1, "error")
      else
        indicators.set_indicator(deps.src_buf, result_line - 1, "success", parsed.latency_ms)
      end
    end

    -- Refresh DB browser tree for the connection/database used
    local db_browser = require("poste-db.db_browser.init")
    if db_browser.is_open() and parsed.connection then
      db_browser.refresh_by_conn(parsed.connection, parsed.database)
    end
  end)
  if not ok_cb then
    state.log("ERROR", "SQL on_response error: " .. tostring(err_cb))
    vim.notify("SQL execution error: " .. tostring(err_cb), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
  end
end

--- Handle an executor-level failure (transport errors, dead sessions):
--- record for the AI chat's "ask about this error", surface, log.
--- @param message string
--- @param parsed table|nil parsed response (session on_sql_error path) — its
---   dialect is the only reliable source here; state.context has no dialect field.
function M.handle_error(deps, message, parsed)
  state.log("ERROR", "SQL execution failed: " .. message)
  vim.schedule(function()
    if deps.current_seq < deps.get_exec_seq() then return end
    deps.entry.error = true
    -- retained for the AI chat's "ask about this error" action
    local err_ctx = require("poste-db.context").resolve_full_context(deps.src_buf, #deps.buf_lines)
    state.last_error = {
      message = tostring(message),
      sql = deps.stmt_sql_raw or deps.buf_content,
      connection = err_ctx.connection,
      database = err_ctx.database,
      at = os.time(),
    }
    indicators.set_indicator(deps.src_buf, deps.block_result_line, "error")
    -- A table here is the session transport's per-statement SQL error; nil or
    -- a string is a transport failure (binary missing, refused start, dead
    -- session, non-zero exit). A SQL failure reports through the panel on
    -- either transport — the error tab and ✘ indicator below — so the notify
    -- stays transport-only: the same failure should not behave differently
    -- because of which transport happened to serve it.
    if type(parsed) ~= "table" then
      vim.notify(message, vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    end
    local lines = sql_format.format_error(message, state.context.connection or "")
    sql_buffer.render_dataset(lines, { type = "error" })
  end)
end

return M
