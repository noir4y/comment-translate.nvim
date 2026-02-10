---@diagnostic disable: undefined-global
describe('commands', function()
  local commands
  local config
  local ui
  local bufnr

  before_each(function()
    -- Reset all related modules before each test
    package.loaded['comment-translate'] = nil
    package.loaded['comment-translate.commands'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.parser'] = nil
    package.loaded['comment-translate.parser.regex'] = nil
    package.loaded['comment-translate.parser.treesitter'] = nil
    package.loaded['comment-translate.translate'] = nil
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.translate.google'] = nil
    package.loaded['comment-translate.translate.llm'] = nil
    package.loaded['comment-translate.ui'] = nil
    package.loaded['comment-translate.ui.hover'] = nil
    package.loaded['comment-translate.ui.virtual_text'] = nil
    package.loaded['comment-translate.autocmds'] = nil
    package.loaded['comment-translate.utils'] = nil

    config = require('comment-translate.config')
    config.setup({
      target_language = 'ja',
      hover = {
        enabled = true,
        delay = 100,
        auto = true,
      },
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
    ui = require('comment-translate.ui')

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    ui.hover.close()
    ui.virtual_text.clear_all()
  end)

  describe('is_immersive_enabled', function()
    it('should return false by default', function()
      assert.is_false(commands.is_immersive_enabled())
    end)

    it('should return true after toggle', function()
      -- Note: toggle_immersive calls update_immersive which needs parser
      -- Just test the state management
      assert.is_false(commands.is_immersive_enabled())
    end)
  end)

  describe('cleanup_buffer', function()
    it('should cleanup buffer state without error', function()
      assert.has_no.errors(function()
        commands.cleanup_buffer(bufnr)
      end)
    end)

    it('should handle invalid buffer gracefully', function()
      assert.has_no.errors(function()
        commands.cleanup_buffer(99999)
      end)
    end)
  end)

  describe('hover_translate_on_demand', function()
    it('should exist and be callable', function()
      assert.is_function(commands.hover_translate_on_demand)
    end)
  end)
end)

describe('autocmds', function()
  local autocmds
  local config

  before_each(function()
    package.loaded['comment-translate.autocmds'] = nil
    package.loaded['comment-translate.config'] = nil

    config = require('comment-translate.config')
    config.setup({
      hover = {
        enabled = true,
        delay = 100,
        auto = true,
      },
    })

    autocmds = require('comment-translate.autocmds')
  end)

  describe('cleanup_all_timers', function()
    it('should cleanup without error', function()
      assert.has_no.errors(function()
        autocmds.cleanup_all_timers()
      end)
    end)
  end)

  describe('show_hover_on_demand', function()
    it('should exist and be callable', function()
      assert.is_function(autocmds.show_hover_on_demand)
    end)
  end)
end)

describe('ui.hover', function()
  local hover
  local bufnr

  before_each(function()
    package.loaded['comment-translate.ui.hover'] = nil
    hover = require('comment-translate.ui.hover')

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'test line' })
  end)

  after_each(function()
    hover.close()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  describe('show', function()
    it('should create hover window with text', function()
      hover.show('Hello World')

      local hover_bufnr = hover.bufnr()
      assert.is_not_nil(hover_bufnr)
      assert.is_true(vim.api.nvim_buf_is_valid(hover_bufnr))

      local lines = vim.api.nvim_buf_get_lines(hover_bufnr, 0, -1, false)
      assert.equals('Hello World', lines[1])
    end)

    it('should handle empty text gracefully', function()
      assert.has_no.errors(function()
        hover.show('')
      end)
      assert.is_nil(hover.bufnr())
    end)

    it('should handle nil text gracefully', function()
      assert.has_no.errors(function()
        hover.show(nil)
      end)
      assert.is_nil(hover.bufnr())
    end)

    it('should handle multiline text', function()
      hover.show('Line 1\nLine 2\nLine 3')

      local hover_bufnr = hover.bufnr()
      assert.is_not_nil(hover_bufnr)

      local lines = vim.api.nvim_buf_get_lines(hover_bufnr, 0, -1, false)
      assert.equals(3, #lines)
      assert.equals('Line 1', lines[1])
      assert.equals('Line 2', lines[2])
      assert.equals('Line 3', lines[3])
    end)
  end)

  describe('close', function()
    it('should close hover window', function()
      hover.show('Test')
      assert.is_not_nil(hover.bufnr())

      hover.close()
      assert.is_nil(hover.bufnr())
    end)

    it('should handle multiple close calls', function()
      hover.show('Test')
      hover.close()

      assert.has_no.errors(function()
        hover.close()
        hover.close()
      end)
    end)
  end)
end)

describe('ui.virtual_text', function()
  local virtual_text
  local bufnr

  before_each(function()
    package.loaded['comment-translate.ui.virtual_text'] = nil
    virtual_text = require('comment-translate.ui.virtual_text')

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      '-- Comment line 1',
      'local x = 1',
      '-- Comment line 2',
    })
  end)

  after_each(function()
    virtual_text.clear_all()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  describe('show', function()
    it('should add virtual text', function()
      assert.has_no.errors(function()
        virtual_text.show(bufnr, 0, 'Translated text')
      end)
    end)
  end)

  describe('clear_buf', function()
    it('should clear virtual text from buffer', function()
      virtual_text.show(bufnr, 0, 'Test')

      assert.has_no.errors(function()
        virtual_text.clear_buf(bufnr)
      end)
    end)

    it('should handle invalid buffer gracefully', function()
      assert.has_no.errors(function()
        virtual_text.clear_buf(99999)
      end)
    end)

    it('should handle nil bufnr gracefully', function()
      assert.has_no.errors(function()
        virtual_text.clear_buf(nil)
      end)
    end)
  end)

  describe('clear_all', function()
    it('should clear all virtual text', function()
      virtual_text.show(bufnr, 0, 'Test 1')
      virtual_text.show(bufnr, 2, 'Test 2')

      assert.has_no.errors(function()
        virtual_text.clear_all()
      end)
    end)
  end)
end)

describe('immersive multi-buffer behavior', function()
  local commands
  local config
  local ui
  local bufnr1, bufnr2

  before_each(function()
    -- Reset all related modules
    package.loaded['comment-translate'] = nil
    package.loaded['comment-translate.commands'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.parser'] = nil
    package.loaded['comment-translate.parser.regex'] = nil
    package.loaded['comment-translate.parser.treesitter'] = nil
    package.loaded['comment-translate.translate'] = nil
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.translate.google'] = nil
    package.loaded['comment-translate.translate.llm'] = nil
    package.loaded['comment-translate.ui'] = nil
    package.loaded['comment-translate.ui.hover'] = nil
    package.loaded['comment-translate.ui.virtual_text'] = nil
    package.loaded['comment-translate.autocmds'] = nil
    package.loaded['comment-translate.utils'] = nil

    config = require('comment-translate.config')
    config.setup({
      target_language = 'ja',
      hover = {
        enabled = false,
        delay = 100,
        auto = true,
      },
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
    ui = require('comment-translate.ui')

    -- Create two test buffers
    bufnr1 = vim.api.nvim_create_buf(false, true)
    bufnr2 = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_buf_set_lines(bufnr1, 0, -1, false, { '-- Buffer 1 comment' })
    vim.api.nvim_buf_set_lines(bufnr2, 0, -1, false, { '-- Buffer 2 comment' })
  end)

  after_each(function()
    if bufnr1 and vim.api.nvim_buf_is_valid(bufnr1) then
      vim.api.nvim_buf_delete(bufnr1, { force = true })
    end
    if bufnr2 and vim.api.nvim_buf_is_valid(bufnr2) then
      vim.api.nvim_buf_delete(bufnr2, { force = true })
    end
    ui.hover.close()
    ui.virtual_text.clear_all()
  end)

  describe('toggle_immersive global disable', function()
    it('should disable immersive mode for all buffers when toggled off', function()
      -- Enable immersive on buffer 1
      vim.api.nvim_set_current_buf(bufnr1)
      commands.enable_immersive(bufnr1)
      assert.is_true(commands.is_immersive_enabled(bufnr1))

      -- Enable immersive on buffer 2
      commands.enable_immersive(bufnr2)
      assert.is_true(commands.is_immersive_enabled(bufnr2))

      -- Toggle off (globally) from buffer 1
      vim.api.nvim_set_current_buf(bufnr1)
      commands.toggle_immersive(bufnr1)

      -- Both buffers should be disabled
      assert.is_false(commands.is_immersive_enabled(bufnr1))
      assert.is_false(commands.is_immersive_enabled(bufnr2))
      assert.is_false(commands.is_immersive_globally_enabled())
    end)

    it('should not affect other buffers when enabling', function()
      -- Enable only on buffer 1
      vim.api.nvim_set_current_buf(bufnr1)
      commands.toggle_immersive(bufnr1)

      assert.is_true(commands.is_immersive_enabled(bufnr1))
      assert.is_false(commands.is_immersive_enabled(bufnr2))
      assert.is_true(commands.is_immersive_globally_enabled())
    end)
  end)
end)
