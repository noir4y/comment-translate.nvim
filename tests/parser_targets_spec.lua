---@diagnostic disable: undefined-global
local parser_runtime = os.getenv('COMMENT_TRANSLATE_TEST_RTP')
if parser_runtime and parser_runtime ~= '' then
  vim.opt.rtp:append(parser_runtime)
end

describe('parser target request boundary', function()
  local config, parser, commands, autocmds, ui, translate
  local bufnr, calls, notifications, timer_callback
  local original_notify, original_get_parser, original_schedule, original_new_timer
  local uv = vim.uv or vim.loop
  local query_api = require('vim.treesitter.query')
  local language_api = require('vim.treesitter.language')
  local set_query = query_api.set or query_api.set_query
  local query_languages

  local function query(lang, text)
    if text and vim.fn.has('nvim-0.9') == 0 then
      text = text:gsub('@injection%.content', '@content'):gsub('injection%.language', 'language')
      text = text:gsub('injection%.combined', 'combined')
    end
    set_query(lang, 'injections', text)
    query_languages[lang] = true
  end

  local function require_language(lang)
    local load = language_api.add or language_api.require_language
    local ok, result = pcall(load, lang)
    if not ok or result == false or result == nil then
      pending('real ' .. lang .. ' parser unavailable; compatibility unverified')
      return false
    end
    return true
  end

  local function fixture(ft, lines, row, col)
    if not require_language(ft) then
      return false
    end
    vim.bo[bufnr].filetype = ft
    vim.bo[bufnr].commentstring = ft == 'lua' and '-- %s' or ''
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { row or 1, col or 0 })
    -- Do not preparse: the plugin must discover injections on the first request.
    return true
  end

  local function request(flow)
    if flow == 'auto' then
      autocmds.setup_hover(config, parser, translate, ui)
      vim.api.nvim_exec_autocmds('CursorHold', { buffer = bufnr })
      assert.is_function(timer_callback)
      timer_callback()
    elseif flow == 'manual' then
      autocmds.setup_hover(config, parser, translate, ui)
      commands.hover_translate_on_demand()
    else
      commands.hover_translate()
    end
  end

  local function expect_text(expected)
    assert.equals(1, #calls)
    -- Keep source text out of assertion failure output.
    assert.is_true(calls[1] == expected)
  end

  before_each(function()
    for name in pairs(package.loaded) do
      if name:match('^comment%-translate') then
        package.loaded[name] = nil
      end
    end
    calls, notifications, query_languages = {}, {}, {}
    timer_callback = nil
    original_notify = vim.notify
    original_get_parser = vim.treesitter.get_parser
    original_schedule = vim.schedule
    original_new_timer = uv.new_timer
    vim.notify = function(message)
      table.insert(notifications, message)
    end
    vim.schedule = function(callback)
      callback()
    end
    uv.new_timer = function()
      return {
        start = function(_, _, _, callback)
          timer_callback = callback
        end,
        stop = function() end,
        close = function() end,
      }
    end
    translate = {
      translate = function(text, _, _, callback)
        table.insert(calls, text)
        callback('translated')
      end,
    }
    ui = {
      hover = { close = function() end, show = function() end, bufnr = function() end },
      virtual_text = {
        clear_buf = function() end,
        clear_all = function() end,
        show = function() end,
      },
    }
    package.loaded['comment-translate.translate'] = translate
    package.loaded['comment-translate.ui'] = ui
    config = require('comment-translate.config')
    config.setup({ target_language = 'ja', hover = { delay = 0 } })
    parser = require('comment-translate.parser')
    commands = require('comment-translate.commands')
    autocmds = require('comment-translate.autocmds')
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    autocmds.cleanup_all_timers()
    pcall(vim.api.nvim_del_augroup_by_name, 'CommentTranslateHover')
    commands.cleanup_buffer(bufnr)
    for lang in pairs(query_languages) do
      set_query(lang, 'injections', nil)
    end
    vim.treesitter.get_parser = original_get_parser
    vim.schedule = original_schedule
    uv.new_timer = original_new_timer
    vim.notify = original_notify
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
    describe(flow, function()
      it('does not reclassify a disabled string as a comment', function()
        config.setup({ targets = { comment = true, string = false } })
        if not fixture('lua', { 'local s = "alpha -- hidden"' }, 1, 21) then
          return
        end
        request(flow)
        assert.equals(0, #calls)
      end)

      it('does not reclassify a disabled comment as a string', function()
        config.setup({ targets = { comment = false, string = true } })
        if not fixture('lua', { '-- "quoted"' }, 1, 5) then
          return
        end
        request(flow)
        assert.equals(0, #calls)
      end)

      it('does not send either category when both are disabled', function()
        config.setup({ targets = { comment = false, string = false } })
        if not fixture('lua', { 'local s = "alpha -- hidden"', '-- "quoted"' }, 1, 21) then
          return
        end
        request(flow)
        vim.api.nvim_win_set_cursor(0, { 2, 5 })
        request(flow)
        assert.equals(0, #calls)
      end)

      for _, text in ipairs({ 'hello', 'こんにちは' }) do
        local label = text == 'hello' and 'ASCII' or 'multibyte'
        it('preserves enabled ' .. label .. ' comments', function()
          if not fixture('lua', { '-- ' .. text }, 1, 3) then
            return
          end
          request(flow)
          expect_text(text)
        end)

        it('preserves enabled ' .. label .. ' strings', function()
          if not fixture('lua', { 'local s = "' .. text .. '"' }, 1, 11) then
            return
          end
          request(flow)
          expect_text(text)
        end)
      end
    end)
  end

  it('does not submit code from a comment-free immersive buffer', function()
    if
      not fixture('lua', {
        'local opening = "/*"',
        'local internal = 314159',
        'local closing = "*/"',
      })
    then
      return
    end
    commands.enable_immersive(bufnr)
    assert.equals(0, #calls)
  end)

  it('preserves a multibyte multiline immersive comment', function()
    if
      not fixture('lua', { '--[[', 'こんにちは', 'hello', ']]', 'local s = "-- hidden"' })
    then
      return
    end
    commands.enable_immersive(bufnr)
    -- Preserve the existing normalization of long Lua comment delimiters.
    expect_text('--[[\nこんにちは\nhello\n]]')
  end)

  it('preserves a C character literal without sending its quote delimiters', function()
    local prefix = '/* 前 */ '
    if not fixture('c', { prefix .. "char value = 'a';" }, 1, #prefix + 14) then
      return
    end
    request('hover')
    expect_text('a')
  end)

  it('preserves a JavaScript template string', function()
    if not fixture('javascript', { 'const value = `hello ${name}`;' }, 1, 17) then
      return
    end
    request('hover')
    expect_text('hello ${name}')
  end)

  for _, unavailable in ipairs({ 'missing parser', 'parse failure', 'missing tree' }) do
    it('preserves fallback after ' .. unavailable .. ' without exposing error details', function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '-- hello', 'local s = "こんにちは"' })
      vim.treesitter.get_parser = function()
        if unavailable == 'missing parser' then
          error('private fixture details')
        end
        return {
          parse = function()
            if unavailable == 'parse failure' then
              error('private fixture details')
            end
            return {}
          end,
        }
      end
      request('hover')
      expect_text('hello')
      calls = {}
      vim.api.nvim_win_set_cursor(0, { 2, 11 })
      request('manual')
      expect_text('こんにちは')
      calls = {}
      commands.enable_immersive(bufnr)
      expect_text('hello')
      calls = {}
      config.setup({ targets = { comment = false, string = true } })
      request('hover')
      expect_text('こんにちは')
      calls = {}
      commands.update_immersive(bufnr)
      assert.equals(0, #calls)
      config.setup({ targets = { comment = true, string = false } })
      request('hover')
      assert.equals(0, #calls)
      commands.update_immersive(bufnr)
      expect_text('hello')
      calls = {}
      config.setup({ targets = { comment = false, string = false } })
      request('hover')
      commands.update_immersive(bufnr)
      assert.equals(0, #calls)
      for _, message in ipairs(notifications) do
        assert.is_nil(message:find('private fixture details', 1, true))
      end
    end)
  end

  local fence = string.rep(string.char(96), 3)
  local embeddings = {
    {
      ft = 'vim',
      open = 'lua << EOF',
      close = 'EOF',
      injection = '(lua_statement (script (body) @injection.content (#set! injection.language "lua")))',
    },
    {
      ft = 'markdown',
      open = fence .. 'lua',
      close = fence,
      injection = '(fenced_code_block (code_fence_content) @injection.content (#set! injection.language "lua"))',
    },
  }

  for _, embedding in ipairs(embeddings) do
    for _, profile in ipairs({ 'parser only', 'injection query', 'missing injected parser' }) do
      describe(embedding.ft .. ' ' .. profile, function()
        local function embedded(lines, row, col)
          if not require_language(embedding.ft) then
            return false
          end
          local injection = profile == 'parser only' and '' or embedding.injection
          if embedding.ft == 'vim' and injection ~= '' then
            local inspect = language_api.inspect or language_api.inspect_language
            if not inspect('vim').symbols.body then
              injection = injection:gsub(
                '%(script %(body%) @injection%.content',
                '(chunk) @injection.content'
              )
            end
          end
          if profile == 'missing injected parser' then
            injection = injection:gsub('"lua"', '"comment_translate_missing"')
          elseif profile == 'injection query' and not require_language('lua') then
            return false
          end
          query(embedding.ft, injection)
          if not fixture(embedding.ft, lines, row, col) then
            return false
          end
          vim.bo[bufnr].commentstring = embedding.ft == 'vim' and '" %s' or '<!-- %s -->'
          return true
        end

        it('preserves an embedded comment on first use and in immersive mode', function()
          if not embedded({ embedding.open, '-- こんにちは', embedding.close }, 2, 3) then
            return
          end
          request('hover')
          expect_text('こんにちは')
          calls = {}
          commands.enable_immersive(bufnr)
          expect_text('こんにちは')
        end)

        it('preserves an embedded string on first use', function()
          if
            not embedded({ embedding.open, 'local s = "こんにちは"', embedding.close }, 2, 11)
          then
            return
          end
          request('hover')
          expect_text('こんにちは')
        end)

        it('preserves punctuation in the embedded comment body', function()
          if not embedded({ embedding.open, '-- % growth', embedding.close }, 2, 3) then
            return
          end
          request('hover')
          expect_text('% growth')
          calls = {}
          commands.enable_immersive(bufnr)
          expect_text('% growth')
        end)

        it('does not send opening or closing boundaries', function()
          if not embedded({ embedding.open, '-- hello', embedding.close }, 1, 0) then
            return
          end
          request('hover')
          vim.api.nvim_win_set_cursor(0, { 3, 0 })
          request('hover')
          assert.equals(0, #calls)
        end)

        it('does not let a block comment escape an unparsed embedded range', function()
          if not embedded({ embedding.open, '/*', embedding.close, 'outside code', '*/' }) then
            return
          end
          commands.enable_immersive(bufnr)
          assert.equals(0, #calls)
        end)

        it('does not join block comments across separate embedded ranges', function()
          if
            not embedded({
              embedding.open,
              '/*',
              embedding.close,
              embedding.open,
              '*/',
              embedding.close,
            })
          then
            return
          end
          commands.enable_immersive(bufnr)
          assert.equals(0, #calls)
        end)

        it('honors target settings in an embedded range', function()
          config.setup({ targets = { comment = false, string = false } })
          if not embedded({ embedding.open, '-- "quoted"', embedding.close }, 2, 5) then
            return
          end
          request('hover')
          commands.enable_immersive(bufnr)
          assert.equals(0, #calls)
        end)

        if profile == 'injection query' then
          it('does not reclassify a disabled embedded string', function()
            config.setup({ targets = { comment = true, string = false } })
            if
              not embedded(
                { embedding.open, 'local s = "alpha -- hidden"', embedding.close },
                2,
                21
              )
            then
              return
            end
            request('hover')
            assert.equals(0, #calls)
          end)

          it('reparses after an embedded comment becomes a disabled string', function()
            config.setup({ targets = { comment = true, string = false } })
            if not embedded({ embedding.open, '-- hello', embedding.close }, 2, 3) then
              return
            end
            request('hover')
            expect_text('hello')
            calls = {}
            vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'local s = "alpha -- hidden"' })
            vim.api.nvim_win_set_cursor(0, { 2, 21 })
            request('hover')
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
          end)
        end
      end)
    end
  end

  it('keeps an injected Vim command as the existing host string translation unit', function()
    if not require_language('vim') then
      return
    end
    query(
      'lua',
      [[
      ((function_call name: (_) @_name
        arguments: (arguments (string content: (_) @injection.content)))
        (#eq? @_name "vim.cmd") (#set! injection.language "vim"))
    ]]
    )
    if not fixture('lua', { 'vim.cmd([[', '" hello', 'let value = 1', ']])' }, 2, 3) then
      return
    end
    request('hover')
    expect_text('" hello\nlet value = 1')
    calls = {}
    config.setup({ targets = { comment = true, string = false } })
    request('hover')
    commands.enable_immersive(bufnr)
    assert.equals(0, #calls)
  end)

  it('does not extract host code between disjoint combined injection regions', function()
    if not require_language('markdown') or not require_language('lua') then
      return
    end
    query(
      'markdown',
      [[
      (fenced_code_block (code_fence_content) @injection.content
        (#set! injection.language "lua") (#set! injection.combined))
    ]]
    )
    if
      not fixture('markdown', {
        fence .. 'lua',
        '--[[ opening',
        fence,
        'outside code',
        fence .. 'lua',
        'closing ]]',
        fence,
      }, 2, 6)
    then
      return
    end
    request('hover')
    commands.enable_immersive(bufnr)
    assert.equals(0, #calls)
  end)

  it('clips regex comments to byte ranges after a multibyte prefix', function()
    local regex = require('comment-translate.parser.regex')
    local prefix, content, suffix = '前文 ', '// hello', ' 後文'
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { prefix .. content .. suffix })
    local range = { 0, #prefix, 0, #prefix + #content }
    assert.is_true(regex.get_comment_at_line(bufnr, 0, #prefix + 3, range) == 'hello')
    assert.is_nil(regex.get_comment_at_line(bufnr, 0, 0, range))
    assert.is_nil(regex.get_comment_at_line(bufnr, 0, range[4], range))
    assert.is_true(regex.get_all_comments(bufnr, range)[0] == 'hello')
  end)

  it('does not use a string delimiter outside the fallback range', function()
    local regex = require('comment-translate.parser.regex')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '"hello" outside' })
    assert.is_nil(regex.get_string_at_position(bufnr, 0, 2, { 0, 0, 0, 6 }))
  end)
end)
