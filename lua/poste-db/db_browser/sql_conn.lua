--- Shared async SQL runner for DB Browser copy/catalog operations.
--- Extracted from db_browser/copy.lua so catalog.lua can reuse the same
--- connection resolution + job plumbing.
local util = require("poste-db.util")

local M = {}

local function find_search_dir()
  local browser = require("poste-db.db_browser")
  return browser.get_search_dir()
end

--- Run `sql` against conn/database, invoke on_result with the raw JSON
--- response string (envelope), or on_error(message).
function M.run(conn_name, database, sql, on_result, on_error)
  local connections = require("poste-db.connections")
  local url, err = connections.resolve_connection_url(conn_name)
  if not url then
    if on_error then on_error(err or "unknown error") end
    return
  end

  local search_dir = find_search_dir()
  local src_file = search_dir .. "/copy.sql"
  local exec_run = require("poste-db.exec_run")
  local job_id = exec_run.run_async(sql, {
    src_file = src_file,
    conn_url = url,
    database = database,
    mode = "greedy",
    log_source = "browser",
    log_extra = { connection = conn_name },
  }, {
    on_response = function(resp)
      if on_result then on_result(vim.json.encode(resp)) end
    end,
    on_error = function(message)
      if on_error then on_error(message) end
    end,
  })

  if not job_id or job_id <= 0 then
    if on_error then on_error("Failed to start job") end
  end
end

--- Decode a SQL envelope (the JSON returned by run) into its first result's
--- { columns, rows }, surfacing transport/body/result errors.
--- Returns true, result on success; false, error_message on failure.
---@param output string|table json-encoded envelope (or already decoded table)
function M.decode_first_result(output)
  local ok, parsed
  if type(output) == "table" then
    ok, parsed = true, output
  else
    ok, parsed = pcall(vim.json.decode, tostring(output))
  end
  if not ok or type(parsed) ~= "table" then
    return false, "failed to parse response"
  end
  local err = parsed.error
  if err ~= nil and err ~= vim.NIL and err ~= "" then
    return false, tostring(err)
  end
  if not parsed.body then
    return false, "no body in response"
  end
  local decoded = util.decode_dataset_body(parsed)
  if not decoded then
    return false, "failed to decode body"
  end
  if not decoded.results or not decoded.results[1] then
    return false, "no result in response"
  end
  local r = decoded.results[1]
  if r.error ~= nil and r.error ~= vim.NIL and r.error ~= "" then
    return false, tostring(r.error)
  end
  -- Preserve copy.lua's original semantics: a non-empty `message` on the
  -- first result was treated as an error there too.
  if r.message ~= nil and r.message ~= vim.NIL and r.message ~= "" then
    return false, tostring(r.message)
  end
  -- The envelope's own verdict is a separate field from any of the above, so a
  -- failure can arrive with nothing to read. Reporting it as a result would
  -- make the caller's "no rows here" branch answer a rejected query with
  -- "nothing to copy".
  if parsed.has_error or parsed.status == "error" or decoded.has_error then
    return false, "the response reported a failure whose statement carried no message"
  end
  return true, r
end

return M
