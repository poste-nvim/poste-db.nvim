--- Shared dataset state extracted from buffer.lua.
--- Tabs, floats, scroll state — no poste deps, only vim.api.*.

local M = {}

M.dataset_buffer = nil
M.dataset_window = nil
M.dataset_tabpage = nil

M.LEFT_PADDING = 2
M.PADDING_SPACES = string.rep(" ", M.LEFT_PADDING)

M.tabs = {}
M.active_tab_idx = 0

-- Request history (JetBrains-style): one entry per executed request.
-- Each entry owns its own `tabs` table; the module-level `M.tabs` is a
-- pointer to the active entry's tabs (swap-on-switch keeps all existing
-- readers working unchanged).
M.history = {}           -- [n] = { label, elapsed_ms, src_buf, src_file, sql, stmt_line, error, tabs = {}, last_tab }
M.active_history = 0
M.max_history = 20
M.default_page_size = 50
M.buf_label_count = {}   -- [bufnr] = n, for fallback labels like test_1, test_2

M.scroll_autocmd_id = nil
M.resize_autocmd_id = nil
M.search_ns = vim.api.nvim_create_namespace("poste_db_search")

function M.history_count()
  return #M.history
end

function M.active_entry()
  return M.history[M.active_history]
end

--- Create a new history entry for a request and make it active.
--- `M.tabs` is swapped to point at the entry's fresh tabs table.
--- @param meta table|nil { label, src_buf, src_file, sql, stmt_line }
--- @return table entry
function M.new_entry(meta)
  meta = meta or {}
  local entry = {
    label = meta.label,
    elapsed_ms = 0,
    ts_sec = meta.ts_sec or 0,
    ts_nsec = meta.ts_nsec or 0,
    src_buf = meta.src_buf,
    src_file = meta.src_file,
    sql = meta.sql,
    stmt_line = meta.stmt_line,
    error = false,
    tabs = {},
    last_tab = 0,
  }
  -- Save the previous entry's last-active tab before swapping away
  local cur = M.active_entry()
  if cur then cur.last_tab = M.active_tab_idx end
  table.insert(M.history, entry)
  M.active_history = #M.history
  M.tabs = entry.tabs
  M.active_tab_idx = 0
  -- Evict the oldest entry (never the just-inserted active one)
  if #M.history > M.max_history then
    table.remove(M.history, 1)
    M.active_history = #M.history
  end
  return entry
end

--- Switch the active history entry; restores that entry's tabs pointer and
--- its last-active tab index.
--- @param idx number 1-based history index
--- @return table|nil entry
function M.switch_entry(idx)
  if idx < 1 or idx > #M.history then return nil end
  local cur = M.active_entry()
  if cur then cur.last_tab = M.active_tab_idx end
  M.active_history = idx
  local entry = M.history[idx]
  M.tabs = entry.tabs
  M.active_tab_idx = entry.last_tab or 0
  return entry
end

--- Delete a history entry, fixing up the active pointer afterwards.
---
--- The pointer follows the ENTRY the user was looking at, not the slot:
--- removing an entry in front of the active one shifts it down by one, and
--- only removing the active entry itself may move the pointer. The old
--- "clamp then decrement" pair ran both rules on the same index, so deleting
--- any request older than the active one while the active one was last
--- ([A,B,C] active=C, delete A) landed on B — the dataset panel switched to a
--- request the user never asked for.
--- @param idx number 1-based history index
--- @return table|nil removed entry
function M.delete_entry(idx)
  if idx < 1 or idx > #M.history then return nil end
  local removed = table.remove(M.history, idx)
  if #M.history == 0 then
    M.active_history = 0
    M.tabs = {}
    M.active_tab_idx = 0
  else
    if M.active_history > idx then
      -- the active entry sat behind the hole: it moved up one slot
      M.active_history = M.active_history - 1
    elseif M.active_history == idx then
      -- the active entry is gone: keep the slot (the entry that slid into it,
      -- or the new last one when the tail was removed)
      M.active_history = math.min(idx, #M.history)
    end
    M.active_history = math.max(1, math.min(M.active_history, #M.history))
    local entry = M.active_entry()
    M.tabs = entry.tabs
    if M.active_tab_idx > #entry.tabs then M.active_tab_idx = 0 end
  end
  return removed
end

--- Reset the active entry's tabs (used by render_dataset when a request
--- starts fresh tab allocation). Falls back to a plain empty tabs table
--- when no history entry exists (legacy callers).
function M.reset_active_entry_tabs()
  local entry = M.active_entry()
  if entry then
    entry.tabs = {}
    M.tabs = entry.tabs
  else
    M.tabs = {}
  end
  M.active_tab_idx = 0
end

--- Format milliseconds as `分:秒.毫秒` with 2-digit minutes (e.g. 00:01.234).
--- @param ms number|string|nil integer milliseconds
--- @return string
function M.format_elapsed(ms)
  ms = math.max(0, math.floor(tonumber(ms) or 0))
  local minutes = math.floor(ms / 60000)
  local seconds = math.floor((ms % 60000) / 1000)
  local millis = ms % 1000
  return string.format("%02d:%02d.%03d", minutes, seconds, millis)
end

--- Per-buffer counter for fallback labels (test_1, test_2, ...).
--- @param bufnr number
--- @return number next counter value
function M.next_label_number(bufnr)
  M.buf_label_count[bufnr] = (M.buf_label_count[bufnr] or 0) + 1
  return M.buf_label_count[bufnr]
end

--- Configure the history cap (setup opts).
function M.set_max_history(n)
  M.max_history = math.max(1, math.floor(n or 20))
end

--- Configure the default row page size for new dataset tabs (setup opts).
function M.set_page_size(n)
  M.default_page_size = math.max(1, math.floor(n or 50))
end

--- Wall-clock timestamp of an event (libuv realtime clock: { sec, nsec }).
--- Falls back to whole-second `os.time()` on older Neovim.
--- @return { sec = number, nsec = number }
function M.now_wall()
  if vim.uv and vim.uv.clock_gettime then
    local ok, ts = pcall(vim.uv.clock_gettime, "realtime")
    if ok and type(ts) == "table" and ts.sec then return ts end
  end
  return { sec = os.time(), nsec = 0 }
end

--- Format a wall timestamp as 时:分:秒.毫秒 (HH:MM:SS.mmm).
--- @param sec number seconds since epoch
--- @param nsec number nanoseconds within the second
--- @return string
function M.format_wallclock(sec, nsec)
  -- tonumber gate: os.date raises on a non-number sec, and the history
  -- render must not be killable by one malformed timestamp
  local t = os.date("*t", tonumber(sec) or os.time())
  -- os.date answers nil (not an error) for a number outside its range —
  -- 1e999, ±inf, a nanosecond field read as seconds — and indexing that nil
  -- took the whole sidebar down for one bad journal line. Fall back to now.
  if type(t) ~= "table" then t = os.date("*t", os.time()) end
  local ms = math.floor((tonumber(nsec) or 0) / 1000000)
  return string.format("%02d:%02d:%02d.%03d", t.hour, t.min, t.sec, ms)
end

function M.tab_count()
  return #M.tabs
end

function M.T()
  return M.tabs[M.active_tab_idx]
end

function M.alloc_tab(idx)
  if not M.tabs[idx] then
    M.tabs[idx] = {
      meta = nil, lines = nil, padded = nil,
      header_text = nil, header_index = nil,
      sort = nil, original_rows = nil, is_sorting = false,
      data = nil,
      cursor = { row = 1, col = 1 },
      leftcol = 0,
      page = 1, page_size = M.default_page_size, num_pages = 1,
      pagination_enabled = true, visible_rows = nil,
      filter_col = nil, filter_val = nil, filter_col_name = nil,
      filter_active = false, filtered_indices = nil,
      search_text = nil, search_matches = {}, search_idx = 0,
      search_matches_by_page = nil, search_total_matches = 0,
      layout = nil, rows_source = nil, view_indices = nil,
      row_number_mode = "source",
      edit_state = nil,
      original_sql = nil,
      src_file = nil,
      src_buf = nil,
    }
  end
  return M.tabs[idx]
end

--- Compute view_indices from filtered_indices + sort state.
--- Operates on tab state only; no poste module deps.
function M.compute_view_indices(tab)
  local src = tab.rows_source
  if not src then return end
  local indices = {}
  if tab.filtered_indices then
    for i, idx in ipairs(tab.filtered_indices) do indices[i] = idx end
  else
    for i = 1, #src do indices[i] = i end
  end
  if tab.sort then
    local col = tab.sort.col
    local ascending = tab.sort.ascending
    table.sort(indices, function(a, b)
      local va, vb = src[a][col], src[b][col]
      if va == nil or va == vim.NIL then return false end
      if vb == nil or vb == vim.NIL then return true end
      local ta, tb = type(va), type(vb)
      if ta == "number" and tb == "number" then
        if ascending then return va < vb else return va > vb end
      end
      if ta == "boolean" and tb == "boolean" then
        if ascending then return not va and vb else return va and not vb end
      end
      -- Coerce numeric-looking strings (bigints arrive as strings) so a
      -- bigint column sorts numerically instead of lexicographically.
      local na = ta == "number" and va
        or (ta == "string" and va:match("^%-?%d+%.?%d*$") and tonumber(va)) or nil
      local nb = tb == "number" and vb
        or (tb == "string" and vb:match("^%-?%d+%.?%d*$") and tonumber(vb)) or nil
      if na and nb then
        if ascending then return na < nb else return na > nb end
      end
      local sa, sb = tostring(va), tostring(vb)
      if ascending then return sa < sb else return sa > sb end
    end)
  end
  tab.view_indices = indices
end

--- Recompute how many pages `total_rows` fills and pull `tab.page` back inside
--- them. Every render path must call this: the count was otherwise only ever
--- written by the paginated branch, so a filter or sort that shrank the view
--- left a stale `num_pages` (and an out-of-range `page`) behind — the winbar
--- advertised "P:7/20" over ten visible rows and `H`/`L` climbed that phantom
--- page count without the buffer ever changing.
--- @return integer num_pages
function M.apply_page_bounds(tab, total_rows)
  -- `or 1`: alloc_tab always sets page_size, but a hand-built tab (tests,
  -- a future caller) must degrade to single-page math, not crash the render
  local pages = math.max(1, math.ceil((total_rows or 0) / (tab.page_size or 1)))
  tab.num_pages = pages
  tab.page = math.min(math.max(tab.page or 1, 1), pages)
  return pages
end

return M
