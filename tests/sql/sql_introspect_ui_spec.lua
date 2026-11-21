local ui = require("poste-db.introspect.ui")

describe("introspect ui helpers", function()
  local saved_notify = vim.notify

  after_each(function()
    vim.notify = saved_notify
  end)

  it("renders tables and connection info through show_float", function()
    local seen = {}
    local function show_float(lines, title, ft)
      seen[#seen + 1] = { lines = lines, title = title, ft = ft }
    end

    ui.show_connection({
      dialect = "postgres",
      host = "localhost",
    }, "primary", show_float)
    ui.show_table_list({ { name = "authors", type = "table" } }, "blog", show_float)
    ui.show_database_info({ { name = "blog", table_count = 2, total_size = "1 MB" } }, "blog", show_float)

    assert.same({
      { lines = {
          "     Dialect  postgres",
          "        Host  localhost",
        }, title = "Connection: primary", ft = nil },
      { lines = { "  authors  (table)" }, title = "Tables: blog", ft = nil },
      { lines = {
          "  Name          blog  ",
          "  Table Count   2  ",
          "  Total Size    1 MB  ",
        }, title = "Database: blog", ft = nil },
    }, seen)
  end)

  it("renders column info and ddl content", function()
    local seen = {}
    local function show_float(lines, title, ft)
      seen[#seen + 1] = { lines = lines, title = title, ft = ft }
    end

    local notified = nil
    vim.notify = function(msg, level, opts)
      notified = { msg = msg, level = level, opts = opts }
    end

    assert.is_true(ui.show_column_info({
      { name = "id", type = "int", nullable = false },
    }, "authors", "id", show_float))
    assert.is_false(ui.show_column_info({}, "authors", "missing", show_float))
    assert.is_true(ui.show_ddl({ { ddl = "CREATE TABLE authors (\n  id int\n);" } }, "authors", show_float))

    local notified2 = nil
    vim.notify = function(msg, level, opts)
      notified2 = { msg = msg, level = level, opts = opts }
    end
    ui.show_database_info(nil, "blog", show_float)

    assert.same({
      { lines = {
          "  Table:    authors",
          "  Type:     int",
          "  Nullable: NO",
          "  Default:  (null)",
        }, title = "Column: id", ft = "sql" },
      { lines = {
          "CREATE TABLE authors (",
          "  id int",
          ");",
        }, title = "DDL: authors", ft = "sql" },
    }, seen)
    assert.same({
      msg = "Column 'missing' not found in table 'authors'",
      level = vim.log.levels.WARN,
      opts = { title = "PosteDb" },
    }, notified)
    assert.same({
      msg = "No database info found",
      level = vim.log.levels.WARN,
      opts = { title = "PosteDb" },
    }, notified2)
  end)

  -- `"ddl": null` decodes to vim.NIL, which is truthy: `or ""` let it through
  -- and vim.split raised on the userdata inside the K keymap callback.
  it("reports a null ddl instead of splitting vim.NIL", function()
    local floated = false
    local notified = nil
    vim.notify = function(msg, level, opts)
      notified = { msg = msg, level = level, opts = opts }
    end

    local ok = ui.show_ddl({ { ddl = vim.NIL } }, "authors", function()
      floated = true
    end)

    assert.is_false(ok)
    assert.is_false(floated)
    assert.same({
      msg = "No DDL found for table 'authors'",
      level = vim.log.levels.WARN,
      opts = { title = "PosteDb" },
    }, notified)
  end)
end)
