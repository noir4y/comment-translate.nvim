---@diagnostic disable: undefined-global
describe('health', function()
  local health
  local config
  local captured
  local bufnr
  local health_bufnr
  local original_bufnr
  local original_health
  local original_get_parser
  local original_treesitter
  local original_env = {}

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

  local function contains_message(messages, pattern)
    for _, msg in ipairs(messages) do
      if msg:match(pattern) then
        return true
      end
    end
    return false
  end

  before_each(function()
    package.loaded['comment-translate.health'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate'] = nil
    package.loaded['plenary'] = true

    config = require('comment-translate.config')
    config.reset()
    health = require('comment-translate.health')
    original_bufnr = vim.api.nvim_get_current_buf()
    bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_current_buf(bufnr)
    health_bufnr = vim.api.nvim_create_buf(false, true)
    original_treesitter = vim.treesitter
    original_get_parser = vim.treesitter.get_parser
    health.set_target_bufnr(nil)

    captured = {
      ok = {},
      error = {},
      warn = {},
      info = {},
    }
    original_health = vim.health
    vim.health = {
      start = function() end,
      ok = function(msg)
        table.insert(captured.ok, msg)
      end,
      error = function(msg)
        table.insert(captured.error, msg)
      end,
      warn = function(msg)
        table.insert(captured.warn, msg)
      end,
      info = function(msg)
        table.insert(captured.info, msg)
      end,
    }
  end)

  after_each(function()
    vim.health = original_health
    vim.treesitter = original_treesitter
    vim.treesitter.get_parser = original_get_parser
    health.set_target_bufnr(nil)
    if original_bufnr and vim.api.nvim_buf_is_valid(original_bufnr) then
      vim.api.nvim_set_current_buf(original_bufnr)
    end
    if health_bufnr and vim.api.nvim_buf_is_valid(health_bufnr) then
      vim.api.nvim_buf_delete(health_bufnr, { force = true })
    end
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    restore_env()
  end)

  it('should report parser availability for the requested buffer filetype', function()
    vim.bo[bufnr].filetype = 'lua'
    vim.api.nvim_set_current_buf(health_bufnr)
    health.set_target_bufnr(bufnr)
    vim.treesitter.get_parser = function(target_bufnr)
      assert.equals(bufnr, target_bufnr)
      return {}
    end

    health.check()

    assert.is_true(
      contains_message(
        captured.ok,
        'Tree%-sitter parser is available for the requested buffer filetype: lua'
      )
    )
  end)

  it('should warn when parser is unavailable for the requested buffer filetype', function()
    vim.bo[bufnr].filetype = 'lua'
    vim.api.nvim_set_current_buf(health_bufnr)
    health.set_target_bufnr(bufnr)
    vim.treesitter.get_parser = function()
      error('parser not found')
    end

    health.check()

    assert.is_true(
      contains_message(
        captured.warn,
        'Tree%-sitter parser is not available for the requested buffer filetype: lua'
      )
    )
  end)

  it('should report info when the requested buffer has no filetype', function()
    vim.bo[bufnr].filetype = ''
    vim.api.nvim_set_current_buf(health_bufnr)
    health.set_target_bufnr(bufnr)
    vim.treesitter.get_parser = function()
      error('should not be called')
    end

    health.check()

    assert.is_true(
      contains_message(
        captured.info,
        'The requested buffer has no filetype; skipped parser validation'
      )
    )
  end)

  it('should report info when no requested buffer was provided', function()
    vim.api.nvim_set_current_buf(health_bufnr)
    vim.bo[health_bufnr].filetype = 'checkhealth'
    vim.treesitter.get_parser = function()
      error('should not be called')
    end

    health.check()

    assert.is_true(
      contains_message(
        captured.info,
        'Parser validation was skipped because no target buffer was provided'
      )
    )
  end)

  it('should report info when the requested buffer is not a normal file buffer', function()
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].filetype = 'lua'
    vim.api.nvim_set_current_buf(health_bufnr)
    health.set_target_bufnr(bufnr)
    vim.treesitter.get_parser = function()
      error('should not be called')
    end

    health.check()

    assert.is_true(
      contains_message(
        captured.info,
        'The requested buffer is not a normal file buffer %(buftype=nofile%); skipped parser validation'
      )
    )
  end)

  it('should warn when Tree-sitter API is unavailable', function()
    vim.treesitter = {}

    health.check()

    assert.is_true(
      contains_message(captured.warn, 'Tree%-sitter API is not available in this Neovim build')
    )
  end)

  it('should report missing api key for llm openai provider', function()
    config.setup({
      translate_service = 'llm',
      llm = {
        provider = 'openai',
        api_key = nil,
      },
    })
    set_env('OPENAI_API_KEY', nil)

    health.check()

    assert.is_true(contains_message(captured.error, 'LLM API key is missing'))
  end)

  it('should report ok when ollama provider is used without api key', function()
    config.setup({
      translate_service = 'llm',
      llm = {
        provider = 'ollama',
      },
    })

    health.check()

    assert.is_true(contains_message(captured.ok, 'not required for ollama'))
  end)

  it('should report ok when provider key exists in env', function()
    config.setup({
      translate_service = 'llm',
      llm = {
        provider = 'anthropic',
      },
    })
    set_env('ANTHROPIC_API_KEY', 'anthropic-env-key')

    health.check()

    assert.is_true(contains_message(captured.ok, '^LLM API key is configured$'))
  end)

  it('should treat whitespace api key as missing', function()
    config.setup({
      translate_service = 'llm',
      llm = {
        provider = 'openai',
        api_key = '   ',
      },
    })
    set_env('OPENAI_API_KEY', nil)

    health.check()

    assert.is_true(contains_message(captured.error, 'LLM API key is missing'))
  end)
end)
