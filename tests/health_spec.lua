---@diagnostic disable: undefined-global
describe('health', function()
  local health
  local config
  local captured
  local original_health
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

  before_each(function()
    package.loaded['comment-translate.health'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate'] = nil
    package.loaded['plenary'] = true
    package.loaded['nvim-treesitter'] = true

    config = require('comment-translate.config')
    config.reset()
    health = require('comment-translate.health')

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
    restore_env()
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

    local found = false
    for _, msg in ipairs(captured.error) do
      if msg:match('LLM API key is missing') then
        found = true
        break
      end
    end
    assert.is_true(found)
  end)

  it('should report ok when ollama provider is used without api key', function()
    config.setup({
      translate_service = 'llm',
      llm = {
        provider = 'ollama',
      },
    })

    health.check()

    local found = false
    for _, msg in ipairs(captured.ok) do
      if msg:match('not required for ollama') then
        found = true
        break
      end
    end
    assert.is_true(found)
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

    local found = false
    for _, msg in ipairs(captured.ok) do
      if msg == 'LLM API key is configured' then
        found = true
        break
      end
    end
    assert.is_true(found)
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

    local found = false
    for _, msg in ipairs(captured.error) do
      if msg:match('LLM API key is missing') then
        found = true
        break
      end
    end
    assert.is_true(found)
  end)
end)
