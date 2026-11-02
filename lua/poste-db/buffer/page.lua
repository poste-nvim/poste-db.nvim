--- Dataset pagination --- page navigation, refresh, and winbar updates.
local D = require("poste-db.dataset")
local C = require("poste-db.constants")
local sql_state = require("poste-db.state")

local M = {}

--- Render the row window the tab's view and paging state put on screen,
--- without touching any buffer. One place decides that window for every
--- caller that redraws from tab state — `refresh_page` here and the editor's
--- post-insert/delete redraw (`editor/nav.rerender_dataset_page`): the view
--- (`view_indices`, when filtered or sorted) picks the row order and count,
--- paging picks the slice, and `apply_page_bounds` keeps `page`/`num_pages`
--- honest after the row set changed. The editor used to carry its own copy
--- that read `layout.rows` directly, so `o`/`dd` on a sorted or filtered
--- dataset snapped the screen back to table order and never moved
--- `num_pages`.
--- @param tab table active tab (needs .layout; view/paging fields optional)
--- @return string[] lines
--- @return table meta meta of the rendered page
--- @return boolean paginated true when a page (not the whole view) was drawn
function M.render_current_view(tab)
  local fmt = require("poste-db.format")
  local total_rows
  if tab.view_indices then
    total_rows = #tab.view_indices
  else
    total_rows = tab.layout.total_rows or #tab.layout.rows
  end

  local pages = D.apply_page_bounds(tab, total_rows)
  local paginated = (tab.pagination_enabled and pages > 1) and true or false
  local page, page_size, page_rows
  if paginated then
    page, page_size = tab.page, tab.page_size
    page_rows = math.min(page_size, total_rows - (page - 1) * page_size)
  else
    -- Either paging is off or the whole view fits on one page: the renderer
    -- emits every row from the top, which is also the page the cursor
    -- arithmetic assumes.
    page, page_size = 1, total_rows
    page_rows = total_rows
  end
  -- Recorded here, with the decision, rather than read back from the meta:
  -- the count is what the paging arithmetic promised, independent of what a
  -- (possibly stubbed) renderer put in `meta.row_count`.
  tab.visible_rows = page_rows

  local lines, meta
  if tab.view_indices then
    lines, meta = fmt.render_view(tab.layout, tab.view_indices, page, page_size,
      { row_number_mode = tab.row_number_mode or "source" })
  else
    lines, meta = fmt.render_page(tab.layout, page, page_size)
  end
  meta.table_name = tab.meta and tab.meta.table_name
  return lines, meta, paginated
end

--- Refresh buffer content from the tab's layout.
--- @return table|nil meta the rendered page's meta (nil when there is nothing
---   to render: no dataset window, or a tab without a layout)
function M.refresh_page()
  local tab = D.T()
  if not tab or not D.dataset_window then return nil end
  -- Resultset tabs are always layout-aware now (render_dataset guarantees
  -- tab.layout); nothing to refresh for error/affected/raw pages.
  if not tab.layout then return nil end

  local lines, meta, paginated = M.render_current_view(tab)
  require("poste-db.buffer").apply_rendered_page(tab, lines, meta)

  if paginated then
    local page_rows = tab.visible_rows
    if sql_state.cell.row > page_rows then
      sql_state.cell.row = page_rows
    end
    if tab.cursor.row > page_rows then
      tab.cursor.row = page_rows
    end
  end

  -- Re-create header float if it was closed (e.g. after raw mode toggle)
  if tab.header_text and not sql_state._hide_header_float then
    require("poste-db.buffer.header").update()
  end
  return meta
end

local function is_dirty()
  local tab = D.T()
  return tab and tab.edit_state and tab.edit_state.dirty
end

local function block_if_dirty()
  if is_dirty() then
    vim.notify(C.EDIT_CONFLICT_MSG, vim.log.levels.WARN, { title = C.TITLE })
    return true
  end
  return false
end

function M.prev_page()
  if block_if_dirty() then return end
  local tab = D.T()
  if not tab or not tab.pagination_enabled or tab.num_pages <= 1 then return end
  if not tab.layout then return end
  tab.page = tab.page - 1
  if tab.page < 1 then tab.page = tab.num_pages end
  M.refresh_page()
end

function M.next_page()
  if block_if_dirty() then return end
  local tab = D.T()
  if not tab or not tab.pagination_enabled or tab.num_pages <= 1 then return end
  if not tab.layout then return end
  tab.page = tab.page + 1
  if tab.page > tab.num_pages then tab.page = 1 end
  M.refresh_page()
end

function M.goto_first_page()
  if block_if_dirty() then return end
  local tab = D.T()
  if not tab or not tab.pagination_enabled or tab.num_pages <= 1 then return end
  if not tab.layout then return end
  tab.page = 1
  M.refresh_page()
end

function M.goto_last_page()
  if block_if_dirty() then return end
  local tab = D.T()
  if not tab or not tab.pagination_enabled or tab.num_pages <= 1 then return end
  if not tab.layout then return end
  tab.page = tab.num_pages
  M.refresh_page()
end

function M.toggle_pagination()
  local tab = D.T()
  if not tab then return end
  -- Same dirty-edit block every other pagination entry point applies:
  -- re-rendering from the unedited layout can move the row being edited
  -- off-page (the edit highlights simply skip it, silently).
  if block_if_dirty() then return end
  tab.pagination_enabled = not tab.pagination_enabled
  M.refresh_page()
  local status = tab.pagination_enabled and ("Page " .. tab.page .. "/" .. tab.num_pages) or "All"
  vim.notify(string.format("Pagination: %s", status),
    vim.log.levels.INFO, { title = C.TITLE })
end

return M
