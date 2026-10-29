local cli = require("poste-db.cli")
local util = require("poste-db.util")
local sql_conn = require("poste-db.db_browser.sql_conn")
local catalog = require("poste-db.db_browser.catalog")
local notify = require("poste-db.db_browser.notify")
local ident = require("poste-db.ident")
local const = require("poste-db.constants")

local M = {}


-- Shared identifier quoting (dialect-aware backtick/double-quote).
local quote = ident.quote

-- Pure DDL/result transform helpers (see copy_ddl.lua).
local copy_ddl = require("poste-db.db_browser.copy_ddl")
local has_value = copy_ddl.has_value
local quote_value = copy_ddl.quote_value
local extract_row_count = copy_ddl.extract_row_count
local extract_elapsed = copy_ddl.extract_elapsed
local check_result_error = copy_ddl.check_result_error
local extract_schema_from_ddl = copy_ddl.extract_schema_from_ddl
local prepare_table_ddl = copy_ddl.prepare_table_ddl
local dialect_table_exists_sql = copy_ddl.dialect_table_exists_sql
local rename_routine_in_def = copy_ddl.rename_routine_in_def

-- Paste confirm/progress/summary dialogs (see copy_progress.lua).
local copy_progress = require("poste-db.db_browser.copy_progress")
local show_paste_confirm = copy_progress.show_paste_confirm
local show_paste_progress = copy_progress.show_paste_progress

--- Run `sql` on conn/database; on_result receives the raw JSON envelope.
local function run_sql_on_conn(conn_name, database, sql, on_result, on_error)
  sql_conn.run(conn_name, database, sql, on_result, on_error)
end

local function introspect_ddl(conn_name, db_name, table_name, on_result, on_error, schema_name)
  local binary = cli.binary()
  if not binary then
    if on_error then on_error("Poste binary not found") end
    return
  end

  local connections = require("poste-db.connections")
  local url, err = connections.resolve_connection_url(conn_name)
  if not url then
    if on_error then on_error(err or "unknown error") end
    return
  end

  local args = {
    binary,
    "introspect",
    "--connection-url", url,
    "--type", "ddl",
    "--table", table_name,
  }
  -- A browser layout's `db` is a listing-row name, so it can be `""` or a
  -- JSON null; either would become `--database`, which the CLI applies as
  -- replace_database_in_url — the DDL (and then the paste) would read a
  -- different database than the node the user copied. Inside the table
  -- constructor a nil `db_name` also truncated `args` at the hole.
  local db = util.named(db_name)
  if db then
    table.insert(args, "--database"); table.insert(args, db)
  end
  -- The schema must ride along: the binary's postgres DDL arm defaults to
  -- `public` when --schema is absent, so the yanked `app.events` fetched the
  -- DDL of public.events — a same-named public table was silently recreated
  -- and copied IN ITS PLACE, and without one the paste errored "No DDL found".
  local schema = util.named(schema_name)
  if schema then
    table.insert(args, "--schema"); table.insert(args, schema)
  end

  local stderr_buf = {}
  -- jobstart raises E475 when the binary vanished between cli.binary() and
  -- this call; unwrapped, the raise escaped the context-menu action instead
  -- of answering through the same on_error a dead job reports
  local ok_job, job = pcall(vim.fn.jobstart, args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      data = util.ensure_job_data(data)
      if #data == 0 then return end
      local output = table.concat(data, "\n")
      vim.schedule(function()
        if on_result then on_result(output) end
      end)
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(stderr_buf, l) end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 and on_error then
        vim.schedule(function()
          local msg = table.concat(stderr_buf, "\n")
          if msg == "" then msg = "DDL introspection failed with code " .. code end
          on_error(msg)
        end)
      end
    end,
  })
  if not ok_job and on_error then
    on_error("DDL introspection could not start: " .. tostring(job))
  end
end

local function check_table_exists(conn_name, database, dialect, name, on_result, on_error, schema)
  local sql = dialect_table_exists_sql(dialect, schema, name)
  run_sql_on_conn(conn_name, database, sql, function(output)
    -- "The lookup was refused" and "there is no such table" are the same empty
    -- answer to a reader that only counts rows, and this one used to answer
    -- `false`: the wizard then offered to create a table that was already there
    -- (and, with `CREATE OR REPLACE`-style dialects, could replace it). Go through
    -- the shared decoder so a failed statement reaches `on_error` instead.
    local ok_first, result = sql_conn.decode_first_result(output)
    if not ok_first then
      if on_error then on_error(tostring(result)) end
      return
    end
    local exists = false
    local r = result.rows
    if r and #r > 0 and r[1] and #r[1] > 0 then
      local val = r[1][1]
      exists = (type(val) == "boolean" and val) or (type(val) == "string" and val ~= "")
    end
    on_result(exists)
  end, on_error)
end

-- --------------------------------------------------------- conflict naming

--- Ceiling on the `<name>_copy` / `_copy2` / … auto-suffix search. See
--- `bump_until_free`.
local MAX_NAME_BUMPS = 100

local function make_default_input()
  ---@param prompt string
  ---@param default string
  ---@param cb function(string|nil)
  return function(prompt, default, cb)
    vim.ui.input({ prompt = prompt, default = default }, function(text)
      if text ~= nil and text == "" then text = nil end
      cb(text)
    end)
  end
end

--- Resolve target names for pasted items when originals already exist there.
---
--- - free name                → kept as-is
--- - colliding name           → dialog prefilled with <name>_copy (auto-bumped
---                              to _copy2… while occupied); user may type any
---                              name, which is itself re-checked and bumped
---                              automatically if taken
--- - cancelling the dialog    → aborts the whole paste (on_cancel)
---
--- With `opts.skip_dialogs` the same collision search runs silently: every
--- colliding item takes its first free `_copy` name and `on_cancel` never
--- fires. That is how `paste_objects` calls this today — the paste is one
--- confirm dialog away, and its progress view lists the resulting names.
---
---@param target table {conn, db, dialect}
---@param items table[] {name=..., schema=?}
---@param on_resolved function(names string[]) parallel to items
---@param on_cancel function()
---@param opts table|nil {skip_dialogs=bool}
function M.resolve_conflict_names(target, items, on_resolved, on_cancel, opts)
  opts = opts or {}
  local hooks = _G.poste_db_copy_test_hooks or {}
  local exists_fn = hooks.exists
    or function(t, name, schema, cb)
      -- `schema` must reach the probe: on postgres the paste recreates the
      -- table under its source schema (the fetched DDL carries the qualifier),
      -- while the probe's `schema` parameter defaulted to "public". Dropping
      -- it made every collision check answer about the wrong namespace — a
      -- taken name in `app` looked free (CREATE then fails) and a taken name
      -- in `public` bumped a free `app` table to a pointless `_copy`.
      check_table_exists(t.conn, t.db, t.dialect, name, cb, function(err)
        vim.schedule(function() vim.notify("Copy: " .. tostring(err), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE }) end)
        cb(true) -- fail closed: pretend it exists rather than clobber it
      end, schema)
    end
  local input_fn = hooks.input or make_default_input()

  -- Pre-collect all collisions up-front so dialogs only appear when needed.
  local collision_state = {} --- [i] = {base=<new base or nil>}
  if #items == 0 then on_resolved({}) return end

  local function proceed_with_resolution()
    local results = {}
    local aborted = false

    local function finish()
      if not aborted then on_resolved(results) end
    end

    local function bump_until_free(i, base, suffix, cb)
      -- The probe fails closed (a permission error on information_schema, a
      -- connection that died mid-paste), so an unbounded search here is an
      -- unbounded stream of queries that never resolves. Past the cap, return
      -- the candidate as-is and let CREATE fail loudly instead of hanging.
      if suffix > MAX_NAME_BUMPS then
        cb(base .. "_copy" .. tostring(suffix))
        return
      end
      local candidate = base .. "_copy" .. (suffix > 1 and tostring(suffix) or "")
      exists_fn(target, candidate, items[i].schema, function(found)
        if not found then cb(candidate) else bump_until_free(i, base, suffix + 1, cb) end
      end)
    end

    local function step(i)
      if aborted then return end
      if i > #items then finish() return end
      local state_i = collision_state[i]
      if not state_i then
        results[i] = items[i].name
        step(i + 1)
        return
      end
      bump_until_free(i, items[i].name, 1, function(safe_default)
        if opts.skip_dialogs then
          results[i] = safe_default
          step(i + 1)
          return
        end
        input_fn(
          "Name for '" .. items[i].name .. "'"
            .. " at " .. target.conn .. "." .. tostring(target.db or "") .. ": ",
          safe_default,
          function(chosen)
            if chosen == nil then
              aborted = true
              on_cancel()
              return
            end
            exists_fn(target, chosen, items[i].schema, function(found2)
              if found2 and chosen ~= safe_default then
                notify.info("'" .. chosen .. "' also exists — using an automatic suffix")
                bump_until_free(i, chosen, 1, function(bumped)
                  results[i] = bumped
                  step(i + 1)
                end)
              else
                results[i] = chosen
                step(i + 1)
              end
            end)
          end
        )
      end)
    end

    step(1)
  end

  local function probe_next(i)
    if i > #items then
      proceed_with_resolution()
      return
    end
    exists_fn(target, items[i].name, items[i].schema, function(found)
      if found then collision_state[i] = { base = items[i].name } end
      probe_next(i + 1)
    end)
  end

  probe_next(1)
end

--- Inspect one `run_sql_on_conn` envelope: transport error, undecodable body,
--- a statement that said why it failed, or the aggregate failure flag set with
--- nothing to show for it. Returns `true, decoded_body` only when all four are
--- clean, so a caller's success path cannot be reached by a rejected statement.
local function check_response(output, label, on_error)
  local ok, parsed = pcall(vim.json.decode, output)
  if not ok or not parsed then
    on_error("Failed to parse " .. label .. " response")
    return false
  end
  local err = parsed.error
  if has_value(err) then
    on_error(tostring(err))
    return false
  end
  local body = parsed.body
  if not body then
    on_error("No body in " .. label .. " response")
    return false
  end
  local ok_body, decoded = pcall(vim.json.decode, body)
  if not ok_body or not decoded then
    on_error("Failed to decode " .. label .. " body")
    return false
  end
  local r_err = check_result_error(decoded)
  if r_err then
    on_error(tostring(r_err))
    return false
  end
  -- `status`/`has_error` on the envelope are the binary's own verdict, and they
  -- are not the same field as a result's text: a driver can flag the statement
  -- without saying why, and a response can carry the verdict without carrying a
  -- result at all. Falling through here would have clone report "copied" about a
  -- statement the server rejected.
  if parsed.has_error or parsed.status == "error" or decoded.has_error then
    on_error("the response reported a failure whose statement carried no message")
    return false
  end
  return true, decoded
end

local function copy_data_same_server(source, target, schema, table_name, target_table_name, on_done, on_error)
  local q = function(n) return quote(n, source.dialect) end
  local function tbl(name)
    if schema and source.dialect ~= "sqlite" then
      return q(schema) .. "." .. q(name)
    end
    return q(name)
  end
  local insert_sql = "INSERT INTO " .. tbl(target_table_name) .. " SELECT * FROM " .. tbl(table_name) .. ";"

  run_sql_on_conn(target.conn, target.db, insert_sql, function(insert_output)
    -- Every other write in this file goes through `check_response`; this one
    -- used to re-spell the decode and stopped at `error`, so the shapes it did
    -- not look at — the flag without the text — landed on `on_done` as copied
    -- rows that were never inserted.
    local ok, decoded = check_response(insert_output, "INSERT of " .. table_name, on_error)
    if not ok then return end
    local r = decoded.results and decoded.results[1]
    if not r then
      on_error("No result in INSERT response for " .. table_name)
      return
    end
    on_done(extract_row_count(r), extract_elapsed(r))
  end, on_error)
end

local function copy_data_cross_server(source, target, schema, table_name, target_table_name, on_done, on_error)
  local q = function(n) return quote(n, source.dialect) end
  local function tbl(name)
    if schema and source.dialect ~= "sqlite" then
      return q(schema) .. "." .. q(name)
    end
    return q(name)
  end
  local select_sql = "SELECT * FROM " .. tbl(table_name) .. ";"

  run_sql_on_conn(source.conn, source.db, select_sql, function(select_output)
    local ok, decoded = check_response(select_output, "SELECT", on_error)
    if not ok then return end

    local r = decoded.results and decoded.results[1]
    if not r then
      on_error("No result in SELECT response for " .. table_name)
      return
    end
    local columns = r.columns
    local rows = r.rows
    if not columns or not rows then
      on_error("No columns or rows in SELECT result for " .. table_name)
      return
    end
    if #rows == 0 then
      on_done("0", "0ms")
      return
    end

    local col_names = {}
    for _, col in ipairs(columns) do
      table.insert(col_names, q(col.name))
    end
    local col_list = table.concat(col_names, ", ")

    local total_rows = 0
    local total_elapsed = "?"
    local batch_size = 500
    local function insert_batch(start_idx)
      if start_idx > #rows then
        on_done(tostring(total_rows), total_elapsed)
        return
      end

      local end_idx = math.min(start_idx + batch_size - 1, #rows)
      local value_groups = {}
      for i = start_idx, end_idx do
        local row = rows[i]
        local vals = {}
        for j = 1, #row do
          table.insert(vals, quote_value(row[j], source.dialect))
        end
        table.insert(value_groups, "(" .. table.concat(vals, ", ") .. ")")
      end

      local insert_sql = "INSERT INTO " .. tbl(target_table_name)
        .. " (" .. col_list .. ") VALUES\n"
        .. table.concat(value_groups, ",\n")
        .. ";"

      run_sql_on_conn(target.conn, target.db, insert_sql, function(insert_output)
        local ok_insert, ins_decoded = check_response(insert_output, "INSERT", on_error)
        if not ok_insert then return end
        local ins_row = ins_decoded.results and ins_decoded.results[1]
        if ins_row then
          total_elapsed = extract_elapsed(ins_row)
        end
        total_rows = total_rows + (end_idx - start_idx + 1)
        insert_batch(end_idx + 1)
      end, on_error)
    end

    insert_batch(1)
  end, on_error)
end

local function copy_one_table(source, target, table_name, target_table_name, on_done, on_error)
  local same_server = source.conn == target.conn
  local same_db = source.db == target.db

  introspect_ddl(source.conn, source.db, table_name, function(ddl_output)
    local ok, parsed = pcall(vim.json.decode, ddl_output)
    if not ok or not parsed then
      on_error("Failed to parse DDL for " .. table_name)
      return
    end

    local items = parsed.items
    if not items or #items == 0 or not items[1].ddl then
      on_error("No DDL found for " .. table_name)
      return
    end

    local ddl = items[1].ddl
    local schema = extract_schema_from_ddl(ddl, table_name, source.dialect)
    local ddl_prepared = prepare_table_ddl(ddl, target_table_name, table_name, schema, source.dialect)

    run_sql_on_conn(target.conn, target.db, ddl_prepared, function(ddl_resp)
      local ok_ddl = check_response(ddl_resp, "DDL", on_error)
      if not ok_ddl then return end
      if same_server and same_db then
        copy_data_same_server(source, target, schema, table_name, target_table_name, on_done, on_error)
      else
        copy_data_cross_server(source, target, schema, table_name, target_table_name, on_done, on_error)
      end
    end, on_error)
  end, on_error, source.schema)
end

-- --------------------------------------------------------------- executors

local KIND_TAGS = {
  view = " (view)",
  trigger = " (trigger)",
  PROCEDURE = " (procedure)",
  FUNCTION = " (function)",
}

local function execute_sql_on_target(target, sql, cb)
  run_sql_on_conn(target.conn, target.db, sql, function(output)
    local ok = check_response(output, "execute", function(err) cb(false, nil, nil, err) end)
    if not ok then return end
    cb(true, "-", "?")
  end, function(err) cb(false, nil, nil, err) end)
end


-- ------------------------------------------------------------ orchestration

local function default_item_context(entry, ctx_defaults)
  entry.conn = entry.conn or ctx_defaults.conn
  entry.db = entry.db or ctx_defaults.db
  entry.dialect = entry.dialect or ctx_defaults.dialect
  return entry
end

--- Copy/paste pipeline shared by yank-paste and legacy multi-select.
---
--- Stage 1 probe sizes (async, tolerant) →
--- Stage 2 resolve conflicts (tables/views only; auto-renamed silently,
---           see resolve_conflict_names / skip_dialogs) →
--- Stage 3 confirm dialog → Stage 4 sequential execution with progress.
---
---@param source table {conn, db, dialect}
---@param target table {conn, db, dialect}
---@param items table[] {kind="table"|"view", name, conn?, db?, dialect?}
---@param triggers table[] parsed catalog trigger rows
---@param routines table[] {name, rtype, conn?, db?, dialect?}
---@param opts table|nil {on_complete=function()}
function M.paste_objects(source, target, items, triggers, routines, opts)
  opts = opts or {}

  if source.dialect ~= target.dialect then
    vim.notify(string.format(
      "Cannot paste: dialect mismatch (%s → %s). Both must be the same dialect.",
      source.dialect, target.dialect), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end
  if #items == 0 and #triggers == 0 and #routines == 0 then
    notify.info("Nothing to paste")
    return
  end

  local norm_items = {}
  for _, it in ipairs(items) do
    table.insert(norm_items, default_item_context(it, source))
  end
  local norm_routines = {}
  for _, r in ipairs(routines) do
    table.insert(norm_routines, default_item_context(r, source))
  end

  local resolvable = {}
  for _, it in ipairs(norm_items) do
    table.insert(resolvable, it) -- keep reference order stable
  end

  -- Views fetch their definitions lazily at execution time, so cache them
  -- here only when the item itself names one (no-op otherwise).

  catalog.sizes({ conn = source.conn, db = source.db, dialect = source.dialect }, function(sizes)
    M.resolve_conflict_names(target, resolvable, function(names)
      local plan = {}
      for i, it in ipairs(norm_items) do
        table.insert(plan, {
          kind = it.kind,
          orig = it.name,
          final = names[i] or it.name,
          schema = it.schema,
          kind_tag = it.kind == "view" and KIND_TAGS.view or "",
        })
      end
      for _, t in ipairs(triggers) do
        table.insert(plan, {
          kind = "trigger",
          orig = tostring(t.name),
          final = tostring(t.name),
          kind_tag = KIND_TAGS.trigger,
        })
      end
      for _, r in ipairs(norm_routines) do
        table.insert(plan, {
          kind = "routine",
          orig = r.name,
          final = r.name,
          rtype = r.rtype,
          kind_tag = KIND_TAGS[r.rtype] or "",
        })
      end

      show_paste_confirm(source, target, plan, sizes, function()
        local jobs = {}

        for i, it in ipairs(norm_items) do
          local final_name = plan[i].final
          if it.kind == "view" then
            jobs[#jobs + 1] = {
              label = final_name,
              tag = KIND_TAGS.view,
              work = function(cb)
                catalog.fetch_view_definition(
                  -- schema rides along so the postgres lookup targets the
                  -- view's own namespace instead of "public or first match".
                  { conn = it.conn, db = it.db, dialect = it.dialect,
                    name = it.name, schema = it.schema },
                  function(body, err)
                    if not body then cb(false, nil, nil, err); return end
                    -- Same schema placement the table DDL carries: the view
                    -- lands in its source namespace (an absent target schema
                    -- fails the paste loudly, like the CREATE TABLE it would
                    -- otherwise silently misplace).
                    local qualified = it.schema and it.schema ~= ""
                      and quote(it.schema, target.dialect) .. "." .. quote(final_name, target.dialect)
                      or quote(final_name, target.dialect)
                    local create_sql = "CREATE VIEW " .. qualified
                      .. " AS " .. body
                    execute_sql_on_target(target, create_sql, cb)
                  end)
              end,
            }
          else
            jobs[#jobs + 1] = {
              label = final_name,
              work = function(cb)
                copy_one_table(it, target, it.name, final_name,
                  function(row_count, elapsed) cb(true, row_count, elapsed) end,
                  function(err) cb(false, nil, nil, err) end)
              end,
            }
          end
        end

        for _, t in ipairs(triggers) do
          jobs[#jobs + 1] = {
            label = tostring(t.name),
            tag = KIND_TAGS.trigger,
            work = function(cb)
              local sql = catalog.compose_trigger_sql(target.dialect, t)
              execute_sql_on_target(target, sql, cb)
            end,
          }
        end

        for ji, r in ipairs(norm_routines) do
          local plan_entry = plan[#norm_items + #triggers + ji]
          jobs[#jobs + 1] = {
            label = plan_entry.final,
            tag = plan_entry.kind_tag,
            work = function(cb)
              catalog.fetch_routine_definition(r, function(def, err)
                if not def then cb(false, nil, nil, err); return end
                local sql = def
                if plan_entry.final ~= r.name then
                  sql = rename_routine_in_def(r.dialect, def, r.name, plan_entry.final)
                end
                execute_sql_on_target(target, sql, cb)
              end)
            end,
          }
        end

        -- cancel now lives on the progress dialog itself (the `c` key)
        local start_fn = show_paste_progress(source, target, jobs, function()
          if opts.on_complete then opts.on_complete() end
        end)
        start_fn()
      end, function()
        -- user cancelled at confirm
      end)
    end, function()
      -- user aborted during conflict naming
    end, { skip_dialogs = true })
  end)
end

--- Run CREATE DATABASE on a connection (no database override → the URL's
--- default database is used as the session database, which is fine for
--- postgres/mysql CREATE DATABASE).
local function create_database(conn, dialect, new_db, on_done, on_error)
  local q = function(n) return quote(n, dialect) end
  local create_sql = "CREATE DATABASE " .. q(new_db) .. ";"
  run_sql_on_conn(conn, nil, create_sql, function(output)
    local ok, decoded = check_response(output, "CREATE DATABASE", on_error)
    if not ok then return end
    on_done(decoded)
  end, on_error)
end

--- Pick a free default clone name: `<base>`, else `<base>2`, `<base>3`, …
--- (matching the sibling-database set).
---@param base string e.g. "blog_copy"
---@param existing table<string,true> existing database names
---@return string
local function pick_clone_default(base, existing)
  if not existing[base] then return base end
  local n = 2
  while existing[base .. tostring(n)] do
    n = n + 1
  end
  return base .. tostring(n)
end

--- Clone a whole database into a NEW database on the target connection.
---
--- Flow: prompt for a name (default `<src>_copy`, auto-bumped free) →
--- CREATE DATABASE → enumerate source objects → paste_objects into the new db.
--- The paste engine reuses its cross-server SELECT+INSERT path because the
--- target database differs from the source, even on the same server.
---
---@param source table {conn, db, dialect} yanked source database
---@param target table {conn, dialect} target connection (non-sqlite)
---@param opts table|nil {on_complete=function()}
function M.clone_database(source, target, opts)
  opts = opts or {}

  if not source.db then
    vim.notify("Cannot clone: no source database name.", vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end
  if source.dialect ~= target.dialect then
    vim.notify(string.format("Cannot clone: dialect mismatch (%s → %s).",
      source.dialect, target.dialect), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
    return
  end

  local async = require("poste-db.db_browser.async")
  local browser = require("poste-db.db_browser")
  local base_name = source.db .. "_copy"

  async.run_introspect(target.conn, "databases", nil, nil, nil, function(result)
    local existing = {}
    if result and result.items then
      for _, it in ipairs(result.items) do existing[it.name] = true end
    end
    local default = pick_clone_default(base_name, existing)

    vim.ui.input({
      prompt = "New database name (" .. target.conn .. "): ",
      default = default,
    }, function(chosen)
      if not chosen or chosen == "" then return end
      if existing[chosen] then
        notify.warn("Database '" .. chosen .. "' already exists on " .. target.conn)
        return
      end
      create_database(target.conn, target.dialect, chosen, function()
        catalog.enumerate(source, function(objects, triggers, routines)
          M.paste_objects(source, {
            conn = target.conn, db = chosen, dialect = target.dialect,
          }, objects, triggers, routines, { on_complete = opts.on_complete })
        end, function(err)
          vim.notify("Failed to enumerate objects for clone: " .. tostring(err), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
        end)
      end, function(err)
        vim.schedule(function()
          vim.notify("Clone failed to create database: " .. tostring(err), vim.log.levels.ERROR, { title = const.PLUGIN_TITLE })
        end)
      end)
    end)
  end, browser.get_search_dir())
end

--- Legacy compat shim for the old multi-select copy path (init.lua:start_copy).
--- Converts a list of {name, [schema]} selections into items and delegates to
--- paste_objects; a bare string is tolerated for very old callers.
function M.copy_tables(source, target, table_selections, on_complete)
  local items = {}
  for _, sel in ipairs(table_selections) do
    if type(sel) == "string" then sel = { name = sel } end
    table.insert(items, {
      kind = "table",
      name = sel.name,
      schema = sel.schema,
      conn = source.conn,
      db = source.db,
      dialect = source.dialect,
    })
  end
  M.paste_objects(source, target, items, {}, {}, { on_complete = on_complete })
end

M._test = {
  pick_clone_default = pick_clone_default,
  show_paste_progress = show_paste_progress,
  check_response = check_response,
  introspect_ddl = introspect_ddl,
  MAX_NAME_BUMPS = MAX_NAME_BUMPS,
}

return M
