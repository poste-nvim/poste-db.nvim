--- Highlight rendering --- apply extmark highlights to dataset buffer lines.
local sql_state = require("poste-db.state")

local const = require("poste-db.constants")

local M = {}

local ns = vim.api.nvim_create_namespace("poste_db_dataset")
local ns_cell = vim.api.nvim_create_namespace("poste_db_dataset_cell")
local ns_cursorline = vim.api.nvim_create_namespace("poste_db_dataset_cursorline")
local ns_edit = vim.api.nvim_create_namespace("poste_db_dataset_edit")

local function row_nums_hidden()
  return sql_state._hide_row_numbers
end

local function find_cell_range_by_starts(col_starts, col)
  local cell = col_starts[col]
  if not cell then return nil end
  return { ext_start = cell.ext_start, ext_end = cell.ext_end, cursor_col = cell.ext_start }
end

--- The one `│`-seam scanner behind both single-cell and multi-cell lookups.
--- find_cell_range_scan and find_cell_ranges_fallback used to be two copies
--- of it that had to stay byte-identical or the two entry points disagreed.
local function scan_seps(line)
  if not line or line == "" then return nil end
  local sep = "│"
  local sep_len = #sep
  local seps = {}
  local pos = 1
  while true do
    pos = line:find(sep, pos, true)
    if not pos then break end
    seps[#seps + 1] = pos
    pos = pos + sep_len
  end
  return seps
end

local function range_at(seps, col)
  return { ext_start = seps[col] + 2, ext_end = seps[col + 1] - 1, cursor_col = seps[col] + 2 }
end

local function find_cell_range_scan(line, col)
  local seps = scan_seps(line)
  if not seps or col > #seps - 1 then return nil end
  return range_at(seps, col)
end

function M.find_cell_range(line, col, col_starts)
  if col_starts then
    local r = find_cell_range_by_starts(col_starts, col)
    if r then return r end
  end
  return find_cell_range_scan(line, col)
end

function M.find_cell_ranges(line, target_col, last_col, col_starts)
  if col_starts then
    local target = find_cell_range_by_starts(col_starts, target_col)
    if not target then return nil end
    local result = { target = target }
    if last_col then
      local last = find_cell_range_by_starts(col_starts, last_col)
      if last then result.last = last end
    end
    return result
  end
  return M.find_cell_ranges_fallback(line, target_col, last_col)
end

function M.find_cell_ranges_fallback(line, target_col, last_col)
  local seps = scan_seps(line)
  if not seps or target_col > #seps - 1 then return nil end
  local result = { target = range_at(seps, target_col) }
  if last_col and last_col <= #seps - 1 then
    result.last = range_at(seps, last_col)
  end
  return result
end

function M.apply_dataset_highlights(buf, lines, meta)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  if not meta or meta.type ~= "resultset" then
    if meta and meta.type == "error" then
      for i, line in ipairs(lines) do
        -- format_error renders the header as "  ✗ SQL Error" and per-statement
        -- failures as "  ERROR: …"; the pattern used to match only the latter,
        -- so the common failed-query page got no red tint at all.
        if line:match("^%s*ERROR") or line:match("^%s*✗") then
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
            end_row = i - 1,
            end_col = #line,
            hl_group = "PosteDbDatasetError",
          })
        end
      end
      return
    end
    for i, line in ipairs(lines) do
      if line:match("^%s*%d+ row") or line:match("^%s*Page") or line:match("^%s*Context") then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
          end_row = i - 1,
          end_col = #line,
          hl_group = "PosteDbDatasetMeta",
        })
      end
      local ok_start, ok_end = line:find("OK")
      if ok_start and ok_end then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, ok_start - 1, {
          end_row = i - 1,
          end_col = ok_end,
          hl_group = "PosteDbDatasetSucceeded",
        })
      end
      local ms_start, ms_end = line:find("%d+ms")
      if ms_start and ms_end then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, ms_start - 1, {
          end_row = i - 1,
          end_col = ms_end,
          hl_group = "PosteDbDatasetConstant",
        })
      end
    end
    return
  end

  if meta.header_line then
    local hline = lines[meta.header_line] or ""
    vim.api.nvim_buf_set_extmark(buf, ns, meta.header_line - 1, 0, {
      end_row = meta.header_line - 1,
      end_col = #hline,
      hl_group = "PosteDbDatasetHeader",
    })
  end

  for i, line in ipairs(lines) do
    if line:sub(1, 3) == "┌" or line:sub(1, 3) == "├" or line:sub(1, 3) == "└" then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        end_row = i - 1,
        end_col = #line,
        hl_group = "PosteDbDatasetBorder",
      })
    end
  end

  if meta.data_start_line and meta.data_end_line then
    local row_count = meta.data_end_line - meta.data_start_line + 1
    local defer_row_nums = row_count > const.HIGHLIGHTS_IMMEDIATE_ROW_LIMIT

    for row_idx = meta.data_start_line, meta.data_end_line do
      local line = lines[row_idx] or ""

      if not row_nums_hidden() and not defer_row_nums then
        local row_range = M.find_cell_range(line, 1)
        if row_range and row_range.ext_start <= #line then
          vim.api.nvim_buf_set_extmark(buf, ns, row_idx - 1, row_range.ext_start, {
            end_row = row_idx - 1,
            end_col = math.min(row_range.ext_end, #line),
            hl_group = "PosteDbDatasetRowNum",
            priority = 100,
          })
        end
      end

      local col = 0
      while true do
        local start, stop = line:find("%(NULL%)", col + 1)
        if not start then break end
        vim.api.nvim_buf_set_extmark(buf, ns, row_idx - 1, start - 1, {
          end_row = row_idx - 1,
          end_col = stop,
          hl_group = "PosteDbDatasetNull",
        })
        col = stop
      end
    end

    if not row_nums_hidden() and defer_row_nums then
      local captured_lines = lines
      -- Two renders can land inside one event-loop turn (a multi-response
      -- batch): the later apply_dataset_highlights clears the namespace, and
      -- a stale scheduled pass would re-add row-number tints computed from
      -- the OLD line positions on top of the new content. The buffer's
      -- content is rewritten with nvim_buf_set_lines between passes, so a
      -- changedtick mismatch means this pass is painting a dead page.
      local captured_tick = vim.api.nvim_buf_get_changedtick(buf)
      vim.schedule(function()
        if row_nums_hidden() or not vim.api.nvim_buf_is_valid(buf) then return end
        if vim.api.nvim_buf_get_changedtick(buf) ~= captured_tick then return end
        for row_idx = meta.data_start_line, meta.data_end_line do
          local line = captured_lines[row_idx] or ""
          local row_range = M.find_cell_range(line, 1)
          if row_range and row_range.ext_start <= #line then
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, row_idx - 1, row_range.ext_start, {
              end_row = row_idx - 1,
              end_col = math.min(row_range.ext_end, #line),
              hl_group = "PosteDbDatasetRowNum",
              priority = 100,
            })
          end
        end
      end)
    end
  end
end

function M.highlight_cell(buf, row, col, meta, line, col_starts)
  vim.api.nvim_buf_clear_namespace(buf, ns_cell, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_cursorline, 0, -1)
  if not sql_state.highlight_cell then return end
  if not meta or meta.type ~= "resultset" then return end
  if not meta.data_start_line or not meta.data_end_line then return end

  local line_idx = meta.data_start_line + row - 1
  if line_idx > meta.data_end_line then return end

  if col_starts then
    local col_count = meta.col_count or 0
    for c = 1, col_count + 1 do
      if c ~= col + 1 then
        local range = col_starts[c]
        if range then
          vim.api.nvim_buf_set_extmark(buf, ns_cursorline, line_idx - 1, range.ext_start, {
            end_row = line_idx - 1,
            end_col = range.ext_end,
            hl_group = "PosteDbDatasetCursorLine",
            hl_mode = "combine",
            priority = 150,
          })
        end
      end
    end
  end

  local range
  if col_starts then
    range = find_cell_range_by_starts(col_starts, col + 1)
  else
    line = line or vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
    range = M.find_cell_range(line, col + 1)
  end
  if not range then return end
  if not col_starts and range.ext_start > #line then return end

  vim.api.nvim_buf_set_extmark(buf, ns_cell, line_idx - 1, range.ext_start, {
    end_row = line_idx - 1,
    end_col = range.ext_end,
    hl_group = "PosteDbDatasetCellSelected",
    priority = 200,
  })
end

function M.clear_cell_highlight(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns_cell, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_cursorline, 0, -1)
end

function M.apply_edit_highlights(buf, tab)
  vim.api.nvim_buf_clear_namespace(buf, ns_edit, 0, -1)
  if not tab or not tab.edit_state or not tab.edit_state.dirty then return end
  if not tab.meta or tab.meta.type ~= "resultset" then return end
  if not tab.meta.data_start_line then return end

  local es = tab.edit_state
  local meta = tab.meta
  -- edit_state rows are SOURCE rows (see editor/nav.to_source_row); a row the
  -- current page does not render has no line to mark
  local sql_format = require("poste-db.format")
  local function line_of(source_row)
    local visible = sql_format.visible_row_of(meta, source_row)
    if not visible then return nil end
    return meta.data_start_line + visible - 1
  end

  for row_idx, _ in pairs(es.deleted_rows) do
    local line_idx = line_of(row_idx)
    if line_idx and line_idx <= meta.data_end_line then
      local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
      vim.api.nvim_buf_set_extmark(buf, ns_edit, line_idx - 1, 0, {
        end_row = line_idx - 1,
        end_col = #line,
        hl_group = "PosteDbDatasetDeleted",
        hl_mode = "combine",
        priority = 300,
      })
    end
  end

  for _, added in ipairs(es.added_rows) do
    local row_idx = added.row_idx
    if row_idx then
      local line_idx = line_of(row_idx)
      if line_idx and line_idx <= meta.data_end_line then
        local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
        vim.api.nvim_buf_set_extmark(buf, ns_edit, line_idx - 1, 0, {
          end_row = line_idx - 1,
          end_col = #line,
          hl_group = "PosteDbDatasetAdded",
          hl_mode = "combine",
          priority = 300,
        })
      end
    end
  end

  for row_key, mod in pairs(es.modified_cells) do
    local row_idx = tonumber(row_key:match("^(%d+):"))
    if row_idx then
      local line_idx = line_of(row_idx)
      if line_idx and line_idx <= meta.data_end_line then
        local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
        local range = M.find_cell_range(line, mod.col + 1)
        if range then
          local ext_start = math.min(range.ext_start, #line)
          local ext_end = math.min(range.ext_end, #line)
          if ext_start < ext_end then
            vim.api.nvim_buf_set_extmark(buf, ns_edit, line_idx - 1, ext_start, {
              end_row = line_idx - 1,
              end_col = ext_end,
              hl_group = "PosteDbDatasetModified",
              hl_mode = "combine",
              priority = 250,
            })
          end
        end
      end
    end
  end

  for row_key, msg in pairs(es.cell_errors) do
    local row_idx = tonumber(row_key:match("^(%d+):"))
    local col_idx = tonumber(row_key:match(":(%d+)$"))
    if row_idx and col_idx then
      local line_idx = line_of(row_idx)
      if line_idx and line_idx <= meta.data_end_line then
        local line = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1] or ""
        local range = M.find_cell_range(line, col_idx + 1)
        if range then
          local ext_start = math.min(range.ext_start, #line)
          local ext_end = math.min(range.ext_end, #line)
          if ext_start < ext_end then
            vim.api.nvim_buf_set_extmark(buf, ns_edit, line_idx - 1, ext_start, {
              end_row = line_idx - 1,
              end_col = ext_end,
              hl_group = "PosteDbDatasetError",
              hl_mode = "combine",
              priority = 350,
            })
          end
        end
      end
    end
  end
end

function M.clear_edit_highlights(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns_edit, 0, -1)
end

return M
