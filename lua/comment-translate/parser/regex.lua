local M = {}

local config = require('comment-translate.config')

local line_comment_patterns = {
  '^%s*//+%s*(.+)$',
  '^%s*#%s*(.+)$',
  '^%s*%-%-+%s*(.+)$',
  '^%s*%%+%s*(.+)$',
  '^%s*/%*+%s*(.-)%s*%*+/%s*$',
  '^%s*%-%-+%[%[%s*(.-)%s*%]%]%-*%s*$',
}

local inline_comment_patterns = {
  '%s//+%s*(.+)$',
  '%s#%s*(.+)$',
  '%s%-%-+%s*(.+)$',
  '%s/%*+%s*(.-)%s*%*+/',
}

local string_patterns = {
  '"([^"]*)"',
  "'([^']*)'",
  '`([^`]*)`',
}

-- Block comment delimiters: { start_pattern, end_pattern, start_literal, end_literal }
local block_comment_delimiters = {
  { '/%*', '%*/', '/*', '*/' },             -- C/C++/Java/JS/etc.
  { '%-%-+%[%[', '%]%]', '--[[', ']]' },    -- Lua (]]-- or ]] both work)
  { '<!%-%-', '%-%->', '<!--', '-->' },     -- HTML/XML
}

---@param line_text string
---@return string
local function clean_block_comment_line(line_text)
  local cleaned = line_text:gsub('^%s*%*?%s?', '')
  return cleaned
end

---@param line_text string
---@return number? delimiter_index
---@return string? content_after_start
local function check_block_start(line_text)
  for i, delim in ipairs(block_comment_delimiters) do
    local start_pattern = delim[1]
    local end_pattern = delim[2]
    
    local start_pos = line_text:find(start_pattern)
    if start_pos then
      local end_pos = line_text:find(end_pattern, start_pos + 1)
      if not end_pos then
        local content = line_text:sub(start_pos):gsub('^' .. start_pattern .. '%s*', '')
        return i, content
      end
    end
  end
  return nil, nil
end

---@param line_text string
---@param delimiter_index number
---@return boolean
---@return string? content_before_end
local function check_block_end(line_text, delimiter_index)
  local delim = block_comment_delimiters[delimiter_index]
  if not delim then
    return false, nil
  end
  
  local end_pattern = delim[2]
  local end_pos = line_text:find(end_pattern)
  if end_pos then
    local content = line_text:sub(1, end_pos - 1)
    content = clean_block_comment_line(content)
    return true, content
  end
  return false, nil
end

---@param bufnr number
---@return table<number, string>
function M.get_all_comments(bufnr)
  if not config.config.targets.comment then
    return {}
  end

  local comments = {}
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, line_count, false)
  
  local in_block = false
  local block_delimiter_index = nil
  local block_start_line = nil
  local block_content_lines = {}
  
  for line_idx = 0, line_count - 1 do
    local line_text = lines[line_idx + 1]
    if not line_text then
      goto continue
    end
    
    if in_block then
      local is_end, content_before_end = check_block_end(line_text, block_delimiter_index)
      if is_end then
        if content_before_end and content_before_end ~= '' then
          table.insert(block_content_lines, content_before_end)
        end
        local block_text = table.concat(block_content_lines, ' ')
        block_text = block_text:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
        if block_text ~= '' then
          comments[block_start_line] = block_text
        end
        in_block = false
        block_delimiter_index = nil
        block_start_line = nil
        block_content_lines = {}
      else
        local cleaned = clean_block_comment_line(line_text)
        if cleaned ~= '' then
          table.insert(block_content_lines, cleaned)
        end
      end
    else
      local delim_idx, content_after_start = check_block_start(line_text)
      if delim_idx then
        in_block = true
        block_delimiter_index = delim_idx
        block_start_line = line_idx
        block_content_lines = {}
        if content_after_start and content_after_start ~= '' then
          table.insert(block_content_lines, content_after_start)
        end
      else
        local comment = nil
        for _, pattern in ipairs(line_comment_patterns) do
          comment = line_text:match(pattern)
          if comment then
            break
          end
        end
        
        if not comment then
          for _, pattern in ipairs(inline_comment_patterns) do
            comment = line_text:match(pattern)
            if comment then
              break
            end
          end
        end
        
        if comment then
          comments[line_idx] = comment
        end
      end
    end
    
    ::continue::
  end
  
  return comments
end

---@param bufnr number
---@param line number
---@return string?
function M.get_comment_at_line(bufnr, line)
  if not config.config.targets.comment then
    return nil
  end

  local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
  if not line_text then
    return nil
  end

  for _, pattern in ipairs(line_comment_patterns) do
    local comment = line_text:match(pattern)
    if comment then
      return comment
    end
  end

  for _, pattern in ipairs(inline_comment_patterns) do
    local comment = line_text:match(pattern)
    if comment then
      return comment
    end
  end

  return nil
end

---@param bufnr number
---@param line number
---@param col number
---@return string?
function M.get_string_at_position(bufnr, line, col)
  if not config.config.targets.string then
    return nil
  end
  
  local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
  if not line_text then
    return nil
  end

  local target_col = (col or 0) + 1

  for _, pattern in ipairs(string_patterns) do
    local search_start = 1
    while true do
      local s, e, match = line_text:find(pattern, search_start)
      if not s then
        break
      end

      if target_col >= s and target_col <= e then
        return match
      end

      search_start = e + 1
    end
  end
  
  return nil
end

return M
