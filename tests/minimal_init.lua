-- Minimal Neovim configuration for running SQL tests.
-- Used as -u script (actual vimrc replacement).
-- Self-contained since the poste.nvim family dissolution (no poste.nvim on
-- rtp). The poste BINARY is still the family one built in ../poste.nvim —
-- a locally built binary is preferred when present (debug first, matching
-- find_poste_binary's order), else a dummy keeps the vendored installer's
-- ensure() hermetic (no download attempt in headless runs).

vim.opt.runtimepath:append(".")

if vim.g.poste_binary == nil then
  -- A caller-supplied $POSTE_BINARY wins over the sibling-build guess:
  -- find_poste_binary itself prefers g:poste_binary over the env, so without
  -- this hand-off an explicit `POSTE_BINARY=... tests/run.sh` (e.g. pointing
  -- at a ../poste.nvim build) would be silently shadowed below.
  local env_binary = vim.env.POSTE_BINARY
  if env_binary and vim.fn.filereadable(env_binary) == 1 then
    vim.g.poste_binary = vim.fn.fnamemodify(env_binary, ":p")
  else
    local debug_build = "../poste.nvim/target/debug/poste"
    local release_build = "../poste.nvim/target/release/poste"
    local chosen = (vim.fn.filereadable(debug_build) == 1) and debug_build or release_build
    if vim.fn.filereadable(chosen) == 1 then
      vim.g.poste_binary = vim.fn.fnamemodify(chosen, ":p")
    else
      local dummy = vim.fn.tempname()
      vim.fn.writefile({ "# dummy poste binary for tests" }, dummy)
      -- find_poste_binary requires the exec bit, so the dummy must carry one.
      local uv = vim.uv or vim.loop
      uv.fs_chmod(dummy, 493) -- 0o755
      vim.g.poste_binary = dummy
    end
  end
end

-- Export the resolved path for the specs plenary runs in a *child* nvim: that
-- process is started without `-u`, so it never evaluates this file and would
-- otherwise find no binary at all -- every Rust-dependent assertion then either
-- prints SKIP or fails on an empty completion list.
if vim.env.POSTE_BINARY == nil then
  vim.env.POSTE_BINARY = vim.g.poste_binary
end

-- Optional: poste-ai.nvim (AI chat integration tests are skipped when absent)
if vim.fn.isdirectory("../poste-ai.nvim") == 1 then
  vim.opt.runtimepath:append("../poste-ai.nvim")
end

package.path = package.path
  .. ";./tests/?.lua"
  .. ";./tests/?/init.lua"

if vim.api.nvim_buf_is_valid(0) then
  pcall(vim.api.nvim_buf_set_option, 0, "filetype", "poste_sql")
end