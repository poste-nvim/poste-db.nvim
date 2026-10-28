local M = {}

local hl_cache = {}      -- conn_name -> { hl_name = string, fp = string, epoch = number }
local hl_cache_group = nil

--- get_ctx_color runs on EVERY statusline evaluation and every cursor move
--- (source winbar + dataset winbar). nvim_set_hl invalidates global
--- highlighting and forces a full-screen redraw even when the value is
--- unchanged, so the definition is only re-applied when the connections.toml
--- fingerprint (color/link/bg) actually changed; a ColorScheme event bumps a
--- global epoch so cached entries re-derive against the new scheme. Mirrors
--- the poste-redis.nvim sibling's cache so the two stay in step.
---
--- The epoch lives in vim.g, NOT in a rebound upvalue: this Neovim dedupes
--- autocmd registrations whose callbacks are content-equivalent, so a
--- reloaded module instance (spec harnesses reload this file) cannot get a
--- second handler — a handler clearing its own instance's table would leave
--- every other live instance's cache permanently stale.
local function cache_drop_group()
  if not hl_cache_group then
    hl_cache_group = vim.api.nvim_create_augroup("PosteDbCtxHlCache", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = hl_cache_group,
      callback = function()
        vim.g.poste_db_ctx_hl_epoch = (vim.g.poste_db_ctx_hl_epoch or 0) + 1
      end,
    })
  end
end

local function get_ctx_color(conn_name)
  local ok, connections = pcall(require, "poste-db.connections")
  if not ok then return nil end

  local config = connections.get_connection_config(conn_name)
  if not config and type(conn_name) == "string" and conn_name:find("://", 1, true) then
    -- Dataset buffers carry the URL the binary echoed, never the section
    -- name (nav_ui's own comment): get_connection_config indexes the parsed
    -- TOML by name, so the per-connection color silently never applied there.
    -- name_for_url maps the URL back (tunnel-aware).
    local ok_name, name = pcall(connections.name_for_url, conn_name)
    if ok_name and name then
      conn_name = name
      config = connections.get_connection_config(conn_name)
    end
  end
  if not config then return nil end

  -- Type-gated like every other connections.toml field the display paths
  -- touch: the TOML parser turns `color = [1]` into a real table, and the
  -- `:sub` below used to error on it — on every statusline redraw.
  local color = type(config.color) == "string" and config.color or nil
  local link = type(config.link) == "string" and config.link or nil
  local bg = type(config.bg) == "string" and config.bg or nil
  if not color and not link then return nil end

  local fp = (color or "") .. "\0" .. (link or "") .. "\0" .. (bg or "")
  local epoch = vim.g.poste_db_ctx_hl_epoch or 0
  local cached = hl_cache[conn_name]
  if cached and cached.fp == fp and cached.epoch == epoch then return cached.hl_name end

  local hl_name = "PosteDbSqlCtx" .. conn_name:gsub("[^%w_]", "_")

  if link then
    pcall(vim.api.nvim_set_hl, 0, hl_name, { link = link })
    cache_drop_group()
    hl_cache[conn_name] = { hl_name = hl_name, fp = fp, epoch = epoch }
    return hl_name
  end

  if not color then return nil end

  local hl_opts = {}
  if bg then
    if bg:sub(1, 1) == "#" then
      hl_opts.bg = bg
    elseif vim.fn.hlexists(bg) == 1 then
      local bg_ok, bg_hl = pcall(vim.api.nvim_get_hl, 0, { name = bg })
      if bg_ok and bg_hl.bg then
        hl_opts.bg = bg_hl.bg
      end
    end
    -- an unknown bg name is dropped, not passed through: nvim_set_hl would
    -- reject the whole definition and the connection loses its fg color too
  end
  if color:sub(1, 1) == "#" then
    hl_opts.fg = color
  elseif vim.fn.hlexists(color) == 1 then
    -- a highlight-group name links through; the old pcall(get_hl) truthiness
    -- also "succeeded" for a group that does not exist, linking to nothing
    hl_opts.link = color
  else
    hl_opts.fg = color
  end
  local ok_hl = pcall(vim.api.nvim_set_hl, 0, hl_name, hl_opts)
  if not ok_hl then return nil end

  cache_drop_group()
  hl_cache[conn_name] = { hl_name = hl_name, fp = fp, epoch = epoch }
  return hl_name
end

-- `%` is the statusline escape character: a connection/context containing it
-- (e.g. "100%/db") breaks every redraw with E539 unless doubled to `%%`.
local function escape_statusline(s)
  return (s:gsub("%%", "%%%%"))
end

local function fmt_ctx(ctx)
  local conn_name = vim.b.poste_db_conn
  if conn_name then
    local hl_name = get_ctx_color(conn_name)
    if hl_name then
      return "%#" .. hl_name .. "# " .. escape_statusline(ctx) .. " "
    end
  end
  return escape_statusline(ctx)
end
--- mini.statusline wiring (the only path since the poste.nvim family
--- dissolution). The context is rendered by wrapping `section_fileinfo`
--- only: db claims a buffer when it carries `poste_db_context` (SQL source,
--- dataset, db browser, introspection buffers) and otherwise falls through
--- to the captured original, so sibling plugins wrapping the same hook chain
--- instead of fighting over a global slot. `section_fileinfo` is a safe
--- anchor — mini.statusline's own default `content.active` renders through
--- it, so the context survives whoever owns the layout. The
--- `vim.g.poste_db_statusline_wired` flag keeps a module reload from
--- re-capturing the already-wrapped hook (wrapper stacking).
local function wire_mini_statusline()
  vim.schedule(function()
    local ok_mini, statusline = pcall(require, "mini.statusline")
    if not ok_mini then return end
    if vim.g.poste_db_statusline_wired then return end
    vim.g.poste_db_statusline_wired = true

    local orig_fileinfo = statusline.section_fileinfo
    statusline.section_fileinfo = function(...)
      local ctx = vim.b.poste_db_context
      if ctx and ctx ~= "" then
        -- Bake the per-connection highlight into the returned string itself:
        -- other plugins (e.g. poste-redis.nvim) may own `content.active` and
        -- drop poste-db's per-group highlight, but `%#…#` markup inside the
        -- string survives any layout.
        -- b:poste_db_conn first: dataset buffers carry a URL there and their
        -- context string ("conn  🗄 db  ⭡ table") has no `/` to split on, so
        -- the slash-parse handed the whole decorated string to the lookup.
        local conn_name = vim.b.poste_db_conn
          or ctx:match("^(.-)[/]") or ctx
        local hl_name = get_ctx_color(conn_name)
        if hl_name then
          return "%#" .. hl_name .. "# " .. escape_statusline(ctx) .. " "
        end
        return escape_statusline(ctx)
      end
      return orig_fileinfo(...)
    end
    -- NOTE: we deliberately do NOT override `config.content.active`.
    -- The context is rendered through the `section_fileinfo` wrapper
    -- above, which survives any layout: mini.statusline's default
    -- `content.active` calls `section_fileinfo`, and every sibling
    -- postgres-family layout does too. Owning `content.active` here
    -- duplicated mini's default layout and, when the user did not
    -- configure their own `content.active` (the default case), the
    -- non-db fall-through returned "" and blanked the statusline on
    -- every non-SQL buffer. See the `section_fileinfo` wrapper for
    -- the per-connection highlight.
  end)
end

function M.setup()
  wire_mini_statusline()

  vim.schedule(function()
    local ok_lualine = pcall(require, "lualine")
    if ok_lualine then
      M.setup_lualine()
    end
  end)
end

function M.setup_lualine()
  vim.schedule(function()
    local lualine = require("lualine")
    local cfg = lualine.get_config()

    cfg.sections = cfg.sections or {}
    cfg.sections.lualine_c = cfg.sections.lualine_c or {}

    local component = { M.get_context_text, color = M.get_context_hl }
    local exists = false
    for _, comp in ipairs(cfg.sections.lualine_c) do
      if type(comp) == "table" and comp[1] == M.get_context_text then
        exists = true
        break
      end
    end
    if not exists then
      table.insert(cfg.sections.lualine_c, 1, component)
    end

    lualine.setup(cfg)
  end)
end

function M.get_context()
  local ctx = vim.b.poste_db_context
  if ctx and ctx ~= "" then
    return fmt_ctx(ctx)
  end
  return ""
end

--- Plain text for lualine components.
function M.get_context_text()
  return vim.b.poste_db_context or ""
end

--- Highlight group name for lualine's color option, per-connection.
--- Returns nil when no context, so lualine falls back to default highlight.
function M.get_context_hl()
  local ctx = vim.b.poste_db_context
  if not ctx or ctx == "" then return nil end
  local conn_name = ctx:match("^(.-)[/]") or ctx
  return get_ctx_color(conn_name)
end

M._test = {
  hl_cache = function() return hl_cache end,
}

return M
