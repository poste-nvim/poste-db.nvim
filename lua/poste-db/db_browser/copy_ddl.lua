--- Pure DDL/result transform helpers for cross-connection copy.
--- Extracted from db_browser/copy.lua: string/table in, string/table out —
--- no IO, no dialogs, directly unit-testable.
local ident = require("poste-db.ident")
local verdict = require("poste-db.verdict")

local quote = ident.quote
local quote_ref = ident.quote_ref

local M = {}


function M.has_value(v)
  return v ~= nil and v ~= vim.NIL
end

--- SQL literal for one copied value. `dialect` selects the escaping rules, so
--- it has to reach ident.quote_literal: MySQL/MariaDB/ClickHouse read `\`
--- inside '…' as an escape, and a value containing a backslash (a JSON column
--- encodes nested quotes as `\"`) arrived mangled without it.
function M.quote_value(val, dialect)
  if type(val) == "table" then
    local ok, json_str = pcall(vim.json.encode, val)
    if not ok then return "NULL" end
    return ident.quote_literal(json_str, dialect)
  end
  return ident.quote_literal(val, dialect)
end

function M.extract_row_count(r)
  if M.has_value(r.affected_rows) then return tostring(r.affected_rows) end
  if M.has_value(r.row_count) then return tostring(r.row_count) end
  return "?"
end

function M.extract_elapsed(r)
  if M.has_value(r.execution_time_ms) then return tostring(r.execution_time_ms) .. "ms" end
  return "?"
end

--- First statement failure in a copy/DDL response, with its text when there is
--- one. Scans every statement rather than just the first: a copy can run a batch
--- (`SET` prelude, several DDLs), and stopping at results[1] left a rejected later
--- statement to be reported by the caller's coarse envelope sentence, or not at
--- all. `message` stays first-result-only — it is a legacy CLI field, and on later
--- results it carries notes rather than failures.
function M.check_result_error(decoded)
  local results = decoded and decoded.results
  if type(results) ~= "table" then return nil end
  for i, r in ipairs(results) do
    local failed, text = verdict.classify(r)
    if failed then return text end
    if i == 1 and M.has_value(r.message) then return r.message end
  end
  return nil
end

function M.extract_schema_from_ddl(ddl, table_name, dialect)
  if dialect == "mysql" or dialect == "mariadb" then
    return nil
  end
  -- The table name is data, not a pattern. Splicing it into the match let a
  -- name with magic characters (`t%x`) or a dot (`a.b`) accept a DDL header
  -- for a different table — and the schema it reported was then applied to
  -- the wrong one.
  local schema, rest = ddl:match('^CREATE TABLE "([^"]+)"%.(.*)')
  if not schema then return nil end
  local quoted = '"' .. table_name .. '"'
  if rest:sub(1, #quoted) ~= quoted then return nil end
  return schema
end

function M.extract_sequences_from_ddl(ddl, schema)
  local sequences = {}
  local seen = {}
  for seq_name in ddl:gmatch("nextval%('([^']+)'%:%:regclass%)") do
    if not seen[seq_name] then
      seen[seq_name] = true
      table.insert(sequences, seq_name)
    end
  end
  return sequences
end

function M.column_type_for_seq(ddl, seq_name)
  local seq_ref = "nextval('" .. seq_name .. "'::regclass)"
  local seq_pos = ddl:find(seq_ref, 1, true)
  if not seq_pos then return "integer" end
  local before = ddl:sub(1, seq_pos - 1)
  local col_type = before:match('"[^"]+"%s+(%w+)%s+[^,]-%s+DEFAULT%s*$')
  if not col_type then
    col_type = before:match('"[^"]+"%s+(%w+)%s+DEFAULT%s*$')
  end
  if col_type == "bigint" then return "bigint" end
  if col_type == "smallint" then return "smallint" end
  return "integer"
end

function M.rename_seq_reference(ddl, seq_name, new_seq_name)
  local old = "nextval('" .. seq_name .. "'::regclass)"
  local new = "nextval('" .. new_seq_name .. "'::regclass)"
  -- old/new contain parens and quotes; gsub would treat them as pattern
  -- magic and never match — escape both sides for a literal replacement.
  return (ddl:gsub(vim.pesc(old), new:gsub("%%", "%%%%"), 1))
end

function M.prepare_table_ddl(ddl, target_table_name, table_name, schema, dialect)
  -- pesc: table_name is data, not a pattern — backtick-quoted MySQL names may
  -- contain gsub-magic chars (`order-2024(`), which would error or mis-match.
  -- The replacement side escapes % (the only replacement magic).
  local pat = vim.pesc(table_name)
  local rep = target_table_name:gsub("%%", "%%%%")
  local modified = ddl:gsub("`" .. pat .. "`", "`" .. rep .. "`")
  modified = modified:gsub('"' .. pat .. '"', '"' .. rep .. '"')

  if dialect ~= "postgres" then
    return modified
  end

  local sequences = M.extract_sequences_from_ddl(modified, schema)
  if #sequences == 0 then
    return modified
  end

  local q = function(n) return quote(n, dialect) end
  local seq_stmts = {}
  for _, seq_name in ipairs(sequences) do
    -- pesc for the same reason as above: a sequence is named after its table,
    -- so a table name that happens to hold pattern magic (`pct%tbl`) matched
    -- nothing and the CREATE SEQUENCE was renamed while the DEFAULT still
    -- pointed at the source sequence.
    -- The inner gsub is parenthesised so its second return (the replacement
    -- count) cannot leak in as the outer gsub's `n` limit — with a `%`-free
    -- target name that count is 0, which silently meant "replace nothing".
    local new_seq_name = seq_name:gsub(vim.pesc(table_name),
      (target_table_name:gsub("%%", "%%%%")))
    local seq_type = M.column_type_for_seq(ddl, seq_name)
    -- Qualified nextval refs leave new_seq_name carrying the schema already,
    -- and it was parsed out of SQL text rather than introspected, so it goes
    -- through quote_ref (split on the dot); prepending schema again would emit
    -- "schema"."schema"."seq", disagreeing with the rewritten DEFAULT ref.
    local qualified
    if schema and not ident.is_qualified(new_seq_name) then
      qualified = q(schema) .. "." .. quote_ref(new_seq_name, dialect)
    else
      qualified = quote_ref(new_seq_name, dialect)
    end
    table.insert(seq_stmts, "CREATE SEQUENCE IF NOT EXISTS " .. qualified .. " AS " .. seq_type .. ";")
    modified = M.rename_seq_reference(modified, seq_name, new_seq_name)
  end

  table.insert(seq_stmts, modified)
  return table.concat(seq_stmts, "\n")
end

--- Existence probe for a paste target: table OR view (a same-named view
--- collides with a table in every engine here).
---
--- The name and schema are rendered through `quote_literal` at build time
--- instead of being spliced into a hand-written `'%s'`: an apostrophe is legal
--- inside a quoted identifier, and one in the probed name closed the literal
--- early, made the query error out, and the caller's fail-closed handler then
--- reported *every* candidate name as taken — the auto-suffix loop never
--- terminated.
function M.dialect_table_exists_sql(dialect, schema, name)
  if dialect == "mysql" or dialect == "mariadb" then
    -- information_schema (not SHOW TABLES) so views collide correctly too.
    return "SELECT TABLE_NAME FROM information_schema.TABLES"
      .. " WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = "
      .. ident.quote_literal(name, dialect)
  elseif dialect == "postgres" then
    return "SELECT EXISTS (SELECT FROM information_schema.tables"
      .. " WHERE table_schema = " .. ident.quote_literal(schema or "public", dialect)
      .. " AND table_name = " .. ident.quote_literal(name, dialect) .. ")"
  else
    return "SELECT name FROM sqlite_master"
      .. " WHERE type IN ('table','view') AND name = "
      .. ident.quote_literal(name, dialect)
  end
end

--- Earliest routine keyword position. A plain
--- `upper:find("PROCEDURE") or upper:find("FUNCTION")` answers with a *later*
--- occurrence whenever the body mentions the other kind: a PL/pgSQL body with
--- the word "procedure" in it anchored the scan after the real name, so the
--- substitution missed and the paste silently re-created (with PG's
--- `CREATE OR REPLACE`, replaced) the *source* routine instead of a copy.
local function routine_kw_pos(upper)
  local proc, func = upper:find("PROCEDURE"), upper:find("FUNCTION")
  if proc and func then return math.min(proc, func) end
  return proc or func
end

--- Replace a routine's own name inside its SHOW CREATE/pg_get_functiondef
--- text (first occurrence after the PROCEDURE/FUNCTION keyword, so DEFINER
--- clauses are untouched).
---
--- MySQL: the routine's own name is the first `` `src` `` after the keyword —
--- SHOW CREATE renders it (schema-qualified or not) before the parameter list,
--- and every other backtick pair (DEFINER, body literals) either sits before
--- the keyword or after the name.
---
--- Postgres: the name immediately precedes the parameter list, spelled bare
--- when it needs no quoting and `"…"` when it does — both spellings have to be
--- recognized, and the target goes back through `ident.quote`. Matching only
--- the bare form dropped the rename for a quoted source name (and for a MySQL
--- name carrying a backtick, which the catalog doubles), and the paste then
--- created — with `CREATE OR REPLACE`, *replaced* — the source routine while the
--- summary reported the copy under the requested name. Emitting the target bare
--- let a mixed-case or spaced name reach the server as invalid SQL, or, worse
--- for Postgres, as the lower-cased version of itself.
function M.rename_routine_in_def(dialect, def, src, tgt)
  -- An empty name on either side would make the substitution rewrite the
  -- header into something the server cannot parse; leave the definition as it
  -- came and let the summary report the copy under its original name.
  if not src or src == "" or not tgt or tgt == "" then return def end
  local upper = def:upper()
  local kw_pos = routine_kw_pos(upper)
  if not kw_pos then return def end

  if dialect == "mysql" or dialect == "mariadb" then
    -- `quote` spells an inner backtick the doubled way SHOW CREATE does, so a
    -- name carrying one is found rather than silently kept.
    local quoted_src = quote(src, dialect)
    local plain_idx = def:find(quoted_src, kw_pos, true)
    if not plain_idx then return def end
    return def:sub(1, plain_idx - 1) .. quote(tgt, dialect) .. def:sub(plain_idx + #quoted_src)
  end

  -- Postgres and the other non-MySQL dialects: the name immediately precedes
  -- the parameter list, in that dialect's own quoting (`ident.quote` gives the
  -- spelling the server itself prints, brackets for mssql included). The tail
  -- is compared against `before` itself — never against a whitespace-stripped
  -- copy of it, because a quoted routine name may contain spaces and stripping
  -- would fold `"Add Two"` into something no server ever printed.
  local paren = def:find("%(", kw_pos)
  if not paren then return def end
  local before = def:sub(kw_pos + 1, paren - 1)
  local no_trailing_ws = before:gsub("%s+$", "")
  local quoted_src = quote(src, dialect)
  local matched, match_at
  for _, cand in ipairs({ quoted_src, src }) do
    if before:sub(-#cand) == cand then
      matched, match_at = cand, #before - #cand + 1
      break
    elseif no_trailing_ws:sub(-#cand) == cand then
      matched, match_at = cand, #no_trailing_ws - #cand + 1
      break
    end
  end
  if not matched then return def end
  return def:sub(1, kw_pos + match_at - 1) .. quote(tgt, dialect) .. def:sub(paren)
end

return M
