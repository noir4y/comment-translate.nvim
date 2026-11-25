local M = {}

local buffer_revision = require('comment-translate.buffer_revision')

local hover_bufnr = nil
local hover_winid = nil

local manual_generation = 0

-- Both manual entry points share one generation and source context.
function M.begin_manual_request()
  manual_generation = manual_generation + 1
  local generation = manual_generation
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local same_revision = buffer_revision.capture(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  return function()
    return generation == manual_generation
      and vim.api.nvim_win_is_valid(winid)
      and vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_get_current_win() == winid
      and vim.api.nvim_get_current_buf() == bufnr
      and same_revision()
      and vim.deep_equal(vim.api.nvim_win_get_cursor(winid), cursor)
  end
end

function M.bufnr()
  return hover_bufnr
end

function M.winid()
  return hover_winid
end

function M.is_hover_window(winid)
  return hover_winid ~= nil and winid == hover_winid and vim.api.nvim_win_is_valid(hover_winid)
end

function M.is_hover_buffer(bufnr)
  return hover_bufnr ~= nil and bufnr == hover_bufnr and vim.api.nvim_buf_is_valid(hover_bufnr)
end

function M.close()
  local winid = hover_winid
  local bufnr = hover_bufnr
  hover_winid = nil
  hover_bufnr = nil

  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
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

  local popup_opts = vim.lsp.util.make_floating_popup_options(width, height, {
    relative = 'cursor',
    anchor_bias = 'below',
    offset_x = 2,
    border = opts.border or 'rounded',
    focusable = true,
    zindex = 50,
  })
  -- The standard helper can return zero height for a very short split.
  popup_opts.width = math.max(1, popup_opts.width)
  popup_opts.height = math.max(1, popup_opts.height)
  hover_winid = vim.api.nvim_open_win(hover_bufnr, false, popup_opts)

  vim.wo[hover_winid].wrap = true
  vim.wo[hover_winid].number = false
  vim.wo[hover_winid].relativenumber = false
  vim.wo[hover_winid].cursorline = false
  vim.wo[hover_winid].winhighlight = 'Normal:NormalFloat'
end

return M
