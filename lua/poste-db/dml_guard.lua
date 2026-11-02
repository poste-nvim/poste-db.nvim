--- Guard for unfiltered destructive SQL — DELETE/UPDATE statements that lack
--- a WHERE clause (and would therefore hit every row).
---
--- Two duties:
---   1. Buffer lint: purple HINT diagnostics via `M.update(buf)` / `M.clear(buf)`
---      (wired from diagnostics.lua, alongside the syntax + semantic checks).
---   2. Run-time confirm gate: `M.scan_text()` + `M.confirm_message()` power the
---      confirmation dialog in sql_runner.run_sql_request() before execution.
---
--- Tree-sitter-sql drives both paths; a regex fallback covers text that does
--- not parse (parser missing, ERROR fragments). The classifier operates on a
--- small plain-table node shape ({ type, children }) so it is unit-testable
--- without a parser; TSNode subtrees are converted at the parse boundary.

local util = require("poste-db.util")

local M = {}

local ns = vim.api.nvim_create_namespace("poste_db_missing_where")
local ns_hl = vim.api.nvim_create_namespace("poste_db_missing_where_highlight")

M.MESSAGES = {
  delete = "DELETE statement without a WHERE clause — this will remove ALL rows in the table",
  update = "UPDATE statement without a WHERE clause — this will modify ALL rows in the table",
}

--- True when `node` has a direct `where` clause child.
--- @param node table { children = table[] }
--- @return boolean
local function clauses_have_where(node)
  for _, c in ipairs(node.children or {}) do
    if c.type == "where" then return true end
  end
  return false
end

--- Classify a DML statement container (plain table: { type, children }) and
--- return its kind ("delete"/"update") when it lacks a top-level WHERE clause,
--- nil otherwise.
---
--- tree-sitter-sql keeps the DELETE WHERE inside the statement's `from` clause
--- (a sibling of the `delete` node), while UPDATE carries `where` directly on
--- the `update` node. A `where` inside a nested subquery (e.g. `UPDATE t
--- SET x = (SELECT ... WHERE ...)`) does NOT count — it filters the subquery,
--- not the rows being changed.
--- @param node table { type = "statement"|"transaction", children = table[] }
--- @return string|nil "delete"|"update" when unfiltered; nil otherwise
function M.missing_where(node)
  if not node then return nil end
  local found_delete = false
  local delete_filtered = false
  for _, c in ipairs(node.children or {}) do
    local t = c.type
    if t == "delete" then
      found_delete = true
    elseif t == "update" then
      if not clauses_have_where(c) then return "update" end
    elseif t == "from" then
      if clauses_have_where(c) then delete_filtered = true end
    end
  end
  if found_delete then
    if delete_filtered then return nil end
    return "delete"
  end
  return nil
end

--- Collect the DML statement containers (TSNode "statement" nodes) in `root`,
--- descending through "transaction" groups.
--- @param root TSNode
--- @return TSNode[]
local function container_tsnodes(root)
  local containers = {}
  local function visit(node)
    local t = node:type()
    if t == "statement" then
      containers[#containers + 1] = node
      return
    end
    for c in node:iter_children() do visit(c) end
  end
  visit(root)
  return containers
end

--- Convert a TSNode subtree to the plain { type, children } shape, bounded
--- to the depth the classifier reads: `missing_where` reads children types
--- (depth 1) and `clauses_have_where` reads grandchildren types (depth 2).
--- The unbounded copy materialized the whole tree — hundreds of thousands of
--- tables per keystroke for a 10k-row `INSERT … VALUES` — to read two levels.
--- @param node TSNode
--- @param depth number current depth, 0 for the root
--- @return table { type, children }
local PLAIN_MAX_DEPTH = 2
local function to_plain(node, depth)
  depth = depth or 0
  local plain = { type = node:type(), children = {} }
  if depth >= PLAIN_MAX_DEPTH then return plain end
  for c in node:iter_children() do
    plain.children[#plain.children + 1] = to_plain(c, depth + 1)
  end
  return plain
end

local function get_parser(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "sql")
  if ok and parser then return parser end
  return nil
end

--- Compute unfiltered DML statements in a buffer (0-based ranges, diagnostics
--- ready). Empty when tree-sitter-sql is unavailable or nothing is risky.
--- @param buf number
--- @return table[] each entry: { kind, lnum, col, end_lnum, end_col }
function M.compute(buf)
  local hits = {}
  local parser = get_parser(buf)
  if not parser then return hits end
  local ok, trees = pcall(parser.parse, parser)
  if not ok or not trees or #trees == 0 then return hits end
  for _, stmt in ipairs(container_tsnodes(trees[1]:root())) do
    local kind = M.missing_where(to_plain(stmt))
    if kind then
      local s, sc, e, ec = stmt:range()
      hits[#hits + 1] = { kind = kind, lnum = s, col = sc, end_lnum = e, end_col = ec }
    end
  end
  return hits
end

--- Set purple HINT diagnostics for unfiltered DELETE/UPDATE statements.
--- @param buf number
function M.update(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local hits = M.compute(buf)
  local diags = {}
  for _, h in ipairs(hits) do
    diags[#diags + 1] = {
      lnum = h.lnum,
      col = h.col,
      end_lnum = h.end_lnum,
      end_col = h.end_col,
      severity = vim.diagnostic.severity.HINT,
      source = "poste-db",
      message = M.MESSAGES[h.kind],
    }
  end
  vim.diagnostic.set(ns, buf, diags, { priority = 200 })
  vim.api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)
  for _, h in ipairs(hits) do
    vim.api.nvim_buf_set_extmark(buf, ns_hl, h.lnum, h.col, {
      end_row = h.end_lnum,
      end_col = h.end_col,
      hl_group = "PosteDbMissingWhere",
      hl_mode = "combine",
      priority = 200,
    })
  end
end

--- Clear the missing-WHERE diagnostics for a buffer.
--- @param buf number
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.diagnostic.reset(ns, buf)
    vim.api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)
  end
end

--- Trim, collapse whitespace and truncate a SQL snippet for confirm dialogs.
--- @param text string|nil
--- @param max number|nil
--- @return string
function M.snippet(text, max)
  max = max or 64
  local s = (text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  s = util.ellipsize(s, max)
  return s
end

--- Blank out quoted literals, comments and dollar-quoted bodies so keyword
--- scanning sees code only: a `where` inside a string is not a WHERE clause, and
--- a `--` inside a string is not a comment. One pass with a small state machine
--- — a gsub chain cannot get both directions right: stripping comments first
--- lets a `--` in a literal swallow the rest of the batch (hiding a DELETE
--- behind it), stripping literals first lets an apostrophe in a comment
--- (`-- don't`) open a literal that erases real code. An unterminated literal,
--- block comment or dollar-quote body runs to end of input, which is what the
--- server does with it too. Newlines are kept so line structure survives for the
--- callers that map back to the buffer.
---
--- Dollar quoting (`$$ … $$`, `$body$ … $body$`) matters for the same reason: a
--- PL/pgSQL function body is not code the outer statement runs, so a
--- `DELETE FROM t` inside one must neither trip this guard nor split the batch
--- at its internal `;`.
---
--- `backslash_escapes` says whether `\'` reads as an escaped quote (MySQL's
--- default `sql_mode`) or as ordinary content with the literal closing there
--- (PostgreSQL/SQLite, `standard_conforming_strings` on). The two readings
--- disagree about where a literal ends, and either disagreement alone can hide
--- an unfiltered statement: the backslash reading swallows the `;`-separated
--- `DELETE` that follows a postgres-legal `'a\'`, while the standard reading
--- hides a MySQL-legal `'it\'s'; DELETE FROM t` inside a phantom literal. The
--- scanner therefore runs BOTH readings at the call sites that decide whether
--- to warn (see `regex_scan`) — a confirm gate must over-flag, never under.
--- @param sql string
--- @param backslash_escapes boolean|nil  default true (the historical reading)
--- @return string
local QUOTE_STATE = { ["'"] = "squote", ['"'] = "dquote", ["`"] = "bquote" }
local CLOSING_QUOTE = { squote = "'", dquote = '"', bquote = "`" }
-- `$` starts a tag only when the closing `$` follows at once (`$$`) or a run of
-- identifier chars (`$body$`); `$1` is a placeholder, not a tag.
local DOLLAR_TAG = "^%$[%w_]*%$"

function M.strip_non_code(sql, backslash_escapes)
  if backslash_escapes == nil then backslash_escapes = true end
  local out = {}
  local i, n = 1, #sql
  local state = "code"
  local dollar_tag = nil
  while i <= n do
    local c = sql:sub(i, i)
    if state == "code" then
      local nx = sql:sub(i + 1, i + 1)
      local tag = (c == "$") and sql:match(DOLLAR_TAG, i) or nil
      if c == "-" and nx == "-" then
        state, i = "line", i + 2
      elseif c == "/" and nx == "*" then
        state, i = "block", i + 2
      elseif tag then
        dollar_tag = tag
        state, i = "dollar", i + #tag
      elseif QUOTE_STATE[c] then
        state, i = QUOTE_STATE[c], i + 1
      else
        i = i + 1
      end
      out[#out + 1] = (state == "code") and c or " "
    elseif state == "line" then
      out[#out + 1] = (c == "\n") and "\n" or " "
      if c == "\n" then state = "code" end
      i = i + 1
    elseif state == "block" then
      if c == "*" and sql:sub(i + 1, i + 1) == "/" then
        state, i = "code", i + 2
      else
        out[#out + 1] = (c == "\n") and "\n" or " "
        i = i + 1
      end
    elseif state == "dollar" then
      if sql:find(dollar_tag, i, true) == i then
        state, dollar_tag, i = "code", nil, i + #dollar_tag
      else
        out[#out + 1] = (c == "\n") and "\n" or " "
        i = i + 1
      end
    else
      local closing = CLOSING_QUOTE[state]
      if c == "\\" and backslash_escapes and state ~= "bquote" then
        i = i + 2 -- an escape consumes its next byte in every quoting style that honors it
      elseif c == closing then
        if sql:sub(i + 1, i + 1) == closing then
          i = i + 2 -- doubled quote: still inside the literal
        else
          state, i = "code", i + 1
        end
      else
        out[#out + 1] = (c == "\n") and "\n" or " "
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

--- The driving DML verb of a statement shell: the verb either opens the
--- statement or follows a `WITH x AS, y AS` CTE naming chain (whose bodies are
--- already gone with their parentheses). Anything before it must be naming, so
--- an `ON UPDATE CASCADE` clause does not read as an UPDATE statement.
---
--- The verbs are scanned one at a time rather than with `%f[%w_](DELETE|UPDATE)`:
--- LuaJIT's pattern matcher cannot combine a frontier pattern with a capture
--- alternation (the match always fails), and Neovim ships Lua 5.1.
--- @param shell string whitespace-collapsed, parenthesis-free statement text
--- @return string|nil "delete"|"update"
local DML_KEYWORDS = { "DELETE", "UPDATE" }

local function dml_verb(shell)
  local upper = shell:upper()
  local pos, verb
  for _, kw in ipairs(DML_KEYWORDS) do
    local at = (upper:find("%f[%w_]" .. kw .. "%f[^%w_]"))
    if at and (not pos or at < pos) then pos, verb = at, kw end
  end
  if not pos then return nil end
  local prefix = upper:sub(1, pos - 1)
  if prefix:match("^%s*$") or prefix:match("^%s*WITH[%w_%s,]*$") then
    return verb:lower()
  end
  return nil
end

--- Regex fallback for `scan_text`: split on `;`, flag DELETE/UPDATE chunks
--- without a top-level WHERE. Parens are dropped before scanning so a WHERE
--- inside a subquery does not count as the statement's filter.
---
--- This runs when tree-sitter is unavailable AND whenever the tree-sitter
--- pass found no risky statement (scan_text falls back to it on zero hits),
--- so it scans the text under BOTH quote-escape readings and unions the
--- hits: the dialects disagree on whether `\'` escapes the quote, and either
--- single reading can park an unfiltered DELETE inside a phantom literal. A
--- confirm gate that over-flags one extra edge is fine; one that misses a
--- statement is
--- not. Deduped on kind+snippet so a statement both readings flag asks once.
--- @param sql string
--- @return table[] each entry: { kind, snippet }
function M.regex_scan(sql)
  local hits, seen = {}, {}
  if not sql or #sql == 0 then return hits end
  for _, backslash in ipairs({ false, true }) do
    for chunk in (M.strip_non_code(sql, backslash) .. ";"):gmatch("[^;]*") do
      local stmt = (chunk:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
      if stmt ~= "" then
        local shell = (stmt:gsub("%b()", " "):gsub("%s+", " "))
        local kind = dml_verb(shell)
        if kind and not shell:upper():find("%sWHERE%s") then
          local key = kind .. "\0" .. stmt
          if not seen[key] then
            seen[key] = true
            hits[#hits + 1] = { kind = kind, snippet = stmt }
          end
        end
      end
    end
  end
  return hits
end

--- Scan SQL text for DELETE/UPDATE statements that lack a WHERE clause.
--- Uses tree-sitter when available; falls back to `regex_scan`. The result is
--- a list of { kind, snippet } used by the execution confirm gate.
--- @param sql string
--- @return table[]
function M.scan_text(sql)
  if not sql or #sql == 0 then return {} end
  local hits = {}
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, vim.split(sql, "\n", { plain = true }))
  local parser = get_parser(buf)
  if parser then
    local ok, trees = pcall(parser.parse, parser)
    if ok and trees and #trees > 0 then
      for _, stmt in ipairs(container_tsnodes(trees[1]:root())) do
        local kind = M.missing_where(to_plain(stmt))
        if kind then
          hits[#hits + 1] = {
            kind = kind,
            snippet = M.snippet(vim.treesitter.get_node_text(stmt, buf)),
          }
        end
      end
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  if #hits == 0 then return M.regex_scan(sql) end
  return hits
end

--- Build the confirm question for a list of risky statements.
--- @param risky table[] { kind, snippet }
--- @return string
function M.confirm_message(risky)
  local n = #risky
  -- The only caller gates on #risky > 0 before opening the dialog, but this is
  -- an exported API: "contains 0 statement(s)" would be a nonsense question.
  if n == 0 then return "No unfiltered DELETE/UPDATE statements found." end
  local kinds = {}
  local seen = {}
  for _, r in ipairs(risky) do
    -- `seen[nil] = true` raises "table index is nil": an exported API must
    -- not crash on a malformed entry, so kindless entries are skipped
    if type(r) == "table" and r.kind and not seen[r.kind] then
      seen[r.kind] = true
      kinds[#kinds + 1] = (r.kind == "delete") and "DELETE statement" or "UPDATE statement"
    end
  end
  if #kinds == 0 then return "SQL contains unfiltered statement(s) without a WHERE clause." end
  local head
  if n == 1 and risky[1].snippet and risky[1].snippet ~= "" then
    head = string.format("%s without a WHERE clause:\n  %s", kinds[1], risky[1].snippet)
  elseif n == 1 then
    head = kinds[1] .. " without a WHERE clause"
  else
    head = string.format("SQL contains %d statement(s) without a WHERE clause (%s)",
      n, table.concat(kinds, ", "))
  end
  return head .. "\n\nThis affects ALL rows — execute anyway?"
end

M._test = {
  missing_where = M.missing_where,
  regex_scan = M.regex_scan,
  confirm_message = M.confirm_message,
  snippet = M.snippet,
  strip_non_code = M.strip_non_code,
  dml_verb = dml_verb,
}

return M