---@diagnostic disable: undefined-global
describe('async result guards', function()
  local commands, ui, autocmds, requests, bufnr, other, original_notify, notices
  local path
  before_each(function()
    for name in pairs(package.loaded) do
      if name:match('^comment%-translate') then
        package.loaded[name] = nil
      end
    end
    requests, notices = {}, {}
    original_notify = vim.notify
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded['comment-translate.translate'] = {
      translate = function(_, _, _, callback)
        requests[#requests + 1] = callback
      end,
    }
    package.loaded['comment-translate.parser'] = {
      get_text_at_cursor = function()
        return vim.api.nvim_get_current_line():match('^%-%- (.+)')
      end,
      get_all_comments = function()
        return { [0] = 'first', [3] = 'last' }
      end,
    }
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '-- 日本語', 'code', 'code', '-- last' })
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    require('comment-translate').setup({
      hover = { auto = true, delay = 1 },
      keymaps = { hover = false, hover_manual = false, replace = false, toggle = false },
    })
    commands = require('comment-translate.commands')
    ui = require('comment-translate.ui')
    autocmds = require('comment-translate.autocmds')
  end)
  after_each(function()
    autocmds.cleanup_all_timers()
    ui.hover.close()
    ui.virtual_text.clear_all()
    for _, group in ipairs({ 'CommentTranslateHover', 'CommentTranslateImmersive' }) do
      vim.api.nvim_del_augroup_by_name(group)
    end
    for _, buf in ipairs({ bufnr, other }) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    other = nil
    if path then
      vim.fn.delete(path)
      path = nil
    end
    vim.notify = original_notify
  end)
  local function use_modified_file_buffer()
    path = vim.fn.tempname()
    vim.bo[bufnr].buftype = ''
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.cmd('silent write')
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'edited code' })
    assert.is_true(vim.bo[bufnr].modified)
  end
  local function save(command)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.cmd('silent ' .. command)
    assert.is_false(vim.bo[bufnr].modified)
    assert.same(lines, vim.fn.readfile(path))
    assert.same(lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end
  local function marks()
    local ns = vim.api.nvim_get_namespaces().comment_translate_immersive
    return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  end
  it('stops immersive results and the remaining queue after editing', function()
    commands.enable_immersive(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { '-- changed' })
    requests[1]('old')
    assert.equals(1, #requests)
    assert.equals(0, #marks())
  end)
  it('does not place an out-of-range extmark after deleting rows', function()
    commands.enable_immersive(bufnr)
    requests[1]('first result')
    assert.equals(2, #requests)
    vim.api.nvim_buf_set_lines(bufnr, 1, -1, false, {})
    assert.has_no.errors(function()
      requests[2]('last result')
    end)
    assert.equals(1, #marks())
  end)
  it('keeps normal immersive results and rejects the batch superseded by a save', function()
    use_modified_file_buffer()
    commands.enable_immersive(bufnr)
    requests[1]('first result')
    requests[2]('last result')
    assert.equals(2, #marks())
    commands.update_immersive(bufnr)
    save('write')
    assert.equals(4, #requests)
    requests[3]('old')
    assert.equals(0, #marks())
    requests[4]('new')
    assert.equals(1, #marks())
  end)
  it('continues the immersive batch after a save without autocommands', function()
    use_modified_file_buffer()
    commands.enable_immersive(bufnr)
    save('noautocmd write')
    assert.equals(1, #requests)
    requests[1]('first result')
    assert.equals(1, #marks())
    assert.equals(2, #requests)
    requests[2]('last result')
    assert.equals(2, #marks())
  end)
  it('refreshes immersive translation on first save and stops it when disabled', function()
    path = vim.fn.tempname()
    vim.bo[bufnr].buftype = ''
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'edited code' })
    assert.equals('', vim.api.nvim_buf_get_name(bufnr))
    assert.is_true(vim.bo[bufnr].modified)
    vim.cmd.CommentTranslateToggle()
    save('write ' .. vim.fn.fnameescape(path))
    assert.equals(2, #requests)
    requests[1]('old')
    assert.equals(0, #marks())

    other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(other)
    assert.is_true(commands.is_immersive_enabled(other))
    vim.cmd.CommentTranslateToggle()
    assert.is_false(commands.is_immersive_globally_enabled())
    requests[2]('late')
    assert.equals(0, #marks())
    assert.equals(3, #requests)
  end)
  it('does not continue an immersive batch after wipeout', function()
    commands.enable_immersive(bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    requests[1]('old')
    assert.equals(1, #requests)
  end)
  it('stops an immersive batch on unload and translates again on re-entry', function()
    use_modified_file_buffer()
    save('write')
    commands.enable_immersive(bufnr)
    other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(other)
    vim.api.nvim_buf_delete(bufnr, { unload = true })
    assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
    assert.is_false(vim.api.nvim_buf_is_loaded(bufnr))
    requests[1]('old')
    assert.equals(1, #requests)
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    assert.equals(bufnr, vim.api.nvim_get_current_buf())
    assert.equals(2, #requests)
    requests[2]('new')
    assert.equals(1, #marks())
  end)
  for _, entry in ipairs({ 'hover_translate', 'hover_translate_on_demand' }) do
    it('keeps ' .. entry .. ' after saving unchanged text', function()
      use_modified_file_buffer()
      local cursor = vim.api.nvim_win_get_cursor(0)
      commands[entry]()
      save('write')
      assert.same(cursor, vim.api.nvim_win_get_cursor(0))
      requests[1]('translated')
      assert.is_not_nil(ui.hover.bufnr())
      assert.same({ 'translated' }, vim.api.nvim_buf_get_lines(ui.hover.bufnr(), 0, -1, false))
    end)
    for _, change in ipairs({ 'buffer', 'window', 'cursor', 'edit', 'wipeout' }) do
      it('discards ' .. entry .. ' after ' .. change, function()
        commands[entry]()
        if change == 'buffer' then
          other = vim.api.nvim_create_buf(false, true)
          vim.api.nvim_set_current_buf(other)
        elseif change == 'window' then
          vim.cmd('split')
        elseif change == 'cursor' then
          vim.api.nvim_win_set_cursor(0, { 1, 6 })
        elseif change == 'edit' then
          vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { '-- edited' })
        else
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        requests[1]('old')
        requests[1](nil)
        assert.is_nil(ui.hover.bufnr())
        assert.equals(0, #notices)
        if change == 'window' then
          vim.cmd('close')
        end
      end)
    end
  end
  it('rejects a pending manual result after reload and accepts a new request', function()
    use_modified_file_buffer()
    save('write')
    local cursor = vim.api.nvim_win_get_cursor(0)
    commands.hover_translate()
    assert.equals(0, vim.fn.writefile({ '-- reloaded', 'code' }, path))
    vim.cmd('silent edit!')
    assert.equals(bufnr, vim.api.nvim_get_current_buf())
    vim.api.nvim_win_set_cursor(0, cursor)
    requests[1]('old')
    assert.is_nil(ui.hover.bufnr())
    commands.hover_translate()
    requests[2]('new')
    assert.is_not_nil(ui.hover.bufnr())
    assert.same({ 'new' }, vim.api.nvim_buf_get_lines(ui.hover.bufnr(), 0, -1, false))
  end)
  it('shares the latest manual request across both entry points', function()
    commands.hover_translate()
    commands.hover_translate_on_demand()
    requests[2]('new')
    requests[1]('old')
    assert.same({ 'new' }, vim.api.nvim_buf_get_lines(ui.hover.bufnr(), 0, -1, false))
  end)
  it('invalidates the older request when the next manual attempt finds no target', function()
    commands.hover_translate()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    commands.hover_translate_on_demand()
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    requests[1]('old')
    assert.is_nil(ui.hover.bufnr())
  end)
  it('allows both manual entry points while automatic hover is off', function()
    commands.toggle_auto_hover()
    commands.hover_translate()
    requests[1]('one')
    assert.is_not_nil(ui.hover.bufnr())
    commands.hover_translate_on_demand()
    requests[2]('two')
    assert.same({ 'two' }, vim.api.nvim_buf_get_lines(ui.hover.bufnr(), 0, -1, false))
  end)
end)
