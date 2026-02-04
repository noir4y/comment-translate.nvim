---@diagnostic disable: undefined-global
describe('parser', function()
  describe('regex', function()
    describe('get_comment_at_line', function()
      local regex
      local config
      local bufnr

      before_each(function()
        -- Reset all related modules before each test
        package.loaded['comment-translate.parser'] = nil
        package.loaded['comment-translate.parser.regex'] = nil
        package.loaded['comment-translate.parser.treesitter'] = nil
        package.loaded['comment-translate.utils'] = nil
        package.loaded['comment-translate.config'] = nil

        config = require('comment-translate.config')
        config.setup({
          targets = {
            comment = true,
            string = true,
          },
        })

        regex = require('comment-translate.parser.regex')
        bufnr = vim.api.nvim_create_buf(false, true)
      end)

      after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end)

      it('should detect // style comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '// This is a comment' })

        local result = regex.get_comment_at_line(bufnr, 0)
        assert.equals('This is a comment', result)
      end)

      it('should detect # style comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '# Python comment' })

        local result = regex.get_comment_at_line(bufnr, 0)
        assert.equals('Python comment', result)
      end)

      it('should detect -- style comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '-- Lua comment' })

        local result = regex.get_comment_at_line(bufnr, 0)
        assert.equals('Lua comment', result)
      end)

      it('should detect % style comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '% LaTeX comment' })

        local result = regex.get_comment_at_line(bufnr, 0)
        assert.equals('LaTeX comment', result)
      end)

      it('should detect /* */ style comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '/* C style comment */' })

        local result = regex.get_comment_at_line(bufnr, 0)
        assert.equals('C style comment', result)
      end)

      it('should return nil for non-comment lines', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local x = 1' })

        local result = regex.get_comment_at_line(bufnr, 0)
        assert.is_nil(result)
      end)

      it('should return nil when comment targets are disabled', function()
        -- Reload config with comment disabled
        package.loaded['comment-translate.config'] = nil
        package.loaded['comment-translate.parser.regex'] = nil

        config = require('comment-translate.config')
        config.setup({
          targets = {
            comment = false,
            string = true,
          },
        })
        regex = require('comment-translate.parser.regex')

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '// This is a comment' })

        local result = regex.get_comment_at_line(bufnr, 0)
        assert.is_nil(result)
      end)

      it('should handle leading whitespace', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '    // Indented comment' })

        local result = regex.get_comment_at_line(bufnr, 0)
        assert.equals('Indented comment', result)
      end)

      it('should detect inline # comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return a + b  # Return the result' })

        local result = regex.get_comment_at_line(bufnr, 0)
        assert.equals('Return the result', result)
      end)

      it('should detect inline // comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'int x = 5; // This is a value' })

        local result = regex.get_comment_at_line(bufnr, 0)
        assert.equals('This is a value', result)
      end)

      it('should detect inline -- comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local x = 1 -- Lua inline comment' })

        local result = regex.get_comment_at_line(bufnr, 0)
        assert.equals('Lua inline comment', result)
      end)
    end)

    describe('get_all_comments (multi-line block comments)', function()
      local regex
      local config
      local bufnr

      before_each(function()
        package.loaded['comment-translate.parser'] = nil
        package.loaded['comment-translate.parser.regex'] = nil
        package.loaded['comment-translate.parser.treesitter'] = nil
        package.loaded['comment-translate.utils'] = nil
        package.loaded['comment-translate.config'] = nil

        config = require('comment-translate.config')
        config.setup({
          targets = {
            comment = true,
            string = true,
          },
        })

        regex = require('comment-translate.parser.regex')
        bufnr = vim.api.nvim_create_buf(false, true)
      end)

      after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end)

      it('should detect multi-line C-style block comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
          '/*',
          ' * This is a multi-line',
          ' * block comment',
          ' */',
          'int x = 1;',
        })

        local comments = regex.get_all_comments(bufnr)
        assert.is_not_nil(comments[0])
        assert.is_truthy(comments[0]:find('This is a multi%-line'))
        assert.is_truthy(comments[0]:find('block comment'))
      end)

      it('should detect multi-line block comment with content on start line', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
          '/* Start of comment',
          '   More content here',
          '   End of comment */',
        })

        local comments = regex.get_all_comments(bufnr)
        -- Note: This is a single-line comment ending with */, so it won't be captured as multi-line
        -- The current implementation captures it as multi-line starting at line 0
        assert.is_not_nil(comments[0])
      end)

      it('should detect Lua multi-line block comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
          '--[[',
          'This is a Lua',
          'multi-line comment',
          ']]',
          'local x = 1',
        })

        local comments = regex.get_all_comments(bufnr)
        assert.is_not_nil(comments[0])
        assert.is_truthy(comments[0]:find('This is a Lua'))
        assert.is_truthy(comments[0]:find('multi%-line comment'))
      end)

      it('should detect HTML multi-line comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
          '<!--',
          '  HTML multi-line',
          '  comment here',
          '-->',
          '<div></div>',
        })

        local comments = regex.get_all_comments(bufnr)
        assert.is_not_nil(comments[0])
        assert.is_truthy(comments[0]:find('HTML multi%-line'))
      end)

      it('should detect single-line comments alongside block comments', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
          '// Single line comment',
          '/*',
          ' * Block comment',
          ' */',
          '// Another single line',
        })

        local comments = regex.get_all_comments(bufnr)
        assert.is_not_nil(comments[0])
        assert.equals('Single line comment', comments[0])
        assert.is_not_nil(comments[1])
        assert.is_truthy(comments[1]:find('Block comment'))
        assert.is_not_nil(comments[4])
        assert.equals('Another single line', comments[4])
      end)

      it('should return empty table when comments disabled', function()
        package.loaded['comment-translate.config'] = nil
        package.loaded['comment-translate.parser.regex'] = nil

        config = require('comment-translate.config')
        config.setup({
          targets = {
            comment = false,
            string = true,
          },
        })
        regex = require('comment-translate.parser.regex')

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
          '/* Block comment */',
          '// Line comment',
        })

        local comments = regex.get_all_comments(bufnr)
        local count = 0
        for _ in pairs(comments) do
          count = count + 1
        end
        assert.equals(0, count)
      end)
    end)

    describe('get_string_at_position', function()
      local regex
      local config
      local bufnr

      before_each(function()
        package.loaded['comment-translate.parser'] = nil
        package.loaded['comment-translate.parser.regex'] = nil
        package.loaded['comment-translate.parser.treesitter'] = nil
        package.loaded['comment-translate.utils'] = nil
        package.loaded['comment-translate.config'] = nil

        config = require('comment-translate.config')
        config.setup({
          targets = {
            comment = true,
            string = true,
          },
        })

        regex = require('comment-translate.parser.regex')
        bufnr = vim.api.nvim_create_buf(false, true)
      end)

      after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end)

      it('should detect double-quoted strings', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local x = "hello world"' })

        -- Column 11 is inside the string (0-based)
        local result = regex.get_string_at_position(bufnr, 0, 11)
        assert.equals('hello world', result)
      end)

      it('should detect single-quoted strings', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x = 'hello world'" })

        local result = regex.get_string_at_position(bufnr, 0, 11)
        assert.equals('hello world', result)
      end)

      it('should detect backtick strings', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'const x = `template string`' })

        local result = regex.get_string_at_position(bufnr, 0, 12)
        assert.equals('template string', result)
      end)

      it('should return nil when cursor is outside string', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local x = "hello"' })

        -- Column 0 is outside the string
        local result = regex.get_string_at_position(bufnr, 0, 0)
        assert.is_nil(result)
      end)

      it('should return nil when string targets are disabled', function()
        package.loaded['comment-translate.config'] = nil
        package.loaded['comment-translate.parser.regex'] = nil

        config = require('comment-translate.config')
        config.setup({
          targets = {
            comment = true,
            string = false,
          },
        })
        regex = require('comment-translate.parser.regex')

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local x = "hello"' })

        local result = regex.get_string_at_position(bufnr, 0, 11)
        assert.is_nil(result)
      end)

      it('should handle multiple strings on same line', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local a = "first" local b = "second"' })

        -- Column in first string
        local result1 = regex.get_string_at_position(bufnr, 0, 12)
        assert.equals('first', result1)

        -- Column in second string
        local result2 = regex.get_string_at_position(bufnr, 0, 30)
        assert.equals('second', result2)
      end)
    end)
  end)

  describe('utils', function()
    local utils

    before_each(function()
      package.loaded['comment-translate.utils'] = nil
      utils = require('comment-translate.utils')
    end)

    it('should remove comment characters correctly', function()
      local result = utils.remove_comment_chars('// hello world', { '//', '#', '--' })
      assert.equals('hello world', result)
    end)

    it('should handle multiple comment styles', function()
      local result1 = utils.remove_comment_chars('# Python', { '//', '#', '--' })
      assert.equals('Python', result1)

      local result2 = utils.remove_comment_chars('-- Lua', { '//', '#', '--' })
      assert.equals('Lua', result2)
    end)

    it('should merge multiple lines with newlines', function()
      local lines = { '  first line  ', '  second line  ', '', '  third line  ' }
      local result = utils.merge_lines(lines)
      assert.equals('first line\nsecond line\nthird line', result)
    end)
  end)
end)
