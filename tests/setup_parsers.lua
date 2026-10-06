-- Run through `make deps`; never installs into the user's Neovim runtime.
local requirements = dofile('tests/parser_requirements.lua')
local uv = vim.uv or vim.loop
local root = assert(os.getenv('COMMENT_TRANSLATE_TEST_DEPS_DIR'))
local tooling = root .. '/nvim-treesitter-' .. requirements.tooling_revision
local runtime = root .. '/runtime'

local function run(argv)
  local output = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 then
    error('Test parser setup failed: ' .. argv[1] .. '\n' .. output)
  end
  return vim.trim(output)
end

local function download(url, path)
  run({ 'curl', '-fL', '--retry', '3', '--connect-timeout', '15', '-o', path .. '.download', url })
  assert(uv.fs_rename(path .. '.download', path))
end

local function fixture_link(source, path)
  local existing = uv.fs_lstat(path)
  if existing then
    assert(
      existing.type == 'link' and uv.fs_readlink(path) == source,
      'Test fixture does not match pinned recipe: ' .. path .. '; use a fresh TEST_DEPS_DIR'
    )
  else
    assert(uv.fs_symlink(source, path))
  end
end

local function setup()
  for _, executable in ipairs({ 'git', 'curl', 'gzip', 'tar', 'node', 'cc' }) do
    assert(vim.fn.executable(executable) == 1, 'Test parser setup requires ' .. executable)
  end
  vim.fn.mkdir(root, 'p')
  if vim.fn.isdirectory(tooling .. '/.git') == 0 then
    run({ 'git', 'init', tooling })
    run({
      'git',
      '-C',
      tooling,
      'remote',
      'add',
      'origin',
      'https://github.com/nvim-treesitter/nvim-treesitter',
    })
  end
  local head = vim.fn.system({ 'git', '-C', tooling, 'rev-parse', 'HEAD' })
  if vim.v.shell_error ~= 0 or vim.trim(head) ~= requirements.tooling_revision then
    run({ 'git', '-C', tooling, 'fetch', '--depth', '1', 'origin', requirements.tooling_revision })
    run({ 'git', '-C', tooling, 'checkout', '--detach', 'FETCH_HEAD' })
  end
  assert(run({ 'git', '-C', tooling, 'rev-parse', 'HEAD' }) == requirements.tooling_revision)
  assert(
    run({ 'git', '-C', tooling, 'status', '--porcelain', '--untracked-files=no' }) == '',
    'Pinned test tooling was modified; use a fresh TEST_DEPS_DIR'
  )

  -- Reject foreign/stale cache entries before installing or reusing grammars.
  vim.fn.mkdir(runtime, 'p')
  fixture_link(tooling .. '/queries', runtime .. '/queries')
  fixture_link(
    tooling .. '/lua/nvim-treesitter/query_predicates.lua',
    runtime .. '/query_predicates.lua'
  )

  local platform = uv.os_uname()
  local system = ({ Darwin = 'macos', Linux = 'linux' })[platform.sysname]
  local arch = ({ arm64 = 'arm64', aarch64 = 'arm64', x86_64 = 'x64' })[platform.machine]
  assert(system and arch, 'Test parser setup supports macOS and Linux on arm64 or x64')
  local bin = root .. '/tree-sitter-' .. requirements.cli_version .. '/bin'
  vim.fn.mkdir(bin, 'p')
  local cli = bin .. '/tree-sitter'
  if vim.fn.filereadable(cli) == 0 then
    download(
      'https://github.com/tree-sitter/tree-sitter/releases/download/v'
        .. requirements.cli_version
        .. '/tree-sitter-'
        .. system
        .. '-'
        .. arch
        .. '.gz',
      cli .. '.gz'
    )
    run({ 'gzip', '-df', cli .. '.gz' })
    assert(uv.fs_chmod(cli, 493))
  end
  assert(
    run({ cli, '--version' }):match(
      '^tree%-sitter ' .. requirements.cli_version:gsub('%.', '%%.') .. '%s'
    )
  )
  vim.env.PATH = bin .. ':' .. vim.env.PATH

  -- Keep installation and query lookup independent of personal plugins/parsers.
  vim.opt.rtp = { runtime, tooling, vim.env.VIMRUNTIME }
  require('nvim-treesitter.configs').setup({ parser_install_dir = runtime })
  local installer = require('nvim-treesitter.install')
  -- Use the same generated ABI on every Neovim version, including 0.10.
  installer.ts_generate_args = { 'generate', '--no-bindings', '--abi', '14' }
  local lock = vim.fn.json_decode(vim.fn.readfile(tooling .. '/lockfile.json'))
  local missing = {}
  for _, lang in ipairs(requirements.languages) do
    local revision_file = runtime .. '/parser-info/' .. lang .. '.revision'
    local revision = vim.fn.filereadable(revision_file) == 1 and vim.fn.readfile(revision_file)[1]
    if
      revision ~= lock[lang].revision
      or vim.fn.filereadable(runtime .. '/parser/' .. lang .. '.so') == 0
    then
      table.insert(missing, lang)
    end
  end
  if #missing > 0 then
    installer.commands.TSInstallSync['run!'](unpack(missing))
  end
  for _, lang in ipairs(requirements.languages) do
    local path = runtime .. '/parser/' .. lang .. '.so'
    assert(vim.fn.filereadable(path) == 1, 'Required test parser missing: ' .. lang)
    local loaded, load_error = vim.treesitter.language.add(lang, { path = path })
    -- Neovim 0.10 returns nil without an error on a successful load.
    assert(loaded ~= false and load_error == nil, 'Required test parser cannot load: ' .. lang)
    local revision_file = runtime .. '/parser-info/' .. lang .. '.revision'
    assert(
      vim.fn.readfile(revision_file)[1] == lock[lang].revision,
      'Test parser revision mismatch: ' .. lang
    )
    print('Test parser: ' .. lang .. ' ' .. lock[lang].revision)
  end
  print('Test tooling: nvim-treesitter ' .. requirements.tooling_revision)
  print('Test generator: tree-sitter ' .. requirements.cli_version .. ', ABI 14')
end

local ok, err = pcall(setup)
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  vim.cmd('cquit 1')
end
