--- Highlight theme --- load and register highlight groups for dataset UI.
local state = require("poste-db.state")
local util = require("poste-db.util")

local M = {}

local function resolve_hl(name)
  local hl = vim.api.nvim_get_hl(0, { name = name })
  while hl.link do
    hl = vim.api.nvim_get_hl(0, { name = hl.link })
  end
  return hl
end

local function fg_of(name, fallback)
  local hl = resolve_hl(name)
  if hl and hl.fg then return hl.fg end
  return fallback
end

local function link_if_empty(name, target)
  local existing = vim.api.nvim_get_hl(0, { name = name })
  if vim.tbl_isempty(existing) then
    vim.api.nvim_set_hl(0, name, { link = target })
  end
end

function M.setup()
  link_if_empty("PosteDbDatasetModified", "DiffChange")
  link_if_empty("PosteDbDatasetDeleted", "DiffDelete")
  link_if_empty("PosteDbDatasetAdded", "DiffAdd")
  link_if_empty("PosteDbDatasetNumber", "Number")
  link_if_empty("PosteDbDatasetBool", "Boolean")
  link_if_empty("PosteDbDatasetNull", "Comment")
  -- NB: no link for PosteDbDatasetSearchMatch here — the full definition
  -- below always overwrites it (the link used to sit here as dead setup).
  link_if_empty("PosteDbDatasetSearchCurrent", "IncSearch")
  link_if_empty("PosteDbDatasetRowNum", "LineNr")
  link_if_empty("PosteDbDatasetCellSelected", "IncSearch")
  link_if_empty("PosteDbDatasetCursorLine", "CursorLine")
  link_if_empty("PosteDbDatasetHeader", "Title")
  link_if_empty("PosteDbDatasetBorder", "FloatBorder")
  link_if_empty("PosteDbDatasetSep", "NonText")
  link_if_empty("PosteDbDatasetMeta", "Comment")
  link_if_empty("PosteDbDatasetMetaDim", "NonText")
  link_if_empty("PosteDbDatasetError", "DiagnosticError")
  link_if_empty("PosteDbDatasetTotal", "Title")
  link_if_empty("PosteDbDatasetSucceeded", "DiagnosticOk")
  link_if_empty("PosteDbDatasetFailed", "DiagnosticError")
  link_if_empty("PosteDbDatasetConstant", "Constant")
  link_if_empty("PosteDbDatasetFilepath", "Directory")
  link_if_empty("PosteDbDatasetWinbarBorder", "PosteDbDatasetBorder")
  link_if_empty("PosteDbHistorySuccess", "DiagnosticOk")
  link_if_empty("PosteDbHistoryError", "DiagnosticError")
  -- the SQL log's "!": a request that ran but delivered less than promised
  -- (partial edit commit). Distinct from DiagnosticError on purpose.
  link_if_empty("PosteDbHistoryWarning", "DiagnosticWarn")
  link_if_empty("PosteDbHistorySQL", "Comment")

  local normal = resolve_hl("Normal")
  local dark = util.is_dark_color(normal.bg)

  link_if_empty("PosteDbDatasetCellText", "String")
  vim.api.nvim_set_hl(0, "PosteDbDatasetWinbarAdded", { fg = fg_of("DiffAdd", dark and 0x4ec94e or 0x2d8a2d) })
  vim.api.nvim_set_hl(0, "PosteDbDatasetWinbarModified", { fg = fg_of("DiffChange", dark and 0xd7d700 or 0x9a7d00) })
  vim.api.nvim_set_hl(0, "PosteDbDatasetWinbarDeleted", { fg = fg_of("DiffDelete", dark and 0xf07070 or 0xc04040) })

  local winbar_hl = resolve_hl("WinBar")
  local winbar_bg = (winbar_hl and winbar_hl.bg) or normal.bg or (dark and 0x1e1e1e or 0xffffff)
  vim.api.nvim_set_hl(0, "PosteDbDatasetWinbarSep", { fg = winbar_bg, bg = winbar_bg })

  vim.api.nvim_set_hl(0, "PosteDbDatasetSortIndicator", { fg = dark and 0x56b6c2 or 0xcf222e, bold = true })
  vim.api.nvim_set_hl(0, "PosteDbDatasetFilterActive", { fg = fg_of("DiagnosticOk", dark and 0x4ade80 or 0x16a34a), bold = true })
  vim.api.nvim_set_hl(0, "PosteDbDatasetSearchActive", { fg = dark and 0xc084fc or 0x7e22ce, bold = true })
  -- the matched characters inside a searched cell (fg over the cell-wide
  -- Search tint); same purple family as the winbar's search label
  vim.api.nvim_set_hl(0, "PosteDbDatasetSearchMatch",
    { fg = dark and 0xffffff or 0x1e1e1e, bold = true, bg = dark and 0x073522 or 0x3cb4ea })
  vim.api.nvim_set_hl(0, "PosteDbDatasetSearchMatchText",
    { fg = dark and 0xc084fc or 0x7e22ce, bold = true })
  -- matched characters inside the CURRENT cell. IncSearch is a flat
  -- bg/reverse group, so the char layer needs its own fg to be visible;
  -- resolve IncSearch's fg (theme-chosen for contrast on its bg) and add
  -- bold/underline so the matched chars read as emphasized.
  vim.api.nvim_set_hl(0, "PosteDbDatasetSearchCurrentText",
    { fg = fg_of("IncSearch", dark and 0xc084fc or 0x7e22ce), bold = true, underline = true })
  vim.api.nvim_set_hl(0, "PosteDbMissingWhere",
    { fg = dark and 0xc084fc or 0x8250df, bold = true })
  vim.api.nvim_set_hl(0, "PosteDbDatasetInsertHint", { fg = dark and 0xe5c07b or 0x0550ae, bold = true, underline = true })
  vim.api.nvim_set_hl(0, "PosteDbHistorySQLKeyword", { fg = fg_of("Keyword", dark and 0xc586c0 or 0x8250df), bold = true })
  vim.api.nvim_set_hl(0, "PosteDbHistoryFilter", { fg = fg_of("DiagnosticWarn", dark and 0xd7d700 or 0x9a7d00), bold = true })

  local completion_kind_links = {
    Text = "String",
    Field = "Identifier",
    Variable = "Identifier",
    Class = "Type",
    Interface = "Type",
    Function = "Function",
    Keyword = "Keyword",
    TypeParameter = "Type",
  }
  local completion_kind_names = {
    "Text", "Field", "Variable", "Class", "Interface",
    "Function", "Keyword", "TypeParameter",
  }
  for _, name in ipairs(completion_kind_names) do
    local hl_name = "PosteDbCompletionKind" .. name
    link_if_empty(hl_name, completion_kind_links[name])
    pcall(vim.api.nvim_set_hl, 0, "BlinkCmpKind" .. name, { link = hl_name })
  end

  state.apply_highlight_overrides({
    "PosteDbDatasetModified", "PosteDbDatasetDeleted", "PosteDbDatasetAdded",
    "PosteDbDatasetCellText", "PosteDbDatasetSep", "PosteDbDatasetBorder",
    "PosteDbDatasetHeader", "PosteDbDatasetWinbarBorder", "PosteDbDatasetWinbarSep",
    "PosteDbDatasetMeta", "PosteDbDatasetMetaDim", "PosteDbDatasetNull",
    "PosteDbDatasetNumber", "PosteDbDatasetBool", "PosteDbDatasetSortIndicator",
    "PosteDbDatasetRowNum", "PosteDbDatasetCellSelected", "PosteDbDatasetCursorLine",
    "PosteDbDatasetSearchMatch", "PosteDbDatasetSearchCurrent", "PosteDbDatasetSearchMatchText", "PosteDbDatasetSearchCurrentText",
    "PosteDbDatasetInsertHint", "PosteDbDatasetError",
    "PosteDbDatasetWinbarAdded", "PosteDbDatasetWinbarModified", "PosteDbDatasetWinbarDeleted",
    "PosteDbMissingWhere",
    "PosteDbHistorySuccess", "PosteDbHistoryError", "PosteDbHistoryWarning", "PosteDbHistorySQL", "PosteDbHistorySQLKeyword", "PosteDbHistoryFilter",
    "PosteDbDatasetTotal", "PosteDbDatasetSucceeded", "PosteDbDatasetFailed", "PosteDbDatasetConstant", "PosteDbDatasetFilepath",
    "PosteDbCompletionKindText", "PosteDbCompletionKindField", "PosteDbCompletionKindVariable",
    "PosteDbCompletionKindClass", "PosteDbCompletionKindInterface",
    "PosteDbCompletionKindFunction", "PosteDbCompletionKindKeyword",
    "PosteDbCompletionKindTypeParameter",
  })
end

return M
