local config = require("poste-db.config")
local statement = require("poste-db.statement")
local sql_introspect = require("poste-db.introspect")
local sql_runner = require("poste-db.sql_runner")

local M = {}
M.ensure_sql_keymaps = sql_runner.ensure_sql_keymaps

M.run_sql_request = sql_runner.run_sql_request
M.show_table_ddl = sql_introspect.show_table_ddl
M._test = statement._test

function M.setup(opts)
  opts = opts or {}
  config.merge(opts)

  -- Registered here, not at load: the keymap has to read the *merged* config,
  -- so `keymaps.sql_source.clear_filter = false` is honoured.
  local ck = config.get_keymap("sql_source", "clear_filter", "<leader>cr")
  if ck then
    vim.keymap.set("n", ck, function()
      local sql_buf = require("poste-db.buffer")
      if sql_buf.is_open() then sql_buf.clear_filter_search() end
    end, { noremap = true, silent = true, desc = "Poste: clear filter/search" })
  end

  -- Shared poste binary (vendored installer, family dissolution): make sure
  -- it is available once per session. vim.g.poste_binary keeps its
  -- first-class override role (a dev/worktree build never triggers a
  -- release download).
  if not vim.g.poste_db_setup_done then
    vim.g.poste_db_setup_done = true
    -- Deferred past the rest of startup: the candidate walk itself is a few
    -- file stats, but a miss ends in a release download, and nothing on the
    -- startup path needs that binary. download() runs the fetch off the main
    -- loop; this only postpones the lookup so first paint is never delayed.
    vim.schedule(function()
      require("poste-db.install").ensure()
    end)
  end

  require("poste-db.snippets").setup(opts)
  require("poste-db.insert_hint").setup()

  local sql_state = require("poste-db.state")
  if vim.tbl_isempty(sql_state.icons) then
    sql_state.icons = vim.tbl_deep_extend("force", {}, { Text = "", Field = "󰇨", Variable = "󰆧", Class = "", Interface = "󰏘", Function = "󰊕", Keyword = "󰌆", TypeParameter = "󰜢" })
  end
  if opts.icons then sql_state.icons = vim.tbl_deep_extend("force", sql_state.icons, opts.icons) end
  if opts.history_max ~= nil then
    require("poste-db.dataset").set_max_history(opts.history_max)
  end
  if opts.page_size ~= nil then
    require("poste-db.dataset").set_page_size(opts.page_size)
  end

  if not pcall(vim.treesitter.language.get_lang, "sql") then
    -- :TSInstall only exists under nvim-treesitter; name it, or a user
    -- without the plugin hits E492 on the advice. The fallback splitter
    -- (binary, then Lua ;-scan) keeps execution working, so this is a
    -- quality note, not a failure.
    vim.notify("poste-db: Tree-sitter SQL parser not found (install nvim-treesitter, then :TSInstall sql). Falling back to the binary/Lua statement splitter; execution works without it.", vim.log.levels.WARN, { title = "PosteDb" })
  end

  local ok = pcall(require("poste-db.completion.register").register)
  if not ok then
    local group = vim.api.nvim_create_augroup("PosteDbCmpRegister", { clear = true })
    vim.api.nvim_create_autocmd("InsertEnter", { group = group, once = true, callback = function()
      pcall(require("poste-db.completion.register").register)
      pcall(vim.api.nvim_del_augroup_by_name, "PosteDbCmpRegister")
    end })
  end

  require("poste-db.highlights").setup()
  require("poste-db.statement_indicator").setup()
  -- Grouped (clear = true) so a second setup() replaces rather than stacks:
  -- ungrouped, every re-setup added another ColorScheme handler.
  local hl_group = vim.api.nvim_create_augroup("PosteDbHighlight", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = hl_group, callback = function()
    require("poste-db.highlights").setup()
    require("poste-db.statement_indicator").setup()
  end })
  require("poste-db.autocmds").setup()
  require("poste-db.commands").setup()
  require("poste-db.tunnel").setup()
  -- Optional AI chat integration (poste-ai.nvim). Silent when absent; the
  -- registration is retried on :PosteDbChat in case poste-ai loads later.
  pcall(function() require("poste-db.ai").register() end)
  -- Statusline integration on by default (opt-out)
  -- always-on behavior so the SQL-file/dataset context stays visible.
  if opts.statusline ~= false then require("poste-db.statusline").setup() end
  require("poste-db.autocmds").setup_existing_buffers()
end

return M
