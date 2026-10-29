--- Dataset search --- find column, filter by cell, next/prev match, search highlight.
local D = require("poste-db.dataset")
local C = require("poste-db.constants")
local nav_ui = require("poste-db.buffer.nav_ui")
local sql_state = require("poste-db.state")

local sql_highlights = require("poste-db.highlights")
local sql_format = require("poste-db.format")
local float_window = require("poste-db.float_window")
local M = {}

-- Search keyword history for the prompt box (<Up>/<Down>), most-recent
-- first. In-memory only — deliberately NOT persisted across sessions.
M.search_history = {}
local MAX_SEARCH_HISTORY = 50

--- Record a submitted query (dedup, most-recent-first, capped).
local function record_search(text)
  if text == nil or text == "" then return end
  for i = #M.search_history, 1, -1 do
    if M.search_history[i] == text then table.remove(M.search_history, i) end
  end
  table.insert(M.search_history, 1, text)
  while #M.search_history > MAX_SEARCH_HISTORY do
    table.remove(M.search_history) -- drop the oldest (tail)
  end
end

--- Pure history step. hist is most-recent-first; idx is the 1-based position
--- in hist, 0 = the box currently holds free text. dir = 1 (<Up>, older),
--- dir = -1 (<Down>, newer). Returns new text + new idx; (nil, idx) means
--- "no change", and (nil, 0) means "restore the box's original text".
local function step_history(hist, idx, dir)
  if #hist == 0 then return nil, idx end
  local next_idx = idx + dir
  if next_idx < 0 or next_idx > #hist then return nil, idx end
  if next_idx == 0 then return nil, 0 end
  return hist[next_idx], next_idx
end

-- Forward declarations
local update_winbar
local jump_to_search_match

--- Display form of a cell for SEARCH matching. A JSON/JSONB cell arrives as a
--- Lua table, and `tostring` on it is a garbage pointer address — the renderer
--- (format.cell_to_string), the cell yank (nav_cell.clipboard_text) and the
--- exporter all compact-encode the table instead, so the text the user sees in
--- the cell is the JSON. Search must match what is on screen: searching for
--- text visibly inside a JSONB cell used to answer "No matches for ..." while
--- the cell itself displayed exactly that text.
local function search_text_of(val)
  if val == nil or val == vim.NIL then return "" end
  if type(val) == "table" then
    local ok, encoded = pcall(vim.json.encode, val)
    return ok and encoded or vim.inspect(val)
  end
  return tostring(val)
end

--- Canonical comparison key for FILTER equality. `==` on two separately
--- decoded tables is pointer identity, so filtering a JSONB column kept only
--- the row the filter was taken from, even when other rows held identical
--- JSON — the filter value and every visually-identical row must compare by
--- their encoded form. Scalars keep plain `==` (a number is not the text "5").
local function same_value(a, b)
  if type(a) == "table" and type(b) == "table" then
    local ea, eb = search_text_of(a), search_text_of(b)
    return ea == eb
  end
  return a == b
end

--- Recompute search matches from search_text against the current view_indices.
--- The set of matching rows is unchanged by sort/filter (only their order), so
--- matches are re-derived to keep n/N and highlights correct after a reorder.
local function compute_matches(tab, text)
  tab.search_matches = {}
  tab.search_matches_by_page = {}
  local q = text:lower()
  local all_indices = tab.view_indices
  if not all_indices then
    all_indices = {}
    for i = 1, #tab.rows_source do all_indices[i] = i end
  end
  local total_count = 0
  for view_pos, src_idx in ipairs(all_indices) do
    local row_data = tab.rows_source[src_idx]
    -- A malformed or hand-built response can carry a non-table row; the
    -- render path (format.row_cells) reads those as empty instead of
    -- raising, and a raise here would kill the whole search pass.
    if type(row_data) == "table" then
      for ci, val in ipairs(row_data) do
        local s = search_text_of(val)
        if s:lower():find(q, 1, true) then
          total_count = total_count + 1
          local page = math.ceil(view_pos / tab.page_size)
          if not tab.search_matches_by_page[page] then
            tab.search_matches_by_page[page] = {}
          end
          tab.search_matches_by_page[page][#tab.search_matches_by_page[page] + 1] = {
            row = view_pos, col = ci, global_match_idx = total_count,
          }
          tab.search_matches[#tab.search_matches + 1] = { row = view_pos, col = ci }
        end
      end
    end
  end
  tab.search_total_matches = total_count
end

--- Is the dataset currently paged, i.e. does a view position map to a screen
--- row only relative to `tab.page`? The conjunction appears in three places
--- (highlighting, jumping, filtering) and they must agree: switching pages is
--- what turns `match.row` (a view position) into a buffer row, and a caller
--- that guesses differently highlights the row above or below the match.
local function is_paginated(tab)
  return (tab.pagination_enabled and tab.num_pages and tab.num_pages > 1 and tab.layout) and true or false
end

--- Re-derive search matches after view_indices changed (sort/filter) so stale
--- view-position matches don't point at rows that are no longer results.
function M.recompute_after_view_change()
  local tab = D.T()
  if not tab or not tab.search_text then return end
  if not tab.rows_source then
    tab.search_text = nil; tab.search_matches = {}; tab.search_idx = 0
    tab.search_matches_by_page = nil; tab.search_total_matches = 0
    M.apply_search_highlights(); update_winbar()
    return
  end
  compute_matches(tab, tab.search_text)
  if #tab.search_matches > 0 then
    jump_to_search_match(1)
  else
    tab.search_idx = 0
    M.apply_search_highlights(); update_winbar()
  end
end

--- Byte span (1-based, inclusive) of `query` inside `cell_text`, case-insensitive
--- plain find; nil when it doesn't appear. The rendered text can drift from the
--- raw value a match was computed on (truncation, NULL formatting) — the caller
--- falls back to the whole-cell highlight then.
local function match_span(cell_text, query)
  if not cell_text or cell_text == "" or not query or query == "" then return nil end
  local pos = cell_text:lower():find(query:lower(), 1, true)
  if not pos then return nil end
  return pos, pos + #query - 1
end

function M.apply_search_highlights()
  if not D.dataset_buffer or not vim.api.nvim_buf_is_valid(D.dataset_buffer) then return end
  vim.api.nvim_buf_clear_namespace(D.dataset_buffer, D.search_ns, 0, -1)
  local tab = D.T()
  if not tab or not tab.search_text or not tab.search_matches or #tab.search_matches == 0 then return end
  if not tab.meta then return end

  local data_start = tab.meta.data_start_line
  local paginated = is_paginated(tab)
  local page = paginated and (tab.page or 1) or 1
  -- The per-page buckets exist so a jump can find which page to switch to;
  -- with paging off the renderer puts every row on one screen, so slicing by
  -- bucket would hide all matches past `page_size` while n/N still walked them.
  local matches
  if paginated then
    matches = tab.search_matches_by_page and tab.search_matches_by_page[page]
    if not matches then return end
  else
    matches = tab.search_matches
  end

  for mi, match in ipairs(matches) do
    local vis_row = match.row
    if paginated then vis_row = vis_row - (page - 1) * tab.page_size end
    local buf_line = data_start + vis_row - 1
    local line = vim.api.nvim_buf_get_lines(D.dataset_buffer, buf_line - 1, buf_line, false)[1]
    if line then
      local range = sql_highlights.find_cell_range(line, match.col + 1)
      if range then
        -- in the flat list the position IS the global index; the buckets carry
        -- the field instead, since they restart numbering on every page
        local current = (match.global_match_idx or mi) == tab.search_idx
        local hl = current and "PosteDbDatasetSearchCurrent" or "PosteDbDatasetSearchMatch"
        vim.api.nvim_buf_set_extmark(D.dataset_buffer, D.search_ns, buf_line - 1, range.ext_start, {
          end_row = buf_line - 1,
          end_col = range.ext_end,
          hl_group = hl,
          priority = 150,
        })
        -- fg-emphasize just the matched characters, layered over the
        -- whole-cell tint above. `cell_text` is exactly the bytes the mark
        -- above covers (ext_start..ext_end, 0-based inclusive of ext_start and
        -- exclusive of ext_end), so a 1-based span s..e inside it starts at
        -- 0-based ext_start + s - 1 and ends (exclusive) at ext_start + e.
        local s, e = match_span(line:sub(range.ext_start + 1, range.ext_end), tab.search_text)
        if s then
          vim.api.nvim_buf_set_extmark(D.dataset_buffer, D.search_ns, buf_line - 1, range.ext_start + s - 1, {
            end_row = buf_line - 1,
            end_col = range.ext_start + e,
            hl_group = current and "PosteDbDatasetSearchCurrentText" or "PosteDbDatasetSearchMatchText",
            priority = 151,
          })
        end
      end
    end
  end
end

jump_to_search_match = function(idx)
  local tab = D.T()
  if not tab or not tab.search_matches or #tab.search_matches == 0 then return end
  local match = tab.search_matches[idx]
  if not match then return end
  tab.search_idx = idx

  local paginated = is_paginated(tab)
  if paginated then
    local match_page = math.ceil(match.row / tab.page_size)
    if match_page ~= tab.page then
      tab.page = match_page
      require("poste-db.buffer.page").refresh_page()
    end
  end

  local vis_row = match.row
  if paginated then vis_row = match.row - (tab.page - 1) * tab.page_size end
  sql_state.cell.row = vis_row
  sql_state.cell.col = match.col
  local line = require("poste-db.buffer.nav").position_cursor(vis_row, match.col)
  local cs = tab.buffer_col_starts and tab.buffer_col_starts[(tab.meta.data_start_line or 1) + vis_row - 1]
  sql_highlights.highlight_cell(D.dataset_buffer, vis_row, match.col, tab.meta, line, cs)
  require("poste-db.buffer.header").update()
  M.apply_search_highlights()
  update_winbar()
end

function M.show_search()
  local tab = D.T()
  if not tab or not tab.data or not tab.meta then return end

  local buf, win = float_window.open_centered({}, {
    filetype = "poste_search",
    title = " Search Dataset ",
    title_pos = "center",
    -- The prompt box has no content lines, so open_centered's content-driven
    -- width collapses to min_width (default 10). Pin it to the same
    -- half-editor cap the width_ratio/max_width pair intended.
    width_ratio = 0.5,
    max_width = 50,
    min_width = math.min(math.floor(vim.o.columns * 0.5), 50),
    width_padding = 0,
    height_ratio = 0.4,
    min_height = 1,
    extra_height = 1,
  })
  vim.api.nvim_set_option_value("buftype", "prompt", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("complete", "", { buf = buf })

  vim.fn.prompt_setprompt(buf, "> ")
  vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = win })

  local closed = false
  local function cleanup()
    if closed then return end
    closed = true
    pcall(vim.api.nvim_win_close, win, { force = true })
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  vim.fn.prompt_setcallback(buf, function(text)
    cleanup()
    if text == nil or text == "" then
      tab.search_text = nil; tab.search_matches = {}; tab.search_idx = 0
      M.apply_search_highlights(); update_winbar()
      return
    end
    record_search(text)
    tab.rows_source = tab.rows_source or (tab.data.results and tab.data.results[1] and tab.data.results[1].rows)
    if not tab.rows_source then return end
    tab.search_text = text
    compute_matches(tab, text)
    if #tab.search_matches > 0 then
      jump_to_search_match(1)
    else
      tab.search_idx = 0
      M.apply_search_highlights(); update_winbar()
      vim.notify("No matches for '" .. text .. "'", vim.log.levels.INFO, { title = C.TITLE })
    end
  end)

  local km = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("i", "<Esc>", cleanup, km)
  vim.keymap.set("i", "<C-c>", cleanup, km)

  -- <Up>/<Down> walk the search keyword history. idx 0 = box holds free text;
  -- the box's text at the moment you first press <Up> is remembered so a
  -- full walk back down restores it (shell-history semantics).
  local hist_idx = 0
  local hist_orig = nil
  local prompt_prefix = vim.fn.prompt_getprompt(buf) or ""
  -- Prompt-buffer line 1 is "<prefix><input>". Read/write ONLY the input
  -- region: overwriting the whole line would clobber the prompt prefix and
  -- desync nvim's internal prompt state (Enter then submits the wrong text).
  local function box_text()
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    return line:sub(#prompt_prefix + 1)
  end
  local function fill_box(text)
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    vim.api.nvim_buf_set_text(buf, 0, #prompt_prefix, 0, #line, { text })
    vim.api.nvim_win_set_cursor(0, { 1, #prompt_prefix + #text })
  end
  local function navigate(dir)
    if #M.search_history == 0 then return end
    if hist_idx == 0 and dir == 1 then hist_orig = box_text() end
    local text, next_idx = step_history(M.search_history, hist_idx, dir)
    if text == nil then
      if next_idx == 0 and hist_idx > 0 then
        hist_idx = 0
        fill_box(hist_orig or "")
      end
      return
    end
    hist_idx = next_idx
    fill_box(text)
  end
  vim.keymap.set("i", "<Up>", function() navigate(1) end, km)
  vim.keymap.set("i", "<Down>", function() navigate(-1) end, km)

  vim.cmd("startinsert!")
end

function M.next_search_match()
  local tab = D.T()
  if not tab or not tab.search_matches or #tab.search_matches == 0 then return end
  local idx = (tab.search_idx % #tab.search_matches) + 1
  jump_to_search_match(idx)
end

function M.prev_search_match()
  local tab = D.T()
  if not tab or not tab.search_matches or #tab.search_matches == 0 then return end
  -- search_idx is 1-based and 0 only while nothing is selected: from 0 the
  -- wrap lands on the LAST match, not one short of it.
  local cur = tab.search_idx
  if cur < 1 then cur = #tab.search_matches + 1 end
  local idx = ((cur - 2 + #tab.search_matches) % #tab.search_matches) + 1
  jump_to_search_match(idx)
end

function M.filter_by_current_cell()
  local tab = D.T()
  if not tab or not tab.data or not tab.meta then return end
  if tab.edit_state and tab.edit_state.dirty then
    vim.notify(C.EDIT_CONFLICT_MSG, vim.log.levels.WARN, { title = C.TITLE })
    return
  end
  local res = tab.data.results and tab.data.results[1]
  if not res or not res.rows or #res.rows == 0 then return end
  -- Resultset tabs are always layout-aware now (render_dataset guarantees
  -- tab.layout); bail before mutating filter state if one somehow isn't.
  local layout = tab.layout
  if not layout then return end
  local row, col = sql_state.cell.row, sql_state.cell.col
  if is_paginated(tab) then
    row = row + (tab.page - 1) * tab.page_size
  end
  local col_name = tab.meta.columns and tab.meta.columns[col] and tab.meta.columns[col].name or tostring(col)

  tab.rows_source = tab.rows_source or res.rows
  local src_row = tab.view_indices and tab.view_indices[row] or row
  local filter_val = tab.rows_source[src_row] and tab.rows_source[src_row][col]
  if filter_val == nil or filter_val == vim.NIL then return end

  tab.filter_col = col; tab.filter_val = filter_val
  tab.filter_col_name = col_name; tab.filter_active = true
  tab.row_number_mode = "view"

  local indices = {}
  for i, r in ipairs(tab.rows_source) do
    -- Same malformed-row reading as compute_matches above: a non-table row
    -- contributes no match instead of raising mid-filter.
    if type(r) == "table" and same_value(r[col], filter_val) then
      indices[#indices + 1] = i
    end
  end
  tab.filtered_indices = indices
  D.compute_view_indices(tab)

  local page_limit = tab.pagination_enabled and tab.page_size or #tab.view_indices
  local lines, meta = sql_format.render_view(
    layout, tab.view_indices, 1, page_limit,
    { row_number_mode = "view" }
  )
  tab.page = 1
  require("poste-db.buffer").render_dataset(lines, meta, {
    data = tab.data,
    keep_tabs = true,
    tab_index = D.active_tab_idx,
    layout = layout,
    view_indices = tab.view_indices,
    row_number_mode = "view",
  })
  -- The filter replaced `view_indices`, and matches are keyed by view position,
  -- so a live search describes rows that may no longer be in the view at all.
  -- Same guard the sort path calls; without it the winbar keeps counting the
  -- pre-filter matches and n/N walks positions past the last rendered row.
  M.recompute_after_view_change()
end

function M.clear_filter_search()
  local tab = D.T()
  if not tab then return end
  local had_filter = tab.filter_active
  local had_search = tab.search_text ~= nil
  tab.filter_active = false; tab.filter_col = nil; tab.filter_val = nil; tab.filter_col_name = nil
  tab.filtered_indices = nil
  tab.search_text = nil; tab.search_matches = {}; tab.search_idx = 0
  tab.search_matches_by_page = nil; tab.search_total_matches = 0
  if D.dataset_buffer and vim.api.nvim_buf_is_valid(D.dataset_buffer) then
    vim.api.nvim_buf_clear_namespace(D.dataset_buffer, D.search_ns, 0, -1)
  end
  if had_filter or had_search then
    tab.view_indices = nil
    tab.row_number_mode = "source"
    if tab.layout then
      require("poste-db.buffer.page").refresh_page()
    else
      update_winbar()
    end
  end
  local parts = {}
  if had_filter then parts[#parts+1] = "filter" end
  if had_search then parts[#parts+1] = "search" end
  if #parts > 0 then
    vim.notify("Cleared " .. table.concat(parts, " + "), vim.log.levels.INFO, { title = C.TITLE })
  end
end

function M.find_column()
  local tab = D.T()
  if not tab or not tab.meta or tab.meta.type ~= "resultset" then return end
  if not tab.meta.columns or #tab.meta.columns == 0 then
    vim.notify("No columns to search", vim.log.levels.WARN, { title = C.TITLE })
    return
  end

  local picker = require("poste-db.select")
  local items = {}
  for i, col in ipairs(tab.meta.columns) do
    items[i] = { key = tostring(i), name = col.name or "", description = col.type or "?" }
  end

  picker.select(items, "Find column", function(choice)
    if not choice then return end
    local idx = tonumber(choice)
    if not idx then return end
    sql_state.cell.col = idx
    local row = sql_state.cell.row
    local line = require("poste-db.buffer.nav").position_cursor(row, idx)
    local cs = tab.buffer_col_starts and tab.buffer_col_starts[(tab.meta.data_start_line or 1) + row - 1]
    sql_highlights.highlight_cell(D.dataset_buffer, row, idx, tab.meta, line, cs)
    require("poste-db.buffer.header").update()
  end)
end

update_winbar = function()
  if not D.dataset_window or not vim.api.nvim_win_is_valid(D.dataset_window) then return end
  local meta = D.T() and D.T().meta
  if not meta then return end
  local text = nav_ui.build_status_winbar(meta, D.T(), #D.tabs, D.active_tab_idx)
  if D.dataset_window and vim.api.nvim_win_is_valid(D.dataset_window) then
    pcall(vim.api.nvim_set_option_value, "winbar", text or "", { win = D.dataset_window })
  end
end
-- The local `update_winbar` above is the only consumer; no export — an
-- identical export on this file used to be dead weight next to page.lua's.

M._test = {
  match_span = match_span,
  step_history = step_history,
  record_search = record_search,
  search_text_of = search_text_of,
  same_value = same_value,
  compute_matches = compute_matches,
}

return M
