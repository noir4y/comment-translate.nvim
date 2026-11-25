---@diagnostic disable: undefined-global
describe('timer_cleanup', function()
  local autocmds
  local config
  local parser
  local translate
  local ui
  local uv
  local original_new_timer
  local original_defer_fn
  local original_notify

  local buffer0
  local buffer1
  local buffer2
  local win0
  local win2
  local timers
  local deferred_callbacks
  local translate_requests
  local hover_state
  local notify_messages

  local POS = {
    comment_a = { 1, 0 },
    code = { 2, 0 },
    comment_b = { 3, 0 },
  }

  local function flush_schedule()
    local done = false
    vim.schedule(function()
      done = true
    end)

    local mocked_new_timer = uv and uv.new_timer
    local mocked_defer_fn = vim.defer_fn
    if uv and original_new_timer then
      uv.new_timer = original_new_timer
    end
    if original_defer_fn then
      vim.defer_fn = original_defer_fn
    end

    local ok, result = pcall(function()
      return vim.wait(100, function()
        return done
      end, 10)
    end)

    if uv and mocked_new_timer then
      uv.new_timer = mocked_new_timer
    end
    vim.defer_fn = mocked_defer_fn

    if not ok then
      error(result, 0)
    end
    assert.is_true(result)
  end

  local function trigger_autocmd(event, opts)
    vim.api.nvim_exec_autocmds(event, opts or {})
    flush_schedule()
  end

  local function with_cursor_moved_ignored(callback)
    local previous_eventignore = vim.o.eventignore

    if previous_eventignore ~= 'all' then
      local existing = {}
      for event in string.gmatch(previous_eventignore, '[^,]+') do
        existing[event] = true
      end

      local next_eventignore = previous_eventignore
      for _, event in ipairs({ 'CursorMoved', 'CursorMovedI' }) do
        if not existing[event] then
          next_eventignore = next_eventignore == '' and event or next_eventignore .. ',' .. event
        end
      end
      vim.o.eventignore = next_eventignore
    end

    local ok, result = pcall(callback)
    vim.o.eventignore = previous_eventignore

    if not ok then
      error(result, 0)
    end
    return result
  end

  local function set_cursor(winid, pos)
    with_cursor_moved_ignored(function()
      vim.api.nvim_win_set_cursor(winid, pos)
    end)
  end

  local function set_source_position(pos)
    vim.api.nvim_set_current_win(win0)
    vim.api.nvim_set_current_buf(buffer0)
    set_cursor(win0, pos)
  end

  local function trigger_timer(timer)
    assert.is_not_nil(timer.callback)
    timer.callback()
    flush_schedule()
  end

  local function trigger_deferred(index)
    local deferred = deferred_callbacks[index]
    assert.is_not_nil(deferred)
    deferred.callback()
    flush_schedule()
  end

  local function reply_translate(index, result)
    local request = translate_requests[index]
    assert.is_not_nil(request)
    request.callback(result)
    flush_schedule()
  end

  before_each(function()
    package.loaded['comment-translate.autocmds'] = nil
    package.loaded['comment-translate.config'] = nil

    autocmds = require('comment-translate.autocmds')
    config = require('comment-translate.config')
    config.setup({
      hover = {
        enabled = true,
        delay = 100,
        auto = true,
      },
    })

    timers = {}
    deferred_callbacks = {}
    translate_requests = {}
    notify_messages = {}
    hover_state = {
      shown = {},
      close_calls = 0,
    }

    parser = {
      get_text_at_cursor = function()
        local bufnr = vim.api.nvim_get_current_buf()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        if bufnr ~= buffer0 then
          return nil, nil
        end
        if row == POS.comment_a[1] then
          return 'comment A', nil
        end
        if row == POS.comment_b[1] then
          return 'comment B', nil
        end
        return nil, nil
      end,
    }

    translate = {
      translate = function(text, _, _, callback)
        table.insert(translate_requests, {
          text = text,
          callback = callback,
        })
      end,
    }

    ui = {
      hover = {
        show = function(text)
          hover_state.last_show_text = text
          table.insert(hover_state.shown, text)
        end,
        close = function()
          hover_state.close_calls = hover_state.close_calls + 1
        end,
        bufnr = function()
          return buffer1
        end,
        winid = function()
          return hover_state.winid
        end,
        is_hover_window = function(winid)
          return hover_state.winid == winid
        end,
        is_hover_buffer = function(bufnr)
          return buffer1 == bufnr
        end,
      },
    }

    uv = vim.uv or vim.loop
    original_new_timer = uv.new_timer
    original_defer_fn = vim.defer_fn
    original_notify = vim.notify
    uv.new_timer = function()
      local timer = {
        started = false,
        stopped = false,
        closed = false,
      }

      function timer:start(timeout, repeat_, callback)
        self.started = true
        self.timeout = timeout
        self.repeat_ = repeat_
        self.callback = callback
      end

      function timer:stop()
        self.stopped = true
      end

      function timer:close()
        self.closed = true
      end

      function timer:is_closing()
        return self.closed
      end

      table.insert(timers, timer)
      return timer
    end

    vim.defer_fn = function(callback, timeout)
      table.insert(deferred_callbacks, {
        callback = callback,
        timeout = timeout,
      })
    end
    vim.notify = function(msg, level)
      table.insert(notify_messages, { msg = msg, level = level })
    end

    buffer0 = vim.api.nvim_create_buf(false, true)
    buffer1 = vim.api.nvim_create_buf(false, true)
    buffer2 = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_buf_set_lines(buffer0, 0, -1, false, {
      '-- comment A',
      'local value = 1',
      '-- comment B',
    })

    win0 = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_buf(buffer0)

    vim.cmd('vsplit')
    win2 = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_buf(buffer2)
    vim.api.nvim_set_current_win(win0)
    vim.api.nvim_set_current_buf(buffer0)
    set_cursor(win0, POS.comment_a)

    autocmds.setup_hover(config, parser, translate, ui)
  end)

  after_each(function()
    autocmds.cleanup_all_timers()
    uv.new_timer = original_new_timer
    vim.defer_fn = original_defer_fn
    vim.notify = original_notify

    if win2 and vim.api.nvim_win_is_valid(win2) then
      vim.api.nvim_win_close(win2, true)
    end

    for _, bufnr in ipairs({ buffer0, buffer1, buffer2 }) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  for _, started in ipairs({ false, true }) do
    it('invalidates automatic hover on OFF, started=' .. tostring(started), function()
      package.loaded['comment-translate.config'] = config
      package.loaded['comment-translate.ui'] = ui
      package.loaded['comment-translate.commands'] = nil
      local commands = require('comment-translate.commands')
      trigger_autocmd('CursorHold')
      if started then
        trigger_timer(timers[1])
      end
      commands.toggle_auto_hover()
      trigger_timer(timers[1])
      if started then
        reply_translate(1, 'old')
      end
      assert.equals(started and 1 or 0, #translate_requests)
      assert.same({}, hover_state.shown)
      commands.toggle_auto_hover()
      trigger_timer(timers[1])
      if started then
        reply_translate(1, 'old')
      end
      assert.same({}, hover_state.shown)
      trigger_autocmd('CursorHold')
      trigger_timer(timers[2])
      reply_translate(started and 2 or 1, 'new')
      assert.same({ 'new' }, hover_state.shown)
    end)
  end

  it('automatically translates and shows hover on CursorHold', function()
    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')

    assert.equals(1, #timers)
    assert.is_true(timers[1].started)
    assert.equals(100, timers[1].timeout)

    trigger_timer(timers[1])

    assert.equals(1, #translate_requests)
    assert.equals('comment A', translate_requests[1].text)

    reply_translate(1, 'translated A')

    assert.same({ 'translated A' }, hover_state.shown)
  end)

  -- T1 represents a timer-triggered hover with translation results displayed.
  it('cleans timer before T1 when cursor moves to code', function()
    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')

    set_source_position(POS.code)
    trigger_autocmd('CursorMoved')

    assert.is_true(timers[1].stopped)
    assert.is_true(timers[1].closed)

    trigger_timer(timers[1])

    assert.equals(0, #translate_requests)
    assert.same({}, hover_state.shown)
  end)

  it('closes hover after T1 when cursor moves to code', function()
    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')
    trigger_timer(timers[1])
    reply_translate(1, 'translated A')

    local close_calls_before = hover_state.close_calls
    set_source_position(POS.code)
    local deferred_callbacks_before = #deferred_callbacks
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    assert.equals(deferred_callbacks_before + 1, #deferred_callbacks)
    trigger_deferred(deferred_callbacks_before + 1)
    assert.equals(close_calls_before + 1, hover_state.close_calls)
  end)

  it('replaces timer1 with timer2 and keeps timer1 inactive', function()
    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')

    assert.equals(1, #timers)

    set_source_position(POS.comment_b)
    trigger_autocmd('CursorHold')

    assert.equals(2, #timers)
    assert.is_true(timers[1].stopped)
    assert.is_true(timers[1].closed)
    assert.is_false(timers[2].stopped)

    trigger_timer(timers[1])
    assert.equals(0, #translate_requests)
    assert.same({}, hover_state.shown)

    trigger_timer(timers[2])
    assert.equals(1, #translate_requests)
    assert.equals('comment B', translate_requests[1].text)

    reply_translate(1, 'translated B')
    assert.same({ 'translated B' }, hover_state.shown)
  end)

  it('cleans timer1 and timer2 after moving again', function()
    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')

    set_source_position(POS.comment_b)
    trigger_autocmd('CursorHold')

    set_source_position(POS.code)
    trigger_autocmd('CursorMoved')

    assert.is_true(timers[1].stopped)
    assert.is_true(timers[1].closed)
    assert.is_true(timers[2].stopped)
    assert.is_true(timers[2].closed)

    trigger_timer(timers[1])
    trigger_timer(timers[2])

    assert.equals(0, #translate_requests)
    assert.same({}, hover_state.shown)
  end)

  it('ignores stale async translate result from timer1', function()
    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')
    trigger_timer(timers[1])

    assert.equals(1, #translate_requests)
    assert.equals('comment A', translate_requests[1].text)

    set_source_position(POS.comment_b)
    trigger_autocmd('CursorHold')
    trigger_timer(timers[2])

    assert.equals(2, #translate_requests)
    assert.equals('comment B', translate_requests[2].text)

    reply_translate(2, 'translated B')
    assert.equals('translated B', hover_state.last_show_text)

    reply_translate(1, 'translated A')
    assert.equals('translated B', hover_state.last_show_text)
    assert.same({ 'translated B' }, hover_state.shown)
  end)

  it('does not include parser error details in hover error notification', function()
    parser.get_text_at_cursor = function()
      error('sensitive source text')
    end

    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')
    trigger_timer(timers[1])

    assert.equals('comment-translate: hover error', notify_messages[1].msg)
    assert.is_nil(notify_messages[1].msg:find('sensitive source text', 1, true))
  end)

  it('cleans timer when switching windows', function()
    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')

    vim.api.nvim_set_current_win(win2)
    vim.api.nvim_set_current_buf(buffer2)
    vim.api.nvim_exec_autocmds('WinLeave', { buffer = buffer0 })
    flush_schedule()

    assert.is_true(timers[1].stopped)
    assert.is_true(timers[1].closed)

    trigger_timer(timers[1])
    assert.equals(0, #translate_requests)
    assert.same({}, hover_state.shown)
  end)

  it('closes hover when switching buffers in the same window', function()
    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')
    trigger_timer(timers[1])
    reply_translate(1, 'translated A')

    local close_calls_before = hover_state.close_calls
    trigger_autocmd('BufLeave', { buffer = buffer0 })
    vim.api.nvim_set_current_win(win0)
    vim.api.nvim_set_current_buf(buffer2)
    flush_schedule()

    assert.is_true(timers[1].stopped)
    assert.is_true(timers[1].closed)
    assert.equals(close_calls_before + 1, hover_state.close_calls)
  end)

  it('does not close hover when moving inside hover buffer', function()
    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')
    trigger_timer(timers[1])
    reply_translate(1, 'translated A')

    vim.api.nvim_set_current_win(win0)
    vim.api.nvim_set_current_buf(buffer1)
    set_cursor(win0, { 1, 0 })
    local close_calls_before = hover_state.close_calls
    trigger_autocmd('CursorMoved')

    assert.is_true(timers[1].stopped)
    assert.is_true(timers[1].closed)
    assert.equals(close_calls_before, hover_state.close_calls)

    set_source_position(POS.comment_b)
    flush_schedule()
    trigger_autocmd('CursorMoved')

    assert.equals(close_calls_before + 1, hover_state.close_calls)
  end)

  it('does not close hover when entering hover window', function()
    hover_state.winid = win2
    vim.api.nvim_set_current_win(win2)
    vim.api.nvim_set_current_buf(buffer2)

    local close_calls_before = hover_state.close_calls
    trigger_autocmd('WinEnter', { buffer = buffer2 })

    assert.equals(close_calls_before, hover_state.close_calls)
  end)

  it('does not start hover translation on CursorHold inside hover window', function()
    hover_state.winid = win2
    vim.api.nvim_set_current_win(win2)
    vim.api.nvim_set_current_buf(buffer2)

    local close_calls_before = hover_state.close_calls
    trigger_autocmd('CursorHold', { buffer = buffer2 })

    assert.equals(0, #timers)
    assert.equals(0, #translate_requests)
    assert.equals(close_calls_before, hover_state.close_calls)
  end)

  it(
    'does not translate or close when a pending hover timer fires after entering hover window',
    function()
      set_source_position(POS.comment_a)
      trigger_autocmd('CursorHold')

      hover_state.winid = win2
      vim.api.nvim_set_current_win(win2)
      vim.api.nvim_set_current_buf(buffer2)

      local close_calls_before = hover_state.close_calls
      trigger_timer(timers[1])

      assert.equals(0, #translate_requests)
      assert.same({}, hover_state.shown)
      assert.equals(close_calls_before, hover_state.close_calls)
    end
  )

  it('does not close hover from deferred cursor move after entering hover window', function()
    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')
    trigger_timer(timers[1])
    reply_translate(1, 'translated A')

    local close_calls_before = hover_state.close_calls
    set_source_position(POS.code)
    local deferred_callbacks_before = #deferred_callbacks
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    assert.equals(deferred_callbacks_before + 1, #deferred_callbacks)

    hover_state.winid = win2
    vim.api.nvim_set_current_win(win2)
    vim.api.nvim_set_current_buf(buffer2)
    trigger_deferred(deferred_callbacks_before + 1)

    assert.equals(close_calls_before, hover_state.close_calls)
  end)
end)

describe('immersive hover buffer guard', function()
  local autocmds
  local commands
  local ui
  local current_bufnr
  local hover_bufnr
  local normal_bufnr
  local enabled
  local calls

  local function reset_groups()
    pcall(vim.api.nvim_del_augroup_by_name, 'CommentTranslateHover')
    pcall(vim.api.nvim_del_augroup_by_name, 'CommentTranslateImmersive')
  end

  before_each(function()
    reset_groups()

    package.loaded['comment-translate.autocmds'] = nil
    autocmds = require('comment-translate.autocmds')

    enabled = {}
    calls = {
      is_enabled = {},
      enable = {},
      update = {},
      cleanup = {},
    }

    commands = {
      is_immersive_globally_enabled = function()
        return true
      end,
      is_immersive_enabled = function(bufnr)
        table.insert(calls.is_enabled, bufnr)
        return enabled[bufnr] == true
      end,
      enable_immersive = function(bufnr)
        table.insert(calls.enable, bufnr)
        enabled[bufnr] = true
      end,
      update_immersive = function(bufnr)
        table.insert(calls.update, bufnr)
      end,
      cleanup_buffer = function(bufnr)
        table.insert(calls.cleanup, bufnr)
      end,
    }

    current_bufnr = vim.api.nvim_create_buf(false, true)
    hover_bufnr = vim.api.nvim_create_buf(false, true)
    normal_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(current_bufnr)

    ui = {
      hover = {
        bufnr = function()
          return hover_bufnr
        end,
        is_hover_buffer = function(bufnr)
          return bufnr == hover_bufnr
        end,
      },
      virtual_text = {
        clear_buf = function() end,
      },
    }

    autocmds.setup_immersive(commands, ui)
  end)

  after_each(function()
    reset_groups()

    for _, bufnr in ipairs({ current_bufnr, hover_bufnr, normal_bufnr }) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it('does not enable immersive mode for hover buffers on BufEnter', function()
    vim.api.nvim_set_current_buf(hover_bufnr)

    assert.same({}, calls.is_enabled)
    assert.same({}, calls.enable)
    assert.same({}, calls.update)
  end)

  it('does not update immersive mode for already-enabled hover buffers on BufEnter', function()
    enabled[hover_bufnr] = true

    vim.api.nvim_set_current_buf(hover_bufnr)

    assert.same({}, calls.is_enabled)
    assert.same({}, calls.enable)
    assert.same({}, calls.update)
  end)

  it('still enables immersive mode for normal buffers on BufEnter', function()
    vim.api.nvim_set_current_buf(normal_bufnr)

    assert.same({ normal_bufnr }, calls.is_enabled)
    assert.same({ normal_bufnr }, calls.enable)
    assert.same({}, calls.update)
  end)
end)
