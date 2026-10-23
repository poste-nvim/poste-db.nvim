# SQL Quick Reference

> `.sql` / `.mysql` / `.sqlite` file syntax cheatsheet

---

## File Structure

```sql
-- @connection dev-pg
-- @database myapp_db

SELECT * FROM users WHERE status = 'active';

INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com');

USE other_db;  -- Dynamically switch database

SELECT * FROM other_db.orders;  -- Cross-database query
```

---

## Connection Configuration

`connections.toml` (walked up from the SQL file):
```toml
[dev-pg]
dialect = "postgres"
host = "localhost"
port = 5432
database = "myapp"
user = "{{PG_DEV_USER}}"
password = "{{PG_DEV_PASSWORD}}"

[local-sqlite]
dialect = "sqlite"
path = "./data/app.db"

[staging-mysql]
dialect = "mysql"
host = "{{MYSQL_STAGING_HOST}}"
port = 3306
database = "staging_db"
user = "{{MYSQL_STAGING_USER}}"
password = "{{MYSQL_STAGING_PASSWORD}}"
```

Sensitive fields are resolved from `.env` (gitignored; see `.env.example`) or
real OS environment variables. Precedence: OS env > `.env` > `env.json`.
Unknown `{{VAR}}` references stay literal.

---

## Execution Context

| Mode | Syntax | Description |
|------|--------|-------------|
| Full context | `-- @connection` + `-- @database` | Explicit specification |
| Dynamic switch | `USE dbname;` | Auto-updates context after execution |
| Cross-database | `SELECT * FROM db.table` | No context needed |

---

## Result Panel Keybindings

| Key | Function |
|-----|----------|
| `h` / `l` | Move left/right one cell |
| `j` / `k` | Move up/down one row |
| `0` / `$` | First/last column in current row |
| `gg` / `G` | First/last row |
| `H` | Jump to header row |
| `Ctrl+f` / `Ctrl+b` | Page down/up |
| `/` | Search within result set |
| `K` | Float preview long text / JSON |
| `q` | Close result panel |
| `<Tab>` / `<S-Tab>` | Switch multi-result tabs |

---

## Database Browser Keybindings

| Key | Function |
|-----|----------|
| `<CR>` | Expand/collapse node; leaf node previews data |
| `r` | Refresh current node |
| `/` | Search filter |
| `d` | Generate DESCRIBE query |
| `q` | Close browser |

---

## Commands

| Command | Function |
|---------|----------|
| `:PosteDbConnection` | Open connection manager |
| `:PosteDbBrowser` | Open database browser |
| `<leader>rr` | Execute current SQL statement/block |
| `]]` / `[[` | Jump to next/previous statement |

---

## Supported Databases

| Database | Extension | Dialect |
|----------|-----------|---------|
| PostgreSQL | `.sql` | postgres |
| MySQL | `.mysql` | mysql |
| SQLite | `.sqlite` | sqlite |

---

## Result JSON Format

### SELECT Query
```json
{
  "type": "resultset",
  "results": [{
    "columns": [{ "name": "id", "type": "integer", "nullable": false }],
    "rows": [[1], [2]],
    "row_count": 2,
    "execution_time_ms": 12
  }]
}
```

### DML/DDL
```json
{
  "type": "affected",
  "results": [{
    "affected_rows": 5,
    "execution_time_ms": 3
  }]
}
```

### USE Statement
```json
{
  "type": "use",
  "database_name": "myapp_db",
  "is_use_statement": true
}
```

---

## Introspection Queries (PostgreSQL Example)

```sql
-- List databases
SELECT datname FROM pg_database WHERE datistemplate = false;

-- List schemas
SELECT schema_name FROM information_schema.schemata
WHERE schema_name NOT IN ('pg_catalog', 'information_schema');

-- List tables
SELECT table_name, table_type FROM information_schema.tables
WHERE table_schema = $1;

-- List columns
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = $1 AND table_name = $2;
```

---

*SQL Quick Reference — Last updated: 2026-06-24*
