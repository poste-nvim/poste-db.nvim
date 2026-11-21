# AI Chat Integration — poste-ai.nvim

> The "db" AI context: chat about your databases, mention connections, and run
> AI-authored SQL straight into the dataset view.

## Architecture

Generic chat infrastructure lives in the sibling repo
[poste-ai.nvim](https://github.com/poste-nvim/poste-ai.nvim) (zero dependencies:
curl + Neovim ≥ 0.10, no poste.nvim requirement). It owns the chat window,
markdown rendering, streaming SSE client, session persistence and the
`@` mention engine. Domain knowledge is plugged in via
`require("poste-ai").register_context(id, spec)`.

poste-db.nvim registers a **`db` context** in `lua/poste-db/ai/`:

```
poste-ai.nvim (generic)          poste-db.nvim (db context)
├─ chat/window.lua               ├─ ai/init.lua        register/bridge
├─ chat/render.lua (markdown)    ├─ ai/mentions.lua    @conn/db[/table]
├─ provider/openai.lua (SSE)     ├─ ai/system_prompt.lua  feature knowledge
├─ chat/mention.lua (@engine)    ├─ ai/schema.lua      auto-injected schema block
└─ context_api.lua (contract)    ├─ ai/introspect.lua  shared introspect wrapper
                                 ├─ ai/commands.lua    /connections, /databases
                                 └─ ai/actions.lua     sql block → dataset
```

- **Optional dependency**: `poste-db/ai/` only ever `pcall(require, "poste-ai")`.
  Registration is attempted in `poste-db.setup()` and retried on
  `:PosteDbChat`; when poste-ai is absent everything silently no-ops.
- **No credentials in prompts**: schema summaries carry connection names,
  dialect, table/column names, types and comments — never host/user/password.
  API keys for the LLM are read from environment variables only
  (`api_key_env`).

## User flows

| Scenario | Flow |
|----------|------|
| "top ten authors by post count this month" | `@my-blog/blog` mention resolves the schema summary → model replies with one ```sql block → `<CR>` on the block executes it → results land in the dataset view |
| "is this SQL right?" | Visual-select the statement in a poste_sql buffer, `<leader>aa` — chat opens with `@file(l1-l2)` pre-filled → model reviews it with file content injected |
| "how do I export?" | The system prompt documents `:PosteDbExport [fmt] [dest] [path]`, dataset `E`, and other commands — the model answers how-to questions without tool calls |

## Context contract (what poste-ai expects)

```lua
{
  system_prompt = fn(scope) → string,          -- static knowledge, per request
  auto_context = fn(text, scope, cb),        -- cb(markdown|nil): schema block
  commands = { … },                          -- slash commands (/connections, /databases)
  mention = {
    match = fn(token) → ref|nil,               -- claim a @token
    complete = fn(prefix, cb) → candidates,    -- completion popup (prefix-filtered)
    resolve = fn(ref, cb) → markdown,          -- schema summary (async ok)
  },
  codeblock = {
    langs = { "sql" },
    confirm = fn(sql) → boolean,               -- read-only passes; DML/DDL asks
    execute = fn(sql, refs, cb),               -- cb(err, note) → chat note line
    append_header = fn(scope, text) → text,    -- scope/header line for the block
  },
}
```

## Safety model (V1)

- Execution goes through the regular `executor.execute` (session-first,
  exec-file fallback) — same paths as manual `<CR>`.
- `actions.confirm_sql`: SELECT/WITH/SHOW/EXPLAIN/... run directly; anything
  else (INSERT/UPDATE/DELETE/DDL) pops a `vim.fn.confirm` gate.
- Mention refs are the routing source: `@my-blog/blog` binds the block to that
  connection; otherwise the poste-ai chat scope (`/connections`, `/databases`)
  is used; otherwise the current SQL buffer context; otherwise the chat gets an
  explanatory error. An empty string counts as "not bound" at every hop (an
  empty `--database` would be applied as a URL rewrite).
- A DDL block executed from chat invalidates the completion and
  semantic-diagnostics schema caches through the same shared
  `poste-db.schema_cache` helper as SQL-buffer DDL — otherwise dropped tables
  kept completing and new tables stayed "not found" for the session.

## V2 (planned, not implemented)

- Function-calling agent loop in poste-ai (`tools/loop.lua`): model calls
  `introspect_schema` / `run_readonly_sql` / `open_db_browser` as tools.
- Anthropic adapter; poste-http "http" context.

## Testing

- poste-ai: `tests/ai/` in the poste-ai repo (`./tests/run.sh`).
- poste-db: `tests/sql/ai_actions_spec.lua`, `ai_ask_spec.lua`,
  `ai_commands_spec.lua`, `ai_mentions_spec.lua`, `ai_register_spec.lua`,
  `ai_schema_spec.lua` — stub the executor/render/introspect modules; no
  network. The registration test is conditional on poste-ai being on rtp (CI
  checks it out as a sibling).

---
*Last updated: 2026-11-21 (round-8 audit: auto_context contract, routing
priority, schema-cache invalidation, module/test lists)*
