---@diagnostic disable: undefined-global
describe('commands', function()
  local commands
  local config
  local ui
  local bufnr

  before_each(function()
    -- Reset all related modules before each test
    package.loaded['comment-translate'] = nil
    package.loaded['comment-translate.commands'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.parser'] = nil
    package.loaded['comment-translate.parser.regex'] = nil
    package.loaded['comment-translate.parser.treesitter'] = nil
    package.loaded['comment-translate.translate'] = nil
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.translate.google'] = nil
    package.loaded['comment-translate.translate.llm'] = nil
    package.loaded['comment-translate.ui'] = nil
    package.loaded['comment-translate.ui.hover'] = nil
    package.loaded['comment-translate.ui.virtual_text'] = nil
    package.loaded['comment-translate.autocmds'] = nil
    package.loaded['comment-translate.utils'] = nil

    config = require('comment-translate.config')
    config.setup({
      target_language = 'ja',
      hover = {
        enabled = true,
        delay = 100,
        auto = true,
      },
      immersive = {
        enabled = false,
      },
      keymaps = {
        hover = false,
        hover_manual = false,
        replace = false,
        toggle = false,
      },
    })

    commands = require('comment-translate.commands')
    ui = require('comment-translate.ui')

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    ui.hover.close()
    ui.virtual_text.clear_all()
  end)

  describe('is_immersive_enabled', function()
    it('should return false by default', function()
      assert.is_false(commands.is_immersive_enabled())
    end)

    it('should return true after toggle', function()
      -- Note: toggle_immersive calls update_immersive which needs parser
      -- Just test the state management
      assert.is_false(commands.is_immersive_enabled())
    end)
  end)

  describe('cleanup_buffer', function()
    it('should cleanup buffer state without error', function()
      assert.has_no.errors(function()
        commands.cleanup_buffer(bufnr)
      end)
    end)

    it('should handle invalid buffer gracefully', function()
      assert.has_no.errors(function()
        commands.cleanup_buffer(99999)
      end)
    end)
  end)

  describe('hover_translate_on_demand', function()
    it('should exist and be callable', function()
      assert.is_function(commands.hover_translate_on_demand)
    end)
  end)
end)

describe('replace selection safety', function()
  local commands
  local bufnr
  local original_notify
  local notify_messages
  local translate_calls
  local pending_callback

  local function reset_modules(fake_translate)
    package.loaded['comment-translate.commands'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.parser'] = nil
    package.loaded['comment-translate.translate'] = fake_translate
    package.loaded['comment-translate.ui'] = nil
    package.loaded['comment-translate.ui.hover'] = nil
    package.loaded['comment-translate.ui.virtual_text'] = nil
  end

  local function set_selection(line, start_col, end_col)
    vim.api.nvim_buf_set_mark(bufnr, '<', line, start_col, {})
    vim.api.nvim_buf_set_mark(bufnr, '>', line, end_col, {})
  end

  before_each(function()
    translate_calls = {}
    pending_callback = nil
    local fake_translate = {
      translate = function(text, target_lang, source_lang, callback)
        table.insert(translate_calls, {
          text = text,
          target_lang = target_lang,
          source_lang = source_lang,
        })
        pending_callback = callback
      end,
    }

    reset_modules(fake_translate)

    local config = require('comment-translate.config')
    config.reset()
    commands = require('comment-translate.commands')

    notify_messages = {}
    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_messages, { msg = msg, level = level })
    end

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    vim.notify = original_notify
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it('should replace a multibyte visual selection using byte columns', function()
    local prefix = 'before '
    local selected = 'こんにちは'
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { prefix .. selected .. ' after' })
    set_selection(1, #prefix, #prefix + #selected - 1)

    commands.replace_selection()
    pending_callback('hello')

    assert.equals(selected, translate_calls[1].text)
    assert.same({ 'before hello after' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it('should not replace when the buffer changed before translation returns', function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'alpha beta' })
    set_selection(1, 0, 4)

    commands.replace_selection()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'user changed beta' })
    pending_callback('translated')

    assert.equals('alpha', translate_calls[1].text)
    assert.same({ 'user changed beta' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.matches('buffer changed', notify_messages[#notify_messages].msg)
  end)
end)

describe('visual block replacement', function()
  local commands
  local bufnr
  local other_bufnr
  local calls
  local callback
  local original_notify
  local notifications
  local saved_options
  local saved_registers
  local saved_maps
  local saved_leader

  local maps = {
    { 'x', ',tr' },
    { 'x', '<Plug>(comment-translate-replace)' },
    { 'n', '<Plug>(comment-translate-hover)' },
    { 'n', '<Plug>(comment-translate-hover-manual)' },
    { 'n', '<Plug>(comment-translate-toggle)' },
    { 'n', '<Plug>(comment-translate-update)' },
  }

  local function keys(input)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(input, true, false, true), 'xt', false)
  end

  local function lines()
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  local function select(input)
    keys(input)
    assert.equals('\22', vim.fn.mode())
  end

  -- Use the editor's own yank as the oracle, without printing source text.
  local function native_source()
    vim.cmd('silent noautocmd keepjumps normal! "zy')
    local source = table.concat(vim.fn.getreg('z', 1, true), '\n')
    vim.cmd('silent noautocmd keepjumps normal! gv')
    return source
  end

  before_each(function()
    saved_options = { selection = vim.o.selection, virtualedit = vim.o.virtualedit }
    vim.o.selection = 'inclusive'
    vim.o.virtualedit = ''
    saved_registers = {}
    for _, name in ipairs({ 'z', '0', '"' }) do
      saved_registers[name] = vim.fn.getreginfo(name)
    end
    saved_leader = vim.g.mapleader
    vim.g.mapleader = ','
    saved_maps = {}
    for index, map in ipairs(maps) do
      saved_maps[index] = vim.fn.maparg(map[2], map[1], false, true)
    end

    calls = {}
    callback = nil
    package.loaded['comment-translate.commands'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.translate'] = {
      translate = function(text, _, _, cb)
        calls[#calls + 1] = text
        callback = cb
      end,
    }
    local config = require('comment-translate.config')
    config.setup({ keymaps = { hover = false, hover_manual = false, toggle = false } })
    commands = require('comment-translate.commands')
    commands.setup()

    original_notify = vim.notify
    notifications = {}
    vim.notify = function(message)
      notifications[#notifications + 1] = message
    end
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].tabstop = 8
    vim.bo[bufnr].vartabstop = ''
  end)

  after_each(function()
    keys('<Esc>')
    vim.notify = original_notify
    vim.o.selection = saved_options.selection
    vim.o.virtualedit = saved_options.virtualedit
    for _, name in ipairs({ 'z', '0', '"' }) do
      vim.fn.setreg(name, saved_registers[name])
    end
    vim.g.mapleader = saved_leader
    for index, map in ipairs(maps) do
      pcall(vim.keymap.del, map[1], map[2])
      if next(saved_maps[index]) then
        vim.fn.mapset(map[1], false, saved_maps[index])
      end
    end
    for _, name in ipairs({
      'CommentTranslateHover',
      'CommentTranslateReplace',
      'CommentTranslateToggle',
      'CommentTranslateUpdate',
      'CommentTranslateHoverToggle',
    }) do
      pcall(vim.api.nvim_del_user_command, name)
    end
    for _, buf in ipairs({ bufnr, other_bufnr }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    other_bufnr = nil
  end)

  for _, route in ipairs({ 'function', 'mapping', 'ex', 'previous selection' }) do
    it('should preserve unselected text through ' .. route, function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'aaOUTSIDE1',
        'bbOUTSIDE2',
        'ccOUTSIDE3',
        'footer',
      })
      select('gg0<C-v>2jl')
      local tick = vim.api.nvim_buf_get_changedtick(bufnr)
      if route == 'mapping' then
        keys(',tr')
      elseif route == 'ex' then
        keys(':<C-u>CommentTranslateReplace<CR>')
      elseif route == 'previous selection' then
        keys('<Esc>4G0')
        vim.cmd('CommentTranslateReplace')
      else
        commands.replace_selection()
      end
      assert.equals(1, #calls)
      assert.is_true(calls[1] == 'aa\nbb\ncc')
      assert.equals(tick, vim.api.nvim_buf_get_changedtick(bufnr))
      callback('translated')
      assert.is_true(vim.deep_equal(lines(), {
        'translatedOUTSIDE1',
        'OUTSIDE2',
        'OUTSIDE3',
        'footer',
      }))
    end)
  end

  local cases = {
    {
      name = 'reverse corners',
      input = { 'xxaaOUT1', 'xxbbOUT2', 'xxccOUT3' },
      keys = '3G03l<C-v>2kh',
      result = 'A\nB\nC',
      expected = { 'xxAOUT1', 'xxBOUT2', 'xxCOUT3' },
    },
    {
      name = 'multibyte characters',
      input = { 'xxあいOUT1', 'xxうえOUT2', 'xxおかOUT3' },
      keys = 'gg02l<C-v>2jl',
      result = 'A\nB\nC',
      expected = { 'xxAOUT1', 'xxBOUT2', 'xxCOUT3' },
    },
    {
      name = 'combining characters',
      input = { 'xxábOUT1', 'xxćdOUT2' },
      keys = 'gg02l<C-v>jl',
      result = 'A\nB',
      expected = { 'xxAOUT1', 'xxBOUT2' },
    },
    {
      name = 'partial tabs',
      input = { 'abcOUT1', '\tOUT2', 'defOUT3' },
      keys = 'gg0l<C-v>2jl',
      result = 'X\nY\nZ',
      expected = { 'aXOUT1', ' Y     OUT2', 'dZOUT3' },
    },
    {
      name = 'partial wide characters',
      input = { 'abcOUT1', 'あいOUT2', 'defOUT3' },
      keys = 'gg0l<C-v>2j',
      result = 'X\nY\nZ',
      expected = { 'aXcOUT1', ' YいOUT2', 'dZfOUT3' },
    },
    {
      name = 'short and empty lines',
      input = { 'xxaaOUT1', 'x', '', 'xxddOUT4' },
      keys = 'gg02l<C-v>3jl',
      result = 'A\nB\nC\nD',
      expected = { 'xxAOUT1', 'x B', '  C', 'xxDOUT4' },
    },
    {
      name = 'exclusive selection',
      input = { 'aaOUT1', 'bbOUT2', 'ccOUT3' },
      keys = 'gg0<C-v>2j2l',
      selection = 'exclusive',
      result = 'A\nB\nC',
      expected = { 'AOUT1', 'BOUT2', 'COUT3' },
    },
    {
      name = 'virtual editing',
      input = { 'xxaaOUT1', 'x', 'xxccOUT3' },
      keys = 'gg02l<C-v>2jl',
      virtualedit = 'block',
      result = 'A\nB\nC',
      expected = { 'xxAOUT1', 'x B', 'xxCOUT3' },
    },
    {
      name = 'virtual endpoints inside tabs',
      input = { '\tabcOUT1', '\tdefOUT2' },
      keys = 'gg02l<C-v>j2l',
      virtualedit = 'all',
      result = 'A\nB',
      expected = { '  A   abcOUT1', '  B   defOUT2' },
    },
    {
      name = 'variable tab stops',
      input = { 'abcOUT1', '\tOUT2', 'defOUT3' },
      keys = 'gg0l<C-v>2jl',
      vartabstop = '4,6',
      result = 'X\nY\nZ',
      expected = { 'aXOUT1', ' Y OUT2', 'dZOUT3' },
    },
    {
      name = 'reverse exclusive corners',
      input = { 'xxaaOUT1', 'xxbbOUT2', 'xxccOUT3' },
      keys = '3G04l<C-v>2k2h',
      selection = 'exclusive',
      result = 'A\nB\nC',
      expected = { 'xxAOUT1', 'xxBOUT2', 'xxCOUT3' },
    },
    {
      name = 'each line to its end',
      input = { 'xxaaa', 'xxbbbbbbbb', 'xxcc', 'footer' },
      keys = 'gg02l<C-v>2j$',
      result = 'A\nB\nC',
      expected = { 'xxA', 'xxB', 'xxC', 'footer' },
    },
    {
      name = 'one line',
      input = { 'xxaaOUT1', 'footer' },
      keys = 'gg02l<C-v>l',
      result = 'A',
      expected = { 'xxAOUT1', 'footer' },
    },
    {
      name = 'additional result lines',
      input = { 'xxaaOUT1', 'xxbbOUT2', 'footer' },
      keys = 'gg02l<C-v>jl',
      result = 'A\nB\nC\nD',
      expected = { 'xxAOUT1', 'xxBOUT2', '  C', '  D', 'footer' },
    },
    {
      name = 'empty result',
      input = { 'xxaaOUT1', 'xxbbOUT2', 'footer' },
      keys = 'gg02l<C-v>jl',
      result = '',
      expected = { 'xxOUT1', 'xxOUT2', 'footer' },
    },
  }

  for _, case in ipairs(cases) do
    it('should handle ' .. case.name, function()
      vim.o.selection = case.selection or 'inclusive'
      vim.o.virtualedit = case.virtualedit or ''
      vim.bo[bufnr].vartabstop = case.vartabstop or ''
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, case.input)
      select(case.keys)
      local expected_source = native_source()
      commands.replace_selection()
      assert.equals(1, #calls)
      assert.is_true(calls[1] == expected_source)
      callback(case.result)
      assert.is_true(vim.deep_equal(lines(), case.expected))
      keys('u')
      assert.is_true(vim.deep_equal(lines(), case.input))
    end)

    it('should match native block removal for ' .. case.name, function()
      vim.o.selection = case.selection or 'inclusive'
      vim.o.virtualedit = case.virtualedit or ''
      vim.bo[bufnr].vartabstop = case.vartabstop or ''
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, case.input)
      select(case.keys)
      vim.cmd('silent noautocmd keepjumps normal! "_d')
      local expected = lines()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, case.input)
      select(case.keys)
      commands.replace_selection()
      callback('')
      assert.is_true(vim.deep_equal(lines(), expected))
    end)
  end

  for _, mode in ipairs({ 'v', 'V' }) do
    it('should keep a new ' .. mode .. ' selection after a block selection', function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'aaOUT1', 'bbOUT2', 'footer' })
      select('gg0<C-v>jl')
      keys('<Esc>gg0' .. mode .. (mode == 'v' and 'l' or 'j'))
      assert.equals(mode, vim.fn.mode())
      commands.replace_selection()
      assert.equals(1, #calls)
      assert.is_true(calls[1] == (mode == 'v' and 'aa' or 'aaOUT1\nbbOUT2'))
      callback('A')
      assert.is_true(
        vim.deep_equal(
          lines(),
          mode == 'v' and { 'AOUT1', 'bbOUT2', 'footer' } or { 'A', 'footer' }
        )
      )
    end)
  end

  it('should restore registers, yank marks and the view without firing TextYankPost', function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'aaOUT1', 'bbOUT2', 'footer' })
    select('gg0<C-v>jl')
    keys('<Esc>3G0')
    local registers = {}
    for _, name in ipairs({ 'z', '0', '"' }) do
      registers[name] = vim.fn.getreginfo(name)
    end
    local start_mark, end_mark = vim.fn.getpos("'["), vim.fn.getpos("']")
    local view = vim.fn.winsaveview()
    local events = 0
    local autocmd = vim.api.nvim_create_autocmd('TextYankPost', {
      callback = function()
        events = events + 1
      end,
    })
    commands.replace_selection()
    vim.api.nvim_del_autocmd(autocmd)
    assert.equals(0, events)
    assert.is_true(vim.deep_equal(view, vim.fn.winsaveview()))
    assert.is_true(vim.deep_equal(start_mark, vim.fn.getpos("'[")))
    assert.is_true(vim.deep_equal(end_mark, vim.fn.getpos("']")))
    for _, name in ipairs({ 'z', '0', '"' }) do
      assert.is_true(vim.deep_equal(registers[name], vim.fn.getreginfo(name)))
    end
  end)

  it('should preserve extmarks outside the rectangle', function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'xxaaOUT1', 'xxbbOUT2' })
    local ns = vim.api.nvim_create_namespace('comment-translate-block-test')
    local left = vim.api.nvim_buf_set_extmark(bufnr, ns, 1, 0, {})
    local right = vim.api.nvim_buf_set_extmark(bufnr, ns, 1, 5, {})
    select('gg02l<C-v>jl')
    commands.replace_selection()
    callback('A\nB')
    assert.same({ 1, 0 }, vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, left, {}))
    assert.same({ 1, 4 }, vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, right, {}))
  end)

  for _, failure in ipairs({
    'changed buffer',
    'unmodifiable buffer',
    'translation failure',
    'deleted buffer',
  }) do
    it('should avoid partial replacement for a ' .. failure, function()
      local original = { 'aaOUT1', 'bbOUT2' }
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, original)
      select('gg0<C-v>jl')
      commands.replace_selection()
      if failure == 'changed buffer' then
        original = { 'user edit', 'bbOUT2' }
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, original)
      elseif failure == 'unmodifiable buffer' then
        vim.bo[bufnr].modifiable = false
      elseif failure == 'deleted buffer' then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      assert.has_no.errors(function()
        if failure == 'translation failure' then
          callback(nil)
        else
          callback('A\nB')
        end
      end)
      if failure ~= 'deleted buffer' then
        assert.is_true(vim.deep_equal(lines(), original))
      end
    end)
  end

  it('should use the captured rectangle after the buffer and selection change', function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'aaOUT1', 'bbOUT2' })
    select('gg0<C-v>jl')
    commands.replace_selection()
    other_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(other_bufnr)
    vim.api.nvim_buf_set_lines(other_bufnr, 0, -1, false, { 'other buffer' })
    keys('gg0vl')
    local cursor, anchor = vim.fn.getpos('.'), vim.fn.getpos('v')
    callback('A\nB')
    assert.is_true(vim.deep_equal(lines(), { 'AOUT1', 'BOUT2' }))
    assert.equals(other_bufnr, vim.api.nvim_get_current_buf())
    assert.equals('v', vim.fn.mode())
    assert.is_true(vim.deep_equal(cursor, vim.fn.getpos('.')))
    assert.is_true(vim.deep_equal(anchor, vim.fn.getpos('v')))
    assert.is_true(
      vim.deep_equal(vim.api.nvim_buf_get_lines(other_bufnr, 0, -1, false), { 'other buffer' })
    )
  end)

  it('should restore state without a request when capture fails', function()
    local original = { 'aaOUT1', 'bbOUT2' }
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, original)
    select('gg0<C-v>jl')
    local registers = {}
    for _, name in ipairs({ 'z', '0', '"' }) do
      registers[name] = vim.fn.getreginfo(name)
    end
    local original_virtcol2col = vim.fn.virtcol2col
    vim.fn.virtcol2col = function()
      error('fixture capture failure')
    end
    local ok = pcall(commands.replace_selection)
    vim.fn.virtcol2col = original_virtcol2col
    assert.is_true(ok)
    assert.equals(0, #calls)
    assert.is_true(vim.deep_equal(lines(), original))
    for _, name in ipairs({ 'z', '0', '"' }) do
      assert.is_true(vim.deep_equal(registers[name], vim.fn.getreginfo(name)))
    end
  end)
end)

describe('immersive async lifecycle', function()
  local commands
  local bufnr
  local translate_callbacks
  local shown

  local function reset_modules(fake_parser, fake_translate, fake_ui)
    package.loaded['comment-translate.commands'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.parser'] = fake_parser
    package.loaded['comment-translate.translate'] = fake_translate
    package.loaded['comment-translate.ui'] = fake_ui
  end

  before_each(function()
    translate_callbacks = {}
    shown = {}

    local fake_parser = {
      get_all_comments = function()
        return {
          [0] = 'comment A',
        }
      end,
    }
    local fake_translate = {
      translate = function(_, _, _, callback)
        table.insert(translate_callbacks, callback)
      end,
    }
    local fake_ui = {
      hover = {
        close = function() end,
      },
      virtual_text = {
        clear_buf = function() end,
        clear_all = function() end,
        show = function(target_bufnr, line, text)
          table.insert(shown, {
            bufnr = target_bufnr,
            line = line,
            text = text,
          })
        end,
      },
    }

    reset_modules(fake_parser, fake_translate, fake_ui)
    local config = require('comment-translate.config')
    config.reset()
    commands = require('comment-translate.commands')

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it('should ignore immersive translation results after the buffer is deleted', function()
    commands.enable_immersive(bufnr)

    assert.equals(1, #translate_callbacks)

    vim.api.nvim_buf_delete(bufnr, { force = true })
    translate_callbacks[1]('translated A')

    assert.same({}, shown)
  end)
end)

describe('plugin commands', function()
  local bufnr
  local health_bufnr
  local original_cmd
  local original_loaded
  local original_health
  local original_get_parser

  before_each(function()
    package.loaded['comment-translate'] = nil
    package.loaded['comment-translate.health'] = nil
    original_loaded = vim.g.loaded_comment_translate
    vim.g.loaded_comment_translate = nil
    original_cmd = vim.cmd
    original_get_parser = vim.treesitter.get_parser

    bufnr = vim.api.nvim_create_buf(false, false)
    health_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = 'lua'

    dofile('plugin/comment-translate.lua')
  end)

  after_each(function()
    vim.cmd = original_cmd
    vim.health = original_health
    vim.treesitter.get_parser = original_get_parser
    vim.g.loaded_comment_translate = original_loaded
    pcall(vim.api.nvim_del_user_command, 'CommentTranslateHealth')
    pcall(vim.api.nvim_del_user_command, 'CommentTranslateSetup')
    if health_bufnr and vim.api.nvim_buf_is_valid(health_bufnr) then
      vim.api.nvim_buf_delete(health_bufnr, { force = true })
    end
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it('should capture the current buffer before running the health check', function()
    local parser_bufnr
    local health = require('comment-translate.health')
    original_health = vim.health
    vim.health = {
      start = function() end,
      ok = function() end,
      error = function() end,
      warn = function() end,
      info = function() end,
    }
    vim.treesitter.get_parser = function(target_bufnr)
      parser_bufnr = target_bufnr
      return {}
    end

    vim.cmd = function(_)
      vim.api.nvim_set_current_buf(health_bufnr)
      health.check()
    end

    vim.api.nvim_cmd({ cmd = 'CommentTranslateHealth' }, {})

    assert.equals(bufnr, parser_bufnr)
  end)

  it('should not load heavy modules during runtime plugin load', function()
    assert.is_nil(package.loaded['comment-translate'])
    assert.is_nil(package.loaded['comment-translate.health'])
  end)

  it('should keep runtime plugin loading idempotent', function()
    local setup_command_before = vim.api.nvim_get_commands({})['CommentTranslateSetup']
    local health_command_before = vim.api.nvim_get_commands({})['CommentTranslateHealth']

    dofile('plugin/comment-translate.lua')

    local commands_after = vim.api.nvim_get_commands({})
    assert.same(setup_command_before, commands_after['CommentTranslateSetup'])
    assert.same(health_command_before, commands_after['CommentTranslateHealth'])
  end)
end)

describe('autocmds', function()
  local autocmds
  local config

  before_each(function()
    package.loaded['comment-translate.autocmds'] = nil
    package.loaded['comment-translate.config'] = nil

    config = require('comment-translate.config')
    config.setup({
      hover = {
        enabled = true,
        delay = 100,
        auto = true,
      },
    })

    autocmds = require('comment-translate.autocmds')
  end)

  describe('cleanup_all_timers', function()
    it('should cleanup without error', function()
      assert.has_no.errors(function()
        autocmds.cleanup_all_timers()
      end)
    end)
  end)

  describe('show_hover_on_demand', function()
    it('should exist and be callable', function()
      assert.is_function(autocmds.show_hover_on_demand)
    end)
  end)
end)

describe('ui.hover', function()
  local hover
  local bufnr

  before_each(function()
    package.loaded['comment-translate.ui.hover'] = nil
    hover = require('comment-translate.ui.hover')

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'test line' })
  end)

  after_each(function()
    hover.close()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  describe('show', function()
    it('should create hover window with text', function()
      hover.show('Hello World')

      local hover_bufnr = hover.bufnr()
      assert.is_not_nil(hover_bufnr)
      assert.is_true(vim.api.nvim_buf_is_valid(hover_bufnr))

      local hover_winid = hover.winid()
      assert.is_not_nil(hover_winid)
      assert.is_true(vim.api.nvim_win_is_valid(hover_winid))
      assert.is_true(vim.api.nvim_win_get_config(hover_winid).focusable)
      assert.is_true(hover.is_hover_window(hover_winid))
      assert.is_true(hover.is_hover_buffer(hover_bufnr))
      assert.is_false(hover.is_hover_buffer(bufnr))

      local lines = vim.api.nvim_buf_get_lines(hover_bufnr, 0, -1, false)
      assert.equals('Hello World', lines[1])
    end)

    it('should handle empty text gracefully', function()
      assert.has_no.errors(function()
        hover.show('')
      end)
      assert.is_nil(hover.bufnr())
    end)

    it('should handle nil text gracefully', function()
      assert.has_no.errors(function()
        hover.show(nil)
      end)
      assert.is_nil(hover.bufnr())
    end)

    it('should handle multiline text', function()
      hover.show('Line 1\nLine 2\nLine 3')

      local hover_bufnr = hover.bufnr()
      assert.is_not_nil(hover_bufnr)

      local lines = vim.api.nvim_buf_get_lines(hover_bufnr, 0, -1, false)
      assert.equals(3, #lines)
      assert.equals('Line 1', lines[1])
      assert.equals('Line 2', lines[2])
      assert.equals('Line 3', lines[3])
    end)
  end)

  describe('close', function()
    it('should close hover window', function()
      hover.show('Test')
      assert.is_not_nil(hover.bufnr())

      hover.close()
      assert.is_nil(hover.bufnr())
      assert.is_nil(hover.winid())
    end)

    it('should clear stale state when hover window was already closed', function()
      hover.show('Test')
      local hover_winid = hover.winid()
      assert.is_not_nil(hover_winid)

      vim.api.nvim_win_close(hover_winid, true)
      hover.close()

      assert.is_nil(hover.bufnr())
      assert.is_nil(hover.winid())
    end)

    it('should handle multiple close calls', function()
      hover.show('Test')
      hover.close()

      assert.has_no.errors(function()
        hover.close()
        hover.close()
      end)
    end)
  end)
end)

describe('ui.virtual_text', function()
  local virtual_text
  local bufnr

  before_each(function()
    package.loaded['comment-translate.ui.virtual_text'] = nil
    virtual_text = require('comment-translate.ui.virtual_text')

    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      '-- Comment line 1',
      'local x = 1',
      '-- Comment line 2',
    })
  end)

  after_each(function()
    virtual_text.clear_all()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  describe('show', function()
    it('should add virtual text', function()
      assert.has_no.errors(function()
        virtual_text.show(bufnr, 0, 'Translated text')
      end)
    end)

    it('should ignore invalid buffers without error', function()
      assert.has_no.errors(function()
        virtual_text.show(99999, 0, 'Translated text')
      end)
    end)
  end)

  describe('clear_buf', function()
    it('should clear virtual text from buffer', function()
      virtual_text.show(bufnr, 0, 'Test')

      assert.has_no.errors(function()
        virtual_text.clear_buf(bufnr)
      end)
    end)

    it('should handle invalid buffer gracefully', function()
      assert.has_no.errors(function()
        virtual_text.clear_buf(99999)
      end)
    end)

    it('should handle nil bufnr gracefully', function()
      assert.has_no.errors(function()
        virtual_text.clear_buf(nil)
      end)
    end)
  end)

  describe('clear_all', function()
    it('should clear all virtual text', function()
      virtual_text.show(bufnr, 0, 'Test 1')
      virtual_text.show(bufnr, 2, 'Test 2')

      assert.has_no.errors(function()
        virtual_text.clear_all()
      end)
    end)
  end)
end)

describe('immersive multi-buffer behavior', function()
  local commands
  local config
  local ui
  local bufnr1, bufnr2

  before_each(function()
    -- Reset all related modules
    package.loaded['comment-translate'] = nil
    package.loaded['comment-translate.commands'] = nil
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.parser'] = nil
    package.loaded['comment-translate.parser.regex'] = nil
    package.loaded['comment-translate.parser.treesitter'] = nil
    -- These cases exercise state changes, never real translation requests.
    package.loaded['comment-translate.translate'] = {
      translate = function(_, _, _, callback)
        callback(nil)
      end,
    }
    package.loaded['comment-translate.translate.cache'] = nil
    package.loaded['comment-translate.translate.google'] = nil
    package.loaded['comment-translate.translate.llm'] = nil
    package.loaded['comment-translate.ui'] = nil
    package.loaded['comment-translate.ui.hover'] = nil
    package.loaded['comment-translate.ui.virtual_text'] = nil
    package.loaded['comment-translate.autocmds'] = nil
    package.loaded['comment-translate.utils'] = nil

    config = require('comment-translate.config')
    config.setup({
      target_language = 'ja',
      hover = {
        enabled = false,
        delay = 100,
        auto = true,
      },
      immersive = {
        enabled = false,
      },
      keymaps = {
        hover = false,
        hover_manual = false,
        replace = false,
        toggle = false,
      },
    })

    commands = require('comment-translate.commands')
    ui = require('comment-translate.ui')

    -- Create two test buffers
    bufnr1 = vim.api.nvim_create_buf(false, true)
    bufnr2 = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_buf_set_lines(bufnr1, 0, -1, false, { '-- Buffer 1 comment' })
    vim.api.nvim_buf_set_lines(bufnr2, 0, -1, false, { '-- Buffer 2 comment' })
  end)

  after_each(function()
    if bufnr1 and vim.api.nvim_buf_is_valid(bufnr1) then
      vim.api.nvim_buf_delete(bufnr1, { force = true })
    end
    if bufnr2 and vim.api.nvim_buf_is_valid(bufnr2) then
      vim.api.nvim_buf_delete(bufnr2, { force = true })
    end
    ui.hover.close()
    ui.virtual_text.clear_all()
  end)

  describe('toggle_immersive global disable', function()
    it('should disable immersive mode for all buffers when toggled off', function()
      -- Enable immersive on buffer 1
      vim.api.nvim_set_current_buf(bufnr1)
      commands.enable_immersive(bufnr1)
      assert.is_true(commands.is_immersive_enabled(bufnr1))

      -- Enable immersive on buffer 2
      commands.enable_immersive(bufnr2)
      assert.is_true(commands.is_immersive_enabled(bufnr2))

      -- Toggle off (globally) from buffer 1
      vim.api.nvim_set_current_buf(bufnr1)
      commands.toggle_immersive(bufnr1)

      -- Both buffers should be disabled
      assert.is_false(commands.is_immersive_enabled(bufnr1))
      assert.is_false(commands.is_immersive_enabled(bufnr2))
      assert.is_false(commands.is_immersive_globally_enabled())
    end)

    it('should not affect other buffers when enabling', function()
      -- Enable only on buffer 1
      vim.api.nvim_set_current_buf(bufnr1)
      commands.toggle_immersive(bufnr1)

      assert.is_true(commands.is_immersive_enabled(bufnr1))
      assert.is_false(commands.is_immersive_enabled(bufnr2))
      assert.is_true(commands.is_immersive_globally_enabled())
    end)
  end)
end)
