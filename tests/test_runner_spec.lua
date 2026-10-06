---@diagnostic disable: undefined-global
describe('strict real-parser test runner', function()
  local original_runtime, original_strict, original_deps_dir
  local temporary_paths
  local uv = vim.uv or vim.loop

  before_each(function()
    original_runtime = vim.env.COMMENT_TRANSLATE_TEST_RTP
    original_strict = vim.env.COMMENT_TRANSLATE_TEST_REQUIRE_PARSERS
    original_deps_dir = vim.env.COMMENT_TRANSLATE_TEST_DEPS_DIR
    temporary_paths = {}
  end)

  after_each(function()
    vim.env.COMMENT_TRANSLATE_TEST_RTP = original_runtime
    vim.env.COMMENT_TRANSLATE_TEST_REQUIRE_PARSERS = original_strict
    vim.env.COMMENT_TRANSLATE_TEST_DEPS_DIR = original_deps_dir
    for _, path in ipairs(temporary_paths) do
      local stat = uv.fs_lstat(path)
      vim.fn.delete(path, stat and stat.type == 'directory' and 'd' or '')
    end
  end)

  local function child(command)
    local output = vim.fn.system({
      vim.v.progpath,
      '--headless',
      '--noplugin',
      '-i',
      'NONE',
      '-u',
      'tests/minimal_init.lua',
      '-c',
      command,
    })
    return vim.v.shell_error, output
  end

  it('fails instead of borrowing personal or bundled parsers from another runtime', function()
    vim.env.COMMENT_TRANSLATE_TEST_REQUIRE_PARSERS = '1'
    vim.env.COMMENT_TRANSLATE_TEST_RTP = vim.fn.tempname()
    local code, output = child('qa')
    assert.is_true(code ~= 0)
    assert.is_true(output:find('Required test parser missing: astro', 1, true) ~= nil)
  end)

  it('fails when strict mode has no parser runtime', function()
    vim.env.COMMENT_TRANSLATE_TEST_REQUIRE_PARSERS = '1'
    vim.env.COMMENT_TRANSLATE_TEST_RTP = ''
    local code, output = child('qa')
    assert.is_true(code ~= 0)
    assert.is_true(
      output:find('Strict parser tests require COMMENT_TRANSLATE_TEST_RTP', 1, true) ~= nil
    )
  end)

  it('fails when a required parser library exists but cannot load', function()
    local runtime = vim.fn.tempname()
    local library = runtime .. '/parser/astro.so'
    vim.fn.mkdir(runtime .. '/parser', 'p')
    temporary_paths = { library, runtime .. '/parser', runtime }
    vim.fn.writefile({ 'invalid parser fixture' }, library)
    vim.env.COMMENT_TRANSLATE_TEST_REQUIRE_PARSERS = '1'
    vim.env.COMMENT_TRANSLATE_TEST_RTP = runtime
    local code, output = child('qa')
    assert.is_true(code ~= 0)
    assert.is_true(output:find('astro', 1, true) ~= nil)
  end)

  -- This check needs the complete fixture runtime; the quick suite does not.
  if os.getenv('COMMENT_TRANSLATE_TEST_REQUIRE_PARSERS') == '1' then
    it('rejects cached queries that do not belong to the pinned recipe', function()
      local requirements = dofile('tests/parser_requirements.lua')
      local root = vim.fn.tempname()
      local runtime = root .. '/runtime'
      local tooling = root .. '/nvim-treesitter-' .. requirements.tooling_revision
      vim.fn.mkdir(runtime, 'p')
      vim.fn.mkdir(root .. '/foreign-queries', 'p')
      temporary_paths = {
        runtime .. '/queries',
        root .. '/foreign-queries',
        runtime,
        tooling,
        root,
      }
      local fixture_tooling =
        vim.fn.fnamemodify(uv.fs_readlink(original_runtime .. '/queries'), ':h')
      assert(uv.fs_symlink(fixture_tooling, tooling))
      assert(uv.fs_symlink(root .. '/foreign-queries', runtime .. '/queries'))
      vim.env.COMMENT_TRANSLATE_TEST_DEPS_DIR = root
      local output = vim.fn.system({
        vim.v.progpath,
        '--headless',
        '--noplugin',
        '-i',
        'NONE',
        '-u',
        'NONE',
        '-l',
        'tests/setup_parsers.lua',
      })
      assert.is_true(vim.v.shell_error ~= 0)
      assert.is_true(output:find('Test fixture does not match pinned recipe', 1, true) ~= nil)
    end)

    it('returns a failing exit code and records attempted pending tests', function()
      local path = vim.fn.tempname() .. '.lua'
      table.insert(temporary_paths, path)
      vim.fn.writefile({
        "describe('controlled runner fixture', function()",
        "  it('cannot skip', function() pending('unavailable fixture') end)",
        'end)',
      }, path)
      local command = 'lua require("plenary.busted").run(' .. string.format('%q', path) .. ')'
      local code, output = child(command)
      assert.is_true(code ~= 0)
      assert.is_true(
        output:find('Pending tests are forbidden in strict real-parser mode', 1, true) ~= nil
      )
      assert.is_true(output:find('Pending: 1', 1, true) ~= nil)
    end)
  end
end)
