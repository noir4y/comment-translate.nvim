local M = {}

local config = require('comment-translate.config')
local parser = require('comment-translate.parser')
local translate = require('comment-translate.translate')
local ui = require('comment-translate.ui')

local immersive_state = {}
local immersive_global_enabled = false

local function normalize_bufnr(bufnr)
  if type(bufnr) ~= 'number' then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function get_state(bufnr)
  bufnr = normalize_bufnr(bufnr)

  if not immersive_state[bufnr] then
    immersive_state[bufnr] = {
      enabled = false,
      token = 0,
    }
  end

  return immersive_state[bufnr]
end

local function bump_token(state)
  state.token = (state.token or 0) + 1
  return state.token
end

---@return boolean
function M.is_immersive_enabled(bufnr)
  return get_state(bufnr).enabled
end

---@return boolean
function M.is_immersive_globally_enabled()
  return immersive_global_enabled
end

function M.init_immersive_globally()
  immersive_global_enabled = true
  local bufnr = vim.api.nvim_get_current_buf()
  M.enable_immersive(bufnr)
end

---@param bufnr? number
function M.enable_immersive(bufnr)
  bufnr = normalize_bufnr(bufnr)
  local state = get_state(bufnr)

  if state.enabled then
    return
  end

  state.enabled = true
  bump_token(state)
  M.update_immersive(bufnr)
end

---@param bufnr number
function M.cleanup_buffer(bufnr)
  if immersive_state[bufnr] then
    immersive_state[bufnr] = nil
  end
end

function M.hover_translate()
  local text, _ = parser.get_text_at_cursor()
  if not text then
    ui.hover.close()
    vim.notify('No comment or string found', vim.log.levels.INFO)
    return
  end

  translate.translate(text, nil, nil, function(result)
    if result then
      ui.hover.show(result)
    else
      vim.notify('Translation failed', vim.log.levels.ERROR)
    end
  end)
end

function M.toggle_auto_hover()
  if not config.config.hover.enabled then
    vim.notify('Auto hover is disabled in config (hover.enabled = false)', vim.log.levels.WARN)
    return
  end

  config.config.hover.auto = not config.config.hover.auto
  if config.config.hover.auto then
    vim.notify('Auto hover enabled', vim.log.levels.INFO)
  else
    ui.hover.close()
    vim.notify('Auto hover disabled', vim.log.levels.INFO)
  end
end

---@return number bufnr
---@return number start_line (0-based)
---@return number start_col (0-based)
---@return number end_line (0-based)
---@return number end_col (exclusive, 0-based)
---@return boolean success
local function get_visual_selection_range()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()

  if mode:match('[vV\22]') then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  end

  local start_pos = vim.api.nvim_buf_get_mark(bufnr, '<')
  local end_pos = vim.api.nvim_buf_get_mark(bufnr, '>')

  local start_line = start_pos[1] - 1
  local start_col = start_pos[2]
  local end_line = end_pos[1] - 1
  local end_col = end_pos[2]

  if start_line < 0 or end_line < 0 then
    return bufnr, 0, 0, 0, 0, false
  end

  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end

  local end_line_content = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1] or ''
  local end_col_excl = math.min(end_col + 1, #end_line_content)

  if end_col >= #end_line_content then
    end_col_excl = #end_line_content
  end

  return bufnr, start_line, start_col, end_line, end_col_excl, true
end

function M.replace_selection()
  local bufnr, start_line, start_col, end_line, end_col_excl, success = get_visual_selection_range()

  if not success then
    vim.notify('No text selected', vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_text(bufnr, start_line, start_col, end_line, end_col_excl, {})
  if #lines == 0 then
    vim.notify('No text selected', vim.log.levels.WARN)
    return
  end

  local text = table.concat(lines, '\n')

  if not text or text == '' then
    vim.notify('Selected text is empty', vim.log.levels.WARN)
    return
  end

  translate.translate(text, nil, nil, function(result)
    if not result then
      vim.notify('Translation failed', vim.log.levels.ERROR)
      return
    end

    local result_lines = vim.split(result, '\n', { plain = true })
    vim.api.nvim_buf_set_text(bufnr, start_line, start_col, end_line, end_col_excl, result_lines)

    vim.notify('Replaced with translation', vim.log.levels.INFO)
  end)
end

---@private
local function disable_all_buffers()
  ui.virtual_text.clear_all()

  for _, state in pairs(immersive_state) do
    state.enabled = false
    bump_token(state)
  end
end

function M.toggle_immersive(bufnr)
  bufnr = normalize_bufnr(bufnr)
  local state = get_state(bufnr)

  local new_enabled = not state.enabled
  immersive_global_enabled = new_enabled

  if new_enabled then
    state.enabled = true
    bump_token(state)
    M.update_immersive(bufnr)
    vim.notify('Immersive translation enabled (globally)', vim.log.levels.INFO)
  else
    disable_all_buffers()
    vim.notify('Immersive translation disabled (globally)', vim.log.levels.INFO)
  end
end

function M.update_immersive(bufnr)
  bufnr = normalize_bufnr(bufnr)
  local state = get_state(bufnr)

  if not state.enabled then
    return
  end

  local token = bump_token(state)
  ui.virtual_text.clear_buf(bufnr)

  local comments = parser.get_all_comments(bufnr)
  local items = {}

  for line, text in pairs(comments) do
    if text and text ~= '' then
      table.insert(items, { line = line, text = text })
    end
  end

  table.sort(items, function(a, b)
    return a.line < b.line
  end)

  local total = #items
  if total == 0 then
    -- Use DEBUG level to avoid noise when navigating files without comments
    vim.notify('No comments found', vim.log.levels.DEBUG)
    return
  end

  local index = 1

  local function process_next()
    if token ~= state.token then
      return
    end

    local item = items[index]
    if not item then
      return
    end

    translate.translate(item.text, nil, nil, function(result)
      if token ~= state.token then
        return
      end

      if result and result ~= '' then
        ui.virtual_text.show(bufnr, item.line, result)
      end

      index = index + 1

      if index <= total then
        process_next()
      end
    end)
  end

  process_next()
end

function M.hover_translate_on_demand()
  local autocmds = require('comment-translate.autocmds')
  autocmds.show_hover_on_demand()
end

local function setup_plug_mappings()
  vim.keymap.set('n', '<Plug>(comment-translate-hover)', M.hover_translate, {
    desc = 'Comment Translate: Hover',
    silent = true,
  })

  vim.keymap.set('n', '<Plug>(comment-translate-hover-manual)', M.hover_translate_on_demand, {
    desc = 'Comment Translate: Hover (manual)',
    silent = true,
  })

  vim.keymap.set('x', '<Plug>(comment-translate-replace)', M.replace_selection, {
    desc = 'Comment Translate: Replace selection',
    silent = true,
  })

  vim.keymap.set('n', '<Plug>(comment-translate-toggle)', M.toggle_immersive, {
    desc = 'Comment Translate: Toggle immersive',
    silent = true,
  })

  vim.keymap.set('n', '<Plug>(comment-translate-update)', M.update_immersive, {
    desc = 'Comment Translate: Update immersive',
    silent = true,
  })
end

function M.setup()
  vim.api.nvim_create_user_command('CommentTranslateHover', M.hover_translate, {
    desc = 'Translate comment/string at cursor',
    force = true,
  })

  vim.api.nvim_create_user_command('CommentTranslateReplace', M.replace_selection, {
    desc = 'Replace selected text with translation',
    range = true,
    force = true,
  })

  vim.api.nvim_create_user_command('CommentTranslateToggle', M.toggle_immersive, {
    desc = 'Toggle immersive translation ON/OFF',
    force = true,
  })

  vim.api.nvim_create_user_command('CommentTranslateUpdate', M.update_immersive, {
    desc = 'Update immersive translation',
    force = true,
  })

  vim.api.nvim_create_user_command('CommentTranslateHoverToggle', M.toggle_auto_hover, {
    desc = 'Toggle auto hover ON/OFF',
    force = true,
  })

  setup_plug_mappings()

  local keymaps = config.config.keymaps or {}

  if keymaps.hover and keymaps.hover ~= false then
    vim.keymap.set('n', keymaps.hover, '<Plug>(comment-translate-hover)', {
      desc = 'Comment Translate: Hover',
      remap = true,
    })
  end

  if keymaps.replace and keymaps.replace ~= false then
    vim.keymap.set('x', keymaps.replace, '<Plug>(comment-translate-replace)', {
      desc = 'Comment Translate: Replace',
      remap = true,
    })
  end

  if keymaps.toggle and keymaps.toggle ~= false then
    vim.keymap.set('n', keymaps.toggle, '<Plug>(comment-translate-toggle)', {
      desc = 'Comment Translate: Toggle',
      remap = true,
    })
  end

  if keymaps.hover_manual and keymaps.hover_manual ~= false then
    vim.keymap.set('n', keymaps.hover_manual, '<Plug>(comment-translate-hover-manual)', {
      desc = 'Comment Translate: Hover (manual)',
      remap = true,
    })
  end
end

return M
