local M = {}

local config = require('comment-translate.config')

local comment_node_types = {
  'comment',
  'line_comment',
  'block_comment',
  'documentation_comment',
  'doc_comment',
}

local string_node_types = {
  'string',
  'string_literal',
  'string_content',
  'text',
}

---@param bufnr number
---@param row number
---@param col number
---@return string?, string?
function M.get_text_at_position(bufnr, row, col)

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil, nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil, nil
  end

  local root = tree:root()
  if not root then
    return nil, nil
  end

  local node = root:named_descendant_for_range(row, col, row, col)
  if not node then
    return nil, nil
  end

  local node_type = node:type()
  local is_comment = false
  local is_string = false

  for _, type_name in ipairs(comment_node_types) do
    if node_type == type_name then
      is_comment = true
      break
    end
  end

  for _, type_name in ipairs(string_node_types) do
    if node_type == type_name then
      is_string = true
      break
    end
  end

  if not is_comment and not is_string then
    local parent = node:parent()
    while parent do
      local parent_type = parent:type()
      for _, type_name in ipairs(comment_node_types) do
        if parent_type == type_name then
          is_comment = true
          node = parent
          break
        end
      end
      if is_comment then break end
      
      for _, type_name in ipairs(string_node_types) do
        if parent_type == type_name then
          is_string = true
          node = parent
          break
        end
      end
      if is_string then break end

      parent = parent:parent()
    end
  end

  if is_comment and not config.config.targets.comment then
    return nil, nil
  end
  if is_string and not config.config.targets.string then
    return nil, nil
  end

  if is_comment or is_string then
    local text = vim.treesitter.get_node_text(node, bufnr)
    if text and text ~= '' then
      return text, node_type
    end
  end

  return nil, nil
end

---@param bufnr number
---@return table<number, string>
function M.get_all_comments(bufnr)
  if not config.config.targets.comment then
    return {}
  end
  
  local comments = {}
  
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return {}
  end
  
  local tree = parser:parse()[1]
  if not tree then
    return {}
  end
  
  local root = tree:root()
  
  local function traverse(node)
    local node_type = node:type()
    
    for _, type_name in ipairs(comment_node_types) do
      if node_type == type_name then
        local text = vim.treesitter.get_node_text(node, bufnr)
        if text and text ~= '' then
          local start_row = node:start()
          comments[start_row] = text
        end
        return
      end
    end
    
    for child in node:iter_children() do
      traverse(child)
    end
  end
  
  traverse(root)
  
  return comments
end

return M
