local M = {}

local config = require('comment-translate.config')
local regex = require('comment-translate.parser.regex')

local comment_node_types = {
  comment = true,
  line_comment = true,
  block_comment = true,
  documentation_comment = true,
  multiline_comment = true,
  doc_comment = true,
  marginalia = true,
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
  quoted_attribute_value = true,
  double_quoted_string = true,
  single_quoted_string = true,
  double_quote_string = true,
  single_quote_string = true,
  string_value = true,
  quoted_key = true,
  character_literal = true,
  ansi_c_string = true,
  line_string_literal = true,
  string_expression = true,
  indented_string_expression = true,
  multi_line_string_literal = true,
  link_title = true,
  heredoc_body = true,
  block_scalar = true,
  string_scalar = true,
  literal = true,
}

local function get_parser(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  -- Parse all injection ranges on first use, including on Neovim 0.10.
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
  if kind == 'raw_text' then
    local parent = node:parent()
    if parent and (parent:type() == 'script_element' or parent:type() == 'style_element') then
      return { node:range() }
    end
  end
  if kind == 'minus_metadata' or kind == 'plus_metadata' then
    local start_row, _, end_row = node:range()
    -- Frontmatter delimiters are Markdown structure, not embedded comments.
    return { start_row + 1, 0, end_row - 1, 0 }
  end
  if kind == 'code_fence_content' or kind == 'html_block' or kind == 'indented_code_block' then
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

local function included_ranges(language_tree, tree)
  local regions = language_tree:included_regions() or {}
  for index, candidate in pairs(language_tree:trees()) do
    if candidate == tree then
      local ranges = {}
      for _, range in ipairs(regions[index] or {}) do
        -- LanguageTree regions include absolute byte offsets on some versions.
        table.insert(ranges, #range == 6 and { range[1], range[2], range[4], range[5] } or range)
      end
      return ranges
    end
  end
  return {}
end

local function intersect(range, included)
  local clipped = {}
  for _, region in ipairs(included) do
    local start = before(range[1], range[2], region[1], region[2]) and region or range
    local finish = before(range[3], range[4], region[3], region[4]) and range or region
    if before(start[1], start[2], finish[3], finish[4]) then
      table.insert(clipped, { start[1], start[2], finish[3], finish[4] })
    end
  end
  return clipped
end

local function effective_ranges(language_tree, tree, parent_ranges, for_fallback)
  local included = included_ranges(language_tree, tree)
  if not parent_ranges then
    return included
  end
  -- Older LanguageTree implementations did not clip nested injection ranges
  -- to their parent's disjoint regions. Preserve each parent tree's ownership;
  -- pooling regions would let a nested capture claim a different parent's code.
  local clipped = {}
  for _, range in ipairs(included) do
    local owned, overlapping = {}, {}
    for _, parent_regions in ipairs(parent_ranges) do
      local start_owned, end_owned = false, false
      for _, region in ipairs(parent_regions) do
        start_owned = start_owned or contains(region, { range[1], range[2], range[1], range[2] })
        end_owned = end_owned or contains(region, { range[3], range[4], range[3], range[4] })
      end
      if start_owned and end_owned then
        vim.list_extend(owned, intersect(range, parent_regions))
      elseif for_fallback then
        vim.list_extend(overlapping, intersect(range, parent_regions))
      end
    end
    -- Unknown ownership permits no extraction. Its parsed overlap must also
    -- prevent regex fallback from reclassifying that content as unparsed.
    vim.list_extend(clipped, #owned > 0 and owned or overlapping)
  end
  return clipped
end

local function tree_in_regions(language_tree, position, parent_ranges)
  for _, tree in pairs(language_tree:trees()) do
    for _, region in ipairs(effective_ranges(language_tree, tree, parent_ranges)) do
      if contains(region, position) then
        return tree
      end
    end
  end
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
  -- SQL block comments need node-bounded cleaning even in the host tree.
  if not comment_node_types[node:type()] or (not injected and node:type() ~= 'marginalia') then
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
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  local previous_range = col > 0 and line and col == #line and { row, col - 1, row, col } or nil
  local function tree_at(language_tree, position, parent_ranges)
    if language_tree == parser then
      return language_tree:tree_for_range(position)
    end
    -- Neovim 0.10 contains/tree_for_range use the envelope of combined
    -- regions. Gaps belong to the host or a sibling, not this injection.
    return tree_in_regions(language_tree, position, parent_ranges)
  end
  local function resolve(language_tree, parent_ranges, ownership_ranges)
    local tree = tree_at(language_tree, range, parent_ranges)
    local node = tree and tree:root():named_descendant_for_range(row, col, row, col)
    local target, category = find_target(node)
    -- Insert-mode EOL lies at a comment's half-open end. Resolve only comments
    -- (or unparsed embedded content) there; do not expand string/code targets.
    if not target and previous_range then
      local previous_tree = tree_at(language_tree, previous_range, parent_ranges)
      local previous_node = previous_tree
        and previous_tree:root():named_descendant_for_range(row, col - 1, row, col - 1)
      local previous_target, previous_category = find_target(previous_node)
      if previous_category == 'comment' then
        local end_row, end_col = previous_target:end_()
        if end_row == row and end_col == col then
          tree, node, target, category =
            previous_tree, previous_node, previous_target, previous_category
        end
      elseif not previous_target and opaque_range(previous_node) then
        tree, node = previous_tree, previous_node
      end
    end
    local included = effective_ranges(language_tree, tree, parent_ranges)
    if target then
      if not config.config.targets[category] then
        return nil, nil, true
      end
      if language_tree ~= parser then
        local contained = false
        for _, region in ipairs(included) do
          contained = contained or contains(region, { target:range() })
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

    -- Coverage ownership needs every parent tree, even when the cursor has
    -- selected only one. A sibling's valid hull must not become ambiguous here.
    local child_ownership
    if language_tree ~= parser then
      child_ownership = {}
      for _, candidate in pairs(language_tree:trees()) do
        table.insert(child_ownership, effective_ranges(language_tree, candidate, ownership_ranges))
      end
    end

    -- Host strings/comments retain their existing translation unit and targets.
    -- Only descend into injections when the host has no eligible category.
    for _, child in pairs(language_tree:children()) do
      local child_ranges = language_tree ~= parser and { included } or nil
      if
        tree_at(child, range, child_ranges)
        or (previous_range and tree_at(child, previous_range, child_ranges))
      then
        return resolve(child, child_ranges, child_ownership)
      end
    end

    local fallback_range = opaque_range(node)
    if not fallback_range then
      return nil, nil, true
    end
    local remaining = language_tree ~= parser and intersect(fallback_range, included)
      or { fallback_range }
    -- A neighboring parsed child can occupy part of the same opaque line.
    -- Regex may inspect only the unparsed fragment containing the cursor.
    for _, child in pairs(language_tree:children()) do
      for _, child_tree in pairs(child:trees()) do
        for _, covered in ipairs(effective_ranges(child, child_tree, child_ownership, true)) do
          remaining = subtract(remaining, covered)
        end
      end
    end
    for _, fragment in ipairs(remaining) do
      if contains(fragment, previous_range or range) then
        return nil, nil, false, fragment
      end
    end
    return nil, nil, true
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
  local ancestors, ancestor_ranges = {}, {}
  local function inside_host_target(node)
    local row, col = node:start()
    local point = { row, col, row, col + 1 }
    for _, host in ipairs(ancestors) do
      local tree = host == parser and host:tree_for_range(point)
        or tree_in_regions(host, point, ancestor_ranges[host])
      local host_node = tree and tree:root():named_descendant_for_range(row, col, row, col)
      if find_target(host_node) then
        return true
      end
    end
    return false
  end

  local function collect(language_tree, parent_ranges)
    local language_ranges = {}
    for _, tree in pairs(language_tree:trees()) do
      local included = effective_ranges(language_tree, tree, parent_ranges)
      table.insert(language_ranges, included)
      for _, range in ipairs(effective_ranges(language_tree, tree, parent_ranges, true)) do
        table.insert(coverage, { range = range, ancestors = vim.list_extend({}, ancestors) })
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
          local ranges = #ancestors > 0 and intersect(range, included) or { range }
          for _, clipped in ipairs(ranges) do
            table.insert(opaque, { range = clipped, language_tree = language_tree })
          end
        end
        for child in node:iter_children() do
          traverse(child)
        end
      end
      traverse(tree:root())
    end

    table.insert(ancestors, language_tree)
    ancestor_ranges[language_tree] = parent_ranges
    for _, child in pairs(language_tree:children()) do
      collect(child, language_tree ~= parser and language_ranges or nil)
    end
    table.remove(ancestors)
    ancestor_ranges[language_tree] = nil
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
