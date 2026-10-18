--- install.lua spec — the startup guarantee: `ensure()` returns a binary the
--- plugin can actually spawn, and only reaches the network when nothing
--- usable exists. The candidate walk itself lives in state.find_poste_binary
--- (see sql_state_spec.lua); these cases pin that ensure() delegates to it
--- rather than keeping a second, drifted copy of the rule. The download
--- itself runs detached (vim.system), so its failure paths are pinned
--- against the two shapes a user can hit: the spawn failing (no curl) and
--- curl exiting non-zero.
local install = require("poste-db.install")
local state = require("poste-db.state")
local uv = vim.uv or vim.loop

describe("poste-db install ensure", function()
  local created = {}
  local empty_dir

  --- Make a file with an explicit mode, tracked for cleanup.
  local function make(path, mode)
    vim.fn.writefile({ "#!/bin/sh", "echo poste 1.0.0" }, path)
    assert.truthy(uv.fs_chmod(path, mode))
    created[#created + 1] = path
    return path
  end

  local download_calls
  local saved = {}
  before_each(function()
    empty_dir = vim.fn.tempname()
    assert.truthy(vim.fn.mkdir(empty_dir, "p"))
    -- An empty PATH keeps the lookup's last arm from answering with a binary
    -- installed on this machine; each case supplies its own candidates.
    saved = {
      g = vim.g.poste_binary,
      env = vim.env.POSTE_BINARY,
      path = vim.env.PATH,
      cfg = state.config.poste_binary,
      download = install.download,
    }
    vim.env.PATH = empty_dir
    state.config.poste_binary = empty_dir .. "/not-configured"
    download_calls = 0
    install.download = function()
      download_calls = download_calls + 1
      return false
    end
  end)
  after_each(function()
    if saved.g == nil then vim.cmd("unlet! g:poste_binary") else vim.g.poste_binary = saved.g end
    vim.env.POSTE_BINARY = saved.env
    vim.env.PATH = saved.path
    state.config.poste_binary = saved.cfg
    install.download = saved.download
    for _, p in ipairs(created) do vim.fn.delete(p) end
    created = {}
    vim.fn.delete(empty_dir, "rf")
  end)

  it("returns the binary state.find_poste_binary resolves, without downloading", function()
    local exe = make(vim.fn.tempname(), tonumber("755", 8))
    vim.g.poste_binary = exe
    assert.equals(vim.fn.fnamemodify(exe, ":p"), install.ensure())
    assert.equals(0, download_calls)
  end)

  it("refuses a readable but not executable override", function()
    -- The old copy of the rule returned this path and skipped the download
    -- that would have produced a binary the transport can spawn.
    local inert = make(vim.fn.tempname(), tonumber("644", 8))
    local runnable = make(vim.fn.tempname(), tonumber("755", 8))
    vim.g.poste_binary = inert
    vim.env.POSTE_BINARY = runnable
    assert.equals(vim.fn.fnamemodify(runnable, ":p"), install.ensure())
    assert.equals(0, download_calls)
  end)

  it("uses a binary on $PATH instead of downloading a release", function()
    -- "put target/release/poste in PATH" is a documented install route;
    -- downloading over it also silently outranks the user's own build.
    vim.cmd("unlet! g:poste_binary")
    vim.env.POSTE_BINARY = nil
    make(empty_dir .. "/poste", tonumber("755", 8))
    local found = install.ensure()
    assert.is_not_nil(found)
    assert.equals("poste", vim.fn.fnamemodify(found, ":t"))
    assert.equals(empty_dir, vim.fn.fnamemodify(found, ":h"))
    assert.equals(0, download_calls)
  end)

  it("downloads when nothing usable is anywhere", function()
    vim.cmd("unlet! g:poste_binary")
    vim.env.POSTE_BINARY = nil
    assert.is_nil(install.ensure())
    assert.equals(1, download_calls)
  end)

  it("hands on_done to the download when nothing usable exists", function()
    -- The download settles asynchronously, so :PosteDbInstall and any other
    -- caller learn the outcome through this callback; ensure() must forward
    -- it untouched.
    vim.cmd("unlet! g:poste_binary")
    vim.env.POSTE_BINARY = nil
    local captured_version, captured_cb
    install.download = function(version, cb)
      download_calls = download_calls + 1
      captured_version, captured_cb = version, cb
      return true
    end
    local marker = function() end
    assert.is_nil(install.ensure(marker))
    assert.equals("latest", captured_version)
    assert.equals(marker, captured_cb)
  end)
end)

describe("poste-db install ps_literal", function()
  -- Everything after `powershell -Command` is re-parsed as a PowerShell command
  -- line even when it arrives through vim.fn.system's list form, so the paths
  -- the installer builds from stdpath("data") must reach it as literals: a
  -- username with a space or an apostrophe is ordinary on Windows.
  it("keeps a path with a space in one piece", function()
    assert.equals("'C:/Users/Jane Smith/nvim-data/poste/bin'",
      install.ps_literal("C:/Users/Jane Smith/nvim-data/poste/bin"))
  end)

  it("escapes an apostrophe by doubling it, not by ending the literal", function()
    assert.equals("'C:/Users/O''Brien/poste/bin'",
      install.ps_literal("C:/Users/O'Brien/poste/bin"))
  end)

  it("leaves expansion metacharacters inside the literal", function()
    assert.equals("'/tmp/x$(touch pwned)/bin'", install.ps_literal("/tmp/x$(touch pwned)/bin"))
  end)
end)

describe("poste-db install curl_argv", function()
  -- Every curl call carries explicit ceilings. The archive fetch runs detached
  -- from the main loop now, but a run without a ceiling would keep the
  -- background curl alive for as long as the OS socket timeout — minutes with
  -- no failure reported — and the checksum fetch runs on the main loop, where
  -- the same ceiling is what bounds a brief pause.
  local function has(argv, flag, value)
    for i, v in ipairs(argv) do
      if v == flag and argv[i + 1] == value then return true end
    end
    return false
  end

  it("bounds both the connect and the whole transfer", function()
    local argv = install.curl_argv("-fL", "https://example/poste.tar.gz", "/tmp/poste.tar.gz", 180)
    assert.is_true(has(argv, "--connect-timeout", "10"))
    assert.is_true(has(argv, "--max-time", "180"))
  end)

  it("keeps the flags the caller asked for, silent or not", function()
    -- The checksum fetch is silent, the release download is not.
    assert.equals("-sfL", install.curl_argv("-sfL", "u", "/tmp/o", 20)[2])
    assert.equals("-fL", install.curl_argv("-fL", "u", "/tmp/o", 20)[2])
  end)

  it("passes url and output path as their own argv entries", function()
    -- List form is what keeps a path with a space or a metacharacter out of a
    -- shell; joining them back into one string would reintroduce Round 7's bug.
    local url = "https://example/a b"
    local out = "/tmp/out file$(touch pwned)"
    local argv = install.curl_argv("-fL", url, out, 20)
    assert.equals("curl", argv[1])
    assert.equals(url, argv[7])
    assert.equals("-o", argv[8])
    assert.equals(out, argv[9])
  end)

  it("returns a fresh list per call", function()
    -- The installer calls this twice; a shared table would let one call's
    -- mutation leak into the other's command line.
    local a = install.curl_argv("-fL", "u", "/tmp/a", 20)
    local b = install.curl_argv("-fL", "u", "/tmp/b", 20)
    a[7] = "mutated"
    assert.is_not.equal(a, b)
    assert.equals("u", b[7])
  end)
end)

describe("poste-db install checksum_matches", function()
  -- The release asset holds sha256sum's lowercase hex; certutil -hashfile
  -- prints the same digest uppercase, which is the only hasher on a Windows
  -- box without Git in PATH.
  local lower = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
  local upper = lower:upper()

  it("accepts the uppercase spelling certutil prints", function()
    assert.is_true(install.checksum_matches(upper, lower))
  end)

  it("accepts two lowercase digests, the sha256sum case", function()
    assert.is_true(install.checksum_matches(lower, lower))
  end)

  it("rejects a digest that differs in one nibble", function()
    local tampered = lower:sub(1, 63) .. (lower:sub(64) == "8" and "9" or "8")
    assert.is_false(install.checksum_matches(tampered, lower))
    assert.is_false(install.checksum_matches(lower, tampered))
  end)

  it("rejects a different digest of the same length", function()
    -- Guards the fix against a compare loose enough to satisfy length alone.
    local other = string.rep("0", 64)
    assert.is_false(install.checksum_matches(other, lower))
  end)

  it("rejects a truncated digest", function()
    assert.is_false(install.checksum_matches(upper:sub(1, 63), lower))
  end)
end)

describe("poste-db install download failure paths", function()
  -- The archive fetch is spawned with vim.system. Both failure shapes a user
  -- can hit must end in a notify (never a raise — download() sits on the
  -- setup() path via ensure()) and settle on_done(false): the spawn itself
  -- failing (curl missing), and curl exiting non-zero (404, timeout, a
  -- captive portal reset).
  local saved_notify, saved_system, notices

  before_each(function()
    saved_notify = vim.notify
    saved_system = vim.system
    notices = {}
    vim.notify = function(msg, level) notices[#notices + 1] = { msg = msg, level = level } end
  end)

  after_each(function()
    vim.notify = saved_notify
    vim.system = saved_system
  end)

  local function failure_notice()
    for _, n in ipairs(notices) do
      if n.level == vim.log.levels.ERROR then return n end
    end
  end

  it("reports failure instead of raising when curl is missing", function()
    -- raise the exact error a spawn failure produces (Vim:E475); a PATH
    -- rewrite does not reliably hide the real curl from the spawn
    vim.system = function(argv)
      error(("Vim:E475: Invalid value for argument cmd: '%s' is not executable"):format(argv[1]))
    end
    local settled = {}
    assert.is_false(install.download("latest", function(ok) settled[#settled + 1] = ok end))
    assert.truthy(failure_notice(), "the failure must be reported, not raised")
    assert.is_truthy(failure_notice().msg:find("curl is not available", 1, true))
    assert.same({ false }, settled)
  end)

  it("reports a curl exit code and settles on_done(false)", function()
    -- The spawn succeeded; curl's exit code is the failure. download() still
    -- returns true (the fetch *ran*), and the outcome rides on_done for
    -- callers like :PosteDbInstall.
    vim.system = function(_, _, on_exit)
      on_exit({ code = 22 })
      return {}
    end
    local settled = {}
    assert.is_true(install.download("latest", function(ok) settled[#settled + 1] = ok end))
    -- on_exit lands from the libuv loop (a fast event): handling is deferred
    -- to the main loop, so nothing may have run synchronously — a notify
    -- there is E5560, the bug an isolated first-run smoke test caught after
    -- an all-green unit run (a stub calls on_exit from safe context).
    assert.same({}, settled)
    assert.is_nil(failure_notice())
    -- vim.wait pumps the event loop until the scheduled handler has run
    assert.truthy(vim.wait(1000, function() return #settled == 1 end),
      "the scheduled handler must settle on_done")
    assert.truthy(failure_notice(), "a curl exit code must surface as a notify")
    assert.is_truthy(failure_notice().msg:find("exit 22", 1, true))
    assert.same({ false }, settled)
  end)
end)
