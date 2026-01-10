if vim.g.loaded_comment_translate then
  return
end

if vim.fn.has('nvim-0.8') == 0 then
  vim.api.nvim_err_writeln('comment-translate.nvim requires Neovim 0.8 or later')
  return
end

vim.g.loaded_comment_translate = true

vim.api.nvim_create_user_command('CommentTranslateSetup', function()
  local ok, err = pcall(function()
    require('comment-translate').setup({})
  end)
  if not ok then
    vim.notify('comment-translate.nvim: Setup failed - ' .. tostring(err), vim.log.levels.ERROR)
  end
end, {
  desc = 'Setup comment-translate.nvim with default settings',
  force = true,
})

vim.api.nvim_create_user_command('CommentTranslateHealth', function()
  vim.cmd('checkhealth comment-translate')
end, {
  desc = 'Check comment-translate.nvim health (alias for :checkhealth comment-translate)',
  force = true,
})
