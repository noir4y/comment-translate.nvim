local M = {}
local cache = require('comment-translate.translate.cache')
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

  local cached = cache.get(text, target_lang, source_lang)
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
      vim.notify('comment-translate: plenary.nvim is required for translation', vim.log.levels.ERROR)
      callback(nil)
    end)
    return
  end
  
  source_lang = source_lang or 'auto'
  target_lang = utils.normalize_lang_code(target_lang)
  source_lang = utils.normalize_lang_code(source_lang)
  
  local encoded_text = utils.url_encode(text)
  local url = string.format(
    'https://translate.googleapis.com/translate_a/single?client=gtx&sl=%s&tl=%s&dt=t&q=%s',
    source_lang,
    target_lang,
    encoded_text
  )
  
  local stderr_output = {}

  Job:new({
    command = 'curl',
    args = {
      '--silent',
      '--show-error',
      '--fail',
      '--max-time', '10',
      url,
    },
    on_stderr = function(_, data)
      if data and data ~= '' then
        table.insert(stderr_output, data)
      end
    end,
    on_exit = function(j, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          local err_msg = 'comment-translate: Translation failed (curl error)'
          if #stderr_output > 0 then
            err_msg = err_msg .. ': ' .. table.concat(stderr_output, ' ')
          end
          vim.notify(err_msg, vim.log.levels.WARN)
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
        
        cache.set(text, translated_text, target_lang, source_lang)
        callback(translated_text)
      end)
    end,
  }):start()
end

return M
