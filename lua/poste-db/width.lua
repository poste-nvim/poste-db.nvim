--- Terminal-consistent display width for dataset rendering.
---
--- Vim folds every Indic combining mark to zero width: its composing table
--- does not distinguish Mn non-spacing marks from Mc spacing marks. Terminals
--- following the wcwidth convention still give Mc marks a real cell, so
--- `strdisplaywidth("सिंधु घाटी")` reports 5 while the terminal paints 8
--- cells — a table padded to strdisplaywidth() gets its right border drawn
--- over. M.display_width() adds one cell back for each Mc mark vim folds;
--- Mn marks measure 0 in both worlds and stay untouched.
---
--- MC_FOLDED below is the exact disagreement set: every Unicode Mc codepoint
--- for which `strdisplaywidth("a" .. mark) == strdisplaywidth("a")` holds on
--- the current Neovim build (probed, not copied from the Unicode category —
--- marks vim does NOT fold already measure 1 and must not be corrected
--- again). Regenerate when Neovim's bundled Unicode tables move.
---
--- The correction cannot be "right" in every paint: nvim draws a line two
--- ways. A fresh full-line draw is written linearly and the cursor follows
--- the TERMINAL's per-mark advance (Ghostty/kitty/WezTerm advance Mc marks
--- one cell); a partial repaint after cursor/highlight moves is positioned
--- absolutely by nvim's own grid, which folds the marks to 0. Padding for
--- the terminal makes repaints drift left on those rows; padding for vim
--- makes fresh paints overhang right. `width_mode` picks the oracle:
--- "nvim" (default) or "terminal" — see |poste-db-config| and LEARNINGS #16.
local M = {}

--- Active width oracle: "nvim" or "terminal".
local function width_mode()
  local ok, cfg = pcall(require, "poste-db.config")
  if ok and cfg.config and cfg.config.width_mode then
    return cfg.config.width_mode
  end
  return "nvim"
end

local MC_FOLDED = {
  {0x0903, 0x0903}, {0x093B, 0x093B}, {0x093E, 0x0940}, {0x0949, 0x094C},
  {0x094E, 0x094F}, {0x0982, 0x0983}, {0x09BE, 0x09C0}, {0x09C7, 0x09C8},
  {0x09CB, 0x09CC}, {0x09D7, 0x09D7}, {0x0A03, 0x0A03}, {0x0A3E, 0x0A40},
  {0x0A83, 0x0A83}, {0x0ABE, 0x0AC0}, {0x0AC9, 0x0AC9}, {0x0ACB, 0x0ACC},
  {0x0B02, 0x0B03}, {0x0B3E, 0x0B3E}, {0x0B40, 0x0B40}, {0x0B47, 0x0B48},
  {0x0B4B, 0x0B4C}, {0x0B57, 0x0B57}, {0x0BBE, 0x0BBF}, {0x0BC1, 0x0BC2},
  {0x0BC6, 0x0BC8}, {0x0BCA, 0x0BCC}, {0x0BD7, 0x0BD7}, {0x0C01, 0x0C03},
  {0x0C41, 0x0C44}, {0x0C82, 0x0C83}, {0x0CBE, 0x0CBE}, {0x0CC0, 0x0CC4},
  {0x0CC7, 0x0CC8}, {0x0CCA, 0x0CCB}, {0x0CD5, 0x0CD6}, {0x0CF3, 0x0CF3},
  {0x0D02, 0x0D03}, {0x0D3E, 0x0D40}, {0x0D46, 0x0D48}, {0x0D4A, 0x0D4C},
  {0x0D57, 0x0D57}, {0x0D82, 0x0D83}, {0x0DCF, 0x0DD1}, {0x0DD8, 0x0DDF},
  {0x0DF2, 0x0DF3}, {0x0F3E, 0x0F3F}, {0x0F7F, 0x0F7F}, {0x1031, 0x1031},
  {0x103B, 0x103C}, {0x1056, 0x1057}, {0x1084, 0x1084}, {0x1715, 0x1715},
  {0x1734, 0x1734}, {0x17B6, 0x17B6}, {0x17BE, 0x17C5}, {0x17C7, 0x17C8},
  {0x1923, 0x1926}, {0x1929, 0x192B}, {0x1930, 0x1931}, {0x1933, 0x1938},
  {0x1A19, 0x1A1A}, {0x1A55, 0x1A55}, {0x1A57, 0x1A57}, {0x1A6D, 0x1A72},
  {0x1B04, 0x1B04}, {0x1B35, 0x1B35}, {0x1B3B, 0x1B3B}, {0x1B3D, 0x1B41},
  {0x1B43, 0x1B44}, {0x1B82, 0x1B82}, {0x1BA1, 0x1BA1}, {0x1BA6, 0x1BA7},
  {0x1BAA, 0x1BAA}, {0x1BE7, 0x1BE7}, {0x1BEA, 0x1BEC}, {0x1BEE, 0x1BEE},
  {0x1BF2, 0x1BF3}, {0x1C24, 0x1C2B}, {0x1C34, 0x1C35}, {0x1CE1, 0x1CE1},
  {0x1CF7, 0x1CF7}, {0x302E, 0x302F}, {0xA823, 0xA824}, {0xA827, 0xA827},
  {0xA880, 0xA881}, {0xA8B4, 0xA8C3}, {0xA952, 0xA953}, {0xA983, 0xA983},
  {0xA9B4, 0xA9B5}, {0xA9BA, 0xA9BB}, {0xA9BE, 0xA9C0}, {0xAA2F, 0xAA30},
  {0xAA33, 0xAA34}, {0xAA4D, 0xAA4D}, {0xAAEB, 0xAAEB}, {0xAAEE, 0xAAEF},
  {0xAAF5, 0xAAF5}, {0xABE3, 0xABE4}, {0xABE6, 0xABE7}, {0xABE9, 0xABEA},
  {0xABEC, 0xABEC}, {0x11000, 0x11000}, {0x11002, 0x11002}, {0x11082, 0x11082},
  {0x110B0, 0x110B2}, {0x110B7, 0x110B8}, {0x1112C, 0x1112C}, {0x11145, 0x11146},
  {0x11182, 0x11182}, {0x111B3, 0x111B5}, {0x111BF, 0x111C0}, {0x111CE, 0x111CE},
  {0x1122C, 0x1122E}, {0x11232, 0x11233}, {0x11235, 0x11235}, {0x112E0, 0x112E2},
  {0x11302, 0x11303}, {0x1133E, 0x1133F}, {0x11341, 0x11344}, {0x11347, 0x11348},
  {0x1134B, 0x1134D}, {0x11357, 0x11357}, {0x11362, 0x11363}, {0x113B8, 0x113BA},
  {0x113C2, 0x113C2}, {0x113C5, 0x113C5}, {0x113C7, 0x113CA}, {0x113CC, 0x113CD},
  {0x113CF, 0x113CF}, {0x11435, 0x11437}, {0x11440, 0x11441}, {0x11445, 0x11445},
  {0x114B0, 0x114B2}, {0x114B9, 0x114B9}, {0x114BB, 0x114BE}, {0x114C1, 0x114C1},
  {0x115AF, 0x115B1}, {0x115B8, 0x115BB}, {0x115BE, 0x115BE}, {0x11630, 0x11632},
  {0x1163B, 0x1163C}, {0x1163E, 0x1163E}, {0x116AC, 0x116AC}, {0x116AE, 0x116AF},
  {0x116B6, 0x116B6}, {0x1171E, 0x1171E}, {0x11720, 0x11721}, {0x11726, 0x11726},
  {0x1182C, 0x1182E}, {0x11838, 0x11838}, {0x11930, 0x11935}, {0x11937, 0x11938},
  {0x1193D, 0x1193D}, {0x11940, 0x11940}, {0x11942, 0x11942}, {0x119D1, 0x119D3},
  {0x119DC, 0x119DF}, {0x119E4, 0x119E4}, {0x11A39, 0x11A39}, {0x11A57, 0x11A58},
  {0x11A97, 0x11A97}, {0x11C2F, 0x11C2F}, {0x11C3E, 0x11C3E}, {0x11CA9, 0x11CA9},
  {0x11CB1, 0x11CB1}, {0x11CB4, 0x11CB4}, {0x11D8A, 0x11D8E}, {0x11D93, 0x11D94},
  {0x11D96, 0x11D96}, {0x11EF5, 0x11EF6}, {0x11F03, 0x11F03}, {0x11F34, 0x11F35},
  {0x11F3E, 0x11F3F}, {0x11F41, 0x11F41}, {0x1612A, 0x1612C}, {0x16F51, 0x16F87},
  {0x16FF0, 0x16FF1}, {0x1D165, 0x1D166}, {0x1D16D, 0x1D172},
}

--- Decode the UTF-8 codepoint starting at byte `i`; returns cp, next index.
--- Invalid lead bytes yield (nil, i+1) so truncation cannot loop.
local function decode_cp(s, i)
  local b = s:byte(i)
  if not b then return nil, i + 1 end
  if b < 0x80 then return b, i + 1 end
  local cp, len
  if b >= 0xF0 then cp, len = b % 0x08, 4
  elseif b >= 0xE0 then cp, len = b % 0x10, 3
  elseif b >= 0xC0 then cp, len = b % 0x20, 2
  else return nil, i + 1 end -- stray continuation byte
  for j = 1, len - 1 do
    local cb = s:byte(i + j)
    if not cb or cb < 0x80 or cb >= 0xC0 then return nil, i + 1 end
    cp = cp * 0x40 + cb % 0x40
  end
  return cp, i + len
end

--- Is this codepoint a mark vim folds to 0 width AND the terminal paints
--- into its own cell?
local function is_folded_mc(cp)
  if cp < 0x0903 or cp > 0x1D172 then return false end
  local lo, hi = 1, #MC_FOLDED
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local r = MC_FOLDED[mid]
    if cp < r[1] then hi = mid - 1
    elseif cp > r[2] then lo = mid + 1
    else return true end
  end
  return false
end

--- Display width under the active width_mode:
--- "terminal": strdisplaywidth() plus one cell per folded Mc mark (agrees
---   with the terminal's linear full-line paint).
--- "nvim": plain strdisplaywidth() (agrees with nvim's grid — cursor, cell
---   navigation, partial repaints).
--- A mark in the very first position already measures 1 (vim only folds it
--- when attached to a preceding base), so it is not corrected.
function M.display_width(s)
  if s == nil then return 0 end
  if type(s) ~= "string" then s = tostring(s) end
  local ascii = true
  for i = 1, #s do
    if s:byte(i) >= 0x80 then ascii = false break end
  end
  if ascii then return #s end

  local ok, w = pcall(vim.fn.strdisplaywidth, s)
  if not ok then return #s end
  if width_mode() == "nvim" then return w end
  local i, first = 1, true
  while i <= #s do
    local cp, next_i = decode_cp(s, i)
    if not first and cp and is_folded_mc(cp) then w = w + 1 end
    first = false
    i = next_i or i + 1
  end
  return w
end

--- Truncate so the active width oracle measures at most max_dw, never
--- splitting a combining mark that fits.
--- "terminal": per-codepoint cost — folded Mc = 1, other folded marks (Mn
---   etc.) = 0, everything else = its standalone strdisplaywidth. (Probed
---   per codepoint and cached — standalone width of an Mn mark is 1, which
---   would over-count and cut CJK-style too early.)
--- "nvim": per-codepoint standalone strdisplaywidth, matching what vim's
---   grid grants each character in isolation (the historic behavior).
local fold_cache = {}

local function char_cost(cp, ch)
  if is_folded_mc(cp) then return 1 end
  local cached = fold_cache[cp]
  if cached == nil then
    cached = (vim.fn.strdisplaywidth("a" .. ch) == 1)
    fold_cache[cp] = cached
  end
  if cached then return 0 end
  local ok, w = pcall(vim.fn.strdisplaywidth, ch)
  return ok and w or 1
end

function M.truncate(s, max_dw)
  if not s then return "" end
  -- Same coercion display_width applies: the two oracles are used together
  -- (measure then cut), so anything one accepts the other must accept too —
  -- a cell that arrives as a number or a decoded JSON null measured fine and
  -- then raised on `#s`.
  if type(s) ~= "string" then s = tostring(s) end
  if s == "" then return s end
  -- once per call, not once per character: this runs per rendered cell, and
  -- width_mode() is a pcall'd require + config lookups
  local mode = width_mode()
  local strdisplaywidth = vim.fn.strdisplaywidth
  local w, i = 0, 1
  while i <= #s do
    local cp, next_i = decode_cp(s, i)
    local ch = s:sub(i, (next_i or i + 1) - 1)
    local cost
    if mode == "nvim" then
      local ok, cw = pcall(strdisplaywidth, ch)
      cost = ok and cw or 1
    else
      cost = cp and char_cost(cp, ch) or 1
    end
    if w + cost > max_dw then break end
    w = w + cost
    i = next_i or i + 1
  end
  return s:sub(1, i - 1)
end

--- Truncate to `max_dw` display cells and mark the cut with a single-cell
--- ellipsis, so the result never measures more than `max_dw` (M.truncate
--- returns the surviving prefix and leaves the caller to add the marker,
--- which is how three copies of this loop drifted apart: one reserved a cell
--- for the ellipsis, one did not, and one returned "" for `max < 1`).
--- @param s string|nil
--- @param max_dw number  total budget, ellipsis included
--- @return string  "" when the budget cannot hold even the ellipsis
function M.truncate_ellipsis(s, max_dw)
  if not s then return "" end
  -- tostring here, not in display_width only: an uncut non-string would
  -- otherwise come back as the value itself (a userdata, a number) for the
  -- caller to concatenate.
  if type(s) ~= "string" then s = tostring(s) end
  if max_dw <= 1 then return max_dw <= 0 and "" or "…" end
  if M.display_width(s) <= max_dw then return s end
  return M.truncate(s, max_dw - 1) .. "…"
end

return M
