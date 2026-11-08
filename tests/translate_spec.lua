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

describe('backend cache isolation', function()
  local config, translate, original_job
  local jobs
  local function await_request(service, target, source)
    local done, value = false, nil
    translate.translate('fixture input', target or 'ja', source, function(result)
      done, value = true, result
    end, service)
    assert.is_true(vim.wait(1000, function()
      return done
    end))
    return value
  end

  before_each(function()
    for _, name in ipairs({
      'config',
      'translate',
      'translate.cache',
      'translate.google',
      'translate.llm',
    }) do
      package.loaded['comment-translate.' .. name] = nil
    end
    config = require('comment-translate.config')
    config.setup({
      translate_service = 'llm',
      llm = { provider = 'ollama', model = 'fixture-a', api_key = 'fixture-key' },
    })
    translate = require('comment-translate.translate')
    original_job = package.loaded['plenary.job']
    jobs = {}
    package.loaded['plenary.job'] = {
      new = function(_, opts)
        local marker = 'result-' .. (#jobs + 1)
        local response
        local job = {
          result = function()
            return { vim.fn.json_encode(response) }
          end,
        }
        local google = opts.writer:find('translate.googleapis.com', 1, true)
        if google then
          response = { { { marker } } }
        elseif config.config.llm.provider == 'ollama' then
          response = { message = { content = marker } }
        else
          response = { choices = { { message = { content = marker } } } }
        end
        function job.start() end
        function job.finish()
          opts.on_exit(job, 0)
        end
        table.insert(jobs, job)
        vim.schedule(function()
          if not job.deferred then
            job:finish()
          end
        end)
        return job
      end,
    }
  end)

  after_each(function()
    package.loaded['plenary.job'] = original_job
  end)

  it('separates per-call services and reuses matching entries', function()
    assert.equals('result-1', await_request('google'))
    assert.equals('result-2', await_request('llm'))
    assert.equals('result-1', await_request('google'))
    assert.equals('result-2', await_request('llm'))
    assert.equals(2, #jobs)
  end)

  for _, change in ipairs({
    { 'provider', 'openai' },
    { 'model', 'fixture-b' },
    { 'endpoint', 'http://localhost:11435/api/chat' },
    { 'system_prompt', 'Use formal language.' },
  }) do
    it('isolates changes to ' .. change[1] .. ' and reuses restored settings', function()
      local initial = vim.deepcopy(config.config)
      assert.equals('result-1', await_request())
      local updated = vim.deepcopy(initial)
      updated.llm[change[1]] = change[2]
      config.setup(updated)
      assert.equals('result-2', await_request())
      config.setup(initial)
      assert.equals('result-1', await_request())
      assert.equals(2, #jobs)
    end)
  end

  it('separates configured services after setup', function()
    config.setup({ translate_service = 'google' })
    assert.equals('result-1', await_request())
    config.setup({ translate_service = 'llm', llm = { provider = 'ollama' } })
    assert.equals('result-2', await_request())
  end)

  it('keeps a late response in its original namespace', function()
    local old_result
    translate.translate('fixture input', 'ja', nil, function(value)
      old_result = value
    end)
    jobs[1].deferred = true
    config.config.llm.model = 'fixture-b'
    assert.equals('result-2', await_request())
    jobs[1]:finish()
    assert.is_true(vim.wait(1000, function()
      return old_result ~= nil
    end))
    assert.equals('result-2', await_request())
    assert.equals(2, #jobs)
  end)

  it('matches normalized languages, defaults, and irrelevant settings', function()
    assert.equals('result-1', await_request(nil, 'JA', 'EN'))
    assert.equals('result-1', await_request(nil, 'ja', 'en'))
    assert.equals('result-2', await_request())
    config.config.llm.endpoint = 'http://localhost:11434/api/chat'
    config.config.llm.system_prompt =
      'You are a translation engine. Return only the translated text. Do not add explanations.'
    config.config.llm.timeout = 30
    config.config.llm.api_key = 'another-fixture-key'
    assert.equals('result-2', await_request(nil, 'ja', 'auto'))
    assert.equals(2, #jobs)
  end)
end)
