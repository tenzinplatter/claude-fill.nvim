---@alias claude_fill.Register '"'|'+'|'*'|'-'|'a'|'b'|'c'|'d'|'e'|'f'|'g'|'h'|'i'|'j'|'k'|'l'|'m'|'n'|'o'|'p'|'q'|'r'|'s'|'t'|'u'|'v'|'w'|'x'|'y'|'z'

---@class claude_fill.Config
---@field model string
---@field tools string[]
---@field allowed_tools string[]
---@field discard_register claude_fill.Register
---@field primer_prompt? string

---@class claude_fill.UserConfig
---@field model? string
---@field tools? string[]
---@field allowed_tools? string[]
---@field discard_register? claude_fill.Register
---@field primer_prompt? string

local M = {}

---@type claude_fill.Config
local DEFAULTS = {
  model = 'sonnet',
  discard_register = 'z',
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

---@param register any
---@return boolean
local function is_register(register)
  if type(register) ~= 'string' or not register:match('^[%l"+*-]$') then
    return false
  end
  return vim.fn.has('clipboard') == 1 or not register:match('^[+*]$')
end

---@param register any
local function validate_register(register)
  if not is_register(register) then
    error(
      ('claude-fill: discard_register must be one of a-z, ", -, or (with a clipboard provider) + or *; got %s'):format(
        vim.inspect(register)
      )
    )
  end
end

---@param user? claude_fill.UserConfig
function M.setup(user)
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(DEFAULTS), user or {})
  validate_register(merged.discard_register)
  current = merged
end

---@return claude_fill.Config
function M.get()
  return current
end

return M
