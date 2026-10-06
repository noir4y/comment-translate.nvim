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

      it('should not detect an inline comment when cursor is before it', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local x = 1 -- Lua inline comment' })

        local result = regex.get_comment_at_line(bufnr, 0, 2)
        assert.is_nil(result)
      end)

      it('should detect an inline comment when cursor is inside it', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local x = 1 -- Lua inline comment' })

        local result = regex.get_comment_at_line(bufnr, 0, 15)
        assert.equals('Lua inline comment', result)
      end)

      it('should not detect an inline block comment when cursor is after it', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'x /* note */ "bar"' })

        local result = regex.get_comment_at_line(bufnr, 0, 14)
        assert.is_nil(result)
      end)

      it('should detect the inline block comment containing the cursor', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'x /* first */ y /* second */' })

        local result = regex.get_comment_at_line(bufnr, 0, 21)
        assert.equals('second', result)
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

      it('should detect strings with escaped delimiters', function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local x = "hello \\"quoted\\" world"' })

        local result = regex.get_string_at_position(bufnr, 0, 20)
        assert.equals('hello \\"quoted\\" world', result)
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

  describe('injection range lookup work', function()
    local treesitter, bufnr, original_get_parser, original_pairs, original_ipairs

    local function node(kind, range, children)
      children = children or {}
      return {
        type = function()
          return kind
        end,
        range = function()
          return unpack(range)
        end,
        start = function()
          return range[1], range[2]
        end,
        parent = function() end,
        iter_children = function()
          local index = 0
          return function()
            index = index + 1
            return children[index]
          end
        end,
        named_descendant_for_range = function(_, row)
          return children[row - range[1] + 1]
        end,
      }
    end

    local function model(opaque, regions, six_fields, reverse)
      local nodes, trees, included, keys = {}, {}, {}, {}
      local height = 1
      for _, range in ipairs(opaque) do
        table.insert(nodes, node('code_fence_content', range))
        height = math.max(height, range[3] + 1)
      end
      for index, ranges in ipairs(regions) do
        local key = index * 3 -- Region keys need not be dense or match pairs order.
        local root = node('program', ranges[1])
        trees[key] = {
          root = function()
            return root
          end,
        }
        included[key] = {}
        table.insert(keys, key)
        for _, range in ipairs(ranges) do
          height = math.max(height, range[3] + 1)
          table.insert(included[key], six_fields and {
            range[1],
            range[2],
            range[1] * 17 + range[2],
            range[3],
            range[4],
            range[3] * 17 + range[4],
          } or range)
        end
      end
      local lines = {}
      for _ = 1, height do
        table.insert(lines, 'abcdefghijklmnop')
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      local child = {
        trees = function()
          return trees
        end,
        included_regions = function()
          return included
        end,
        children = function()
          return {}
        end,
      }
      local root = node('program', { 0, 0, height - 1, 16 }, nodes)
      local tree = {
        root = function()
          return root
        end,
      }
      local host = {
        parse = function(_, all)
          assert.is_true(all)
          return { tree }
        end,
        trees = function()
          return { tree }
        end,
        included_regions = function()
          return { {} }
        end,
        tree_for_range = function()
          return tree
        end,
        children = function()
          return { lua = child }
        end,
      }
      vim.treesitter.get_parser = function()
        return host
      end
      _G.pairs = function(value)
        if value ~= trees then
          return original_pairs(value)
        end
        local index = reverse and #keys + 1 or 0
        return function()
          index = index + (reverse and -1 or 1)
          local key = keys[index]
          if key then
            return key, trees[key]
          end
        end
      end
      return included, child
    end

    local function work(iterator, callback)
      local original, count = _G[iterator], 0
      _G[iterator] = function(value)
        local next_item, state, key = original(value)
        return function(_, previous)
          local index, item = next_item(state, previous)
          if index ~= nil then
            count = count + 1
          end
          return index, item
        end,
          state,
          key
      end
      local ok, err = pcall(callback)
      _G[iterator] = original
      if not ok then
        error(err)
      end
      return count
    end

    before_each(function()
      package.loaded['comment-translate.parser.treesitter'] = nil
      require('comment-translate.config').setup({ targets = { comment = true, string = true } })
      treesitter = require('comment-translate.parser.treesitter')
      original_get_parser = vim.treesitter.get_parser
      original_pairs, original_ipairs = pairs, ipairs
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'abcdefghijklmnop' })
    end)

    after_each(function()
      vim.treesitter.get_parser = original_get_parser
      _G.pairs, _G.ipairs = original_pairs, original_ipairs
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    for _, reverse in ipairs({ false, true }) do
      for _, position in ipairs({ 'late tree', 'outside all trees' }) do
        it(
          'keeps cursor lookup linear: ' .. position .. ', reverse=' .. tostring(reverse),
          function()
            local counts = {}
            for _, size in ipairs({ 64, 256 }) do
              local opaque, regions = {}, {}
              for row = 0, size - 1 do
                local range = { row, 0, row, 16 }
                table.insert(opaque, range)
                table.insert(regions, { range })
              end
              model(opaque, regions, false, reverse)
              local row = position == 'outside all trees' and size or (reverse and 0 or size - 1)
              counts[size] = work('pairs', function()
                local text, _, handled = treesitter.get_text_at_position(bufnr, row, 2)
                assert.is_nil(text)
                assert.is_true(handled)
              end)
            end
            -- Four times as many trees must not cause quadratic identity searches.
            assert.is_true(counts[256] <= counts[64] * 6)
          end
        )
      end
    end

    for _, profile in ipairs({ 'separate', 'combined', 'unparsed', 'mixed', 'fragmented' }) do
      it('avoids quadratic coverage scans: ' .. profile, function()
        local counts = {}
        for _, size in ipairs({ 64, 256 }) do
          local opaque, regions, expected = {}, profile == 'combined' and { {} } or {}, {}
          for row = 0, size - 1 do
            local range = { row, 0, row, 16 }
            if profile == 'fragmented' then
              table.insert(regions, { { row, 4, row, 12 } })
              table.insert(expected, { row == 0 and 0 or row - 1, row == 0 and 0 or 12, row, 4 })
            elseif profile == 'unparsed' or (profile == 'mixed' and row % 2 == 1) then
              table.insert(expected, range)
            elseif profile == 'combined' then
              table.insert(regions[1], range)
            else
              table.insert(regions, { range })
            end
            table.insert(opaque, range)
          end
          if profile == 'fragmented' then
            opaque = { { 0, 0, size - 1, 16 } }
            table.insert(expected, { size - 1, 12, size - 1, 16 })
          end
          model(opaque, regions, false, true)
          counts[size] = work('ipairs', function()
            local comments, handled, fallback = treesitter.get_all_comments(bufnr)
            assert.same({}, comments)
            assert.is_true(handled)
            assert.same(expected, fallback)
          end)
        end
        assert.is_true(counts[256] <= counts[64] * 6)
      end)
    end

    for _, profile in ipairs({ 'separate', 'combined parent', 'combined leaf' }) do
      for _, reverse in ipairs({ false, true }) do
        it(
          'keeps nested ownership and ancestor lookup scalable: '
            .. profile
            .. ', reverse='
            .. tostring(reverse),
          function()
            local counts, cursor_counts = {}, {}
            for _, size in ipairs({ 64, 256 }) do
              local opaque, regions, nested_trees, nested_regions = {}, {}, {}, {}
              local leaf_nodes = {}
              if profile ~= 'separate' then
                regions[1] = {}
              end
              for row = 0, size - 1 do
                local range = { row, 0, row, 16 }
                table.insert(opaque, range)
                if profile ~= 'separate' then
                  table.insert(regions[1], range)
                else
                  table.insert(regions, { range })
                end
                local comment = node('comment', range)
                table.insert(leaf_nodes, comment)
                local root = node('program', range, { comment })
                nested_trees[(row + 1) * 7] = {
                  root = function()
                    return root
                  end,
                }
                nested_regions[(row + 1) * 7] = { range }
              end
              if profile == 'combined leaf' then
                local root = node('program', { 0, 0, size - 1, 16 }, leaf_nodes)
                nested_trees = {
                  [7] = {
                    root = function()
                      return root
                    end,
                  },
                }
                nested_regions = { [7] = regions[1] }
              end
              local _, parent = model(opaque, regions, true, reverse)
              parent.children = function()
                return {
                  javascript = {
                    trees = function()
                      return nested_trees
                    end,
                    included_regions = function()
                      return nested_regions
                    end,
                    children = function()
                      return {}
                    end,
                  },
                }
              end
              counts[size] = work('ipairs', function()
                local comments, handled, fallback = treesitter.get_all_comments(bufnr)
                assert.is_true(handled)
                assert.equals(size, vim.tbl_count(comments))
                for row = 0, size - 1 do
                  assert.is_true(comments[row] == 'abcdefghijklmnop')
                end
                assert.same({}, fallback)
              end)
              cursor_counts[size] = work('ipairs', function()
                local text, _, handled = treesitter.get_text_at_position(bufnr, size - 1, 2)
                assert.is_true(handled)
                assert.is_true(text == 'abcdefghijklmnop')
              end)
            end
            -- Includes parent ownership clipping and per-comment ancestor search.
            assert.is_true(counts[256] <= counts[64] * 6)
            assert.is_true(cursor_counts[256] <= cursor_counts[64] * 6)
          end
        )
      end
    end

    for _, six_fields in ipairs({ false, true }) do
      it(
        'subtracts overlapping coverage without changing its metadata: six=' .. tostring(six_fields),
        function()
          local included = model({
            { 0, 0, 0, 16 },
            { 1, 0, 1, 16 },
            { 2, 0, 2, 16 },
          }, {
            { { 0, 9, 0, 12 }, { 0, 5, 0, 9 }, { 0, 2, 0, 6 } },
            { { 1, 0, 1, 16 } },
            { { 2, 16, 3, 0 } },
          }, six_fields, true)
          local snapshot = vim.deepcopy(included)
          local _, handled, fallback = treesitter.get_all_comments(bufnr)
          assert.is_true(handled)
          assert.same({ { 0, 0, 0, 2 }, { 0, 12, 0, 16 }, { 2, 0, 2, 16 } }, fallback)
          assert.same(snapshot, included)
        end
      )
    end

    it('refreshes region metadata on the next request', function()
      local included = model({ { 0, 0, 0, 16 }, { 1, 0, 1, 16 } }, { { { 0, 0, 0, 16 } } })
      local _, _, fallback = treesitter.get_all_comments(bufnr)
      assert.same({ { 1, 0, 1, 16 } }, fallback)
      local _, _, handled, fragment = treesitter.get_text_at_position(bufnr, 0, 2)
      assert.is_true(handled)
      assert.is_nil(fragment)
      included[3] = { { 1, 0, 1, 16 } }
      _, _, fallback = treesitter.get_all_comments(bufnr)
      assert.same({ { 0, 0, 0, 16 } }, fallback)
      _, _, handled, fragment = treesitter.get_text_at_position(bufnr, 0, 2)
      assert.is_false(handled)
      assert.same({ 0, 0, 0, 16 }, fragment)
    end)
  end)

  describe('fallback get_text_at_cursor', function()
    local parser
    local config
    local bufnr
    local original_get_parser

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

      original_get_parser = vim.treesitter.get_parser
      vim.treesitter.get_parser = function()
        error('parser unavailable')
      end

      parser = require('comment-translate.parser')
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(bufnr)
    end)

    after_each(function()
      vim.treesitter.get_parser = original_get_parser
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it('should not translate an inline comment when cursor is before the comment', function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local x = 1 -- inline comment' })
      vim.api.nvim_win_set_cursor(0, { 1, 2 })

      local text, node_type = parser.get_text_at_cursor(bufnr)

      assert.is_nil(text)
      assert.is_nil(node_type)
    end)

    it('should translate a string before an inline comment when cursor is in the string', function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local x = "hello" -- inline comment' })
      vim.api.nvim_win_set_cursor(0, { 1, 12 })

      local text, node_type = parser.get_text_at_cursor(bufnr)

      assert.equals('hello', text)
      assert.equals('string', node_type)
    end)

    it(
      'should translate a string after an inline block comment when cursor is in the string',
      function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'x /* note */ "bar"' })
        vim.api.nvim_win_set_cursor(0, { 1, 14 })

        local text, node_type = parser.get_text_at_cursor(bufnr)

        assert.equals('bar', text)
        assert.equals('string', node_type)
      end
    )
  end)
end)
