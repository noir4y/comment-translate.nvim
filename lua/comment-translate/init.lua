local M = {}

local config
local commands
local parser
local translate
local ui
local autocmds

local function load_modules()
  if config then
    return true
  end

  local ok, err = pcall(function()
    config = require('comment-translate.config')
    commands = require('comment-translate.commands')
    parser = require('comment-translate.parser')
    translate = require('comment-translate.translate')
    ui = require('comment-translate.ui')
    autocmds = require('comment-translate.autocmds')
  end)

  if not ok then
    vim.notify(
      'comment-translate: Failed to load modules - ' .. tostring(err),
      vim.log.levels.ERROR
    )
    return false
  end

  return true
end

---@param user_config? table
function M.setup(user_config)
  if not load_modules() then
    return
  end

  config.setup(user_config)
  commands.setup()

  autocmds.setup_hover(config, parser, translate, ui)
  autocmds.setup_immersive(commands, ui)

  if config.config.immersive.enabled then
    commands.init_immersive_globally()
  end
end

return M
