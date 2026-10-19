--- Poste CLI binary installer.
--- Downloads prebuilt binary from GitHub Releases to stdpath("data")/poste/bin/.
--- Vendored from poste.nvim@5b3759e lua/poste/install.lua (family
--- dissolution) and trimmed: plugin_tag / schedule_version_sync /
--- installed_version / update are dropped — the git-tag version sync
--- matched the binary against the *plugin checkout's* tag, which is
--- meaningless in a sibling repo (sibling tags are not poste.nvim release
--- tags). REPO stays poste-nvim/poste.nvim: one binary for the whole family.
local M = {}

local REPO = "poste-nvim/poste.nvim"
local BASE = vim.fn.stdpath("data") .. "/poste"
local BIN_DIR = BASE .. "/bin"
local VERSION_FILE = BASE .. "/.version"

--- Detect platform string matching release asset names.
local function detect_platform()
  local uname = vim.loop.os_uname()
  local sys = uname.sysname
  local machine = uname.machine
  if sys == "Linux" and machine == "x86_64" then return "x86_64-linux" end
  if sys == "Linux" and machine == "aarch64" then return "aarch64-linux" end
  if sys == "Darwin" and machine == "x86_64" then return "x86_64-macos" end
  if sys == "Darwin" and machine == "arm64" then return "aarch64-macos" end
  if sys:find("Windows") and machine == "x86_64" then return "x86_64-windows" end
  return nil
end

--- Render a path as a PowerShell string literal.
--- `vim.fn.system` in list form still hands everything after `-Command` to
--- PowerShell as a *command line*, so a `stdpath("data")` containing a space
--- (`C:\Users\Jane Smith\…`) split into two arguments there and the extract
--- step failed. Single quotes suppress `$`/backtick expansion; the only
--- escape inside them is '' for a literal '.
--- @param path string
--- @return string the path as a PowerShell single-quoted literal
function M.ps_literal(path)
  return "'" .. (path:gsub("'", "''")) .. "'"
end

--- Build the curl argv for one release download.
--- Every call carries an explicit ceiling. The archive fetch runs detached
--- from the main loop (vim.system), but a ceiling is still what makes it
--- *finish*: a blackholed connection — a captive portal, or a firewall that
--- answers the SYN and drops the rest — would otherwise keep the background
--- curl alive until the OS socket timeout expires, minutes later, with no
--- failure reported in between. The checksum fetch shares this function and
--- runs on the main loop inside the download callback, where --max-time
--- bounds a brief pause instead of an unbounded one.
--- @param flags string curl's short flags, "-fL" or the silent "-sfL"
--- @param url string
--- @param out string path to write the body to
--- @param max_time integer seconds
--- @return string[] argv for `vim.fn.system` (list form, so no shell)
function M.curl_argv(flags, url, out, max_time)
  return {
    "curl", flags,
    "--connect-timeout", "10",
    "--max-time", tostring(max_time),
    url, "-o", out,
  }
end

--- Compare the downloaded archive's digest with the one the release carries.
--- Hex SHA-256 is case-insensitive by construction, but the tools disagree
--- about which case to print: `sha256sum` and `shasum` print lowercase, which
--- is what the release `.sha256` asset holds, while `certutil -hashfile` prints
--- uppercase. An exact compare therefore reports "Checksum mismatch — download
--- corrupted" for a perfectly good archive on a Windows box that has no Git in
--- `PATH` — i.e. precisely the machine that reaches the certutil branch — and
--- deletes the download, so every startup re-downloads and re-fails.
--- @param actual string digest computed from the downloaded file
--- @param expected string digest from the release asset
--- @return boolean
function M.checksum_matches(actual, expected)
  return actual:lower() == expected:lower()
end

--- Archive extension for the platform.
local function archive_ext(platform)
  if platform:find("windows") then return ".zip" end
  return ".tar.gz"
end

--- Download URL for a release asset.
--- @param platform string  e.g. "x86_64-linux"
--- @param version string   e.g. "latest" or "v0.1.0"
function M.download_url(platform, version)
  version = version or "latest"
  local arch = "poste-" .. platform .. archive_ext(platform)
  if version == "latest" then
    return string.format("https://github.com/%s/releases/latest/download/%s", REPO, arch)
  end
  return string.format("https://github.com/%s/releases/download/%s/%s", REPO, version, arch)
end

--- Checksum URL for a release asset.
function M.checksum_url(platform, version)
  version = version or "latest"
  local arch = "poste-" .. platform .. archive_ext(platform) .. ".sha256"
  if version == "latest" then
    return string.format("https://github.com/%s/releases/latest/download/%s", REPO, arch)
  end
  return string.format("https://github.com/%s/releases/download/%s/%s", REPO, version, arch)
end

--- Verify SHA256 checksum of downloaded archive against release asset.
--- Returns true if checksum matches or verification is unavailable.
local function verify_checksum(archive_path, platform, version)
  local url = M.checksum_url(platform, version)
  local tmp = BIN_DIR .. "/checksum.tmp"

  -- vim.fn.system RAISES E475 when argv[0] is missing, and both system calls
  -- below sit on the setup() path via ensure(): a box without curl must end
  -- in the graceful "download failed" notify, not a plugin-load exception
  -- (health.lua's own warning promises "auto-download will fail", not "load
  -- will crash").
  local sys_ok = pcall(vim.fn.system, M.curl_argv("-sfL", url, tmp, 20))
  if not sys_ok or vim.v.shell_error ~= 0 then
    -- checksum file unavailable — proceed unverified, but say so: the
    -- no-hasher path below is the precedent for skipping loudly
    pcall(os.remove, tmp)
    vim.notify("[Poste] Checksum file unavailable — skipped verification", vim.log.levels.WARN)
    return true
  end

  local f = io.open(tmp, "r")
  if not f then
    pcall(os.remove, tmp)
    vim.notify("[Poste] Checksum file unavailable — skipped verification", vim.log.levels.WARN)
    return true
  end
  local expected = f:read("*a"):match("^(%S+)")
  f:close()
  pcall(os.remove, tmp)

  if not expected then
    vim.notify("[Poste] Checksum file unavailable — skipped verification", vim.log.levels.WARN)
    return true
  end

  -- hasher availability varies by platform (no sha256sum/shasum on Windows):
  -- without any hasher, skip verification like a missing checksum file
  -- rather than comparing garbage and rejecting a good download
  local actual
  if vim.fn.executable("sha256sum") == 1 then
    actual = vim.fn.system({ "sha256sum", archive_path }):match("^(%S+)")
  elseif vim.fn.executable("shasum") == 1 then
    actual = vim.fn.system({ "shasum", "-a", "256", archive_path }):match("^(%S+)")
  elseif vim.fn.executable("certutil") == 1 then
    -- certutil prints the 64-hex-char digest on its own line between banners
    local out = vim.fn.system({ "certutil", "-hashfile", archive_path, "SHA256" })
    for run in tostring(out):gmatch("%x+") do
      if #run == 64 then actual = run break end
    end
  end

  if not actual then
    vim.notify("[Poste] No SHA256 tool found — skipped checksum verification", vim.log.levels.WARN)
    return true
  end
  return M.checksum_matches(actual, expected)
end

--- Synchronous tail of an install: verify checksum, extract, make runnable,
--- stamp the version file. Runs on the main loop from the download callback;
--- every subprocess here is short (a ~1 kB checksum file, the hasher, tar) —
--- the one long call, the archive itself, already finished.
--- @param tmp_archive string  path of the downloaded archive
--- @param platform string  e.g. "aarch64-macos"
--- @param version string  tag or "latest"
--- @return boolean  success
local function finalize_download(tmp_archive, platform, version)
  local ext = archive_ext(platform)

  if not verify_checksum(tmp_archive, platform, version) then
    vim.notify("[Poste] Checksum mismatch — download corrupted", vim.log.levels.ERROR)
    pcall(os.remove, tmp_archive)
    return false
  end

  if ext == ".zip" then
    vim.fn.system({ "powershell", "-Command",
      "Expand-Archive -Force -Path " .. M.ps_literal(tmp_archive)
      .. " -DestinationPath " .. M.ps_literal(BIN_DIR)
    })
  else
    vim.fn.system({ "tar", "xzf", tmp_archive, "-C", BIN_DIR })
  end

  pcall(os.remove, tmp_archive)

  if platform:find("windows") then
    local final_path = BIN_DIR .. "/poste.exe"
    -- tar/zip may create a subdirectory; flatten if needed
    if vim.fn.filereadable(final_path) ~= 1 then
      vim.fn.system({ "powershell", "-Command",
        "Get-ChildItem -Recurse -Filter poste.exe -Path " .. M.ps_literal(BIN_DIR)
        .. " | Move-Item -Destination " .. M.ps_literal(final_path) .. " -Force"
      })
    end
  else
    vim.fn.system({ "chmod", "+x", BIN_DIR .. "/poste" })
  end

  -- extraction was never checked: a corrupt archive / full disk used to fall
  -- through, stamp the .version file and report success with no binary present
  local extracted = BIN_DIR .. (platform:find("windows") and "/poste.exe" or "/poste")
  if vim.fn.filereadable(extracted) ~= 1 then
    vim.notify("[Poste] Extraction failed — binary missing from archive", vim.log.levels.ERROR)
    return false
  end

  local version_tag = version
  if not version_tag:match("^v") and version_tag ~= "latest" then
    version_tag = "v" .. version_tag
  end
  local f = io.open(VERSION_FILE, "w")
  if f then
    f:write(version_tag .. "\n")
    f:close()
  end

  vim.notify("[Poste] Installed " .. version_tag .. " (" .. platform .. ")", vim.log.levels.INFO)
  return true
end

--- One archive path serves every download (`BIN_DIR/download.<ext>`), and the
--- checksum file and extraction step are just as global — so two concurrent
--- downloads would interleave writes into the same files and hand finalize a
--- half-written archive. The overlap is real, not theoretical: startup
--- (`ensure()`) begins fetching the moment no binary is found, and a user who
--- does not know that runs `:PosteDbInstall`. A second call is therefore
--- chained onto the in-flight fetch when it wants the same version (its
--- on_done fires with that fetch's outcome) and refused with a notice
--- otherwise — chaining a different version would silently install the
--- wrong one.
local inflight  -- nil, or { version = string, callbacks = function[] }

--- Download and install the poste binary.
--- The archive fetch — the one call that can run for minutes — is spawned
--- with vim.system so the editor stays usable while it runs; the outcome
--- arrives via on_done and the notify log. Everything before the spawn
--- (platform check, mkdir, curl missing) settles synchronously.
--- @param version string  tag or "latest" (default)
--- @param on_done function|nil  called with true/false once the install settles
--- @return boolean  false when the install could not even start (unsupported
---   platform, mkdir wall, curl missing, a different download already
---   running) — ensure() turns that into the "set vim.g.poste_binary"
---   warning; true means the fetch is running (possibly one this call
---   chained onto) and its result is reported asynchronously
function M.download(version, on_done)
  version = version or "latest"
  if inflight then
    if inflight.version == version then
      vim.notify("[Poste] Download of " .. version
        .. " is already running — chained to it", vim.log.levels.INFO)
      if on_done then table.insert(inflight.callbacks, on_done) end
      return true
    end
    vim.notify("[Poste] Download of " .. inflight.version
      .. " is already running; wait for it to finish, then retry " .. version,
      vim.log.levels.WARN)
    if on_done then on_done(false) end
    return false
  end
  local platform = detect_platform()
  if not platform then
    vim.notify(
      "[Poste] Unsupported platform: " .. vim.inspect(vim.loop.os_uname()),
      vim.log.levels.ERROR
    )
    if on_done then on_done(false) end
    return false
  end

  -- mkdir raises E739 on a permission wall or a read-only data dir — the
  -- same plugin-load kill the un-pcall'd curl calls were (round 50); report
  -- and fail the install instead
  local ok_dir, dir_err = pcall(vim.fn.mkdir, BIN_DIR, "p")
  if not ok_dir then
    vim.notify("[Poste] Cannot create install directory " .. BIN_DIR .. ": "
      .. tostring(dir_err), vim.log.levels.ERROR)
    if on_done then on_done(false) end
    return false
  end

  local url = M.download_url(platform, version)
  local tmp_archive = BIN_DIR .. "/download" .. archive_ext(platform)

  vim.notify("[Poste] Downloading " .. url, vim.log.levels.INFO)

  inflight = { version = version, callbacks = on_done and { on_done } or {} }
  local ok_spawn = pcall(vim.system, M.curl_argv("-fL", url, tmp_archive, 180), {}, function(res)
    -- on_exit arrives straight from the libuv loop — a fast event context
    -- where nvim_echo (vim.notify) and vim.fn.system raise E5560. The
    -- checksum fetch, extraction and every notify move to the main loop
    -- first; caught by an isolated first-run smoke test, not by the specs
    -- (a stubbed vim.system calls on_exit from safe main-loop context).
    vim.schedule(function()
      local ok = false
      if res.code ~= 0 then
        -- a curl exit code (404, timeout, captive portal reset), not a raise
        vim.notify("[Poste] Download failed (exit " .. tostring(res.code) .. ")",
          vim.log.levels.ERROR)
        pcall(os.remove, tmp_archive)
      else
        ok = finalize_download(tmp_archive, platform, version)
      end
      -- Cleared before the callbacks run: a callback that starts the next
      -- download (or a chained :PosteDbInstall retry) must not find this
      -- finished fetch still holding the slot.
      local callbacks = inflight and inflight.callbacks or {}
      inflight = nil
      for _, cb in ipairs(callbacks) do cb(ok) end
    end)
  end)
  if not ok_spawn then
    -- vim.system RAISES when the spawn itself fails (curl missing, E475) —
    -- the same "graceful notify, never a plugin-load exception" contract the
    -- old vim.fn.system call was pcall'd for
    inflight = nil
    vim.notify("[Poste] Download failed — curl is not available on PATH", vim.log.levels.ERROR)
    pcall(os.remove, tmp_archive)
    if on_done then on_done(false) end
    return false
  end
  return true
end

--- Whether a release download is currently in flight. Surfaces in
--- :checkhealth, which otherwise reports "binary not found — run
--- :PosteDbInstall" for a download that is already running.
--- @return boolean
function M.in_progress()
  return inflight ~= nil
end

--- Ensure the binary is available.
--- Called at plugin startup. Returns the binary path when one is already
--- usable; otherwise it starts the release download in the background and
--- returns nil — the installed binary answers the next find_poste_binary()
--- call, and the outcome rides the notify log (plus on_done).
--- The search itself belongs to `state.find_poste_binary()`: one rule, one
--- copy. The second copy this function used to carry had drifted — no
--- runnability test (a readable-but-not-executable override was returned as
--- the answer, and the download that would have replaced it was skipped), no
--- `$POSTE_BINARY`, and no `$PATH` lookup, which made the documented
--- "put target/release/poste in your PATH" install trigger a release download
--- that then took precedence over the user's own build. What this function
--- adds is only what a lookup cannot: downloading a release when nothing
--- usable exists anywhere.
--- @param on_done function|nil  forwarded to download()
--- @return string|nil  the usable binary path, nil while a download runs
function M.ensure(on_done)
  local found = require("poste-db.state").find_poste_binary()
  if found then return found end

  -- Fallback: attempt download
  local started = M.download("latest", on_done)
  if not started then
    vim.notify(
      "[Poste] Binary not found and download failed. "
        .. "Set `vim.g.poste_binary = \"/path/to/poste\"` in your config.",
      vim.log.levels.WARN
    )
  end
  return nil
end

M._test = {
  --- Spec isolation: a download that never settles inside a test (a stubbed
  --- vim.system whose on_exit nobody pumps) would otherwise chain the next
  --- test's download onto a phantom fetch.
  reset_inflight = function() inflight = nil end,
  inflight_version = function() return inflight and inflight.version or nil end,
}

return M
