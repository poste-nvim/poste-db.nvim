--- table_ops DDL generation: dialect-correct ALTER forms. The generated SQL
--- lands in the user's buffer for review — a wrong dialect form wastes the
--- flow (mssql got Postgres `RENAME COLUMN`, which that engine does not
--- support; clickhouse/mssql got `ALTER COLUMN c TYPE t`, invalid in both).

describe("poste-db table_ops DDL generation", function()
  local t = require("poste-db.table_ops")._test

  describe("quote", function()
    it("backticks and doubles embedded backticks for mysql/mariadb", function()
      assert.equals("`we``rd`", t.quote("we`rd", "mysql"))
      assert.equals("`x`", t.quote("x", "mariadb"))
    end)
    it("double quotes and doubles embedded quotes elsewhere", function()
      assert.equals('"we""rd"', t.quote('we"rd', "postgres"))
      assert.equals('"x"', t.quote("x", "sqlite"))
    end)
    -- The generator used to carry its own two-line quoting helper, which
    -- predated these dialects and rendered a clickhouse name as "t" (invalid
    -- there) and an mssql one as "t" (only legal with QUOTED_IDENTIFIER on).
    it("shares poste-db.ident's clickhouse and mssql spellings", function()
      assert.equals("`t`", t.quote("t", "clickhouse"))
      assert.equals("[t]", t.quote("t", "mssql"))
    end)
  end)

  describe("add column", function()
    it("carries NOT NULL and DEFAULT", function()
      assert.equals('ALTER TABLE "t" ADD COLUMN "c" INT NOT NULL DEFAULT 0;',
        t.gen_add_column("t", "c", "INT", false, "0", "postgres"))
    end)
    it("omits both when nullable and no default", function()
      assert.equals('ALTER TABLE "t" ADD COLUMN "c" TEXT;',
        t.gen_add_column("t", "c", "TEXT", true, nil, "postgres"))
    end)
    it("annotates sqlite NOT NULL without a DEFAULT (server rejects it)", function()
      local ddl = t.gen_add_column("t", "c", "TEXT", false, "", "sqlite")
      assert.match("^ALTER TABLE", ddl)
      assert.match("requires a DEFAULT", ddl)
      -- a DEFAULT makes it legal: no note
      assert.equals('ALTER TABLE "t" ADD COLUMN "c" TEXT NOT NULL DEFAULT 0;',
        t.gen_add_column("t", "c", "TEXT", false, "0", "sqlite"))
    end)
  end)

  describe("rename column", function()
    it("uses sp_rename on mssql (no RENAME COLUMN there)", function()
      assert.equals("EXEC sp_rename 't.old', 'new', 'COLUMN';",
        t.gen_rename_column("t", "old", "new", "mssql"))
    end)
    it("uses the standard form elsewhere", function()
      assert.equals('ALTER TABLE "t" RENAME COLUMN "old" TO "new";',
        t.gen_rename_column("t", "old", "new", "postgres"))
    end)
    it("quotes on mysql", function()
      assert.equals("ALTER TABLE `t` RENAME COLUMN `old` TO `new`;",
        t.gen_rename_column("t", "old", "new", "mysql"))
    end)
    it("doubles an apostrophe inside sp_rename's literal arguments", function()
      assert.equals("EXEC sp_rename 'dbo.o''brien.old', 'new', 'COLUMN';",
        t.gen_rename_column("dbo.o'brien", "old", "new", "mssql"))
    end)
  end)

  describe("drop column", function()
    it("quotes per dialect", function()
      assert.equals('ALTER TABLE "t" DROP COLUMN "c";', t.gen_drop_column("t", "c", "postgres"))
      assert.equals("ALTER TABLE `t` DROP COLUMN `c`;", t.gen_drop_column("t", "c", "mysql"))
    end)
  end)

  describe("alter column type", function()
    it("postgres keeps ALTER COLUMN ... TYPE", function()
      assert.equals('ALTER TABLE "t" ALTER COLUMN "c" TYPE TEXT;',
        t.gen_alter_type("t", "c", "TEXT", "postgres"))
    end)
    it("mysql/mariadb/clickhouse use MODIFY COLUMN", function()
      assert.equals("ALTER TABLE `t` MODIFY COLUMN `c` TEXT;",
        t.gen_alter_type("t", "c", "TEXT", "mysql"))
      assert.equals('ALTER TABLE `t` MODIFY COLUMN `c` TEXT;',
        t.gen_alter_type("t", "c", "TEXT", "clickhouse"))
    end)
    it("mssql uses bare ALTER COLUMN (no TYPE keyword)", function()
      assert.equals('ALTER TABLE [t] ALTER COLUMN [c] TEXT;',
        t.gen_alter_type("t", "c", "TEXT", "mssql"))
    end)
    it("sqlite explains instead of emitting broken DDL", function()
      local ddl = t.gen_alter_type("t", "c", "TEXT", "sqlite")
      assert.match("does not support", ddl)
      assert.is_nil(ddl:find("ALTER TABLE", 1, true))
    end)
  end)
end)

--- The generators answer with a comment *block* for SQLite. nvim_buf_set_lines
--- rejects any item containing a newline, so an unsplitted multi-line string
--- aborted the insert and left the source buffer untouched: `mt` on SQLite
--- looked like a command that does nothing.
describe("poste-db table_ops DDL insertion", function()
  local ops = require("poste-db.table_ops")

  --- Feed the sequential vim.ui.input prompts of a table_ops flow.
  local function feed(inputs)
    local i = 0
    local orig = vim.ui.input
    vim.ui.input = function(_, cb)
      i = i + 1
      cb(inputs[i])
    end
    return function() vim.ui.input = orig end
  end

  local function run(fn, inputs, dialect)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "select 1;" })
    local restore = feed(inputs)
    local ok, err = pcall(fn, "t", dialect, buf)
    restore()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert(ok, tostring(err))
    return lines
  end

  it("writes every line of a multi-line answer into the buffer", function()
    local lines = run(ops.alter_type, { "c", "TEXT" }, "sqlite")
    assert.equals("select 1;", lines[1])
    assert.match("^%-%- Alter type", lines[3])
    assert.match("does not support", lines[4])
    assert.match("^%-%- Recreate", lines[5])
    assert.equals(6, #lines, "blank, label, two comment lines, blank")
  end)

  it("keeps the DDL and its SQLite caveat as separate lines", function()
    local lines = run(ops.add_column, { "c", "INT", "n", "" }, "sqlite")
    assert.equals('ALTER TABLE "t" ADD COLUMN "c" INT NOT NULL;', lines[4])
    assert.match("requires a DEFAULT", lines[5])
  end)

  it("still inserts a plain one-line statement unchanged", function()
    local lines = run(ops.add_column, { "c", "INT", "y", "" }, "postgres")
    assert.equals('ALTER TABLE "t" ADD COLUMN "c" INT;', lines[4])
    assert.equals(5, #lines)
  end)
end)

--- The register_keymaps action names used to be copied from a browser
--- keymap group (select_all/refresh_all/...), so :PosteDbHelp described
--- keys as doing things they never did and a config disabling `select_all`
--- silently lost add-column. The rename keeps the legacy names readable.
describe("poste-db table_ops keymap names", function()
  local config = require("poste-db.config")
  local ops = require("poste-db.table_ops")

  local saved
  local function with_table_ops(overrides, fn)
    saved = vim.deepcopy(config.config.keymaps.sql_table_ops)
    config.config.keymaps.sql_table_ops = overrides
    fn()
    config.config.keymaps.sql_table_ops = saved
  end

  it("binds the new action names with their default keys", function()
    local bound = {}
    local orig_set = vim.keymap.set
    vim.keymap.set = function(mode, lhs) bound[lhs] = true end
    with_table_ops({ add_column = "ma", rename_column = "mr", drop_column = "md", alter_type = "mt" }, function()
      ops.register_keymaps(vim.api.nvim_create_buf(false, true), function() return nil end)
    end)
    vim.keymap.set = orig_set
    assert.is_true(bound.ma and bound.mr and bound.md and bound.mt)
  end)

  it("an override of the legacy name still wins", function()
    local bound = {}
    local orig_set = vim.keymap.set
    vim.keymap.set = function(mode, lhs) bound[lhs] = true end
    with_table_ops({ add_column = "ma", rename_column = "mr", drop_column = "md", alter_type = "mt", select_all = "mx" }, function()
      ops.register_keymaps(vim.api.nvim_create_buf(false, true), function() return nil end)
    end)
    vim.keymap.set = orig_set
    assert.is_true(bound.mx, "the pre-rename override must survive the rename")
    assert.is_nil(bound.ma, "the legacy override replaces the new default")
  end)

  it("a legacy `false` disables the binding", function()
    local bound = {}
    local orig_set = vim.keymap.set
    vim.keymap.set = function(mode, lhs) bound[lhs] = true end
    with_table_ops({ add_column = "ma", rename_column = "mr", drop_column = "md", alter_type = "mt", select_all = false }, function()
      ops.register_keymaps(vim.api.nvim_create_buf(false, true), function() return nil end)
    end)
    vim.keymap.set = orig_set
    assert.is_nil(bound.ma, "false must disable, not fall back to the default key")
    assert.is_true(bound.mr)
  end)

  it("help describes what the keys actually do", function()
    local desc = require("poste-db.help")._test.descriptions.sql_table_ops
    -- the old copy claimed select_all ran a SELECT; the four keys prompt for
    -- column DDL, and the descriptions must say so
    assert.match("column", desc.add_column)
    assert.match("column", desc.rename_column)
    assert.match("column", desc.drop_column)
    assert.match("column", desc.alter_type)
    assert.is_nil(desc.select_all)
  end)
end)

-- Esc on the "Nullable?" or "Default value" prompt read as "no"/"none" and
-- carried on to the next prompt, so there was no way out of the sequence.
describe("table_ops add column prompts", function()
  local ops = require("poste-db.table_ops")
  local buf, saved_input, saved_notify

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    saved_input = vim.ui.input
    saved_notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    vim.ui.input = saved_input
    vim.notify = saved_notify
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  local function lines_of()
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  it("stops when the nullable prompt is cancelled", function()
    local prompts = { "col", "TEXT", nil }
    vim.ui.input = function(_, cb) cb(table.remove(prompts, 1)) end
    ops.add_column("t", "postgres", buf)
    assert.falsy(table.concat(lines_of(), "\n"):find("ADD COLUMN"),
      "no DDL inserted after Esc")
  end)

  it("stops when the default-value prompt is cancelled", function()
    local prompts = { "col", "TEXT", "n", nil }
    vim.ui.input = function(_, cb) cb(table.remove(prompts, 1)) end
    ops.add_column("t", "postgres", buf)
    assert.falsy(table.concat(lines_of(), "\n"):find("ADD COLUMN"),
      "no DDL inserted after Esc")
  end)

  it("inserts the DDL when every prompt is answered", function()
    local prompts = { "col", "TEXT", "n", "" }
    vim.ui.input = function(_, cb) cb(table.remove(prompts, 1)) end
    ops.add_column("t", "postgres", buf)
    local joined = table.concat(lines_of(), "\n")
    assert.truthy(joined:find("ADD COLUMN"))
  end)
end)
