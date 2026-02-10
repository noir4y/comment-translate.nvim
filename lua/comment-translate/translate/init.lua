local M = {}

M.SERVICES = {
  google = 'google',
  llm = 'llm',
}

---@param service_name? string
---@return table?
---@return string?
local function get_service(service_name)
  local config = require('comment-translate.config')
  service_name = service_name or config.config.translate_service

  if service_name == M.SERVICES.google then
    return require('comment-translate.translate.google'), nil
  elseif service_name == M.SERVICES.llm then
    return require('comment-translate.translate.llm'), nil
  else
    return nil, 'Unknown translate service: ' .. tostring(service_name)
  end
end

---Translate text using configured service
---@param text string Text to translate
---@param target_lang? string Target language code
---@param source_lang? string Source language code
---@param callback fun(result: string?) Callback with translated text or nil on error
---@param service_name? string Override translation service
function M.translate(text, target_lang, source_lang, callback, service_name)
  if not callback then
    vim.notify('comment-translate: callback is required for translate()', vim.log.levels.ERROR)
    return
  end

  local config = require('comment-translate.config')
  target_lang = target_lang or config.config.target_language

  local service, err = get_service(service_name)
  if not service then
    vim.notify('comment-translate: ' .. (err or 'Unknown error'), vim.log.levels.ERROR)
    vim.schedule(function()
      callback(nil)
    end)
    return
  end

  service.translate(text, target_lang, source_lang, callback)
end

---@return string[]
function M.get_available_services()
  return { M.SERVICES.google, M.SERVICES.llm }
end

return M
