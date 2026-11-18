local M = {}

---@param user? claude_fill.UserConfig
function M.setup(user)
  require('claude_fill.config').setup(user)
end

return M
