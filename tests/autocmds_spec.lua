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

  local buffer0
  local buffer1
  local buffer2
  local win0
  local win2
  local timers
  local deferred_callbacks
  local translate_requests
  local hover_state

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
    assert.is_true(vim.wait(100, function()
      return done
    end, 10))
  end

  local function trigger_autocmd(event, opts)
    vim.api.nvim_exec_autocmds(event, opts or {})
    flush_schedule()
  end

  local function set_source_position(pos)
    vim.api.nvim_set_current_win(win0)
    vim.api.nvim_set_current_buf(buffer0)
    vim.api.nvim_win_set_cursor(win0, pos)
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
      },
    }

    uv = vim.uv or vim.loop
    original_new_timer = uv.new_timer
    original_defer_fn = vim.defer_fn
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

      table.insert(timers, timer)
      return timer
    end

    vim.defer_fn = function(callback, timeout)
      table.insert(deferred_callbacks, {
        callback = callback,
        timeout = timeout,
      })
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
    vim.api.nvim_win_set_cursor(win0, POS.comment_a)

    autocmds.setup_hover(config, parser, translate, ui)
  end)

  after_each(function()
    autocmds.cleanup_all_timers()
    uv.new_timer = original_new_timer
    vim.defer_fn = original_defer_fn

    if win2 and vim.api.nvim_win_is_valid(win2) then
      vim.api.nvim_win_close(win2, true)
    end

    for _, bufnr in ipairs({ buffer0, buffer1, buffer2 }) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

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
    vim.api.nvim_exec_autocmds('CursorMoved', {})
    assert.equals(1, #deferred_callbacks)
    trigger_deferred(1)
    assert.is_true(hover_state.close_calls == 1 + close_calls_before)
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

  it('does not close hover when moving inside hover buffer', function()
    set_source_position(POS.comment_a)
    trigger_autocmd('CursorHold')
    trigger_timer(timers[1])
    reply_translate(1, 'translated A')

    vim.api.nvim_set_current_win(win0)
    vim.api.nvim_set_current_buf(buffer1)
    vim.api.nvim_win_set_cursor(win0, { 1, 0 })
    local close_calls_before = hover_state.close_calls
    trigger_autocmd('CursorMoved')

    assert.is_true(timers[1].stopped)
    assert.is_true(timers[1].closed)
    assert.equals(close_calls_before, hover_state.close_calls)

    set_source_position(POS.comment_b)
    trigger_autocmd('WinEnter', { buffer = buffer0 })
    trigger_autocmd('CursorMoved')

    assert.equals(close_calls_before + 1, hover_state.close_calls)
  end)
end)
