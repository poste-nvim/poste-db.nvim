--- SQL plugin configuration — owns all `sql_*` defaults, keymaps, and
--- SQL-only options. Generic shared infra (binary, env, split, log) stays in
--- `poste.state`; anything SQL-specific belongs here.

local M = {}

--- SQL-only defaults. Merged with user opts in M.merge().
M.defaults = {
  sql_formatters = { "sqlfluff", "sqlfmt", "sql-formatter", "pg_format" },
  hide_empty_result_tabs = true,
  default_max_rows = 0,
  -- Server-side row cap for the persistent `poste session` transport.
  -- 0 (default) = unlimited, so `SET @a` / temp-table flows and client-side
  -- paging behave exactly like exec-file; raise it when a stray
  -- `SELECT *` on a huge table should be cut off at the server instead of
  -- streamed into Neovim. Applies when a session starts (see
  -- :PosteDbSessionStop to recycle running sessions).
  session_max_rows = 0,
  export_path = nil,
  import_chunk_size = 100,
  -- Enable debug commands (:PosteDbCmpDebug, :PosteDbDiag, ...). Off by
  -- default; turn on via setup({ debug = true }) or g:poste_db_debug = true.
  debug = false,
  -- Confirm before executing DELETE/UPDATE statements that lack a WHERE clause
  confirm_unfiltered_dml = true,
  -- Width oracle for dataset/table cell padding. Neovim folds Indic spacing
  -- marks (Devanagari ि ा ी ...) to 0 while wcwidth terminals advance them a
  -- full cell, and nvim paints a line two ways (linear fresh draws follow the
  -- terminal; partial repaints follow nvim's grid) — no padding satisfies
  -- both. "nvim" (default) keeps the cursor, cell navigation and repaints
  -- aligned; "terminal" keeps freshly drawn rows aligned instead.
  -- See LEARNINGS.md #16.
  width_mode = "nvim",
  -- How the statement under the cursor is marked: "background" tints a
  -- full-width rectangle behind its lines, "gutter" tints only the number
  -- column of those lines and leaves the text (and its parser colours) alone.
  boundary_style = "background",
  db_browser = {
    split_position = "left",  -- "left" or "right"
    split_width = 40,
  },
  keymaps = {
    sql_source = {
      run = "<CR>",
      show_ddl = "K",
      explain = "<leader>ep",
      format = "<leader>ff",
      clear_filter = "<leader>cr",
      toggle_db_browser = "<leader>db",
      trigger_completion = "<C-Space>",
      ask_ai = "<leader>aa",
      toggle_log = "<leader>l",
      help = "g?",
      -- was a call-site-only default in buffer_setup.lua (invisible to help)
      goto_definition = "gd",
    },
    sql_dataset = {
      close = "q",
      ask_ai = "a",
      move_left = "h",
      move_down = "j",
      move_up = "k",
      move_right = "l",
      prev_page = "H",
      next_page = "L",
      first_col = "0",
      last_col = "$",
      first_row = "gg",
      last_row = "G",
      preview_cell = "K",
      yank_cell = "yy",
      yank_column = "yc",
      sort_column = "s",
      toggle_raw_mode = "<leader>gp",
      next_tab = "<Tab>",
      prev_tab = "<S-Tab>",
      rerun = "R",
      goto_first_page = "<leader>hh",
      goto_last_page = "<leader>ll",
      toggle_pagination = "<leader>pa",
      find_column = "<leader>fc",
      filter_by_cell = "<leader>ce",
      show_search = "<leader>/",
      clear_filter_search = "<leader>cr",
      next_search = "n",
      prev_search = "N",
      edit_cell = "i",
      edit_cell_replace = "cc",
      delete_row = "dd",
      insert_row = "o",
      commit_edits = "<leader>w",
      show_sql = "gs",
      export = "E",
      history_toggle = "<leader>ph",
      history_next = "<leader>n",
      history_prev = "<leader>p",
      help = "g?",
    },
    -- Action names match what the keys DO (they bind from the db-browser
    -- buffer via table_ops.register_keymaps). The old names — select_all,
    -- refresh_all, describe_all, toggle_menu — described browser actions the
    -- keys never performed, and :PosteDbHelp showed those lies; a user who
    -- disabled `select_all` silently lost add-column instead. The old names
    -- are still honored when a config carries them (table_ops reads legacy
    -- first), they just no longer appear here.
    sql_table_ops = {
      add_column = "ma",
      rename_column = "mr",
      drop_column = "md",
      alter_type = "mt",
    },
    sql_db_browser = {
      toggle_node = "<CR>",
      move_left = "h",
      move_right = "l",
      context_menu = "x",
      refresh_node = "r",
      search_filter = "/",
      close = "q",
      search_next = "n",
      search_prev = "N",
      help = "g?",
      table_info = "i",
      ask_ai = "a",
      -- These used to live only as get_keymap call-site defaults: bound and
      -- rebindable, but invisible to :PosteDbHelp (help walks THIS table) and
      -- absent from the README's keymap table.
      yank_node = "y",
      copy_tables = "p",
      multi_select_toggle = "<Tab>",
      multi_select_drop = "D",
      multi_select_exit = "<Esc>",
      goto_definition = "gd",
    },
    sql_introspect = {
      close = "q",
      close_alt = "<Esc>",
    },
  },
}

--- Effective config (defaults + merged user opts).
M.config = vim.deepcopy(M.defaults)

--- Merge user opts into the effective config (deep for nested tables).
--- Called from poste-db.setup().
--- List-valued options (sql_formatters) replace wholesale: tbl_deep_extend
--- merges arrays by index, so `setup({ sql_formatters = { "pg_format" } })`
--- kept the three excluded formatters as fallbacks and duplicated the new
--- entry at position 4 — a shorter list could never shrink the default. An
--- empty table still merges (a no-op for lists; the "no keymap overrides"
--- reading for maps).
--- @param opts table|nil
function M.merge(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    if type(v) == "table" and type(M.config[k]) == "table" then
      if #v > 0 and #M.config[k] > 0 then
        M.config[k] = vim.deepcopy(v)
      else
        M.config[k] = vim.tbl_deep_extend("force", M.config[k], v)
      end
    else
      M.config[k] = v
    end
  end
end

local KEY_DISPLAY_NAMES = {
  ["<Tab>"] = "Tab",
  ["<S-Tab>"] = "S-Tab",
  ["<CR>"] = "Enter",
  ["<Esc>"] = "Esc",
  ["<Space>"] = "<Space>",
  ["<Up>"] = "Up",
  ["<Down>"] = "Down",
  ["<Left>"] = "Left",
  ["<Right>"] = "Right",
  ["<C-Space>"] = "C-Space",
  ["<BS>"] = "BS",
}

--- Resolve a keymap for (section, action). `false` disables; nil → default.
--- Keymaps are read from THIS plugin's config only — the legacy fall-through
--- to `poste.state.config.keymaps` (family shared layer) is gone since the
--- poste.nvim family dissolution.
--- @param section string
--- @param action string
--- @param default string|nil
--- @return string|nil
function M.get_keymap(section, action, default)
  local sec = M.config.keymaps[section]
  if not sec then return default end
  local key = sec[action]
  if key == nil then return default end
  if key == false then return nil end
  return key
end

--- Format a key string for display (handles <leader> and named keys).
--- @param key string
--- @return string
function M.format_key_string(key)
  if not key or key == "" then return "" end
  if KEY_DISPLAY_NAMES[key] then return KEY_DISPLAY_NAMES[key] end
  if key:sub(1, 8) == "<leader>" then
    local leader = vim.g.mapleader or "\\"
    if leader == " " then leader = "<Space>"
    elseif leader == "\t" then leader = "<Tab>"
    elseif leader == "\r" then leader = "<CR>"
    end
    leader = KEY_DISPLAY_NAMES[leader] or leader
    return leader .. key:sub(9)
  end
  return key
end

M._test = {
  get_keymap = M.get_keymap,
  format_key_string = M.format_key_string,
  merge = M.merge,
}

return M