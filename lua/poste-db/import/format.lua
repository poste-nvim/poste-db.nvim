local M = {}

local function strip_bom(text)
  if text:sub(1, 3) == "\239\187\191" then
    return text:sub(4)
  end
  return text
end

local function normalize_text(text)
  text = strip_bom(text)
  text = text:gsub("\r\n", "\n")
  text = text:gsub("\r", "\n")
  return text
end

--- Shape scanned rows into `{ columns, rows }`. The first row is the header: a
--- name spelled twice is ambiguous input (the column map would point both file
--- columns at one table column and the last would silently win), and every data
--- row must match the header width or the columns shift under the user. Either
--- way the whole file fails, naming the row that caused it — an import must not
--- quietly load a mis-aligned subset. Shared by the CSV and TSV paths, which
--- differ only in how they scan rows.
--- @param rows string[][]
--- @return table|nil result  { columns, rows } on success
--- @return string|nil err  reason the file was rejected
local function to_table(rows)
  if #rows == 0 then return nil, "No data rows found" end
  local header = rows[1]
  local seen = {}
  for _, name in ipairs(header) do
    if seen[name] then
      return nil, ("Duplicate column '%s' in header"):format(name)
    end
    seen[name] = true
  end
  local num_cols = #header
  local data_rows = {}
  for ri = 2, #rows do
    local row = rows[ri]
    if #row ~= num_cols then
      return nil, string.format("Row %d: expected %d columns, got %d", ri, num_cols, #row)
    end
    data_rows[#data_rows + 1] = row
  end
  return { columns = header, rows = data_rows }
end

function M.parse_csv(text)
  -- No blanket CRLF rewrite here: a CRLF INSIDE a quoted field is the cell's
  -- data (RFC 4180), and normalizing it away changed the value the exporter
  -- had quoted — csv_escape quotes an embedded \r\n precisely so it survives
  -- the round trip. Line endings are decided by the scanner below, which can
  -- see whether it is inside quotes.
  text = strip_bom(text)
  local parsed_rows = {}
  local i = 1
  local len = #text

  while i <= len do
    local row = {}
    local in_quoted = false
    local val_chars = {}

    while i <= len do
      local ch = text:sub(i, i)
      if in_quoted then
        if ch == '"' then
          local next = text:sub(i + 1, i + 1)
          if next == '"' then
            table.insert(val_chars, '"')
            i = i + 2
          else
            in_quoted = false
            i = i + 1
          end
        else
          table.insert(val_chars, ch)
          i = i + 1
        end
      elseif ch == '"' then
        -- A quote only opens a quoted region at the START of a field (the
        -- RFC-4180 / python-csv reading). A stray quote mid-field — an
        -- unescaped inch mark like `3" pipe` — used to flip the scanner into
        -- quoted mode, swallowing the following commas and newlines into one
        -- giant cell until the whole import failed with a bogus column count
        -- (or silently mis-aligned when the file happened to stay rectangular).
        if #val_chars == 0 then
          in_quoted = true
          i = i + 1
        else
          table.insert(val_chars, ch)
          i = i + 1
        end
      elseif ch == "," then
        table.insert(row, table.concat(val_chars))
        val_chars = {}
        i = i + 1
      elseif ch == "\r" then
        -- CRLF (the usual Windows row end) and a lone CR both end the row
        -- outside quotes; inside quotes the branch above keeps the bytes.
        if text:sub(i + 1, i + 1) == "\n" then i = i + 2 else i = i + 1 end
        break
      elseif ch == "\n" then
        i = i + 1
        break
      else
        table.insert(val_chars, ch)
        i = i + 1
      end
    end
    table.insert(row, table.concat(val_chars))

    local trimmed_first = (row[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #row > 1 or trimmed_first ~= "" then
      table.insert(parsed_rows, row)
    end
  end

  return to_table(parsed_rows)
end

function M.parse_tsv(text)
  text = normalize_text(text)
  local raw_lines = vim.split(text, "\n")
  local rows = {}
  for _, raw in ipairs(raw_lines) do
    -- Split the RAW line: a leading/trailing empty cell ("a\tb\t") is real
    -- data, and trimming the line used to delete that column — a spurious
    -- "expected N columns" error, or silent column misalignment when every
    -- row shared the empty edge cell. Only blank lines are skipped.
    if raw:match("^%s*$") == nil then
      table.insert(rows, vim.split(raw, "\t"))
    end
  end

  return to_table(rows)
end

function M.parse_json(text)
  text = normalize_text(text)
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" then
    return nil, "Invalid JSON: " .. tostring(ok)
  end
  if #data == 0 then
    -- A single object — the shape a pasted API response has — is one row:
    -- `{"a": 1}` imports exactly like `[{"a": 1}]`. Only a decoded value
    -- with no keys at all stays an error.
    if next(data) ~= nil then
      data = { data }
    else
      return nil, "JSON array is empty"
    end
  end

  local seen = {}
  for _, obj in ipairs(data) do
    if type(obj) == "table" then
      for k, _ in pairs(obj) do
        seen[k] = true
      end
    end
  end
  local keys = {}
  for k, _ in pairs(seen) do
    table.insert(keys, k)
  end
  table.sort(keys)

  if #keys == 0 then
    return nil, "No keys found in JSON objects"
  end

  local rows = {}
  for _, obj in ipairs(data) do
    if type(obj) ~= "table" then
      return nil, "Expected array of objects"
    end
    local row = {}
    for _, k in ipairs(keys) do
      local v = obj[k]
      if v == nil or v == vim.NIL then
        table.insert(row, vim.NIL)
      elseif type(v) == "table" then
        -- nested object/array (a jsonb value): tostring would import the
        -- garbage pointer text "table: 0x…"; encode it as JSON instead
        local enc_ok, encoded = pcall(vim.json.encode, v)
        table.insert(row, enc_ok and encoded or vim.inspect(v))
      else
        table.insert(row, tostring(v))
      end
    end
    table.insert(rows, row)
  end

  return { columns = keys, rows = rows }
end

function M.detect_format(content, filepath)
  if filepath then
    local ext = filepath:lower():match("%.([^%.]+)$")
    if ext == "csv" then return "csv" end
    if ext == "tsv" then return "tsv" end
    if ext == "json" then return "json" end
  end

  local trimmed = content:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed:sub(1, 1) == "[" or trimmed:sub(1, 1) == "{" then
    local ok, _ = pcall(vim.json.decode, trimmed)
    if ok then return "json" end
  end

  local first_line = content:match("^[^\n]+")
  if first_line then
    local tab_count = select(2, first_line:gsub("\t", ""))
    local comma_count = select(2, first_line:gsub(",", ""))
    if tab_count > comma_count and tab_count > 0 then
      return "tsv"
    end
    if comma_count > 0 then
      return "csv"
    end
  end

  return nil
end

return M
