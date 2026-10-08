---@diagnostic disable: undefined-global
describe('plugin version guard', function()
  local original_has, original_error, original_create_command, original_loaded
  local supported, errors, commands

  before_each(function()
    original_has = vim.fn.has
    original_error = vim.api.nvim_err_writeln
    original_create_command = vim.api.nvim_create_user_command
    original_loaded = vim.g.loaded_comment_translate
    vim.g.loaded_comment_translate = nil
    supported, errors, commands = false, {}, {}
    vim.fn.has = function(feature)
      if feature == 'nvim-0.10' then
        return supported and 1 or 0
      end
      return original_has(feature)
    end
    vim.api.nvim_err_writeln = function(message)
      table.insert(errors, message)
    end
    vim.api.nvim_create_user_command = function(name)
      table.insert(commands, name)
    end
  end)

  after_each(function()
    vim.fn.has = original_has
    vim.api.nvim_err_writeln = original_error
    vim.api.nvim_create_user_command = original_create_command
    vim.g.loaded_comment_translate = original_loaded
  end)

  it('rejects versions below 0.10 before registering commands', function()
    dofile('plugin/comment-translate.lua')
    assert.same({ 'comment-translate.nvim requires Neovim 0.10 or later' }, errors)
    assert.equals(0, #commands)
    assert.is_nil(vim.g.loaded_comment_translate)
  end)

  it('registers lightweight entry commands once on 0.10 or later', function()
    supported = true
    dofile('plugin/comment-translate.lua')
    assert.same({ 'CommentTranslateSetup', 'CommentTranslateHealth' }, commands)
    assert.equals(0, #errors)
    assert.is_true(vim.g.loaded_comment_translate)
    dofile('plugin/comment-translate.lua')
    assert.equals(2, #commands)
  end)
end)
