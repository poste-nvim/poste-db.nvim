--- SQL snippet definitions for blink.cmp integration.
--- Built-in snippets are organized as *categories* (e.g. create_table) with
--- per-dialect template variants (mysql/mariadb/postgres/sqlite + default).
--- Triggers map to a category; the active template is chosen by dialect at
--- completion time:
---
---   trigger -> category -> [dialect] -> template
---
--- User overrides via setup({ snippets = { ... } }):
---   * { key = "create_database" }         -> route/override trigger to a built-in category
---   * { key = "CREATE TABLE ..." }        -> custom raw template (legacy behavior)
---   * { key = { snippet = "...", label=... } }  -> custom raw template (legacy)
---   * { key = { default=..., postgres=... } }    -> custom category with dialect variants

local M = {}

--- @type table<string, {label:string, default:string, mysql?:string, mariadb?:string, postgres?:string, sqlite?:string}>
local CATEGORIES = {
  create_table = {
    label = "create table template",
    default = "CREATE TABLE ${1:table_name} (\n  ${2:column_name} ${3:INTEGER} ${4:NOT NULL}\n);",
    mysql = "CREATE TABLE ${1:table_name} (\n  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,\n  ${2:column_name} ${3:INTEGER} ${4:NOT NULL}\n);",
    mariadb = "CREATE TABLE ${1:table_name} (\n  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,\n  ${2:column_name} ${3:INTEGER} ${4:NOT NULL}\n);",
    postgres = "CREATE TABLE ${1:table_name} (\n  id SERIAL PRIMARY KEY,\n  ${2:column_name} ${3:INTEGER} ${4:NOT NULL}\n);",
    sqlite = "CREATE TABLE ${1:table_name} (\n  id INTEGER PRIMARY KEY AUTOINCREMENT,\n  ${2:column_name} ${3:INTEGER} ${4:NOT NULL}\n);",
    mssql = "CREATE TABLE ${1:table_name} (\n  id INT IDENTITY(1,1) PRIMARY KEY,\n  ${2:column_name} ${3:INT} ${4:NOT NULL}\n);",
    clickhouse = "CREATE TABLE ${1:table_name} (\n  id UInt64,\n  ${2:column_name} ${3:String}\n) ENGINE = MergeTree ORDER BY id;",
  },
  create_table_timestamp = {
    label = "create table with timestamp template",
    default = "CREATE TABLE ${1:table_name} (\n  id INTEGER NOT NULL PRIMARY KEY AUTO_INCREMENT,\n  ${2:-- columns}\n  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,\n  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP\n);",
    postgres = "CREATE TABLE ${1:table_name} (\n  id SERIAL PRIMARY KEY,\n  ${2:-- columns}\n  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,\n  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP\n);",
    sqlite = "CREATE TABLE ${1:table_name} (\n  id INTEGER PRIMARY KEY AUTOINCREMENT,\n  ${2:-- columns}\n  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,\n  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP\n);",
    mssql = "CREATE TABLE ${1:table_name} (\n  id INT IDENTITY(1,1) PRIMARY KEY,\n  ${2:-- columns}\n  updated_at DATETIME2 NOT NULL DEFAULT SYSDATETIME(),\n  created_at DATETIME2 NOT NULL DEFAULT SYSDATETIME()\n);",
    clickhouse = "CREATE TABLE ${1:table_name} (\n  id UInt64,\n  ${2:-- columns}\n  created_at DateTime64(3) DEFAULT now64()\n) ENGINE = MergeTree ORDER BY id;",
  },
  create_database = {
    label = "create database",
    default = "CREATE DATABASE ${1:db_name};",
    mysql = "CREATE DATABASE IF NOT EXISTS ${1:db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;",
    mariadb = "CREATE DATABASE IF NOT EXISTS ${1:db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;",
    postgres = "CREATE DATABASE ${1:db_name} ENCODING 'UTF8' LC_COLLATE '${2:en_US.UTF-8}' LC_CTYPE '${3:en_US.UTF-8}';",
    sqlite = "ATTACH DATABASE '${1:/path/to/db.sqlite}' AS ${2:db_name};",
    mssql = "CREATE DATABASE ${1:db_name};",
    clickhouse = "CREATE DATABASE IF NOT EXISTS ${1:db_name};",
  },
  column = {
    label = "column",
    default = "${1:col_name} ${2:INT} NOT NULL DEFAULT ${3:0} COMMENT '${4}' ${5:,}",
    postgres = "${1:col_name} ${2:INT} NOT NULL DEFAULT ${3:0} ${5:,}",
    sqlite = "${1:col_name} ${2:INTEGER} ${3:NOT NULL} DEFAULT ${4:0} ${5:,}",
    mssql = "${1:col_name} ${2:INT} ${3:NOT NULL} DEFAULT ${4:0} ${5:,}",
    clickhouse = "${1:col_name} ${2:UInt32} DEFAULT ${3:0} ${5:,}",
  },
  column_varchar = {
    label = "column varchar",
    default = "${1:col_name} VARCHAR(${2:255}) NOT NULL DEFAULT '${3}' COMMENT '${4}' ${5:,}",
    postgres = "${1:col_name} VARCHAR(${2:255}) NOT NULL DEFAULT '${3}' ${5:,}",
    sqlite = "${1:col_name} TEXT ${3:NOT NULL} DEFAULT '${4}' ${5:,}",
    mssql = "${1:col_name} NVARCHAR(${2:255}) ${3:NOT NULL} DEFAULT '${4}' ${5:,}",
    clickhouse = "${1:col_name} String DEFAULT '${3}' ${5:,}",
  },
  select_from = {
    label = "select * from",
    default = "SELECT * FROM ${1:table_name} LIMIT 100;",
  },
  select_count = {
    label = "select count(*)",
    default = "SELECT COUNT(*) FROM ${1:table_name};",
  },
  insert = {
    label = "insert into template",
    default = "INSERT INTO ${1:table_name} (${2:columns}) VALUES (${3:values});",
  },
  update = {
    label = "update template",
    default = "UPDATE ${1:table_name} SET ${2:column} = ${3:value} WHERE ${4:condition};",
  },
  delete = {
    label = "delete template",
    default = "DELETE FROM ${1:table_name} WHERE ${2:condition};",
  },
  cte = {
    label = "with cte",
    default = "WITH ${1:cte_name} AS (\n  ${2:select_query}\n)\n${3:final_query};",
  },
  create_index = {
    label = "create index",
    default = "CREATE INDEX ${1:idx_name} ON ${2:table_name} (${3:column});",
  },
  alter_add_column = {
    label = "alter table add column",
    default = "ALTER TABLE ${1:table_name} ADD COLUMN ${2:column_name} ${3:INTEGER} ${4:NOT NULL} DEFAULT ${5:0} COMMENT '${6}';",
    postgres = "ALTER TABLE ${1:table_name} ADD COLUMN ${2:column_name} ${3:INTEGER} ${4:NOT NULL} DEFAULT ${5:0};",
    sqlite = "ALTER TABLE ${1:table_name} ADD COLUMN ${2:column_name} ${3:INTEGER} ${4:NOT NULL} DEFAULT ${5:0};",
    mssql = "ALTER TABLE ${1:table_name} ADD ${2:column_name} ${3:INT} ${4:NOT NULL} DEFAULT ${5:0};",
    clickhouse = "ALTER TABLE ${1:table_name} ADD COLUMN ${2:column_name} ${3:UInt32} DEFAULT ${4:0};",
  },
  alter_modify_column = {
    label = "alter table modify column",
    default = "ALTER TABLE ${1:table_name} MODIFY COLUMN ${2:column_name} ${3:INTEGER} ${4:NOT NULL} DEFAULT ${5:0} COMMENT '${6}';",
    -- Postgres spells a type change `ALTER COLUMN c TYPE t`; there is no
    -- `SET <type>` form, and SET NOT NULL / SET DEFAULT are separate
    -- statements (the shape ops_sql.build_alter_column_sql emits).
    postgres = "ALTER TABLE ${1:table_name} ALTER COLUMN ${2:column_name} TYPE ${3:INTEGER};",
    sqlite = "ALTER TABLE ${1:table_name} MODIFY COLUMN ${2:column_name} ${3:INTEGER} ${4:NOT NULL} DEFAULT ${5:0};",
    mssql = "ALTER TABLE ${1:table_name} ALTER COLUMN ${2:column_name} ${3:INT} ${4:NOT NULL};",
    clickhouse = "ALTER TABLE ${1:table_name} MODIFY COLUMN ${2:column_name} ${3:String};",
  },
  union_all = {
    label = "union all",
    default = "UNION ALL\n${1:select_query}",
  },
}

--- @type table<string,string> trigger -> category name
local DEFAULT_TRIGGERS = {
  ct = "create_table",
  tab = "create_table_timestamp",
  cdb = "create_database",
  col = "column",
  colv = "column_varchar",
  sf = "select_from",
  cnt = "select_count",
  ins = "insert",
  upd = "update",
  del = "delete",
  cte = "cte",
  idx = "create_index",
  cola = "alter_add_column",
  colu = "alter_modify_column",
  uni = "union_all",
}

--- @type table<string,{category?:string, raw?:true, label?:string, snippet?:string}>
--- trigger -> route. route either points at a category or is a raw template.
M.snippets = {}

M.categories = vim.deepcopy(CATEGORIES)

function M.setup(opts)
  opts = opts or {}
  M.categories = vim.deepcopy(CATEGORIES)
  M.snippets = {}
  for trigger, category in pairs(DEFAULT_TRIGGERS) do
    M.snippets[trigger] = { category = category }
  end

  if opts.snippets then
    for trigger, config in pairs(opts.snippets) do
      if type(config) == "string" then
        if M.categories[config] then
          -- route (or override) this trigger to a built-in category
          M.snippets[trigger] = { category = config }
        else
          -- legacy: raw template
          M.snippets[trigger] = { raw = true, trigger = trigger, label = trigger, snippet = config }
        end
      elseif type(config) == "table" then
        if config.category and M.categories[config.category] then
          M.snippets[trigger] = { category = config.category }
        elseif config.snippet then
          M.snippets[trigger] = { raw = true, trigger = trigger, label = config.label or trigger, snippet = config.snippet }
        elseif config.default then
          -- user-provided per-dialect variants → register as a new category
          local cat_name = "custom_" .. trigger
          local cat = {}
          for k, v in pairs(config) do cat[k] = v end
          cat.label = config.label or trigger
          M.categories[cat_name] = cat
          M.snippets[trigger] = { category = cat_name }
        else
          M.snippets[trigger] = { raw = true, trigger = trigger, label = trigger, snippet = "" }
        end
      end
    end
  end
end

--- Pick a category template for a dialect (lowercased), falling back
--- mariadb -> mysql -> default.
--- @param cat {default:string, mysql?:string, mariadb?:string, postgres?:string, sqlite?:string, mssql?:string}
--- @param dialect string|nil
--- @return string
local function pick_template(cat, dialect)
  if dialect then
    local d = dialect:lower()
    local v = cat[d]
    if v == nil and d == "mariadb" then v = cat.mysql end
    if v then return v end
  end
  return cat.default
end

--- Resolve a trigger to its {label, snippet} for the given dialect.
--- @param trigger string
--- @param dialect string|nil
--- @return {label:string, snippet:string}|nil
function M.resolve(trigger, dialect)
  local route = M.snippets[trigger]
  if not route then return nil end
  if route.raw then
    return { label = route.label or trigger, snippet = route.snippet }
  end
  local cat = M.categories[route.category]
  if not cat then return nil end
  return { label = cat.label or route.category, snippet = pick_template(cat, dialect) }
end

--- Return blink.cmp-compatible completion items for the given prefix,
--- routed through the active dialect.
--- Items have data.snippet = true so the execute handler can expand them.
--- @param prefix string
--- @param dialect string|nil  connection dialect (postgres/mysql/mariadb/sqlite)
function M.get_completion_items(prefix, dialect)
  local items = {}
  local seen = {}
  for trigger, route in pairs(M.snippets) do
    -- plain=true: the prefix is the user's typed text — treating it as a
    -- pattern would error on magic chars (`sel(`) and mis-filter on others.
    if not seen[trigger] and trigger:find(prefix, 1, true) == 1 then
      seen[trigger] = true
      local resolved = M.resolve(trigger, dialect)
      if resolved then
        table.insert(items, {
          label = resolved.label,
          insertText = trigger,
          filterText = trigger,
          sortText = "zzz" .. trigger,
          kind = 14,
          documentation = resolved.snippet,
          data = { snippet = true, trigger = trigger, body = resolved.snippet },
        })
      end
    end
  end
  return items
end

return M