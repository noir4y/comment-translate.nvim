local M = {}

local config = require('comment-translate.config')
local regex = require('comment-translate.parser.regex')

local comment_node_types = {
  comment = true,
  line_comment = true,
  block_comment = true,
  documentation_comment = true,
  doc_comment = true,
}

local string_node_types = {
  string = true,
  string_literal = true,
  string_content = true,
  text = true,
}

-- These forms previously relied on regex for their quoted content. Keep that
-- extraction, but restrict it to the string node, never the surrounding code.
local quoted_node_types = {
  char_literal = true,
  template_string = true,
  raw_string_literal = true,
  interpreted_string_literal = true,
  raw_string = true,
  double_quote_scalar = true,
  single_quote_scalar = true,
  system_lib_string = true,
}

local function get_parser(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  -- Newer Neovim versions require a range to parse injections on first use.
  -- Neovim 0.8 ignores this extra argument and already parses all injections.
  local parsed, trees = pcall(parser.parse, parser, true)
  if not parsed or not trees or not trees[1] or not trees[1]:root() then
    return nil
  end
  return parser
end

local function find_target(node)
  while node do
    local kind = node:type()
    if comment_node_types[kind] then
      return node, 'comment'
    end
    if string_node_types[kind] or quoted_node_types[kind] then
      return node, 'string'
    end
    node = node:parent()
  end
end

local function opaque_node_range(node)
  local kind = node:type()
  if kind == 'code_fence_content' then
    return { node:range() }
  end
  if kind == 'body' or kind == 'chunk' then
    local parent = node:parent()
    if parent and parent:type() == 'script' then
      parent = parent:parent()
    end
    local parent_type = parent and parent:type()
    if
      parent_type == 'lua_statement'
      or parent_type == 'python_statement'
      or parent_type == 'ruby_statement'
    then
      return { node:range() }
    end
  end
end

local function opaque_range(node)
  while node do
    local range = opaque_node_range(node)
    if range then
      return range
    end
    node = node:parent()
  end
end

local function before(row, col, other_row, other_col)
  return row < other_row or (row == other_row and col < other_col)
end

local function contains(outer, inner)
  return not before(inner[1], inner[2], outer[1], outer[2])
    and not before(outer[3], outer[4], inner[3], inner[4])
end

local function subtract(ranges, covered)
  local remaining = {}
  for _, range in ipairs(ranges) do
    if
      not before(range[1], range[2], covered[3], covered[4])
      or not before(covered[1], covered[2], range[3], range[4])
    then
      table.insert(remaining, range)
    else
      if before(range[1], range[2], covered[1], covered[2]) then
        table.insert(remaining, { range[1], range[2], covered[1], covered[2] })
      end
      if before(covered[3], covered[4], range[3], range[4]) then
        table.insert(remaining, { covered[3], covered[4], range[3], range[4] })
      end
    end
  end
  return remaining
end

local function get_target_text(node, bufnr, injected)
  local text = vim.treesitter.get_node_text(node, bufnr)
  if not injected or not comment_node_types[node:type()] then
    return text
  end
  -- Clean only a proven comment node. The host commentstring and a generic
  -- list of prefixes can otherwise strip punctuation from the actual body.
  local range = { node:range() }
  local cleaned
  if range[1] == range[3] then
    cleaned = regex.get_comment_at_line(bufnr, range[1], nil, range)
  else
    cleaned = regex.get_all_comments(bufnr, range)[range[1]]
  end
  return cleaned or text
end

---@param bufnr number
---@param row number
---@param col number
---@return string?, string?, boolean handled, table? fallback_range
function M.get_text_at_position(bufnr, row, col)
  local parser = get_parser(bufnr)
  if not parser then
    return nil, nil, false
  end

  local range = { row, col, row, col + 1 }
  local function resolve(language_tree)
    local tree = language_tree:tree_for_range(range)
    local node = tree and tree:root():named_descendant_for_range(row, col, row, col)
    local target, category = find_target(node)
    if target then
      if not config.config.targets[category] then
        return nil, nil, true
      end
      if language_tree ~= parser then
        local contained = false
        for _, included in ipairs(tree:included_ranges()) do
          contained = contained or contains(included, { target:range() })
        end
        if not contained then
          return nil, nil, true
        end
      end
      if quoted_node_types[target:type()] then
        local text = regex.get_string_at_position(bufnr, row, col, { target:range() })
        return text, 'string', true
      end
      return get_target_text(target, bufnr, language_tree ~= parser),
        language_tree == parser and node:type() or category,
        true
    end

    -- Host strings/comments retain their existing translation unit and targets.
    -- Only descend into injections when the host has no eligible category.
    for _, child in pairs(language_tree:children()) do
      if child:contains(range) then
        return resolve(child)
      end
    end

    local fallback_range = opaque_range(node)
    return nil, nil, fallback_range == nil, fallback_range
  end

  return resolve(parser)
end

---@param bufnr number
---@return table<number, string>, boolean handled, table fallback_ranges
function M.get_all_comments(bufnr)
  if not config.config.targets.comment then
    return {}, true, {}
  end
  local parser = get_parser(bufnr)
  if not parser then
    return {}, false, {}
  end

  local comments, opaque, coverage = {}, {}, {}
  local ancestors = {}
  local function inside_host_target(node)
    local row, col = node:start()
    local point = { row, col, row, col + 1 }
    for _, host in ipairs(ancestors) do
      local tree = host:tree_for_range(point)
      local host_node = tree and tree:root():named_descendant_for_range(row, col, row, col)
      if find_target(host_node) then
        return true
      end
    end
    return false
  end

  local function collect(language_tree)
    local regions = language_tree:included_regions() or {}
    for index, tree in pairs(language_tree:trees()) do
      local included = {}
      for _, range in ipairs(regions[index] or {}) do
        -- included_regions() uses six fields (including absolute byte offsets).
        local normalized = #range == 6 and { range[1], range[2], range[4], range[5] } or range
        table.insert(included, normalized)
        table.insert(coverage, { range = normalized, ancestors = vim.list_extend({}, ancestors) })
      end

      local function traverse(node)
        if comment_node_types[node:type()] then
          if inside_host_target(node) then
            return
          end
          if #ancestors > 0 then
            local contained = false
            for _, range in ipairs(included) do
              contained = contained or contains(range, { node:range() })
            end
            -- A combined injection can span disjoint regions. Do not extract
            -- intervening host code as part of a contiguous comment node.
            if not contained then
              return
            end
          end
          local text = get_target_text(node, bufnr, #ancestors > 0)
          if text and text ~= '' then
            comments[node:start()] = text
          end
          return
        end

        local range = opaque_node_range(node)
        if range and not inside_host_target(node) then
          table.insert(opaque, { range = range, language_tree = language_tree })
        end
        for child in node:iter_children() do
          traverse(child)
        end
      end
      traverse(tree:root())
    end

    table.insert(ancestors, language_tree)
    for _, child in pairs(language_tree:children()) do
      collect(child)
    end
    table.remove(ancestors)
  end
  collect(parser)

  local fallback_ranges = {}
  for _, region in ipairs(opaque) do
    local remaining = { region.range }
    for _, parsed in ipairs(coverage) do
      for _, host in ipairs(parsed.ancestors) do
        if host == region.language_tree then
          remaining = subtract(remaining, parsed.range)
          break
        end
      end
    end
    vim.list_extend(fallback_ranges, remaining)
  end
  return comments, true, fallback_ranges
end

return M
