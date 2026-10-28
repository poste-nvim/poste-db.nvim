--- db_browser/util.run_ddl_and_refresh: refresh_subtree clears the target's
--- children and sets its loading marker BEFORE the job starts, so a transport
--- failure reported once via on_error must re-fetch the subtree too — a
--- notify-only failure used to leave the node stuck on the loading marker
--- with no children until a manual refresh.
local saved = {
  connections = package.loaded["poste-db.connections"],
  exec_run = package.loaded["poste-db.exec_run"],
}

local exec_cbs = nil
package.loaded["poste-db.connections"] = {
  resolve_connection_url = function() return "pg://u:pw@h/db", nil end,
}
package.loaded["poste-db.exec_run"] = {
  run_async = function(_sql, _opts, cbs)
    exec_cbs = cbs
    return 42
  end,
}

package.loaded["poste-db.db_browser.util"] = nil
local util = require("poste-db.db_browser.util")

describe("db_browser util run_ddl_and_refresh", function()
  local saved_notify, saved_refresh, refresh_calls

  before_each(function()
    exec_cbs = nil
    refresh_calls = 0
    saved_notify = vim.notify
    vim.notify = function() end
    saved_refresh = util.refresh_subtree
    util.refresh_subtree = function() refresh_calls = refresh_calls + 1 end
  end)

  after_each(function()
    vim.notify = saved_notify
    util.refresh_subtree = saved_refresh
  end)

  local context = { source_buf = 1 }

  it("refreshes the subtree on a transport failure, not only on a response", function()
    util.run_ddl_and_refresh("CREATE TABLE t (id INT)", "pg-main", context, {
      success_msg = "created",
      fail_prefix = "Create table",
    })
    assert.is_not_nil(exec_cbs, "the DDL job must have been started")

    exec_cbs.on_error("poste binary vanished")
    assert.equals(1, refresh_calls, "on_error must re-fetch the cleared subtree")
  end)

  it("refreshes the subtree exactly once on an SQL failure", function()
    util.run_ddl_and_refresh("CREATE TABLE t (id INT)", "pg-main", context, {
      success_msg = "created",
      fail_prefix = "Create table",
    })
    exec_cbs.on_response({ has_error = true, body = "{}" })
    assert.equals(1, refresh_calls, "an SQL failure refreshes once via on_response")
  end)
end)
