---@class CommentTranslateConfig
---@field target_language string
---@field translate_service string
---@field hover CommentTranslateHoverConfig
---@field immersive CommentTranslateImmersiveConfig
---@field cache CommentTranslateCacheConfig
---@field max_length number
---@field targets CommentTranslateTargetsConfig

---@class CommentTranslateHoverConfig
---@field enabled boolean
---@field delay number
---@field auto boolean Enable auto-hover on CursorHold (false = manual hover only)

---@class CommentTranslateImmersiveConfig
---@field enabled boolean

---@class CommentTranslateCacheConfig
---@field enabled boolean
---@field max_entries number

---@class CommentTranslateTargetsConfig
---@field comment boolean
---@field string boolean

---@class CommentTranslateKeymapsConfig
---@field hover? string|false
---@field hover_manual? string|false Keymap for manual hover when auto-hover is disabled
---@field replace? string|false
---@field toggle? string|false

local M = {}

---@return string
local function get_default_language()
  local lang = vim.env.LANG or vim.env.LANGUAGE or vim.env.LC_ALL or ''
  local code = lang:match('^([^_.@]+)')
  if code and code ~= '' and code ~= 'C' and code ~= 'POSIX' then
    return code
  end
  local vim_lang = vim.v.lang or ''
  code = vim_lang:match('^([^_.@]+)')
  if code and code ~= '' and code ~= 'C' then
    return code
  end
  return 'en'
end

---@type CommentTranslateConfig
local default_config = {
  target_language = get_default_language(),
  translate_service = 'google',
  hover = {
    enabled = true,
    delay = 500,
    auto = true,
  },
  immersive = {
    enabled = false,
  },
  cache = {
    enabled = true,
    max_entries = 1000,
  },
  max_length = 5000,
  targets = {
    comment = true,
    string = true,
  },
  keymaps = {
    hover = '<leader>th',
    hover_manual = '<leader>tc',
    replace = '<leader>tr',
    toggle = '<leader>tt',
  },
}

---@type CommentTranslateConfig
M.config = vim.deepcopy(default_config)

local function warn_unknown(prefix, tbl, allowed)
  for key, _ in pairs(tbl) do
    if not allowed[key] then
      vim.notify(
        string.format('comment-translate: unknown config key %s.%s', prefix, key),
        vim.log.levels.WARN
      )
    end
  end
end

local function validate(user_config)
  if type(user_config) ~= 'table' then
    return
  end

  vim.validate({
    target_language = { user_config.target_language, 'string', true },
    translate_service = { user_config.translate_service, 'string', true },
    hover = { user_config.hover, 'table', true },
    immersive = { user_config.immersive, 'table', true },
    cache = { user_config.cache, 'table', true },
    max_length = { user_config.max_length, 'number', true },
    targets = { user_config.targets, 'table', true },
    keymaps = { user_config.keymaps, 'table', true },
  })

  if user_config.hover then
    warn_unknown('hover', user_config.hover, { enabled = true, delay = true, auto = true })
    vim.validate({
      ['hover.enabled'] = { user_config.hover.enabled, 'boolean', true },
      ['hover.delay'] = { user_config.hover.delay, 'number', true },
      ['hover.auto'] = { user_config.hover.auto, 'boolean', true },
    })
  end

  if user_config.immersive then
    warn_unknown('immersive', user_config.immersive, { enabled = true })
    vim.validate({
      ['immersive.enabled'] = { user_config.immersive.enabled, 'boolean', true },
    })
  end

  if user_config.cache then
    warn_unknown('cache', user_config.cache, { enabled = true, max_entries = true })
    vim.validate({
      ['cache.enabled'] = { user_config.cache.enabled, 'boolean', true },
      ['cache.max_entries'] = { user_config.cache.max_entries, 'number', true },
    })
    -- Ensure max_entries is at least 1 to prevent infinite loops
    if user_config.cache.max_entries and user_config.cache.max_entries < 1 then
      vim.notify(
        'comment-translate: cache.max_entries must be >= 1, defaulting to 1',
        vim.log.levels.WARN
      )
      user_config.cache.max_entries = 1
    end
  end

  if user_config.targets then
    warn_unknown('targets', user_config.targets, { comment = true, string = true })
    vim.validate({
      ['targets.comment'] = { user_config.targets.comment, 'boolean', true },
      ['targets.string'] = { user_config.targets.string, 'boolean', true },
    })
  end

  if user_config.keymaps then
    warn_unknown(
      'keymaps',
      user_config.keymaps,
      { hover = true, hover_manual = true, replace = true, toggle = true }
    )
    vim.validate({
      ['keymaps.hover'] = { user_config.keymaps.hover, { 'string', 'boolean' }, true },
      ['keymaps.hover_manual'] = { user_config.keymaps.hover_manual, { 'string', 'boolean' }, true },
      ['keymaps.replace'] = { user_config.keymaps.replace, { 'string', 'boolean' }, true },
      ['keymaps.toggle'] = { user_config.keymaps.toggle, { 'string', 'boolean' }, true },
    })
  end
end

---@param user_config? CommentTranslateConfig
function M.setup(user_config)
  user_config = user_config or {}
  validate(user_config)
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(default_config), user_config)
end

---@return CommentTranslateConfig
function M.get()
  return M.config
end

function M.reset()
  M.config = vim.deepcopy(default_config)
end

return M
