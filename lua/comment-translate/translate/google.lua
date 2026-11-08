local M = {}
local cache = require('comment-translate.translate.cache')
local curl_config = require('comment-translate.translate.curl_config')
local utils = require('comment-translate.utils')

---@return boolean, table?
local function get_plenary_job()
  local ok, Job = pcall(require, 'plenary.job')
  if not ok then
    return false, nil
  end
  return true, Job
end

---@return boolean
local curl_available = nil
local function check_curl()
  if curl_available == nil then
    curl_available = vim.fn.executable('curl') == 1
  end
  return curl_available
end

---Translate text using Google Translate API (free version)
---@param text string
---@param target_lang string
---@param source_lang? string
---@param callback fun(result: string?)
function M.translate(text, target_lang, source_lang, callback)
  if not callback then
    error('callback is required')
  end

  target_lang = utils.normalize_lang_code(target_lang)
  source_lang = utils.normalize_lang_code(source_lang or 'auto')
  local namespace = cache.namespace({ 'google' })
  local cached = cache.get(text, target_lang, source_lang, namespace)
  if cached then
    vim.schedule(function()
      callback(cached)
    end)
    return
  end

  if utils.is_empty(text) then
    vim.schedule(function()
      callback('')
    end)
    return
  end

  local config = require('comment-translate.config')
  if #text > config.config.max_length then
    vim.schedule(function()
      callback(nil)
    end)
    return
  end

  if not check_curl() then
    vim.schedule(function()
      vim.notify('comment-translate: curl is required for translation', vim.log.levels.ERROR)
      callback(nil)
    end)
    return
  end

  local ok, Job = get_plenary_job()
  if not ok then
    vim.schedule(function()
      vim.notify(
        'comment-translate: plenary.nvim is required for translation',
        vim.log.levels.ERROR
      )
      callback(nil)
    end)
    return
  end

  local url = string.format(
    'https://translate.googleapis.com/translate_a/single?client=gtx&sl=%s&tl=%s&dt=t',
    source_lang,
    target_lang
  )
  local request_config = curl_config.build({
    'silent',
    'show-error',
    'fail',
    'get',
    curl_config.option('max-time', '10'),
    curl_config.option('data-urlencode', 'q=' .. text),
    curl_config.option('url', url),
  })

  Job:new({
    command = 'curl',
    args = { '--config', '-' },
    writer = request_config,
    on_stderr = function() end,
    on_exit = function(j, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          vim.notify('comment-translate: Translation failed (curl error)', vim.log.levels.WARN)
          callback(nil)
          return
        end

        local result = table.concat(j:result(), '')
        if not result or result == '' then
          callback(nil)
          return
        end

        local parse_ok, json = pcall(vim.fn.json_decode, result)
        if not parse_ok or not json then
          vim.notify('comment-translate: Failed to parse translation response', vim.log.levels.WARN)
          callback(nil)
          return
        end

        local translated_text = ''
        if json[1] and type(json[1]) == 'table' then
          for _, item in ipairs(json[1]) do
            if item[1] then
              translated_text = translated_text .. item[1]
            end
          end
        end

        if translated_text == '' then
          callback(nil)
          return
        end

        cache.set(text, translated_text, target_lang, source_lang, namespace)
        callback(translated_text)
      end)
    end,
  }):start()
end

return M
