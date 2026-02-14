---@diagnostic disable: undefined-global
describe('integration', function()
  describe('plugin setup', function()
    before_each(function()
      -- Reset all modules
      for name, _ in pairs(package.loaded) do
        if name:match('^comment%-translate') then
          package.loaded[name] = nil
        end
      end
    end)

    it('should setup without errors with default config', function()
      local plugin = require('comment-translate')

      assert.has_no.errors(function()
        plugin.setup()
      end)
    end)

    it('should setup with custom config', function()
      local plugin = require('comment-translate')

      assert.has_no.errors(function()
        plugin.setup({
          target_language = 'en',
          hover = {
            enabled = true,
            delay = 300,
            auto = false,
          },
          immersive = {
            enabled = false,
          },
          keymaps = {
            hover = false,
            hover_manual = '<C-k>',
            replace = false,
            toggle = false,
          },
        })
      end)
    end)

    it('should setup with auto hover disabled and register keymaps', function()
      local plugin = require('comment-translate')

      assert.has_no.errors(function()
        plugin.setup({
          hover = {
            enabled = true,
            auto = false,
          },
          keymaps = {
            hover = false,
            hover_manual = '<C-t>',
          },
        })
      end)
    end)

    it('should warn on unknown nested config keys', function()
      local notifications = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notifications, { msg = msg, level = level })
      end

      local plugin = require('comment-translate')
      plugin.setup({
        hover = {
          unknown_nested_key = true,
        },
      })

      vim.notify = original_notify

      local found_warning = false
      for _, n in ipairs(notifications) do
        if n.msg:match('unknown config key') then
          found_warning = true
          break
        end
      end
      assert.is_true(found_warning)
    end)
  end)

  describe('user commands', function()
    local bufnr

    before_each(function()
      -- Reset modules
      for name, _ in pairs(package.loaded) do
        if name:match('^comment%-translate') then
          package.loaded[name] = nil
        end
      end

      local plugin = require('comment-translate')
      plugin.setup({
        keymaps = {
          hover = false,
          hover_manual = false,
          replace = false,
          toggle = false,
        },
      })

      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        '-- This is a test comment',
        'local x = 1',
        '-- Another comment',
      })
    end)

    after_each(function()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it('should register CommentTranslateHover command', function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands['CommentTranslateHover'])
    end)

    it('should register CommentTranslateToggle command', function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands['CommentTranslateToggle'])
    end)

    it('should register CommentTranslateUpdate command', function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands['CommentTranslateUpdate'])
    end)

    it('should register CommentTranslateReplace command', function()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands['CommentTranslateReplace'])
    end)
  end)

  describe('plug mappings', function()
    before_each(function()
      for name, _ in pairs(package.loaded) do
        if name:match('^comment%-translate') then
          package.loaded[name] = nil
        end
      end

      local plugin = require('comment-translate')
      plugin.setup({
        keymaps = {
          hover = false,
          hover_manual = false,
          replace = false,
          toggle = false,
        },
      })
    end)

    it('should register <Plug>(comment-translate-hover)', function()
      local mappings = vim.api.nvim_get_keymap('n')
      local found = false
      for _, map in ipairs(mappings) do
        if map.lhs == '<Plug>(comment-translate-hover)' then
          found = true
          break
        end
      end
      assert.is_true(found)
    end)

    it('should register <Plug>(comment-translate-hover-manual)', function()
      local mappings = vim.api.nvim_get_keymap('n')
      local found = false
      for _, map in ipairs(mappings) do
        if map.lhs == '<Plug>(comment-translate-hover-manual)' then
          found = true
          break
        end
      end
      assert.is_true(found)
    end)

    it('should register <Plug>(comment-translate-toggle)', function()
      local mappings = vim.api.nvim_get_keymap('n')
      local found = false
      for _, map in ipairs(mappings) do
        if map.lhs == '<Plug>(comment-translate-toggle)' then
          found = true
          break
        end
      end
      assert.is_true(found)
    end)

    it('should register <Plug>(comment-translate-update)', function()
      local mappings = vim.api.nvim_get_keymap('n')
      local found = false
      for _, map in ipairs(mappings) do
        if map.lhs == '<Plug>(comment-translate-update)' then
          found = true
          break
        end
      end
      assert.is_true(found)
    end)
  end)

  describe('parser integration', function()
    local parser
    local config
    local bufnr

    before_each(function()
      for name, _ in pairs(package.loaded) do
        if name:match('^comment%-translate') then
          package.loaded[name] = nil
        end
      end

      config = require('comment-translate.config')
      config.setup({
        targets = {
          comment = true,
          string = true,
        },
      })

      parser = require('comment-translate.parser')
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(bufnr)
    end)

    after_each(function()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it('should get all comments from buffer', function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        '-- Comment 1',
        'local x = 1',
        '-- Comment 2',
        'local y = 2',
        '# Comment 3',
      })

      local comments = parser.get_all_comments(bufnr)

      -- Should find at least some comments
      local count = 0
      for _, _ in pairs(comments) do
        count = count + 1
      end
      assert.is_true(count > 0)
    end)

    it('should return empty table for buffer without comments', function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'local x = 1',
        'local y = 2',
      })

      local comments = parser.get_all_comments(bufnr)

      local count = 0
      for _, _ in pairs(comments) do
        count = count + 1
      end
      assert.equals(0, count)
    end)

    it('should get text at cursor', function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        '-- This is a comment',
      })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local text, _ = parser.get_text_at_cursor()

      assert.is_not_nil(text)
      assert.equals('This is a comment', text)
    end)
  end)

  describe('manual hover mode', function()
    local config

    before_each(function()
      for name, _ in pairs(package.loaded) do
        if name:match('^comment%-translate') then
          package.loaded[name] = nil
        end
      end

      config = require('comment-translate.config')
      config.setup({
        hover = {
          enabled = true,
          auto = false,
        },
        keymaps = {
          hover = false,
          hover_manual = '<C-t>',
        },
      })

      require('comment-translate.commands')
    end)

    it('should have auto hover disabled in config', function()
      assert.is_false(config.config.hover.auto)
    end)

    it('should have hover_manual keymap set', function()
      assert.equals('<C-t>', config.config.keymaps.hover_manual)
    end)
  end)

  describe('immersive mode state', function()
    local commands
    local bufnr

    before_each(function()
      for name, _ in pairs(package.loaded) do
        if name:match('^comment%-translate') then
          package.loaded[name] = nil
        end
      end

      local config = require('comment-translate.config')
      config.setup({
        immersive = {
          enabled = false,
        },
        keymaps = {
          hover = false,
          hover_manual = false,
          replace = false,
          toggle = false,
        },
      })

      commands = require('comment-translate.commands')
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(bufnr)
    end)

    after_each(function()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it('should track immersive state per buffer', function()
      local buf1 = vim.api.nvim_create_buf(false, true)
      local buf2 = vim.api.nvim_create_buf(false, true)

      assert.is_false(commands.is_immersive_enabled(buf1))
      assert.is_false(commands.is_immersive_enabled(buf2))

      vim.api.nvim_buf_delete(buf1, { force = true })
      vim.api.nvim_buf_delete(buf2, { force = true })
    end)

    it('should cleanup buffer state', function()
      assert.has_no.errors(function()
        commands.cleanup_buffer(bufnr)
      end)
    end)
  end)

  describe('immersive global auto-enable', function()
    local commands

    before_each(function()
      for name, _ in pairs(package.loaded) do
        if name:match('^comment%-translate') then
          package.loaded[name] = nil
        end
      end

      local config = require('comment-translate.config')
      config.setup({
        immersive = {
          enabled = false,
        },
        keymaps = {
          hover = false,
          hover_manual = false,
          replace = false,
          toggle = false,
        },
      })

      commands = require('comment-translate.commands')
    end)

    it('should have is_immersive_globally_enabled function', function()
      assert.is_function(commands.is_immersive_globally_enabled)
    end)

    it('should return false for global enabled by default', function()
      assert.is_false(commands.is_immersive_globally_enabled())
    end)

    it('should have enable_immersive function', function()
      assert.is_function(commands.enable_immersive)
    end)

    it('should have init_immersive_globally function', function()
      assert.is_function(commands.init_immersive_globally)
    end)

    it('should enable globally when init_immersive_globally is called', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(bufnr)

      assert.is_false(commands.is_immersive_globally_enabled())

      commands.init_immersive_globally()

      assert.is_true(commands.is_immersive_globally_enabled())
      assert.is_true(commands.is_immersive_enabled(bufnr))

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('should enable new buffers when globally enabled', function()
      local buf1 = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf1)

      -- Enable globally
      commands.init_immersive_globally()

      -- Create a new buffer
      local buf2 = vim.api.nvim_create_buf(false, true)

      -- buf2 is not enabled yet (needs BufEnter autocmd)
      assert.is_false(commands.is_immersive_enabled(buf2))

      -- Manually enable (simulating what BufEnter autocmd does)
      commands.enable_immersive(buf2)

      assert.is_true(commands.is_immersive_enabled(buf2))

      vim.api.nvim_buf_delete(buf1, { force = true })
      vim.api.nvim_buf_delete(buf2, { force = true })
    end)

    it('should toggle global state with toggle_immersive', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(bufnr)

      assert.is_false(commands.is_immersive_globally_enabled())

      commands.toggle_immersive()

      assert.is_true(commands.is_immersive_globally_enabled())

      commands.toggle_immersive()

      assert.is_false(commands.is_immersive_globally_enabled())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
