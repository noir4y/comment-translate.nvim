---@diagnostic disable: undefined-global
describe('config', function()
  local config

  before_each(function()
    -- Reset module cache
    package.loaded['comment-translate.config'] = nil
    config = require('comment-translate.config')
    config.reset()
  end)

  describe('setup', function()
    it('should use default values when no config provided', function()
      config.setup()

      assert.is_not_nil(config.config)
      assert.equals('google', config.config.translate_service)
      assert.is_true(config.config.hover.enabled)
      assert.equals(500, config.config.hover.delay)
      assert.is_false(config.config.immersive.enabled)
      assert.is_true(config.config.cache.enabled)
      assert.equals(1000, config.config.cache.max_entries)
      assert.equals('openai', config.config.llm.provider)
      assert.is_nil(config.config.llm.api_key)
      assert.equals('gpt-5.2', config.config.llm.model)
      assert.is_nil(config.config.llm.endpoint)
      assert.equals(20, config.config.llm.timeout)
    end)

    it('should merge user config with defaults', function()
      config.setup({
        target_language = 'ja',
        translate_service = 'google',
        hover = {
          delay = 1000,
        },
        llm = {
          provider = 'anthropic',
          model = 'claude-sonnet-4-0',
        },
      })

      assert.equals('ja', config.config.target_language)
      assert.equals(1000, config.config.hover.delay)
      assert.equals('anthropic', config.config.llm.provider)
      assert.equals('claude-sonnet-4-0', config.config.llm.model)
      -- Default values should be preserved
      assert.is_true(config.config.hover.enabled)
      assert.is_true(config.config.hover.auto)
      assert.equals(20, config.config.llm.timeout)
    end)

    it('should handle nested config correctly', function()
      config.setup({
        immersive = {
          enabled = true,
        },
      })

      assert.is_true(config.config.immersive.enabled)
    end)

    it('should handle empty config', function()
      config.setup({})

      assert.is_not_nil(config.config)
      assert.is_not_nil(config.config.hover)
      assert.is_not_nil(config.config.immersive)
    end)

    it('should fallback unsupported translate_service to google', function()
      config.setup({
        translate_service = 'invalid-service',
      })

      assert.equals('google', config.config.translate_service)
    end)

    it('should fallback unsupported llm.provider to openai', function()
      config.setup({
        llm = {
          provider = 'invalid-provider',
        },
      })

      assert.equals('openai', config.config.llm.provider)
    end)
  end)

  describe('get', function()
    it('should return current config', function()
      config.setup({ target_language = 'fr' })

      local current = config.get()
      assert.equals('fr', current.target_language)
    end)
  end)

  describe('reset', function()
    it('should reset to default config', function()
      config.setup({ target_language = 'zh' })
      config.reset()

      -- Should be back to default (system locale or 'en')
      assert.is_not_nil(config.config.target_language)
      assert.equals('google', config.config.translate_service)
    end)
  end)
end)
