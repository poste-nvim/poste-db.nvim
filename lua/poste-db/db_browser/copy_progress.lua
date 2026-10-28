--- Copy/paste UI: options popup, size confirm dialog, progress spinner, and
--- the post-run error summary. Extracted from db_browser/copy.lua — pure
--- presentation over caller-injected jobs ({label, tag, work}).
local uv = vim.uv or vim.loop
local config = require("poste-db.config")
local dialog = require("poste-db.dialog")
local C = require("poste-db.constants")
local db_util = require("poste-db.db_browser.util")

require("poste-db.db_browser.theme").register({
  PosteDbCopySuccess = { fg = "#9ece6a" },
  PosteDbCopyError = { fg = "#f7768e" },
  PosteDbCopyProgress = { fg = "#565f89" },
})

local M = {}

function M.popup_options()
  local cfg = config.config.db_browser or {}
  local pos = cfg.split_position or "right"
  local width = 60
  local height = 12
  return { width = width, height = height, dir = pos }
end

local format_bytes = db_util.format_bytes

--- Look up a plan item's byte size from the sizes map (bare and, for PG,
--- "schema.name" keys).
function M.item_bytes(sizes, item)
  if not sizes or next(sizes) == nil then return nil end
  local v = sizes[item.final]
  if v == nil and item.schema then v = sizes[item.schema .. "." .. item.orig] end
  if v == nil then v = sizes[item.orig] end
  if type(v) == "number" then return v end
  return nil
end

--- Show the pre-flight confirmation with size estimate and rename mapping.
---@param source table {conn, db, dialect}
---@param target table {conn, db, dialect}
---@param plan table[] {kind, orig, final, schema, kind_tag}
---@param sizes table|nil name -> bytes map from catalog.sizes()
function M.show_paste_confirm(source, target, plan, sizes, on_confirm, on_cancel)
  local popts = M.popup_options()
  local same_dialect = source.dialect == target.dialect
  local same_server = source.conn == target.conn

  local total_bytes = 0
  local any_size = false
  for _, p in ipairs(plan) do
    if p.kind == "table" or p.kind == "view" then
      local b = M.item_bytes(sizes, p)
      if b then any_size = true; total_bytes = total_bytes + b end
    end
  end

  local status_text
  if not same_dialect then
    status_text = "MISMATCH - dialect differs"
  elseif not same_server then
    status_text = "Cross-server (SELECT+INSERT)"
  else
    status_text = "Ready"
  end

  local lines = {
    "  Source:  " .. source.conn .. "." .. tostring(source.db or "(conn)")
      .. " (" .. source.dialect .. ")",
    "  Target:  " .. target.conn .. "." .. tostring(target.db or "(conn)")
      .. " (" .. target.dialect .. ")",
    "  Status:  " .. status_text,
    "",
    "  Items:   " .. #plan .. "        Size: ~"
      .. (any_size and format_bytes(total_bytes) or "unknown"),
  }

  -- Warn before a heavy cross-server load: SELECT* loads the whole result
  -- set into memory before batching INSERTs.
  if same_dialect and not same_server and total_bytes > 100 * 1024 * 1024 then
    table.insert(lines, "           ⚠ >100 MB cross-server copy may be slow")
  end

  table.insert(lines, "")
  table.insert(lines, "  Plan:")
  local renamed = 0
  for i, p in ipairs(plan) do
    local label
    if p.kind_tag and p.kind_tag ~= "" then
      label = "    " .. p.final .. p.kind_tag
    else
      label = "    " .. p.final
    end
    if p.final ~= p.orig then
      renamed = renamed + 1
      label = "    " .. p.orig .. " → " .. p.final .. p.kind_tag
    end
    local b = M.item_bytes(sizes, p)
    if b and b > 0 then
      label = label .. string.rep(" ", math.max(1, 34 - #label)) .. "(" .. format_bytes(b) .. ")"
    end
    table.insert(lines, label)
    if i >= 8 and #plan > 8 then
      table.insert(lines, "    ... and " .. (#plan - 8) .. " more")
      break
    end
  end
  if renamed > 0 then
    table.insert(lines, "")
    table.insert(lines, "  " .. renamed .. " name conflict" .. (renamed > 1 and "s" or "") .. " resolved via dialog")
  end
  table.insert(lines, "")
  table.insert(lines, "  [y] Start  [n] Cancel")

  local height = math.min(math.max(12, #lines + 2), 26)
  -- One settle path for every way the dialog can go away: y confirms, and
  -- n / q / <Esc> / WinLeave all count as cancel — the on_cancel callback is
  -- part of this function's contract, so a bare dialog close must not
  -- silently drop it.
  local answered = false
  local dlg
  local function answer(is_cancel)
    if answered then return end
    answered = true
    if is_cancel and on_cancel then on_cancel() end
    dlg:close()  -- re-enters via on_close; the answered flag absorbs it
    if not is_cancel and on_confirm then on_confirm() end
  end

  dlg = dialog.open({
    title = "Paste",
    width = math.max(popts.width, 56),
    height = height,
    border = "rounded",
    backdrop = true,
    on_close = function() answer(true) end,
  })

  local km = { buffer = dlg.buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "y", function() answer(false) end, km)
  vim.keymap.set("n", "n", function() answer(true) end, km)

  dlg:update(lines)
end

function M.show_summary_dialog(completed, failed, errors)
  local lines = {
    "  Succeeded: " .. completed .. "  |  Failed: " .. failed,
    "",
  }
  if failed > 0 then
    -- Sorted: pairs() order reshuffles between runs, and the summary should
    -- read in a stable order (same class as the connection pickers).
    local names = {}
    for name in pairs(errors) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
      table.insert(lines, "  ✘ " .. name)
      -- tostring: the callback contract says a string, but the err argument
      -- travels through several modules before it lands here.
      local clean = tostring(errors[name] or ""):gsub("\n", " "):gsub("\r", "")
      for _, chunk in ipairs(db_util.wrap_utf8(clean, 50)) do
        table.insert(lines, "      " .. chunk)
      end
    end
  end

  local height = math.max(6, 4 + #lines)
  height = math.min(height, 24)

  local dlg = dialog.open({
    title = "Copy Complete",
    width = 60,
    height = height,
    border = "rounded",
    backdrop = false,
  })
  dlg:update(lines)
end

function M.show_paste_progress(source, target, jobs, on_close)
  local popts = M.popup_options()
  local height = math.max(14, 8 + #jobs)
  height = math.min(height, 24)

  local spinner_timer = nil
  local cancelled = false

  local function stop_spinner()
    if spinner_timer then
      spinner_timer:stop()
      pcall(spinner_timer.close, spinner_timer)
      spinner_timer = nil
    end
  end

  -- Forward-declared: the `c` keymap closes over this; the body is defined
  -- once the dialog handle exists. Unlike plain `q` (close, copy keeps
  -- running), `c` stops the queue after the in-flight job finishes.
  local cancel_copy

  local opts = {
    title = "Copying",
    width = popts.width,
    height = height,
    border = "rounded",
    backdrop = true,
    keymaps = {
      c = function() cancel_copy() end,
    },
    on_close = function()
      stop_spinner()
      if on_close then on_close() end
    end,
  }

  local dlg = dialog.open(opts)
  local results = {}
  local total = #jobs
  local completed = 0
  local failed = 0
  local errors = {}
  local spinner_frame = 1

  cancel_copy = function()
    if cancelled then return end
    cancelled = true
    dlg:close()
  end

  -- Keyed by the job's position, not its label: a postgres trigger legally
  -- shares its table's name, and two same-label jobs used to read/write one
  -- results slot (rows showed one job's status under both names). The label
  -- stays the DISPLAY text; `errors` below stays label-keyed on purpose —
  -- same-name items merging into one summary line is acceptable.
  for i in ipairs(jobs) do
    results[i] = { status = "pending", row_count = "", elapsed = "" }
  end

  local function set_spinner_frame(frame)
    spinner_frame = ((frame - 1) % #C.SPINNER_FRAMES) + 1
  end

  local function render()
    local lines = {}
    local highlights = {}
    local done = completed + failed
    local pct = total > 0 and math.floor(done / total * 100) or 0
    local bar_len = 20
    -- Same guard as pct: with no jobs at all, done/total is 0/0 and
    -- string.rep would receive NaN.
    local filled = total > 0 and math.floor(done / total * bar_len) or 0
    local bar = string.rep("█", filled) .. string.rep("░", bar_len - filled)
    table.insert(lines, "  Source: " .. source.conn .. "." .. tostring(source.db or "(conn)"))
    table.insert(lines, "  Target: " .. target.conn .. "." .. tostring(target.db or "(conn)"))
    table.insert(lines, "")
    local bar_line = "  " .. bar .. "  " .. done .. "/" .. total .. " (" .. pct .. "%)"
    table.insert(lines, bar_line)
    table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = #bar_line, hl_group = "PosteDbCopyProgress" })
    table.insert(lines, "")

    for i, j in ipairs(jobs) do
      local r = results[i]
      local shown = j.label .. (j.tag or "")
      if r.status == "done" then
        local line = "  ✓ " .. shown
        if r.row_count ~= "" then
          line = line .. "  (" .. r.row_count .. (r.elapsed ~= "" and ", " .. r.elapsed or "") .. ")"
        elseif r.elapsed ~= "" then
          line = line .. "  (" .. r.elapsed .. ")"
        end
        table.insert(lines, line)
        table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = #line, hl_group = "PosteDbCopySuccess" })
      elseif r.status == "copying" then
        local line = "  " .. C.SPINNER_FRAMES[spinner_frame] .. " " .. shown .. "  (copying...)"
        table.insert(lines, line)
        table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = #line, hl_group = "PosteDbCopyProgress" })
      elseif r.status == "error" then
        local line = "  ✘ " .. shown
        table.insert(lines, line)
        table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = #line, hl_group = "PosteDbCopyError" })
      else
        table.insert(lines, "  ◻ " .. shown .. "  (pending)")
      end
    end

    if done == total then
      table.insert(lines, "")
      local done_line = "  Done. " .. completed .. " succeeded, " .. failed .. " failed."
      table.insert(lines, done_line)
      -- Find before subtracting: a nil match here must skip the highlight,
      -- not crash on 'nil - 1' before the guard runs.
      local match = done_line:find(tostring(completed) .. " succeeded", 1, true)
      if match and completed > 0 then
        local succeeded_start = match - 1
        local succeeded_str = tostring(completed) .. " succeeded"
        table.insert(highlights, { line = #lines - 1, col_start = succeeded_start, col_end = succeeded_start + #succeeded_str, hl_group = "PosteDbCopySuccess" })
      end
      if failed > 0 then
        table.insert(lines, "  Press [q] to see errors")
      end
    else
      table.insert(lines, "")
      table.insert(lines, "  [c] cancel remaining   [q] close")
    end

    dlg:update(lines, highlights)
  end

  render()

  local function any_copying()
    local active = false
    for i in ipairs(jobs) do
      if results[i] and results[i].status == "copying" then
        active = true
        break
      end
    end
    return active
  end

  -- `idx` is the job's position in `jobs`, not its label (see results above).
  local function advance(idx, status, row_count, elapsed, err_msg)
    results[idx] = { status = status, row_count = row_count or "", elapsed = elapsed or "" }
    local label = jobs[idx] and jobs[idx].label
    if status == "done" then
      completed = completed + 1
    elseif status == "error" then
      failed = failed + 1
      errors[label] = err_msg or "Unknown error"
    end
    render()

    if not any_copying() then
      stop_spinner()
    end

    if completed + failed == total and failed > 0 then
      vim.defer_fn(function()
        M.show_summary_dialog(completed, failed, errors)
      end, 500)
    end
  end

  local function start_copy()
    local idx = 0
    local function process_next()
      if cancelled then return end
      idx = idx + 1
      if idx > total then
        stop_spinner()
        return
      end
      local j = jobs[idx]

      results[idx] = { status = "copying", row_count = "", elapsed = "" }
      if not spinner_timer then
        -- Animate the copying spinner while any item is in flight.
        spinner_timer = uv.new_timer()
        spinner_timer:start(C.SPINNER_INTERVAL_MS, C.SPINNER_INTERVAL_MS, vim.schedule_wrap(function()
          if cancelled or not dlg.buf or not vim.api.nvim_buf_is_valid(dlg.buf) then
            stop_spinner()
            return
          end
          set_spinner_frame(spinner_frame + 1)
          render()
        end))
      else
        set_spinner_frame(spinner_frame + 1)
      end
      render()

      j.work(function(ok, row_count, elapsed, err)
        if ok then
          advance(idx, "done", row_count, elapsed)
        else
          advance(idx, "error", nil, nil, err)
        end
        process_next()
      end)
    end

    process_next()
  end

  return start_copy, cancel_copy
end

return M
