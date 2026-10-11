local M = {}

local function normal(keys)
  -- Literal editor keys only: source text never enters an Ex command.
  vim.cmd('silent noautocmd keepjumps normal! ' .. keys)
end

local function character_end(line, start_col)
  local length = vim.fn.byteidx(line:sub(start_col + 1), 1)
  return length < 0 and #line or start_col + length
end

local function row_range(winid, row, line, left, right, to_eol)
  local eol = vim.fn.virtcol({ row, #line + 1 }, 1, winid)[1]
  if left >= eol then
    return {
      row = row - 1,
      start_col = #line,
      end_col = #line,
      left_pad = left - eol,
      right_pad = 0,
    }
  end

  local start_col = vim.fn.virtcol2col(winid, row, left) - 1
  local start_cells = vim.fn.virtcol({ row, start_col + 1 }, 1, winid)
  local end_col, right_pad = #line, 0
  if not to_eol and right < eol then
    local last_col = vim.fn.virtcol2col(winid, row, right - 1) - 1
    end_col = character_end(line, last_col)
    -- With virtualedit, a tab's virtcol end can be the cursor cell. The next
    -- character's start still gives the full character boundary.
    local after_cells = vim.fn.virtcol({ row, end_col + 1 }, 1, winid)
    right_pad = after_cells[1] - right
  end

  return {
    row = row - 1,
    start_col = start_col,
    end_col = end_col,
    left_pad = left - start_cells[1],
    right_pad = right_pad,
  }
end

---Capture a block with native selection semantics, including $ and virtualedit.
---Registers, yank marks and the view are restored; the Visual selection is ended.
---@return table? selection
function M.capture()
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  local view = vim.fn.winsaveview()
  local registers = {}
  for _, name in ipairs({ 'z', '0', '"' }) do
    registers[name] = vim.fn.getreginfo(name)
  end
  local start_mark, end_mark = vim.fn.getpos("'["), vim.fn.getpos("']")

  local ok, selection = pcall(function()
    if vim.fn.mode() ~= '\22' then
      normal('gv')
    end
    local anchor, cursor = vim.fn.getpos('v'), vim.fn.getpos('.')
    local first_row, last_row = math.min(anchor[2], cursor[2]), math.max(anchor[2], cursor[2])
    local anchor_cells = vim.fn.virtcol({ anchor[2], anchor[3], anchor[4] }, 1)
    local cursor_cells = vim.fn.virtcol({ cursor[2], cursor[3], cursor[4] }, 1)
    local left = math.min(anchor_cells[1], cursor_cells[1])
    local to_eol = vim.fn.getcurpos()[5] == vim.v.maxcol

    normal('"zy')
    local source = vim.fn.getreg('z', 1, true)
    local width = tonumber(vim.fn.getregtype('z'):sub(2))
    if not width or width < 1 or #source ~= last_row - first_row + 1 then
      return nil
    end

    local rows = {}
    local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, first_row - 1, last_row, false)
    for index, line in ipairs(buffer_lines) do
      rows[index] = row_range(winid, first_row + index - 1, line, left, left + width, to_eol)
    end
    return { rows = rows, left = left, text = table.concat(source, '\n') }
  end)

  -- Restore the unnamed register last, including its points_to association.
  for _, name in ipairs({ 'z', '0', '"' }) do
    vim.fn.setreg(name, registers[name])
  end
  vim.fn.setpos("'[", start_mark)
  vim.fn.setpos("']", end_mark)
  vim.fn.winrestview(view)

  return ok and selection or nil
end

---Replace each selected row, preserving outside bytes and extmarks.
---@param bufnr number
---@param selection table
---@param result_lines string[]
function M.replace(bufnr, selection, result_lines)
  local edits = {}
  for index = #selection.rows, 1, -1 do
    local range = selection.rows[index]
    local text = result_lines[index] or ''
    if text ~= '' or range.start_col ~= range.end_col then
      text = string.rep(' ', range.left_pad) .. text .. string.rep(' ', range.right_pad)
      edits[#edits + 1] = { range = range, text = text }
    end
  end
  local extra = {}
  for index = #selection.rows + 1, #result_lines do
    extra[#extra + 1] = string.rep(' ', selection.left - 1) .. result_lines[index]
  end

  local changed = false
  local function join_undo()
    if changed then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd('undojoin')
      end)
    end
    changed = true
  end

  for _, edit in ipairs(edits) do
    local range = edit.range
    join_undo()
    vim.api.nvim_buf_set_text(
      bufnr,
      range.row,
      range.start_col,
      range.row,
      range.end_col,
      { edit.text }
    )
  end
  if #extra > 0 then
    join_undo()
    local after = selection.rows[#selection.rows].row + 1
    vim.api.nvim_buf_set_lines(bufnr, after, after, false, extra)
  end
end

return M
