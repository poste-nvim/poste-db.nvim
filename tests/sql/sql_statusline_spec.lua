-- Tests for lua/poste-db/statusline.lua
-- Context text/conn resolution from the buffer-local poste_db_* variables.

package.loaded["poste-db.connections"] = {
  get_connection_config = function(conn)
    if conn == "prod" then return { color = "red" } end
    return nil
  end,
}

local statusline = require("poste-db.statusline")

describe("statusline context text", function()
  before_each(function()
    vim.b.poste_db_context = nil
    vim.b.poste_db_conn = nil
  end)

  it("returns empty string when no context is stored", function()
    assert.equals("", statusline.get_context_text())
    assert.equals("", statusline.get_context())
  end)

  it("returns the stored context text", function()
    vim.b.poste_db_context = "prod  🗄  blog"
    assert.equals("prod  🗄  blog", statusline.get_context_text())
  end)

  it("returns plain context when the connection has no color config", function()
    vim.b.poste_db_context = "anon/blog"
    assert.equals("anon/blog", statusline.get_context())
  end)

  it("wraps the context in a per-connection highlight when color is configured", function()
    vim.b.poste_db_context = "prod/blog"
    vim.b.poste_db_conn = "prod"
    local out = statusline.get_context()
    assert.matches("^%%#PosteDbSqlCtxprod#", out)
    assert.matches("# prod/blog $", out)
  end)

  it("context highlight uses the connection name from the context string", function()
    vim.b.poste_db_context = "prod/blog"
    local hl = statusline.get_context_hl()
    assert.equals("PosteDbSqlCtxprod", hl)
  end)

  it("context highlight reads b:poste_db_conn for a dataset-shaped context", function()
    -- A dataset buffer's context string has no `/` to split on ("conn  🗄 db
    -- ⭡ table"), so the slash-parse handed the whole decorated string to the
    -- lookup and lualine lost the per-connection color on every dataset
    -- buffer. The mini path already reads b:poste_db_conn first.
    vim.b.poste_db_context = "prod  🗄 blog  ⭡ users"
    vim.b.poste_db_conn = "prod"
    local hl = statusline.get_context_hl()
    assert.equals("PosteDbSqlCtxprod", hl)
  end)

  it("degrades a table-typed color/link/bg instead of erroring the redraw", function()
    -- The TOML parser turns `color = [1]` into a real table; `:sub` used to
    -- raise on it — inside a function every statusline redraw runs. A
    -- non-string field counts as absent (the redis sibling's round-24 gate).
    package.loaded["poste-db.connections"] = {
      get_connection_config = function(conn)
        if conn == "tbl" then return { color = { "red" }, link = {}, bg = {} } end
        if conn == "tblbg" then return { color = "red", bg = { "#222222" } } end
        if conn == "prod" then return { color = "red" } end
        return nil
      end,
    }
    vim.b.poste_db_conn = "tbl"
    assert.equals("", statusline.get_context())
    vim.b.poste_db_context = "tblbg/blog"
    vim.b.poste_db_conn = "tblbg"
    assert.matches("^%%#PosteDbSqlCtxtblbg#", statusline.get_context())
    -- restore the module-level stub the other tests read
    package.loaded["poste-db.connections"] = {
      get_connection_config = function(conn)
        if conn == "prod" then return { color = "red" } end
        return nil
      end,
    }
  end)
end)
describe("statusline % escaping", function()
  before_each(function()
    vim.b.poste_db_context = nil
    vim.b.poste_db_conn = nil
  end)

  it("escapes % in the colored context so statusline redraws never hit E539", function()
    vim.b.poste_db_context = "prod/100%db"
    vim.b.poste_db_conn = "prod"
    local out = statusline.get_context()
    assert.matches("prod/100%%db", out, 1, true)
    assert.has_no.errors(function()
      vim.api.nvim_eval_statusline(out, {})
    end)
  end)

  it("escapes % in the plain (uncolored) context", function()
    vim.b.poste_db_context = "anon/50%db"
    local out = statusline.get_context()
    assert.matches("anon/50%%db", out, 1, true)
    assert.has_no.errors(function()
      vim.api.nvim_eval_statusline(out, {})
    end)
  end)
end)

---------------------------------------------------------------------------
-- mini.statusline wiring (poste.nvim family dissolution): scope-guard,
-- fall-through chain discipline, reload idempotency.
---------------------------------------------------------------------------
--- Fake mini.statusline with just enough surface for the wiring. `content`
--- starts empty, mirroring the real mini.statusline: `config.content.active`
--- is nil unless the user configures one, in which case mini falls back to
--- its own `default_content_active` at render time.
local function fake_mini()
  local fake = {
    section_fileinfo = function() return "[orig]" end,
    config = { content = {} },
  }
  package.loaded["mini.statusline"] = fake
  return fake
end

--- Fresh module + fake mini, then run setup() and pump the scheduled wiring.
local function fresh_setup()
  local ms = fake_mini()
  package.loaded["poste-db.statusline"] = nil
  local sl = require("poste-db.statusline")
  sl.setup()
  vim.wait(100, function() return vim.g.poste_db_statusline_wired end)
  return sl, ms
end

describe("statusline mini wiring", function()
  before_each(function()
    vim.g.poste_db_statusline_wired = nil
  end)

  after_each(function()
    package.loaded["mini.statusline"] = nil
    vim.g.poste_db_statusline_wired = nil
    vim.b.poste_db_context = nil
    vim.b.poste_db_conn = nil
    vim.cmd("enew")
  end)

  it("renders the context through the section_fileinfo wrapper", function()
    local _, ms = fresh_setup()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].poste_db_context = "prod/blog"
    vim.api.nvim_set_current_buf(buf)

    assert.match("prod/blog", ms.section_fileinfo({}))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("leaves content.active untouched when the user set none", function()
    -- Regression: owning `content.active` and returning "" on non-db
    -- buffers blanked the whole statusline for the default
    -- `mini.statusline.setup({ use_icons = … })` configuration, where
    -- `content.active` is nil and mini falls back to its own default
    -- layout. The context must come only from `section_fileinfo`, which
    -- mini's default layout renders through.
    local _, ms = fresh_setup()
    assert.equals(nil, ms.config.content.active)

    local db_buf = vim.api.nvim_create_buf(false, true)
    vim.b[db_buf].poste_db_context = "prod/blog"
    vim.api.nvim_set_current_buf(db_buf)
    assert.match("prod/blog", ms.section_fileinfo({}))
    vim.api.nvim_buf_delete(db_buf, { force = true })
  end)

  it("does not clobber a user-provided content.active", function()
    local ms = fake_mini()
    local user_active = function() return "[user-active]" end
    ms.config.content.active = user_active

    package.loaded["poste-db.statusline"] = nil
    require("poste-db.statusline").setup()
    vim.wait(100, function() return vim.g.poste_db_statusline_wired end)

    assert.equals(user_active, ms.config.content.active)
    assert.equals("[user-active]", ms.config.content.active())

    -- and the db context still reaches the layout through fileinfo
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].poste_db_context = "prod/blog"
    vim.api.nvim_set_current_buf(buf)
    assert.match("prod/blog", ms.section_fileinfo({}))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("falls through to the captured original fileinfo on non-db buffers", function()
    local _, ms = fresh_setup()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)

    assert.equals("[orig]", ms.section_fileinfo({}))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("escapes % in the wired context text (statusline E539)", function()
    local _, ms = fresh_setup()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].poste_db_context = "prod/100%db"
    vim.api.nvim_set_current_buf(buf)

    local out = ms.section_fileinfo({})
    assert.match("prod/100%%db", out, 1, true)
    assert.has_no.errors(function()
      vim.api.nvim_eval_statusline(out, {})
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not re-capture the hooks when setup runs twice", function()
    local sl, ms = fresh_setup()
    local fileinfo1 = ms.section_fileinfo

    sl.setup()  -- same module instance
    assert.equals(fileinfo1, ms.section_fileinfo, "hooks must not be re-wrapped")

    -- a module reload must also be a no-op: the vim.g guard owns the
    -- idempotency across reloads
    package.loaded["poste-db.statusline"] = nil
    require("poste-db.statusline").setup()
    vim.wait(50)
    assert.equals(fileinfo1, ms.section_fileinfo,
      "a reload must not stack a second wrapper")
  end)

  it("chains: a sibling wrapper installed earlier still renders", function()
    -- Install a redis-style sibling wrapper first: it claims buffers
    -- carrying `poste_redis_context` and falls through otherwise. This is
    -- the real shape of the poste family, where several plugins each wrap
    -- `section_fileinfo` in setup order.
    local ms = fake_mini()
    local base_fileinfo = ms.section_fileinfo
    ms.section_fileinfo = function(...)
      local rctx = vim.b.poste_redis_context
      if rctx and rctx ~= "" then return "%#PosteRedisCtxlocal# " .. rctx end
      return base_fileinfo(...)
    end

    package.loaded["poste-db.statusline"] = nil
    local sl = require("poste-db.statusline")
    sl.setup()
    vim.wait(100, function() return vim.g.poste_db_statusline_wired end)

    local db_buf = vim.api.nvim_create_buf(false, true)
    vim.b[db_buf].poste_db_context = "prod/blog"
    local redis_buf = vim.api.nvim_create_buf(false, true)
    vim.b[redis_buf].poste_redis_context = "redis/streams"
    local plain = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_set_current_buf(db_buf)
    assert.match("prod/blog", ms.section_fileinfo({}),
      "db context must render on db buffers")

    vim.api.nvim_set_current_buf(redis_buf)
    assert.match("PosteRedisCtxlocal", ms.section_fileinfo({}),
      "sibling context must survive db wrapping it")

    vim.api.nvim_set_current_buf(plain)
    assert.equals("[orig]", ms.section_fileinfo({}),
      "unclaimed buffers must reach mini's original fileinfo")

    vim.api.nvim_buf_delete(db_buf, { force = true })
    vim.api.nvim_buf_delete(redis_buf, { force = true })
    vim.api.nvim_buf_delete(plain, { force = true })
  end)
end)

describe("statusline ctx-highlight cache", function()
  after_each(function()
    -- restore the module-level stub the other tests read
    package.loaded["poste-db.connections"] = {
      get_connection_config = function(conn)
        if conn == "prod" then return { color = "red" } end
        return nil
      end,
    }
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    vim.b.poste_db_context = nil
    vim.b.poste_db_conn = nil
  end)

  it("caches per (color,link,bg) fingerprint and re-derives on change", function()
    vim.b.poste_db_context = "prod/blog"
    vim.b.poste_db_conn = "prod"
    assert.equals("PosteDbSqlCtxprod", statusline.get_context_hl())
    assert.are.equal("red\0\0", statusline._test.hl_cache().prod.fp)

    -- the toml entry changes; the fingerprint changes and the definition is
    -- re-applied under the same group name
    package.loaded["poste-db.connections"] = {
      get_connection_config = function()
        return { color = "blue", bg = "#222222" }
      end,
    }
    assert.equals("PosteDbSqlCtxprod", statusline.get_context_hl())
    assert.are.equal("blue\0\0#222222", statusline._test.hl_cache().prod.fp)
  end)

  it("stales the cache on ColorScheme so definitions re-derive", function()
    vim.b.poste_db_context = "prod/blog"
    vim.b.poste_db_conn = "prod"
    statusline.get_context_hl()
    assert.is_truthy(statusline._test.hl_cache().prod)

    vim.api.nvim_exec_autocmds("ColorScheme", {})
    -- the epoch bump lives in vim.g, so every live module instance sees the
    -- invalidation even though the handler itself was registered once
    local served = statusline.get_context_hl()
    assert.equals("PosteDbSqlCtxprod", served)
    assert.are.equal(vim.g.poste_db_ctx_hl_epoch,
      statusline._test.hl_cache().prod.epoch,
      "the post-switch evaluation must re-derive, not serve the stale entry")
  end)
end)

describe("statusline ctx-highlight cache across reloads", function()
  after_each(function()
    package.loaded["poste-db.statusline"] = nil
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    package.loaded["mini.statusline"] = nil
    vim.b.poste_db_context = nil
    vim.b.poste_db_conn = nil
  end)

  it("a scheme switch stales every reloaded instance's cache", function()
    -- this Neovim dedupes content-equivalent autocmd callbacks, so a
    -- reloaded instance (the mini-wiring specs reload this file) never gets
    -- its own handler; the epoch lives in vim.g precisely so one handler
    -- invalidates every live instance's cache
    package.loaded["poste-db.connections"] = {
      get_connection_config = function() return { color = "red" } end,
    }
    local first = require("poste-db.statusline")
    vim.b.poste_db_conn = "prod"
    vim.b.poste_db_context = "prod/blog"
    first.get_context_hl()

    package.loaded["poste-db.statusline"] = nil
    local second = require("poste-db.statusline")
    second.get_context_hl()

    vim.api.nvim_exec_autocmds("ColorScheme", {})
    local epoch = vim.g.poste_db_ctx_hl_epoch
    assert.is_number(epoch)
    -- both instances must see the invalidation and re-derive
    assert.equals("PosteDbSqlCtxprod", first.get_context_hl())
    assert.equals("PosteDbSqlCtxprod", second.get_context_hl())
    assert.are.equal(epoch, first._test.hl_cache().prod.epoch, "first instance re-derived")
    assert.are.equal(epoch, second._test.hl_cache().prod.epoch, "second instance re-derived")
  end)
end)
