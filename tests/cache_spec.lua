---@diagnostic disable: undefined-global
describe('cache', function()
  local cache
  local config

  before_each(function()
    -- Reset module cache
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.config'] = nil

    config = require('comment-translate.config')
    config.setup({
      cache = {
        enabled = true,
        max_entries = 5,
      },
    })

    cache = require('comment-translate.translate.cache')
    cache.clear()
  end)

  it('shares LRU capacity across isolated namespaces', function()
    for i = 1, 6 do
      cache.set('same input', 'result', 'ja', nil, cache.namespace({ 'llm', tostring(i) }))
    end
    assert.equals(5, cache.size())
    assert.is_nil(cache.get('same input', 'ja', nil, cache.namespace({ 'llm', '1' })))
    assert.equals('result', cache.get('same input', 'ja', nil, cache.namespace({ 'llm', '6' })))
    assert.is_not.equals(cache.namespace({ 'a|b', 'c' }), cache.namespace({ 'a', 'b|c' }))
  end)

  describe('set and get', function()
    it('should store and retrieve translations', function()
      cache.set('hello', 'こんにちは', 'ja')

      local result = cache.get('hello', 'ja')
      assert.equals('こんにちは', result)
    end)

    it('should return nil for non-existent entries', function()
      local result = cache.get('not-cached', 'ja')
      assert.is_nil(result)
    end)

    it('should handle source language', function()
      cache.set('hello', 'こんにちは', 'ja', 'en')

      local result = cache.get('hello', 'ja', 'en')
      assert.equals('こんにちは', result)

      -- Different source language should not match
      local other = cache.get('hello', 'ja', 'fr')
      assert.is_nil(other)
    end)

    it('should handle text containing pipe characters without collision', function()
      -- These texts would collide with the old delimiter-based key format
      cache.set('a|b|c', 'translated1', 'ja')
      cache.set('a', 'translated2', 'ja', 'b|c')

      -- Both should be stored separately without collision
      local result1 = cache.get('a|b|c', 'ja')
      local result2 = cache.get('a', 'ja', 'b|c')

      assert.equals('translated1', result1)
      assert.equals('translated2', result2)
    end)

    it('should handle text with special characters', function()
      local special_text = 'text|with|pipes\nand\nnewlines\ttabs'
      cache.set(special_text, 'translated', 'ja')

      local result = cache.get(special_text, 'ja')
      assert.equals('translated', result)
    end)

    it('should update existing entry', function()
      cache.set('hello', 'v1', 'ja')
      cache.set('hello', 'v2', 'ja')

      local result = cache.get('hello', 'ja')
      assert.equals('v2', result)
    end)
  end)

  describe('LRU eviction', function()
    it('should evict least recently used entry when at capacity', function()
      -- Fill cache to capacity (max_entries = 5)
      cache.set('a', '1', 'ja')
      cache.set('b', '2', 'ja')
      cache.set('c', '3', 'ja')
      cache.set('d', '4', 'ja')
      cache.set('e', '5', 'ja')

      assert.equals(5, cache.size())

      -- Add one more - should evict 'a'
      cache.set('f', '6', 'ja')

      assert.equals(5, cache.size())
      assert.is_nil(cache.get('a', 'ja'))
      assert.equals('6', cache.get('f', 'ja'))
    end)

    it('should update LRU order on get', function()
      cache.set('a', '1', 'ja')
      cache.set('b', '2', 'ja')
      cache.set('c', '3', 'ja')
      cache.set('d', '4', 'ja')
      cache.set('e', '5', 'ja')

      -- Access 'a' to make it recently used
      cache.get('a', 'ja')

      -- Add new entry - should evict 'b' (now least recently used)
      cache.set('f', '6', 'ja')

      assert.equals('1', cache.get('a', 'ja')) -- 'a' still exists
      assert.is_nil(cache.get('b', 'ja')) -- 'b' was evicted
    end)

    it('should update LRU order on set for existing key', function()
      cache.set('a', '1', 'ja')
      cache.set('b', '2', 'ja')
      cache.set('c', '3', 'ja')
      cache.set('d', '4', 'ja')
      cache.set('e', '5', 'ja')

      -- Update 'a' to make it recently used
      cache.set('a', 'updated', 'ja')

      -- Add new entry - should evict 'b'
      cache.set('f', '6', 'ja')

      assert.equals('updated', cache.get('a', 'ja'))
      assert.is_nil(cache.get('b', 'ja'))
    end)
  end)

  describe('clear', function()
    it('should remove all entries', function()
      cache.set('a', '1', 'ja')
      cache.set('b', '2', 'ja')

      cache.clear()

      assert.equals(0, cache.size())
      assert.is_nil(cache.get('a', 'ja'))
      assert.is_nil(cache.get('b', 'ja'))
    end)
  end)

  describe('size', function()
    it('should return current cache size', function()
      assert.equals(0, cache.size())

      cache.set('a', '1', 'ja')
      assert.equals(1, cache.size())

      cache.set('b', '2', 'ja')
      assert.equals(2, cache.size())
    end)

    it('should not expose cache keys or source text through stats', function()
      cache.set('secret source text', 'translated', 'ja')

      assert.is_nil(cache.stats)
    end)
  end)

  describe('disabled cache', function()
    it('should not store when cache is disabled', function()
      config.setup({
        cache = {
          enabled = false,
        },
      })

      cache.set('hello', 'こんにちは', 'ja')
      local result = cache.get('hello', 'ja')

      assert.is_nil(result)
    end)
  end)

  describe('max_entries edge cases', function()
    it('should handle max_entries = 0 without infinite loop', function()
      -- Config validation should correct this to 1
      config.setup({
        cache = {
          enabled = true,
          max_entries = 0,
        },
      })

      -- Should not hang or error
      assert.has_no.errors(function()
        cache.set('test', 'value', 'ja')
      end)
    end)

    it('should handle max_entries = -1 without infinite loop', function()
      config.setup({
        cache = {
          enabled = true,
          max_entries = -1,
        },
      })

      assert.has_no.errors(function()
        cache.set('test', 'value', 'ja')
      end)
    end)

    it('should work correctly with max_entries = 1', function()
      config.setup({
        cache = {
          enabled = true,
          max_entries = 1,
        },
      })

      cache.set('a', '1', 'ja')
      assert.equals('1', cache.get('a', 'ja'))

      cache.set('b', '2', 'ja')
      assert.equals('2', cache.get('b', 'ja'))
      assert.is_nil(cache.get('a', 'ja')) -- 'a' should be evicted
    end)
  end)
end)
