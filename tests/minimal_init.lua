---Minimal init for running tests
---Usage:
---nvim --headless -u tests/minimal_init.lua
---Then run PlenaryBustedDirectory with this minimal_init.

local plenary_dir = os.getenv('PLENARY_DIR') or '/tmp/plenary.nvim'
local is_not_a_directory = vim.fn.isdirectory(plenary_dir) == 0

if is_not_a_directory then
  vim.fn.system({ 'git', 'clone', 'https://github.com/nvim-lua/plenary.nvim', plenary_dir })
end

local parser_runtime = os.getenv('COMMENT_TRANSLATE_TEST_RTP')
local strict = os.getenv('COMMENT_TRANSLATE_TEST_REQUIRE_PARSERS') == '1'
if strict then
  -- Exclude personal parser/query installations, even for the parent runner.
  vim.opt.rtp = { '.', plenary_dir, vim.env.VIMRUNTIME }
else
  vim.opt.rtp:append('.')
  vim.opt.rtp:append(plenary_dir)
end
if parser_runtime and parser_runtime ~= '' then
  vim.opt.rtp:prepend(parser_runtime)
end

local fixture_helpers = parser_runtime and parser_runtime .. '/query_predicates.lua'
if strict or (fixture_helpers and vim.fn.filereadable(fixture_helpers) == 1) then
  local ok, err = pcall(function()
    if strict then
      assert(
        parser_runtime and parser_runtime ~= '',
        'Strict parser tests require COMMENT_TRANSLATE_TEST_RTP'
      )
      for _, lang in ipairs(dofile('tests/parser_requirements.lua').languages) do
        local path = parser_runtime .. '/parser/' .. lang .. '.so'
        assert(vim.fn.filereadable(path) == 1, 'Required test parser missing: ' .. lang)
        local loaded, load_error = vim.treesitter.language.add(lang, { path = path })
        assert(loaded ~= false and load_error == nil, 'Required test parser cannot load: ' .. lang)
      end
    end
    -- The fixture provider's native queries use its own directives (downcase!,
    -- for example). Load only that pinned helper, not the provider plugin.
    local query_api = require('vim.treesitter.query')
    local add_directive, add_predicate = query_api.add_directive, query_api.add_predicate
    local function register_legacy(register, name, handler, opts)
      if type(opts) == 'table' and opts.all == false then
        local legacy_handler = handler
        handler = function(matches, ...)
          -- Neovim 0.12 removed all=false. Preserve the pinned helper's
          -- single-node semantics when captures are now lists of nodes.
          local single = {}
          for id, nodes in pairs(matches) do
            single[id] = type(nodes) == 'table' and nodes[1] or nodes
          end
          return legacy_handler(single, ...)
        end
      end
      return register(name, handler, opts)
    end
    query_api.add_directive = function(...)
      return register_legacy(add_directive, ...)
    end
    query_api.add_predicate = function(...)
      return register_legacy(add_predicate, ...)
    end
    local loaded, helper_error = pcall(dofile, fixture_helpers)
    query_api.add_directive, query_api.add_predicate = add_directive, add_predicate
    assert(loaded, helper_error)
  end)
  if not ok then
    io.stderr:write(tostring(err) .. '\n')
    vim.cmd('cquit 1')
  end
end

vim.cmd('runtime plugin/plenary.vim')
local busted = require('plenary.busted')
if strict then
  local pending_count = 0
  busted.pending = function()
    pending_count = pending_count + 1
    error('Pending tests are forbidden in strict real-parser mode')
  end
  _G.pending = busted.pending
  local format_results = busted.format_results
  busted.format_results = function(results)
    format_results(results)
    print('Executed: ' .. (#results.pass + #results.fail))
    print('Pending: ' .. pending_count)
  end
end
