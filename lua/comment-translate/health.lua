---@brief Health check for comment-translate.nvim
---Run with :checkhealth comment-translate

local M = {}
local utils = require('comment-translate.utils')

---@param module_name string
---@return boolean
local function check_module(module_name)
  local ok, _ = pcall(require, module_name)
  return ok
end

---@return string
local function get_nvim_version()
  local v = vim.version()
  return string.format('%d.%d.%d', v.major, v.minor, v.patch)
end

function M.check()
  vim.health.start('comment-translate.nvim')

  vim.health.info('Neovim version: ' .. get_nvim_version())

  if vim.fn.has('nvim-0.8') == 1 then
    vim.health.ok('Neovim version is 0.8 or later')
  else
    vim.health.error('Neovim 0.8+ is required', {
      'Upgrade Neovim to version 0.8 or later',
    })
  end

  -- plenary.nvim (required)
  if check_module('plenary') then
    vim.health.ok('plenary.nvim is installed')
  else
    vim.health.error('plenary.nvim is required but not found', {
      'Install plenary.nvim: https://github.com/nvim-lua/plenary.nvim',
    })
  end

  -- nvim-treesitter (recommended)
  if check_module('nvim-treesitter') then
    vim.health.ok('nvim-treesitter is installed')
  else
    vim.health.warn('nvim-treesitter is not installed (recommended for accurate parsing)', {
      'Install nvim-treesitter: https://github.com/nvim-treesitter/nvim-treesitter',
      'Without treesitter, regex-based parsing will be used as fallback',
    })
  end

  if vim.fn.executable('curl') == 1 then
    vim.health.ok('curl is installed')
  else
    vim.health.error('curl is not installed (required for translation API)', {
      'Install curl using your package manager',
    })
  end

  if check_module('comment-translate') then
    vim.health.ok('comment-translate is loaded')

    local config = require('comment-translate.config')
    if config.config then
      vim.health.ok('Plugin is configured')
      vim.health.info('Target language: ' .. (config.config.target_language or 'not set'))
      vim.health.info('Translate service: ' .. (config.config.translate_service or 'not set'))

      if config.config.translate_service == 'llm' then
        local provider = (config.config.llm and config.config.llm.provider) or 'openai'
        vim.health.info('LLM provider: ' .. provider)

        if provider == 'ollama' then
          vim.health.ok('LLM API key is not required for ollama provider')
        else
          local env_keys = {
            openai = { 'OPENAI_API_KEY' },
            anthropic = { 'ANTHROPIC_API_KEY' },
            gemini = { 'GEMINI_API_KEY' },
          }
          local configured = config.config.llm and config.config.llm.api_key
          local has_key = configured and utils.trim(configured) ~= ''
          if not has_key then
            for _, env_name in ipairs(env_keys[provider] or {}) do
              local value = vim.env[env_name]
              if value and utils.trim(value) ~= '' then
                has_key = true
                break
              end
            end
          end

          if has_key then
            vim.health.ok('LLM API key is configured')
          else
            vim.health.error('LLM API key is missing', {
              'Set `llm.api_key` in setup() or required env var for provider',
            })
          end
        end
      end
    else
      vim.health.warn('Plugin setup() has not been called', {
        "Call require('comment-translate').setup({}) in your config",
      })
    end
  else
    vim.health.error('comment-translate failed to load')
  end

  vim.health.info('Note: Translation requires internet connectivity')
end

return M
