--- Go-to-definition --- context detection via Rust CLI, route dispatch.
local const = require("poste-db.constants")
local util = require("poste-db.util")

local M = {}

local function pick_table_match(parsed_tables, word_lower)
  local matched = nil
  local schema_matched = nil
  for _, t in ipairs(parsed_tables or {}) do
    -- Names arrive in their source spelling (`` `users` `` from a MySQL
    -- buffer); the bare cword only matches unquoted. Same strip the
    -- introspect sibling (introspect/context.lua) applies to the same JSON.
    local tn = util.unquote_ident(t.name):lower()
    local ta = util.unquote_ident(t.alias):lower()
    local ts = (t.schema or ""):lower()
    if tn == word_lower then
      matched = t
      break
    end
    if ta == word_lower then
      matched = t
      break
    end
    if ts == word_lower then
      schema_matched = t
    end
  end
  return matched, schema_matched
end

--- A `navigate_to_table` target. The dotted prefix the detector reports on
--- an entry (`schema`) is handed back AS a prefix, next to the context's own
--- database: whether it names a database (MySQL's `otherdb.users`) or a
--- schema inside the current one (postgres's `app.users`) is the caller's
--- call, since only it knows the dialect (nav/handlers composes the browser
--- call from it). Folding it into `database` here sent every postgres
--- schema-qualified reference to "Database 'app' not found".
--- @param prefix string|nil the dotted prefix, "" and nil both meaning none
local function table_target(full_ctx, prefix, table_name, column_name)
  return {
    action = "navigate_to_table",
    database = full_ctx.database,
    schema = (prefix and prefix ~= "") and prefix or nil,
    table_name = table_name,
    column_name = column_name,
  }
end

local function prefix_of(t)
  return t and t.schema or nil
end

--- A detect entry's bare name field: quotes stripped, nil preserved (NOT ""
--- — callers chain these into `or` fallbacks, and "" is truthy in Lua).
local function bare(t, field)
  local v = t and t[field]
  if not v then return nil end
  return util.unquote_ident(v)
end

local function table_by_name(parsed, name)
  for _, t in ipairs(parsed.tables or {}) do
    if t.name and util.unquote_ident(t.name):lower() == (name or ""):lower() then return t end
  end
  return nil
end

local function resolve_alias(parsed, prefix)
  if not (prefix and parsed and parsed.tables) then return nil end
  for _, t in ipairs(parsed.tables) do
    if t.alias and util.unquote_ident(t.alias):lower() == prefix:lower() then
      return bare(t, "name")
    end
  end
  return nil
end

--- 0-based index of the character before the word that ends at `from`
--- (inclusive); -1 when the word reaches the start of the line.
local function back_over_word(line_text, from)
  local p = from
  while p >= 0 and line_text:sub(p + 1, p + 1):match("[%w_]") do p = p - 1 end
  return p
end

--- The word after the dot when the cursor word ends right before one — the
--- cursor-on-alias spelling of `alias.column`, where the target column is the
--- word PAST the dot. Any other character (a `,` with no space after the
--- column, a space, `)`) means the cursor word IS the column: scanning
--- forward from there used to steal the next statement token, so
--- `SELECT u.name,o.total` with the cursor on `name` navigated to column
--- `o`. Mirrors the `nxt == "."` guard in the column/keyword branch below.
local function word_after_dot(line_text, end_col)
  if line_text:sub(end_col + 1, end_col + 1) ~= "." then return nil end
  return line_text:sub(end_col + 2):match("^([%w_]+)")
end

function M.extract_sql_block(all_lines, line_num, line_text, end_col)
  local block_start = 1
  if line_num > 1 then
    for i = line_num - 1, 1, -1 do
      if const.is_section_marker(all_lines[i]) then
        block_start = i + 1
        break
      end
    end
  end

  local block_end = #all_lines
  for i = line_num + 1, #all_lines do
    if const.is_section_marker(all_lines[i]) then
      block_end = i - 1
      break
    end
  end

  if not (block_start <= line_num and line_num <= block_end) then
    return nil
  end

  local before_parts = {}
  for i = block_start, line_num - 1 do
    before_parts[#before_parts + 1] = all_lines[i] or ""
  end
  before_parts[#before_parts + 1] = line_text:sub(1, end_col)

  local offset = #table.concat(before_parts, "\n")
  if offset > 0 then
    offset = offset - 1
  end

  local block_parts = {}
  for i = block_start, block_end do
    block_parts[#block_parts + 1] = all_lines[i] or ""
  end

  return {
    block_start = block_start,
    block_end = block_end,
    offset = offset,
    sql_text = table.concat(block_parts, "\n"),
  }
end

function M.resolve_detected_table_target(parsed, line_text, end_col, cword, full_ctx)
  if not parsed or not parsed.tables or #parsed.tables == 0 then return nil end
  local cword_lower = (cword or ""):lower()

  if parsed.ctx_type == "dot_column" and parsed.ctx_data then
    local prefix = parsed.ctx_data or ""
    return table_target(full_ctx, parsed.ctx_schema,
      resolve_alias(parsed, prefix) or prefix,
      word_after_dot(line_text, end_col) or cword)
  elseif parsed.ctx_type == "insert_column" and parsed.ctx_data then
    local prefix = parsed.ctx_data or ""
    return table_target(full_ctx, parsed.ctx_schema,
      resolve_alias(parsed, prefix) or prefix,
      word_after_dot(line_text, end_col) or cword)
  elseif parsed.ctx_type == "schema_table" and parsed.ctx_data then
    return table_target(full_ctx, parsed.ctx_data, cword, nil)
  elseif parsed.ctx_type == "table" then
    local matched, schema_matched = pick_table_match(parsed.tables, cword_lower)
    if schema_matched then
      return {
        action = "navigate_to",
        connection = full_ctx.connection,
        database = cword,
      }
    end
    if matched then
      return table_target(full_ctx, prefix_of(matched),
        bare(matched, "name") or bare(matched, "alias") or cword, nil)
    end
    return table_target(full_ctx, prefix_of(parsed.tables[1]), cword, nil)
  elseif parsed.ctx_type == "column" or parsed.ctx_type == "keyword" then
    local after_dot_col = nil
    local nxt = line_text:sub(end_col + 1, end_col + 1)
    if nxt == "." then
      local cm = line_text:match("^([%w_]+)", end_col + 2)
      if cm then after_dot_col = cm end
    end

    if after_dot_col then
      local matched, schema_matched = pick_table_match(parsed.tables, cword_lower)
      if matched then
        return table_target(full_ctx, prefix_of(matched),
          bare(matched, "name") or bare(matched, "alias") or cword, after_dot_col)
      elseif schema_matched then
        -- the cursor word IS the prefix of this entry
        return table_target(full_ctx, cword, bare(schema_matched, "name"), nil)
      end
      local resolved = resolve_alias(parsed, parsed.ctx_data or "")
      if resolved then
        return table_target(full_ctx, prefix_of(table_by_name(parsed, resolved)),
          resolved, after_dot_col)
      end
    else
      local matched, schema_matched = pick_table_match(parsed.tables, cword_lower)
      if matched then
        return table_target(full_ctx, prefix_of(matched),
          bare(matched, "name") or bare(matched, "alias") or cword, nil)
      elseif schema_matched then
        return table_target(full_ctx, cword, bare(schema_matched, "name"), nil)
      end

      -- `alias.column`. end_col is the 0-based index just past the word under
      -- the cursor (nav/handlers.lua extends it forward), so the walk over the
      -- word itself has to start at end_col - 1; starting at end_col tested the
      -- delimiter after the word and stopped before consuming it, which left
      -- every column cursor falling through to tables[1].
      local alias = nil
      local dot = back_over_word(line_text, end_col)
      if line_text:sub(dot + 1, dot + 1) ~= "." then
        dot = back_over_word(line_text, end_col - 1)
        if line_text:sub(dot + 1, dot + 1) ~= "." then dot = nil end
      end
      if dot then
        local pre = back_over_word(line_text, dot - 1)
        if pre + 1 <= dot - 1 then alias = line_text:sub(pre + 2, dot) end
      end
      local resolved = nil
      if alias then
        resolved = resolve_alias(parsed, alias)
      end
      if resolved then
        return table_target(full_ctx, prefix_of(table_by_name(parsed, resolved)),
          resolved, cword)
      end
      local target = bare(parsed.tables[1], "name") or bare(parsed.tables[1], "alias")
      if target then
        return table_target(full_ctx, prefix_of(parsed.tables[1]), target, cword)
      end
    end
  end

  return nil
end

return M
