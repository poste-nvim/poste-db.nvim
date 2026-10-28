--- SQL directive comment highlighter.
--- Only handles -- @connection / @database / @protocol highlighting.
--- SQL keyword/type/function highlighting is handled by Tree-sitter
--- via after/queries/poste_sql/highlights.scm.

local M = {}
local const = require("poste-db.constants")
-- `dialect_mod`, not `dialect`: two functions below take a `dialect`
-- parameter and would shadow the module binding.
local dialect_mod = require("poste-db.dialect")

local _hl_setup_done = false

local function ensure_hl()
  if _hl_setup_done then return end
  _hl_setup_done = true
  vim.api.nvim_set_hl(0, "PosteDbSqlDirective", { fg = "#D19A66", bold = true })
  vim.api.nvim_set_hl(0, "PosteDbSqlDirectiveValue", { fg = "#E5C07B" })
  vim.api.nvim_set_hl(0, "PosteDbSqlDirectiveComment", { link = "Special" })
end

local DIRECTIVE_NS = vim.api.nvim_create_namespace("poste_db_directive")
local DIRECTIVE_KEYWORDS = {
  const.DIRECTIVE_CONNECTION,
  const.DIRECTIVE_DATABASE,
  const.DIRECTIVE_PROTOCOL,
}

--- Highlight -- @connection / @database / @protocol lines using extmarks.
--- Uses priority 101-102 (> Tree-sitter's default 100) to override
--- the comment highlighting from after/queries/poste_sql/highlights.scm.
function M.highlight_directive_comments(buf)
  ensure_hl()
  buf = buf or 0
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  vim.api.nvim_buf_clear_namespace(buf, DIRECTIVE_NS, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    for _, dir in ipairs(DIRECTIVE_KEYWORDS) do
      local dstart, dend = line:find("^--%s*@" .. dir)
      if dstart then
        vim.api.nvim_buf_set_extmark(buf, DIRECTIVE_NS, i - 1, 0, {
          end_col = dend, hl_group = "PosteDbSqlDirectiveComment", priority = 101,
        })
        vim.api.nvim_buf_set_extmark(buf, DIRECTIVE_NS, i - 1, dstart - 1, {
          end_col = dend, hl_group = "PosteDbSqlDirective", priority = 102,
        })
        local vstart, vend = line:find("%S.*$", dend + 1)
        if vstart then
          vim.api.nvim_buf_set_extmark(buf, DIRECTIVE_NS, i - 1, vstart - 1, {
            end_col = vend, hl_group = "PosteDbSqlDirectiveValue", priority = 102,
          })
        end
        break
      end
    end
  end
end

local DIGIT_PREFIX_NS = vim.api.nvim_create_namespace("poste_db_digit_fragment")

--- Resolve the connection dialect for a buffer (lowercase), or nil.
--- The single implementation lives in dialect.lua — this was one of three
--- drifting copies.
--- @param buf number  buffer handle
--- @return string|nil
local function get_dialect(buf)
  return dialect_mod.dialect_for_buf(buf)
end

--- tree-sitter-sql splits digit-leading identifiers (`123_abc`) into
--- ERROR[123] + identifier[_abc]; the ERROR fragment inherits nvim-treesitter's
--- @error color while `_abc` renders as a table name (@type). For MySQL/MariaDB
--- (where digit-leading unquoted identifiers are legal) recolor the fragment
--- with the @type group so the name renders as one token.
--- Geometry rule: ERROR text is pure digits AND its next sibling's first leaf
--- is an identifier starting exactly where the ERROR ends. `234 _tablename`
--- has a whitespace gap → untouched (it is a standalone all-digit name, illegal
--- even in MySQL). Non-mysql dialects keep the red @error signal; unknown
--- dialect (nil) is conservative and keeps it too.
--- @param buf number  Buffer handle
--- @param dialect string|nil  Optional dialect override (lowercase); nil
---   resolves via connection context.
function M.highlight_digit_prefix_fragments(buf, dialect)
  ensure_hl()
  buf = buf or 0
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  vim.api.nvim_buf_clear_namespace(buf, DIGIT_PREFIX_NS, 0, -1)
  dialect = dialect or get_dialect(buf)
  if dialect ~= "mysql" and dialect ~= "mariadb" then return end

  local ok_lang, lang = pcall(vim.treesitter.language.get_lang, "sql")
  if not (ok_lang and lang) then return end
  local ok_parse, parser = pcall(vim.treesitter.get_parser, buf, "sql")
  if not ok_parse or not parser then return end
  local ok_trees, trees = pcall(parser.parse, parser)
  if not ok_trees or not trees or #trees == 0 then return end

  local hl = "@type"
  if vim.fn.hlexists("@type") ~= 1 then
    if vim.fn.hlexists("Type") == 1 then
      hl = "Type"
    else
      hl = nil -- no usable group: skip coloring
    end
  end

  local stack = { trees[1]:root() }
  while #stack > 0 do
    local node = table.remove(stack)
    if node:type() == "ERROR" then
      local text = vim.treesitter.get_node_text(node, buf) or ""
      if text:match("^%d+$") then
        local _, _, er, ec = node:range()
        local next_node = node:next_sibling()
        if next_node and hl then
          local first = next_node
          while first:child_count() > 0 do
            first = first:child(0)
          end
          local fsr, fsc = first:range()
          if first:type() == "identifier" and fsr == er and fsc == ec then
            -- MySQL dialect: the ERROR digits are part of the identifier that
            -- follows immediately. Color the whole name like a table.
            local sr, sc = node:range()
            local _, _, fer, fec = first:range()
            pcall(vim.api.nvim_buf_set_extmark, buf, DIGIT_PREFIX_NS, sr, sc, {
              end_row = fer,
              end_col = fec,
              hl_group = hl,
              hl_mode = "combine",
              priority = 300,
            })
          end
        end
      end
    end
    for i = node:child_count() - 1, 0, -1 do
      stack[#stack + 1] = node:child(i)
    end
  end
end

--- SQL keyword highlighting for a single line via extmarks.
--- Used by log_viewer to highlight SQL in detail view.
--- @param buf number  Buffer handle
--- @param ns number   Namespace for extmarks
--- @param line_idx number  Buffer line (1-indexed)
--- @param text string  Text content to highlight (without buffer prefix)
--- @param offset number  Column offset in buffer where text starts
function M.highlight_line(buf, ns, line_idx, text, offset)
  local keywords = {
    "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
    "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "VIEW", "WITH",
    "AND", "OR", "NOT", "NULL", "IN", "AS", "ON", "JOIN", "LEFT", "RIGHT",
    "INNER", "OUTER", "FULL", "CROSS", "GROUP", "BY", "ORDER", "HAVING",
    "LIMIT", "OFFSET", "DISTINCT", "CASE", "WHEN", "THEN", "ELSE", "END",
    "EXISTS", "UNION", "ALL", "BETWEEN", "LIKE", "IS", "TRUE", "FALSE",
    "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CASCADE", "DEFAULT",
    "INTEGER", "INT", "BIGINT", "SMALLINT", "TEXT", "VARCHAR", "CHAR",
    "BOOLEAN", "BOOL", "FLOAT", "DOUBLE", "DECIMAL", "NUMERIC",
    "DATE", "TIMESTAMP", "TIME", "JSON", "JSONB", "SERIAL", "BIGSERIAL",
    "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "CAST",
  }
  local kw_map = {}
  for _, kw in ipairs(keywords) do
    kw_map[kw] = true
  end

  local hl_group = "Statement"
  local i = 1
  while i <= #text do
    local word_start, word_end = text:find("[%w_]+", i)
    if not word_start then break end
    if kw_map[text:sub(word_start, word_end):upper()] then
      vim.api.nvim_buf_set_extmark(buf, ns, line_idx - 1, offset + word_start - 1, {
        end_col = offset + word_end,
        hl_group = hl_group,
        priority = 150,
        hl_mode = "combine",
      })
    end
    i = word_end + 1
  end
end

------------------------------------------------------------------------
--- Re-highlight constructs tree-sitter-sql can't parse.
------------------------------------------------------------------------

local ERROR_CONSTRUCT_NS = vim.api.nvim_create_namespace("poste_db_error_construct")

--- Lowercased markers identifying ERROR nodes that are known false positives
--- (constructs tree-sitter-sql doesn't parse but the user's SQL is valid).
--- Kept in sync with ts_stmt.find_error_nodes' filter list.
local KNOWN_CONSTRUCT_MARKERS = {
  "pragma", "glob", "natural join", "savepoint", "release",
  "explain query plan", "query plan", "values", "or replace", "or ignore",
  "or abort", "or fail", "or rollback", "percentile_", "within group",
  "interval", "separator", "show ",
  "create or replace", "invisible", "collate", "character set",
  "with totals", "array join", "group (order by",
}

local CONSTRUCT_KEYWORDS = {
  PRAGMA = true, GLOB = true, SAVEPOINT = true, RELEASE = true,
  NATURAL = true, EXPLAIN = true, QUERY = true, PLAN = true,
  VALUES = true, INSERT = true, OR = true, INTO = true, BY = true,
  REPLACE = true, ROLLBACK = true, ABORT = true, FAIL = true, IGNORE = true,
  WITHIN = true, GROUP = true, ORDER = true, SELECT = true, FROM = true,
  WHERE = true, JOIN = true, LIMIT = true, AS = true, ASC = true, DESC = true,
  UPDATE = true, SET = true, DELETE = true,
  INTERVAL = true, SEPARATOR = true, SHOW = true,
  OFFSET = true, FETCH = true, NEXT = true, FIRST = true,
  ROWS = true, ONLY = true, JSON = true, XML = true,
  TOTALS = true, ARRAY = true,
  PERCENTILE_CONT = true, PERCENTILE_DISC = true,
  CREATE = true, TABLE = true, SEQUENCE = true, INVISIBLE = true, INT = true,
  PRIMARY = true, KEY = true, AUTO_INCREMENT = true, VARCHAR = true,
  CHAR = true, COLLATE = true, CHARACTER = true,
  IF = true, EXISTS = true,
}

local function hl_err_tokens(buf, row, from_col, to_col)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  if to_col <= from_col then return end
  local seg = line:sub(from_col + 1, to_col)
  local base = from_col
  local i = 1
  while i <= #seg do
    local c = seg:sub(i, i)
    if c == "'" then
      local close = seg:find("'", i + 1, true)
      if close then
        pcall(vim.api.nvim_buf_set_extmark, buf, ERROR_CONSTRUCT_NS, row, base + i - 1, {
          end_col = base + close, hl_group = "String", priority = 300,
        })
        i = close + 1
      else
        i = i + 1
      end
    else
      local ws, we = seg:find("[%w_]+", i)
      if not ws then break end
      local word = seg:sub(ws, we):upper()
      if CONSTRUCT_KEYWORDS[word] then
        vim.api.nvim_buf_set_extmark(buf, ERROR_CONSTRUCT_NS, row, base + ws - 1, {
          end_col = base + we, hl_group = "Statement", priority = 300,
        })
      elseif word:match("^%d") then
        vim.api.nvim_buf_set_extmark(buf, ERROR_CONSTRUCT_NS, row, base + ws - 1, {
          end_col = base + we, hl_group = "Number", priority = 300,
        })
      end
      i = we + 1
    end
  end
end

--- Tree-sitter node types for the `SET` keyword of a DML statement. An
--- unfinished `UPDATE t SET ▮` parses as a root-level ERROR whose SET is a
--- `keyword_set` sibling; a misspelt table (`UPDATE SET users;`) parses
--- `SET users` as a `relation` instead. That difference is what tells
--- "still typing" apart from "wrong".
local DML_SET_NODES = { keyword_set = true, set = true }

--- True when `node` is a DML statement whose clause is still open
--- (`UPDATE t SET ▮`, `UPDATE t SET ▮ WHERE ;`, `INSERT INTO t (a, ▮`,
--- `DELETE FROM t WHERE ▮`): the grammar closes no `statement` around a
--- half-written statement, so nvim paints the line as an error. Red is the
--- wrong signal for "keep typing".
---
--- "Open" means the `SET` is the last thing written before the terminator or
--- the next clause: `UPDATE users SET DEFAULT;` also parses as one ERROR, but
--- DEFAULT is a real mistake there, so it keeps its red.
--- @param node TSNode
--- @param buf number
--- @return boolean
local function is_unfinished_dml(node, buf)
  local verb = nil
  local insert_paren = false
  local set_seen = false
  for c in node:iter_children() do
    local t = c:type()
    -- `;` closes whatever came before it: nothing after the `;` belongs to
    -- this statement, so a SET already seen was left open.
    if t == ";" then return set_seen end
    if verb == nil then
      -- only UPDATE/INSERT/DELETE own a SET clause: `SET NAMES ...` is a
      -- session statement, never an unfinished DML one
      local text = vim.treesitter.get_node_text(c, buf):lower()
      if text ~= "update" and text ~= "insert" and text ~= "delete" then return false end
      verb = text
    elseif t == "keyword" then
      -- a keyword tokenized as plain text means the rest was not recognised:
      -- that is a real error, not an unfinished statement
      return false
    elseif verb == "insert" then
      if t == "(" then insert_paren = true end
    elseif verb == "delete" then
      if t == "keyword_where" then return true end
    elseif DML_SET_NODES[t] then
      set_seen = true
    elseif set_seen then
      -- A clause keyword after SET (`WHERE`) closes an empty SET list, so the
      -- clause was left open.
      if t:match("^keyword_") then return true end
      -- SET followed by the WHERE clause itself. It surfaces as a plain
      -- `identifier` here (the grammar lost the clause while recovering), so
      -- match its text: that is the SET clause being closed, not a value.
      if vim.treesitter.get_node_text(c, buf):lower() == "where" then return true end
      -- SET followed by an assignment/identifier: the SET list has begun.
      return false
    end
  end
  -- the ERROR simply ends after SET (`UPDATE t SET ▮`)
  return set_seen or insert_paren
end

--- Recolors ERROR nodes that are known tree-sitter false positives so they
--- render like normal SQL instead of @error red. nvim's TS highlighter marks
--- every ERROR node red by default; these constructs are valid in their
--- dialect despite not being parseable. A neutral base kills the redness and
--- keywords/strings/numbers inside get their usual groups.
--- Mirrors ts_stmt.find_error_nodes' known-false-positive list.
--- @param buf number  Buffer handle
--- @param dialect string|nil  Optional dialect override (unused, kept for symmetry)
function M.highlight_known_error_constructs(buf, dialect)
  ensure_hl()
  buf = buf or 0
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  vim.api.nvim_buf_clear_namespace(buf, ERROR_CONSTRUCT_NS, 0, -1)

  local ok_lang, lang = pcall(vim.treesitter.language.get_lang, "sql")
  if not (ok_lang and lang) then return end
  local ok_parse, parser = pcall(vim.treesitter.get_parser, buf, "sql")
  if not ok_parse or not parser then return end
  local ok_trees, trees = pcall(parser.parse, parser)
  if not ok_trees or not trees or #trees == 0 then return end

  local stack = { trees[1]:root() }
  while #stack > 0 do
    local node = table.remove(stack)
    if node:type() == "ERROR" then
      local text = vim.treesitter.get_node_text(node, buf) or ""
      local lower = text:lower()
      local known = false
      for _, marker in ipairs(KNOWN_CONSTRUCT_MARKERS) do
        if lower:find(marker, 1, true) then known = true break end
      end
      -- value-fragment cascades from a misparsed VALUES clause (`1, 'a'),`)
      if not known and lower:match("^%d+%s*,") then known = true end
      -- statement-terminator cascades (e.g. `; USE` after a CREATE DATABASE)
      if not known and lower:match("^%s*;") then known = true end
      -- leading-dot fragments (mssql `SELECT TOP (N) alias.column` artifact)
      if not known and lower:match("^%.[%w_]") then known = true end
      -- MySQL/SQLite/ClickHouse `LIMIT 1, 10` pagination: the grammar
      -- strands `, 10` as an ERROR sibling after `limit 1`
      if not known and lower:match("^%s*,%s*%d+%s*;?%s*$") then known = true end
      -- mssql OFFSET-FETCH pagination / FOR JSON-XML tails and the plain
      -- ARRAY JOIN strand (`JOIN <array> ...` after ARRAY became an alias)
      if not known and (lower:match("offset%s*%d+%s*rows")
        or lower:match("fetch%s*next") or lower:match("fetch%s*first")
        or lower:match("for%s+json") or lower:match("for%s+xml")
        or lower:match("^join%s")) then known = true end
      -- A fragment of a statement that is still being typed, so nothing was
      -- parsed wrong (see is_unfinished_dml).
      if not known and is_unfinished_dml(node, buf) then known = true end
      if known then
        local sr, sc, er, ec = node:range()
        pcall(vim.api.nvim_buf_set_extmark, buf, ERROR_CONSTRUCT_NS, sr, sc, {
          end_row = er, end_col = ec, hl_group = "Normal", priority = 250,
        })
        if er == sr then
          hl_err_tokens(buf, sr, sc, ec)
        else
          hl_err_tokens(buf, sr, sc, #((vim.api.nvim_buf_get_lines(buf, sr, sr + 1, false)[1] or "")))
          for row = sr + 1, er - 1 do
            hl_err_tokens(buf, row, 0, #((vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")))
          end
          hl_err_tokens(buf, er, 0, ec)
        end
      end
    end
    for i = node:child_count() - 1, 0, -1 do
      stack[#stack + 1] = node:child(i)
    end
  end
end

return M
