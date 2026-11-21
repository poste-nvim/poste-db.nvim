local saved_cli = package.loaded["poste-db.cli"]
local cli_stub = {}
package.loaded["poste-db.cli"] = cli_stub

local exec = require("poste-db.introspect.exec")

describe("introspect exec helpers", function()
  local saved_schedule = vim.schedule
  local saved_notify = vim.notify

  before_each(function()
    package.loaded["poste-db.cli"] = cli_stub
    vim.schedule = function(fn)
      fn()
    end
  end)

  after_each(function()
    vim.schedule = saved_schedule
    vim.notify = saved_notify
    package.loaded["poste-db.cli"] = saved_cli
  end)

  it("runs json item jobs and forwards parsed items", function()
    local captured = {}
    local callbacks = {}
    local notified = nil

    cli_stub.run_async = function(args, cb)
      captured.args = args
      callbacks = cb
    end
    vim.notify = function(msg, level, opts)
      notified = { msg = msg, level = level, opts = opts }
    end

    local seen = nil
    exec.run_json_items_job({ "binary", "introspect" }, {
      title = "PosteDb",
      failure_message = "bad json",
      empty_message = "no rows",
      exit_kind = "Thing",
      on_items = function(items, parsed)
        seen = { items = items, parsed = parsed }
      end,
    })

    assert.same({ "binary", "introspect" }, captured.args)

    callbacks.on_stdout({ '{"items":[{"name":"authors"}]}' })
    assert.same({ { name = "authors" } }, seen.items)
    assert.same({ items = { { name = "authors" } } }, seen.parsed)

    callbacks.on_stderr({ "err one", "err two" })
    callbacks.on_exit(2)
    assert.same({
      msg = "Thing exited with code 2\nerr one\nerr two",
      level = vim.log.levels.ERROR,
      opts = { title = "PosteDb" },
    }, notified)
  end)

  it("shows the empty message when the items list is empty", function()
    local callbacks = {}
    local notified = nil

    cli_stub.run_async = function(_, cb)
      callbacks = cb
    end
    vim.notify = function(msg, level, opts)
      notified = { msg = msg, level = level, opts = opts }
    end

    exec.run_json_items_job({ "binary", "introspect" }, {
      title = "PosteDb",
      empty_message = "no rows",
      on_items = function()
        error("should not be called")
      end,
    })

    callbacks.on_stdout({ '{"items":[]}' })
    assert.same({
      msg = "no rows",
      level = vim.log.levels.WARN,
      opts = { title = "PosteDb" },
    }, notified)
  end)

  it("treats a null items payload as empty instead of raising on #vim.NIL", function()
    local callbacks = {}
    local notified = nil

    cli_stub.run_async = function(_, cb)
      callbacks = cb
    end
    vim.notify = function(msg, level, opts)
      notified = { msg = msg, level = level, opts = opts }
    end

    exec.run_json_items_job({ "binary", "introspect" }, {
      title = "PosteDb",
      empty_message = "no rows",
      on_items = function()
        error("should not be called")
      end,
    })

    callbacks.on_stdout({ '{"items":null}' })
    assert.same({
      msg = "no rows",
      level = vim.log.levels.WARN,
      opts = { title = "PosteDb" },
    }, notified)
  end)
end)
