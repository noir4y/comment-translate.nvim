---@diagnostic disable: undefined-global
describe('translate.llm', function()
  local config
  local llm
  local cache
  local original_notify
  local original_executable
  local original_env = {}
  local notify_messages
  local job_state

  local function restore_env()
    for key, value in pairs(original_env) do
      vim.env[key] = value
    end
    original_env = {}
  end

  local function set_env(key, value)
    if original_env[key] == nil then
      original_env[key] = vim.env[key]
    end
    vim.env[key] = value
  end

  local function setup_fake_job()
    job_state = {
      new_calls = 0,
      exit_code = 0,
      stdout = '',
      stderr_lines = {},
      last_opts = nil,
    }

    local FakeJob = {}
    function FakeJob:new(opts)
      job_state.new_calls = job_state.new_calls + 1
      job_state.last_opts = opts
      return setmetatable({
        _opts = opts,
      }, {
        __index = {
          result = function()
            return { job_state.stdout }
          end,
          start = function(self)
            for _, line in ipairs(job_state.stderr_lines or {}) do
              self._opts.on_stderr(nil, line)
            end
            self._opts.on_exit(self, job_state.exit_code)
          end,
        },
      })
    end

    package.loaded['plenary.job'] = FakeJob
  end

  local function await_callback(fn)
    local done = false
    local value = nil
    fn(function(result)
      value = result
      done = true
    end)
    assert.is_true(vim.wait(1000, function()
      return done
    end))
    return value
  end

  local function extract_request_body(args)
    for i = 1, #args do
      if args[i] == '-d' then
        return vim.fn.json_decode(args[i + 1])
      end
    end
    return nil
  end

  local function has_arg(args, expected)
    for _, arg in ipairs(args) do
      if arg == expected then
        return true
      end
    end
    return false
  end

  local function last_arg(args)
    return args[#args]
  end

  before_each(function()
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.translate.llm'] = nil
    package.loaded['plenary.job'] = nil

    setup_fake_job()

    config = require('comment-translate.config')
    config.reset()
    cache = require('comment-translate.translate.cache')
    cache.clear()
    llm = require('comment-translate.translate.llm')

    notify_messages = {}
    original_notify = vim.notify
    original_executable = vim.fn.executable
    vim.notify = function(msg, level)
      table.insert(notify_messages, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = original_notify
    vim.fn.executable = original_executable
    restore_env()
  end)

  it('should build openai request and parse response', function()
    config.setup({
      llm = {
        provider = 'openai',
        api_key = 'openai-key',
        model = 'gpt-5.2',
        timeout = 12,
      },
    })
    job_state.stdout = vim.fn.json_encode({
      choices = {
        { message = { content = 'こんにちは' } },
      },
    })

    local result = await_callback(function(cb)
      llm.translate('hello', 'ja', 'en', cb)
    end)

    assert.equals('こんにちは', result)
    assert.equals(1, job_state.new_calls)
    assert.equals('curl', job_state.last_opts.command)
    local args = job_state.last_opts.args
    assert.equals('https://api.openai.com/v1/chat/completions', last_arg(args))
    assert.is_true(has_arg(args, 'Authorization: Bearer openai-key'))
    local body = extract_request_body(args)
    assert.equals('gpt-5.2', body.model)
    assert.equals('system', body.messages[1].role)
    assert.equals('user', body.messages[2].role)
  end)

  it('should use OPENAI_API_KEY for openai provider', function()
    set_env('OPENAI_API_KEY', 'env-openai-key')
    config.setup({
      llm = {
        provider = 'openai',
        model = 'my-model',
        endpoint = 'https://example.com/v1/chat/completions',
      },
    })
    job_state.stdout = vim.fn.json_encode({
      choices = {
        { message = { content = '訳文' } },
      },
    })

    local result = await_callback(function(cb)
      llm.translate('text', 'ja', nil, cb)
    end)

    assert.equals('訳文', result)
    local args = job_state.last_opts.args
    assert.equals('https://example.com/v1/chat/completions', last_arg(args))
    assert.is_true(has_arg(args, 'Authorization: Bearer env-openai-key'))
  end)

  it('should build anthropic request and parse response', function()
    config.setup({
      llm = {
        provider = 'anthropic',
        api_key = 'anthropic-key',
        model = 'claude-sonnet-4-0',
      },
    })
    job_state.stdout = vim.fn.json_encode({
      content = {
        { type = 'text', text = '翻訳結果' },
      },
    })

    local result = await_callback(function(cb)
      llm.translate('source', 'ja', 'en', cb)
    end)

    assert.equals('翻訳結果', result)
    local args = job_state.last_opts.args
    assert.equals('https://api.anthropic.com/v1/messages', last_arg(args))
    assert.is_true(has_arg(args, 'x-api-key: anthropic-key'))
    assert.is_true(has_arg(args, 'anthropic-version: 2023-06-01'))
    local body = extract_request_body(args)
    assert.equals('claude-sonnet-4-0', body.model)
    assert.equals('user', body.messages[1].role)
  end)

  it('should build gemini request and parse response', function()
    config.setup({
      llm = {
        provider = 'gemini',
        api_key = 'gemini-key',
        model = 'gemini-2.5-flash',
      },
    })
    job_state.stdout = vim.fn.json_encode({
      candidates = {
        {
          content = {
            parts = {
              { text = 'Gemini訳' },
            },
          },
        },
      },
    })

    local result = await_callback(function(cb)
      llm.translate('source', 'ja', nil, cb)
    end)

    assert.equals('Gemini訳', result)
    local args = job_state.last_opts.args
    assert.matches(
      '^https://generativelanguage%.googleapis%.com/.+:generateContent$',
      last_arg(args)
    )
    assert.is_true(has_arg(args, 'x-goog-api-key: gemini-key'))
    assert.is_false(has_arg(args, 'Authorization: Bearer gemini-key'))
    assert.is_false(has_arg(args, 'x-api-key: gemini-key'))
    local body = extract_request_body(args)
    assert.equals(
      'Translate the following text from auto to ja. Return only translated text.\n\nsource',
      body.contents[1].parts[1].text
    )
  end)

  it('should use GEMINI_API_KEY for gemini provider', function()
    set_env('GEMINI_API_KEY', 'env-gemini-key')
    config.setup({
      llm = {
        provider = 'gemini',
        model = 'gemini-2.5-flash',
      },
    })
    job_state.stdout = vim.fn.json_encode({
      candidates = {
        {
          content = {
            parts = {
              { text = 'Gemini訳' },
            },
          },
        },
      },
    })

    local result = await_callback(function(cb)
      llm.translate('source', 'ja', nil, cb)
    end)

    assert.equals('Gemini訳', result)
    local args = job_state.last_opts.args
    assert.matches(
      '^https://generativelanguage%.googleapis%.com/.+:generateContent$',
      last_arg(args)
    )
    assert.is_true(has_arg(args, 'x-goog-api-key: env-gemini-key'))
  end)

  it('should allow ollama without api key', function()
    config.setup({
      llm = {
        provider = 'ollama',
        model = 'translategemma:4b',
      },
    })
    job_state.stdout = vim.fn.json_encode({
      message = {
        content = 'ローカル翻訳',
      },
    })

    local result = await_callback(function(cb)
      llm.translate('source', 'ja', nil, cb)
    end)

    assert.equals('ローカル翻訳', result)
    local args = job_state.last_opts.args
    assert.equals('http://localhost:11434/api/chat', last_arg(args))
    assert.is_false(has_arg(args, 'Authorization: Bearer '))
  end)

  it('should fallback unsupported provider to openai and fail without api key', function()
    set_env('OPENAI_API_KEY', nil)
    config.setup({
      llm = {
        provider = 'invalid-provider',
      },
    })

    local result = await_callback(function(cb)
      llm.translate('source', 'ja', nil, cb)
    end)

    assert.is_nil(result)
    assert.equals(0, job_state.new_calls)
    assert.matches("unsupported llm.provider 'invalid%-provider'", notify_messages[1].msg)
    assert.matches('API key is missing for provider openai', notify_messages[2].msg)
  end)

  it('should fail when api key is missing for non-ollama provider', function()
    config.setup({
      llm = {
        provider = 'anthropic',
      },
    })

    local result = await_callback(function(cb)
      llm.translate('source', 'ja', nil, cb)
    end)

    assert.is_nil(result)
    assert.equals(0, job_state.new_calls)
    assert.matches('API key is missing', notify_messages[1].msg)
  end)

  it('should fail when curl is not installed', function()
    config.setup({
      llm = {
        provider = 'openai',
        api_key = 'openai-key',
      },
    })
    vim.fn.executable = function(bin)
      if bin == 'curl' then
        return 0
      end
      return original_executable(bin)
    end

    local result = await_callback(function(cb)
      llm.translate('source', 'ja', nil, cb)
    end)

    assert.is_nil(result)
    assert.equals(0, job_state.new_calls)
    assert.matches('curl is required for translation', notify_messages[1].msg)
  end)

  it('should return nil when curl exits with error', function()
    config.setup({
      llm = {
        provider = 'openai',
        api_key = 'openai-key',
      },
    })
    job_state.exit_code = 22
    job_state.stderr_lines = { 'curl failed' }
    job_state.stdout = ''

    local result = await_callback(function(cb)
      llm.translate('source', 'ja', nil, cb)
    end)

    assert.is_nil(result)
    assert.matches('LLM translation failed', notify_messages[1].msg)
    assert.matches('curl failed', notify_messages[1].msg)
  end)

  it('should return nil for invalid json response', function()
    config.setup({
      llm = {
        provider = 'openai',
        api_key = 'openai-key',
      },
    })
    job_state.stdout = 'not-json'

    local result = await_callback(function(cb)
      llm.translate('source', 'ja', nil, cb)
    end)

    assert.is_nil(result)
    assert.matches('Failed to parse LLM response', notify_messages[1].msg)
  end)

  it('should reuse cache and avoid duplicate requests', function()
    config.setup({
      llm = {
        provider = 'openai',
        api_key = 'openai-key',
      },
    })
    job_state.stdout = vim.fn.json_encode({
      choices = {
        { message = { content = 'cached-translation' } },
      },
    })

    local first = await_callback(function(cb)
      llm.translate('cache-me', 'ja', nil, cb)
    end)
    local second = await_callback(function(cb)
      llm.translate('cache-me', 'ja', nil, cb)
    end)

    assert.equals('cached-translation', first)
    assert.equals('cached-translation', second)
    assert.equals(1, job_state.new_calls)
  end)
end)
