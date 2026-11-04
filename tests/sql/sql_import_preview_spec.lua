-- The import preview is the only place a user sees what an import will do, and
-- nothing pinned its layout. show_preview only ever *displays* — the choices
-- come from keymaps fired later — so stubbing the dialog is enough to capture
-- the rendered lines and their highlights.

local captured

local function load_module()
  package.loaded["poste-db.import.preview"] = nil
  package.loaded["poste-db.dialog"] = {
    open = function(opts)
      captured.dialog_opts = opts
      local d = {}
      function d:update(lines, highlights)
        captured.lines = lines
        captured.highlights = highlights or {}
      end
      function d:close() captured.closed = true end
      return d
    end,
  }
  return require("poste-db.import.preview")
end

-- Three shapes a mapped column can have: a primary key, a nullable column the
-- file names differently, and a NOT NULL column with no default.
local function mapped_columns()
  return {
    { import_idx = 1, import_name = "id", table_idx = 1,
      table_col = { name = "id", col_type = "int", is_pk = true, nullable = false, default = nil } },
    { import_idx = 2, import_name = "label", table_idx = 2,
      table_col = { name = "name", col_type = "text", is_pk = false, nullable = true, default = nil } },
    { import_idx = 3, import_name = "mail", table_idx = 3,
      table_col = { name = "email", col_type = "text", is_pk = false, nullable = false, default = nil } },
  }
end

--- Render through show_preview and return what the dialog received.
local function render(overrides)
  local preview = load_module()
  local o = overrides or {}
  preview.show_preview(
    o.table_info or { schema = "public", name = "users", connection = "c1", dialect = "postgres" },
    o.total_rows or 4,
    o.valid_count or 3,
    o.bad_rows or {},
    o.col_map or mapped_columns(),
    o.unmatched_import or {},
    o.unmatched_table or {},
    o.parsed_cols or { "id", "label", "mail" },
    o.parsed_rows or { { "1", "a", "x" }, { "2", "b", "y" }, { "3", "c", "z" }, { "4", "d", "w" } },
    function() end
  )
  return captured.lines, captured.highlights
end

-- The mapping table shifts down when the data preview above it grows, so lines
-- are located by content. Returns the 1-based index and the line itself.
local function find_line(lines, pattern)
  for i, line in ipairs(lines) do
    if line:match(pattern) then return i, line end
  end
  error("no line matches " .. pattern, 2)
end

local function groups_at(highlights, line_1based)
  local groups = {}
  for _, h in ipairs(highlights) do
    if h.line == line_1based - 1 then table.insert(groups, h.hl_group) end
  end
  return groups
end

describe("import preview rendering", function()
  before_each(function()
    captured = {}
  end)

  it("shows the table, the counts and the column mapping", function()
    local lines = render()
    assert.matches("public%.users", lines[1])
    assert.equals("Parsed: 4 rows total, 3 valid, 0 with errors", lines[find_line(lines, "^Parsed: ")])

    -- The mapping is a two-column table: the name as the file spells it, and
    -- the column it lands on with its type. "label" is not a table column, so
    -- a row showing it proves the file side survived the mapping.
    assert.matches("^  file%s+%| table%s*$", select(2, find_line(lines, "^  file")))
    assert.matches("^  label%s+%| name %(text%)%s*$", select(2, find_line(lines, "^  label")))
  end)

  it("previews three rows and says how many were left out", function()
    local lines = render()
    local header = find_line(lines, "^  id%s+%| label")
    local data_rows = 0
    for i = header + 2, #lines do
      if lines[i]:match("^  %d") then data_rows = data_rows + 1 end
    end
    assert.equals(3, data_rows)
    assert.equals("  ... (1 more row(s))", lines[find_line(lines, "more row")])
  end)

  it("renders an empty cell as NULL rather than a blank field", function()
    local lines = render({
      parsed_rows = { { "1", nil, "x" }, { "2", "b", "y" } },
      total_rows = 2, valid_count = 2,
    })
    assert.matches("^  1%s+%| NULL%s+%| x", select(2, find_line(lines, "^  1")))
  end)

  it("marks a table column the file does not supply as default-filled", function()
    local lines = render({ unmatched_table = { { name = "created_at" } } })
    assert.equals("  (missing: created_at <- DEFAULT)", lines[find_line(lines, "missing")])
  end)

  it("lists file columns that found no table column", function()
    -- import.lua blocks on unmatched file columns before reaching the preview,
    -- so this line is the renderer's contract rather than a reachable screen:
    -- if that policy softens, the preview must not hide the mismatch.
    local lines = render({ unmatched_import = { "extra_col" } })
    assert.equals("  (unmatched: extra_col)", lines[find_line(lines, "unmatched")])
  end)

  it("shows the validation errors under the mapping", function()
    local lines = render({
      bad_rows = { { row_idx = 2, import_row = { "", "x" },
        errors = { "  2: primary key column 'id' cannot be null" } } },
    })
    local err_idx = find_line(lines, "^Validation errors:")
    assert.equals("  2: primary key column 'id' cannot be null", lines[err_idx + 1])
  end)

  describe("highlights", function()
    it("colors the error count only when rows actually failed", function()
      local clean_lines, clean_hl = render()
      for _, group in ipairs(groups_at(clean_hl, find_line(clean_lines, "^Parsed: "))) do
        assert.is_not.equals("DiagnosticError", group)
      end

      local dirty_lines, dirty_hl = render({
        bad_rows = { { row_idx = 2, import_row = { "", "x" },
          errors = { "  2: primary key column 'id' cannot be null" } } },
      })
      local saw = false
      for _, group in ipairs(groups_at(dirty_hl, find_line(dirty_lines, "^Parsed: "))) do
        if group == "DiagnosticError" then saw = true end
      end
      assert.is_true(saw)
    end)

    it("warns on a NOT NULL column with no default, not on a nullable or key one", function()
      local lines, hl = render()
      local mail_row = find_line(lines, "^  mail%s+%| email %(text%)")
      local label_row = find_line(lines, "^  label")
      local id_row = find_line(lines, "^  id%s+%| id %(int%)")

      -- email is NOT NULL with no default, so the file has to fill it; "name"
      -- is nullable and "id" is a key, so neither is worth a warning.
      local mail_warned = false
      for _, group in ipairs(groups_at(hl, mail_row)) do
        if group == "DiagnosticWarn" then mail_warned = true end
      end
      assert.is_true(mail_warned)
      assert.equals(0, #groups_at(hl, label_row))
      assert.equals(0, #groups_at(hl, id_row))
    end)
  end)
end)

describe("import preview answering", function()
  before_each(function() captured = {} end)

  -- The layout stub above never closes; these tests need the real dialog
  -- contract: close() fires on_close (what q/<Esc>/WinLeave all funnel into).
  local function load_real_contract()
    package.loaded["poste-db.import.preview"] = nil
    package.loaded["poste-db.dialog"] = {
      open = function(opts)
        captured.dialog_opts = opts
        local d = {}
        function d:update() end
        function d:close()
          captured.closed = true
          if opts.on_close then opts.on_close() end
        end
        return d
      end,
    }
    return require("poste-db.import.preview")
  end

  local function show(preview, callback)
    preview.show_preview(
      { schema = "public", name = "users", connection = "c1", dialect = "postgres" },
      4, 3, {}, mapped_columns(), {}, {}, { "id", "label", "mail" },
      { { "1", "a", "x" } }, callback)
  end

  it("closing without a choice (q/Esc/WinLeave) answers nil", function()
    -- regression: dialog.open's own q/<Esc> keymaps and the WinLeave fallback
    -- close through on_close, which the preview never passed — Esc ended the
    -- whole import with no callback and no "Import cancelled" notice.
    local preview = load_real_contract()
    local n, first = 0, "unset"
    show(preview, function(a)
      n = n + 1
      first = a
    end)
    captured.dialog_opts.on_close()
    vim.wait(50, function() return n > 0 end)
    assert.equals(1, n)
    assert.is_nil(first)
  end)

  it("a keymap answer wins over the close-time nil", function()
    -- The keymaps close first, so on_close fires before their own answer: the
    -- scheduled nil must lose to the synchronous choice, not overwrite it.
    local preview = load_real_contract()
    local n, first = 0, nil
    show(preview, function(a)
      n = n + 1
      first = a
    end)
    captured.dialog_opts.keymaps.p()
    vim.wait(50, function() return n > 0 end)
    assert.equals(1, n)
    assert.equals("proceed", first)
  end)
end)
