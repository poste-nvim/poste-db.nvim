--- poste-db AI integration — registers a "db" context on poste-ai.nvim
--- (optional dependency). Zero coupling: poste-ai is never required at load
--- time; registration is attempted in setup() and on :PosteDbChat.

local const = require("poste-db.constants")
local M = {}

--- True when poste-ai.nvim is on the runtimepath.
function M.available()
  return (pcall(require, "poste-ai")) and true or false
end

--- Register (or refresh) the "db" context. Returns false when poste-ai is
--- not installed; callers decide whether that is worth telling the user.
--- @return boolean
function M.register()
  local ok, poste_ai = pcall(require, "poste-ai")
  if not ok then return false end
  poste_ai.register_context("db", {
    system_prompt = function(scope)
      return require("poste-db.ai.system_prompt").build(scope)
    end,
    auto_context = function(text, scope, cb)
      require("poste-db.ai.schema").auto_context(text, scope, cb)
    end,
    commands = require("poste-db.ai.commands").list(),
    mention = {
      match = function(token)
        return require("poste-db.ai.mentions").match(token)
      end,
      complete = function(prefix, cb)
        require("poste-db.ai.mentions").complete(prefix, cb)
      end,
      resolve = function(ref, cb)
        require("poste-db.ai.mentions").resolve(ref, cb)
      end,
    },
    codeblock = {
      langs = { "sql" },
      confirm = function(sql)
        return require("poste-db.ai.actions").confirm_sql(sql)
      end,
      execute = function(sql, refs, cb)
        require("poste-db.ai.actions").execute_sql(sql, refs, cb)
      end,
      append_header = function(scope, text)
        return require("poste-db.ai.actions").append_header(scope, text)
      end,
    },
  })
  return true
end

--- Notify and report absence of poste-ai. Returns true when available.
--- Load a poste-ai submodule, nil when the installed version predates it.
--- The plugin contract is silent-skip when poste-ai is absent; a bare
--- submodule require would turn every ask_* entry into a hard "module not
--- found" on an OLDER poste-ai instead.
local function ai_submodule(name)
  local ok, mod = pcall(require, name)
  return ok and mod or nil
end

local function ensure_available()
  if M.available() then return true end
  vim.notify("PosteDb AI chat needs poste-ai.nvim (poste-nvim/poste-ai.nvim) installed.",
    vim.log.levels.WARN, { title = const.PLUGIN_TITLE })
  return false
end

--- Open the AI chat with the db context active.
function M.open_chat()
  if not ensure_available() then return end
  M.register()
  local poste_ai = require("poste-ai")
  poste_ai.set_active_context("db")
  poste_ai.chat("db")
end

--- Visual-mode entry: "ask the AI about this selection". Builds a
--- "@path(l1-l2)" mention and pre-fills the chat input.
function M.ask_selection()
  if not ensure_available() then return end
  local buf = vim.api.nvim_get_current_buf()
  local l1 = vim.fn.line("'<")
  local l2 = vim.fn.line("'>")
  -- leave visual mode before opening the chat split
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)

  local mention_mod = ai_submodule("poste-ai.chat.mention")
  local window = ai_submodule("poste-ai.chat.window")
  if not mention_mod or not window then return end
  local mention = mention_mod.range_mention(buf, l1, l2)
  if not mention then return end
  M.open_chat()
  window.set_input_text(mention .. " ")
  window.focus_input(true)
end

--- Scope the chat to a connection/database pair (icons follow the browser's).
--- A failed execution carries its target in `state.last_error`, and the response
--- envelope spells an unknown connection or database as `""` — binding that would
--- scope the chat to a target with no name, which the prompt then announced and
--- every later read of the scope inherited. Only a real name is worth binding.
local function scope_chat_target(connection, database)
  local ok_s, scope = pcall(require, "poste-ai.chat.scope")
  if not ok_s then return end
  local util = require("poste-db.util")
  local conn = util.named(connection)
  if not conn then return end
  local ok_i, icons = pcall(require, "poste-db.db_browser.icons")
  local conn_icon = ok_i and icons.ICONS.connection or nil
  local db_icon = ok_i and icons.ICONS.database or nil
  scope.set("connection", conn, conn_icon)
  local db = util.named(database)
  if db then scope.set("database", db, db_icon) end
end

--- `a` on an error view: prefill the chat with the failed SQL + error
--- message and scope the chat to the failing target.
function M.ask_last_error()
  if not ensure_available() then return end
  local err = require("poste-db.state").last_error
  if not err or not err.message then
    vim.notify("no failed execution to ask about", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    return
  end
  local text = table.concat({
    "This SQL failed — help me fix it:",
    "```sql",
    err.sql or "",
    "```",
    "Error:",
    "```",
    tostring(err.message),
    "```",
  }, "\n")
  -- scope AFTER open_chat: open_chat restores the session's scope, which
  -- must not override the failing target
  M.open_chat()
  scope_chat_target(err.connection, err.database)
  local window = ai_submodule("poste-ai.chat.window")
  if not window then return end
  window.set_input_text(text)
  window.focus_input(true)
end

--- `a` on a resultset view: send the last result set (truncated to 20 rows)
--- as a markdown table into the chat, with the query that produced it.
function M.ask_resultset()
  if not ensure_available() then return end
  local data = require("poste-db.state").last_dataset
  if not data or data.type ~= "resultset" or not data.results or #data.results == 0 then
    vim.notify("no resultset to ask about", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    return
  end
  local res = data.results[1]
  local cols = {}
  for _, c in ipairs(res.columns or {}) do cols[#cols + 1] = c.name or "?" end
  local rows = res.rows or {}
  if #cols == 0 or #rows == 0 then
    vim.notify("the result set is empty", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    return
  end

  local MAX_ROWS = 20
  local function row_line(cells) return "| " .. table.concat(cells, " | ") .. " |" end
  local out = { row_line(cols) }
  local seps = {}
  for _ in ipairs(cols) do seps[#seps + 1] = "---" end
  out[#out + 1] = row_line(seps)
  for i = 1, math.min(#rows, MAX_ROWS) do
    local cells = {}
    for j = 1, #cols do
      local v = rows[i][j]
      local s = (v == nil and "NULL" or tostring(v)):gsub("[|\n]", " ")
      if #s > 60 then
        -- char-safe cut at the byte budget: a plain sub split multibyte cell
        -- values (CJK schemas are first-class) and sent invalid UTF-8
        s = require("poste-db.util").utf8_safe_cut(s, 57) .. "..."
      end
      cells[#cells + 1] = s
    end
    out[#out + 1] = row_line(cells)
  end
  if #rows > MAX_ROWS then
    out[#out + 1] = ("(%d of %d rows shown)"):format(MAX_ROWS, #rows)
  end

  local text = "Help me interpret this result set:\n\n" .. table.concat(out, "\n")
  local sql = res.original_sql or res.translated_sql
  if not sql or sql == "" then
    local ok_nav, nav_state = pcall(require, "poste-db.buffer.nav_state")
    local tab = ok_nav and nav_state.get_resultset_data_tab() or nil
    sql = tab and tab.original_sql or nil
  end
  if sql and sql ~= "" then
    text = text .. "\n\nThe query was:\n```sql\n" .. sql .. "\n```"
  end
  M.open_chat()
  local window = ai_submodule("poste-ai.chat.window")
  if not window then return end
  window.set_input_text(text)
  window.focus_input(true)
end

--- `a` in the dataset/error view: ask the AI about what is shown — the last
--- failure when the error view is up (or one exists), otherwise the result set.
function M.ask_view()
  local state_sql = require("poste-db.state")
  local D = require("poste-db.dataset")
  if D.error_buffer and vim.api.nvim_get_current_buf() == D.error_buffer then
    return M.ask_last_error()
  end
  if state_sql.last_dataset and state_sql.last_dataset.type == "resultset" then
    return M.ask_resultset()
  end
  if state_sql.last_error then return M.ask_last_error() end
  vim.notify("nothing to ask about — run a query first", vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
end

--- `a` in the db browser: ask the AI about the node's table/database via an
--- @mention, pre-filling the chat input.
--- @param node table|nil browser node ({ node_type, name, meta })
function M.ask_node(node)
  if not ensure_available() then return end
  if not node then return end
  local meta = node.meta or {}
  local conn = meta.connection
  local db = meta.database
  local mention = nil
  if node.node_type == "table" and conn and db then
    mention = conn .. "/" .. db .. "/" .. node.name
  elseif node.node_type == "database" and conn then
    mention = conn .. "/" .. node.name
  elseif node.node_type == "schema" and conn and db then
    mention = conn .. "/" .. db
  elseif node.node_type == "connection" and conn and (db or meta.database) then
    mention = conn .. "/" .. (db or meta.database)
  end
  if not mention then
    vim.notify("put the cursor on a table or database node to ask the AI",
      vim.log.levels.INFO, { title = const.PLUGIN_TITLE })
    return
  end
  M.open_chat()
  local window = ai_submodule("poste-ai.chat.window")
  if not window then return end
  window.set_input_text("@" .. mention .. " ")
  window.focus_input(true)
end

M._test = { available = M.available }

return M
