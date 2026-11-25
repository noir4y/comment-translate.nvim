local M = {}

local tracked = {}

-- Track text updates separately from changedtick, which can advance on a save.
function M.capture(bufnr)
  local state = tracked[bufnr]
  if not state then
    state = { revision = 0 }
    local function advance()
      state.revision = state.revision + 1
    end
    local attached = vim.api.nvim_buf_is_loaded(bufnr)
      and vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = advance,
        on_reload = advance,
        on_detach = function()
          tracked[bufnr] = nil
        end,
      })
    if attached then
      tracked[bufnr] = state
    end
  end

  local revision = state.revision
  return function()
    return tracked[bufnr] == state and state.revision == revision
  end
end

return M
