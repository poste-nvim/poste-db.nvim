--- `clean_nil` / `find_file_upwards` / `ensure_job_data` are merged from
--- poste.nvim@5b3759e lua/poste/util.lua (family dissolution).
local M = {}

local width = require("poste-db.width")

function M.utf8_char_bytes(byte)
  if byte < 0x80 then return 1 end
  if byte < 0xE0 then return 2 end
  if byte < 0xF0 then return 3 end
  return 4
end

function M.is_dark_color(color)
  if not color then return true end
  local r = math.floor(color / 0x10000) % 0x100 / 255
  local g = math.floor(color / 0x100) % 0x100 / 255
  local b = color % 0x100 / 255
  return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
end

--- Fit `s` into `max` display cells, appending "..." when it had to cut.
--- Never splits a UTF-8 character and counts CJK at their real width, so a
--- label or confirm snippet with non-ASCII text stays inside its budget on
--- screen instead of overflowing (byte length) or splitting mid-glyph.
--- @param s string|nil
--- @param max number
--- @return string
function M.ellipsize(s, max)
  s = s or ""
  if width.display_width(s) <= max then return s end
  if max <= 3 then return width.truncate(s, max) end
  return width.truncate(s, max - 3) .. "..."
end

--- Truncate at a BYTE budget without splitting a UTF-8 character: the cut
--- point backs up over continuation bytes. (No ellipsis appended.) A plain
--- `sub` cut emitted invalid UTF-8 whenever the budget landed inside a CJK
--- character — schema summaries and AI context blocks are routinely CJK.
function M.utf8_safe_cut(s, max_bytes)
  -- Coerced like width's helpers: a value that arrives as a number or a
  -- decoded JSON null measured fine everywhere else and then raised on `#s`
  -- at the cut.
  if s == nil or s == vim.NIL then return "" end
  if type(s) ~= "string" then s = tostring(s) end
  if max_bytes <= 0 then return "" end
  if #s <= max_bytes then return s end
  local cut = max_bytes
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end -- not a continuation byte
    cut = cut - 1
  end
  return s:sub(1, cut)
end

--- Strip one MATCHING pair of identifier quotes (backtick or double quote)
--- from `s`. Names that merely end in a quote character (`a"`) stay
--- verbatim, so a table genuinely named `a"` is not rewritten. Detect
--- responses (`poste context detect`) carry the source spelling of a name —
--- `` `users` `` from a MySQL buffer — and every caller that MATCHES those
--- names against a bare cword needs the quoted form gone first.
--- @param s string|nil
--- @return string
function M.unquote_ident(s)
  if not s then return "" end
  local q = s:sub(1, 1)
  if (q == "`" or q == '"') and #s >= 2 and s:sub(-1) == q then
    return s:sub(2, -2)
  end
  return s
end

--- A name that names something: a non-empty string, or nil. Any value of any
--- other type counts as absent, so a hostile or hand-built table cannot reach
--- `..` as a number or a table.
--- The empty string is the interesting case, and it is not a name: the SQL
--- response envelope normalises an unknown connection/database to `""`
--- (`exec_run.lua`'s `conn or ""`, `shown_db or ""`), and a failed execution
--- carries that into `state.context`, the last error and the AI chat scope.
--- Readers that tested only for nil took the empty string for a target: the
--- system prompt told the model the chat was "scoped to connection " with
--- nothing after it (and hid the buffer's own context behind it), and a session
--- started with `--database ""` — which the CLI applies as a URL rewrite
--- (`exec_file.rs` / `session.rs`: `replace_database_in_url`), so the statement
--- ran with the database stripped off the connection string. Generated SQL took
--- the same bait: `ops_sql.qualified_table_ref` still joined the empty schema to
--- its separator and emitted `."users"` (a syntax error), and a JSON null name
--- decodes to `vim.NIL`, which is truthy, so it raised in `ident.quote` or at
--- the `..` instead of yielding a statement.
--- `nav_ui`, `sql_runner`, `explain`, `completion/data` and `introspect/table`
--- already test `x ~= ""`; this is that rule with the type check attached, so a
--- site reads once instead of re-deriving which of nil, `""` and `vim.NIL` it
--- has to care about.
--- @param v any
--- @return string|nil
function M.named(v)
  if type(v) ~= "string" or v == "" then return nil end
  return v
end

--- 0-based index just past the identifier run that starts at or after the
--- 0-based cursor column `col`. The "extend the cursor column over the
--- word" scan shared by go-to-definition (nav/handlers) and introspect
--- target detection (introspect/init): both feed the byte offset of the
--- word's end into `poste context detect`.
--- @param line_text string
--- @param col number
--- @return number
function M.scan_word_end(line_text, col)
  local end_col = col or 0
  local len = #line_text
  while end_col < len do
    local ch = line_text:sub(end_col + 1, end_col + 1)
    if ch:match("[%w_]") then end_col = end_col + 1 else break end
  end
  return end_col
end

---------------------------------------------------------------------------
-- Merged from poste.nvim@5b3759e lua/poste/util.lua (family dissolution)
---------------------------------------------------------------------------

--- Recursively remove vim.NIL values from a parsed JSON table.
---
--- `vim.json.decode` converts JSON `null` to `vim.NIL`. This function
--- replaces those values with Lua `nil` so they can be safely compared
--- with `== nil`. It mutates the table in place and also returns it.
---
--- @param t table|nil  A table from vim.json.decode, or nil
--- @return table|nil    The same table with vim.NIL values removed, or nil
function M.clean_nil(t)
  if not t or type(t) ~= "table" then return t end
  for k, v in pairs(t) do
    if v == vim.NIL then
      t[k] = nil
    elseif type(v) == "table" then
      M.clean_nil(v)
    end
  end
  return t
end

--- Walk up the directory tree from `start_dir` to find a file.
--- Checks each ancestor directory for the given filename, stopping at
--- the filesystem root. Returns the first matching absolute path, or nil.
---
--- @param filename  string  File name to search for (e.g. "env.json")
--- @param start_dir string  Directory to start searching from
--- @return string|nil       Absolute path to the found file, or nil
function M.find_file_upwards(filename, start_dir)
  if not filename or filename == "" then return nil end
  local dir = start_dir or vim.fn.getcwd()
  while true do
    local candidate = dir .. "/" .. filename
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

--- A statement's affected-row count as the response envelope carries it: a
--- number, or nil for "the statement returned no rows and changed nothing"
--- (a SELECT has no count at all). JSON null decodes to the truthy `vim.NIL`,
--- which every consumer would otherwise read as "something was affected", and
--- a count that arrives as a string (`"3"`) is a count.
--- Shared by exec_run's and session_conn's response builders so the two
--- transports cannot disagree about what "no count" looks like.
--- @param v any
--- @return number|nil
function M.affected_rows(v)
  if v == nil or v == vim.NIL then return nil end
  return tonumber(v)
end

--- Given an array of lines from a job's stdout/stderr callback, remove
--- trailing empty strings. Neovim's jobstart callbacks often include
--- one or more trailing empty strings; this is a safe normalizer.
---
--- Returns the same array (mutated in place) with trailing empties
--- removed, for consistency with existing calling conventions.
---
--- @param data string[]|nil  Lines from a job callback
--- @return string[]          Cleaned array (may be empty)
function M.ensure_job_data(data)
  if not data or type(data) ~= "table" then return {} end
  while #data > 0 and data[#data] == "" do
    data[#data] = nil
  end
  return data
end

return M
