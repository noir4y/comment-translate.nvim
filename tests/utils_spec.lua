---@diagnostic disable: undefined-global
describe('utils', function()
  local utils

  before_each(function()
    package.loaded['comment-translate.utils'] = nil
    utils = require('comment-translate.utils')
  end)

  describe('trim', function()
    it('should remove leading and trailing whitespace', function()
      assert.equals('hello', utils.trim('  hello  '))
      assert.equals('hello', utils.trim('\thello\t'))
      assert.equals('hello', utils.trim('\n  hello  \n'))
    end)

    it('should handle empty string', function()
      assert.equals('', utils.trim(''))
      assert.equals('', utils.trim('   '))
    end)

    it('should handle nil', function()
      assert.equals('', utils.trim(nil))
    end)

    it('should preserve internal whitespace', function()
      assert.equals('hello world', utils.trim('  hello world  '))
    end)
  end)

  describe('merge_lines', function()
    it('should merge lines with newline', function()
      local result = utils.merge_lines({ 'hello', 'world' })
      assert.equals('hello\nworld', result)
    end)

    it('should trim each line', function()
      local result = utils.merge_lines({ '  hello  ', '  world  ' })
      assert.equals('hello\nworld', result)
    end)

    it('should skip empty lines', function()
      local result = utils.merge_lines({ 'hello', '', '  ', 'world' })
      assert.equals('hello\nworld', result)
    end)

    it('should handle empty array', function()
      local result = utils.merge_lines({})
      assert.equals('', result)
    end)
  end)

  describe('is_empty', function()
    it('should return true for nil', function()
      assert.is_true(utils.is_empty(nil))
    end)

    it('should return true for empty string', function()
      assert.is_true(utils.is_empty(''))
    end)

    it('should return true for whitespace only', function()
      assert.is_true(utils.is_empty('   '))
      assert.is_true(utils.is_empty('\t\n'))
    end)

    it('should return false for non-empty string', function()
      assert.is_false(utils.is_empty('hello'))
      assert.is_false(utils.is_empty('  hello  '))
    end)
  end)

  describe('url_encode', function()
    it('should encode special characters', function()
      local result = utils.url_encode('hello world')
      assert.equals('hello%20world', result)
    end)

    it('should preserve alphanumeric characters', function()
      local result = utils.url_encode('abc123')
      assert.equals('abc123', result)
    end)

    it('should encode newlines as %0A', function()
      local result = utils.url_encode('hello\nworld')
      assert.equals('hello%0Aworld', result)
    end)

    it('should encode Japanese characters', function()
      local result = utils.url_encode('こんにちは')
      -- Japanese characters should be percent-encoded
      assert.is_not_nil(result:match('%%'))
    end)
  end)

  describe('normalize_lang_code', function()
    it('should lowercase language code', function()
      assert.equals('ja', utils.normalize_lang_code('JA'))
      assert.equals('en', utils.normalize_lang_code('EN'))
    end)

    it('should replace underscore with hyphen', function()
      assert.equals('zh-cn', utils.normalize_lang_code('zh_CN'))
      assert.equals('zh-tw', utils.normalize_lang_code('zh_TW'))
    end)
  end)

  describe('remove_comment_chars', function()
    it('should remove common comment characters', function()
      local result = utils.remove_comment_chars('// hello', { '//' })
      assert.equals('hello', result)
    end)

    it('should handle multiple comment styles', function()
      local result = utils.remove_comment_chars('# comment', { '//', '#', '--' })
      assert.equals('comment', result)
    end)

    it('should trim result', function()
      local result = utils.remove_comment_chars('//   hello   ', { '//' })
      assert.equals('hello', result)
    end)
  end)
end)
