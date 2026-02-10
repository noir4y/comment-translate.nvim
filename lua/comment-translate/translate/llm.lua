local M = {}
local cache = require('comment-translate.translate.cache')
local utils = require('comment-translate.utils')

local SUPPORTED_PROVIDERS = {
  openai = true,
  anthropic = true,
  gemini = true,
  ollama = true,
}

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

---@param provider string
---@param llm_config table
---@return string?
local function resolve_api_key(provider, llm_config)
  local api_key = llm_config.api_key

  if api_key and utils.trim(api_key) ~= '' then
    return api_key
  end

  local env_candidates = {
    openai = { 'OPENAI_API_KEY' },
    anthropic = { 'ANTHROPIC_API_KEY' },
    gemini = { 'GEMINI_API_KEY' },
    ollama = {},
  }

  for _, env_name in ipairs(env_candidates[provider] or {}) do
    local value = vim.env[env_name]
    if value and utils.trim(value) ~= '' then
      return value
    end
  end

  return nil
end

---@param provider string
---@param llm_config table
---@return string
local function resolve_endpoint(provider, llm_config)
  if llm_config.endpoint and utils.trim(llm_config.endpoint) ~= '' then
    return llm_config.endpoint
  end

  if provider == 'openai' then
    return 'https://api.openai.com/v1/chat/completions'
  end
  if provider == 'anthropic' then
    return 'https://api.anthropic.com/v1/messages'
  end
  if provider == 'gemini' then
    return string.format(
      'https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent',
      llm_config.model
    )
  end
  return 'http://localhost:11434/api/chat'
end

---@param provider string
---@param response table
---@return string?
local function extract_translated_text(provider, response)
  if type(response) ~= 'table' then
    return nil
  end

  if provider == 'anthropic' then
    local content = response.content
    if type(content) ~= 'table' then
      return nil
    end
    local chunks = {}
    for _, item in ipairs(content) do
      if type(item) == 'table' and type(item.text) == 'string' and item.text ~= '' then
        table.insert(chunks, item.text)
      end
    end
    if #chunks > 0 then
      return utils.trim(table.concat(chunks, ''))
    end
    return nil
  end

  if provider == 'gemini' then
    local candidates = response.candidates
    if type(candidates) ~= 'table' or type(candidates[1]) ~= 'table' then
      return nil
    end
    local content = candidates[1].content
    if type(content) ~= 'table' or type(content.parts) ~= 'table' then
      return nil
    end
    local chunks = {}
    for _, part in ipairs(content.parts) do
      if type(part) == 'table' and type(part.text) == 'string' and part.text ~= '' then
        table.insert(chunks, part.text)
      end
    end
    if #chunks > 0 then
      return utils.trim(table.concat(chunks, ''))
    end
    return nil
  end

  if provider == 'ollama' then
    local message = response.message
    if type(message) ~= 'table' or type(message.content) ~= 'string' then
      return nil
    end
    return utils.trim(message.content)
  end

  -- OpenAI response format
  local choices = response.choices
  if type(choices) ~= 'table' or type(choices[1]) ~= 'table' then
    return nil
  end

  local message = choices[1].message
  if type(message) ~= 'table' then
    return nil
  end

  local content = message.content
  if type(content) == 'string' then
    return utils.trim(content)
  end

  if type(content) == 'table' then
    local chunks = {}
    for _, item in ipairs(content) do
      if type(item) == 'table' and type(item.text) == 'string' and item.text ~= '' then
        table.insert(chunks, item.text)
      end
    end
    if #chunks > 0 then
      return utils.trim(table.concat(chunks, ''))
    end
  end

  return nil
end

---@param provider string
---@param model string
---@param system_prompt string
---@param user_prompt string
---@return table
local function build_payload(provider, model, system_prompt, user_prompt)
  if provider == 'anthropic' then
    return {
      model = model,
      max_tokens = 1024,
      temperature = 0,
      system = system_prompt,
      messages = {
        { role = 'user', content = user_prompt },
      },
    }
  end

  if provider == 'gemini' then
    return {
      systemInstruction = {
        parts = {
          { text = system_prompt },
        },
      },
      contents = {
        {
          parts = {
            { text = user_prompt },
          },
        },
      },
      generationConfig = {
        temperature = 0,
      },
    }
  end

  if provider == 'ollama' then
    return {
      model = model,
      stream = false,
      messages = {
        { role = 'system', content = system_prompt },
        { role = 'user', content = user_prompt },
      },
      options = {
        temperature = 0,
      },
    }
  end

  return {
    model = model,
    temperature = 0,
    messages = {
      { role = 'system', content = system_prompt },
      { role = 'user', content = user_prompt },
    },
  }
end

---@param provider string
---@param api_key string?
---@return string[]
local function build_headers(provider, api_key)
  local headers = {
    'Content-Type: application/json',
  }

  if provider == 'openai' then
    if api_key then
      table.insert(headers, 'Authorization: Bearer ' .. api_key)
    end
  elseif provider == 'anthropic' then
    if api_key then
      table.insert(headers, 'x-api-key: ' .. api_key)
    end
    table.insert(headers, 'anthropic-version: 2023-06-01')
  elseif provider == 'gemini' then
    if api_key then
      table.insert(headers, 'x-goog-api-key: ' .. api_key)
    end
  end

  return headers
end

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

  local provider = config.config.llm.provider or 'openai'
  if not SUPPORTED_PROVIDERS[provider] then
    vim.schedule(function()
      vim.notify(
        'comment-translate: Unsupported LLM provider: ' .. tostring(provider),
        vim.log.levels.ERROR
      )
      callback(nil)
    end)
    return
  end

  local api_key = resolve_api_key(provider, config.config.llm)
  if provider ~= 'ollama' and not api_key then
    vim.schedule(function()
      vim.notify(
        'comment-translate: LLM API key is missing for provider ' .. provider,
        vim.log.levels.ERROR
      )
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

  local normalized_target_lang = utils.normalize_lang_code(target_lang)
  local normalized_source_lang = source_lang and utils.normalize_lang_code(source_lang) or 'auto'
  local system_prompt = config.config.llm.system_prompt
    or 'You are a translation engine. Return only the translated text. Do not add explanations.'
  local user_prompt = string.format(
    'Translate the following text from %s to %s. Return only translated text.\n\n%s',
    normalized_source_lang,
    normalized_target_lang,
    text
  )
  local endpoint = resolve_endpoint(provider, config.config.llm)
  local payload = build_payload(provider, config.config.llm.model, system_prompt, user_prompt)
  local headers = build_headers(provider, api_key)

  local request_body = vim.fn.json_encode(payload)

  local stderr_output = {}
  local curl_args = {
    '--silent',
    '--show-error',
    '--fail',
    '--max-time',
    tostring(config.config.llm.timeout),
    '-X',
    'POST',
  }

  for _, header in ipairs(headers) do
    table.insert(curl_args, '-H')
    table.insert(curl_args, header)
  end

  table.insert(curl_args, '-d')
  table.insert(curl_args, request_body)
  table.insert(curl_args, endpoint)

  Job:new({
    command = 'curl',
    args = curl_args,
    on_stderr = function(_, data)
      if data and data ~= '' then
        table.insert(stderr_output, data)
      end
    end,
    on_exit = function(j, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          local err_msg = 'comment-translate: LLM translation failed (curl error)'
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
          vim.notify('comment-translate: Failed to parse LLM response', vim.log.levels.WARN)
          callback(nil)
          return
        end

        local translated_text = extract_translated_text(provider, json)
        if not translated_text or translated_text == '' then
          callback(nil)
          return
        end

        cache.set(text, translated_text, normalized_target_lang, normalized_source_lang)
        callback(translated_text)
      end)
    end,
  }):start()
end

return M
