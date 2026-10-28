# SQL Session Persistent Connection Design

## Problem

Every `<CR>` execution spawns a fresh `exec-file` process, each process opens
its own database connection and closes it immediately after. Session variables
(`SET @a=1;`) do not survive across statements:

```
SET @a=1;     → exec-file(process 1) → connection 1 → run → close
SELECT @a;    → exec-file(process 2) → connection 2 → @a does not exist
```

## Design

The Rust side gains a `poste session` subcommand — a long-lived process that
holds one connection open. Lua keeps a session pool keyed by `connection_url`
and reuses a session per connection on `<CR>`.

### Session pool

```
session_conn.pool = {
  ["mysql://user@host:3306/db"] = {
    job_id = 123,
    conn_url = "mysql://user@host:3306/db",
    bufs = { [bufnr_a] = true, [bufnr_b] = true },
    start_time = 1234567,
    idle_timer = nil,
  },
  ["postgres://user@host:5432/db"] = { ... },
}
```

The key is the `connection_url` (the full URL Lua resolves); `<CR>` looks the
session up by it.

### Lookup flow

```
on <CR>
  → resolve -- @connection name → resolve_connection_url(name) → conn_url
  → pool[conn_url] exists?
    → yes: reuse the session, send the SQL on stdin
    → no: jobstart("poste session --connection <url>"), add to the pool
```

### Lifecycle

| Event | Behavior |
|------|------|
| First `<CR>` on a connection | Start the session process, add to pool |
| Later `<CR>` on the same connection | Reuse the session |
| `<CR>` on a different connection | Start a new session (separate process); the two sessions are independent |
| Buffer closed | Walk the pool, drop the buffer from `bufs`; when `bufs` empties → close the session, delete from pool |
| `:PosteDbSessionStop` | Takes a connection_url to stop one, or `--all` for everything |
| Idle timeout (optional) | Close automatically after N seconds without a request |

### Sharing

Sharing is per connection, across buffers. Several buffers with the same
connection_url share one session and see each other's variables (matching real
MySQL/PostgreSQL behavior).

## Rust side: `crates/poste-cli/src/session.rs`

### Subcommand

```
poste session --connection <url> [--database <db>] [--timeout <sec>] [--max-rows <n>]
```

### Protocol

Reads JSON lines from stdin, writes JSON lines to stdout (NDJSON).

**Request shape** (Lua → Rust):

```json
{"seq": 1, "sql": "SET @a = 1"}
{"seq": 2, "sql": "SELECT @a"}
```

**Response shape** (Rust → Lua, same as exec-file's `result` events):

```json
{"type":"result","seq":1,"status":"ok","sql":"SET @a = 1","row_count":0,"affected_rows":0,"execution_time_ms":1,"columns":[],"rows":[]}
{"type":"result","seq":2,"status":"ok","sql":"SELECT @a","row_count":1,"affected_rows":null,"execution_time_ms":1,"columns":[{"name":"@a","type":"INT"}],"rows":[[1]]}
```

**Error response**:

```json
{"type":"result","seq":3,"status":"error","sql":"SELECT * FROM nonexistent","error":"table not found","execution_time_ms":0}
```

### Flow

```
session::execute()
  ├─ 1. Connect to the database (pool → acquire, same logic as exec_file)
  ├─ 2. Loop:
  │    ├─ read one stdin line
  │    ├─ parse the JSON { seq, sql }
  │    ├─ run the SQL (same conn reused)
  │    ├─ write the result JSON to stdout
  │    └─ on error: write an error result and keep looping (do not exit)
  ├─ 3. stdin EOF → close the connection → exit (exit 0)
```

## Lua side: `lua/poste-db/session_conn.lua`

### Interface

```lua
local M = {}

-- Start a session (returns the pooled one when it already exists)
M.start(conn_url, opts) → session

-- Send SQL to the session; the result arrives via callback (async)
M.execute(session, sql, callbacks)

-- Stop one session
M.stop(conn_url)

-- Stop every session
M.stop_all()

-- Stop every session tied to one buffer (called on buffer close)
M.cleanup_buf(bufnr)
```

### Wiring into `sql_runner.lua`

In `run_sql_request()`, after the context resolves to a conn_url:

1. Check `session_conn.pool[conn_url]`
2. Hit → `session_conn.execute(session, sql, callbacks)` (send on stdin)
3. Miss → `session_conn.start(conn_url)` → fall back to `exec_run.run_async`
   (or wait for the session to be ready and then send)

`exec_run.run_async` stays unchanged as the fallback when a session is not
available.

### Session process management

```lua
local session = {
  job_id = vim.fn.jobstart({"poste", "session", "--connection", conn_url, ...}, {
    stdin = "pipe",
    stdout_buffered = false,
    on_stdout = function(_, data) ... end,
    on_exit = function() ... end,
  }),
  conn_url = conn_url,
  bufs = { [bufnr] = true },
  pending = {},  -- { [seq] = { on_response, on_error } }
  seq = 0,
}
```

Sending SQL:

```lua
session.seq = session.seq + 1
local seq = session.seq
session.pending[seq] = { on_response = ..., on_error = ... }
vim.fn.chansend(session.job_id, vim.json.encode({ seq = seq, sql = sql }) .. "\n")
```

Receiving responses:

```lua
on_stdout = function(_, data)
  for _, line in ipairs(data) do
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      if ok and event.type == "result" then
        local cb = session.pending[event.seq]
        if cb then
          session.pending[event.seq] = nil
          if event.status == "ok" then
            cb.on_response(event)
          else
            cb.on_error(event.error or "unknown error")
          end
        end
      end
    end
  end
end
```

## Files touched

| File | Change |
|------|---------|
| `crates/poste-cli/src/session.rs` | **New file**: the session daemon |
| `crates/poste-cli/src/main.rs` | Register the `Session` subcommand |
| `lua/poste-db/session_conn.lua` | **New file**: pool management + send/receive |
| `lua/poste-db/sql_runner.lua` | `run_sql_request()` routes to the session path |
| `lua/poste-db/init.lua` | `setup()` registers the BufUnload cleanup |

## Possible extensions

- Automatic close on idle timeout
- `:PosteDbSessionList` to show live sessions
- Transaction-mode sessions (`BEGIN` across `<CR>`)
