---@class claude_fill.Config
---@field model string
---@field tools string[]
---@field allowed_tools string[]

---@class claude_fill.UserConfig
---@field model? string
---@field tools? string[]
---@field allowed_tools? string[]

local M = {}

---@type claude_fill.Config
local DEFAULTS = {
  model = 'sonnet',
  tools = { 'Read', 'Grep', 'Glob', 'WebFetch', 'WebSearch', 'Bash' },
  allowed_tools = {
    'Read',
    'Grep',
    'Glob',
    'WebFetch',
    'WebSearch',
    'Bash(git log:*)',
    'Bash(git show:*)',
    'Bash(git diff:*)',
    'Bash(git blame:*)',
    'Bash(ls:*)',
  },
}

---@type claude_fill.Config
local current = vim.deepcopy(DEFAULTS)

---@param user? claude_fill.UserConfig
function M.setup(user)
  current = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULTS), user or {})
end

---@return claude_fill.Config
function M.get()
  return current
end

return M
