describe("poste-db.ai.system_prompt", function()
  local system_prompt = require("poste-db.ai.system_prompt")
  local state = require("poste-db.state")

  after_each(function()
    state.context.connection = nil
    state.context.database = nil
  end)

  it("describes plugin capabilities including export", function()
    local prompt = system_prompt._test.build()
    assert.truthy(prompt:find("PosteDbExport"))
    assert.truthy(prompt:find("db browser"))
    assert.truthy(prompt:find("connections%.toml"))
  end)

  it("instructs the model to emit exactly one sql block", function()
    local prompt = system_prompt._test.build()
    assert.truthy(prompt:find("exactly one"))
    assert.truthy(prompt:find("@connection"))
  end)

  it("forbids ? placeholders in generated sql", function()
    local prompt = system_prompt._test.build()
    assert.truthy(prompt:find("Never emit", 1, true))
    assert.truthy(prompt:find("placeholders", 1, true))
  end)

  it("includes the current SQL context when set", function()
    state.context.connection = "pg-ecommerce"
    state.context.database = "shop"
    local prompt = system_prompt._test.build()
    assert.truthy(prompt:find("Current SQL context"))
    assert.truthy(prompt:find("pg%-ecommerce"))
    assert.truthy(prompt:find("shop"))
  end)

  it("prefers the chat scope over the SQL buffer context", function()
    state.context.connection = "pg-ecommerce"
    state.context.database = "shop"
    local prompt = system_prompt._test.build({ connection = "my-blog", database = "blog" })
    assert.truthy(prompt:find("Current chat scope"))
    assert.truthy(prompt:find("my%-blog"))
    assert.truthy(prompt:find("blog"))
    assert.falsy(prompt:find("Current SQL context"))
  end)

  it("covers a connection-only chat scope", function()
    local prompt = system_prompt._test.build({ connection = "my-blog" })
    assert.truthy(prompt:find("Current chat scope"))
    assert.truthy(prompt:find("my%-blog"))
  end)

  it("names the dialect of the scoped connection", function()
    local prompt = system_prompt._test.build({ connection = "my-blog", database = "blog" })
    assert.truthy(prompt:find("mysql dialect"))
    assert.truthy(prompt:find("mysql%-compatible statements"))
  end)

  it("omits the context section when unset", function()
    local prompt = system_prompt._test.build()
    assert.falsy(prompt:find("Current SQL context"))
  end)

  it("treats non-string scope/context fields as absent instead of crashing", function()
    -- the scope map is hand-buildable and state.context mirrors the binary's
    -- error payloads; a number/table where a string belongs must degrade to
    -- "no such field", not break the prompt build inside the chat request
    local hostile_scope = system_prompt._test.build({ connection = 42, database = { "db" } })
    assert.falsy(hostile_scope:find("Current chat scope"))
    assert.falsy(hostile_scope:find("Current SQL context"))

    local hostile_scope2 = system_prompt._test.build({ connection = "my-blog", database = true })
    assert.truthy(hostile_scope2:find("Current chat scope"))
    assert.truthy(hostile_scope2:find("my%-blog"))
    -- the old code reached 'string .. true' and crashed before rendering
    -- anything; arriving here without an error is the regression
    assert.falsy(hostile_scope2:find("database true", 1, true))

    state.context.connection = 99
    state.context.database = {}
    local hostile_ctx = system_prompt._test.build()
    assert.falsy(hostile_ctx:find("Current SQL context"))
  end)

  it("keeps credentials out of the prompt for both context paths", function()
    -- A chat scope / buffer context can hold the resolved DSN, and the prompt
    -- goes to a remote model.
    local scoped = system_prompt._test.build({
      connection = "postgres://u:pa/ss@h:5432/db?password=hunter2", database = "blog",
    })
    assert.falsy(scoped:find("hunter2", 1, true))
    assert.falsy(scoped:find("pa/ss", 1, true))
    assert.truthy(scoped:find("postgres://u:***@h:5432/db", 1, true))

    state.context.connection = "mysql://root:s3cret@h:3306/app"
    local ctx = system_prompt._test.build()
    assert.falsy(ctx:find("s3cret", 1, true))
    assert.truthy(ctx:find("mysql://root:***@h:3306/app", 1, true))
  end)

  it("does not read an empty chat scope as a scoped one", function()
    -- The envelope spells an unknown connection/database as "" and a failed
    -- execution carries that into the chat scope. Treated as a binding, the
    -- prompt announced "scoped to connection " with nothing after it, told the
    -- model blocks run against that target, and — because the chat scope wins —
    -- hid the buffer's real context behind an empty string.
    state.context.connection = "pg-ecommerce"
    state.context.database = "shop"
    local prompt = system_prompt._test.build({ connection = "" })
    assert.falsy(prompt:find("Current chat scope"))
    assert.truthy(prompt:find("Current SQL context"))
    assert.truthy(prompt:find("pg%-ecommerce"))
  end)

  it("drops an empty database from a scoped prompt instead of dangling it", function()
    local prompt = system_prompt._test.build({ connection = "my-blog", database = "" })
    assert.truthy(prompt:find("Current chat scope"))
    assert.falsy(prompt:find(", database ", 1, true))
    local both = system_prompt._test.build({ connection = "", database = "" })
    assert.falsy(both:find("Current chat scope"))
  end)

  it("renders the unbound side of a partial SQL context as (none)", function()
    -- only one half is known: the line must say so rather than print a blank
    state.context.connection = ""
    state.context.database = "shop"
    local prompt = system_prompt._test.build()
    assert.truthy(prompt:find("connection (none), database shop", 1, true))

    state.context.connection = "pg-ecommerce"
    state.context.database = ""
    prompt = system_prompt._test.build()
    assert.truthy(prompt:find("connection pg-ecommerce, database (none)", 1, true))
  end)

  it("omits the context section when both halves are empty strings", function()
    state.context.connection = ""
    state.context.database = ""
    local prompt = system_prompt._test.build()
    assert.falsy(prompt:find("Current SQL context"))
    assert.falsy(prompt:find("bound to", 1, true))
  end)
end)

describe("poste-db.ai integration", function()
  local ai = require("poste-db.ai")

  it("registers the db context when poste-ai is available", function()
    if not ai.available() then
      pending("poste-ai.nvim not on rtp")
      return
    end
    assert.is_true(ai.register())
    local poste_ai = require("poste-ai")
    local spec = poste_ai.register_context and require("poste-ai.context_api").get("db")
    assert.is_not_nil(spec)
    assert.is_function(spec.mention.match)
    assert.is_function(spec.mention.resolve)
    assert.is_function(spec.codeblock.execute)
    assert.is_function(spec.codeblock.append_header)
    -- the mention bridge routes to poste-db.ai.mentions
    local ref = spec.mention.match("my-blog/blog")
    assert.is_not_nil(ref)
    assert.are.equal("my-blog", ref.connection)
  end)

  it("reports availability gracefully when poste-ai is missing", function()
    -- available() must never throw even when the dependency is absent
    assert.is_boolean(ai.available())
  end)

  it("exposes the PosteDbChat command and the visual ask keymap", function()
    -- plenary specs run in a child process without the parent's setup() call
    require("poste-db.commands").setup()
    assert.is_true(vim.fn.exists(":PosteDbChat") > 0)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "test_ai.sql")
    vim.api.nvim_buf_set_option(buf, "filetype", "poste_sql")
    require("poste-db.buffer_setup").setup_buffer_keymaps(buf)
    vim.api.nvim_set_current_buf(buf)
    local k = require("poste-db.config").get_keymap("sql_source", "ask_ai", "<leader>aa")
    local mapped = vim.fn.maparg(k, "v", false, true)
    assert.is_table(mapped)
    assert.is_truthy(mapped.buffer)
  end)
end)
