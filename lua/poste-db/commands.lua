local state = require("poste-db.state")
local connections = require("poste-db.connections")
local log = require("poste-db.log")
local compat = require("poste-db.compat")
local config = require("poste-db.config")
local const = require("poste-db.constants")

local M = {}

function M.setup()
  local session_conn = require("poste-db.session_conn")

  vim.api.nvim_create_user_command("PosteDbSessionStop", function(args)
    local arg = vim.trim(args.args)
    if arg == "" or arg == "--all" then
      session_conn.stop_all()
      vim.notify("Closed all SQL sessions", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    else
      session_conn.stop(arg)
      vim.notify("Closed SQL session: " .. arg, vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    end
  end, { nargs = "*", desc = "Close SQL session(s) — :PosteDbSessionStop [--all] [connection_url]" })

  vim.api.nvim_create_user_command("PosteDbSessionList", function()
    local sessions = session_conn.list()
    local lines = { "Active SQL sessions:" }
    local count = 0
    for _, info in pairs(sessions) do
      count = count + 1
      local created = os.date("%m-%d %H:%M", info.created_at)
      local active = os.date("%m-%d %H:%M", info.last_active)
      local now = os.time()
      local idle_sec = now - info.last_active
      local status = idle_sec < 30 and "active" or "idle"
      -- one connection can hold several pooled sessions (per database)
      local display = log.redact_url(info.conn_url or "?")
      if info.database and info.database ~= "" then
        display = display .. "  db=" .. info.database
      end
      table.insert(lines, string.format(
        "  %s  created: %s  last: %s  (%s)",
        display, created, active, status
      ))
    end
    if count == 0 then table.insert(lines, "  (none)") end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
  end, { desc = "List active SQL sessions" })

  vim.api.nvim_create_user_command("PosteDbInfo", function()
    local sep = "─"
    local parts = { sep }
    local binary, source = state.find_poste_binary()
    if binary then
      parts[#parts + 1] = "poste_binary: " .. binary
      parts[#parts + 1] = "from:         " .. source
      local mtime = (vim.uv or vim.loop).fs_stat(binary)
      if mtime then
        parts[#parts + 1] = "built:       " .. os.date("%Y-%m-%d %H:%M:%S", mtime.mtime.sec)
      end
      local version = state.poste_version(binary)
      if version then
        local tag, date = version:match("poste ([^%(]+)%(([^%)]+)%)")
        if tag and date then
          parts[#parts + 1] = "version:     " .. tag
          parts[#parts + 1] = "released:    " .. date
        else
          parts[#parts + 1] = "version:     " .. version
        end
      end
    else
      parts[#parts + 1] = "poste_binary: not found"
    end
    local search_dir = connections.get_search_dir()
    local config_path = connections.find_connections_toml(search_dir)
    parts[#parts + 1] = config_path and ("connections: " .. config_path) or ("connections: not found (searched from " .. search_dir .. ")")
    local parser_dir = vim.fn.stdpath("data") .. "/site/parser"
    local ts_ok, _ = pcall(vim.treesitter.get_parser, 0, "sql")
    local ts_file = (vim.fn.filereadable(parser_dir .. "/sql.so") == 1) and "installed" or "missing"
    parts[#parts + 1] = "treesitter: " .. (ts_ok and "active" or "unavailable") .. " (" .. ts_file .. ")"
    parts[#parts + 1] = sep
    local blink_ok = pcall(require, "blink.cmp")
    if blink_ok then
      local providers = {}
      local blink_config_ok, blink_config = pcall(require, "blink.cmp.config")
      if blink_config_ok and blink_config.sources and blink_config.sources.providers then
        for id, _ in pairs(blink_config.sources.providers) do providers[#providers + 1] = id end
      end
      parts[#parts + 1] = "blink.cmp: loaded"
      parts[#parts + 1] = "  providers:  " .. (#providers > 0 and table.concat(providers, ", ") or "(none)")
      parts[#parts + 1] = "  poste_db:  " .. (vim.tbl_contains(providers, "poste_db") and "yes" or "no")
    else
      parts[#parts + 1] = "blink.cmp: not loaded"
    end
    local cmp_ok = pcall(require, "cmp")
    if cmp_ok then parts[#parts + 1] = "nvim-cmp:   loaded" end
    parts[#parts + 1] = "filetype:   " .. (vim.bo.filetype or "(none)")
    parts[#parts + 1] = sep
    vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
  end, { desc = "Show PosteDb environment info" })

  vim.api.nvim_create_user_command("PosteDbInstall", function(args)
    local version = vim.trim(args.args)
    -- The download runs in the background (install.download), so the command
    -- returns before there is an outcome; the callback is where it is named.
    -- On success the resolved path matters more than "Installed": the lookup
    -- may legitimately answer from g:poste_binary or $PATH instead of the
    -- fresh release, and the user should know which one will actually run.
    require("poste-db.install").download(version ~= "" and version or "latest", function(ok)
      if not ok then
        vim.notify("[Poste] Install failed — see the message above, or set vim.g.poste_binary",
          vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
        return
      end
      local binary = require("poste-db.state").find_poste_binary()
      vim.notify("[Poste] Ready: " .. (binary or "poste binary"), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    end)
  end, {
    nargs = "?",
    desc = "Download/install the poste binary from GitHub releases (optional: version tag, e.g. v0.4.2)",
  })

  vim.api.nvim_create_user_command("PosteDbCmpStatus", function()
    local sql_comp = require("poste-db.completion")
    local ft = vim.bo.filetype
    local buf = vim.api.nvim_get_current_buf()
    local status = { "SQL Completion Status:", "  Current filetype: " .. ft, "  Buffer: " .. buf }
    local instance = sql_comp.new()
    status[#status + 1] = "  Enabled: " .. tostring(instance:enabled())
    local adapter = require("poste-db.completion.adapter")
    status[#status + 1] = "  blink.cmp loaded: " .. tostring(adapter.is_available())
    if adapter.is_available() then
      status[#status + 1] = "  poste_db provider registered: " .. tostring(adapter.has_provider("poste_db"))
    end
    local ctx_mod = require("poste-db.context")
    local ctx = ctx_mod.resolve_context(buf)
    status[#status + 1] = "  Connection: " .. (ctx.connection or "none")
    status[#status + 1] = "  Database: " .. (ctx.database or "none")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    local line_before = line:sub(1, cursor[2])
    status[#status + 1] = "\nAt cursor position (col=" .. cursor[2] .. "):"
    status[#status + 1] = "  Before cursor: '" .. line_before .. "'"
    vim.notify(table.concat(status, "\n"), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
  end, { desc = "Check SQL completion status" })

  vim.api.nvim_create_user_command("PosteDbCmpReload", function()
    package.loaded["poste-db.completion"] = nil
    require("poste-db.completion")
    local adapter = require("poste-db.completion.adapter")
    if not adapter.is_available() then
      vim.notify("blink.cmp not loaded, cannot re-register", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
      return
    end
    adapter.register_source({ name = "poste_db", module = "poste-db.completion", label = "PosteDb",
      score_offset = 1000, min_keyword_length = 0, should_show_items = true })
    adapter.register_filetype("poste_sql", "poste_db")
    adapter.register_filetype("poste_sqlite", "poste_db")
    vim.notify("SQL completion reloaded and re-registered with blink.cmp", vim.log.levels.INFO)
  end, { desc = "Reload SQL completion provider" })

  vim.api.nvim_create_user_command("PosteDbConnection", function()
    require("poste-db.connections").show_menu()
  end, { desc = "Manage SQL connections" })

  vim.api.nvim_create_user_command("PosteDbFormat", function()
    local _, source_format = pcall(require, "poste-db.source_format")
    if source_format then source_format.format_buffer()
    else vim.notify("Poste source_format module not available", vim.log.levels.ERROR) end
  end, { desc = "Format SQL buffer/selection" })

  vim.api.nvim_create_user_command("PosteDbFormatStatus", function()
    local _, source_format = pcall(require, "poste-db.source_format")
    if source_format then source_format.status()
    else vim.notify("Poste source_format module not available", vim.log.levels.ERROR) end
  end, { desc = "Show formatter status" })

  vim.api.nvim_create_user_command("PosteDbBrowser", function()
    require("poste-db.db_browser").toggle()
  end, { desc = "Toggle database browser" })

  vim.api.nvim_create_user_command("PosteDbChat", function()
    require("poste-db.ai").open_chat()
  end, { desc = "Open the AI chat with the PosteDb context (requires poste-ai.nvim)" })

  vim.api.nvim_create_user_command("PosteDbExport", function(args)
    local parts = {}; for word in args.args:gmatch("%S+") do parts[#parts + 1] = word end
    require("poste-db.export").run(parts[1], parts[2], parts[3])
  end, { nargs = "*", complete = function(a, l) return require("poste-db.export").complete(a, l) end,
    desc = "Export dataset — :PosteDbExport [format] [destination] [path]" })

  vim.api.nvim_create_user_command("PosteDbShowSql", function()
    require("poste-db.buffer.nav_ui").show_dataset_sql()
  end, { desc = "Show the SQL of the active dataset request in a floating window" })

  vim.api.nvim_create_user_command("PosteDbExplain", function()
    require("poste-db.explain").explain()
  end, { desc = "EXPLAIN the statement under the cursor (plan in a float)" })

  vim.api.nvim_create_user_command("PosteDbTunnel", function(args)
    local tunnel = require("poste-db.tunnel")
    local name = args.args:match("%S+")
    if name == "--all" then
      local n = tunnel.stop_all()
      vim.notify(n > 0 and string.format("Stopped %d tunnel(s)", n) or "No active tunnels", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    elseif name and name ~= "" then
      vim.notify(tunnel.stop(name) and string.format("Tunnel stopped: %s", name)
        or string.format("No active tunnel: %s", name), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    else
      local list = tunnel.status_list()
      if #list == 0 then
        vim.notify("No active tunnels", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
        return
      end
      local lines = { "Active SSH tunnels:" }
      for _, t in ipairs(list) do
        lines[#lines + 1] = ("  %s — 127.0.0.1:%d → %s"):format(t.name, t.port, t.target)
      end
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    end
  end, { nargs = "?", complete = function()
    local out = { "--all" }
    for _, t in ipairs(require("poste-db.tunnel").status_list()) do
      out[#out + 1] = t.name
    end
    return out
  end, desc = "List or stop SSH tunnels (:PosteDbTunnel [name|--all])" })

  vim.api.nvim_create_user_command("PosteDbLog", function()
    require("poste-db.log_viewer").toggle()
  end, { desc = "Toggle SQL execution log viewer" })

  vim.api.nvim_create_user_command("PosteDbRunFile", function(args)
    require("poste-db.file_exec").run({ filepath = args.args, mode = "greedy" })
  end, { nargs = 1, complete = "file", desc = "Execute a SQL file" })

  -- Debug commands stay out of the way by default. Enable them explicitly via
  -- setup({ debug = true }) or g:poste_db_debug = true (the g:poste_sql_debug
  -- spelling is the deprecated alias compat.lua still honours).
  if config.config.debug or compat.opt("debug") then
    vim.api.nvim_create_user_command("PosteDbAutoTrigger", function()
      local group = vim.api.nvim_create_augroup("PosteDbAutoComplete", { clear = true })
      vim.api.nvim_create_autocmd("TextChangedI", {
        group = group, buffer = 0,
        callback = function()
          local line = vim.api.nvim_get_current_line()
          local col = vim.api.nvim_win_get_cursor(0)[2]
          if col > 0 and line:sub(col, col) == " " then
            local before = line:sub(1, col - 1)
            local last_word = before:match("(%w+)%s*$")
            if last_word then
              local lw = last_word:lower()
              if lw == "from" or lw == "join" or lw == "where" or lw == "set" or lw == "on" or lw == "having" or lw == "by" or lw == "and" or lw == "or" then
                vim.schedule(function() pcall(function() require("poste-db.completion.adapter").show() end) end)
              end
            end
          end
        end,
      })
      vim.notify("SQL auto-trigger installed for current buffer", vim.log.levels.INFO)
    end, { desc = "Install SQL auto-trigger (debug)" })

    vim.api.nvim_create_user_command("PosteDbDiag", function()
      local sql_comp = require("poste-db.completion")
      local buf = vim.api.nvim_get_current_buf()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local line = vim.api.nvim_get_current_line()
      local line_before = line:sub(1, cursor[2])
      local cursor_lnum = cursor[1]
      local blink_src = require("poste-db.completion.adapter").get_source_lib()
      local blink_config = require("poste-db.completion.adapter").get_config()
      local active_providers = blink_src and blink_src.get_enabled_provider_ids("insert")
      local per_ft = "(unavailable)"
      if blink_config.sources and blink_config.sources.per_filetype then
        per_ft = vim.inspect(blink_config.sources.per_filetype["poste_sql"])
      end
      -- The tables and aliases the completion sees come out of the Rust
      -- context, so ask for it the same way the pipeline does. Reporting them
      -- without that call is what used to make this command claim "tables: {}"
      -- even in a buffer full of FROM clauses.
      local msg = { "line_before: '" .. line_before .. "'",
        "conn_key: " .. tostring(sql_comp._test.conn_key()),
        "cursor_lnum: " .. cursor_lnum, "ft: " .. vim.bo.filetype,
        "active blink providers: " .. vim.inspect(active_providers),
        "static per_filetype[poste_sql]: " .. per_ft,
        "runtime per_filetype_provider_ids: " .. vim.inspect(blink_src and blink_src.per_filetype_provider_ids or {}) }
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, cursor_lnum, false)
      for i, l in ipairs(buf_lines) do msg[#msg + 1] = "  " .. i .. ": " .. l end
      sql_comp._test.try_rust_context_async(buf, line_before, cursor_lnum, function(rust_ctx)
        local tbls, alias_map = sql_comp._test.get_tables_and_alias(rust_ctx)
        msg[#msg + 1] = "rust ctx_type: " .. tostring(rust_ctx and rust_ctx.ctx_type)
        msg[#msg + 1] = "tables: " .. vim.inspect(tbls)
        msg[#msg + 1] = "alias_map: " .. vim.inspect(alias_map)
        sql_comp._test.get_items(buf, line_before, cursor_lnum, function(items)
          msg[#msg + 1] = "items(" .. #items .. "): " .. vim.inspect(vim.list_slice(items, 1, 3))
          vim.notify(table.concat(msg, "\n"), vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
        end)
      end)
    end, { desc = "Diagnose SQL completion (debug)" })

    vim.api.nvim_create_user_command("PosteDbDebugSpace", function()
      local line = vim.api.nvim_get_current_line()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      local before = line:sub(1, col)
      local adapter = require("poste-db.completion.adapter")
      local msg = { "PosteDbDebugSpace:", "  line_before: '" .. before .. "'", "  blink loaded: " .. tostring(adapter.is_available()),
        "  menu open: " .. tostring(adapter.is_menu_open()) }
      if adapter.is_available() then
        vim.notify(table.concat(msg, "\n") .. "\n  → calling blink.show()...", vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
        adapter.show()
      else
        vim.notify(table.concat(msg, "\n"), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
      end
    end, { desc = "Debug space completion trigger (debug)" })

    vim.api.nvim_create_user_command("PosteDbCmpTest", function()
      local sql_comp = require("poste-db.completion")
      local buf = vim.api.nvim_get_current_buf()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local line = vim.api.nvim_get_current_line()
      local line_before = line:sub(1, cursor[2])
      local cursor_line = cursor[1]
      local status = { "SQL Completion Test:", "  line_before: '" .. line_before .. "'", "  cursor_line: " .. cursor_line }
      if sql_comp._test then
        local conn = sql_comp._test.conn_key and sql_comp._test.conn_key()
        status[#status + 1] = "  Connection key: " .. tostring(conn)
      end
      if sql_comp._test and sql_comp._test.get_items then
        sql_comp._test.get_items(buf, line_before, cursor_line, function(items)
          status[#status + 1] = "\nReturned " .. #items .. " items:"
          for i, item in ipairs(items) do
            if i <= 10 then status[#status + 1] = "  " .. item.label .. " (" .. (item.documentation or "") .. ")" end
          end
          if #items > 10 then status[#status + 1] = "  ... and " .. (#items - 10) .. " more" end
          vim.notify(table.concat(status, "\n"), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
        end)
      else
        vim.notify(table.concat(status, "\n"), vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
      end
    end, { desc = "Test SQL completion at cursor (debug)" })

    vim.api.nvim_create_user_command("PosteDbCmpDebug", function()
      require("poste-db.completion.debug").toggle()
    end, { desc = "Toggle completion debug window (debug)" })
  end
end

return M