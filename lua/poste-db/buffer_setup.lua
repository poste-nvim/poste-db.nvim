--- SQL buffer keymap setup — runs for poste_sql / poste_sqlite buffers.
--- Source-buffer keymaps (nav dispatch + snippet tab-stop) live here; the
--- dataset / db_browser / introspect keymaps are registered by their modules.

local config = require("poste-db.config")
local M = {}

local function get_nav(buf)
  local ok, mod = pcall(require, "poste-db.nav")
  if ok then return mod end
  return nil
end

local function get_run_request(buf)
  local ok, mod = pcall(require, "poste-db.init")
  if ok and mod.run_sql_request then return mod.run_sql_request end
  return nil
end

function M.setup_buffer_keymaps(buf)
  local keymap_opts = { buffer = buf, noremap = true, silent = true }
  local nav = get_nav(buf)
  local run_request = get_run_request(buf)

  if run_request then
    local k = config.get_keymap("sql_source", "run", "<CR>")
    if k then
      vim.keymap.set("n", k, run_request, keymap_opts)
    end
  end

  if nav then
    -- goto_definition is the only nav surface: K and <leader>ff are bound by
    -- sql_runner.ensure_sql_keymaps (show_ddl → introspect, format →
    -- source_format), which the FileType handler also runs; the dead guards
    -- for the nonexistent nav.show_ddl / nav.format_sql /
    -- nav.trigger_completion hid that fact.
    local k = config.get_keymap("sql_source", "goto_definition", "gd")
    if k and nav.goto_definition then vim.keymap.set("n", k, nav.goto_definition, keymap_opts) end
  end

  -- Ask the AI about a visual selection (@file(l1-l2) mention into the chat)
  local ai_key = config.get_keymap("sql_source", "ask_ai", "<leader>aa")
  if ai_key then
    local ai_opts = { buffer = buf, noremap = true, silent = true, desc = "Poste: ask AI about selection" }
    vim.keymap.set("v", ai_key, function()
      require("poste-db.ai").ask_selection()
    end, ai_opts)
  end

  -- Snippet tab-stop navigation (insert mode, only intercept when snippet active)
  local ft = vim.bo[buf].filetype
  if ft == "poste_sql" or ft == "poste_sqlite" then
    local sopts = { buffer = buf, noremap = true, silent = true }
    vim.keymap.set({ "i", "s" }, "<Tab>", function()
      if vim.snippet and vim.snippet.active() then
        vim.snippet.jump(1)
      else
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, true, true), "n")
      end
    end, sopts)
    vim.keymap.set({ "i", "s" }, "<S-Tab>", function()
      if vim.snippet and vim.snippet.active() then
        vim.snippet.jump(-1)
      else
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, true, true), "n")
      end
    end, sopts)
  end

  local indicator_ns = vim.api.nvim_create_namespace("poste_indicator")
  local group = vim.api.nvim_create_augroup("PosteClearIndicators_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group, buffer = buf,
    callback = function()
      vim.api.nvim_buf_clear_namespace(buf, indicator_ns, 0, -1)
    end,
  })
end

return M