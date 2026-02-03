local M = {}

local hover_bufnr = nil
local hover_winid = nil

function M.bufnr()
  return hover_bufnr
end

function M.close()
  if hover_winid and vim.api.nvim_win_is_valid(hover_winid) then
    vim.api.nvim_win_close(hover_winid, true)
    hover_winid = nil
  end
  if hover_bufnr and vim.api.nvim_buf_is_valid(hover_bufnr) then
    vim.api.nvim_buf_delete(hover_bufnr, { force = true })
    hover_bufnr = nil
  end
end

---@param text string
---@param opts? table
function M.show(text, opts)
  opts = opts or {}

  M.close()

  if not text or text == '' then
    return
  end

  local lines = vim.split(text, '\n')
  if #lines == 0 then
    return
  end

  hover_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(hover_bufnr, 0, -1, false, lines)
  vim.bo[hover_bufnr].filetype = 'markdown'
  vim.bo[hover_bufnr].buftype = 'nofile'

  local max_width = math.floor(vim.o.columns * 0.8)
  local max_height = math.floor(vim.o.lines * 0.6)

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, max_width)

  local height = math.min(#lines, max_height)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local win_height = vim.api.nvim_win_get_height(0)
  local win_width = vim.api.nvim_win_get_width(0)

  local col = math.min(cursor[2] + 2, win_width - width - 1)
  local row = cursor[1]

  if row + height + 1 > win_height then
    row = row - height - 1
    if row < 0 then
      row = 0
    end
  else
    row = row + 1
  end

  hover_winid = vim.api.nvim_open_win(hover_bufnr, false, {
    relative = 'win',
    row = row,
    col = col,
    width = width,
    height = height,
    style = 'minimal',
    border = opts.border or 'rounded',
    zindex = 50,
  })

  vim.wo[hover_winid].wrap = true
  vim.wo[hover_winid].number = false
  vim.wo[hover_winid].relativenumber = false
  vim.wo[hover_winid].cursorline = false
  vim.wo[hover_winid].winhighlight = 'Normal:NormalFloat'
end

return M
