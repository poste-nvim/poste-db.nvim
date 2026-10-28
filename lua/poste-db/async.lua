local cli = require("poste-db.cli")

local M = {}

function M.run(args, opts)
  opts = opts or {}
  local timeout = opts.timeout or 15000
  local state = {
    job_id = nil,
    alive = false,
    cancelled = false,
    timer = nil,
  }

  local task = {}

  function task:cancel()
    if not state.alive then return end
    state.cancelled = true
    state.alive = false
    if state.timer then
      state.timer:stop()
      state.timer = nil
    end
    if state.job_id and vim.fn.jobwait({ state.job_id }, 0)[1] == -1 then
      pcall(vim.fn.jobstop, state.job_id)
    end
    if opts.on_cancel then opts.on_cancel() end
  end

  function task:is_alive()
    return state.alive
  end

  local function cleanup()
    state.alive = false
    if state.timer then
      state.timer:stop()
      state.timer = nil
    end
  end

  local function on_timeout()
    if not state.alive or state.cancelled then return end
    state.cancelled = true
    if state.job_id then
      pcall(vim.fn.jobstop, state.job_id)
    end
    cleanup()
    if opts.on_error then opts.on_error("Timeout after " .. timeout .. "ms") end
  end

  state.timer = vim.defer_fn(on_timeout, timeout)

  local job_id = cli.run_async(args, {
    on_stdout = function(data)
      if state.cancelled then return end
      if opts.on_data then opts.on_data(data) end
    end,
    on_stderr = function(data)
      if state.cancelled then return end
      if opts.on_stderr then opts.on_stderr(data) end
    end,
    on_exit = function(code)
      if state.cancelled then return end
      -- cli.run_async synthesizes a synchronous on_exit(-1) when the binary is
      -- missing, before any job exists (state.job_id is only set after a
      -- successful start). Swallow that one: the failed-start branch below
      -- reports the failure, and a caller must not get on_exit(-1) *and*
      -- on_error for the same run — the introspect caller journaled twice and
      -- notified twice off exactly this pair.
      if state.job_id == nil then return end
      cleanup()
      if opts.on_exit then opts.on_exit(code) end
    end,
  })

  if not job_id or job_id <= 0 then
    cleanup()
    if opts.on_error then opts.on_error("Failed to start job") end
    return nil
  end

  state.job_id = job_id
  state.alive = true
  return task
end

return M