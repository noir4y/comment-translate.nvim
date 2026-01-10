---@brief Translation cache with LRU eviction policy
---@class TranslationCache

local M = {}

---@type table<string, string>
local cache = {}

---@type string[]
local lru_keys = {}

---Generate cache key from text and language pair
---Uses SHA256 hash to avoid key collisions when text contains delimiter characters
---@param text string
---@param target_lang string
---@param source_lang? string
---@return string
local function make_key(text, target_lang, source_lang)
  source_lang = source_lang or 'auto'
  -- Hash the text to avoid collisions from delimiter characters in the original text
  local text_hash = vim.fn.sha256(text)
  return string.format('%s|%s|%s', text_hash, source_lang, target_lang)
end

---@param key string
---@return number?
local function find_key_index(key)
  for i, k in ipairs(lru_keys) do
    if k == key then
      return i
    end
  end
  return nil
end

---@param key string
local function touch_key(key)
  local idx = find_key_index(key)
  if idx then
    table.remove(lru_keys, idx)
  end
  table.insert(lru_keys, key)
end

local function evict_lru()
  if #lru_keys > 0 then
    local oldest_key = table.remove(lru_keys, 1)
    cache[oldest_key] = nil
  end
end

---@param text string
---@param translated_text string
---@param target_lang string
---@param source_lang? string
function M.set(text, translated_text, target_lang, source_lang)
  local config = require('comment-translate.config')
  if not config.config.cache.enabled then
    return
  end

  local key = make_key(text, target_lang, source_lang)

  if cache[key] then
    cache[key] = translated_text
    touch_key(key)
    return
  end

  local max_entries = config.config.cache.max_entries
  -- Guard against invalid max_entries to prevent infinite loop
  if max_entries < 1 then
    return
  end
  while #lru_keys >= max_entries do
    evict_lru()
  end

  cache[key] = translated_text
  table.insert(lru_keys, key)
end

---@param text string
---@param target_lang string
---@param source_lang? string
---@return string?
function M.get(text, target_lang, source_lang)
  local config = require('comment-translate.config')
  if not config.config.cache.enabled then
    return nil
  end

  local key = make_key(text, target_lang, source_lang)
  local value = cache[key]

  if value then
    touch_key(key)
  end

  return value
end

function M.clear()
  cache = {}
  lru_keys = {}
end

---@return number
function M.size()
  return #lru_keys
end

---@return table
function M.stats()
  return {
    size = #lru_keys,
    keys = vim.deepcopy(lru_keys),
  }
end

return M
