local config = require("poste-db.config")
local buffer_setup = require("poste-db.buffer_setup")

local M = {}

local function setup_db_browser_keymap(buf)
  local k = config.get_keymap("sql_source", "toggle_db_browser", "<leader>db")
  if k then
    vim.keymap.set("n", k, function() require("poste-db.db_browser").toggle() end,
      { buffer = buf, noremap = true, silent = true, desc = "Toggle DB Browser" })
  end
end

function M.setup()
  local sql_runner = require("poste-db.sql_runner")
  local sql_syntax = require("poste-db.syntax")

  -- One group for the whole pass, cleared on re-setup: ungrouped, every
  -- setup() call stacked another copy of each handler below.
  local group = vim.api.nvim_create_augroup("PosteDbAutocmds", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "poste_sql", "poste_sqlite" },
    callback = function(args)
      pcall(vim.treesitter.language.register, "sql", "poste_sql")
      pcall(vim.treesitter.language.register, "sql", "poste_sqlite")
      buffer_setup.setup_buffer_keymaps(args.buf)
      sql_runner.ensure_sql_keymaps(args.buf)
      setup_db_browser_keymap(args.buf)
      -- Buffer-local: a top-level BufUnload with pattern "poste_sql" matched
      -- against the *file name* (never literally "poste_sql"), so the
      -- connection cleanup silently never ran.
      vim.api.nvim_create_autocmd("BufUnload", {
        group = vim.api.nvim_create_augroup("PosteDbSessionConn_" .. args.buf, { clear = true }),
        buffer = args.buf,
        callback = function(b)
          pcall(require("poste-db.session_conn").cleanup_buf, b.buf)
        end,
      })
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "sql", "poste_sql", "poste_sqlite" },
    callback = function(args)
      sql_syntax.highlight_directive_comments(args.buf)
      sql_syntax.highlight_digit_prefix_fragments(args.buf)
      sql_syntax.highlight_known_error_constructs(args.buf)
      local buf_group = vim.api.nvim_create_augroup("PosteDbDirectiveHL_" .. args.buf, { clear = true })
      -- Per-buffer debounce for the two full tree-sitter sweeps: every
      -- keystroke used to re-walk the whole tree twice. Directive highlighting
      -- is the immediate feedback for the connection/database line being
      -- typed (and only walks lines until the first ###), so it stays
      -- synchronous; a dead buffer's pending timer just drops out.
      local hl_timer = nil
      vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = buf_group, buffer = args.buf,
        callback = function()
          sql_syntax.highlight_directive_comments(args.buf)
          if hl_timer then
            hl_timer:stop()
            hl_timer:close()
          end
          hl_timer = vim.defer_fn(function()
            hl_timer = nil
            if not vim.api.nvim_buf_is_valid(args.buf) then return end
            sql_syntax.highlight_digit_prefix_fragments(args.buf)
            sql_syntax.highlight_known_error_constructs(args.buf)
          end, 150)
        end,
      })
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "connections.toml",
    callback = function()
      require("poste-db.ai.mentions").invalidate()
    end,
  })

  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    group = group,
    pattern = { "*.sql", "*.sqlite" },
    callback = function()
      pcall(vim.treesitter.language.register, "sql", "poste_sql")
      pcall(vim.treesitter.language.register, "sql", "poste_sqlite")
      local name = vim.api.nvim_buf_get_name(0)
      if name:match("%.sqlite$") then
        vim.bo.filetype = "poste_sqlite"
      else
        vim.bo.filetype = "poste_sql"
      end
      local k = config.get_keymap("sql_source", "trigger_completion", "<C-Space>")
      if k then
        vim.keymap.set("i", k, function()
          pcall(function() require("poste-db.completion.adapter").show() end)
        end, { buffer = 0, noremap = true, silent = true, desc = "Trigger completion" })
      end
      local sql_keywords = { from=true, join=true, where=true, set=true, on=true, having=true, by=true, ["and"]=true, ["or"]=true, use=true }
      local trig_group = vim.api.nvim_create_augroup("PosteDbTrigger_" .. vim.api.nvim_get_current_buf(), { clear = true })
      vim.api.nvim_create_autocmd("CursorMovedI", {
        group = trig_group, buffer = 0,
        callback = function()
          local line = vim.api.nvim_get_current_line()
          local col = vim.api.nvim_win_get_cursor(0)[2]
          if col < 1 or line:sub(col, col) ~= " " then return end
          local last_word = line:sub(1, col - 1):match("(%w+)%s*$")
          if last_word and sql_keywords[last_word:lower()] then
            require("poste-db.completion.adapter").show({ force = true, trigger_kind = "manual" })
          end
        end,
      })
      vim.api.nvim_create_autocmd("InsertEnter", {
        group = trig_group, buffer = 0,
        callback = function()
          local line = vim.api.nvim_get_current_line()
          local col = vim.api.nvim_win_get_cursor(0)[2]
          local before = line:sub(1, col)
          local prefix = before:match("[%w_]*$") or ""
          if #prefix > 0 then
            vim.schedule(function()
              require("poste-db.completion.adapter").show({ force = true, trigger_kind = "manual" })
            end)
          end
        end,
      })
      vim.b.blink_cmp_min_keyword_length = 0
    end,
  })
end

function M.setup_existing_buffers()
  local sql_runner = require("poste-db.sql_runner")

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%.sqlite$") then
      vim.bo[buf].filetype = "poste_sqlite"
      buffer_setup.setup_buffer_keymaps(buf)
      sql_runner.ensure_sql_keymaps(buf)
      setup_db_browser_keymap(buf)
    elseif name:match("%.sql$") then
      vim.bo[buf].filetype = "poste_sql"
      buffer_setup.setup_buffer_keymaps(buf)
      sql_runner.ensure_sql_keymaps(buf)
      setup_db_browser_keymap(buf)
    end
  end
end

return M