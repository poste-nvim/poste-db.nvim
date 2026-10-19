-- Tests for lua/poste-db/export.lua
-- Pure formatter tests (csv/tsv/json/markdown/sql-insert) + filename generation.

local export = require("poste-db.export")

--- results[1] of a response body: the bare column/row payload. The table name
--- and dialect are NOT here — see the get_current_data block below.
local function data_result(overrides)
  local base = {
    columns = { { name = "id" }, { name = "name" }, { name = "bio" } },
    rows = {
      { 1, "Alice", "hello, world" },
      { 2, 'Bob "the" builder', nil },
    },
    row_count = 2,
  }
  return vim.tbl_extend("force", base, overrides or {})
end

--- What the exporter derives from the body / tab, not from the result.
local function info(overrides)
  return vim.tbl_extend("force", { table_name = "users", schema = "public", dialect = "postgres" },
    overrides or {})
end

describe("export format_csv", function()
  it("writes header row", function()
    local out = export._test.format_csv(data_result())
    assert.equals("id,name,bio", out:sub(1, string.find(out, "\n") - 1))
  end)

  it("emits one line per row", function()
    local lines = vim.split(export._test.format_csv(data_result()), "\n")
    assert.same({ "id,name,bio", "1,Alice,\"hello, world\"", '2,"Bob ""the"" builder",' }, lines)
  end)

  it("quotes fields containing comma, quote or newline", function()
    local out = export._test.format_csv(data_result({ rows = { { "a,b", 'c"d', "e\nf" } } }))
    assert.equals('id,name,bio\n"a,b","c""d","e\nf"', out)
  end)

  it("renders nil cells as empty fields", function()
    local out = export._test.format_csv(data_result({ rows = { { nil, "", nil } } }))
    assert.equals("id,name,bio\n,,", out)
  end)

  it("quotes fields containing a bare carriage return", function()
    -- a bare CR inside an unquoted field corrupts the record structure,
    -- same as a bare newline would
    local out = export._test.format_csv(data_result({ rows = { { "a\rb" } } }))
    assert.equals('id,name,bio\n"a\rb",,', out)
  end)

  it("encodes a JSON/JSONB cell as its JSON, not as a table address", function()
    -- A jsonb column reaches Lua as a decoded table; tostring on it is the
    -- pointer spelling the renderer and the cell yank already avoid.
    local out = export._test.format_csv(data_result({ rows = { { 1, { tags = { "a", "b" } } } } }))
    assert.equals('id,name,bio\n1,"{""tags"":[""a"",""b""]}",', out)
  end)
end)

describe("export format_tsv", function()
  it("separates cells with tabs and writes header", function()
    local out = export._test.format_tsv(data_result({ columns = { { name = "a" }, { name = "b" } }, rows = { { "x", 5 } } }))
    assert.equals("a\tb\nx\t5", out)
  end)

  it("replaces tabs, newlines and carriage returns in cells with spaces", function()
    local out = export._test.format_tsv(data_result({ columns = { { name = "a" } }, rows = { { "l1\nl2" }, { "t\tab" }, { "c\rd" } } }))
    assert.equals("a\nl1 l2\nt ab\nc d", out)
  end)

  it("flattens the same bytes in a column name", function()
    local out = export._test.format_tsv(
      data_result({ columns = { { name = "a\tb" } }, rows = { { "x" } } }))
    assert.equals("a b\nx", out)
  end)

  it("renders a JSON/JSONB header cell as its JSON, not a table address", function()
    -- header names are strings in practice, but the shape reaches the same
    -- export_val seam the values do — a table must not render as `table: 0x…`
    local out = export._test.format_tsv(
      data_result({ columns = { { name = { a = 1 } } }, rows = { { "x" } } }))
    assert.equals('{"a":1}\nx', out)
  end)
end)

describe("export format_json", function()
  it("encodes rows as an array of objects keyed by column", function()
    local out = export._test.format_json(data_result())
    local parsed = vim.json.decode(out)
    assert.same({
      { id = 1, name = "Alice", bio = "hello, world" },
      { id = 2, name = 'Bob "the" builder' },
    }, parsed)
  end)

  it("keeps duplicate result columns as suffixed keys instead of dropping them", function()
    -- Regression: `SELECT a.id, b.id FROM a JOIN b` used to export as
    -- [{"id":2}] — one JSON key slot, last write won, the first column's
    -- values silently gone. CSV and the SQL exporter keep both columns.
    local out = export._test.format_json({
      columns = { { name = "id" }, { name = "id" } },
      rows = { { 1, 2 } },
    })
    assert.same({ { id = 1, id_2 = 2 } }, vim.json.decode(out))
  end)

  it("keeps a JSON null column name from becoming the key 'vim.NIL'", function()
    -- tostring(vim.NIL) names the key "vim.NIL" and merges two such columns
    -- into one. The real binary never sends null names; a hand-built
    -- response should still export with an empty-string key.
    local out = export._test.format_json({
      columns = { { name = vim.NIL }, { name = vim.NIL } },
      rows = { { 1, 2 } },
    })
    assert.same({ { [""] = 1, ["_2"] = 2 } }, vim.json.decode(out))
  end)
end)

describe("export format_markdown", function()
  it("builds a pipe table with header separator row", function()
    local out = export._test.format_markdown(data_result())
    local lines = vim.split(out, "\n")
    assert.equals("| id | name | bio |", lines[1])
    assert.equals("| --- | --- | --- |", lines[2])
    assert.equals("| 1 | Alice | hello, world |", lines[3])
  end)

  it("escapes pipe characters in cell values", function()
    local out = export._test.format_markdown(data_result({ columns = { { name = "a" } }, rows = { { "x|y" } } }))
    assert.equals("| a |\n| --- |\n| x\\|y |", out)
  end)

  it("renders newlines inside a cell as <br> so the row stays one line", function()
    -- a raw newline split the pipe-table row and every row below stopped
    -- being a row — the same break csv_escape quotes and tsv flattens
    local out = export._test.format_markdown(
      data_result({ columns = { { name = "a" } }, rows = { { "line1\nline2\r\nline3" } } }))
    assert.equals("| a |\n| --- |\n| line1<br>line2<br>line3 |", out)
  end)

  it("escapes a pipe in a COLUMN NAME, not just in a value", function()
    -- `a|b` is a legal quoted column name; the header row was written raw, so
    -- the exported table had one more column than the separator row and every
    -- data row lined up under the wrong header.
    local out = export._test.format_markdown(
      data_result({ columns = { { name = "a|b" }, { name = "c" } }, rows = { { "x", "y" } } }))
    assert.equals("| a\\|b | c |\n| --- | --- |\n| x | y |", out)
  end)

  it("escapes a newline in a column name the same way", function()
    local out = export._test.format_markdown(
      data_result({ columns = { { name = "l1\nl2" } }, rows = { { "x" } } }))
    assert.equals("| l1<br>l2 |\n| --- |\n| x |", out)
  end)
end)

describe("export format_sql_insert", function()
  it("emits INSERT with qualified quoted table and columns", function()
    local out = export._test.format_sql_insert(data_result(), info())
    local lines = vim.split(out, "\n")
    assert.equals('INSERT INTO "public"."users" ("id", "name", "bio") VALUES (1, \'Alice\', \'hello, world\');', lines[1])
    assert.equals('INSERT INTO "public"."users" ("id", "name", "bio") VALUES (2, \'Bob "the" builder\', NULL);', lines[2])
  end)

  it("uses the quoted table name without schema when schema is empty", function()
    local out = export._test.format_sql_insert(data_result(), info({ schema = "" }))
    assert.matches('^INSERT INTO "users" ', out)
  end)

  it("escapes single quotes in string values", function()
    local out = export._test.format_sql_insert(
      data_result({ columns = { { name = "a" } }, rows = { { "it's" } } }), info())
    assert.equals("INSERT INTO \"public\".\"users\" (\"a\") VALUES ('it''s');", out)
  end)

  it("renders booleans as TRUE/FALSE", function()
    local out = export._test.format_sql_insert(
      data_result({ columns = { { name = "a" } }, rows = { { true }, { false } } }), info())
    assert.equals("INSERT INTO \"public\".\"users\" (\"a\") VALUES (TRUE);\nINSERT INTO \"public\".\"users\" (\"a\") VALUES (FALSE);", out)
  end)

  it("quotes identifiers with mysql backticks", function()
    local out = export._test.format_sql_insert(
      data_result({ columns = { { name = "a" } }, rows = { { 1 } } }), info({ dialect = "mysql" }))
    assert.equals("INSERT INTO `public`.`users` (`a`) VALUES (1);", out)
  end)

  it("falls back to a plain export table when the dataset names none", function()
    local out = export._test.format_sql_insert(
      data_result({ columns = { { name = "a" } }, rows = { { 1 } } }), {})
    assert.equals('INSERT INTO "export" ("a") VALUES (1);', out)
  end)
end)

describe("export sql_escape_val", function()
  it("turns nil into NULL", function()
    assert.equals("NULL", export._test.sql_escape_val(nil))
    assert.equals("NULL", export._test.sql_escape_val(vim.NIL))
  end)

  it("keeps numbers literal and booleans as TRUE/FALSE", function()
    assert.equals("42", export._test.sql_escape_val(42))
    assert.equals("TRUE", export._test.sql_escape_val(true))
    assert.equals("FALSE", export._test.sql_escape_val(false))
  end)

  it("writes a JSON/JSONB cell as a JSON string literal", function()
    -- tostring would put the table address in the statement
    assert.equals('\'{"tags":["a","b"]}\'', export._test.sql_escape_val({ tags = { "a", "b" } }))
  end)

  it("escapes quotes; control bytes stay raw outside postgres", function()
    assert.equals("'a''b'", export._test.sql_escape_val("a'b"))
    -- mysql/sqlite: no dialect interprets \xHH in a regular literal, so the
    -- raw byte is the only round-tripping form
    assert.equals("'a\1b'", export._test.sql_escape_val("a\1b", "mysql"))
    assert.equals("'a\27b'", export._test.sql_escape_val("a\27b", "sqlite"))
  end)

  it("postgres control bytes use the E'' prefix with \\xHH escapes", function()
    assert.equals("E'a\\x1Bb'", export._test.sql_escape_val("a\27b", "postgres"))
    assert.equals("E'\\x00'", export._test.sql_escape_val(string.char(0), "postgres"))
    -- a plain value keeps the plain literal (no E'' unless needed)
    assert.equals("'a''b'", export._test.sql_escape_val("a'b", "postgres"))
  end)

  it("backslashes in the value survive the dialects that read them as escapes", function()
    -- mysql/clickhouse honor \ inside ordinary literals: un-doubled, an
    -- exported C:\path would import back as C: + TAB + ath
    assert.equals("'C:\\\\path'", export._test.sql_escape_val("C:\\path", "mysql"))
    assert.equals("'C:\\\\path'", export._test.sql_escape_val("C:\\path", "clickhouse"))
    -- sqlite keeps literals verbatim — doubling there would corrupt data
    assert.equals("'C:\\path'", export._test.sql_escape_val("C:\\path", "sqlite"))
    -- postgres standard literals too (standard_conforming_strings)
    assert.equals("'C:\\path'", export._test.sql_escape_val("C:\\path", "postgres"))
    -- inside an E'' literal the value's own backslashes must double as well
    assert.equals("E'C:\\\\data\\x07'", export._test.sql_escape_val("C:\\data\7", "postgres"))
  end)
end)

describe("export generate_filename", function()
  it("prefixes with the dataset table name and appends extension", function()
    local name = export._test.generate_filename({ table_name = "users" }, ".csv")
    assert.matches("^users_%d%d%d%d%d%d%d%d_%d%d%d%d%d%d%.csv$", name)
  end)

  it("falls back to export prefix when no table name", function()
    local name = export._test.generate_filename({}, ".json")
    assert.matches("^export_%d%d%d%d%d%d%d%d_%d%d%d%d%d%d%.json$", name)
  end)

  it("tolerates a missing info table", function()
    local name = export._test.generate_filename(nil, ".md")
    assert.matches("^export_", name)
  end)

  it("neutralizes path separators in a schema-qualified table name", function()
    local name = export._test.generate_filename({ table_name = "data/tmp" }, ".csv")
    assert.matches("^data_tmp_%d%d%d%d%d%d%d%d_%d%d%d%d%d%d%.csv$", name)
  end)

  it("degrades a non-string table_name to the export prefix instead of crashing", function()
    -- A hand-built tab (or a future caller) with a numeric table_name used to
    -- reach `:gsub` on a number and kill the whole export; the str() gate now
    -- counts it absent so the `export` fallback applies.
    local name = export._test.generate_filename({ table_name = 42 }, ".csv")
    assert.matches("^export_", name)
  end)
end)

describe("export get_current_data (response shape wiring)", function()
  local dataset = require("poste-db.dataset")
  local saved_tabs, saved_idx

  before_each(function()
    saved_tabs, saved_idx = dataset.tabs, dataset.active_tab_idx
  end)
  after_each(function()
    dataset.tabs, dataset.active_tab_idx = saved_tabs, saved_idx
  end)

  -- The shape sql_runner/response.lua actually builds: identity fields on the
  -- body, results[1] carrying nothing but columns/rows.
  local function tab_from(body, layout, meta)
    dataset.active_tab_idx = 1
    dataset.tabs = { [1] = { data = body, layout = layout, meta = meta } }
  end

  it("reads table name and dialect off the response body", function()
    tab_from({
      type = "resultset",
      results = { { columns = { { name = "id" } }, rows = { { 1 } } } },
      table_name = "authors",
      dialect = "mysql",
    }, {}, {})
    local result, got = export._test.get_current_data()
    assert.equals(1, result.rows[1][1])
    assert.same({ table_name = "authors", schema = nil, dialect = "mysql" }, got)
  end)

  it("falls back to the tab meta and layout, and JSON null away", function()
    tab_from({
      type = "resultset",
      results = { { columns = {}, rows = {} } },
      table_name = vim.NIL,
      dialect = vim.NIL,
    }, { table_name = "layout_tbl", dialect = "sqlite", schema = "main" }, { table_name = "meta_tbl" })
    local _, got = export._test.get_current_data()
    assert.same({ table_name = "meta_tbl", schema = "main", dialect = "sqlite" }, got)
  end)

  it("names the source table in the generated INSERT, not `export`", function()
    tab_from({
      type = "resultset",
      results = { { columns = { { name = "id" } }, rows = { { 7 } } } },
      table_name = "authors",
      dialect = "mysql",
    }, {}, {})
    local result, current = export._test.get_current_data()
    assert.equals("INSERT INTO `authors` (`id`) VALUES (7);",
      export._test.format_sql_insert(result, current))
  end)

  it("renders a numeric identity field as text instead of passing it through", function()
    -- The str() gate: strings pass, numbers render, tables count as absent so
    -- the fallback chain (meta, layout, dialect default) gets its turn — one
    -- hand-built tab must not reach `:gsub`/`..` with a number.
    tab_from({
      type = "resultset",
      results = { { columns = { { name = "id" } }, rows = { { 1 } } } },
      table_name = 42,
      dialect = "mysql",
    }, {}, {})
    local _, got = export._test.get_current_data()
    assert.same({ table_name = "42", schema = nil, dialect = "mysql" }, got)
  end)

  it("counts a table-typed identity field as absent", function()
    tab_from({
      type = "resultset",
      results = { { columns = { { name = "id" } }, rows = { { 1 } } } },
      table_name = { "not", "a", "name" },
    }, { table_name = "layout_tbl" }, {})
    local _, got = export._test.get_current_data()
    assert.same({ table_name = "layout_tbl", schema = nil, dialect = "postgres" }, got)
  end)
end)

describe("export complete", function()
  it("offers formats first", function()
    local formats = export.complete("", "")
    assert.same({ "csv", "tsv", "json", "md", "sql" }, formats)
  end)

  it("matches the format prefix mid-word — the shape vim really passes", function()
    -- `:PosteDbExport cs<Tab>`: CmdLine carries the command name plus the word
    -- under the cursor. The old word-count read this as the destination slot
    -- and returned nothing (or completed `clipboard` into the format slot).
    assert.same({ "csv" }, export.complete("cs", "PosteDbExport cs"))
    assert.same({ "csv" }, export.complete("csv", "PosteDbExport csv"))
  end)

  it("offers destinations once the format is terminated by a space", function()
    -- a trailing space means the cursor starts the NEXT (destination) argument
    assert.same({ "clipboard", "file" }, export.complete("", "PosteDbExport csv "))
    assert.same({ "file" }, export.complete("f", "PosteDbExport csv f"))
  end)

  it("falls back to filename completion only from the third argument on", function()
    -- path completion calls vim.fn.getcompletion; a lead nothing in this cwd
    -- matches pins the DISPATCH (file lookup reached, destination list not)
    assert.same(vim.fn.getcompletion("zz_", "file"), export.complete("zz_", "PosteDbExport csv clipboard zz_"))
  end)

  it("matches the prefix plainly — a magic ArgLead neither errors nor fuzzy-matches", function()
    assert.same({}, export.complete("%", ""))
    assert.same({ "csv" }, export.complete("cs", ""))
    -- "sv" is a substring of csv but not a prefix
    assert.same({}, export.complete("sv", ""))
  end)
end)

describe("export run", function()
  local dataset = require("poste-db.dataset")

  -- The system clipboard is shared machine state. `provider#clipboard` shells
  -- out to pbcopy/pbpaste on every access, so any other process that writes in
  -- between the two calls wins: with 12 headless Neovims each setting a unique
  -- value and reading it straight back, 11 read someone else's. That is why
  -- this file reported 34/0 on its own and 33/1 (this case) inside the 95-file
  -- suite. g:clipboard is consulted on every access, unlike the once-loaded
  -- builtin provider, so this in-process provider takes over no matter what
  -- touched "+" earlier.
  local prev_clipboard
  local copied

  before_each(function()
    prev_clipboard = vim.g.clipboard
    copied = {}
    local function copy(reg)
      return function(lines)
        copied[reg] = lines
        return 0
      end
    end
    local function paste(reg)
      return function()
        return copied[reg] or { "" }
      end
    end
    vim.g.clipboard = {
      name = "poste-db-spec",
      copy = { ["+"] = copy("+"), ["*"] = copy("*") },
      paste = { ["+"] = paste("+"), ["*"] = paste("*") },
    }
  end)

  after_each(function()
    dataset.tabs = {}
    dataset.active_tab_idx = 0
    vim.g.clipboard = prev_clipboard
  end)

  --- The fake provider stores the line list the exporter handed to setreg().
  local function clipboard(reg)
    return table.concat(copied[reg or "+"] or {}, "\n")
  end

  local function install_tab()
    dataset.tabs[1] = {
      meta = {},
      data = {
        type = "resultset",
        results = {
          {
            columns = { { name = "id" }, { name = "name" } },
            rows = { { 1, "Alice" } },
            row_count = 1,
          },
        },
      },
    }
    dataset.active_tab_idx = 1
    return dataset.tabs[1]
  end

  it("writes the file when a path is given (command form)", function()
    install_tab()
    local out = vim.fn.tempname() .. "/out/users.csv"
    export.run("csv", "file", out)
    assert.equals(1, vim.fn.filereadable(out))
    local lines = vim.fn.readfile(out)
    assert.equals("id,name", lines[1])
    assert.equals("1,Alice", lines[2])
    -- The documented behaviour is that a file export leaves the absolute path
    -- on the clipboard, not the payload.
    assert.equals(vim.fn.fnamemodify(out, ":p"), clipboard())
    assert.equals("", clipboard("*"))
  end)

  it("copies to the clipboard for destination=clipboard", function()
    install_tab()
    export.run("csv", "clipboard")
    assert.equals("id,name\n1,Alice", clipboard())
    -- The unnamed register gets the same text, so a paste in the result buffer
    -- works even where no system clipboard tool exists.
    assert.equals("id,name\n1,Alice", vim.fn.getreg('"'))
  end)

  it("exports only the first result set", function()
    local tab = install_tab()
    tab.data.results[1].columns = { { name = "x" } }
    tab.data.results[1].rows = { { "only" } }
    local out = vim.fn.tempname() .. "/out2/users.csv"
    export.run("csv", "file", out)
    assert.equals("x\nonly", table.concat(vim.fn.readfile(out), "\n"))
  end)
end)