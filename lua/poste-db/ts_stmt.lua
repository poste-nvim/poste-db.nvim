--- Tree-sitter-based SQL statement boundary detection.
--- Replaces Rust CLI `poste context stmt` for finding statement spans.
--- Falls back to nil if Tree-sitter is unavailable, letting callers
--- fall through to Rust or Lua heuristics.

local M = {}

--- Check if the Tree-sitter SQL parser is available.
--- @return boolean
function M.check_parser()
  local ok, lang = pcall(vim.treesitter.language.get_lang, "sql")
  if not (ok and lang ~= nil) then
    return false
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT 1;" })
  local parser_ok, parser = pcall(vim.treesitter.get_parser, buf, "sql")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  return parser_ok and parser ~= nil
end

--- Get a Tree-sitter parser for the given buffer, or nil.
--- @param buf number
--- @return table|nil
local function get_parser(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "sql")
  if ok and parser then
    return parser
  end
  return nil
end

--- Text of a TSNode ("" when unavailable).
local function node_text(node, buf)
  return vim.treesitter.get_node_text(node, buf) or ""
end

--- True for the digit tail of a paren-less MSSQL `SELECT TOP 100 alias.col`:
--- tree-sitter-sql has no TOP clause, so the count lands in a term right
--- after a bare `top` identifier (`TOP (100)` parses cleanly instead).
local function is_top_digit_fragment(node, buf)
  local parent = node:parent()
  if not parent or parent:type() ~= "term" then return false end
  local prev = node:prev_named_sibling()
  return prev ~= nil and node_text(prev, buf):lower() == "top"
end

--- True for the `, <count>` ERROR tree-sitter-sql strands after
--- `LIMIT <offset>, <count>` (MySQL/SQLite/ClickHouse pagination): the
--- grammar only knows `LIMIT n [OFFSET m]` and closes the statement right
--- after `LIMIT <offset>`. Anchored, so a fragment that swallowed a
--- following statement (no `;` before it) is not matched.
local function is_limit_comma_fragment(node, buf)
  local text = node_text(node, buf)
  return text:match("^%s*,%s*%d+%s*;?%s*$") ~= nil
end

--- True when a trailing-`WITH` ERROR is the ClickHouse WITH TOTALS modifier:
--- the grammar leaves `<expr> WITH` as an ERROR and TOTALS survives as a
--- stray field sibling. A truncated `x WITH` (no TOTALS sibling) is a real
--- error and stays reported.
local function is_with_totals_fragment(node, buf)
  local nxt = node:next_named_sibling()
  return nxt ~= nil and node_text(nxt, buf):lower() == "totals"
end

--- True when `stmt` contains the misparsed ClickHouse
--- `ALTER TABLE t DELETE WHERE <pred>` shape: DELETE consumed as a
--- column_definition name inside an alter_table.
local function has_alter_delete_column(stmt, buf)
  local outer = { stmt }
  while #outer > 0 do
    local n = table.remove(outer)
    if n:type() == "alter_table" then
      local inner = { n }
      while #inner > 0 do
        local m = table.remove(inner)
        if m:type() == "column_definition" then
          local name = m:named_child(0)
          if name and node_text(name, buf):lower() == "delete" then
            return true
          end
        end
        for i = 0, m:named_child_count() - 1 do
          inner[#inner + 1] = m:named_child(i)
        end
      end
    else
      for i = 0, n:named_child_count() - 1 do
        outer[#outer + 1] = n:named_child(i)
      end
    end
  end
  return false
end

--- Walk the program root's children to find top-level statement-like nodes.
--- Treats ERROR nodes as statement-like (they include USE, SET, etc.
--- that tree-sitter-sql doesn't recognize).
--- @param root table  TSNode
--- @param buf number
--- @return table[]  list of TSNode
local function get_top_level_stmts(root, buf)
  local stmts = {}
  for child in root:iter_children() do
    local t = child:type()
    if t == "statement" then
      stmts[#stmts + 1] = child
    elseif t == "transaction" then
      stmts[#stmts + 1] = child
      for grandchild in child:iter_children() do
        if grandchild:type() == "statement" then
          stmts[#stmts + 1] = grandchild
        end
      end
    elseif t == "ERROR" then
      -- A trailing LIMIT comma fragment (`, 10`) belongs to the statement
      -- before it; keeping it would register its line as another statement.
      if #stmts == 0 or not is_limit_comma_fragment(child, buf) then
        stmts[#stmts + 1] = child
      end
    end
  end
  return stmts
end

-- Per-buffer cache of top-level statement spans, invalidated whenever the
-- buffer's changedtick advances (i.e. any edit). Lets find_stmt_span do an
-- O(log n) number lookup instead of re-walking top-level TSNode children
-- from the root on every cursor move (unmeasurably slow on large files).
-- Bounded by a wholesale wipe: a closed buffer is never passed to
-- find_stmt_span again, so nothing else removes its entry (bufnr values are
-- never reused), and a large file's span list would otherwise outlive it
-- until restart. The counter counts inserts, not live entries — deletions
-- below don't decrement — so the cap may fire early; it is a leak bound,
-- not an LRU, and a wiped entry simply rebuilds on the next call.
local _span_cache = {}
local _span_cache_inserts = 0
local _SPAN_CACHE_MAX = 64

local function span_cache_evict()
  if _span_cache_inserts < _SPAN_CACHE_MAX then return end
  _span_cache = {}
  _span_cache_inserts = 0
end

--- Build the sorted list of top-level statement spans for a buffer.
--- Mirrors the nodes find_stmt_span used to walk live (statement,
--- transaction, ERROR). Returns nil when the parser is unavailable.
local function build_span_list(buf)
  local parser = get_parser(buf)
  if not parser then return nil end

  local ok, trees = pcall(parser.parse, parser)
  if not ok or not trees or #trees == 0 then return nil end

  local root = trees[1]:root()
  local spans = {}
  for child in root:iter_children() do
    local t = child:type()
    if t == "statement" or t == "transaction" then
      -- store 0-based rows (TS coordinates); find_stmt_span converts at return
      spans[#spans + 1] = { child:start(), child:end_() }
    elseif t == "ERROR" then
      local prev = spans[#spans]
      if prev and is_limit_comma_fragment(child, buf) then
        -- `LIMIT 1, 10` strands `, 10` as a top-level ERROR sibling: the
        -- fragment is the tail of the statement it trails, so fold it in
        -- instead of reporting a phantom statement of its own.
        if child:end_() > prev[2] then prev[2] = child:end_() end
      else
        spans[#spans + 1] = { child:start(), child:end_() }
      end
    end
  end
  return #spans > 0 and spans or nil
end

--- Find the statement span containing a given cursor line using Tree-sitter.
--- @param buf number  buffer handle
--- @param cursor_line number  1-based line number
--- @return {start_line: number, end_line: number}|nil  1-based, inclusive
function M.find_stmt_span(buf, cursor_line)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    if buf then _span_cache[buf] = nil end
    return nil
  end

  local changedtick = vim.api.nvim_buf_get_changedtick(buf)
  local cache = _span_cache[buf]
  if not cache or cache.changedtick ~= changedtick then
    local spans = build_span_list(buf)
    if not spans then
      _span_cache[buf] = nil
      return nil
    end
    cache = { changedtick = changedtick, spans = spans }
    span_cache_evict()
    _span_cache[buf] = cache
    _span_cache_inserts = _span_cache_inserts + 1
  end

  local row = cursor_line - 1
  local spans = cache.spans
  -- Binary search for the last (and only) span starting at or above row.
  -- Top-level spans are ordered and non-overlapping; the row is inside its
  -- span iff it lands between a span's start and end.
  local lo, hi, best = 1, #spans, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if spans[mid][1] <= row then
      best = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end

  if best and row <= spans[best][2] then
    return { spans[best][1] + 1, spans[best][2] + 1 }
  end
  return nil
end

--- Find all statement boundary lines in a range using Tree-sitter.
--- Returns 1-based buffer line numbers of each statement's first content line.
--- @param buf number  buffer handle
--- @param start_line number  1-based
--- @param end_line number  1-based
--- @return number[]|nil  1-based statement start lines
function M.find_all_stmt_lines(buf, start_line, end_line)
  local parser = get_parser(buf)
  if not parser then return nil end

  local ok, trees = pcall(parser.parse, parser)
  if not ok or not trees or #trees == 0 then return nil end

  local root = trees[1]:root()
  local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local stmts = get_top_level_stmts(root, buf)
  local result = {}

  for _, node in ipairs(stmts) do
    local s = node:start() + 1
    local e = node:end_() + 1

    -- Check if this statement overlaps with the requested range
    if s <= end_line and e >= start_line then
      -- Find the first non-blank, non-comment line in this statement
      local content_start = s
      while content_start <= e do
        local line = buf_lines[content_start] or ""
        local trimmed = line:match("^%s*(.*)$")
        if trimmed ~= "" and not trimmed:match("^%-%-") and not trimmed:match("^###") then
          break
        end
        content_start = content_start + 1
      end
      if content_start <= end_line then
        result[#result + 1] = content_start
      end
    end
  end

  return #result > 0 and result or nil
end

--- Find Tree-sitter ERROR nodes in a buffer for diagnostics.
--- Filters out known false positives (USE, SET statements that
--- tree-sitter-sql doesn't recognize).
--- @param buf number
--- @param dialect string|nil  Connection dialect (lowercase); enables
---   dialect-specific filters. nil keeps all errors.
--- @return {lnum: number, col: number, end_lnum: number, end_col: number, text: string}[]
function M.find_error_nodes(buf, dialect)
  local parser = get_parser(buf)
  if not parser then return {} end

  local ok, trees = pcall(parser.parse, parser)
  if not ok or not trees or #trees == 0 then return {} end

  local root = trees[1]:root()
  local errors = {}

  local query = vim.treesitter.query.parse("sql", "(ERROR) @err")
  for id, node, metadata in query:iter_captures(root, buf, 0, -1) do
    local text = vim.treesitter.get_node_text(node, buf) or ""
    local start_row, start_col, end_row, end_col = node:range()

    -- Filter out false positives: statements that tree-sitter-sql
    -- doesn't recognize (MySQL-specific and other non-standard SQL),
    -- and cascading errors (short fragments from nested parser errors).
    local upper = text:upper()

    -- Filter cascading parser errors: single char, punctuation-only, or short parenthesized identifiers
    if #text <= 2 or upper:match("^%(%w+%)$") then
      goto continue
    end

    -- Filter value-fragment cascades from a misparsed VALUES clause
    -- (`VALUES (1, 'a'), ...` → residuals like `1, 'a'),`).
    if upper:match("^%d+%s*,") then
      goto continue
    end

    -- Filter bare-word cascades ending in `;` (e.g. `utf8mb4_unicode_ci;`
    -- from a `CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci` clause).
    if upper:match("^%w+;$") then
      goto continue
    end

    -- Filter statement-terminator cascades. A `;` legally ends the previous
    -- statement, so an ERROR node *starting* with `;` is always a recovery
    -- fragment. E.g. `CREATE DATABASE ... COLLATE x;` followed by `USE y`
    -- (tree-sitter-sql has no USE rule): the create_database `name value`
    -- listing greedily keeps extending and its ERROR swallows `; USE`.
    -- e.g. text = ";\nUSE". A real syntax error never starts with `;`.
    if upper:match("^%s*;") then
      goto continue
    end

    -- Filter bare-word fragments nested inside the fake `GROUP (...)` call
    -- tree-sitter-sql produces for `WITHIN GROUP (ORDER BY ...)`: the ERROR
    -- head is consumed earlier and the ORDER BY target survives as a
    -- standalone word (e.g. `total`) or a plain qualified column
    -- (`o.status`) which is not an error by itself.
    if upper:match("^[%w_]+$") or upper:match("^[%w_]+%.[%w_]+$") then
      local anc = node:parent()
      while anc do
        if anc:type() == "invocation" then
          for c in anc:iter_children() do
            if c:type() == "object_reference" then
              if (vim.treesitter.get_node_text(c, buf) or ""):lower() == "group" then
                goto continue
              end
              break
            end
          end
          break
        end
        anc = anc:parent()
      end
    end

    -- Filter digit-leading identifiers that the parser splits in half:
    -- `select * from 23_tablename` parses as ERROR[23] + relation[_tablename].
    -- MySQL/MariaDB legally allow unquoted identifiers beginning with a digit
    -- (as long as they aren't solely digits), so the digit fragment is not
    -- an error for them. PostgreSQL/SQLite require quoting — keep the error.
    if (dialect == "mysql" or dialect == "mariadb") and text:match("^%d+$") then
      -- The fragment is only part of an identifier when it runs directly
      -- into more identifier characters (`234_tablename`); whitespace means
      -- a standalone all-digit table name, which MySQL also rejects.
      local line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ""
      if line:sub(end_col + 1, end_col + 1):match("[%w_]") then
        goto continue
      end
    end

    -- Filter INTERVAL followed by a parenthesized expression, e.g.
    -- `INTERVAL (i * 2) DAY`. tree-sitter-sql can't parse this form in any
    -- dialect — the ERROR node is a parser limitation, not a real error.
    -- Also catches the bare `INTERVAL` word which is a cascade fragment from
    -- the same misparse.
    if upper:match("^INTERVAL%s+%(") or upper == "INTERVAL" then
      goto continue
    end

    -- Filter MySQL/MariaDB numeric INTERVAL quantities that the parser only
    -- accepts as quoted strings (`INTERVAL '7' DAY`): `INTERVAL 7 DAY` and
    -- `INTERVAL (expr) UNIT` forms are legal MySQL/MariaDB date arithmetic.
    -- Keep the error for dialects that require the quoted form (postgres, sqlite).
    if (dialect == "mysql" or dialect == "mariadb")
      and upper:match("^INTERVAL") then
      goto continue
    end

    -- Filter MySQL/MariaDB GROUP_CONCAT ... SEPARATOR which the parser
    -- does not recognize (`... SEPARATOR '-'`). SEPARATOR is MySQL-specific.
    if (dialect == "mysql" or dialect == "mariadb")
      and upper:match("^SEPARATOR%s+") then
      goto continue
    end

    -- Filter the WITHIN GROUP tail of ordered-set aggregates
  -- (PERCENTILE_CONT/DISC). tree-sitter-sql can't express it and misparses
  -- the head as `percentile_cont(0.5) WITHIN`. PERCENTILE_CONT is listed in
  -- known_false_positives below, but that matcher only catches word-initial
  -- ERROR nodes; a function-call head needs its own check.
  if upper:match("^PERCENTILE_[A-Z_]+%(") then
    goto continue
  end

  -- Filter leading-dot fragments (`.id`, `.username`, `.value AS n`). No SQL
  -- token starts with `.`, and these arise when the grammar eats the
  -- identifier *before* the dot — e.g. mssql `SELECT TOP (10) o.id` parses
  -- `TOP (10) o` as an invocation + alias and strands `.id`. A genuine
  -- `t. col` typo produces no such node, so the fragment is always a
  -- parser artifact.
  if upper:match("^%.%w") then
    goto continue
  end

  -- Filter the paren-less mssql `SELECT TOP 100` count digit (see
  -- is_top_digit_fragment). Dialect-gated: a standalone digit ERROR can be
  -- a real error elsewhere (e.g. MySQL digit-leading table fragments).
  if dialect == "mssql" and upper:match("^%d+$") and is_top_digit_fragment(node, buf) then
    goto continue
  end

  -- Filter MySQL/SQLite/ClickHouse `LIMIT <offset>, <count>` pagination:
  -- the grammar closes the statement at `LIMIT <offset>` and strands a
  -- top-level ERROR sibling `, <count>`. PostgreSQL/MSSQL reject the comma
  -- form — keep the error there (and when the dialect is unknown).
  if (dialect == "mysql" or dialect == "mariadb" or dialect == "sqlite" or dialect == "clickhouse")
    and is_limit_comma_fragment(node, buf) then
    goto continue
  end

  -- Filter T-SQL OFFSET-FETCH pagination (`ORDER BY ... OFFSET 10 ROWS
  -- FETCH NEXT ...`) and FOR JSON / FOR XML result suffixes, which
  -- tree-sitter-sql cannot express.
  if dialect == "mssql"
    and (upper:match("OFFSET%s*%d+%s*ROWS")
      or upper:match("FETCH%s*NEXT%s*%d+%s*ROWS")
      or upper:match("FETCH%s*FIRST%s*%d+%s*ROWS")
      or upper:match("FOR%s+JSON")
      or upper:match("FOR%s+XML")) then
    goto continue
  end

  -- Filter the WITHIN GROUP tail of `agg(...) WITHIN GROUP (ORDER BY x)`:
  -- the grammar folds `WITHIN` into the invocation and the rest surfaces as
  -- an ERROR head `GROUP (ORDER BY x) ...` (STRING_AGG in mssql, ordered-set
  -- aggregates elsewhere). Mirrors the PERCENTILE_/bare-word filters above.
  if upper:match("^GROUP%s*%(") then
    goto continue
  end
  -- Alternate recovery for the same construct: the invocation plus the
  -- stranded WITHIN become the ERROR (`STRING_AGG(x, ', ') WITHIN`).
  if upper:match("WITHIN%s*$") then
    goto continue
  end

  -- Filter the ClickHouse WITH TOTALS modifier on GROUP BY / ORDER BY
  -- (`GROUP BY status WITH TOTALS` → ERROR `status WITH` + stray field
  -- `TOTALS`; see is_with_totals_fragment).
  if dialect == "clickhouse" then
    if (upper:match("WITH%s*$") and is_with_totals_fragment(node, buf))
      or upper:match("WITH%s+TOTALS") then
      goto continue
    end

    -- ClickHouse ARRAY JOIN: the plain form consumes ARRAY as a table alias
    -- and strands `JOIN <array> [AS alias]`; LEFT ARRAY JOIN strands
    -- `LEFT ARRAY JOIN ...` plus a nested bare `ARRAY` fragment.
    if upper:match("^JOIN%s") or upper:match("^LEFT%s+ARRAY%s+JOIN") then
      goto continue
    end
    if upper == "ARRAY" and node:parent() and node:parent():type() == "ERROR" then
      goto continue
    end

    -- ClickHouse `ALTER TABLE t DELETE WHERE <pred>`: DELETE parses as an
    -- added column (custom_type WHERE) and the predicate surfaces as a
    -- top-level ERROR right after the misparsed statement.
    local prev = node:prev_named_sibling()
    if prev and prev:type() == "statement" and has_alter_delete_column(prev, buf) then
      goto continue
    end
  end

  -- Filter the mysql-client `\G`/`\g` statement terminator (vertical
    -- output). It is stripped by the client and never sent to the server,
    -- so a residual `\G` (or a `posts\G` fragment on parsers that merge
    -- it into the statement) is not a SQL error.
    if (dialect == "mysql" or dialect == "mariadb")
      and upper:match("\\[Gg]$") then
      goto continue
    end

    -- Filter MySQL/MariaDB SHOW statements the grammar doesn't know
    -- (SHOW TABLE STATUS, SHOW COLUMNS, SHOW DATABASES, ...). Only a few
    -- forms (SHOW CREATE ...) are recognized.
    if (dialect == "mysql" or dialect == "mariadb")
      and upper:match("^SHOW[%s;]") then
      goto continue
    end

    -- Filter table option continuations (e.g. `= InnoDB` after `ENGINE`)
    if text:match("^%s*=") then
      goto continue
    end

    -- Filter PRAGMA statements and their merged cascade fragments:
    -- tree-sitter-sql has no PRAGMA grammar (SQLite), so both the whole
    -- statement and residuals like `users); PRAGMA index_list` parse as ERROR.
    if upper:match("PRAGMA") then
      goto continue
    end

    -- Filter the SQLite GLOB operator (LIKE-like), unknown to the grammar.
    if upper:match("^GLOB") then
      goto continue
    end

    -- Filter MySQL/MariaDB CREATE OR REPLACE TABLE, which tree-sitter-sql
    -- does not recognize (the grammar only knows `CREATE [TEMPORARY] TABLE`).
    if (dialect == "mysql" or dialect == "mariadb")
      and upper:match("^CREATE%s+OR%s+REPLACE") then
      goto continue
    end

    -- Filter MariaDB column attribute INVISIBLE, unknown to the grammar.
    if upper == "INVISIBLE" then
      goto continue
    end

    -- Filter known non-standard statements
    local stmt_kw = upper:match("^(%w+)%s") or upper:match("^(%w+);")
    local known_false_positives = {
        USE = true, SET = true, DESC = true, DESCRIBE = true,
        ANALYZE = true, KILL = true, FLUSH = true, CALL = true,
        LOAD = true, REPAIR = true, CHECK = true,
        ON = true, FOR = true, NOTIFY = true, TABLE = true,
        BEGIN = true, SETS = true, PERCENTILE_CONT = true,
        COMMENT = true, ENGINE = true, CHARSET = true,
        CHARACTER = true,
        NATURAL = true, SAVEPOINT = true, RELEASE = true,
        QUERY = true, VALUES = true,
      }
    -- Filter single-word false positives (e.g. `engine` alone as an ERROR node)
    if not stmt_kw then
      stmt_kw = upper:match("^(%w+)$")
    end
    if stmt_kw then
      if known_false_positives[stmt_kw] then
        goto continue
      end
    end

    -- Filter PG-specific constructs that the parser misparses
    if upper:match("^%(%w+%)%s+DO%s+UPDATE") or upper:match("^%(%w+%)%s+ON%s+CONFLICT") then
      goto continue
    end

    -- Filter OR-conflict clauses of SQLite INSERT OR x INTO
    -- (`INSERT OR REPLACE INTO ...`). tree-sitter-sql splits off the
    -- `OR REPLACE` fragment (with or without the following INTO).
    if upper:match("^OR%s+REPLACE") or upper:match("^OR%s+ROLLBACK")
      or upper:match("^OR%s+ABORT") or upper:match("^OR%s+FAIL")
      or upper:match("^OR%s+IGNORE") then
      goto continue
    end

    errors[#errors + 1] = {
      lnum = start_row + 1,
      col = start_col + 1,
      end_lnum = end_row + 1,
      end_col = end_col + 1,
      text = "Unexpected token: " .. text,
    }
    ::continue::
  end

  return errors
end

M._test = {
  find_stmt_span = M.find_stmt_span,
  find_all_stmt_lines = M.find_all_stmt_lines,
  find_error_nodes = M.find_error_nodes,
}

return M
