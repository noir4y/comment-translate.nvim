---@diagnostic disable: undefined-global

describe('parser target request boundary', function()
  local config, parser, commands, autocmds, ui, translate
  local bufnr, calls, notifications, timer_callback
  local original_notify, original_get_parser, original_schedule, original_new_timer, original_virtualedit
  local uv = vim.uv or vim.loop
  local query_api = require('vim.treesitter.query')
  local language_api = require('vim.treesitter.language')
  local language_tree_api = require('vim.treesitter.languagetree')
  local original_get_injections, original_contains, original_tree_for_range, original_pairs
  local original_query_get, query_overrides
  local original_get_string_parser, recovered_parser

  local function query(lang, text)
    query_overrides[lang] = query_api.parse(lang, text)
  end

  local function require_language(lang)
    local load = language_api.add or language_api.require_language
    local ok, result, err = pcall(load, lang)
    if not ok or result == false or (result == nil and err ~= nil) then
      if os.getenv('COMMENT_TRANSLATE_TEST_REQUIRE_PARSERS') == '1' then
        error('Required real parser unavailable: ' .. lang)
      end
      pending('real ' .. lang .. ' parser unavailable; compatibility unverified')
      return false
    end
    return true
  end

  local function vim_has_body()
    local inspect = language_api.inspect or language_api.inspect_language
    local symbols = inspect('vim').symbols
    if symbols.body then
      return true
    end
    -- v0.10 returns symbol tuples keyed by numeric IDs, newer versions by name.
    for _, symbol in pairs(symbols) do
      if type(symbol) == 'table' and symbol[1] == 'body' then
        return true
      end
    end
    return false
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
    if flow == 'auto' or flow == 'insert' then
      autocmds.setup_hover(config, parser, translate, ui)
      vim.api.nvim_exec_autocmds(
        flow == 'insert' and 'CursorHoldI' or 'CursorHold',
        { buffer = bufnr }
      )
      assert.is_function(timer_callback)
      timer_callback()
      for _, message in ipairs(notifications) do
        assert.is_false(message:find('comment%-translate: hover error') ~= nil)
      end
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

  local function expect_child(lang)
    local child = (recovered_parser or original_get_parser(bufnr)):children()[lang]
    assert.is_not_nil(child)
    assert.is_not_nil(next(child:trees()))
  end

  before_each(function()
    for name in pairs(package.loaded) do
      if name:match('^comment%-translate') then
        package.loaded[name] = nil
      end
    end
    calls, notifications, query_overrides = {}, {}, {}
    timer_callback = nil
    original_notify = vim.notify
    original_get_parser = vim.treesitter.get_parser
    original_schedule = vim.schedule
    original_new_timer = uv.new_timer
    original_virtualedit = vim.o.virtualedit
    original_get_injections = language_tree_api._get_injections
    original_contains = language_tree_api.contains
    original_tree_for_range = language_tree_api.tree_for_range
    original_pairs = pairs
    original_query_get = query_api.get
    original_get_string_parser = vim.treesitter.get_string_parser
    recovered_parser = nil
    vim.treesitter.get_string_parser = function(...)
      recovered_parser = original_get_string_parser(...)
      return recovered_parser
    end
    -- Scope injection overrides to this case. v0.10 query.set cannot unset a
    -- query with nil, so do not alter its persistent explicit-query table.
    query_api.get = function(lang, name)
      if name == 'injections' and query_overrides[lang] then
        return query_overrides[lang]
      end
      return original_query_get(lang, name)
    end
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
    query_api.get = original_query_get
    vim.treesitter.get_string_parser = original_get_string_parser
    vim.treesitter.get_parser = original_get_parser
    vim.schedule = original_schedule
    uv.new_timer = original_new_timer
    vim.notify = original_notify
    vim.o.virtualedit = original_virtualedit
    language_tree_api._get_injections = original_get_injections
    language_tree_api.contains = original_contains
    language_tree_api.tree_for_range = original_tree_for_range
    _G.pairs = original_pairs
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

  for _, form in ipairs({
    { ft = 'php', open = "<?php $s = <<<'DOC'", close = 'DOC;', outside = '$after = 1;' },
    { ft = 'vim', open = 'let g:s =<< DOC', close = 'DOC', outside = 'let after = 1' },
    { ft = 'vim', open = 'let g:s =<< trim DOC', close = 'DOC', outside = 'let after = 1' },
    { ft = 'vim', open = 'const g:s =<< DOC', close = 'DOC', outside = 'let after = 1' },
    { ft = 'vim', open = 'const g:s =<< trim DOC', close = 'DOC', outside = 'let after = 1' },
  }) do
    for _, profile in ipairs({ 'native', 'parser-only' }) do
      for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
        for _, enabled in ipairs({ true, false }) do
          it(
            'keeps quoted assignment heredoc content bounded: '
              .. form.open
              .. ', '
              .. profile
              .. ', '
              .. flow
              .. ', strings='
              .. tostring(enabled),
            function()
              if not require_language(form.ft) then
                return
              end
              if profile == 'parser-only' then
                query(form.ft, '')
              end
              local prefix, body = '前文 "', 'こんにちは -- # /* body'
              config.setup({ targets = { comment = true, string = enabled } })
              if
                not fixture(form.ft, {
                  form.open,
                  prefix .. body .. '"',
                  '"second"',
                  form.close,
                  form.outside,
                }, 2, #prefix)
              then
                return
              end
              request(flow)
              if enabled then
                expect_text(body)
              else
                assert.equals(0, #calls)
              end
              assert.is_false(original_get_parser(bufnr):trees()[1]:root():has_error())
              calls = {}
              commands.enable_immersive(bufnr)
              assert.equals(0, #calls)
              for _, position in ipairs({ { 1, 0 }, { 1, #form.open - 2 }, { 4, 1 }, { 5, 0 } }) do
                vim.api.nvim_win_set_cursor(0, position)
                request(flow)
              end
              assert.equals(0, #calls)
              config.setup({ targets = { comment = false, string = true } })
              vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { '"updated"' })
              vim.api.nvim_win_set_cursor(0, { 2, 2 })
              request(flow)
              expect_text('updated')
            end
          )
        end
      end
    end
    for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
      it('rejects an unterminated assignment heredoc: ' .. form.open .. ', ' .. flow, function()
        if not fixture(form.ft, { form.open, 'Hello "quoted"' }, 2, 8) then
          return
        end
        request(flow)
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)
      end)
    end
  end

  for _, form in ipairs({
    { ft = 'php', open = "<?php $s = <<<'DOC'", close = 'DOC;', content = '(nowdoc_body)' },
    { ft = 'vim', open = 'let g:s =<< trim DOC', close = 'DOC', content = '(heredoc (body))' },
    { ft = 'vim', open = 'const g:s =<< trim DOC', close = 'DOC', content = '(heredoc (body))' },
  }) do
    for _, first in ipairs({ 'hover', 'manual', 'auto', 'immersive' }) do
      it(
        'withholds injected comments in assignment heredoc strings: ' .. form.open .. ', ' .. first,
        function()
          if not require_language(form.ft) or not require_language('lua') then
            return
          end
          query(
            form.ft,
            '('
              .. form.content
              .. ' @injection.content (#set! injection.language "lua") (#set! injection.include-children))'
          )
          query('lua', '')
          config.setup({ targets = { comment = true, string = false } })
          if not fixture(form.ft, { form.open, '-- "quoted"', form.close }, 2, 5) then
            return
          end
          if first == 'immersive' then
            commands.enable_immersive(bufnr)
          else
            request(first)
          end
          expect_child('lua')
          request('hover')
          assert.equals(0, #calls)
          config.setup({ targets = { comment = false, string = true } })
          request('hover')
          expect_text('quoted')
        end
      )
    end
  end

  for _, form in ipairs({
    { ft = 'php', open = "<?php $s = <<<'DOC'", content = '(nowdoc_body)' },
    { ft = 'vim', open = 'let g:s =<< trim DOC', content = '(heredoc (body))' },
    { ft = 'vim', open = 'const g:s =<< trim DOC', content = '(heredoc (body))' },
  }) do
    for _, flow in ipairs({ 'hover', 'manual', 'auto', 'immersive' }) do
      for _, comment in ipairs({ true, false }) do
        it(
          'withholds malformed host bodies above custom injections: '
            .. form.open
            .. ', '
            .. flow
            .. ', comments='
            .. tostring(comment),
          function()
            if not require_language(form.ft) or not require_language('lua') then
              return
            end
            query(
              form.ft,
              '('
                .. form.content
                .. ' @injection.content (#set! injection.language "lua") (#set! injection.include-children))'
            )
            query('lua', '')
            config.setup({ targets = { comment = comment, string = not comment } })
            local body = comment and '-- "quoted"' or 'local s = "quoted"'
            if not fixture(form.ft, { form.open, body }, 2, #body - 3) then
              return
            end
            if flow == 'immersive' then
              commands.enable_immersive(bufnr)
            else
              request(flow)
            end
            assert.equals(0, #calls)
            if flow ~= 'immersive' or comment then
              assert.is_true(original_get_parser(bufnr):trees()[1]:root():has_error())
              if form.ft == 'php' then
                expect_child('lua')
              end
            end
          end
        )
      end
    end
  end

  for _, profile in ipairs({ 'native', 'parser-only' }) do
    for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
      for _, delimiter in ipairs({ '"', "'", '`' }) do
        it(
          'preserves bounded Bash heredoc quotes via '
            .. flow
            .. ' ('
            .. profile
            .. delimiter
            .. ')',
          function()
            if not require_language('bash') then
              return
            end
            if profile == 'parser-only' then
              query('bash', '')
            end
            if
              not fixture('bash', {
                'cat <<EOF',
                delimiter .. 'こんにちは -- content' .. delimiter,
                'EOF',
                'printf outside',
              }, 2, 4)
            then
              return
            end
            config.setup({ targets = { comment = true, string = true } })
            request(flow)
            expect_text('こんにちは -- content')
            local root = vim.treesitter.get_parser(bufnr)
            local node = root:trees()[1]:root():named_descendant_for_range(1, 4, 1, 4)
            while node and node:type() ~= 'heredoc_body' do
              node = node:parent()
            end
            assert.is_not_nil(node)
            assert.is_nil(next(root:children()))

            calls = {}
            config.setup({ targets = { comment = true, string = false } })
            request(flow)
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
            config.setup({ targets = { comment = false, string = false } })
            request(flow)
            assert.equals(0, #calls)

            config.setup({ targets = { comment = false, string = true } })
            vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { delimiter .. 'edited' .. delimiter })
            vim.api.nvim_win_set_cursor(0, { 2, 3 })
            request(flow)
            expect_text('edited')
            calls = {}
            for _, position in ipairs({ { 1, 5 }, { 3, 1 }, { 4, 8 } }) do
              vim.api.nvim_win_set_cursor(0, position)
              request(flow)
            end
            assert.equals(0, #calls)
          end
        )
      end
    end
  end

  for _, form in ipairs({
    { header = 'message: |', line = '  %s', row = 2, col = 4, node = 'block_scalar' },
    { header = 'message: >', line = '  %s', row = 2, col = 4, node = 'block_scalar' },
    { header = '', line = 'message: He said %s', row = 1, col = 18, node = 'string_scalar' },
  }) do
    for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
      it(
        'preserves quoted YAML scalar content via ' .. flow .. ' (' .. form.header .. ')',
        function()
          for _, delimiter in ipairs({ '"', "'", '`' }) do
            local lines = {
              string.format(form.line, delimiter .. 'こんにちは -- content' .. delimiter),
              'outside: value',
            }
            if form.header ~= '' then
              table.insert(lines, 1, form.header)
            end
            if not fixture('yaml', lines, form.row, form.col) then
              return
            end
            config.setup({ targets = { comment = true, string = true } })
            request(flow)
            expect_text('こんにちは -- content')
            local root = vim.treesitter.get_parser(bufnr)
            local node = root
              :trees()[1]
              :root()
              :named_descendant_for_range(form.row - 1, form.col, form.row - 1, form.col)
            while node and node:type() ~= form.node do
              node = node:parent()
            end
            assert.is_not_nil(node)
            calls = {}
            config.setup({ targets = { comment = true, string = false } })
            request(flow)
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
            config.setup({ targets = { comment = false, string = false } })
            request(flow)
            assert.equals(0, #calls)
            config.setup({ targets = { comment = false, string = true } })
            vim.api.nvim_buf_set_lines(bufnr, form.row - 1, form.row, false, {
              string.format(form.line, delimiter .. 'edited' .. delimiter),
            })
            request(flow)
            expect_text('edited')
            calls = {}
            vim.api.nvim_win_set_cursor(0, { #lines, 10 })
            request(flow)
            vim.api.nvim_win_set_cursor(0, { 1, 1 })
            request(flow)
            assert.equals(0, #calls)
          end
        end
      )
    end
  end

  for _, embedded in ipairs({ false, true }) do
    for _, multiline in ipairs({ false, true }) do
      for _, flow in ipairs({ 'hover', 'manual', 'auto', 'immersive' }) do
        it(
          'preserves SQL block comments via '
            .. flow
            .. ' (embedded='
            .. tostring(embedded)
            .. ', multiline='
            .. tostring(multiline)
            .. ')',
          function()
            if not require_language('sql') or (embedded and not require_language('markdown')) then
              return
            end
            query('sql', '')
            if embedded then
              query(
                'markdown',
                '(fenced_code_block (info_string) @injection.language'
                  .. ' (code_fence_content) @injection.content (#set! injection.include-children))'
              )
            end
            local function lines(body)
              local result = vim.list_extend({}, body)
              table.insert(result, 'SELECT 1;')
              if embedded then
                table.insert(result, 1, '```sql')
                table.insert(result, '```')
              end
              return result
            end
            local body = multiline and { '/* こんにちは', 'body */' }
              or { '/* こんにちは */' }
            local row = embedded and 2 or 1
            if not fixture(embedded and 'markdown' or 'sql', lines(body), row, 4) then
              return
            end
            config.setup({ targets = { comment = true, string = false } })
            if flow == 'immersive' then
              commands.enable_immersive(bufnr)
            else
              request(flow)
            end
            expect_text(multiline and 'こんにちは body' or 'こんにちは')
            calls = {}
            config.setup({ targets = { comment = false, string = true } })
            if flow == 'immersive' then
              commands.update_immersive(bufnr)
            else
              request(flow)
            end
            assert.equals(0, #calls)
            config.setup({ targets = { comment = true, string = false } })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines({ '/* edited */' }))
            if flow == 'immersive' then
              commands.update_immersive(bufnr)
            else
              request(flow)
            end
            expect_text('edited')
            calls = {}
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines({ 'SELECT 2;' }))
            if flow == 'immersive' then
              commands.update_immersive(bufnr)
            else
              request(flow)
            end
            assert.equals(0, #calls)
          end
        )
      end
    end
  end

  for _, form in ipairs({
    { ft = 'scss', kind = 'single_line_comment', commentstring = '// %s' },
    { ft = 'css', kind = 'js_comment', commentstring = '/* %s */' },
  }) do
    for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
      for _, prefix in ipairs({ '', 'a { content: "あ"; } ' }) do
        local position = prefix == '' and 'standalone' or 'inline'
        it(
          'preserves ' .. form.ft .. ' slash comments via ' .. flow .. ' (' .. position .. ')',
          function()
            if not require_language(form.ft) then
              return
            end
            query(form.ft, '')
            config.setup({ targets = { comment = true, string = false } })
            if
              not fixture(
                form.ft,
                { prefix .. '// hello', 'a { content: "// hidden"; }' },
                1,
                #prefix + 3
              )
            then
              return
            end
            vim.bo[bufnr].commentstring = form.commentstring
            request(flow)
            expect_text('hello')
            local tree = vim.treesitter.get_parser(bufnr):trees()[1]
            assert.is_false(tree:root():has_error())
            local node = tree:root():named_descendant_for_range(0, #prefix + 3, 0, #prefix + 3)
            assert.equals(form.kind, node:type())

            calls = {}
            local body = 'こんにちは "quoted"'
            local line = prefix .. '// ' .. body
            vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { line })
            request(flow)
            expect_text(body)
            calls = {}
            vim.o.virtualedit = 'onemore'
            vim.api.nvim_win_set_cursor(0, { 1, #line })
            request(flow)
            expect_text(body)

            calls = {}
            config.setup({ targets = { comment = false, string = true } })
            vim.api.nvim_win_set_cursor(0, { 1, line:find('quoted', 1, true) - 1 })
            request(flow)
            assert.equals(0, #calls)
            config.setup({ targets = { comment = false, string = false } })
            request(flow)
            assert.equals(0, #calls)
            config.setup({ targets = { comment = true, string = false } })
            vim.api.nvim_win_set_cursor(0, { 2, 16 })
            request(flow)
            assert.equals(0, #calls)
            if prefix ~= '' then
              vim.api.nvim_win_set_cursor(0, { 1, 0 })
              request(flow)
              assert.equals(0, #calls)
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { '//' })
            vim.api.nvim_win_set_cursor(0, { 1, 1 })
            request(flow)
            assert.equals(0, #calls)
          end
        )
      end
    end

    it('preserves first-use ' .. form.ft .. ' slash comments in immersive mode', function()
      if not require_language(form.ft) then
        return
      end
      query(form.ft, '')
      config.setup({ targets = { comment = true, string = false } })
      if
        not fixture(
          form.ft,
          { '// こんにちは', 'a { content: "あ"; } // inline', 'a { content: "// hidden"; }' }
        )
      then
        return
      end
      vim.bo[bufnr].commentstring = form.commentstring
      commands.enable_immersive(bufnr)
      assert.equals(2, #calls)
      assert.is_true(calls[1] == 'こんにちは')
      assert.is_true(calls[2] == 'inline')
      calls = {}
      config.setup({ targets = { comment = false, string = true } })
      commands.update_immersive(bufnr)
      assert.equals(0, #calls)
      config.setup({ targets = { comment = true, string = false } })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '// edited', '/* block */' })
      commands.update_immersive(bufnr)
      assert.equals(2, #calls)
      assert.is_true(calls[1] == 'edited')
      -- Preserve the base's block-comment unit under each native commentstring.
      assert.is_true(calls[2] == (form.ft == 'scss' and '/* block */' or 'block'))
      calls = {}
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a { content: "// hidden"; }' })
      commands.update_immersive(bufnr)
      assert.equals(0, #calls)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '//', '//   ' })
      commands.update_immersive(bufnr)
      assert.equals(0, #calls)
    end)

    it('preserves injected ' .. form.ft .. ' slash comment boundaries', function()
      if not require_language(form.ft) or not require_language('html') then
        return
      end
      query(form.ft, '')
      query(
        'html',
        '(style_element (raw_text) @injection.content (#set! injection.language "'
          .. form.ft
          .. '"))'
      )
      config.setup({ targets = { comment = true, string = false } })
      local body = 'こんにちは "quoted"'
      if
        not fixture(
          'html',
          { '<style>', '// ' .. body, 'a { content: "// hidden"; }', '</style>' },
          2,
          4
        )
      then
        return
      end
      vim.bo[bufnr].commentstring = '<!-- %s -->'
      commands.enable_immersive(bufnr)
      expect_text(body)
      calls = {}
      request('hover')
      expect_text(body)
      assert.is_not_nil(vim.treesitter.get_parser(bufnr):children()[form.ft])
      calls = {}
      config.setup({ targets = { comment = false, string = true } })
      vim.api.nvim_win_set_cursor(0, { 2, ('// ' .. body):find('quoted', 1, true) - 1 })
      request('hover')
      commands.update_immersive(bufnr)
      assert.equals(0, #calls)
      config.setup({ targets = { comment = true, string = false } })
      for _, position in ipairs({ { 1, 1 }, { 3, 16 }, { 4, 1 } }) do
        vim.api.nvim_win_set_cursor(0, position)
        request('hover')
      end
      assert.equals(0, #calls)
    end)
  end

  for _, embedded in ipairs({ false, true }) do
    for _, form in ipairs({
      { name = 'simple', body = 'こんにちは // # $name' },
      { name = 'braced', body = 'こんにちは // # {$name}' },
      { name = 'quoted subscript', body = 'こんにちは // # {$names["key"]}' },
      { name = 'multiline', body = 'こんにちは // # \n$name' },
      { name = 'escaped quotes', body = 'こんにちは \\"quoted\\" // # $name' },
      { name = 'binary', body = 'こんにちは // # $name', binary = 'b' },
      { name = 'uppercase binary', body = 'こんにちは // # $name', binary = 'B' },
    }) do
      for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
        it(
          'preserves bounded PHP interpolation via '
            .. flow
            .. ' (embedded='
            .. tostring(embedded)
            .. ', form='
            .. form.name
            .. ')',
          function()
            if not require_language('php') or (embedded and not require_language('markdown')) then
              return
            end
            query('php', '')
            if embedded then
              query(
                'markdown',
                '(fenced_code_block (info_string) @injection.language'
                  .. ' (code_fence_content) @injection.content (#set! injection.include-children))'
              )
            end
            local body = form.body
            local prefix = '<?php $label = "前"; $x = ' .. (form.binary or '')
            local lines =
              vim.split(prefix .. '"' .. body .. '"; $next = "outside";', '\n', { plain = true })
            local body_lines = vim.split(body, '\n', { plain = true })
            if embedded then
              table.insert(lines, 1, '```php')
              table.insert(lines, '```')
            end
            local row = embedded and 2 or 1
            if not fixture(embedded and 'markdown' or 'php', lines, row, #prefix) then
              return
            end
            vim.bo[bufnr].commentstring = embedded and '<!-- %s -->' or '// %s'
            config.setup({ targets = { comment = false, string = true } })
            -- Opening quote on first use must resolve the encapsed_string node.
            request(flow)
            expect_text(body)
            local root = original_get_parser(bufnr)
            local language_tree = embedded and root:children().php or root
            assert.is_not_nil(language_tree)
            local tree = language_tree:tree_for_range({ row - 1, #prefix, row - 1, #prefix + 1 })
            assert.is_false(tree:root():has_error())
            local node = tree:root():named_descendant_for_range(row - 1, #prefix, row - 1, #prefix)
            assert.equals('encapsed_string', node:type())
            local variable
            for index, line in ipairs(body_lines) do
              local col = line:find('$', 1, true)
              if col then
                variable = { row + index - 1, index == 1 and #prefix + col or col - 1 }
                break
              end
            end
            local end_row = row + #body_lines - 1
            local end_col = #body_lines[#body_lines] + (#body_lines == 1 and #prefix + 1 or 0)
            local positions = { { row, #prefix }, variable, { end_row, end_col } }
            for _, position in ipairs(positions) do
              calls = {}
              vim.api.nvim_win_set_cursor(0, position)
              request(flow)
              expect_text(body)
            end
            calls = {}
            config.setup({ targets = { comment = true, string = true } })
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
            if form.name == 'quoted subscript' then
              -- Preserve the closest target for literal content and inner strings.
              vim.api.nvim_win_set_cursor(0, { row, #prefix + 1 })
              request(flow)
              expect_text('こんにちは // #')
              calls = {}
              vim.api.nvim_win_set_cursor(0, { row, #prefix + body:find('"key"', 1, true) })
              request(flow)
              expect_text('key')
              calls = {}
            end
            for _, comment in ipairs({ true, false }) do
              config.setup({ targets = { comment = comment, string = false } })
              calls = {}
              for _, position in ipairs(positions) do
                vim.api.nvim_win_set_cursor(0, position)
                request(flow)
              end
              commands.enable_immersive(bufnr)
              assert.equals(0, #calls)
            end
            config.setup({ targets = { comment = true, string = true } })
            for _, position in ipairs({ { row, 0 }, { end_row, end_col + 1 } }) do
              vim.api.nvim_win_set_cursor(0, position)
              request(flow)
            end
            assert.equals(0, #calls)
            vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { '<?php // "quoted $name"' })
            vim.api.nvim_win_set_cursor(0, { row, 18 })
            config.setup({ targets = { comment = false, string = true } })
            request(flow)
            commands.update_immersive(bufnr)
            assert.equals(0, #calls)
          end
        )
      end
    end
  end

  for _, embedded in ipairs({ false, true }) do
    for _, body in ipairs({ 'こんにちは // # {$names["key"]}', 'こんにちは // # \n$name' }) do
      it(
        'suppresses PHP strings on first-use immersive (embedded='
          .. tostring(embedded)
          .. ', multiline='
          .. tostring(body:find('\n', 1, true) ~= nil)
          .. ')',
        function()
          if not require_language('php') or (embedded and not require_language('markdown')) then
            return
          end
          query('php', '')
          if embedded then
            query(
              'markdown',
              '(fenced_code_block (info_string) @injection.language'
                .. ' (code_fence_content) @injection.content (#set! injection.include-children))'
            )
          end
          local lines = vim.split('<?php $x = "' .. body .. '";', '\n', { plain = true })
          if embedded then
            table.insert(lines, 1, '```php')
            table.insert(lines, '```')
          end
          if not fixture(embedded and 'markdown' or 'php', lines) then
            return
          end
          config.setup({ targets = { comment = true, string = true } })
          commands.enable_immersive(bufnr)
          assert.equals(0, #calls)
          local root = original_get_parser(bufnr)
          local language_tree = embedded and root:children().php or root
          assert.is_not_nil(language_tree)
          assert.is_true(next(language_tree:trees()) ~= nil)
          for _, tree in pairs(language_tree:trees()) do
            assert.is_false(tree:root():has_error())
          end
        end
      )
    end
  end

  for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
    for _, form in ipairs({
      { name = 'missing closing quote', body = 'こんにちは {$names["key"]};' },
      { name = 'invalid interpolation', body = 'こんにちは {$name[}";' },
    }) do
      it('rejects incomplete PHP strings via ' .. flow .. ' (' .. form.name .. ')', function()
        if not require_language('php') then
          return
        end
        query('php', '')
        local prefix = '<?php $x = '
        if not fixture('php', { prefix .. '"' .. form.body }, 1, #prefix) then
          return
        end
        config.setup({ targets = { comment = true, string = true } })
        request(flow)
        assert.equals(0, #calls)
        local root = original_get_parser(bufnr):trees()[1]:root()
        assert.is_true(root:has_error())
        vim.api.nvim_win_set_cursor(0, { 1, #prefix + form.body:find('$', 1, true) })
        request(flow)
        assert.equals(0, #calls)
        config.setup({ targets = { comment = false, string = false } })
        request(flow)
        assert.equals(0, #calls)
      end)
    end
  end

  for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
    it('keeps PHP interpolation fallback available without a parser via ' .. flow, function()
      vim.treesitter.get_parser = function()
        error('parser unavailable')
      end
      vim.bo[bufnr].filetype = 'php'
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '<?php $x = "Hello $name";' })
      vim.api.nvim_win_set_cursor(0, { 1, 17 })
      config.setup({ targets = { comment = false, string = true } })
      request(flow)
      expect_text('Hello $name')
      calls = {}
      config.setup({ targets = { comment = true, string = false } })
      request(flow)
      assert.equals(0, #calls)
    end)
  end

  for _, form in ipairs({
    { ft = 'typescript', prefix = 'type Value = ', suffix = ';' },
    { ft = 'astro', prefix = '<div title=', suffix = ' />' },
  }) do
    for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
      it('preserves bounded ' .. form.ft .. ' backtick content via ' .. flow, function()
        if not require_language(form.ft) then
          return
        end
        query(form.ft, '')
        local body = 'こんにちは -- # /* body'
        local line = form.prefix .. '`' .. body .. '`' .. form.suffix
        if not fixture(form.ft, { line }, 1, #form.prefix + 1) then
          return
        end
        request(flow)
        expect_text(body)
        calls = {}
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)
        config.setup({ targets = { comment = true, string = false } })
        request(flow)
        assert.equals(0, #calls)
        config.setup({ targets = { comment = true, string = true } })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        request(flow)
        vim.api.nvim_win_set_cursor(0, { 1, #line - 1 })
        request(flow)
        assert.equals(0, #calls)
        local edited = 'updated'
        vim.api.nvim_buf_set_lines(
          bufnr,
          0,
          -1,
          false,
          { form.prefix .. '`' .. edited .. '`' .. form.suffix }
        )
        vim.api.nvim_win_set_cursor(0, { 1, #form.prefix + 1 })
        request(flow)
        expect_text(edited)
      end)
    end
  end

  for _, form in ipairs({
    {
      ft = 'dockerfile',
      open = 'RUN <<EOF',
      close = 'EOF',
      comment = '# ',
      string_prefix = 'echo ',
      lang = 'bash',
      injection = '(run_instruction (heredoc_block) @injection.content)',
    },
    {
      ft = 'astro',
      open = '---',
      close = '---',
      comment = '// ',
      string_prefix = 'const value = ',
      lang = 'typescript',
      injection = '(frontmatter (frontmatter_js_block) @injection.content)',
    },
  }) do
    for _, profile in ipairs({ 'parser only', 'injection query', 'missing injected parser' }) do
      for _, first in ipairs({ 'hover', 'immersive' }) do
        it(
          'restores bounded ' .. form.ft .. ' bodies with ' .. profile .. ' via ' .. first,
          function()
            if not require_language(form.ft) then
              return
            end
            local lang = profile == 'missing injected parser' and 'comment_translate_missing'
              or form.lang
            if profile == 'injection query' and not require_language(lang) then
              return
            end
            query(
              form.ft,
              profile == 'parser only' and ''
                or '('
                  .. form.injection
                  .. ' (#set! injection.language "'
                  .. lang
                  .. '") (#set! injection.include-children))'
            )
            local body = 'こんにちは'
            if
              not fixture(
                form.ft,
                { form.open, form.comment .. body, form.close },
                2,
                #form.comment
              )
            then
              return
            end
            vim.bo[bufnr].commentstring = form.ft == 'astro' and '<!-- %s -->' or '# %s'
            if first == 'immersive' then
              commands.enable_immersive(bufnr)
            else
              request('hover')
            end
            expect_text(body)
            if profile == 'injection query' then
              expect_child(form.lang)
            end
            calls = {}
            config.setup({ targets = { comment = false, string = false } })
            request('hover')
            commands.update_immersive(bufnr)
            assert.equals(0, #calls)
            config.setup({ targets = { comment = true, string = true } })
            for _, row in ipairs({ 1, 3 }) do
              vim.api.nvim_win_set_cursor(0, { row, 0 })
              request('hover')
            end
            assert.equals(0, #calls)
            vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { form.string_prefix .. '"updated"' })
            vim.api.nvim_win_set_cursor(0, { 2, #form.string_prefix + 1 })
            request('manual')
            expect_text(
              profile == 'injection query' and form.ft == 'astro' and '"updated"' or 'updated'
            )
            calls = {}
            commands.update_immersive(bufnr)
            assert.equals(0, #calls)
            config.setup({ targets = { comment = true, string = false } })
            request('auto')
            assert.equals(0, #calls)
            if profile == 'injection query' then
              vim.api.nvim_buf_set_lines(
                bufnr,
                1,
                2,
                false,
                { form.string_prefix .. '"updated # // hidden"' }
              )
              vim.api.nvim_win_set_cursor(0, { 2, #form.string_prefix + 10 })
              request('hover')
              commands.update_immersive(bufnr)
              assert.equals(0, #calls)
            end
            config.setup({ targets = { comment = true, string = true } })
            local line = form.comment .. 'changed'
            vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { line })
            vim.o.virtualedit = 'onemore'
            vim.api.nvim_win_set_cursor(0, { 2, #line })
            request('insert')
            expect_text('changed')
          end
        )
      end
    end
  end

  it('does not join Dockerfile block comments across heredoc delimiters', function()
    if not require_language('dockerfile') then
      return
    end
    query('dockerfile', '')
    if not fixture('dockerfile', { 'RUN <<EOF cat <<SECOND', '/*', 'EOF', '*/', 'SECOND' }) then
      return
    end
    commands.enable_immersive(bufnr)
    assert.equals(0, #calls)
  end)

  it('keeps Dockerfile COPY heredoc data outside RUN fallback', function()
    if not require_language('dockerfile') then
      return
    end
    query('dockerfile', '')
    if not fixture('dockerfile', { 'COPY <<EOF /data', '# "quoted"', 'EOF' }, 2, 4) then
      return
    end
    request('hover')
    commands.enable_immersive(bufnr)
    assert.equals(0, #calls)
  end)

  for _, form in ipairs({
    {
      ft = 'dockerfile',
      lang = 'bash',
      prefix = 'RUN --mount=type=cache,target=/tmp echo "',
      suffix = '"',
    },
    { ft = 'dockerfile', lang = 'bash', prefix = 'CMD echo "', suffix = '"' },
    { ft = 'dockerfile', lang = 'bash', prefix = 'ENTRYPOINT echo "', suffix = '"' },
    { ft = 'markdown', lang = 'markdown_inline', prefix = '前文 [link](url "', suffix = '")' },
    {
      ft = 'markdown',
      lang = 'markdown_inline',
      prefix = '| 前文 [link](url "',
      suffix = '") |',
      before = { '| title |', '| --- |' },
    },
  }) do
    for _, profile in ipairs({
      'native',
      'parser only',
      'injection query',
      'missing injected parser',
    }) do
      for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
        it(
          'restores bounded opaque quotes: ' .. form.prefix .. ', ' .. profile .. ', ' .. flow,
          function()
            if not require_language(form.ft) then
              return
            end
            local injected = profile == 'native' or profile == 'injection query'
            if injected and not require_language(form.lang) then
              return
            end
            local lang = profile == 'missing injected parser' and 'comment_translate_missing'
              or form.lang
            if profile ~= 'native' then
              local content = form.ft == 'dockerfile'
                  and '(shell_command (shell_fragment) @injection.content)'
                or '[(inline) (pipe_table_cell)] @injection.content'
              query(
                form.ft,
                profile == 'parser only' and ''
                  or '(' .. content .. ' (#set! injection.language "' .. lang .. '"))'
              )
            end
            if injected then
              query(form.lang, '')
            end
            local body = 'こんにちは'
            local lines = vim.deepcopy(form.before or {})
            local row = #lines + 1
            local line = form.prefix .. body .. form.suffix
            table.insert(lines, line)
            config.setup({ targets = { comment = true, string = true } })
            if not fixture(form.ft, lines, row, #form.prefix) then
              return
            end
            request(flow)
            expect_text(body)
            if injected then
              expect_child(form.lang)
            end
            assert.is_false(original_get_parser(bufnr):trees()[1]:root():has_error())
            calls = {}
            config.setup({ targets = { comment = true, string = false } })
            request(flow)
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
            config.setup({ targets = { comment = false, string = false } })
            request(flow)
            assert.equals(0, #calls)
            config.setup({ targets = { comment = false, string = true } })
            for _, col in ipairs({ 0, #line }) do
              vim.o.virtualedit = 'onemore'
              vim.api.nvim_win_set_cursor(0, { row, col })
              request(flow)
            end
            assert.equals(0, #calls)
            vim.api.nvim_buf_set_lines(
              bufnr,
              row - 1,
              row,
              false,
              { form.prefix .. 'updated' .. form.suffix }
            )
            vim.api.nvim_win_set_cursor(0, { row, #form.prefix })
            request(flow)
            expect_text('updated')
            if injected then
              calls = {}
              config.setup({ targets = { comment = true, string = false } })
              vim.api.nvim_buf_set_lines(
                bufnr,
                row - 1,
                row,
                false,
                { form.prefix .. 'alpha -- # hidden' .. form.suffix }
              )
              vim.api.nvim_win_set_cursor(0, { row, #form.prefix + 10 })
              request(flow)
              commands.update_immersive(bufnr)
              assert.equals(0, #calls)
            end
          end
        )
      end
    end
  end

  for _, ft in ipairs({ 'dockerfile', 'markdown' }) do
    it('does not join block comments across new opaque regions: ' .. ft, function()
      if not require_language(ft) then
        return
      end
      query(ft, '')
      local lines = ft == 'dockerfile' and { 'RUN echo /* first', 'CMD echo last */' }
        or { '/* first', '', 'last */' }
      if not fixture(ft, lines) then
        return
      end
      commands.enable_immersive(bufnr)
      assert.equals(0, #calls)
    end)
  end

  for _, form in ipairs({
    { ft = 'dockerfile', prefix = 'RUN ', suffix = '', node = '(shell_fragment)' },
    { ft = 'markdown', prefix = '', suffix = '', node = '(inline)' },
    {
      ft = 'markdown',
      prefix = '| ',
      suffix = ' |',
      node = '(pipe_table_row (pipe_table_cell) @injection.content)',
      before = { '| title |', '| --- |' },
    },
  }) do
    for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
      it(
        'clips new opaque fallback around partial parsed coverage: ' .. form.node .. ', ' .. flow,
        function()
          if not require_language(form.ft) or not require_language('lua') then
            return
          end
          local unparsed, parsed = '"こんにちは" ', 'return "hidden -- # hidden"'
          query(
            form.ft,
            '('
              .. form.node
              .. (form.before and '' or ' @injection.content')
              .. ' (#set! injection.language "lua") (#offset! @injection.content 0 '
              .. #unparsed
              .. ' 0 0))'
          )
          query('lua', '')
          local lines = vim.deepcopy(form.before or {})
          local row = #lines + 1
          table.insert(lines, form.prefix .. unparsed .. parsed .. form.suffix)
          if not fixture(form.ft, lines, row, #form.prefix + 2) then
            return
          end
          request(flow)
          expect_text('こんにちは')
          expect_child('lua')
          calls = {}
          config.setup({ targets = { comment = true, string = false } })
          vim.api.nvim_win_set_cursor(0, { row, #form.prefix + #unparsed + 10 })
          request(flow)
          commands.enable_immersive(bufnr)
          assert.equals(0, #calls)
          config.setup({ targets = { comment = false, string = true } })
          local unclosed = '"unterminated' .. string.rep(' ', #unparsed - #'"unterminated')
          vim.api.nvim_buf_set_lines(
            bufnr,
            row - 1,
            row,
            false,
            { form.prefix .. unclosed .. parsed .. form.suffix }
          )
          vim.api.nvim_win_set_cursor(0, { row, #form.prefix + 2 })
          request(flow)
          assert.equals(0, #calls)
        end
      )
    end
  end

  it('retains approximate quote detection in unparsed Markdown prose', function()
    if not require_language('markdown') then
      return
    end
    query('markdown', '')
    if not fixture('markdown', { '前文 "こんにちは" 後文' }, 1, #'前文 "') then
      return
    end
    request('auto')
    expect_text('こんにちは')
  end)

  for _, profile in ipairs({ 'parser only', 'JSON injection' }) do
    for _, instruction in ipairs({ 'RUN', 'CMD', 'ENTRYPOINT', 'SHELL' }) do
      for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
        it(
          'keeps Dockerfile '
            .. instruction
            .. ' JSON strings bounded via '
            .. flow
            .. ' ('
            .. profile
            .. ')',
          function()
            if not require_language('dockerfile') then
              return
            end
            if profile == 'JSON injection' and not require_language('json') then
              return
            end
            query(
              'dockerfile',
              profile == 'parser only' and ''
                or '((json_string_array) @injection.content'
                  .. ' (#set! injection.language "json") (#set! injection.include-children))'
            )
            if profile == 'JSON injection' then
              query('json', '')
            end
            local prefix = instruction .. ' ["echo", "'
            local body = 'こんにちは # -- \\"quoted\\"'
            local line = prefix .. body .. '"]'
            if not fixture('dockerfile', { line }, 1, #prefix) then
              return
            end
            config.setup({ targets = { comment = false, string = true } })
            request(flow)
            expect_text(body)
            local root = original_get_parser(bufnr)
            assert.is_false(root:trees()[1]:root():has_error())
            local node = root:trees()[1]:root():named_descendant_for_range(0, #prefix, 0, #prefix)
            assert.equals('json_string', node:type())
            assert.equals(profile == 'JSON injection', root:children().json ~= nil)

            calls = {}
            config.setup({ targets = { comment = true, string = false } })
            vim.api.nvim_win_set_cursor(0, { 1, #prefix + #'こんにちは ' })
            request(flow)
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
            config.setup({ targets = { comment = false, string = false } })
            request(flow)
            assert.equals(0, #calls)

            config.setup({ targets = { comment = true, string = true } })
            vim.api.nvim_win_set_cursor(0, { 1, #instruction + 3 })
            request(flow)
            expect_text('echo')
            calls = {}
            for _, col in ipairs({ 0, #instruction + 1, #prefix - 3, #line - 1, #line }) do
              vim.o.virtualedit = 'onemore'
              vim.api.nvim_win_set_cursor(0, { 1, col })
              request(flow)
            end
            commands.update_immersive(bufnr)
            assert.equals(0, #calls)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { prefix .. 'edited"]' })
            vim.api.nvim_win_set_cursor(0, { 1, #prefix })
            request(flow)
            expect_text('edited')
          end
        )
      end
    end
  end

  for _, profile in ipairs({ 'parser only', 'native queries' }) do
    for _, instruction in ipairs({ 'COPY', 'ADD' }) do
      for _, quote in ipairs({ '"', "'" }) do
        for _, flow in ipairs({ 'hover', 'manual', 'auto', 'insert' }) do
          it(
            'keeps Dockerfile '
              .. instruction
              .. ' quoted paths bounded via '
              .. flow
              .. ' ('
              .. profile
              .. ', '
              .. quote
              .. ')',
            function()
              if not require_language('dockerfile') then
                return
              end
              if profile == 'parser only' then
                query('dockerfile', '')
              end
              local prefix = instruction .. ' '
              local body = 'こんにちは world'
              local source = quote .. body .. quote
              local destination = '/行き先 世界/'
              local middle = ' plain '
              local dest_prefix = prefix .. source .. middle
              local line = dest_prefix .. quote .. destination .. quote
              if not fixture('dockerfile', { line }, 1, #prefix + #quote) then
                return
              end
              config.setup({ targets = { comment = false, string = true } })
              request(flow)
              expect_text(body)
              local root = original_get_parser(bufnr):trees()[1]:root()
              assert.is_false(root:has_error())
              local node = root:named_descendant_for_range(0, #prefix + 1, 0, #prefix + 1)
              assert.equals('path', node:type())
              assert.equals(instruction:lower() .. '_instruction', node:parent():type())

              calls = {}
              for _, col in ipairs({
                #prefix,
                #prefix + #quote + #'こんにちは',
                #prefix + #source - 1,
              }) do
                vim.api.nvim_win_set_cursor(0, { 1, col })
                request(flow)
                expect_text(body)
                calls = {}
              end
              vim.api.nvim_win_set_cursor(0, { 1, #dest_prefix + #quote })
              request(flow)
              expect_text(destination)

              calls = {}
              config.setup({ targets = { comment = true, string = false } })
              for _, col in ipairs({ #prefix + #quote + #'こんにちは ', #dest_prefix + #quote }) do
                vim.api.nvim_win_set_cursor(0, { 1, col })
                request(flow)
              end
              commands.enable_immersive(bufnr)
              assert.equals(0, #calls)
              config.setup({ targets = { comment = false, string = false } })
              request(flow)
              assert.equals(0, #calls)

              config.setup({ targets = { comment = true, string = true } })
              for _, col in ipairs({
                0,
                #instruction,
                #prefix + #source,
                #prefix + #source + 2,
                #dest_prefix - 1,
                #line,
              }) do
                vim.o.virtualedit = 'onemore'
                vim.api.nvim_win_set_cursor(0, { 1, col })
                request(flow)
              end
              commands.update_immersive(bufnr)
              assert.equals(0, #calls)
              vim.api.nvim_win_set_cursor(0, { 1, #prefix + #quote })
              request(flow)
              expect_text(body)

              calls = {}
              vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { prefix .. 'plain /app/' })
              for _, col in ipairs({ #prefix, #prefix + #'plain ' }) do
                vim.api.nvim_win_set_cursor(0, { 1, col })
                request(flow)
              end
              assert.equals(0, #calls)
              config.setup({ targets = { comment = true, string = false } })
              request(flow)
              assert.equals(0, #calls)
            end
          )
        end
      end
    end
  end

  for _, instruction in ipairs({ 'COPY', 'ADD' }) do
    for _, flow in ipairs({ 'hover', 'auto' }) do
      it('limits Dockerfile ' .. instruction .. ' path recovery via ' .. flow, function()
        if not require_language('dockerfile') then
          return
        end
        query('dockerfile', '')
        local option = instruction == 'COPY' and '--from="stage"' or '--checksum="value"'
        local prefix = instruction .. ' ' .. option .. ' '
        local body = 'こんにちは world'
        if
          not fixture('dockerfile', { prefix .. '"' .. body .. '" /app/' }, 1, #instruction + 10)
        then
          return
        end
        config.setup({ targets = { comment = false, string = true } })
        request(flow)
        assert.equals(0, #calls)
        vim.api.nvim_win_set_cursor(0, { 1, #prefix + 1 })
        request(flow)
        expect_text(body)
        assert.is_false(original_get_parser(bufnr):trees()[1]:root():has_error())

        calls = {}
        local json_prefix = instruction .. ' ["'
        local destination = '/行き先 世界/'
        if
          not fixture(
            'dockerfile',
            { json_prefix .. body .. '", "' .. destination .. '"]' },
            1,
            #json_prefix
          )
        then
          return
        end
        request(flow)
        expect_text(body)
        calls = {}
        vim.api.nvim_win_set_cursor(0, { 1, #json_prefix + #body + #'", "' })
        request(flow)
        expect_text(destination)
        assert.is_false(original_get_parser(bufnr):trees()[1]:root():has_error())
        calls = {}
        config.setup({ targets = { comment = true, string = false } })
        request(flow)
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)

        config.setup({ targets = { comment = false, string = true } })
        if
          not fixture(
            'dockerfile',
            { instruction .. ' "unfinished /app/', 'ENV OTHER="outside"' },
            1,
            #instruction + 2
          )
        then
          return
        end
        request(flow)
        assert.equals(0, #calls)
        if
          not fixture(
            'dockerfile',
            { instruction .. ' <<EOF /data', 'inside "hidden"', 'EOF' },
            2,
            #'inside "'
          )
        then
          return
        end
        request(flow)
        commands.update_immersive(bufnr)
        assert.equals(0, #calls)
      end)
    end
  end

  for _, instruction in ipairs({ 'COPY', 'ADD' }) do
    it(
      'preserves injected Dockerfile ' .. instruction .. ' path boundaries on first use',
      function()
        if not require_language('markdown') or not require_language('dockerfile') then
          return
        end
        query(
          'markdown',
          '((fenced_code_block (code_fence_content) @injection.content)'
            .. ' (#set! injection.language "dockerfile"))'
        )
        query('dockerfile', '')
        local prefix = instruction .. ' "'
        local body = 'こんにちは world'
        local line = prefix .. body .. '" /app/'
        if not fixture('markdown', { '```dockerfile', line, '```' }, 2, #prefix) then
          return
        end
        config.setup({ targets = { comment = false, string = true } })
        request('auto')
        expect_text(body)
        expect_child('dockerfile')
        calls = {}
        config.setup({ targets = { comment = true, string = false } })
        request('auto')
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)
        config.setup({ targets = { comment = true, string = true } })
        for _, position in ipairs({ { 1, 0 }, { 2, 0 }, { 2, #prefix + #body + 3 }, { 3, 0 } }) do
          vim.api.nvim_win_set_cursor(0, position)
          request('auto')
        end
        commands.update_immersive(bufnr)
        assert.equals(0, #calls)
      end
    )
  end

  for _, instruction in ipairs({ 'COPY', 'ADD' }) do
    for _, flow in ipairs({ 'hover', 'auto' }) do
      it('rejects nonliteral Dockerfile ' .. instruction .. ' quotes via ' .. flow, function()
        if not require_language('dockerfile') then
          return
        end
        query('dockerfile', '')
        config.setup({ targets = { comment = true, string = true } })
        local prefix = instruction .. ' '
        for _, escape in ipairs({ '\\', '`' }) do
          local path = 'foo' .. escape .. '"unquoted"quoted"'
          local lines = { '# escape=' .. escape, prefix .. path .. ' /app/' }
          if not fixture('dockerfile', lines, 2, #prefix + #'foo' + #escape + 1) then
            return
          end
          request(flow)
          assert.equals(0, #calls)
          vim.api.nvim_win_set_cursor(0, { 2, #prefix + #'foo' + #escape + #'"unquoted"' })
          request(flow)
          expect_text('quoted')
          calls = {}
          config.setup({ targets = { comment = true, string = false } })
          request(flow)
          assert.equals(0, #calls)
          config.setup({ targets = { comment = false, string = false } })
          commands.enable_immersive(bufnr)
          assert.equals(0, #calls)
          local json_body = [=[hello \"quoted\" world]=]
          local json_prefix = instruction .. ' ["'
          if
            not fixture(
              'dockerfile',
              { lines[1], json_prefix .. json_body .. '", "/app/"]' },
              2,
              #json_prefix
            )
          then
            return
          end
          config.setup({ targets = { comment = false, string = true } })
          request(flow)
          expect_text(json_body)
          calls = {}
          vim.api.nvim_win_set_cursor(0, { 2, #json_prefix + #'hello "' })
          request(flow)
          expect_text(json_body)
          calls = {}
          config.setup({ targets = { comment = true, string = false } })
          request(flow)
          assert.equals(0, #calls)
          config.setup({ targets = { comment = false, string = false } })
          request(flow)
          assert.equals(0, #calls)
          config.setup({ targets = { comment = true, string = true } })
          vim.api.nvim_win_set_cursor(0, { 2, #json_prefix + #json_body + #'", "' })
          request(flow)
          expect_text('/app/')
          calls = {}
        end
        if not fixture('dockerfile', { prefix .. '`unquoted` /app/' }, 1, #prefix + 1) then
          return
        end
        request(flow)
        assert.equals(0, #calls)
        for _, quote in ipairs({ '"', "'" }) do
          if
            not fixture(
              'dockerfile',
              { prefix .. '<<' .. quote .. 'EOF' .. quote .. ' /data', 'body', 'EOF' },
              1,
              #prefix + 3
            )
          then
            return
          end
          request(flow)
          assert.equals(0, #calls)
          assert.is_false(original_get_parser(bufnr):trees()[1]:root():has_error())
        end
        if
          not fixture(
            'dockerfile',
            { prefix .. '"quoted source" plain <<"EOF" /data', 'body', 'EOF' },
            1,
            #prefix + 1
          )
        then
          return
        end
        request(flow)
        expect_text('quoted source')
      end)
    end
  end

  for _, profile in ipairs({ 'parser only', 'native queries' }) do
    for _, instruction in ipairs({ 'COPY', 'ADD' }) do
      for _, form in ipairs({ 'compact JSON', 'hash path', 'hash JSON' }) do
        for _, flow in ipairs({ 'hover', 'manual', 'auto', 'insert' }) do
          it(
            'recovers Dockerfile '
              .. instruction
              .. ' '
              .. form
              .. ' via '
              .. flow
              .. ' ('
              .. profile
              .. ')',
            function()
              if not require_language('dockerfile') then
                return
              end
              if profile == 'parser only' then
                query('dockerfile', '')
              end
              local prefix = instruction .. ' '
              local body = form == 'compact JSON' and 'こんにちは' or 'こんにちは # world'
              local destination = '/行き先 # 世界/'
              local line = form == 'hash path'
                  and prefix .. '"' .. body .. '" "' .. destination .. '"'
                or prefix .. '["' .. body .. '","' .. destination .. '"]'
              if
                not fixture(
                  'dockerfile',
                  { line, '# genuine comment' },
                  1,
                  #prefix + (form == 'hash path' and 1 or 2)
                )
              then
                return
              end
              config.setup({ targets = { comment = false, string = true } })
              request(flow)
              expect_text(body)
              calls = {}
              local dest_col = assert(line:find(destination, 1, true)) - 1
              vim.api.nvim_win_set_cursor(0, { 1, dest_col })
              request(flow)
              expect_text(destination)
              calls = {}
              config.setup({ targets = { comment = true, string = false } })
              request(flow)
              assert.equals(0, #calls)
              commands.enable_immersive(bufnr)
              expect_text('genuine comment')
              calls = {}
              config.setup({ targets = { comment = false, string = false } })
              request(flow)
              commands.update_immersive(bufnr)
              assert.equals(0, #calls)
              config.setup({ targets = { comment = true, string = true } })
              for _, col in ipairs({ 0, #instruction, #line }) do
                vim.o.virtualedit = 'onemore'
                vim.api.nvim_win_set_cursor(0, { 1, col })
                request(flow)
              end
              assert.equals(0, #calls)
            end
          )
        end
      end
    end
  end

  for _, instruction in ipairs({ 'COPY', 'ADD' }) do
    for _, quote in ipairs({ '"', "'" }) do
      it(
        'withholds misparsed Dockerfile ' .. instruction .. ' comment tails with ' .. quote,
        function()
          if not require_language('dockerfile') then
            return
          end
          query('dockerfile', '')
          local prefix = instruction .. ' ' .. quote
          local body = 'こんにちは # world'
          local line = prefix .. body .. quote .. ' /app/'
          if not fixture('dockerfile', { line }, 1, #prefix + #'こんにちは # ') then
            return
          end
          config.setup({ targets = { comment = true, string = true } })
          request('auto')
          expect_text(body)
          calls = {}
          vim.api.nvim_win_set_cursor(0, { 1, #line - #'/app/' })
          request('auto')
          commands.enable_immersive(bufnr)
          assert.equals(0, #calls)
          config.setup({ targets = { comment = true, string = false } })
          vim.api.nvim_win_set_cursor(0, { 1, #prefix + #'こんにちは # ' })
          request('auto')
          assert.equals(0, #calls)
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { prefix .. body, 'ENV OTHER="outside"' })
          request('auto')
          commands.update_immersive(bufnr)
          assert.equals(0, #calls)
          config.setup({ targets = { comment = true, string = true } })
          request('auto')
          commands.update_immersive(bufnr)
          assert.equals(0, #calls)
        end
      )
    end
  end

  for _, instruction in ipairs({ 'COPY', 'ADD' }) do
    for _, form in ipairs({ 'compact JSON', 'hash path' }) do
      for _, first in ipairs({ 'hover', 'immersive' }) do
        it(
          'recovers injected ' .. instruction .. ' ' .. form .. ' with ' .. first .. ' first',
          function()
            if not require_language('markdown') or not require_language('dockerfile') then
              return
            end
            query(
              'markdown',
              '((fenced_code_block (code_fence_content) @injection.content)'
                .. ' (#set! injection.language "dockerfile"))'
            )
            query('dockerfile', '')
            local prefix = instruction .. ' '
            local body = 'こんにちは # world'
            local line = form == 'compact JSON' and prefix .. '["' .. body .. '","/app/"]'
              or prefix .. '"' .. body .. '" /app/'
            local col = #prefix + (form == 'compact JSON' and 2 or 1)
            if not fixture('markdown', { '```dockerfile', line, '```' }, 2, col) then
              return
            end
            config.setup({ targets = { comment = true, string = false } })
            if first == 'hover' then
              request('auto')
            else
              commands.enable_immersive(bufnr)
            end
            assert.equals(0, #calls)
            expect_child('dockerfile')
            config.setup({ targets = { comment = false, string = true } })
            request('auto')
            expect_text(body)
            calls = {}
            vim.api.nvim_win_set_cursor(0, { 3, 0 })
            request('auto')
            assert.equals(0, #calls)
          end
        )
      end
    end
  end

  for _, instruction in ipairs({ 'COPY', 'ADD' }) do
    it('preserves parsed ' .. instruction .. ' paths before a line continuation', function()
      if not require_language('dockerfile') then
        return
      end
      query('dockerfile', '')
      if not fixture('dockerfile', { instruction .. ' "hello world" \\', '  /app/' }, 1, 8) then
        return
      end
      config.setup({ targets = { comment = true, string = true } })
      request('auto')
      expect_text('hello world')
      calls = {}
      config.setup({ targets = { comment = true, string = false } })
      request('auto')
      commands.enable_immersive(bufnr)
      assert.equals(0, #calls)
    end)

    for _, prefix in ipairs({ instruction .. ' --chown="owner" ', 'ONBUILD ' .. instruction .. ' ' }) do
      it('recovers compact JSON after ' .. prefix, function()
        if not require_language('dockerfile') then
          return
        end
        query('dockerfile', '')
        local body = 'hello # world'
        if
          not fixture('dockerfile', { prefix .. '["' .. body .. '","/app/"]' }, 1, #prefix + 2)
        then
          return
        end
        config.setup({ targets = { comment = true, string = true } })
        request('auto')
        expect_text(body)
        calls = {}
        if prefix:find('--chown', 1, true) then
          vim.api.nvim_win_set_cursor(0, { 1, #instruction + #' --chown="' })
          request('auto')
          assert.equals(0, #calls)
        end
        config.setup({ targets = { comment = true, string = false } })
        vim.api.nvim_win_set_cursor(0, { 1, #prefix + 2 })
        request('auto')
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)
      end)
    end

    it('withholds invalid ' .. instruction .. ' JSON recovery', function()
      if not require_language('dockerfile') then
        return
      end
      query('dockerfile', '')
      config.setup({ targets = { comment = true, string = true } })
      for _, arguments in ipairs({
        '["hello # world"]',
        '["hello # world",null]',
        '["hello # world","/app/"',
        '["hello # world","/app/"] trailing',
      }) do
        local prefix = instruction .. ' ["'
        if
          not fixture('dockerfile', { instruction .. ' ' .. arguments }, 1, #prefix + #'hello # ')
        then
          return
        end
        request('auto')
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)
      end
    end)
  end

  it('withholds Dockerfile recovery across disjoint root regions', function()
    if not require_language('dockerfile') then
      return
    end
    query('dockerfile', '')
    local first = 'COPY "hello '
    local hole = 'HOST'
    local last = ' world" /app/'
    local line = first .. hole .. last
    if not fixture('dockerfile', { line }, 1, #'COPY "') then
      return
    end
    original_get_parser(bufnr):set_included_regions({
      { { 0, 0, 0, #first }, { 0, #first + #hole, 0, #line } },
    })
    config.setup({ targets = { comment = true, string = true } })
    request('auto')
    commands.enable_immersive(bufnr)
    assert.equals(0, #calls)
  end)

  for _, instruction in ipairs({ 'COPY', 'ADD' }) do
    for _, kind in ipairs({ 'path', 'option' }) do
      it(
        'withholds misparsed ' .. instruction .. ' quoted ' .. kind .. ' on a continuation row',
        function()
          if not require_language('dockerfile') then
            return
          end
          query('dockerfile', '')
          local line = kind == 'path' and '  "hello # world" /app/'
            or '  --exclude="private # pattern" "src" /app/'
          if not fixture('dockerfile', { instruction .. ' \\', line }, 2, #line - 7) then
            return
          end
          for _, enabled in ipairs({ false, true }) do
            config.setup({ targets = { comment = true, string = enabled } })
            request('auto')
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
          end
        end
      )
    end

    it(
      'preserves genuine comments and parsed ' .. instruction .. ' paths on continuation rows',
      function()
        if not require_language('dockerfile') then
          return
        end
        query('dockerfile', '')
        if
          not fixture(
            'dockerfile',
            { instruction .. ' \\', '# genuine comment', '  "hello world" /app/' },
            3,
            4
          )
        then
          return
        end
        config.setup({ targets = { comment = false, string = true } })
        request('auto')
        expect_text('hello world')
        calls = {}
        config.setup({ targets = { comment = true, string = false } })
        request('auto')
        assert.equals(0, #calls)
        commands.enable_immersive(bufnr)
        expect_text('genuine comment')
        calls = {}
        vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { '  "hello # world" /app/' })
        request('auto')
        assert.equals(0, #calls)
        commands.update_immersive(bufnr)
        expect_text('genuine comment')
      end
    )

    for _, option in ipairs({
      '--exclude="private # pattern"',
      '--link --exclude="hidden"',
      [[--exclude='private \' # pattern']],
    }) do
      it('excludes complete ' .. instruction .. ' option words: ' .. option, function()
        if not require_language('dockerfile') then
          return
        end
        query('dockerfile', '')
        local body = 'source # body'
        local prefix = instruction .. ' ' .. option .. ' '
        local line = prefix .. '["' .. body .. '","/app/"]'
        if not fixture('dockerfile', { line }, 1, #prefix + 2) then
          return
        end
        config.setup({ targets = { comment = true, string = true } })
        request('auto')
        expect_text(body)
        calls = {}
        for _, col in ipairs({ assert(line:find('=', 1, true)) + 1, #prefix - 1 }) do
          vim.api.nvim_win_set_cursor(0, { 1, col })
          request('auto')
        end
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)
        config.setup({ targets = { comment = true, string = false } })
        vim.api.nvim_win_set_cursor(0, { 1, #prefix + 2 })
        request('auto')
        commands.update_immersive(bufnr)
        assert.equals(0, #calls)
      end)
    end

    it('preserves ' .. instruction .. ' path fragments after the flag separator', function()
      if not require_language('dockerfile') then
        return
      end
      query('dockerfile', '')
      local prefix, body = instruction .. ' -- --source="', 'hello # world'
      if not fixture('dockerfile', { prefix .. body .. '" /app/' }, 1, #prefix + 7) then
        return
      end
      config.setup({ targets = { comment = true, string = true } })
      request('auto')
      expect_text(body)
      calls = {}
      config.setup({ targets = { comment = true, string = false } })
      request('auto')
      commands.enable_immersive(bufnr)
      assert.equals(0, #calls)
    end)

    for _, form in ipairs({ 'hash path', 'hash JSON' }) do
      it(
        'withholds ' .. instruction .. ' false comments at an injected region end: ' .. form,
        function()
          if not require_language('markdown') or not require_language('dockerfile') then
            return
          end
          query(
            'markdown',
            '((fenced_code_block (code_fence_content) @injection.content)'
              .. ' (#set! injection.language "dockerfile"))'
          )
          query('dockerfile', '')
          local body = 'hello # world'
          local prefix = instruction .. ' '
          local line = form == 'hash path' and prefix .. '"' .. body .. '" /app/'
            or prefix .. '["' .. body .. '","/app/"]'
          if not fixture('markdown', { '```dockerfile', line, '```' }, 2, 0) then
            return
          end
          local host = original_get_parser(bufnr)
          host:parse(true)
          local child = assert(host:children().dockerfile)
          child:set_included_regions({ { { 1, 0, 1, #line } } })
          vim.o.virtualedit = 'onemore'
          vim.api.nvim_win_set_cursor(0, { 2, #line })
          config.setup({ targets = { comment = true, string = false } })
          request('insert')
          commands.enable_immersive(bufnr)
          assert.equals(0, #calls)
          config.setup({ targets = { comment = true, string = true } })
          vim.api.nvim_win_set_cursor(0, { 2, #prefix + (form == 'hash path' and 1 or 2) })
          request('insert')
          expect_text(body)
          calls = {}
          vim.api.nvim_win_set_cursor(0, { 2, #line })
          request('insert')
          assert.equals(0, #calls)

          line = '# genuine comment'
          vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { line })
          host:parse(true)
          child:set_included_regions({ { { 1, 0, 1, #line } } })
          vim.api.nvim_win_set_cursor(0, { 2, #line })
          request('insert')
          expect_text('genuine comment')
        end
      )
    end

    it(
      'withholds nested comments inside misparsed ' .. instruction .. ' paths on first use',
      function()
        if
          not require_language('markdown')
          or not require_language('dockerfile')
          or not require_language('bash')
        then
          return
        end
        query(
          'markdown',
          '((fenced_code_block (code_fence_content) @injection.content)'
            .. ' (#set! injection.language "dockerfile"))'
        )
        query('dockerfile', '((comment) @injection.content (#set! injection.language "bash"))')
        query('bash', '')
        local prefix, body = instruction .. ' "', 'hello # world'
        if
          not fixture(
            'markdown',
            { '```dockerfile', prefix .. body .. '" /app/', '```' },
            2,
            #prefix + 7
          )
        then
          return
        end
        config.setup({ targets = { comment = true, string = false } })
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)
        expect_child('dockerfile')
        local dockerfile = original_get_parser(bufnr):children().dockerfile
        assert.is_truthy(dockerfile:children().bash)
        request('auto')
        assert.equals(0, #calls)
        config.setup({ targets = { comment = true, string = true } })
        request('auto')
        expect_text(body)
      end
    )
  end

  it('withholds Dockerfile recovery across disjoint injected regions', function()
    if not require_language('markdown') or not require_language('dockerfile') then
      return
    end
    query(
      'markdown',
      '((fenced_code_block (code_fence_content) @injection.content)'
        .. ' (#set! injection.language "dockerfile"))'
    )
    query('dockerfile', '')
    local first, hole, last = 'COPY "hello ', 'HOST', ' world" /app/'
    local line = first .. hole .. last
    if not fixture('markdown', { '```dockerfile', line, '```' }, 2, #'COPY "') then
      return
    end
    local host = original_get_parser(bufnr)
    host:parse(true)
    host:children().dockerfile:set_included_regions({
      { { 1, 0, 1, #first }, { 1, #first + #hole, 1, #line } },
    })
    config.setup({ targets = { comment = true, string = true } })
    request('auto')
    commands.enable_immersive(bufnr)
    assert.equals(0, #calls)
  end)

  it('keeps malformed Dockerfile JSON out of message history', function()
    if not require_language('dockerfile') then
      return
    end
    query('dockerfile', '')
    local message, history = vim.v.errmsg, vim.fn.execute('messages')
    for _, form in ipairs({
      { line = 'COPY ["synthetic-private","/app/"', col = 9 },
      { line = 'COPY [synthetic-private] /app/', col = 5 },
    }) do
      if not fixture('dockerfile', { form.line }, 1, form.col) then
        return
      end
      for _, targets in ipairs({
        { comment = false, string = false },
        { comment = true, string = true },
      }) do
        config.setup({ targets = targets })
        request('auto')
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)
        assert.is_true(vim.v.errmsg == message)
        assert.is_true(vim.fn.execute('messages') == history)
      end
    end
  end)

  for _, instruction in ipairs({ 'COPY', 'ADD' }) do
    for _, escape in ipairs({ '\\', '`' }) do
      for _, form in ipairs({ 'path', 'option', 'spanning quote' }) do
        for _, profile in ipairs({ 'parser only', 'nested injection' }) do
          it(
            'withholds logical '
              .. instruction
              .. ' continuation comments: '
              .. form
              .. ', '
              .. escape
              .. ', '
              .. profile,
            function()
              if not require_language('dockerfile') then
                return
              end
              query('dockerfile', '')
              local header = instruction
                .. ' '
                .. (form == 'spanning quote' and '"hello ' or '')
                .. escape
              local line = form == 'path' and '  "hello # world" /app/'
                or form == 'option' and '  --exclude="private # pattern" "src" /app/'
                or '  world # fragment" /app/'
              local lines = { '# escape=' .. escape, header, line, '# genuine comment' }
              local row, ft = 3, 'dockerfile'
              if profile == 'nested injection' then
                if not require_language('markdown') or not require_language('bash') then
                  return
                end
                query(
                  'markdown',
                  '((fenced_code_block (code_fence_content) @injection.content)'
                    .. ' (#set! injection.language "dockerfile"))'
                )
                query(
                  'dockerfile',
                  '((comment) @injection.content (#set! injection.language "bash"))'
                )
                query('bash', '')
                table.insert(lines, 1, '```dockerfile')
                table.insert(lines, '```')
                row, ft = row + 1, 'markdown'
              end
              if not fixture(ft, lines, row, assert(line:find('#', 1, true)) + 1) then
                return
              end
              config.setup({ targets = { comment = true, string = false } })
              request('auto')
              assert.equals(0, #calls)
              vim.o.virtualedit = 'onemore'
              vim.api.nvim_win_set_cursor(0, { row, #line })
              request('insert')
              assert.equals(0, #calls)
              commands.enable_immersive(bufnr)
              assert.equals(2, #calls)
              for _, text in ipairs(calls) do
                assert.is_true(text == 'escape=' .. escape or text == 'genuine comment')
              end
              calls = {}
              config.setup({ targets = { comment = false, string = true } })
              vim.api.nvim_win_set_cursor(0, { row, assert(line:find('#', 1, true)) + 1 })
              request('auto')
              assert.equals(0, #calls)
              if profile == 'nested injection' then
                expect_child('dockerfile')
                assert.is_truthy(original_get_parser(bufnr):children().dockerfile:children().bash)
              end
            end
          )
        end
      end
    end

    it('withholds parsed ' .. instruction .. ' continuation paths across root gaps', function()
      if not require_language('dockerfile') then
        return
      end
      query('dockerfile', '')
      local header, first, hole, last = instruction .. ' \\', '  "hello ', 'HOST', ' world" /app/'
      local line = first .. hole .. last
      if not fixture('dockerfile', { header, line }, 2, 5) then
        return
      end
      original_get_parser(bufnr):set_included_regions({
        {
          { 0, 0, 0, #header },
          { 1, 0, 1, #first },
          { 1, #first + #hole, 1, #line },
        },
      })
      config.setup({ targets = { comment = true, string = true } })
      request('auto')
      commands.enable_immersive(bufnr)
      assert.equals(0, #calls)
    end)

    it('does not classify inline ' .. instruction .. ' hash arguments as comments', function()
      if not require_language('dockerfile') then
        return
      end
      query('dockerfile', '')
      if
        not fixture(
          'dockerfile',
          { instruction .. ' plain#argument /app/', '# genuine comment' },
          1,
          16
        )
      then
        return
      end
      config.setup({ targets = { comment = true, string = true } })
      request('auto')
      assert.equals(0, #calls)
      commands.enable_immersive(bufnr)
      expect_text('genuine comment')
    end)
  end

  for _, escape in ipairs({ '\\', '`' }) do
    for _, instruction in ipairs({ 'COPY', 'ADD' }) do
      it('withholds ' .. instruction .. ' directly adjoining a continuation: ' .. escape, function()
        if not require_language('dockerfile') then
          return
        end
        query('dockerfile', '')
        local line = '  "hello # world" /app/'
        if
          not fixture('dockerfile', { '# escape=' .. escape, instruction .. escape, line }, 3, 11)
        then
          return
        end
        config.setup({ targets = { comment = true, string = false } })
        request('auto')
        assert.equals(0, #calls)
        vim.o.virtualedit = 'onemore'
        vim.api.nvim_win_set_cursor(0, { 3, #line })
        request('insert')
        assert.equals(0, #calls)
        commands.enable_immersive(bufnr)
        expect_text('escape=' .. escape)
      end)
    end

    it('does not continue COPY after an escaped escape token: ' .. escape, function()
      if not require_language('dockerfile') then
        return
      end
      query('dockerfile', '')
      if
        not fixture('dockerfile', {
          '# escape=' .. escape,
          'COPY plain /app/ ' .. escape .. escape,
          'ADD ["hello","/app/"]',
        }, 3, 7)
      then
        return
      end
      config.setup({ targets = { comment = false, string = true } })
      request('auto')
      expect_text('hello')
    end)
  end

  local quoted_forms = {
    { ft = 'sql', prefix = 'SELECT ', suffix = ';' },
    { ft = 'html', prefix = '<div title=', suffix = '></div>' },
    { ft = 'dockerfile', prefix = 'ENV NAME=', suffix = '' },
    { ft = 'fish', prefix = 'echo ', suffix = '' },
    { ft = 'scss', prefix = 'a { content: ', suffix = '; }' },
    { ft = 'toml', prefix = '', suffix = ' = 1' },
    { ft = 'java', prefix = 'class A { char value = ', suffix = '; }', character = true },
    { ft = 'bash', prefix = 'echo $', suffix = '', single_quote = true },
    { ft = 'swift', prefix = 'let value = ', suffix = '', double_quote = true },
    { ft = 'nix', prefix = '{ value = ', suffix = '; }', double_quote = true },
  }
  for _, form in ipairs(quoted_forms) do
    for _, quote in
      ipairs(
        form.double_quote and { '"' }
          or (form.character or form.single_quote) and { "'" }
          or { '"', "'" }
      )
    do
      local label = form.ft .. (quote == '"' and ' double quote' or ' single quote')
      it('preserves ' .. label .. ' content within its node', function()
        local text = form.character and 'あ' or 'こんにちは -- # /* body'
        if
          not fixture(
            form.ft,
            { form.prefix .. quote .. text .. quote .. form.suffix },
            1,
            #form.prefix + 1
          )
        then
          return
        end
        request('hover')
        expect_text(text)
        calls = {}
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)
      end)

      it('does not reclassify disabled ' .. label .. ' content', function()
        config.setup({ targets = { comment = true, string = false } })
        local text = form.character and 'a' or 'hello -- # /* body'
        if
          not fixture(
            form.ft,
            { form.prefix .. quote .. text .. quote .. form.suffix },
            1,
            #form.prefix + 1
          )
        then
          return
        end
        request('hover')
        assert.equals(0, #calls)
      end)
    end
    if form.prefix ~= '' then
      it('does not submit code outside the ' .. form.ft .. ' quoted node', function()
        local quote = (form.character or form.single_quote) and "'" or '"'
        local text = form.character and 'a' or 'hello'
        if not fixture(form.ft, { form.prefix .. quote .. text .. quote .. form.suffix }, 1, 0) then
          return
        end
        request('hover')
        assert.equals(0, #calls)
      end)
    end
  end

  for _, flow in ipairs({ 'hover', 'manual', 'insert' }) do
    for _, prefix in ipairs({ '-- ', 'local x = 1 -- ' }) do
      for _, text in ipairs({ 'hello', 'こんにちは' }) do
        local label = (prefix == '-- ' and 'standalone' or 'inline')
          .. (text == 'hello' and ' ASCII' or ' multibyte')
        it('preserves ' .. flow .. ' at the end of a ' .. label .. ' comment', function()
          vim.o.virtualedit = 'onemore'
          local line = prefix .. text
          if not fixture('lua', { line }, 1, #line) then
            return
          end
          assert.equals(#line, vim.api.nvim_win_get_cursor(0)[2])
          request(flow)
          expect_text(text)
        end)
      end
    end
  end

  it('does not reclassify an excluded comment at its insertion boundary', function()
    config.setup({ targets = { comment = false, string = true } })
    vim.o.virtualedit = 'onemore'
    local line = '-- "quoted"'
    if not fixture('lua', { line }, 1, #line) then
      return
    end
    request('insert')
    assert.equals(0, #calls)
  end)

  for _, line in ipairs({ 'local s = "hello -- hidden"', 'local x = 1', '' }) do
    it('does not expand insertion hover to the preceding string or code', function()
      vim.o.virtualedit = 'onemore'
      if not fixture('lua', { '-- previous comment', line }, 2, #line) then
        return
      end
      request('insert')
      assert.equals(0, #calls)
      config.setup({ targets = { comment = true, string = false } })
      request('insert')
      assert.equals(0, #calls)
    end)
  end

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

  for _, embedding in ipairs({
    {
      tag = 'script',
      lang = 'javascript',
      comment = '// こんにちは',
      str = 'const s = "hello world";',
      col = 12,
    },
    {
      tag = 'style',
      lang = 'css',
      comment = '/* こんにちは */',
      str = 'a { content: "hello world"; }',
      col = 15,
    },
  }) do
    for _, profile in ipairs({ 'parser only', 'injection query', 'missing injected parser' }) do
      it('preserves bounded HTML ' .. embedding.tag .. ' detection with ' .. profile, function()
        if not require_language('html') then
          return
        end
        local lang = profile == 'missing injected parser' and 'comment_translate_missing'
          or embedding.lang
        if profile == 'injection query' and not require_language(lang) then
          return
        end
        query(
          'html',
          profile == 'parser only' and ''
            or '('
              .. embedding.tag
              .. '_element (raw_text) @injection.content (#set! injection.language "'
              .. lang
              .. '"))'
        )
        if
          not fixture('html', {
            '<' .. embedding.tag .. '>',
            embedding.comment,
            embedding.str,
            '</' .. embedding.tag .. '>',
          }, 2, 4)
        then
          return
        end
        vim.bo[bufnr].commentstring = '<!-- %s -->'
        commands.enable_immersive(bufnr)
        expect_text('こんにちは')
        if profile == 'injection query' then
          expect_child(embedding.lang)
        end
        calls = {}
        request('hover')
        expect_text('こんにちは')
        calls = {}
        vim.api.nvim_win_set_cursor(0, { 3, embedding.col })
        request('hover')
        -- The pinned JS grammar returns its enclosing string node, including
        -- quotes; keep that established parsed extraction behavior.
        expect_text(
          profile == 'injection query' and embedding.lang == 'javascript' and '"hello world"'
            or 'hello world'
        )
        calls = {}
        config.setup({ targets = { comment = false, string = false } })
        request('hover')
        commands.update_immersive(bufnr)
        assert.equals(0, #calls)
        config.setup({ targets = { comment = true, string = true } })
        for _, row in ipairs({ 1, 4 }) do
          vim.api.nvim_win_set_cursor(0, { row, 0 })
          request('hover')
        end
        assert.equals(0, #calls)
        if profile == 'injection query' then
          config.setup({ targets = { comment = true, string = false } })
          vim.api.nvim_buf_set_lines(
            bufnr,
            2,
            3,
            false,
            { (embedding.str:gsub('hello world', 'alpha -- hidden')) }
          )
          vim.api.nvim_win_set_cursor(0, { 3, embedding.col })
          request('hover')
          assert.equals(0, #calls)
        end
      end)
    end
  end

  for _, embedding in ipairs(embeddings) do
    for _, profile in ipairs({ 'parser only', 'injection query', 'missing injected parser' }) do
      describe(embedding.ft .. ' ' .. profile, function()
        local function embedded(lines, row, col)
          if not require_language(embedding.ft) then
            return false
          end
          local injection = profile == 'parser only' and '' or embedding.injection
          if embedding.ft == 'vim' and injection ~= '' then
            if not vim_has_body() then
              injection = injection
                :gsub('%(script %(body%) @injection%.content', '(chunk) @injection.content')
                :gsub('%)%)%)$', '))')
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
          if profile == 'injection query' then
            expect_child('lua')
          end
          calls = {}
          commands.enable_immersive(bufnr)
          expect_text('こんにちは')
        end)

        it('preserves an embedded comment with immersive as the first operation', function()
          if not embedded({ embedding.open, '-- こんにちは', embedding.close }) then
            return
          end
          commands.enable_immersive(bufnr)
          expect_text('こんにちは')
          if profile == 'injection query' then
            expect_child('lua')
          end
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

        it('preserves an embedded comment at the insertion boundary on first use', function()
          vim.o.virtualedit = 'onemore'
          local line = '-- こんにちは'
          if not embedded({ embedding.open, line, embedding.close }, 2, #line) then
            return
          end
          request('insert')
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
          it('reparses an edit to an excluded string through immersive directly', function()
            config.setup({ targets = { comment = true, string = false } })
            if not embedded({ embedding.open, '-- hello', embedding.close }) then
              return
            end
            commands.enable_immersive(bufnr)
            expect_text('hello')
            calls = {}
            vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'local s = "alpha -- hidden"' })
            commands.update_immersive(bufnr)
            assert.equals(0, #calls)
          end)
          it('does not reclassify a disabled embedded comment at EOL', function()
            config.setup({ targets = { comment = false, string = true } })
            vim.o.virtualedit = 'onemore'
            local line = '-- "quoted"'
            if not embedded({ embedding.open, line, embedding.close }, 2, #line) then
              return
            end
            request('insert')
            assert.equals(0, #calls)
          end)

          it('does not send a disabled embedded string at EOL', function()
            config.setup({ targets = { comment = true, string = false } })
            vim.o.virtualedit = 'onemore'
            local line = 'local s = "alpha -- hidden"'
            if not embedded({ embedding.open, line, embedding.close }, 2, #line) then
              return
            end
            request('insert')
            assert.equals(0, #calls)
          end)

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

  for _, profile in ipairs({ 'native', '0.10 hull model' }) do
    for _, middle in ipairs({ 'unparsed', 'javascript' }) do
      local orders = middle == 'unparsed' and { 'lua first' } or { 'lua first', 'javascript first' }
      for _, order in ipairs(orders) do
        it(
          'keeps combined-injection gaps available: ' .. profile .. ', ' .. middle .. ', ' .. order,
          function()
            if not require_language('markdown') or not require_language('lua') then
              return
            end
            if middle == 'javascript' and not require_language('javascript') then
              return
            end
            query('lua', '')
            if middle == 'javascript' then
              query('javascript', '')
            end
            query(
              'markdown',
              [[
            (fenced_code_block (info_string (language) @_lang)
              (code_fence_content) @injection.content (#eq? @_lang "lua")
              (#set! injection.language "lua") (#set! injection.combined))
            (fenced_code_block (info_string (language) @_lang)
              (code_fence_content) @injection.content (#eq? @_lang "javascript")
              (#set! injection.language "javascript"))
          ]]
            )
            local root
            vim.treesitter.get_parser = function(...)
              root = original_get_parser(...)
              return root
            end
            -- Control sibling enumeration without assuming table iteration order.
            _G.pairs = function(value)
              if root and value == root:children() then
                local keys = order == 'lua first' and { 'lua', 'javascript' }
                  or { 'javascript', 'lua' }
                local index = 0
                return function()
                  repeat
                    index = index + 1
                  until not keys[index] or value[keys[index]]
                  local key = keys[index]
                  if key then
                    return key, value[key]
                  end
                end
              end
              return original_pairs(value)
            end
            if profile == '0.10 hull model' then
              -- v0.10.0 tree_contains used the envelope of a tree's disjoint
              -- included regions. This model is separate from actual version runs.
              local function tree_at(language_tree, range)
                for _, tree in original_pairs(language_tree:trees()) do
                  local regions = tree:included_ranges(false)
                  local first, last = regions[1], regions[#regions]
                  if first and last then
                    local before_start = range[1] < first[1]
                      or (range[1] == first[1] and range[2] < first[2])
                    local after_end = range[3] > last[3]
                      or (range[3] == last[3] and range[4] > last[4])
                    if not before_start and not after_end then
                      return tree
                    end
                  end
                end
              end
              language_tree_api.tree_for_range = tree_at
              language_tree_api.contains = function(language_tree, range)
                return tree_at(language_tree, range) ~= nil
              end
            end
            local comment = middle == 'javascript' and '// ' or '-- '
            if
              not fixture('markdown', {
                fence .. 'lua',
                '-- first',
                fence,
                fence .. (middle == 'unparsed' and 'comment_translate_missing' or middle),
                comment .. 'こんにちは',
                fence,
                fence .. 'lua',
                '-- last',
                fence,
              }, 5, 3)
            then
              return
            end
            request('hover')
            expect_text('こんにちは')
            calls = {}
            vim.o.virtualedit = 'onemore'
            vim.api.nvim_win_set_cursor(0, { 5, #comment + #'こんにちは' })
            request('insert')
            expect_text('こんにちは')
            calls = {}
            config.setup({ targets = { comment = false, string = true } })
            request('hover')
            assert.equals(0, #calls)
            config.setup({ targets = { comment = true, string = false } })
            vim.api.nvim_buf_set_lines(bufnr, 4, 5, false, { 'local value = "-- hidden"' })
            vim.api.nvim_win_set_cursor(0, { 5, 19 })
            request('hover')
            assert.equals(0, #calls)
          end
        )
      end
    end
  end

  for _, ft in ipairs({ 'swift', 'kotlin' }) do
    it('preserves ' .. ft .. ' block comments for hover and immersive', function()
      if not fixture(ft, { '/* こんにちは */' }, 1, 4) then
        return
      end
      request('hover')
      expect_text('こんにちは')
      calls = {}
      commands.enable_immersive(bufnr)
      expect_text('こんにちは')
    end)

    it('preserves ' .. ft .. ' multiline immersive comments', function()
      if not fixture(ft, { '/* first', ' * こんにちは', ' */' }, 2, 4) then
        return
      end
      commands.enable_immersive(bufnr)
      -- Keep the existing parsed-comment normalization of interior stars.
      expect_text('first\n* こんにちは')
    end)

    it('does not reclassify an excluded ' .. ft .. ' block comment', function()
      config.setup({ targets = { comment = false, string = true } })
      if not fixture(ft, { '/* "quoted" */' }, 1, 6) then
        return
      end
      request('hover')
      commands.enable_immersive(bufnr)
      assert.equals(0, #calls)
    end)
  end

  for _, form in ipairs({
    {
      name = 'YAML metadata',
      node = 'minus_metadata',
      lines = { '---', 'title: "こんにちは"', '---', '"outside"' },
      row = 2,
      col = 9,
    },
    {
      name = 'TOML metadata',
      node = 'plus_metadata',
      lines = { '+++', 'title = "こんにちは"', '+++', '"outside"' },
      row = 2,
      col = 10,
    },
    {
      name = 'HTML block',
      node = 'html_block',
      lines = { '<div title="こんにちは"></div>', '', '"outside"' },
      row = 1,
      col = 13,
    },
    {
      name = 'indented code',
      node = 'indented_code_block',
      lines = { '    local value = "こんにちは"', '', '"outside"' },
      row = 1,
      col = 20,
    },
  }) do
    for _, profile in ipairs({ 'no query', 'missing injected parser' }) do
      it('preserves bounded Markdown ' .. form.name .. ' with ' .. profile, function()
        if not require_language('markdown') then
          return
        end
        query(
          'markdown',
          profile == 'no query' and ''
            or '(('
              .. form.node
              .. ') @injection.content (#set! injection.language "comment_translate_missing")'
              .. ' (#set! injection.include-children))'
        )
        if not fixture('markdown', form.lines, form.row, form.col) then
          return
        end
        request('hover')
        expect_text('こんにちは')
        calls = {}
        config.setup({ targets = { comment = false, string = false } })
        request('hover')
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)
        config.setup({ targets = { comment = true, string = true } })
        vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(bufnr), 3 })
        request('hover')
        -- This separate inline region is independently eligible for fallback.
        expect_text('outside')
      end)
    end
  end

  it('keeps indented Markdown comments separate from eligible inline comments', function()
    query('markdown', '')
    if not fixture('markdown', { '    -- こんにちは', '', '-- outside' }, 1, 7) then
      return
    end
    request('hover')
    expect_text('こんにちは')
    calls = {}
    commands.enable_immersive(bufnr)
    assert.equals(2, #calls)
    assert.is_true(vim.tbl_contains(calls, 'こんにちは'))
    assert.is_true(vim.tbl_contains(calls, 'outside'))
  end)

  for _, enabled in ipairs({ true, false }) do
    it('honors quoted Markdown link titles when strings are ' .. tostring(enabled), function()
      if not require_language('markdown_inline') or not require_language('markdown') then
        return
      end
      query(
        'markdown',
        '((inline) @injection.content (#set! injection.language "markdown_inline"))'
      )
      query('markdown_inline', '')
      config.setup({ targets = { comment = true, string = enabled } })
      if not fixture('markdown', { '[site](url "こんにちは -- hidden")' }, 1, 13) then
        return
      end
      request('hover')
      if enabled then
        expect_text('こんにちは -- hidden')
      else
        assert.equals(0, #calls)
      end
      calls = {}
      vim.api.nvim_win_set_cursor(0, { 1, 8 })
      request('hover')
      commands.enable_immersive(bufnr)
      assert.equals(0, #calls)
    end)
  end

  for _, ft in ipairs({ 'swift', 'nix' }) do
    for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
      it(
        'preserves bounded quoted content in ' .. ft .. ' multiline strings via ' .. flow,
        function()
          if not require_language(ft) then
            return
          end
          query(ft, '')
          local lines = ft == 'swift'
              and { 'let value = """', 'He said "こんにちは".', '"""', 'let outside = 1' }
            or { "{ value = ''", 'He said "こんにちは".', "''; }", '# outside' }
          if not fixture(ft, lines, 2, 10) then
            return
          end
          request(flow)
          expect_text('こんにちは')
          calls = {}
          config.setup({ targets = { comment = true, string = false } })
          request(flow)
          commands.enable_immersive(bufnr)
          -- The genuine Nix comment remains eligible; the string never is.
          assert.equals(ft == 'nix' and 1 or 0, #calls)
        end
      )
    end
  end

  for _, form in ipairs({
    { node = 'string_expression', delimiter = '"' },
    { node = 'indented_string_expression', delimiter = "''" },
  }) do
    for _, flow in ipairs({ 'hover', 'manual', 'auto' }) do
      it('keeps Nix ' .. form.node .. ' exclusions above Bash injections via ' .. flow, function()
        if not require_language('nix') or not require_language('bash') then
          return
        end
        query(
          'nix',
          '(binding attrpath: (attrpath (identifier) @_path) expression: ('
            .. form.node
            .. ' (string_fragment) @injection.content) (#eq? @_path "buildPhase")'
            .. ' (#set! injection.language "bash"))'
        )
        query('bash', '')
        config.setup({ targets = { comment = true, string = false } })
        if
          not fixture(
            'nix',
            { '# host', '{ buildPhase = ' .. form.delimiter, '# hidden', form.delimiter .. '; }' },
            3,
            4
          )
        then
          return
        end
        request(flow)
        local child = original_get_parser(bufnr):children().bash
        assert.is_not_nil(child)
        assert.is_true(next(child:trees()) ~= nil)
        assert.equals(0, #calls)
        commands.enable_immersive(bufnr)
        expect_text('host')
      end)
    end
  end

  for _, profile in ipairs({ 'native', 'unclipped child model' }) do
    for _, order in ipairs({ 'combined first', 'separate first' }) do
      for _, flow in ipairs({ 'hover', 'manual', 'auto', 'immersive' }) do
        it(
          'keeps nested ownership per parent tree: ' .. profile .. ', ' .. order .. ', ' .. flow,
          function()
            if
              not require_language('markdown')
              or not require_language('vim')
              or not require_language('lua')
            then
              return
            end
            local outer = ''
            for _, label in ipairs({ 'a', 'b' }) do
              outer = outer
                .. '(fenced_code_block (info_string (language) @_lang)'
                .. ' (code_fence_content) @injection.content (#eq? @_lang "'
                .. label
                .. '") (#set! injection.language "vim") (#set! injection.combined))'
            end
            query('markdown', outer)
            local injection = embeddings[1].injection
            if not vim_has_body() then
              injection = injection
                :gsub('%(script %(body%) @injection%.content', '(chunk) @injection.content')
                :gsub('%)%)%)$', '))')
            end
            query('vim', injection)
            query('lua', '')
            local modeled = false
            if profile == 'unclipped child model' then
              language_tree_api._get_injections = function(language_tree, ...)
                local result = original_get_injections(language_tree, ...)
                if language_tree:lang() == 'vim' and result.lua then
                  local ranges = {}
                  for _, region in ipairs(result.lua) do
                    vim.list_extend(ranges, region)
                  end
                  local first, last = ranges[1], ranges[#ranges]
                  if first and last then
                    local end_index = #last == 6 and 4 or 3
                    result.lua =
                      { { { first[1], first[2], last[end_index], last[end_index + 1] } } }
                    modeled = true
                  end
                end
                return result
              end
            end
            local root
            vim.treesitter.get_parser = function(...)
              root = original_get_parser(...)
              return root
            end
            local enumerating_regions = false
            _G.pairs = function(value)
              if enumerating_regions then
                return original_pairs(value)
              end
              local parent = root and root:children().vim
              if parent and value == parent:trees() then
                enumerating_regions = true
                local regions = parent:included_regions()
                enumerating_regions = false
                local keys = {}
                for key in original_pairs(value) do
                  table.insert(keys, key)
                end
                table.sort(keys, function(a, b)
                  local a_size, b_size = #(regions[a] or {}), #(regions[b] or {})
                  if a_size == b_size then
                    return a < b
                  end
                  return order == 'combined first' and a_size > b_size
                    or order == 'separate first' and a_size < b_size
                end)
                local index = 0
                return function()
                  index = index + 1
                  local key = keys[index]
                  if key then
                    return key, value[key]
                  end
                end
              end
              return original_pairs(value)
            end
            if
              not fixture('markdown', {
                fence .. 'a',
                'lua << EOF',
                '-- first',
                fence,
                fence .. 'b',
                'let x = 1 -- sibling',
                fence,
                fence .. 'a',
                '-- こんにちは',
                'EOF',
                fence,
              }, 6, 15)
            then
              return
            end
            if flow == 'immersive' then
              commands.enable_immersive(bufnr)
            else
              request(flow)
              assert.equals(0, #calls)
              commands.enable_immersive(bufnr)
            end
            local parent = original_get_parser(bufnr):children().vim
            assert.equals(2, vim.tbl_count(parent:trees()))
            assert.is_true(next(parent:children().lua:trees()) ~= nil)
            if profile == 'unclipped child model' then
              assert.is_true(modeled)
            end
            assert.equals(2, #calls)
            assert.is_true(calls[1] == 'first')
            assert.is_true(calls[2] == 'こんにちは')
            calls = {}
            config.setup({ targets = { comment = false, string = true } })
            vim.api.nvim_win_set_cursor(0, { 3, 3 })
            request('hover')
            commands.update_immersive(bufnr)
            assert.equals(0, #calls)
          end
        )
      end
    end
  end

  for _, profile in ipairs({ 'native', 'unclipped sibling model' }) do
    for _, flow in ipairs({ 'hover', 'manual', 'auto', 'immersive' }) do
      it(
        'preserves fallback beside another parent-owned child: ' .. profile .. ', ' .. flow,
        function()
          for _, lang in ipairs({ 'markdown', 'vim', 'lua' }) do
            if not require_language(lang) then
              return
            end
          end
          local outer = ''
          for _, label in ipairs({ 'a', 'b' }) do
            outer = outer
              .. '(fenced_code_block (info_string (language) @_lang)'
              .. ' (code_fence_content) @injection.content (#eq? @_lang "'
              .. label
              .. '") (#set! injection.language "vim") (#set! injection.combined))'
          end
          query('markdown', outer)
          local content = vim_has_body() and '(lua_statement (script (body) @injection.content))'
            or '(lua_statement (chunk) @injection.content)'
          query(
            'vim',
            '('
              .. content
              .. ' (#set! injection.language "lua") (#match? @injection.content "START"))'
          )
          query('lua', '')
          local modeled = false
          if profile == 'unclipped sibling model' then
            language_tree_api._get_injections = function(language_tree, ...)
              local result = original_get_injections(language_tree, ...)
              if language_tree:lang() == 'vim' and result.lua then
                for index, regions in ipairs(result.lua) do
                  local first, last = regions[1], regions[#regions]
                  local end_index = #last == 6 and 4 or 3
                  result.lua[index] =
                    { { first[1], first[2], last[end_index], last[end_index + 1] } }
                  modeled = true
                end
              end
              return result
            end
          end
          config.setup({ targets = { comment = true, string = false } })
          assert.is_true(fixture('markdown', {
            fence .. 'a',
            'lua << EOF',
            '--[[START',
            fence,
            fence .. 'b',
            'lua << EOF2',
            '-- こんにちは',
            'EOF2',
            fence,
            fence .. 'a',
            ']]',
            'EOF',
            fence,
          }, 7, 5))
          if flow == 'immersive' then
            commands.enable_immersive(bufnr)
          else
            if flow == 'immersive' then
              commands.update_immersive(bufnr)
            else
              request(flow)
            end
          end
          local parent = original_get_parser(bufnr):children().vim
          assert.equals(2, vim.tbl_count(parent:trees()))
          assert.equals(1, vim.tbl_count(parent:children().lua:trees()))
          if profile == 'unclipped sibling model' then
            assert.is_true(modeled)
          end
          expect_text('こんにちは')
          calls = {}
          vim.api.nvim_buf_set_lines(bufnr, 6, 7, false, { '-- 世界' })
          if flow == 'immersive' then
            commands.update_immersive(bufnr)
          else
            if flow == 'immersive' then
              commands.update_immersive(bufnr)
            else
              request(flow)
            end
          end
          expect_text('世界')
          calls = {}
          config.setup({ targets = { comment = false, string = true } })
          if flow == 'immersive' then
            commands.update_immersive(bufnr)
          else
            if flow == 'immersive' then
              commands.update_immersive(bufnr)
            else
              request(flow)
            end
          end
          assert.equals(0, #calls)
        end
      )
    end
  end

  for _, profile in ipairs({ 'native', 'outside-parent model' }) do
    for _, flow in ipairs({ 'hover', 'manual', 'auto', 'immersive' }) do
      it('withholds ambiguous nested parser coverage: ' .. profile .. ', ' .. flow, function()
        for _, lang in ipairs({ 'markdown', 'vim', 'lua' }) do
          if not require_language(lang) then
            return
          end
        end
        query(
          'markdown',
          '(fenced_code_block (code_fence_content) @injection.content'
            .. ' (#set! injection.language "vim"))'
        )
        local has_body = vim_has_body()
        local content = has_body and '(lua_statement (script (body) @injection.content))'
          or '(lua_statement (chunk) @injection.content)'
        query(
          'vim',
          '('
            .. content
            .. ' (#set! injection.language "lua")'
            .. ' (#offset! @injection.content '
            .. (has_body and '-1 -10' or '-2 0')
            .. ' 0 0))'
        )
        query('lua', '')
        local modeled = false
        if profile == 'outside-parent model' then
          language_tree_api._get_injections = function(language_tree, ...)
            local result = original_get_injections(language_tree, ...)
            if language_tree:lang() == 'vim' and result.lua then
              for index in ipairs(result.lua) do
                result.lua[index] = { { 0, 0, 3, 0 } }
                modeled = true
              end
            end
            return result
          end
        end
        config.setup({ targets = { comment = true, string = false } })
        if
          not fixture('markdown', {
            fence .. 'vim',
            'lua << EOF',
            'local value = "alpha -- hidden"',
            'EOF',
            fence,
          }, 3, 24)
        then
          return
        end
        if flow == 'immersive' then
          commands.enable_immersive(bufnr)
        else
          request(flow)
        end
        local child = original_get_parser(bufnr):children().vim:children().lua
        assert.is_true(next(child:trees()) ~= nil)
        assert.equals(0, #calls)
        if profile == 'outside-parent model' then
          assert.is_true(modeled)
        end
        -- A fresh parser with an owned capture still preserves eligible text.
        language_tree_api._get_injections = original_get_injections
        query('vim', '(' .. content .. ' (#set! injection.language "lua"))')
        commands.cleanup_buffer(bufnr)
        vim.api.nvim_buf_delete(bufnr, { force = true })
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(bufnr)
        assert.is_true(fixture('markdown', {
          fence .. 'vim',
          'lua << EOF',
          '-- こんにちは',
          'EOF',
          fence,
        }, 3, 4))
        if flow == 'immersive' then
          commands.enable_immersive(bufnr)
        else
          request(flow)
        end
        expect_text('こんにちは')
      end)
    end
  end

  for _, form in ipairs({
    {
      side = 'before',
      kind = 'comment',
      unparsed = '-- こんにちは ',
      expected = 'こんにちは',
    },
    {
      side = 'after',
      kind = 'comment',
      unparsed = ' -- こんにちは',
      expected = 'こんにちは',
    },
    {
      side = 'before',
      kind = 'string',
      unparsed = '"こんにちは" ',
      expected = 'こんにちは',
    },
    { side = 'before', kind = 'string', unparsed = '"unclosed ', expected = false },
  }) do
    local flows = form.kind == 'comment' and { 'hover', 'manual', 'auto', 'immersive' }
      or { 'hover', 'manual', 'auto' }
    for _, flow in ipairs(flows) do
      it(
        'subtracts partial same-line parsed coverage '
          .. form.side
          .. ' fallback via '
          .. flow
          .. ': '
          .. form.unparsed:sub(1, 1),
        function()
          if not require_language('markdown') or not require_language('lua') then
            return
          end
          local parsed = 'return "hidden"'
          local offset = form.side == 'before' and ('0 ' .. #form.unparsed .. ' 0 0')
            or ('0 0 -1 ' .. #parsed)
          query(
            'markdown',
            '((fenced_code_block (code_fence_content) @injection.content)'
              .. ' (#set! injection.language "lua") (#offset! @injection.content '
              .. offset
              .. '))'
          )
          query('lua', '')
          config.setup({
            targets = { comment = form.kind == 'comment', string = form.kind == 'string' },
          })
          local line = form.side == 'before' and form.unparsed .. parsed or parsed .. form.unparsed
          local col = form.side == 'before' and 4 or #parsed + 4
          if not fixture('markdown', { fence .. 'lua', line, fence }, 2, col) then
            return
          end
          if flow == 'immersive' then
            commands.enable_immersive(bufnr)
          else
            request(flow)
          end
          local child = original_get_parser(bufnr):children().lua
          assert.is_not_nil(child)
          assert.is_true(next(child:trees()) ~= nil)
          if form.expected and (flow ~= 'immersive' or form.kind == 'comment') then
            expect_text(form.expected)
          else
            assert.equals(0, #calls)
          end
          calls = {}
          if flow == 'immersive' then
            commands.update_immersive(bufnr)
          else
            commands.enable_immersive(bufnr)
          end
          if form.kind == 'comment' then
            expect_text(form.expected)
          else
            assert.equals(0, #calls)
          end
          calls = {}
          -- An edit inside the parsed suffix must not change the fallback unit.
          vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { (line:gsub('hidden', 'secret')) })
          if flow == 'immersive' then
            commands.update_immersive(bufnr)
          else
            request(flow)
          end
          if form.expected and (flow ~= 'immersive' or form.kind == 'comment') then
            expect_text(form.expected)
          else
            assert.equals(0, #calls)
          end
          calls = {}
          config.setup({ targets = { comment = false, string = false } })
          if flow == 'immersive' then
            commands.update_immersive(bufnr)
          else
            request(flow)
          end
          commands.update_immersive(bufnr)
          assert.equals(0, #calls)
        end
      )
    end
  end

  it('preserves fallback comment insertion EOL after partial parsed coverage', function()
    if not require_language('markdown') or not require_language('lua') then
      return
    end
    local parsed = 'return "hidden"'
    local line = parsed .. ' -- こんにちは'
    query(
      'markdown',
      '((fenced_code_block (code_fence_content) @injection.content)'
        .. ' (#set! injection.language "lua") (#offset! @injection.content 0 0 -1 '
        .. #parsed
        .. '))'
    )
    query('lua', '')
    config.setup({ targets = { comment = true, string = false } })
    vim.o.virtualedit = 'onemore'
    if not fixture('markdown', { fence .. 'lua', line, fence }, 2, #line) then
      return
    end
    request('insert')
    expect_text('こんにちは')
    calls = {}
    config.setup({ targets = { comment = false, string = true } })
    request('insert')
    assert.equals(0, #calls)
  end)

  for _, profile in ipairs({ 'native', 'unclipped ancestor model' }) do
    for _, order in ipairs({ 'spanning first', 'separate first' }) do
      for _, flow in ipairs({ 'hover', 'manual', 'auto', 'immersive' }) do
        it(
          'keeps effective ancestor ownership at three levels: '
            .. profile
            .. ', '
            .. order
            .. ', '
            .. flow,
          function()
            for _, lang in ipairs({ 'markdown', 'vim', 'lua', 'javascript' }) do
              if not require_language(lang) then
                return
              end
            end
            local outer = ''
            for _, label in ipairs({ 'a', 'b' }) do
              outer = outer
                .. '(fenced_code_block (info_string (language) @_lang)'
                .. ' (code_fence_content) @injection.content (#eq? @_lang "'
                .. label
                .. '")'
                .. ' (#set! injection.language "vim") (#set! injection.combined))'
            end
            query('markdown', outer)
            query(
              'vim',
              vim_has_body()
                  and '(lua_statement (script (body) @injection.content (#set! injection.language "lua")))'
                or '(lua_statement (chunk) @injection.content (#set! injection.language "lua"))'
            )
            query(
              'lua',
              '((function_call name: (identifier) @_name'
                .. ' arguments: (arguments (binary_expression) @injection.content))'
                .. ' (#eq? @_name "js") (#set! injection.language "javascript")'
                .. ' (#set! injection.include-children))'
            )
            query('javascript', '')
            local modeled = false
            if profile == 'unclipped ancestor model' then
              language_tree_api._get_injections = function(language_tree, ...)
                local result = original_get_injections(language_tree, ...)
                if language_tree:lang() == 'vim' and result.lua then
                  -- Keep separate parent trees; model only each capture's old hull.
                  for index, regions in ipairs(result.lua) do
                    local first, last = regions[1], regions[#regions]
                    if first and last then
                      local end_index = #last == 6 and 4 or 3
                      result.lua[index] =
                        { { first[1], first[2], last[end_index], last[end_index + 1] } }
                      modeled = true
                    end
                  end
                end
                return result
              end
            end
            local root, enumerating_regions
            vim.treesitter.get_parser = function(...)
              root = original_get_parser(...)
              return root
            end
            _G.pairs = function(value)
              if enumerating_regions then
                return original_pairs(value)
              end
              local parent = root and root:children().vim
              local ancestor = parent and parent:children().lua
              if ancestor and value == ancestor:trees() then
                enumerating_regions = true
                local regions = ancestor:included_regions()
                enumerating_regions = false
                local keys = {}
                for key in original_pairs(value) do
                  table.insert(keys, key)
                end
                table.sort(keys, function(a, b)
                  local first_a, first_b = regions[a][1], regions[b][1]
                  return order == 'spanning first' and first_a[1] < first_b[1]
                    or order == 'separate first' and first_a[1] > first_b[1]
                end)
                local index = 0
                return function()
                  index = index + 1
                  local key = keys[index]
                  if key then
                    return key, value[key]
                  end
                end
              end
              return original_pairs(value)
            end
            if
              not fixture('markdown', {
                fence .. 'a',
                'lua << EOF',
                '--[[',
                fence,
                fence .. 'b',
                'lua << EOF2',
                'js(a // legitimate)',
                'EOF2',
                fence,
                fence .. 'a',
                ']]',
                'EOF',
                fence,
              }, 7, 10)
            then
              return
            end
            if flow == 'immersive' then
              commands.enable_immersive(bufnr)
            else
              request(flow)
              expect_text('legitimate')
              calls = {}
              commands.enable_immersive(bufnr)
            end
            expect_text('legitimate')
            local parent = original_get_parser(bufnr):children().vim
            assert.equals(2, vim.tbl_count(parent:trees()))
            local ancestor = parent:children().lua
            assert.equals(2, vim.tbl_count(ancestor:trees()))
            assert.equals(1, vim.tbl_count(ancestor:children().javascript:trees()))
            if profile == 'unclipped ancestor model' then
              assert.is_true(modeled)
            end
            calls = {}
            config.setup({ targets = { comment = false, string = true } })
            request('hover')
            commands.update_immersive(bufnr)
            assert.equals(0, #calls)
          end
        )
      end
    end
  end

  for _, form in ipairs({
    {
      lang = 'yaml',
      node = 'minus_metadata',
      lines = { '---', 'title: "こんにちは"', '---', '"outside"' },
      row = 2,
      col = 9,
      expected = 'こんにちは',
      hidden = 'title: "alpha # hidden"',
      comment = '# こんにちは',
      quoted_comment = '# "quoted"',
    },
    {
      lang = 'toml',
      node = 'plus_metadata',
      lines = { '+++', 'title = "こんにちは"', '+++', '"outside"' },
      row = 2,
      col = 10,
      expected = '"こんにちは"',
      hidden = 'title = "alpha # hidden"',
      comment = '# こんにちは',
      quoted_comment = '# "quoted"',
    },
    {
      lang = 'html',
      node = 'html_block',
      lines = { '<div title="こんにちは"></div>', '', '"outside"' },
      row = 1,
      col = 13,
      expected = 'こんにちは',
      hidden = '<div title="alpha -- hidden"></div>',
      comment = { '<!--', 'こんにちは', '-->' },
      quoted_comment = '<!-- "quoted" -->',
    },
    {
      lang = 'lua',
      node = 'indented_code_block',
      lines = { '    local value = "こんにちは"', '', '"outside"' },
      row = 1,
      col = 20,
      expected = 'こんにちは',
      hidden = '    local value = "alpha -- hidden"',
      comment = '    -- こんにちは',
      quoted_comment = '    -- "quoted"',
    },
  }) do
    it('keeps parsed exclusions and coverage in Markdown ' .. form.node, function()
      if not require_language('markdown') or not require_language(form.lang) then
        return
      end
      local offset = form.lang == 'yaml' or form.lang == 'toml'
      query(
        'markdown',
        '(('
          .. form.node
          .. ') @injection.content (#set! injection.language "'
          .. form.lang
          .. '") (#set! injection.include-children)'
          .. (offset and ' (#offset! @injection.content 1 0 -1 0)' or ' (#set! injection.combined)')
          .. ')'
      )
      query(form.lang, '')
      if not fixture('markdown', form.lines, form.row, form.col) then
        return
      end
      vim.bo[bufnr].commentstring = '<!-- %s -->'
      request('hover')
      local child = original_get_parser(bufnr):children()[form.lang]
      assert.is_not_nil(child)
      assert.is_true(next(child:trees()) ~= nil)
      expect_text(form.expected)
      calls = {}
      config.setup({ targets = { comment = true, string = false } })
      vim.api.nvim_buf_set_lines(bufnr, form.row - 1, form.row, false, { form.hidden })
      request('hover')
      commands.enable_immersive(bufnr)
      assert.equals(0, #calls)
      config.setup({ targets = { comment = false, string = true } })
      vim.api.nvim_buf_set_lines(bufnr, form.row - 1, form.row, false, { form.quoted_comment })
      request('hover')
      commands.update_immersive(bufnr)
      assert.equals(0, #calls)
      config.setup({ targets = { comment = true, string = false } })
      vim.api.nvim_buf_set_lines(
        bufnr,
        form.row - 1,
        form.row,
        false,
        type(form.comment) == 'table' and form.comment or { form.comment }
      )
      if type(form.comment) == 'table' then
        vim.api.nvim_win_set_cursor(0, { form.row + 1, 3 })
      end
      request('hover')
      expect_text('こんにちは')
      calls = {}
      commands.update_immersive(bufnr)
      expect_text('こんにちは')
      calls = {}
      if offset then
        for _, row in ipairs({ 1, 3 }) do
          vim.api.nvim_win_set_cursor(0, { row, 0 })
          request('hover')
        end
      end
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(bufnr), 3 })
      request('hover')
      assert.equals(0, #calls)
    end)
  end

  it('uses LanguageTree region metadata without newer TSTree methods', function()
    if not require_language('markdown') or not require_language('lua') then
      return
    end
    query('markdown', embeddings[2].injection)
    if not fixture('markdown', { fence .. 'lua', '-- こんにちは', fence }, 2, 3) then
      return
    end
    local wrappers, trees = {}, {}
    local function wrap_tree(tree)
      if tree and not trees[tree] then
        trees[tree] = {
          root = function()
            return tree:root()
          end,
        }
      end
      return trees[tree]
    end
    local function wrap(language_tree)
      if wrappers[language_tree] then
        return wrappers[language_tree]
      end
      local wrapper = {
        parse = function(_, range)
          local parsed = language_tree:parse(range)
          return vim.tbl_map(wrap_tree, parsed)
        end,
        trees = function()
          return vim.tbl_map(wrap_tree, language_tree:trees())
        end,
        included_regions = function()
          return language_tree:included_regions()
        end,
        tree_for_range = function(_, range)
          return wrap_tree(language_tree:tree_for_range(range))
        end,
        contains = function(_, range)
          return language_tree:contains(range)
        end,
        children = function()
          return vim.tbl_map(wrap, language_tree:children())
        end,
      }
      wrappers[language_tree] = wrapper
      return wrapper
    end
    vim.treesitter.get_parser = function(...)
      return wrap(original_get_parser(...))
    end
    request('hover')
    expect_text('こんにちは')
    calls = {}
    commands.enable_immersive(bufnr)
    expect_text('こんにちは')
  end)

  for _, profile in ipairs({ 'separate', 'combined parent', 'combined leaf' }) do
    it('scales nested Markdown HTML JavaScript collection: ' .. profile, function()
      if
        not require_language('markdown')
        or not require_language('html')
        or not require_language('javascript')
      then
        return
      end
      query(
        'markdown',
        '(fenced_code_block (code_fence_content) @injection.content'
          .. ' (#set! injection.language "html")'
          .. (profile ~= 'separate' and ' (#set! injection.combined)' or '')
          .. ')'
      )
      query(
        'html',
        '(script_element (raw_text) @injection.content (#set! injection.language "javascript")'
          .. (profile == 'combined leaf' and ' (#set! injection.combined)' or '')
          .. ')'
      )
      local counts, cursor_counts = {}, {}
      for _, size in ipairs({ 64, 256 }) do
        local lines = {}
        for _ = 1, size do
          vim.list_extend(
            lines,
            { '```html', '<script>', '// こんにちは', '</script>', '```', '' }
          )
        end
        if not fixture('markdown', lines) then
          return
        end
        -- First collection must discover both injection levels without preparse.
        local comments = parser.get_all_comments(bufnr)
        assert.equals(size, vim.tbl_count(comments))
        local original_ipairs, count = ipairs, 0
        _G.ipairs = function(value)
          local next_item, state, key = original_ipairs(value)
          return function(_, previous)
            local index, item = next_item(state, previous)
            if index ~= nil then
              count = count + 1
            end
            return index, item
          end,
            state,
            key
        end
        local ok, result = pcall(parser.get_all_comments, bufnr)
        counts[size] = count
        count = 0
        vim.api.nvim_win_set_cursor(0, { (size - 1) * 6 + 3, 4 })
        local cursor_ok, text = pcall(parser.get_text_at_cursor, bufnr)
        cursor_counts[size] = count
        _G.ipairs = original_ipairs
        assert.is_true(ok)
        assert.is_true(cursor_ok)
        assert.is_true(text == 'こんにちは')
        assert.equals(size, vim.tbl_count(result))
        for index = 1, size do
          assert.is_true(comments[(index - 1) * 6 + 2] == 'こんにちは')
          assert.is_true(result[(index - 1) * 6 + 2] == 'こんにちは')
        end
      end
      -- Deterministic work bound for a warm parse, independent of machine speed.
      assert.is_true(counts[256] <= counts[64] * 6)
      assert.is_true(cursor_counts[256] <= cursor_counts[64] * 6)
    end)
  end

  for _, profile in ipairs({
    'no inner query',
    'missing inner parser',
    'available inner parser',
    'unclipped inner ranges',
  }) do
    describe('nested combined injection ' .. profile, function()
      local function nested(first, second)
        if not require_language('markdown') or not require_language('vim') then
          return false
        end
        query(
          'markdown',
          '(fenced_code_block (code_fence_content) @injection.content'
            .. ' (#set! injection.language "vim") (#set! injection.combined))'
        )
        local injection = ''
        if profile ~= 'no inner query' then
          if profile ~= 'missing inner parser' and not require_language('lua') then
            return false
          end
          injection = embeddings[1].injection
          if profile == 'missing inner parser' then
            injection = injection:gsub('"lua"', '"comment_translate_missing"')
          end
          if not vim_has_body() then
            injection = injection
              :gsub('%(script %(body%) @injection%.content', '(chunk) @injection.content')
              :gsub('%)%)%)$', '))')
          end
        end
        query('vim', injection)
        if profile == 'unclipped inner ranges' then
          -- Model older LanguageTree queries that kept a captured body range
          -- contiguous even when its parent included disjoint regions.
          language_tree_api._get_injections = function(language_tree, ...)
            local result = original_get_injections(language_tree, ...)
            if language_tree:lang() == 'vim' and result.lua then
              local ranges = {}
              for _, region in ipairs(result.lua) do
                vim.list_extend(ranges, region)
              end
              local first_range, last_range = ranges[1], ranges[#ranges]
              if first_range and last_range then
                local end_index = #last_range == 6 and 4 or 3
                result.lua = {
                  {
                    {
                      first_range[1],
                      first_range[2],
                      last_range[end_index],
                      last_range[end_index + 1],
                    },
                  },
                }
              end
            end
            return result
          end
        end
        return fixture('markdown', {
          fence .. 'vim',
          'lua << EOF',
          first,
          fence,
          '-- excluded host',
          fence .. 'vim',
          second,
          'EOF',
          fence,
        }, 3, 3)
      end

      it('keeps fallback comments separate from an independently eligible host gap', function()
        if not nested('-- first', '-- こんにちは') then
          return
        end
        commands.enable_immersive(bufnr)
        assert.equals(3, #calls)
        assert.is_true(vim.tbl_contains(calls, 'first'))
        assert.is_true(vim.tbl_contains(calls, 'こんにちは'))
        assert.is_true(vim.tbl_contains(calls, 'excluded host'))
        calls = {}
        request('hover')
        expect_text('first')
        calls = {}
        for _, row in ipairs({ 1, 4, 6, 9 }) do
          vim.api.nvim_win_set_cursor(0, { row, 0 })
          request('hover')
        end
        assert.equals(0, #calls)
        vim.api.nvim_win_set_cursor(0, { 5, 3 })
        request('hover')
        expect_text('excluded host')
      end)

      it('does not join a fallback block comment across the host gap', function()
        if not nested('--[[ first', 'last ]]') then
          return
        end
        if profile == 'available inner parser' or profile == 'unclipped inner ranges' then
          request('hover')
          assert.equals(0, #calls)
        end
        commands.enable_immersive(bufnr)
        -- Only the independent host inline comment may be submitted.
        expect_text('excluded host')
      end)
    end)
  end

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
  for _, form in ipairs({
    { command = 'python', lang = 'python', node = 'python_statement' },
    { command = 'python3', lang = 'python', node = 'python_statement' },
    { command = 'py3', lang = 'python', node = 'python_statement' },
    { command = 'python3 << trim EOF', header = true, lang = 'python', node = 'python_statement' },
    { command = 'py3 << trim EOF', header = true, lang = 'python', node = 'python_statement' },
    { command = 'ruby', lang = 'ruby', node = 'ruby_statement' },
  }) do
    for _, profile in ipairs({
      'parser only',
      'injection query',
      'native query',
      'missing injected parser',
    }) do
      describe('Vim heredoc ' .. form.command .. ' ' .. profile, function()
        local function embedded(lines, row, col)
          if not require_language('vim') or not require_language(form.lang) then
            return false
          end
          if profile ~= 'native query' then
            local content = vim_has_body() and '(script (body) @injection.content)'
              or '(chunk) @injection.content'
            local language = profile == 'missing injected parser' and 'comment_translate_missing'
              or form.lang
            query(
              'vim',
              profile == 'parser only' and ''
                or '('
                  .. form.node
                  .. ' '
                  .. content
                  .. ' (#set! injection.language "'
                  .. language
                  .. '"))'
            )
          end
          fixture('vim', lines, row, col)
          vim.bo[bufnr].commentstring = '" %s'
          return true
        end
        local function block(content)
          return { (form.header and form.command or form.command .. ' << EOF'), content, 'EOF' }
        end
        local function parsed_child()
          if profile == 'injection query' or profile == 'native query' then
            expect_child(form.lang)
          end
        end
        it('preserves a comment on first hover', function()
          if not embedded(block('# こんにちは'), 2, 3) then
            return
          end
          request('hover')
          expect_text('こんにちは')
          parsed_child()
        end)
        it('preserves a comment with immersive first', function()
          if not embedded(block('# こんにちは')) then
            return
          end
          commands.enable_immersive(bufnr)
          expect_text('こんにちは')
          parsed_child()
        end)
        it('preserves an enabled string on first hover', function()
          if not embedded(block('value = "こんにちは"'), 2, 10) then
            return
          end
          request('hover')
          expect_text('こんにちは')
          parsed_child()
        end)
        it('preserves a comment at the insertion boundary', function()
          vim.o.virtualedit = 'onemore'
          local line = '# こんにちは'
          if not embedded(block(line), 2, #line) then
            return
          end
          request('insert')
          expect_text('こんにちは')
          parsed_child()
        end)
        it('preserves comment punctuation', function()
          if not embedded(block('# % growth'), 2, 3) then
            return
          end
          request('hover')
          expect_text('% growth')
          calls = {}
          commands.enable_immersive(bufnr)
          expect_text('% growth')
        end)
        it('does not send heredoc boundaries', function()
          if not embedded(block('# hello'), 1, 0) then
            return
          end
          request('hover')
          vim.api.nvim_win_set_cursor(0, { 3, 0 })
          request('hover')
          assert.equals(0, #calls)
        end)
        it('honors disabled targets on first use', function()
          config.setup({ targets = { comment = false, string = false } })
          if not embedded(block('# "quoted"'), 2, 5) then
            return
          end
          request('hover')
          commands.enable_immersive(bufnr)
          assert.equals(0, #calls)
        end)
        it('preserves adjacent host comments and strings', function()
          if
            not embedded({
              '" host comment',
              (form.header and form.command or form.command .. ' << EOF'),
              '# child comment',
              'EOF',
              'let s = "host string"',
            }, 1, 3)
          then
            return
          end
          request('hover')
          expect_text('host comment')
          calls = {}
          vim.api.nvim_win_set_cursor(0, { 5, 10 })
          request('hover')
          expect_text('"host string"')
          calls = {}
          commands.enable_immersive(bufnr)
          assert.equals(2, #calls)
        end)
        if profile == 'injection query' or profile == 'native query' then
          it('does not reclassify a disabled string containing comment markers', function()
            config.setup({ targets = { comment = true, string = false } })
            if not embedded(block('value = "alpha # hidden"'), 2, 19) then
              return
            end
            request('hover')
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
            parsed_child()
          end)
          it('suppresses a parsed string with immersive as first operation', function()
            config.setup({ targets = { comment = true, string = false } })
            if not embedded(block('value = "alpha # hidden"')) then
              return
            end
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
            parsed_child()
          end)
          it('does not reclassify a disabled comment containing quotes', function()
            config.setup({ targets = { comment = false, string = true } })
            vim.o.virtualedit = 'onemore'
            local line = '# "quoted"'
            if not embedded(block(line), 2, #line) then
              return
            end
            request('insert')
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
            parsed_child()
          end)
          it('reparses a comment edited into a disabled string', function()
            config.setup({ targets = { comment = true, string = false } })
            if not embedded(block('# hello'), 2, 3) then
              return
            end
            request('hover')
            expect_text('hello')
            calls = {}
            vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'value = "alpha # hidden"' })
            vim.api.nvim_win_set_cursor(0, { 2, 19 })
            request('hover')
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
          end)
        else
          it('does not let fallback block comments escape the body', function()
            if
              not embedded({
                (form.header and form.command or form.command .. ' << EOF'),
                '/*',
                'EOF',
                'outside code',
                '*/',
              })
            then
              return
            end
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
          end)
          it('does not join fallback blocks across heredocs', function()
            if
              not embedded({
                (form.header and form.command or form.command .. ' << EOF'),
                '/*',
                'EOF',
                (form.header and form.command or form.command .. ' << EOF'),
                '*/',
                'EOF',
              })
            then
              return
            end
            commands.enable_immersive(bufnr)
            assert.equals(0, #calls)
          end)
        end
      end)
    end
  end

  describe('Vim Python3 compatibility guards', function()
    local function prepare(lines, row, col)
      if not require_language('vim') or not require_language('python') then
        return false
      end
      if not fixture('vim', lines, row, col) then
        return false
      end
      vim.bo[bufnr].commentstring = '" %s'
      return true
    end

    for _, command in ipairs({ 'python3', 'py3' }) do
      for _, form in ipairs({
        { name = 'default marker', open = command .. ' <<', close = '.', prefix = '', indent = '' },
        {
          name = 'no whitespace',
          open = command .. '<<EOF',
          close = 'EOF',
          prefix = '',
          indent = '',
        },
        {
          name = 'trailing whitespace',
          open = command .. ' << EOF  ',
          close = 'EOF',
          prefix = '',
          indent = '',
        },
        {
          name = 'trim without whitespace',
          open = '  ' .. command .. '<<trim EOF',
          close = '  EOF',
          prefix = 'function! Example()',
          indent = '    ',
        },
        {
          name = 'trim trailing tab',
          open = '\t' .. command .. ' << trim EOF\t',
          close = '\tEOF',
          prefix = 'function! Example()',
          indent = '\t\t',
        },
        {
          name = 'colon',
          open = ':' .. command .. ' << EOF',
          close = 'EOF',
          prefix = '',
          indent = '',
        },
        {
          name = 'function',
          open = '  ' .. command .. ' << EOF',
          close = 'EOF',
          prefix = 'function! Example()',
          indent = '',
        },
        {
          name = 'trim spaces',
          open = '  ' .. command .. ' << trim EOF',
          close = '  EOF',
          prefix = 'function! Example()',
          indent = '    ',
        },
        {
          name = 'trim tabs',
          open = '\t' .. command .. ' << trim EOF',
          close = '\tEOF',
          prefix = 'function! Example()',
          indent = '\t\t',
        },
        {
          name = 'trim default marker',
          open = '  ' .. command .. ' << trim',
          close = '  .',
          prefix = 'function! Example()',
          indent = '    ',
        },
      }) do
        local function lines(body)
          local result = { form.open, form.indent .. body, form.close }
          if form.prefix ~= '' then
            table.insert(result, 1, form.prefix)
            table.insert(result, 'endfunction')
          end
          return result, form.prefix == '' and 2 or 3
        end
        for _, first in ipairs({ 'hover', 'immersive' }) do
          it(
            'preserves ' .. command .. ' ' .. form.name .. ' with ' .. first .. ' first',
            function()
              local input, row = lines('# こんにちは')
              if not prepare(input, row, #form.indent + 3) then
                return
              end
              local tick = vim.api.nvim_buf_get_changedtick(bufnr)
              if first == 'hover' then
                request('hover')
              else
                commands.enable_immersive(bufnr)
              end
              expect_text('こんにちは')
              expect_child('python')
              assert.equals(tick, vim.api.nvim_buf_get_changedtick(bufnr))
              assert.is_true(vim.deep_equal(input, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)))
            end
          )
          it(
            'suppresses a disabled string in '
              .. command
              .. ' '
              .. form.name
              .. ' with '
              .. first
              .. ' first',
            function()
              config.setup({ targets = { comment = true, string = false } })
              local input, row = lines('value = "alpha # hidden"')
              if not prepare(input, row, #form.indent + 19) then
                return
              end
              if first == 'hover' then
                request('hover')
              else
                commands.enable_immersive(bufnr)
              end
              assert.equals(0, #calls)
              expect_child('python')
            end
          )
        end
        it('preserves insertion-byte boundaries in ' .. command .. ' ' .. form.name, function()
          vim.o.virtualedit = 'onemore'
          local input, row = lines('# こんにちは')
          if not prepare(input, row, #input[row]) then
            return
          end
          request('insert')
          expect_text('こんにちは')
          expect_child('python')
        end)
      end
    end

    it('does not normalize a fake header inside a Python heredoc string', function()
      config.setup({ targets = { comment = true, string = false } })
      local input =
        { 'python3 << EOF', 'value = """', 'py3 << INNER', '# hidden', 'INNER', '"""', 'EOF' }
      if not prepare(input, 4, 3) then
        return
      end
      local source
      local factory = vim.treesitter.get_string_parser
      vim.treesitter.get_string_parser = function(text, ...)
        source = text
        return factory(text, ...)
      end
      request('hover')
      commands.enable_immersive(bufnr)
      assert.equals(0, #calls)
      assert.is_true(source:find('py3 << INNER', 1, true) ~= nil)
      expect_child('python')
    end)

    for _, host in ipairs({ 'comment', 'string', 'heredoc' }) do
      it('does not normalize a fake Python3 header in a host ' .. host, function()
        local input = host == 'comment' and { '" python3 << trim EOF' }
          or host == 'string' and { 'let value = "py3 << EOF"' }
          or { 'let value =<< END', 'py3 << EOF', '# hidden', 'EOF', 'END' }
        if not prepare(input) then
          return
        end
        local count = 0
        local factory = vim.treesitter.get_string_parser
        vim.treesitter.get_string_parser = function(...)
          count = count + 1
          return factory(...)
        end
        request('hover')
        commands.enable_immersive(bufnr)
        assert.equals(0, count)
      end)
    end

    it('reuses the compatibility parser until text or the host parser changes', function()
      if not prepare({ 'py3 << EOF', '# original', 'EOF' }, 2, 3) then
        return
      end
      local count = 0
      local factory = vim.treesitter.get_string_parser
      vim.treesitter.get_string_parser = function(...)
        count = count + 1
        return factory(...)
      end
      request('hover')
      expect_text('original')
      calls = {}
      commands.enable_immersive(bufnr)
      expect_text('original')
      calls = {}
      request('hover')
      expect_text('original')
      calls = {}
      assert.equals(1, count)
      vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { '# changed' })
      request('hover')
      expect_text('changed')
      calls = {}
      assert.equals(2, count)
      -- A parser replacement with unchanged bytes must not reuse the old view.
      local input = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') .. '\n'
      local replacement = original_get_string_parser(input, 'vim')
      vim.treesitter.get_parser = function()
        return replacement
      end
      request('hover')
      expect_text('changed')
      assert.equals(3, count)
    end)

    it('keeps compatibility parsers separate across buffer wipeout', function()
      if not prepare({ 'python3 << EOF', '# original', 'EOF' }, 2, 3) then
        return
      end
      request('hover')
      expect_text('original')
      calls = {}
      commands.cleanup_buffer(bufnr)
      vim.api.nvim_buf_delete(bufnr, { force = true })
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(bufnr)
      recovered_parser = nil
      if not prepare({ 'python3 << EOF', '# next buffer', 'EOF' }, 2, 3) then
        return
      end
      request('hover')
      expect_text('next buffer')
      expect_child('python')
    end)

    for _, header in ipairs({ 'python << EOF', 'python3 << EOF' }) do
      it('does not retain a released host parser for ' .. header, function()
        if not prepare({ header, '# hidden' }, 2, 3) then
          return
        end
        local function release_host()
          local host = original_get_string_parser(header .. '\n# hidden\n', 'vim')
          vim.treesitter.get_parser = function()
            return host
          end
          request('hover')
          vim.treesitter.get_parser = original_get_parser
          return setmetatable({ host }, { __mode = 'v' })
        end
        local weak = release_host()
        -- Compiled traces can retain references independently of the cache.
        local jit_runtime = rawget(_G, 'jit')
        if jit_runtime then
          jit_runtime.flush()
        end
        collectgarbage('collect')
        collectgarbage('collect')
        assert.is_true(weak[1] == nil)
      end)
    end

    for _, failure in ipairs({ 'construction', 'parse error', 'missing tree', 'unproven boundary' }) do
      it(
        'withholds requests after compatibility ' .. failure .. ' without revealing details',
        function()
          if not prepare({ 'python3 << EOF', 'value = "# hidden"', 'EOF' }, 2, 11) then
            return
          end
          local attempts = 0
          vim.treesitter.get_string_parser = function()
            attempts = attempts + 1
            if failure == 'construction' then
              error('private fixture details')
            end
            if failure == 'unproven boundary' then
              return original_get_parser(bufnr)
            end
            return {
              set_included_regions = function() end,
              parse = function()
                if failure == 'parse error' then
                  error('private fixture details')
                end
                return {}
              end,
            }
          end
          request('hover')
          commands.enable_immersive(bufnr)
          assert.equals(0, #calls)
          assert.equals(1, attempts)
          for _, message in ipairs(notifications) do
            assert.is_nil(message:find('private fixture details', 1, true))
          end
        end
      )
    end

    for _, ending in ipairs({ 'missing', 'trailing space', 'wrong trim indentation' }) do
      it('withholds an unproven Python3 terminator: ' .. ending, function()
        local input = ending == 'wrong trim indentation'
            and { '  py3 << trim EOF', '    # hidden', ' EOF' }
          or { 'python3 << EOF', '# hidden' }
        if ending == 'trailing space' then
          table.insert(input, 'EOF ')
        end
        if not prepare(input, 2, 3) then
          return
        end
        request('hover')
        commands.enable_immersive(bufnr)
        assert.equals(0, #calls)
        assert.is_nil(recovered_parser)
      end)
    end

    it('keeps a parser that already recognizes the Python3 script shape', function()
      if not prepare({ 'python3 << EOF', '# original', 'EOF' }, 2, 3) then
        return
      end
      local recognized = original_get_string_parser('python  << EOF\n# original\nEOF\n', 'vim')
      vim.treesitter.get_parser = function()
        return recognized
      end
      request('hover')
      expect_text('original')
      assert.is_nil(recovered_parser)
      assert.is_not_nil(next(recognized:children().python:trees()))
    end)
  end)

  describe('Vim Python3 parser configuration', function()
    it('preserves custom injection options', function()
      if not require_language('vim') or not require_language('python') then
        return
      end
      fixture('vim', { 'py3 << EOF', '# hello', 'EOF' }, 2, 3)
      vim.bo[bufnr].commentstring = '" %s'
      local host = original_get_string_parser(
        'py3 << EOF\n# hello\nEOF\n',
        'vim',
        { injections = { vim = '' } }
      )
      vim.treesitter.get_parser = function()
        return host
      end
      request('hover')
      expect_text('hello')
      assert.is_not_nil(recovered_parser)
      assert.is_nil(recovered_parser:children().python)
    end)

    it('preserves restricted root coverage', function()
      if not require_language('vim') or not require_language('python') then
        return
      end
      fixture('vim', { 'py3 << EOF', '# hello', 'EOF', '" outside' }, 2, 3)
      vim.bo[bufnr].commentstring = '" %s'
      local host = original_get_string_parser('py3 << EOF\n# hello\nEOF\n" outside\n', 'vim')
      vim.treesitter.get_parser = function()
        return host
      end
      request('hover')
      expect_text('hello')
      calls = {}
      host:set_included_regions({ { { 0, 0, 3, 0 } } })
      commands.enable_immersive(bufnr)
      expect_text('hello')
      calls = {}
      vim.api.nvim_win_set_cursor(0, { 4, 3 })
      request('hover')
      assert.equals(0, #calls)
    end)
  end)
end)
