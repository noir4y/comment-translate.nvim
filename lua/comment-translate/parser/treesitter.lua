local M = {}

local config = require('comment-translate.config')
local regex = require('comment-translate.parser.regex')

local comment_node_types = {
  comment = true,
  line_comment = true,
  single_line_comment = true,
  js_comment = true,
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
  encapsed_string = true,
  template_literal_type = true,
  attribute_backtick_string = true,
  raw_string_literal = true,
  interpreted_string_literal = true,
  raw_string = true,
  double_quote_scalar = true,
  single_quote_scalar = true,
  system_lib_string = true,
  quoted_attribute_value = true,
  double_quoted_string = true,
  json_string = true,
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

local function is_quoted_node(node)
  local kind = node:type()
  if quoted_node_types[kind] then
    return true
  end
  if kind == 'nowdoc_string' or kind == 'nowdoc_body' then
    -- Keep the host category even when its enclosing node is incomplete.
    return true
  end
  local parent = node:parent()
  if kind == 'body' and parent and parent:type() == 'heredoc' then
    local statement = parent:parent()
    local statement_type = statement and statement:type()
    return statement_type == 'let_statement' or statement_type == 'const_statement'
  end
  return false
end

local function is_complete_quoted_node(node)
  local kind = node:type()
  local parent = node:parent()
  if kind == 'nowdoc_string' or kind == 'nowdoc_body' then
    local nowdoc = kind == 'nowdoc_string' and parent and parent:parent() or parent
    -- A body can survive under ERROR when the closing marker is missing.
    return nowdoc and nowdoc:type() == 'nowdoc' and not nowdoc:has_error()
  end
  if kind == 'body' then
    return parent and not parent:has_error()
  end
  return true
end

-- A parser is released with its buffer; do not retain it through this cache.
local python3_cache = setmetatable({}, { __mode = 'k' })

local function child_of_type(node, kind)
  for child in node:iter_children() do
    if child:type() == kind then
      return child
    end
  end
end

local function recover_python3(bufnr, parser, trees)
  if not parser.lang or parser:lang() ~= 'vim' then
    return parser
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local regions = parser:included_regions()
  local cached = python3_cache[parser]
  if
    cached
    and cached.tick == tick
    and vim.deep_equal(cached.regions, regions)
    and cached.query == parser._injection_query
  then
    return cached.parser or parser, cached.blocked
  end
  local function finish(result, blocked)
    python3_cache[parser] = {
      tick = tick,
      parser = result ~= parser and result or nil,
      blocked = blocked,
      regions = vim.deepcopy(regions),
      query = parser._injection_query,
    }
    return result, blocked
  end

  local candidates = {}
  local function inspect(node)
    local kind = node:type()
    -- Host strings/comments and already recognized script bodies are opaque.
    if
      kind == 'script'
      or kind == 'heredoc'
      or comment_node_types[kind]
      or string_node_types[kind]
      or quoted_node_types[kind]
    then
      return
    end
    if kind == 'python_statement' and not child_of_type(node, 'script') then
      local row, col = node:start()
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
      local content = (line or ''):sub(col + 1)
      local command, space, tail = content:match('^([%a%d]+)([ \t]*)<<[ \t]*(.-)[ \t]*$')
      if command == 'python3' or command == 'py3' then
        local trimmed = tail == 'trim' or tail:match('^trim[ \t]+') ~= nil
        local marker_text = trimmed and tail:sub(5):match('^[ \t]*(.-)[ \t]*$') or tail
        local trim_start = trimmed and content:find('trim', #command + #space + 3, true)
        table.insert(candidates, {
          row = row,
          col = col,
          digit = col + #command,
          trailing = #(content:match('[ \t]*$')),
          marker = marker_text == '' and '.' or marker_text,
          indent = trimmed and line:match('^[ \t]*') or '',
          trim_start = trim_start and col + trim_start,
        })
      end
    end
    for child in node:iter_children() do
      if child:named() then
        inspect(child)
      end
    end
  end
  for _, tree in pairs(trees) do
    inspect(tree:root())
  end
  if #candidates == 0 then
    return finish(parser)
  end
  table.sort(candidates, function(a, b)
    return a.row < b.row
  end)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local accepted, last_close = {}, -1
  for _, candidate in ipairs(candidates) do
    -- A malformed host tree can misclassify code inside an earlier heredoc.
    if candidate.row > last_close then
      if candidate.marker:find('%s') then
        return finish(parser, true)
      end
      local closing
      for index = candidate.row + 2, #lines do
        if lines[index] == candidate.indent .. candidate.marker then
          closing = index - 1
          break
        end
      end
      if not closing then
        return finish(parser, true)
      end
      candidate.closing = closing
      last_close = closing
      table.insert(accepted, candidate)
      local line = lines[candidate.row + 1]
      line = line:sub(1, candidate.digit - 1) .. ' ' .. line:sub(candidate.digit + 1)
      if candidate.trim_start then
        line = line:sub(1, candidate.trim_start - 1) .. '    ' .. line:sub(candidate.trim_start + 4)
      end
      -- Old scanners include trailing header whitespace in the end marker.
      -- Move that trivia into command spacing without changing line length.
      if candidate.trailing > 0 then
        line = line:sub(1, candidate.digit)
          .. string.rep(' ', candidate.trailing)
          .. line:sub(candidate.digit + 1, #line - candidate.trailing)
      end
      lines[candidate.row + 1] = line
    end
  end

  -- Only headers change. All target text and byte positions stay intact.
  local created, shadow =
    pcall(vim.treesitter.get_string_parser, table.concat(lines, '\n') .. '\n', 'vim', parser._opts)
  if not created then
    return finish(parser, true)
  end
  local parsed, shadow_trees = pcall(function()
    -- Keep custom injection options and root coverage from the original parser.
    -- An explicit empty region differs from default whole-source coverage on
    -- newer Neovim versions: it can discard child injection boundaries.
    if not vim.deep_equal(regions, { {} }) then
      shadow:set_included_regions(vim.deepcopy(regions))
    end
    return shadow:parse(true)
  end)
  if not parsed or not shadow_trees or not shadow_trees[1] then
    return finish(parser, true)
  end
  local confirmed = {}
  local function confirm(node)
    if node:type() == 'python_statement' then
      local script = child_of_type(node, 'script')
      local ending = script and child_of_type(script, 'endmarker')
      if ending and not script:has_error() then
        local row, col = node:start()
        local closing = ending:start()
        confirmed[row] = { col = col, closing = closing }
      end
    end
    for child in node:iter_children() do
      if child:named() then
        confirm(child)
      end
    end
  end
  for _, tree in pairs(shadow_trees) do
    confirm(tree:root())
  end
  for _, candidate in ipairs(accepted) do
    local proof = confirmed[candidate.row]
    if not proof or proof.col ~= candidate.col or proof.closing ~= candidate.closing then
      return finish(parser, true)
    end
  end
  return finish(shadow)
end

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
  local recovered, result, blocked = pcall(recover_python3, bufnr, parser, trees)
  -- A compatibility failure must never reactivate whole-buffer regex fallback.
  if not recovered then
    python3_cache[parser] = {
      tick = vim.api.nvim_buf_get_changedtick(bufnr),
      blocked = true,
    }
    return parser, true
  end
  return result, blocked
end

local function find_target(node)
  while node do
    local kind = node:type()
    if comment_node_types[kind] then
      return node, 'comment'
    end
    if string_node_types[kind] or is_quoted_node(node) then
      return node, 'string'
    end
    node = node:parent()
  end
end

local function opaque_node_range(node)
  local kind = node:type()
  if kind == 'frontmatter_js_block' then
    return { node:range() }
  end
  if kind == 'shell_fragment' then
    local parent = node:parent()
    if parent and parent:type() == 'shell_command' then
      return { node:range() }
    end
  end
  if kind == 'inline' then
    local parent = node:parent()
    local parent_type = parent and parent:type()
    -- markdown_inline has a parsed root named inline; it is not opaque.
    if
      parent_type == 'paragraph'
      or parent_type == 'atx_heading'
      or parent_type == 'setext_heading'
    then
      return { node:range() }
    end
  end
  if kind == 'heredoc_block' then
    local parent = node:parent()
    if parent and parent:type() == 'run_instruction' then
      -- Dockerfile block ranges include heredoc markers; keep only body lines.
      local first, last
      for child in node:iter_children() do
        if child:type() == 'heredoc_line' then
          first, last = first or child, child
        end
      end
      if first then
        local start_row, start_col = first:start()
        local end_row, end_col = last:end_()
        return { start_row, start_col, end_row, end_col }
      end
    end
  end
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
  if
    kind == 'code_fence_content'
    or kind == 'html_block'
    or kind == 'indented_code_block'
    or kind == 'pipe_table_cell'
  then
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

local function included_ranges(cache, language_tree, tree)
  local by_tree = cache[language_tree]
  if not by_tree then
    by_tree = {}
    cache[language_tree] = by_tree
    local regions = language_tree:included_regions() or {}
    for index, candidate in pairs(language_tree:trees()) do
      local ranges = {}
      for _, range in ipairs(regions[index] or {}) do
        -- LanguageTree regions include absolute byte offsets on some versions.
        table.insert(ranges, #range == 6 and { range[1], range[2], range[4], range[5] } or range)
      end
      by_tree[candidate] = ranges
    end
  end
  return by_tree[tree] or {}
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

-- Keep owners distinct while indexing their regions. The subtree end bound
-- also handles overlapping owners without scanning unrelated earlier regions.
local function region_index(groups)
  local entries = {}
  for owner, ranges in ipairs(groups) do
    for _, range in ipairs(ranges) do
      table.insert(entries, { range = range, owner = owner, order = #entries + 1 })
    end
  end
  table.sort(entries, function(a, b)
    return before(a.range[1], a.range[2], b.range[1], b.range[2])
  end)
  local function build(first, last)
    if first > last then
      return
    end
    local middle = math.floor((first + last) / 2)
    local entry = entries[middle]
    entry.left, entry.right = build(first, middle - 1), build(middle + 1, last)
    entry.finish = entry.range
    for _, child in pairs({ entry.left, entry.right }) do
      if before(entry.finish[3], entry.finish[4], child.finish[3], child.finish[4]) then
        entry.finish = child.finish
      end
    end
    return entry
  end
  local root = build(1, #entries)
  return {
    query = function(_, range)
      local matches = {}
      local function visit(entry)
        if not entry or before(entry.finish[3], entry.finish[4], range[1], range[2]) then
          return
        end
        visit(entry.left)
        if before(range[3], range[4], entry.range[1], entry.range[2]) then
          return
        end
        if not before(entry.range[3], entry.range[4], range[1], range[2]) then
          table.insert(matches, entry)
        end
        visit(entry.right)
      end
      visit(root)
      -- Retain the original tree/region order when several owners overlap.
      table.sort(matches, function(a, b)
        return a.order < b.order
      end)
      return matches
    end,
  }
end

local function effective_ranges(cache, language_tree, tree, parent_ranges, for_fallback)
  local included = included_ranges(cache, language_tree, tree)
  if not parent_ranges then
    return included
  end
  -- Older LanguageTree implementations did not clip nested injection ranges
  -- to their parent's disjoint regions. Preserve each parent tree's ownership;
  -- pooling regions would let a nested capture claim a different parent's code.
  local clipped = {}
  for _, range in ipairs(included) do
    local owned, overlapping = {}, {}
    local candidates = parent_ranges
    if parent_ranges.query then
      candidates = {}
      local by_owner = {}
      for _, entry in ipairs(parent_ranges:query(range)) do
        local regions = by_owner[entry.owner]
        if not regions then
          regions = {}
          by_owner[entry.owner] = regions
          table.insert(candidates, regions)
        end
        table.insert(regions, entry.range)
      end
    end
    for _, parent_regions in ipairs(candidates) do
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

local function tree_in_regions(cache, language_tree, position, parent_ranges)
  for _, tree in pairs(language_tree:trees()) do
    for _, region in ipairs(effective_ranges(cache, language_tree, tree, parent_ranges)) do
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

local function merge_coverage(ranges)
  table.sort(ranges, function(a, b)
    return before(a[1], a[2], b[1], b[2])
  end)
  local merged = {}
  for _, range in ipairs(ranges) do
    local last = merged[#merged]
    if last and not before(last[3], last[4], range[1], range[2]) then
      if before(last[3], last[4], range[3], range[4]) then
        last[3], last[4] = range[3], range[4]
      end
    else
      -- Never mutate included-region metadata shared with another owner.
      table.insert(merged, { range[1], range[2], range[3], range[4] })
    end
  end
  return merged
end

local function uncovered_ranges(range, coverage)
  coverage = coverage or {}
  local first, last = 1, #coverage
  while first <= last do
    local middle = math.floor((first + last) / 2)
    local covered = coverage[middle]
    if before(range[1], range[2], covered[3], covered[4]) then
      last = middle - 1
    else
      first = middle + 1
    end
  end
  if
    first > #coverage or not before(coverage[first][1], coverage[first][2], range[3], range[4])
  then
    return { range }
  end

  local remaining, row, col = {}, range[1], range[2]
  for index = first, #coverage do
    local covered = coverage[index]
    if
      not before(covered[1], covered[2], range[3], range[4])
      or not before(row, col, range[3], range[4])
    then
      break
    end
    if before(row, col, covered[1], covered[2]) then
      table.insert(remaining, { row, col, covered[1], covered[2] })
    end
    row, col = covered[3], covered[4]
  end
  if before(row, col, range[3], range[4]) then
    table.insert(remaining, { row, col, range[3], range[4] })
  end
  return remaining
end

local function get_target_text(node, bufnr, injected)
  local text = vim.treesitter.get_node_text(node, bufnr)
  local slash_comment = node:type() == 'single_line_comment' or node:type() == 'js_comment'
  -- Restored comment forms need node-bounded cleaning even in the host tree.
  if
    not comment_node_types[node:type()]
    or (not injected and node:type() ~= 'marginalia' and not slash_comment)
  then
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
  return cleaned or (slash_comment and '' or text)
end

---@param bufnr number
---@param row number
---@param col number
---@return string?, string?, boolean handled, table? fallback_range
function M.get_text_at_position(bufnr, row, col)
  local parser, blocked = get_parser(bufnr)
  if blocked then
    return nil, nil, true
  end
  if not parser then
    return nil, nil, false
  end

  -- Cache raw regions only for this fully parsed request. Parent clipping is
  -- context-dependent and must still be computed for each use.
  local range_cache = {}
  local range = { row, col, row, col + 1 }
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  local previous_range = col > 0 and line and col == #line and { row, col - 1, row, col } or nil
  local function tree_at(language_tree, position, parent_ranges)
    if language_tree == parser then
      return language_tree:tree_for_range(position)
    end
    -- Neovim 0.10 contains/tree_for_range use the envelope of combined
    -- regions. Gaps belong to the host or a sibling, not this injection.
    return tree_in_regions(range_cache, language_tree, position, parent_ranges)
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
    local included = effective_ranges(range_cache, language_tree, tree, parent_ranges)
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
      if target:type() == 'encapsed_string' then
        -- PHP interpolation may contain quotes and span lines. Its parser
        -- already owns the complete string; do not rescan delimiters with regex.
        local text = not target:has_error() and vim.treesitter.get_node_text(target, bufnr)
        return text and text:match('^[bB]?"(.*)"$') or nil, 'string', true
      end
      if is_quoted_node(target) then
        if not is_complete_quoted_node(target) then
          return nil, 'string', true
        end
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
        table.insert(
          child_ownership,
          effective_ranges(range_cache, language_tree, candidate, ownership_ranges)
        )
      end
      child_ownership = region_index(child_ownership)
    end

    -- Host strings/comments retain their existing translation unit and targets.
    -- Only descend into injections when the host has no eligible category.
    local child_ranges = language_tree ~= parser and region_index({ included }) or nil
    for _, child in pairs(language_tree:children()) do
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
        for _, covered in
          ipairs(effective_ranges(range_cache, child, child_tree, child_ownership, true))
        do
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
  local parser, blocked = get_parser(bufnr)
  if blocked then
    return {}, true, {}
  end
  if not parser then
    return {}, false, {}
  end

  local comments, opaque, coverage, range_cache = {}, {}, {}, {}
  local ancestors = {}
  local function inside_host_target(node)
    local row, col = node:start()
    local point = { row, col, row, col + 1 }
    for _, ancestor in ipairs(ancestors) do
      local host, tree = ancestor.language_tree
      if host == parser then
        tree = host:tree_for_range(point)
      else
        for _, entry in ipairs(ancestor.index:query(point)) do
          if contains(entry.range, point) then
            tree = ancestor.trees[entry.owner]
            break
          end
        end
      end
      local host_node = tree and tree:root():named_descendant_for_range(row, col, row, col)
      if find_target(host_node) then
        return true
      end
    end
    return false
  end

  local function collect(language_tree, parent_ranges)
    local language_ranges, trees = {}, {}
    for _, tree in pairs(language_tree:trees()) do
      table.insert(
        language_ranges,
        effective_ranges(range_cache, language_tree, tree, parent_ranges)
      )
      table.insert(trees, tree)
    end
    local index = region_index(language_ranges)
    for owner, tree in ipairs(trees) do
      local included = language_ranges[owner]
      local function candidates(range)
        if #included <= 1 then
          return included
        end
        local ranges = {}
        for _, entry in ipairs(index:query(range)) do
          if entry.owner == owner then
            table.insert(ranges, entry.range)
          end
        end
        return ranges
      end
      for _, range in
        ipairs(effective_ranges(range_cache, language_tree, tree, parent_ranges, true))
      do
        for _, ancestor in ipairs(ancestors) do
          local host = ancestor.language_tree
          coverage[host] = coverage[host] or {}
          table.insert(coverage[host], range)
        end
      end

      local function traverse(node)
        if comment_node_types[node:type()] then
          if inside_host_target(node) then
            return
          end
          if #ancestors > 0 then
            local contained = false
            local node_range = { node:range() }
            for _, range in ipairs(candidates(node_range)) do
              contained = contained or contains(range, node_range)
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
          local ranges = #ancestors > 0 and intersect(range, candidates(range)) or { range }
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

    table.insert(ancestors, { language_tree = language_tree, index = index, trees = trees })
    for _, child in pairs(language_tree:children()) do
      collect(child, language_tree ~= parser and index or nil)
    end
    table.remove(ancestors)
  end
  collect(parser)

  for host, ranges in pairs(coverage) do
    coverage[host] = merge_coverage(ranges)
  end
  local fallback_ranges = {}
  for _, region in ipairs(opaque) do
    vim.list_extend(fallback_ranges, uncovered_ranges(region.range, coverage[region.language_tree]))
  end
  return comments, true, fallback_ranges
end

return M
