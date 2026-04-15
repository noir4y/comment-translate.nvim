---@brief Health check for comment-translate.nvim
---Run with :checkhealth comment-translate or :CommentTranslateHealth

local M = {}
local utils = require('comment-translate.utils')
local pending_target_bufnr
local parser_sources_note = 'Parsers may come from bundled Neovim parsers, manual installation, or '
  .. 'parser-providing plugin setups such as nvim-treesitter'
local parser_api_note = "comment-translate.nvim uses Neovim's built-in Tree-sitter APIs "
  .. 'and does not require the nvim-treesitter plugin itself'

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

---@return number?
local function consume_health_target_bufnr()
  local bufnr = pending_target_bufnr
  pending_target_bufnr = nil

  if type(bufnr) == 'number' and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end

  return nil
end

---@param bufnr number?
function M.set_target_bufnr(bufnr)
  if type(bufnr) == 'number' and vim.api.nvim_buf_is_valid(bufnr) then
    pending_target_bufnr = bufnr
    return
  end

  pending_target_bufnr = nil
end

---@param bufnr number?
---@return string, string
local function check_target_buffer_parser(bufnr)
  if not vim.treesitter or type(vim.treesitter.get_parser) ~= 'function' then
    return 'api_unavailable', 'Tree-sitter API is not available in this Neovim build'
  end

  if not bufnr then
    return 'target_required', 'Parser validation was skipped because no target buffer was provided'
  end

  local buftype = vim.bo[bufnr].buftype
  if buftype ~= '' then
    return 'non_file_buffer',
      string.format(
        'The requested buffer is not a normal file buffer (buftype=%s); skipped parser validation',
        buftype
      )
  end

  local filetype = vim.bo[bufnr].filetype

  if not filetype or filetype == '' then
    return 'filetype_missing', 'The requested buffer has no filetype; skipped parser validation'
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if ok and parser then
    return 'ok',
      string.format(
        'Tree-sitter parser is available for the requested buffer filetype: %s',
        filetype
      )
  end

  return 'parser_missing',
    string.format(
      'Tree-sitter parser is not available for the requested buffer filetype: %s',
      filetype
    )
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

  local parser_status, parser_message = check_target_buffer_parser(consume_health_target_bufnr())
  if parser_status == 'ok' then
    vim.health.ok(parser_message)
  elseif parser_status == 'api_unavailable' then
    vim.health.warn(parser_message, {
      'Tree-sitter support is not available in this Neovim build',
      'Without a parser, regex-based parsing will be used as fallback',
    })
  elseif parser_status == 'target_required' then
    vim.health.info(parser_message)
    vim.health.info('Use :CommentTranslateHealth from the file buffer you want to inspect')
  elseif parser_status == 'non_file_buffer' then
    vim.health.info(parser_message)
    vim.health.info(
      'Use :CommentTranslateHealth from a normal file buffer to validate parser availability'
    )
  elseif parser_status == 'filetype_missing' then
    vim.health.info(parser_message)
    vim.health.info('Set the buffer filetype and rerun :CommentTranslateHealth')
  else
    vim.health.warn(parser_message, {
      'Install a parser for this language using your preferred method',
      parser_sources_note,
      parser_api_note,
      'Without a parser, regex-based parsing will be used as fallback',
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
