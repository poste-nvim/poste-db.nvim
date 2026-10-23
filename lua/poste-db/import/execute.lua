local state = require("poste-db.state")
local config = require("poste-db.config")
local dml = require("poste-db.dml")
local edit_commit = require("poste-db.edit_commit")
local mapping = require("poste-db.import.mapping")
local dialog = require("poste-db.dialog")
local verdict = require("poste-db.verdict")
local const = require("poste-db.constants")

local M = {}

--- What a chunk says about itself when the response reported a failure and the
--- body carried nothing readable to explain it. Shared by the journal entry and
--- the error dialog so the two cannot disagree about what was seen.
local UNREADABLE_CHUNK = "The chunk's response reported a failure and its results could not be read"

local function dedup_error(msg)
  local s = msg:match("^error returned from database: (.*)")
  if not s then s = msg end
  local n = #s
  for i = 1, math.floor((n - 2) / 2) do
    local left = s:sub(1, i)
    local sep = s:sub(i + 1, i + 2)
    if sep == ": " and s:sub(i + 3) == left then
      return left
    end
  end
  return s
end

local function show_import_errors(errors)
  if #errors == 0 then return end
  local groups = {}
  local order = {}
  for _, err in ipairs(errors) do
    local text = dedup_error(err.error)
    if groups[text] then
      groups[text].count = groups[text].count + 1
    else
      groups[text] = { count = 1, row = err.row, chunk_start = err.chunk_start, chunk_end = err.chunk_end }
      table.insert(order, text)
    end
  end

  local lines = {}
  local function add(l) table.insert(lines, l) end
  for _, text in ipairs(order) do
    local g = groups[text]
    add("")
    local suffix = g.count > 1 and string.format(" (%dx)", g.count) or ""
    local r = g.row or g.chunk_start
    local label = g.row and string.format("Row %d", r) or string.format("Row %d-%d", g.chunk_start, g.chunk_end)
    add(label .. suffix .. ":")
    for _, eline in ipairs(vim.split(text, "\n")) do
      add("  " .. eline)
    end
  end

  if #lines == 0 then return end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 4, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))

  local d = dialog.open({
    title = "Import Errors",
    width = width,
    height = height,
  })
  d:update(lines)
end

function M.execute_import(table_info, valid_rows, col_map, table_cols, callback)
  if #valid_rows == 0 then
    vim.notify("No valid rows to import", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
    if callback then callback(nil) end
    return
  end

  local norm_cols = mapping.normalize_columns(table_cols)
  -- `import_chunk_size` is user config, and both failure modes of an
  -- unclamped value are silent: a size below 1 makes the end index precede the
  -- start, so the chunk holds no statement, `end_idx + 1` is `start_idx` again,
  -- and the loop re-sends the same empty chunk forever; a non-numeric value
  -- throws mid-import, after the first chunks have already been written.
  local chunk_size = tonumber(config.config.import_chunk_size) or 100
  if chunk_size < 1 then chunk_size = 1 end
  chunk_size = math.floor(chunk_size)
  local total_imported = 0
  local all_errors = {}

  local src_file = table_info.search_dir .. "/.__poste_import_temp.sql"

  local conn_prefix = ""
  local conn_url = nil
  if table_info.connection and table_info.connection ~= "" then
    conn_prefix = "-- @connection " .. table_info.connection .. "\n"
    local connections = require("poste-db.connections")
    conn_url = connections.resolve_connection_url(table_info.connection)
  end
  local db_prefix = ""
  if table_info.database and table_info.database ~= "" then
    db_prefix = "-- @database " .. table_info.database .. "\n"
  end

  local function send_chunk(start_idx)
    if start_idx > #valid_rows then
      vim.schedule(function()
        local msg = string.format("Imported %d rows into %s%s",
          total_imported,
          table_info.schema and (table_info.schema .. ".") or "",
          table_info.name)
        if #all_errors > 0 then
          -- `all_errors` is one entry per rejected *statement* (plus one per
          -- dead process), so its length is not a chunk count: a chunk whose
          -- three rows all hit a constraint used to announce itself as
          -- "3 chunk(s) with errors", which reads as though much more of the
          -- file went bad than did.
          local bad_chunks = {}
          for _, e in ipairs(all_errors) do bad_chunks[e.chunk_start] = true end
          local n_chunks = 0
          for _ in pairs(bad_chunks) do n_chunks = n_chunks + 1 end
          vim.notify(msg .. string.format(" (%d chunk(s) with errors)", n_chunks), vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
          show_import_errors(all_errors)
        else
          vim.notify(msg, vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
        end
        if callback then callback({ imported = total_imported, errors = all_errors }) end
      end)
      return
    end

    local end_idx = math.min(start_idx + chunk_size - 1, #valid_rows)
    local sql_parts = {}
    for i = start_idx, end_idx do
      local row_vals = valid_rows[i]
      local stmt = dml.generate_insert(
        table_info.schema, table_info.name, norm_cols, row_vals, table_info.dialect)
      table.insert(sql_parts, stmt)
    end
    local sql_content = conn_prefix .. db_prefix .. table.concat(sql_parts, "\n")

    state.log("INFO", string.format("Import chunk: rows %d-%d (%d rows, target=%s.%s)",
      start_idx, end_idx, end_idx - start_idx + 1,
      table_info.schema or "(default)", table_info.name))

    local chunk_start = vim.fn.reltime()
    local exec_run = require("poste-db.exec_run")
    exec_run.run_async(sql_content, {
      src_file = src_file,
      conn_url = conn_url,
      database = table_info.database,
      mode = "greedy",
      log = false, -- chunk outcomes are journaled per chunk with source=import
    }, {
      on_response = function(resp)
        local ok_body, body = pcall(vim.json.decode, resp.body or "{}")
        if not ok_body or type(body) ~= "table" then body = {} end

        -- Read the statements first, the flag second. `has_error` is the
        -- binary's aggregate, and an unreadable body is exactly the case where
        -- the aggregate is missing while the truth is known: the response
        -- arrived as a failure. Taking the results unconditionally also means a
        -- per-statement error cannot be dropped because a flag was not set.
        local chunk_errors = {}
        for ri, result in ipairs(body.results or {}) do
          -- The flag decides, the text explains. Reading only `error` left a
          -- rejected-but-silent statement out of `chunk_errors`, and the entry
          -- below then said "its results could not be read" about a body that
          -- decoded fine — naming the wrong cause for the same failure.
          local failed, err_text = verdict.classify(result)
          if failed then
            chunk_errors[#chunk_errors + 1] = err_text
            table.insert(all_errors, {
              row = start_idx + ri - 1,
              chunk_start = start_idx, chunk_end = end_idx,
              error = err_text,
            })
          end
        end
        local has_error = (resp.has_error == true) or #chunk_errors > 0
        if has_error and #chunk_errors == 0 then
          -- The chunk was rejected and nothing names why. Recording it keeps the
          -- error dialog and the WARN summary honest: without this entry an
          -- import whose every chunk failed ends as "Imported 0 rows" at INFO
          -- level, which is true and useless.
          table.insert(all_errors, {
            chunk_start = start_idx, chunk_end = end_idx,
            error = UNREADABLE_CHUNK,
          })
        end

        local affected = 0
        if body.results then
          for _, result in ipairs(body.results) do
            -- A rejected statement applied nothing, so its number stays out of the
            -- count: this sum is what the summary line prints as "Imported N rows",
            -- and a driver can report matched rows for a statement it then refused.
            if not verdict.classify(result) then
              local ar = result.affected_rows
              if type(ar) == "number" then affected = affected + ar end
            end
          end
        end
        total_imported = total_imported + affected

        local elapsed = vim.fn.reltimefloat(vim.fn.reltime(chunk_start)) * 1000
        -- One chunk, one entry, one difference between the two outcomes: what
        -- the reason text says. Greedy mode means the statements that did not
        -- error are committed, so the entry has to say *which* statements
        -- errored — "One or more statements failed" tells a user reviewing the
        -- log nothing about which rows to re-import.
        local reason
        if has_error then
          reason = #chunk_errors > 0
            and string.format("%d statement(s) in this chunk failed: %s",
              #chunk_errors, chunk_errors[1])
            or UNREADABLE_CHUNK
        end
        edit_commit.write_log({
          source = "import",
          table_name = table_info.schema and (table_info.schema .. "." .. table_info.name) or table_info.name,
          connection = table_info.connection or "",
          dialect = table_info.dialect or "",
          database = table_info.database or "",
          sql = sql_content,
          status = has_error and "error" or "success",
          elapsed_ms = math.floor(elapsed + 0.5),
          -- Rows that really landed, on both outcomes. Under greedy mode the
          -- statements a chunk did not reject are committed, so a failed chunk's
          -- entry has to say how much of it took — otherwise the journal records a
          -- failure whose size is unknown and the only way back is to re-import
          -- everything and see what conflicts. The viewer shows this number for
          -- edit entries (they carry an `edit_summary` to compare against); for an
          -- import it stays in the JSON, where `total_imported` is the figure the
          -- on-screen summary already prints.
          affected_rows = affected,
          error_msg = reason,
        })

        send_chunk(end_idx + 1)
      end,
      on_error = function(message)
        local elapsed = vim.fn.reltimefloat(vim.fn.reltime(chunk_start)) * 1000
        edit_commit.write_log({
          source = "import",
          table_name = table_info.schema and (table_info.schema .. "." .. table_info.name) or table_info.name,
          connection = table_info.connection or "",
          dialect = table_info.dialect or "",
          database = table_info.database or "",
          sql = sql_content,
          status = "error",
          elapsed_ms = math.floor(elapsed + 0.5),
          error_msg = "Process error:\n" .. message,
        })
        table.insert(all_errors, {
          chunk_start = start_idx, chunk_end = end_idx,
          error = "Process error:\n" .. message,
        })
        state.log("WARN", "Import chunk error: " .. message)
        vim.schedule(function()
          vim.notify("Import stopped due to process error", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
          if callback then callback({ imported = total_imported, errors = all_errors }) end
        end)
      end,
    })
end

send_chunk(1)
end

return M
