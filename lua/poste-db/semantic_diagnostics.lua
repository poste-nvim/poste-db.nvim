--- Semantic SQL diagnostics — validates table/column references against database schema.
--- Uses Tree-sitter to extract references, then checks against cached schema.
--- Async: kicks off schema fetch when cache is cold.
---
--- Per-statement context resolution: each statement is checked against the
--- database context at its line (-- @database, USE, etc. are position-sensitive).
---
--- Owns its own schema cache (bypasses completion_data key ambiguity).

local context = require("poste-db.context")
local connections = require("poste-db.connections")
local state = require("poste-db.state")
local const = require("poste-db.constants")
local util = require("poste-db.util")

local M = {}

local ns = vim.api.nvim_create_namespace("poste_db_semantic_diagnostics")
local ns_hl = vim.api.nvim_create_namespace("poste_db_semantic_highlight")
local _pending_checks = {}
local _updating = false
local _schema_cache = {}

--- Check if Tree-sitter SQL parser is available.
local function check_parser()
  local ok, lang = pcall(vim.treesitter.language.get_lang, "sql")
  return ok and lang ~= nil
end

local function get_parser(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "sql")
  if ok and parser then return parser end
  return nil
end

--- Top-level nodes that carry a statement. The grammar closes a `statement`
--- only once the syntax is complete, so a half-written statement is left as a
--- root-level ERROR instead: `UPDATE users SET ▮ WHERE ;` parses as one ERROR
--- holding `keyword_update`, `relation users`, `keyword_set`, and the walk
--- below never sees an `update` container. Those ERROR nodes are included so
--- the table and the columns already typed are still extracted (and checked)
--- while the statement is being typed -- `ts_stmt` treats them as statements
--- for the same reason.
local function get_statement_nodes(buf)
  local parser = get_parser(buf)
  if not parser then return nil end
  local ok, trees = pcall(parser.parse, parser)
  if not ok or not trees or #trees == 0 then return nil end
  local root = trees[1]:root()
  local stmts = {}
  for child in root:iter_children() do
    local t = child:type()
    if t == "statement" or t == "transaction" or t == "ERROR" then
      stmts[#stmts + 1] = child
    end
  end
  return #stmts > 0 and stmts or nil
end

local function extract_references_from_node(stmt_node, buf)
  local tables = {}
  local columns = {}
  local alias_map = {}
  local from_tables = {}
  local select_aliases = {}
  local seen_tables = {}
  local seen_cols = {}

  local function get_node_range(node)
    local start_row, start_col, end_row, end_col = node:range()
    return start_row + 1, start_col + 1, end_row + 1, end_col + 1
  end

  --- Strip the quoting a dialect writes around an identifier: backticks (MySQL),
  --- double quotes (postgres/ANSI), brackets (SQL Server). These nodes are not
  --- dialect-specific, so all of them can arrive here.
  --- @param text string
  --- @return string
  local function unquote(text)
    return (text:gsub("^[`\"'\\[]+", ""):gsub("[]`\"'\\]+$", ""))
  end

  --- Destructure an `object_reference` written as identifier ("." identifier)*.
  --- The trailing identifier is the table; the leading one is the qualifier
  --- (a database in MySQL/ClickHouse, a schema in postgres for two-part refs).
  --- For three or more parts the leftmost is still the database and the middle
  --- ones are schemas, which the per-database cache cannot express -- so the
  --- qualifier is always `names[1]` and the components it skips simply go
  --- unchecked. `unqualified` tells the caller the name stood alone.
  ---
  --- Only the 3-child case used to be destructured, so the legal postgres
  --- `FROM blog.public.users` became one table literally named
  --- "blog.public.users" and was always reported missing.
  ---
  --- A shape that is not a plain dotted list is reported whole instead, which
  --- is what the callers did before; a dotted list ending in an empty
  --- identifier (a stray quote, a dangling dot) yields no name at all, since
  --- the raw text would then be blamed on a table the user never wrote.
  --- @param obj TSNode
  --- @return string|nil qualifier, string|nil name, TSNode|nil name_node, boolean unqualified
  local function dotted_reference(obj)
    local names, name_nodes, plain = {}, {}, true
    for c in obj:iter_children() do
      if c:type() == "identifier" then
        names[#names + 1] = unquote(vim.treesitter.get_node_text(c, buf))
        name_nodes[#name_nodes + 1] = c
      elseif c:type() ~= "." then
        plain = false
      end
    end
    if #names == 0 or not plain then
      local whole = unquote(vim.treesitter.get_node_text(obj, buf))
      return nil, whole ~= "" and whole or nil, obj, false
    end
    local qualifier = #names >= 2 and names[1] or nil
    if qualifier == "" then qualifier = nil end
    local name = names[#names]
    return qualifier, name ~= "" and name or nil, name_nodes[#name_nodes], #names == 1
  end

  -- CTE names (WITH a AS (...) SELECT ... FROM a) are scoped aliases, not
  -- real tables. Collect them so references to a CTE are never validated
  -- against the schema — including recursive self-references and references
  -- from a later CTE's body (chained CTEs).
  local cte_names = {}
  do
    local function scan_ctes(node)
      if node == nil then return end
      if node:type() == "cte" then
        for c in node:iter_children() do
          if c ~= nil and c:type() == "identifier" then
            cte_names[vim.treesitter.get_node_text(c, buf):lower()] = true
            break
          end
        end
      end
      for c in node:iter_children() do scan_ctes(c) end
    end
    scan_ctes(stmt_node)
  end

  --- tree-sitter splits digit-leading identifiers (`123_abc`) into
  --- ERROR[123] + relation/object_reference[_abc]. Rejoin the fragment
  --- when its text is pure digits and it runs directly into the
  --- identifier (byte-contiguous; `234 _tablename` has a space gap and
  --- must stay separate). The merged name is what the user wrote —
  --- digit-leading unquoted identifiers are legal in MySQL/MariaDB.
  --- @param buf number
  --- @param node TSNode  node whose previous sibling may be the digit ERROR
  --- @param tbl_name string
  --- @param id_node TSNode  the identifier node inside the relation
  --- @return string tbl_name, TSNode|nil span_start
  local function merge_digit_fragment(src_buf, node, tbl_name, id_node)
    local prev = node:prev_sibling()
    if not (prev and prev:type() == "ERROR") then return tbl_name, nil end
    local err_text = vim.treesitter.get_node_text(prev, src_buf) or ""
    if not err_text:match("^%d+$") then return tbl_name, nil end
    local _, _, per, pec = prev:range()
    local isr, isc = id_node:range()
    if per ~= isr or pec ~= isc then return tbl_name, nil end
    return err_text .. tbl_name, prev
  end

  local function add_table(name, node, db_prefix, start_node)
    -- The raw node text, before any unquote, tells a bare keyword from a
    -- quoted identifier: `UPDATE SET users;` (no target table) parses as one
    -- root ERROR whose `SET users` is a relation, and the bare keyword would
    -- be looked up as a table literally named SET. A quoted `` `set` `` is a
    -- real, if rare, table and survives the check.
    local raw = vim.treesitter.get_node_text(node, buf)
    if raw and raw:lower() == "set" then return end
    name = unquote(name)
    if name == "" then return end
    if cte_names[name:lower()] then return end
    local key = name:lower() .. ":" .. node:start() .. ":" .. node:end_()
    if seen_tables[key] then return end
    seen_tables[key] = true
    local start_row, start_col = (start_node or node):range()
    local _, _, end_row, end_col = node:range()
    table.insert(tables, {
      name = name, db_prefix = db_prefix,
      lnum = start_row + 1, col = start_col + 1,
      end_lnum = end_row + 1, end_col = end_col + 1,
    })
  end

  local function add_column(name, tbl, node)
    name = unquote(name)
    if name == "" then return end
    local key = (tbl or "") .. "." .. name:lower() .. ":" .. node:start() .. ":" .. node:end_()
    if seen_cols[key] then return end
    seen_cols[key] = true
    local lnum, col, end_lnum, end_col = get_node_range(node)
    table.insert(columns, { name = name, table = tbl, lnum = lnum, col = col, end_lnum = end_lnum, end_col = end_col })
  end

  local function walk(node, context_stack)
    context_stack = context_stack or {}
    if node == nil then return end
    local nt = node:type()

    if nt == "from" then
      table.insert(context_stack, "from")
      for c in node:iter_children() do walk(c, context_stack) end
      table.remove(context_stack)
      return
    end

    if nt == "join" then
      table.insert(context_stack, "join")
      for c in node:iter_children() do walk(c, context_stack) end
      table.remove(context_stack)
      return
    end

    if nt == "insert" then
      table.insert(context_stack, "insert")
      for c in node:iter_children() do walk(c, context_stack) end
      table.remove(context_stack)
      return
    end

    -- A half-written statement arrives as an ERROR whose container is missing
    -- (`UPDATE t SET ▮ WHERE ;` has no `update` node at all) and only a bare
    -- `keyword_update`/`keyword_insert`/`keyword_delete` marks the verb. Enter
    -- that context for the rest of the ERROR's children so the table
    -- reference beside it is still read as a table, not as a column.
    -- Restricted to an ERROR parent: a complete statement always has its
    -- container node, and re-walking its children from here would duplicate
    -- every reference it holds.
    if nt == "keyword_update" or nt == "keyword_insert" or nt == "keyword_delete" then
      local parent = node:parent()
      if parent and parent:type() == "ERROR" then
        table.insert(context_stack, nt:sub(#"keyword_" + 1))
        for c in parent:iter_children() do
          if c:id() ~= node:id() then walk(c, context_stack) end
        end
        table.remove(context_stack)
        return
      end
    end

    if nt == "update" then
      table.insert(context_stack, "update")
      for c in node:iter_children() do walk(c, context_stack) end
      table.remove(context_stack)
      return
    end

    if nt == "delete" then
      table.insert(context_stack, "delete")
      for c in node:iter_children() do walk(c, context_stack) end
      table.remove(context_stack)
      return
    end

    if nt == "relation" then
      local tbl_name = nil
      local db_prefix = nil
      local alias = nil
      local tbl_node = nil
      for c in node:iter_children() do
        if c:type() == "object_reference" then
          local qualifier, name, name_node = dotted_reference(c)
          db_prefix = qualifier
          if name then
            tbl_name, tbl_node = name, name_node
          end
        elseif c:type() == "identifier" and tbl_name then
          alias = unquote(vim.treesitter.get_node_text(c, buf))
          if alias == "" then alias = nil end
        end
      end
      if tbl_name and tbl_node then
        local merged_name, span_start = merge_digit_fragment(buf, node, tbl_name, tbl_node)
        tbl_name = merged_name
        local is_from_or_join = false
        for _, ctx in ipairs(context_stack) do
          if ctx == "from" or ctx == "join" or ctx == "update" or ctx == "delete" or ctx == "insert" then
            is_from_or_join = true
            break
          end
        end
        if is_from_or_join then
          add_table(tbl_name, tbl_node, db_prefix, span_start)
          table.insert(from_tables, tbl_name)
          if alias then alias_map[alias] = tbl_name end
        end
      end
      return
    end

    if nt == "object_reference" then
      local is_in_insert = false
      for _, ctx in ipairs(context_stack) do
        if ctx == "insert" then is_in_insert = true; break end
      end
      if is_in_insert then
        local parent = node:parent()
        if parent and parent:type() == "invocation" then return end
        local qualifier, tn, tn_node, unqualified = dotted_reference(node)
        if tn then
          if unqualified then
            local merged, span_start = merge_digit_fragment(buf, node, tn, tn_node)
            add_table(merged, tn_node, nil, span_start)
            table.insert(from_tables, merged)
          else
            add_table(tn, tn_node, qualifier)
            table.insert(from_tables, tn)
          end
        end
        return
      end
    end

    if nt == "invocation" then
      -- tree-sitter-sql misparses `WITHIN GROUP (ORDER BY ...)` (ordered-set
      -- aggregates) as a call to a fake GROUP() function. GROUP is not a SQL
      -- function, so skip its argument list — otherwise ORDER/total inside
      -- it get extracted as phantom columns.
      for c in node:iter_children() do
        if c:type() == "object_reference" then
          local name = vim.treesitter.get_node_text(c, buf)
          if name and name:lower() == "group" then return end
          break
        end
      end
      for c in node:iter_children() do walk(c, context_stack) end
      return
    end

    if nt == "term" then
      -- Detect SELECT aliases: term → invocation + keyword_as + identifier
      -- e.g. AVG(metric_01) AS avg_load  → alias "avg_load"
      for c in node:iter_children() do
        if c:type() == "keyword_as" then
          local alias_node = c:next_sibling()
          if alias_node and alias_node:type() == "identifier" then
            local alias_name = vim.treesitter.get_node_text(alias_node, buf)
            if alias_name ~= "" then
              select_aliases[alias_name:lower()] = true
            end
          end
        end
        walk(c, context_stack)
      end
      return
    end

    if nt == "field" then
      local parts = {}
      for c in node:iter_children() do
        parts[#parts + 1] = { type = c:type(), text = vim.treesitter.get_node_text(c, buf), node = c }
      end
      if #parts == 3 and parts[1].type == "object_reference" and parts[2].type == "." and parts[3].type == "identifier" then
        -- The qualifier is itself a dotted list when the column is written out
        -- as `db.table.col`; the table is its last component, and the ones
        -- before it name the database/schema -- which database to check comes
        -- from the FROM clause, not from here. Taking the raw text used to
        -- look up a table named "otherdb.users", which never matches.
        local _, qualifier_tbl = dotted_reference(parts[1].node)
        local qualifier = qualifier_tbl or unquote(parts[1].text)
        if qualifier ~= "" then
          add_column(unquote(parts[3].text), alias_map[qualifier] or qualifier, parts[3].node)
        end
      elseif #parts == 1 and parts[1].type == "identifier" then
        local col_name = parts[1].text
        if col_name ~= "*" and not col_name:match("^@") then
          add_column(col_name, nil, parts[1].node)
        end
      end
      return
    end

    if nt == "column" then
      for c in node:iter_children() do
        if c:type() == "identifier" then
          local col_name = vim.treesitter.get_node_text(c, buf)
          if not col_name:match("^@") then
            add_column(col_name, nil, c)
          end
        end
      end
      return
    end

    for c in node:iter_children() do
      walk(c, context_stack)
    end
  end

  walk(stmt_node)
  return { tables = tables, columns = columns, alias_map = alias_map, from_tables = from_tables, select_aliases = select_aliases, ctes = cte_names }
end

--- True when a table reference points at a built-in system schema or (for
--- postgres) an unqualified pg_catalog relation. Such refs are exempt from
--- schema validation: their contents are version-specific and never returned
--- by ordinary introspection.
--- @param db_prefix string|nil  schema/database prefix in the reference
--- @param name string  table name
--- @param dialect string|nil  connection dialect (lowercase)
--- @return boolean
local function is_catalog_ref(db_prefix, name, dialect)
  if db_prefix and const.SYSTEM_SCHEMAS[db_prefix:lower()] then return true end
  if not db_prefix and const.is_pg_catalog_name(name) and dialect == "postgres" then
    return true
  end
  if not db_prefix and const.is_sqlite_system_name(name) then
    return true
  end
  return false
end

--- Resolve connection URL from a connection name.
local function resolve_conn_url(conn)
  if not conn or conn == "" then return nil end
  if const.dialect_from_url(conn:lower()) then return conn end
  local url, _ = connections.resolve_connection_url(conn)
  return url
end

--- Build schema lookup from cached data.
local function build_schema(tables, columns, db)
  local known = {}
  for _, t in ipairs(tables or {}) do known[t:lower()] = true end
  local col_lookup = {}
  for tbl, cols in pairs(columns or {}) do
    -- Folded like `known` above: unquoted identifiers fold to lowercase in
    -- postgres and are case-insensitive in MySQL/SQLite, and the cache can
    -- hold one table under two spellings because the fetch used to key it by
    -- the name as typed.
    local key = tbl:lower()
    col_lookup[key] = col_lookup[key] or {}
    for _, c in ipairs(cols or {}) do col_lookup[key][c:lower()] = true end
  end
  return { known_tables = known, columns = col_lookup, db = db }
end

--- Launch an introspect job and hand its decoded `items` list to `store`.
---
--- Both fetch helpers used to open-code this callback shape, and both could
--- leave the caller's in-flight flag set forever. Two measured Neovim
--- behaviours do that: `jobstart()` *throws* E475 when argv[0] is missing or
--- not executable (and argv[0] comes from `find_poste_binary`, so a binary
--- removed by a reinstall or a stale `g:poste_binary` reaches it), and a job
--- that exits without writing to stdout still fires `on_stdout` — with a
--- single empty line, which the old guards returned on without calling back.
--- `settle` guarantees the callback runs exactly once, so a failed fetch
--- re-arms the next `M.update()` instead of muting that buffer for the rest of
--- the session.
--- @param args string[]  argv, never a shell string: the binary path is user config
--- @param store fun(items: any[])  called with the decoded items on success
--- @param callback fun(success: boolean)
local function run_introspect(args, store, callback)
  local settled = false
  local function settle(success)
    if settled then return end
    settled = true
    callback(success)
  end

  local ok, job = pcall(vim.fn.jobstart, args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      data = util.ensure_job_data(data)
      if #data == 0 then return end
      local decoded, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
      if decoded and parsed and parsed.items then
        store(parsed.items)
        settle(true)
      else
        settle(false)
      end
    end,
    -- Exit without a decoded payload is a failure even for code 0: reporting
    -- success would re-enter the same cold-cache fetch on every update.
    on_exit = function() settle(false) end,
  })
  if not ok then
    -- The path is a filesystem location the plugin already prints in
    -- `:PosteDbInfo`, so naming it here is the diagnosis; the connection URL
    -- in the same argv is not repeated anywhere.
    pcall(state.log, "WARN", "semantic_diagnostics: cannot launch poste binary: " .. tostring(args[1]))
    settle(false)
  elseif type(job) ~= "number" or job <= 0 then
    settle(false)
  end
end

--- Fetch tables for a database and cache them.
--- Calls the Rust CLI directly. Stores in _schema_cache with key conn.."/"..db.
--- Calls callback(true) on success, callback(false) on failure.
local function fetch_tables(buf, conn, db, callback)
  local binary = state.find_poste_binary()
  if not binary then callback(false); return end

  local url = resolve_conn_url(conn)
  if not url then callback(false); return end

  local cache_key = conn .. "/" .. db
  local args = { binary, "introspect", "--connection-url", url,
    "--type", "tables", "--database", db }

  run_introspect(args, function(items)
    _schema_cache[cache_key] = _schema_cache[cache_key] or { tables = {}, columns = {} }
    _schema_cache[cache_key].tables = vim.tbl_map(function(i) return i.name end, items)
  end, callback)
end

--- Fetch columns for a table and cache them.
--- Stores in _schema_cache with key conn.."/"..db.
local function fetch_columns(buf, conn, db, tbl, callback)
  local binary = state.find_poste_binary()
  if not binary then callback(false); return end

  local url = resolve_conn_url(conn)
  if not url then callback(false); return end

  local cache_key = conn .. "/" .. db
  local args = { binary, "introspect", "--connection-url", url,
    "--type", "columns", "--table", tbl, "--database", db }

  run_introspect(args, function(items)
    _schema_cache[cache_key] = _schema_cache[cache_key] or { tables = {}, columns = {} }
    _schema_cache[cache_key].columns[tbl:lower()] = vim.tbl_map(function(i) return i.name end, items)
  end, callback)
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.diagnostic.reset(ns, buf)
    vim.api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)
  end
  _pending_checks[buf] = nil
end

--- Invalidate the cached schema after DDL (CREATE/ALTER/DROP/TRUNCATE/RENAME).
--- Clears the cache entry for the connection/database so the next M.update()
--- re-introspects and picks up newly created tables. When db is nil/empty the
--- whole connection's cached databases are dropped.
--- @param conn string|nil connection name
--- @param db string|nil database name
function M.invalidate(conn, db)
  if not conn or conn == "" then
    _schema_cache = {}
    return
  end
  if db and db ~= "" then
    _schema_cache[conn .. "/" .. db] = nil
    return
  end
  local prefix = conn .. "/"
  for k in pairs(_schema_cache) do
    if k:sub(1, #prefix) == prefix then
      _schema_cache[k] = nil
    end
  end
end

function M.update(buf)
  if _updating then return end
  _updating = true

  local ok, err = pcall(function()
    if not vim.api.nvim_buf_is_valid(buf) then _updating = false; return end
    local ft = vim.bo[buf].filetype
    if ft ~= "poste_sql" and ft ~= "poste_sqlite" and ft ~= "sql" then _updating = false; return end
    if not check_parser() then _updating = false; return end

    local default_ctx = context.resolve_full_context(buf, vim.api.nvim_buf_line_count(buf))
    if not default_ctx.connection then _updating = false; return end

    local stmt_nodes = get_statement_nodes(buf)
    if not stmt_nodes then
      vim.diagnostic.reset(ns, buf)
      vim.api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)
      _updating = false
      return
    end

    local diags = {}
    -- Keyed by "<database>.<table as written>": the same table name in two
    -- databases of one file is two different column lists.
    local pending_column_fetches = {}
    local dialect_for = {}
    local schemas_built = {}

    local function get_dialect(conn)
      if conn == nil or conn == "" then return nil end
      if dialect_for[conn] == nil then
        local cfg = connections.get_connection_config(conn)
        dialect_for[conn] = (cfg and cfg.dialect and cfg.dialect ~= "")
          and cfg.dialect:lower() or false
      end
      return dialect_for[conn] or nil
    end

    --- The schema a reference should be checked against, or nil when that
    --- database has no cached table list.
    ---
    --- A cached-but-different database must not fall back to the statement's
    --- own schema. `SELECT full_name FROM otherdb.users` used to be validated
    --- against `blog`'s `users`, so a real column was reported missing and a
    --- typo that happened to name a `blog.users` column was accepted -- wrong
    --- in both directions, with a message naming the database it never read.
    --- "not cached" is therefore "cannot check", never "wrong".
    --- @param conn string
    --- @param db string
    --- @return table|nil
    local function schema_for(conn, db)
      local key = conn .. "/" .. db
      local built = schemas_built[key]
      if built == nil then
        local cached = _schema_cache[key]
        built = (cached and cached.tables and #cached.tables > 0)
          and build_schema(cached.tables, cached.columns or {}, db) or false
        schemas_built[key] = built
      end
      return built or nil
    end

    for _, stmt_node in ipairs(stmt_nodes) do
      local stmt_line = stmt_node:start() + 1

      local ctx = context.resolve_full_context(buf, stmt_line)
      local conn = ctx.connection or default_ctx.connection
      local db = ctx.database or default_ctx.database
      if not conn or not db then goto continue end

      local schema = schema_for(conn, db)
      if not schema then
        if not _pending_checks[buf] then
          _pending_checks[buf] = true
          fetch_tables(buf, conn, db, function(success)
            _pending_checks[buf] = nil
            if success and vim.api.nvim_buf_is_valid(buf) then
              vim.schedule(function()
                M.update(buf)
              end)
            end
          end)
        end
        goto continue
      end

      local refs = extract_references_from_node(stmt_node, buf)
      if #refs.tables == 0 and #refs.columns == 0 then goto continue end

      -- Which database a column's table lives in comes from the FROM list, so
      -- record it there while the qualified names are still in hand. `false`
      -- marks a name used by two different databases in one statement -- an
      -- unresolvable tie, and guessing would recreate the fallback bug above.
      local ref_db = {}

      for _, tbl in ipairs(refs.tables) do
        -- Built-in system schemas (pg_catalog, information_schema, mysql, ...)
        -- hold version-specific tables that introspection never returns; in
        -- postgres pg_catalog relations also resolve without a prefix
        -- (`FROM pg_tables`). Either way this is not a schema error.
        if is_catalog_ref(tbl.db_prefix, tbl.name, get_dialect(conn)) then
          goto continue_table
        end
        local target_db = tbl.db_prefix or db
        local lower = tbl.name:lower()
        local target_schema = schema_for(conn, target_db)
        if not target_schema then
          -- That database has no cached table list, so nothing is known about
          -- this table -- and it must not be recorded as belonging to the
          -- statement's own database either, or the columns it qualifies would
          -- be checked against the wrong list. `false` already means "this name
          -- has no single database to check", so unqualified columns of the
          -- same name are skipped below.
          if tbl.db_prefix then ref_db[lower] = false end
        else
          local seen_db = ref_db[lower]
          if seen_db == nil then
            ref_db[lower] = target_db
          elseif seen_db ~= false and seen_db ~= target_db then
            ref_db[lower] = false
          end
          if not target_schema.known_tables[lower] then
            table.insert(diags, {
              lnum = tbl.lnum - 1,
              col = tbl.col - 1,
              end_lnum = tbl.end_lnum - 1,
              end_col = tbl.end_col - 1,
              severity = vim.diagnostic.severity.WARN,
              source = "poste-db",
              message = string.format("Table '%s' not found in database '%s'", tbl.name, target_db),
            })
          end
        end
        ::continue_table::
      end

      --- Why this column is unknown to the table that qualifies it, or nil
      --- when nothing can be said about it.
      --- @param col table  one entry of `refs.columns`
      --- @param tbl_name string  the qualifier, alias-resolved during extraction
      --- @return string|nil message
      local function column_problem(col, tbl_name)
        local db_of_ref = ref_db[tbl_name:lower()]
        if db_of_ref == false then return nil end
        local target_db = db_of_ref or db
        local target_schema = schema_for(conn, target_db)
        local lower_tbl = tbl_name:lower()
        if not target_schema or not target_schema.known_tables[lower_tbl] then
          return nil
        end
        -- `next(cols) == nil` is an empty cached list, which no real table can
        -- have: treat it as not known yet rather than as "this table has no
        -- columns", which would flag every reference to it.
        local cols = target_schema.columns[lower_tbl]
        if not cols or not next(cols) then
          local key = target_db .. "." .. lower_tbl
          if not pending_column_fetches[key] then
            pending_column_fetches[key] = { conn = conn, db = target_db, tbl = tbl_name }
          end
          return nil
        end
        if cols[col.name:lower()] then return nil end
        return string.format("Column '%s' not found in table '%s'", col.name, tbl_name)
      end

      for _, col in ipairs(refs.columns) do
        -- Skip columns that match a SELECT alias (e.g. ORDER BY alias ref)
        if refs.select_aliases and refs.select_aliases[col.name:lower()] then goto continue_col end
        -- An unqualified column is only checkable when the statement has one
        -- table; with a join there is no way to know which side it came from.
        local message
        if col.table then
          message = column_problem(col, col.table)
        elseif #refs.from_tables == 1 then
          message = column_problem(col, refs.from_tables[1])
        end
        if message then
          table.insert(diags, {
            lnum = col.lnum - 1,
            col = col.col - 1,
            end_lnum = col.end_lnum - 1,
            end_col = col.end_col - 1,
            severity = vim.diagnostic.severity.WARN,
            source = "poste-db",
            message = message,
          })
        end
        ::continue_col::
      end

      ::continue::
    end

    vim.diagnostic.set(ns, buf, diags, { priority = 200 })
    vim.api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)
    for _, d in ipairs(diags) do
      vim.api.nvim_buf_set_extmark(buf, ns_hl, d.lnum, d.col, {
        end_row = d.end_lnum,
        end_col = d.end_col,
        hl_group = "DiagnosticWarn",
        hl_mode = "combine",
        priority = 200,
      })
    end

    for _, pending in pairs(pending_column_fetches) do
      if _pending_checks[buf] then _updating = false; return end
      _pending_checks[buf] = true
      fetch_columns(buf, pending.conn, pending.db, pending.tbl, function(success)
        _pending_checks[buf] = nil
        if success and vim.api.nvim_buf_is_valid(buf) then
          vim.schedule(function()
            M.update(buf)
          end)
        end
      end)
    end
    _updating = false
  end)

  if not ok then
    _updating = false
    -- The handler must never throw: in a session that cached pre-dissolution
    -- modules, `state.log` itself can be nil, and letting it error here would
    -- crash the FileType autocmd and mask the original `err`.
    pcall(state.log, "ERROR", "semantic_diagnostics: " .. tostring(err))
  end
end

M._test = {
  extract_references_from_node = extract_references_from_node,
  is_catalog_ref = is_catalog_ref,
  invalidate = M.invalidate,
  cache_keys = function()
    local keys = {}
    for k in pairs(_schema_cache) do keys[#keys + 1] = k end
    return keys
  end,
  set_cache = function(key, value)
    _schema_cache[key] = value
  end,
}

return M