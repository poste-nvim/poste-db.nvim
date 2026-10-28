--- Dataset render --- normalize and lay out result rows for display.
local D = require("poste-db.dataset")
local sql_highlights = require("poste-db.highlights")

local M = {}

local function split_render_lines(lines)
  local clean = {}
  for i, line in ipairs(lines) do
    if type(line) ~= "string" then line = tostring(line or "") end
    for seg in (line .. "\n"):gmatch("(.-)\n") do
      clean[#clean + 1] = seg
    end
  end
  return clean
end

function M.normalize_rendered_page(tab, lines, meta)
  local clean = split_render_lines(lines)
  local has_header = meta and meta.type == "resultset" and meta.header_line
  if not has_header then
    local padded = {}
    for _, line in ipairs(clean) do
      if line == "" then
        padded[#padded + 1] = ""
      else
        padded[#padded + 1] = D.PADDING_SPACES .. line
      end
    end
    return padded, meta, false
  end

  local header_line = clean[meta.header_line]
  if header_line then
    tab.header_text = header_line
    if tab.sort then
      local range = sql_highlights.find_cell_range(tab.header_text, tab.sort.col + 1)
      if range then
        local text_end = range.ext_end
        while text_end > range.ext_start + 1 do
          if tab.header_text:byte(text_end) ~= 0x20 then break end
          text_end = text_end - 1
        end
        if text_end > range.ext_start then
          -- `text_end` is the last byte of the column name; the run up to
          -- `ext_end` is the cell's padding. The arrow replaces that padding,
          -- so the cell keeps its width and the separators to its right stay
          -- aligned. The wide form needs two cells of it: a column whose name
          -- fills the width (the widest value in the column being shorter)
          -- keeps only the one space before `│`, and cutting a fixed two bytes
          -- there would drop the separator's first byte instead.
          local pad_cells = range.ext_end - text_end
          local indicator, consumed
          if pad_cells >= 2 then
            indicator, consumed = (tab.sort.ascending and " ↑" or " ↓"), 2
          elseif pad_cells == 1 then
            indicator, consumed = (tab.sort.ascending and "↑" or "↓"), 1
          end
          if indicator then
            tab.header_text = tab.header_text:sub(1, text_end) .. indicator
              .. tab.header_text:sub(text_end + consumed + 1)
          end
        end
      end
    end
    local padded_h = D.PADDING_SPACES .. tab.header_text
    tab.header_index = require("poste-db.buffer.header").build_header_index(padded_h)

    table.remove(clean, meta.header_line + 1)
    table.remove(clean, meta.header_line)
    -- The shift must equal the number of lines actually removed: both
    -- renderers emit a top border today (header_line == 2, three lines go),
    -- but the guard implies header_line == 1 was considered reachable — with
    -- it, only two lines go and a flat -3 walked the indexes over the bottom
    -- border, so its removal below deleted the last data row instead.
    local removed = 3
    if meta.header_line > 1 then
      table.remove(clean, meta.header_line - 1)
    else
      removed = 2
    end
    meta.header_line = nil
    meta.data_start_line = meta.data_start_line - removed
    meta.data_end_line = meta.data_end_line - removed
    table.remove(clean, meta.data_end_line + 1)
  end

  local padded = {}
  for _, line in ipairs(clean) do
    if line == "" then
      padded[#padded + 1] = ""
    else
      padded[#padded + 1] = D.PADDING_SPACES .. line
    end
  end
  table.insert(padded, 1, "")
  meta.data_start_line = meta.data_start_line + 1
  meta.data_end_line = meta.data_end_line + 1
  return padded, meta, true
end

--- Build per-row column byte/display maps for cursor placement. Header
--- positions are not mapped here: the header float slices the rendered
--- header text per-char, which stays byte-vs-display correct for multibyte
--- names and sort indicators.
function M.build_column_start_maps(tab, meta)
  tab.buffer_col_starts = {}
  if meta and meta.col_starts then
    for i, starts in ipairs(meta.col_starts) do
      local line_idx = meta.data_start_line + i - 1
      local padded_starts = {}
      local cum = D.LEFT_PADDING + 2
      for col_idx, cell in ipairs(starts) do
        local w = meta.col_widths and meta.col_widths[col_idx] or 0
        local disp_start = cum
        local disp_end = disp_start + w + 1
        padded_starts[col_idx] = {
          ext_start = cell.ext_start + D.LEFT_PADDING,
          ext_end = cell.ext_end + D.LEFT_PADDING,
          disp_start = disp_start,
          disp_end = disp_end,
        }
        cum = disp_end + 2
      end
      tab.buffer_col_starts[line_idx] = padded_starts
    end
  end

end

return M
