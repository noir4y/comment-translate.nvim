---@diagnostic disable: undefined-global
describe('translate', function()
  local translate

  before_each(function()
    package.loaded['comment-translate.config'] = nil
    package.loaded['comment-translate.translate'] = nil
    package.loaded['comment-translate.translate.google'] = nil
    package.loaded['comment-translate.translate.llm'] = nil
    package.loaded['comment-translate.translate.cache'] = nil

    local config = require('comment-translate.config')
    config.reset()
    translate = require('comment-translate.translate')
  end)

  it('should include google and llm in available services', function()
    local services = translate.get_available_services()
    local found_google = false
    local found_llm = false

    for _, service in ipairs(services) do
      if service == 'google' then
        found_google = true
      end
      if service == 'llm' then
        found_llm = true
      end
    end

    assert.is_true(found_google)
    assert.is_true(found_llm)
  end)
end)
