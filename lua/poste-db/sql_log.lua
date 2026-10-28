--- Persistent SQL activity log — the single writer for sql_log.jsonl,
--- the journal behind the `<leader>l` viewer (`log_viewer.lua`).
---
--- Every SQL-carrying request should land here exactly once, success or
--- failure: manual runs, run-file, AI-executed SQL, EXPLAIN, dataset edit
--- commits, imports, browser queries, schema introspection and connection
--- probes — including transport-level failures (connection timeout, missing
--- binary) that never produce a response envelope.
---
--- Entry fields (JSON keys): ts, source, sql, connection, dialect, database,
--- status, elapsed_ms, error + passthrough extras (table, edit_summary,
--- affected_rows, rolled_back, mode). `source` tags the surface; see
--- log_viewer's SOURCE_TAGS for the display mapping.
---
--- `status` vocabulary: "error" (the request failed — transport-level or an
--- in-band statement error) and "success". One writer adds a third:
--- "partial", for a request that ran to completion yet achieved less than it
--- promised — a dataset edit commit whose statements matched fewer rows than
--- there were edits. Partial rows are never written as "success", and their
--- `error` text says what was missed, so the journal alone can be trusted.

local const = require("poste-db.constants")
local log = require("poste-db.log")
-- Dependency-free, so this cannot cycle even though every transport requires
-- this module.
local verdict = require("poste-db.verdict")

local M = {}

local SQL_LOG_PATH = nil
local _log_write_count = 0

local MAX_ERROR_LEN = 500


--- Where the journal lives. The one place that knows: the writer
--- (`M.append`), `M.clear` and the `<leader>l` viewer all read the journal
--- through here, so the viewer honors `set_log_path` too (it used to build
--- the same `stdpath("data").."/poste/sql_log.jsonl"` string itself and read
--- the real journal even when a spec had redirected the writer).
function M.path()
  if SQL_LOG_PATH then return SQL_LOG_PATH end
  SQL_LOG_PATH = vim.fn.stdpath("data") .. "/poste/sql_log.jsonl"
  local dir = vim.fn.fnamemodify(SQL_LOG_PATH, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    -- raises E739 on a permission wall; the journal writer runs inside
    -- execution paths whose own error handling must not die on a log write
    pcall(vim.fn.mkdir, dir, "p")
  end
  return SQL_LOG_PATH
end

--- Override the log path (tests).
function M.set_log_path(path)
  SQL_LOG_PATH = path
end

--- JSON line for one entry. Nil fields are omitted; unknown fields
--- (edit_summary, affected_rows, ...) pass through so callers can enrich.
--- `error_msg`/`table_name` are internal names (JSON: `error`/`table`) and
--- must not leak through the passthrough loop under their raw keys.
local PASSTHROUGH_SKIP = { error_msg = true, table_name = true }

function M.format_entry(entry)
  entry = entry or {}
  local data = {
    ts = os.date("!%Y-%m-%dT%H:%M:%S"),
  }
  if entry.source then data.source = entry.source end
  if entry.sql then data.sql = entry.sql end
  if entry.table_name then data["table"] = entry.table_name end
  if entry.connection then data.connection = entry.connection end
  if entry.dialect then data.dialect = entry.dialect end
  if entry.database then data.database = entry.database end
  if entry.status then data.status = entry.status end
  if entry.elapsed_ms then data.elapsed_ms = entry.elapsed_ms end
  if entry.error_msg then data.error = entry.error_msg end
  for k, v in pairs(entry) do
    if not PASSTHROUGH_SKIP[k] and data[k] == nil and v ~= nil then data[k] = v end
  end
  return vim.json.encode(data)
end

--- Append one entry to the journal. Never raises: a failed write must not
--- break the request it documents. Periodically trims the file to
--- `const.LOG_MAX_ENTRIES` lines.
function M.record(entry)
  entry = entry or {}
  if entry.error_msg and type(entry.error_msg) == "string" then
    entry.error_msg = entry.error_msg:sub(1, MAX_ERROR_LEN)
  end
  if type(entry.connection) == "string" then
    entry.connection = log.redact_url(entry.connection)
  end
  local ok, line = pcall(M.format_entry, entry)
  if not ok then return nil end

  local path = M.path()
  local ok_w = pcall(function()
    local f = io.open(path, "a")
    if f then
      f:write(line, "\n")
      f:close()
    end
  end)
  if not ok_w then return nil end

  _log_write_count = _log_write_count + 1
  if _log_write_count < const.LOG_TRIM_EVERY then return entry end
  _log_write_count = 0
  pcall(function()
    local lines = {}
    for l in io.lines(path) do
      lines[#lines + 1] = l
    end
    if #lines > const.LOG_MAX_ENTRIES then
      local keep = {}
      for i = #lines - const.LOG_MAX_ENTRIES + 1, #lines do
        keep[#keep + 1] = lines[i]
      end
      local f = io.open(path, "w")
      if f then
        f:write(table.concat(keep, "\n"), "\n")
        f:close()
      end
    end
  end)
  return entry
end

--- Build the entry base for a transport seam (exec_run/executor): common
--- fields every request path knows before dispatching. Returns nil when the
--- caller opted out (`opts.log == false`).
---   opts.log_source  surface tag ("manual_exec", "browser", ...)
---   opts.log_extra   field overrides, typically { connection = <name> }
---   opts.conn_url    resolved URL — redacted when no name override is given
---   opts.database    database override
function M.seam_base(opts)
  opts = opts or {}
  if opts.log == false then return nil end
  local extra = opts.log_extra or {}
  local conn = extra.connection
  if conn == nil or conn == "" then
    conn = opts.conn_url and log.redact_url(opts.conn_url) or nil
  end
  return {
    source = opts.log_source or "exec",
    connection = conn,
    database = extra.database or opts.database or nil,
  }
end

--- Journal a delivered response: status from `resp.has_error`, first in-band
--- statement error as the error text. Shared by the exec_run and executor
--- seams.
function M.result(base, resp, elapsed_ms)
  if not base then return end
  local status, first_err = "success", nil
  if resp and resp.has_error then
    status = "error"
    for _, r in ipairs(resp.results or {}) do
      if r.error and r.error ~= "" then first_err = tostring(r.error) break end
    end
    -- Same sentence the panel and the AI action show for this shape: the
    -- journal used to carry a third, drifting wording of its own.
    if not first_err then first_err = verdict.UNEXPLAINED_FAILURE end
  end
  M.record(vim.tbl_extend("force", base, {
    status = status,
    elapsed_ms = elapsed_ms,
    dialect = resp and resp.dialect or nil,
    error_msg = first_err,
  }))
end

--- Journal a transport-level failure (timeout, dead session, missing binary,
--- spawn failure) — no response envelope exists.
function M.fail(base, message, elapsed_ms)
  if not base then return end
  M.record(vim.tbl_extend("force", base, {
    status = "error",
    elapsed_ms = elapsed_ms,
    error_msg = message,
  }))
end

--- Wrap the user's response/error callbacks so a transport logs exactly one
--- journal entry per request: `M.result` on a response (binary-reported
--- latency when present, wall clock otherwise), `M.fail` on a transport
--- error. `executor.lua` (whose entry the session and exec-file fallbacks
--- share) and `exec_run.lua` carried byte-identical copies of this seam.
--- @param base table|nil journal base; nil = journaling off, callbacks pass through
--- @param t0 number wall-clock start (vim.uv.now())
--- @param sql string|nil statement text, stamped on the base when it lacks one
--- @param on_response function|nil
--- @param on_error function|nil
--- @return function|nil wrapped_on_response
--- @return function|nil wrapped_on_error
function M.wrap_callbacks(base, t0, sql, on_response, on_error)
  if not base then return on_response, on_error end
  if not base.sql and sql then base.sql = sql end
  return function(parsed)
    local elapsed = tonumber(parsed and parsed.latency_ms) or (vim.uv.now() - t0)
    M.result(base, parsed, elapsed)
    if on_response then on_response(parsed) end
  end, function(message, extra)
    M.fail(base, message, vim.uv.now() - t0)
    if on_error then on_error(message, extra) end
  end
end

--- Journal fields for a raw `poste <subcommand>` job (introspect listings,
--- connection probes): pulls the connection URL and --database out of the
--- args so the entry carries them, while the sql summary stays readable
--- (URL omitted — it is redacted on write anyway).
function M.cli_fields(args, source)
  local conn_url, database = nil, nil
  local parts = {}
  local skip_next = false
  for i, a in ipairs(args) do
    if skip_next then
      skip_next = false
    elseif a == "--connection-url" then
      conn_url = args[i + 1]
      skip_next = true
    elseif a == "--database" then
      database = args[i + 1]
      parts[#parts + 1] = a
    else
      parts[#parts + 1] = a
    end
  end
  return {
    source = source,
    sql = table.concat(parts, " "),
    connection = conn_url,
    database = database,
  }
end

return M
