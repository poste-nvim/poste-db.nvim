--- Introspection --- shell command execution and job management.
local cli = require("poste-db.cli")
local util = require("poste-db.util")
local job = require("poste-db.introspect.job")
local sql_log = require("poste-db.sql_log")
local const = require("poste-db.constants")

local M = {}

function M.run_json_items_job(args, opts)
  opts = opts or {}
  local stderr_lines = {}
  local t0 = vim.uv.now()
  local journal = sql_log.cli_fields(args, "introspect")
  -- Buffered stdout is delivered even on a failed run, so the parse path and
  -- the non-zero-exit path can both fire — journal only the first outcome.
  local journaled = false
  local function journal_once(status, error_msg)
    if journaled then return end
    journaled = true
    sql_log.record(vim.tbl_extend("force", journal, {
      status = status,
      elapsed_ms = vim.uv.now() - t0,
      error_msg = error_msg,
    }))
  end

  -- cli.run_async buffers stdout, so a SUCCESSFUL run with NO output delivers
  -- `{ "" }` — ensure_job_data strips it to `{}` and the parse path used to
  -- return before anything happened: no empty_message notify, no journal, no
  -- on_items — the DDL/column float never appeared with zero feedback.
  -- on_exit remembers whether the parse path ran and settles the empty case.
  local saw_parse = false

  cli.run_async(args, {
    on_stdout = function(data)
      data = util.ensure_job_data(data)
      if #data == 0 then return end

      saw_parse = true
      local output = table.concat(data, "\n")
      vim.schedule(function()
        local parsed = job.decode_json_table(output, opts.failure_message or "Failed to parse response")
        if not parsed then
          journal_once("error", opts.failure_message or "Failed to parse response")
          return
        end

        local items = parsed.items
        if not items or #items == 0 then
          if opts.empty_message then
            vim.notify(opts.empty_message, vim.log.levels.WARN, { title = opts.title or const.PLUGIN_TITLE })
          end
          -- The query itself succeeded; empty is a result, not a failure.
          journal_once("success", nil)
          return
        end

        journal_once("success", nil)

        if opts.on_items then
          opts.on_items(items, parsed)
        end
      end)
    end,
    on_stderr = function(data)
      job.append_stderr(stderr_lines, data, opts.stderr_prefix)
    end,
    on_exit = function(code)
      if code ~= 0 then
        vim.schedule(function()
          job.notify_exit_error(opts.exit_kind or "Introspection", code, stderr_lines, opts.title or const.PLUGIN_TITLE)
        end)
        local err_text = table.concat(stderr_lines, "\n")
        journal_once("error", err_text ~= "" and err_text
          or (opts.exit_kind or "Introspection") .. " exit code " .. tostring(code))
      elseif not saw_parse then
        -- Exit 0 with nothing on stdout: same empty-result treatment as a
        -- decoded-but-empty payload.
        vim.schedule(function()
          if opts.empty_message then
            vim.notify(opts.empty_message, vim.log.levels.WARN, { title = opts.title or const.PLUGIN_TITLE })
          end
        end)
        journal_once("success", nil)
      end
    end,
  })
end

return M
