--- Regression specs for the 2026-10-30 round-5 audit.
---
--- Each case pins a defect found by reading the code and reproduced before the
--- fix, so the fix cannot quietly revert. Grouped in one file because the
--- defects are otherwise unrelated (statement split, TOML, import, log file,
--- highlights, dataset render guard); the per-area specs stay focused on their
--- own module's behavior.

local statement = require("poste-db.statement")
local toml = require("poste-db.toml")
local import_format = require("poste-db.import.format")
local mapping = require("poste-db.import.mapping")
local fmt = require("poste-db.format")
local state = require("poste-db.state")

describe("statement.find_stmt_lines semicolon-only lines", function()
  it("does not open a statement for a line that is only `;`", function()
    -- The `;` line opened a statement and closed it in the same pass, so the
    -- result->statement mapping shifted by one and read ";" as the SQL: no
    -- table name, no DML editing for the whole result set.
    assert.same({ 1, 3 }, statement.find_stmt_lines({ "SELECT 1;", ";", "SELECT 2;" }, 1, 3))
  end)

  it("still closes the statement above a trailing `;` line", function()
    assert.same({ 1 }, statement.find_stmt_lines({ "SELECT 1", ";" }, 1, 2))
  end)

  it("keeps `;;` and whitespace-only semicolon lines out of the list", function()
    assert.same({ 1 }, statement.find_stmt_lines({ "SELECT 1;", "  ;;  " }, 1, 2))
  end)
end)

describe("statement.extract_table_name with an aliased comma list", function()
  it("refuses `FROM a x, b y` the way it refuses `FROM a, b`", function()
    -- The comma check ran from the end of the name, so the alias hid it and a
    -- two-table result handed the DML builder "users" as its only target.
    assert.is_nil(statement.extract_table_name("SELECT * FROM users u, orders o"))
    assert.is_nil(statement.extract_table_name("SELECT * FROM users AS u, orders AS o"))
  end)

  it("keeps a single aliased table and its clause keywords working", function()
    assert.equals("users", statement.extract_table_name("SELECT * FROM users u WHERE u.id = 1"))
    assert.equals("users", statement.extract_table_name("SELECT * FROM users AS u ORDER BY 1"))
    assert.equals("users", statement.extract_table_name("SELECT * FROM users u LIMIT 5"))
    assert.equals("users", statement.extract_table_name("SELECT * FROM users u"))
  end)
end)

describe("toml duplicate keys", function()
  it("rejects a repeated key instead of letting the last one win", function()
    local parsed, err = toml.parse('password = "a"\npassword = "b"\n')
    assert.is_nil(parsed)
    assert.matches("Duplicate key", err)
  end)

  it("allows the same key in different sections", function()
    local parsed, err = toml.parse('[a]\npassword = "a"\n[b]\npassword = "b"\n')
    assert.is_nil(err)
    assert.equals("a", parsed.a.password)
    assert.equals("b", parsed.b.password)
  end)
end)

describe("import JSON shape validation", function()
  it("rejects a heterogeneous array without raising", function()
    -- `table.sort` over string+numeric keys raised "attempt to compare string
    -- with number" from inside the import preview, so the dialog never opened.
    local parsed, err = import_format.parse_json('[{"a":1},[2,3]]')
    assert.is_nil(parsed)
    assert.equals("Expected array of objects", err)
  end)

  it("rejects an array of arrays instead of inventing numeric column names", function()
    local parsed, err = import_format.parse_json("[[1,2],[3,4]]")
    assert.is_nil(parsed)
    assert.equals("Expected array of objects", err)
  end)

  it("rejects an array of scalars", function()
    local parsed, err = import_format.parse_json("[1,2,3]")
    assert.is_nil(parsed)
    assert.equals("Expected array of objects", err)
  end)

  it("still parses an array of objects, including a ragged one", function()
    local parsed = assert(import_format.parse_json('[{"a":1},{"b":2}]'))
    assert.same({ "a", "b" }, parsed.columns)
    assert.equals(2, #parsed.rows)
  end)
end)

describe("import numeric precision", function()
  it("keeps a decimal literal a double cannot hold as text", function()
    -- `math.abs(num) < 2^53` only guarantees exact INTEGERS; a 19-digit
    -- fraction passed that guard and was rounded before the INSERT.
    assert.equals("0.1234567890123456789",
      mapping.coerce_value("0.1234567890123456789", "numeric(30,19)"))
  end)

  it("still coerces short decimals and exact integers", function()
    assert.equals(0.125, mapping.coerce_value("0.125", "numeric"))
    assert.equals(3, mapping.coerce_value("3.0", "integer"))
    assert.equals(4503599627370496, mapping.coerce_value("4503599627370496", "bigint"))
  end)
end)

describe("format wrap_text", function()
  it("keeps every character of a very long single-line message", function()
    -- The bounded-window scan replaced a per-chunk measurement of the whole
    -- remaining line; both must cut the same text, character for character.
    local body = string.rep("x", 40000)
    local lines = fmt._test.wrap_text(body, 78)
    assert.equals(body, table.concat(lines, ""))
    assert.is_true(#lines > 1, "the message really was wrapped")
  end)

  it("never exceeds the width budget", function()
    local body = string.rep("y", 800)
    for _, line in ipairs(fmt._test.wrap_text(body, 78)) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= 78,
        "no wrapped line exceeds the budget")
    end
  end)

  it("keeps a multibyte line intact while wrapping", function()
    local body = string.rep("日本語テキスト", 200)
    local lines = fmt._test.wrap_text(body, 40)
    assert.equals(body, table.concat(lines, ""))
    for _, line in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= 40)
      assert.is_true(vim.fn.strchars(line) > 0)
    end
  end)
end)

describe("state.log level gate and file mode", function()
  local log_path = "/tmp/poste-db-log-spec.log"
  local saved_log_file, saved_log_level

  before_each(function()
    saved_log_file, saved_log_level = state.config.log_file, state.config.log_level
    os.remove(log_path)
    state.config.log_file = log_path
    state.config.log_level = "WARN"
  end)

  after_each(function()
    state.config.log_file, state.config.log_level = saved_log_file, saved_log_level
    os.remove(log_path)
  end)

  it("drops DEBUG lines at the default level", function()
    state.log("DEBUG", "SQL session payload: SELECT secret FROM users")
    assert.equals(0, vim.fn.filereadable(log_path))
  end)

  it("writes WARN and ERROR lines, creating the file 0600", function()
    state.log("ERROR", "SQL execution failed: boom")
    assert.equals(1, vim.fn.filereadable(log_path))
    local perms = vim.fn.getfperm(log_path)
    assert.equals("rw-------", perms, "statement text must not be world-readable")
    local content = table.concat(vim.fn.readfile(log_path), "\n")
    assert.matches("boom", content)
  end)

  it("honours an explicit DEBUG level", function()
    state.config.log_level = "DEBUG"
    state.log("DEBUG", "verbose")
    assert.equals(1, vim.fn.filereadable(log_path))
  end)
end)

describe("dataset NULL highlight", function()
  it("marks the renderer's <null> and <default> spellings", function()
    local highlights = require("poste-db.highlights")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "┌────┐",
      "│ 1 │ <null>    │",
      "│ 2 │ <default> │",
      "└────┘",
    })
    highlights.apply_dataset_highlights(buf, vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
      type = "resultset",
      header_line = 1,
      data_start_line = 2,
      data_end_line = 3,
      row_count = 2,
    })
    local ns = vim.api.nvim_create_namespace("poste_db_dataset")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local null_marks = 0
    for _, mark in ipairs(marks) do
      local hl = mark[4] and mark[4].hl_group
      if hl == "PosteDbDatasetNull" then null_marks = null_marks + 1 end
    end
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.equals(2, null_marks, "one mark per NULL/default cell")
  end)
end)

describe("dataset render refuses to drop pending edits", function()
  local buffer = require("poste-db.buffer")
  local D = require("poste-db.dataset")

  before_each(function()
    buffer._test.reset()
  end)

  it("keeps the active tab and its edit state when the view would be replaced", function()
    local tab = buffer._test.create_tab(1)
    D.active_tab_idx = 1
    tab.edit_state = { dirty = true, modified_cells = {}, added_rows = {}, deleted_rows = {} }
    local notified = nil
    local saved_notify = vim.notify
    vim.notify = function(msg) notified = msg end
    buffer.render_dataset({ "line" }, { type = "raw" })
    vim.notify = saved_notify

    assert.is_truthy(notified, "the user is told why nothing changed")
    assert.equals(tab, D.T(), "the dirty tab is still the active one")
    assert.is_true(D.T().edit_state.dirty, "the queued edits survive")
  end)

  it("replaces the view once the edits are gone", function()
    local tab = buffer._test.create_tab(1)
    D.active_tab_idx = 1
    tab.edit_state = { dirty = false, modified_cells = {}, added_rows = {}, deleted_rows = {} }
    local saved_notify = vim.notify
    local notified = nil
    vim.notify = function(msg) notified = msg end
    buffer.render_dataset({ "line" }, { type = "raw" })
    vim.notify = saved_notify

    assert.is_nil(notified, "no conflict warning for a clean dataset")
  end)
end)
