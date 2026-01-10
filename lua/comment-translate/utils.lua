local M = {}

---@param text string
---@return string
function M.trim(text)
  if not text then
    return ''
  end
  return text:match('^%s*(.-)%s*$')
end

---@param lines string[]
---@return string
function M.merge_lines(lines)
  local cleaned = {}
  for _, line in ipairs(lines) do
    local trimmed = M.trim(line)
    if trimmed ~= '' then
      table.insert(cleaned, trimmed)
    end
  end
  return table.concat(cleaned, ' ')
end

---@param text string
---@param comment_chars string[]
---@return string
function M.remove_comment_chars(text, comment_chars)
  local result = text
  for _, char in ipairs(comment_chars) do
    result = result:gsub('^%s*' .. vim.pesc(char) .. '%s*', '')
    result = result:gsub('%s*' .. vim.pesc(char) .. '%s*$', '')
  end
  return M.trim(result)
end

---@param text string
---@return boolean
function M.is_empty(text)
  return text == nil or M.trim(text) == ''
end

---@param text string
---@return string
function M.url_encode(text)
  text = text:gsub('\n', ' ')
  text = text:gsub('([^%w%-%.%_%~])', function(c)
    return string.format('%%%02X', string.byte(c))
  end)
  return text
end

---@param lang string
---@return string
function M.normalize_lang_code(lang)
  lang = lang:lower()
  lang = lang:gsub('_', '-')
  return lang
end

return M
