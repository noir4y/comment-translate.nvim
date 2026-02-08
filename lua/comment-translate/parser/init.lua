local M = {}
local treesitter = require('comment-translate.parser.treesitter')
local regex = require('comment-translate.parser.regex')
local utils = require('comment-translate.utils')

local comment_tokens = {
  '//',
  '#',
  '--',
  '%',
  '/**',
  '/*',
  '*/',
  '--[[',
  ']]--',
}

local function get_comment_tokens(bufnr)
  local cs = vim.bo[bufnr or 0].commentstring
  if cs and cs:find('%%s') then
    local tokens = {}
    local prefix = cs:match('^(.*)%%s')
    local suffix = cs:match('%%s(.*)$')
    if prefix and prefix ~= '' then
      table.insert(tokens, prefix)
    end
    if suffix and suffix ~= '' then
      table.insert(tokens, suffix)
    end
    if #tokens > 0 then
      return tokens
    end
  end
  return comment_tokens
end

local function clean_comment_text(text, bufnr)
  if not text or text == '' then
    return text
  end

  local lines = vim.split(text, '\n', { plain = true })
  local stripped = {}

  local tokens = get_comment_tokens(bufnr)
  for _, line in ipairs(lines) do
    local cleaned = utils.remove_comment_chars(line, tokens)
    if not utils.is_empty(cleaned) then
      table.insert(stripped, cleaned)
    end
  end

  return utils.merge_lines(stripped)
end

local function normalize_text(text, node_type)
  if not text then
    return nil
  end

  if node_type and node_type:find('comment') then
    return clean_comment_text(text)
  end

  return utils.trim(text)
end

---@param bufnr? number
---@return string?, string?
function M.get_text_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  local text, node_type = treesitter.get_text_at_position(bufnr, row, col)
  if text then
    local cleaned = normalize_text(text, node_type)
    if utils.is_empty(cleaned) then
      return nil, node_type
    end
    return cleaned, node_type
  end

  local comment = regex.get_comment_at_line(bufnr, row)
  if comment then
    local cleaned = normalize_text(clean_comment_text(comment, bufnr), 'comment')
    if utils.is_empty(cleaned) then
      return nil, 'comment'
    end
    return cleaned, 'comment'
  end

  local str = regex.get_string_at_position(bufnr, row, col)
  if str then
    local cleaned = normalize_text(str)
    if utils.is_empty(cleaned) then
      return nil, 'string'
    end
    return cleaned, 'string'
  end

  return nil, nil
end

---@param bufnr? number
---@return table<number, string>
function M.get_all_comments(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local comments = treesitter.get_all_comments(bufnr)
  if next(comments) then
    local cleaned = {}
    for line, text in pairs(comments) do
      local normalized = clean_comment_text(text, bufnr)
      if not utils.is_empty(normalized) then
        cleaned[line] = normalized
      end
    end
    return cleaned
  end

  local regex_comments = regex.get_all_comments(bufnr)
  local cleaned = {}
  for line, text in pairs(regex_comments) do
    local normalized = clean_comment_text(text, bufnr)
    if not utils.is_empty(normalized) then
      cleaned[line] = normalized
    end
  end
  return cleaned
end

return M
