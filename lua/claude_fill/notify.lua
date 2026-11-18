local M = {}

---@param message string
function M.error(message)
  vim.notify('claude-fill: ' .. message, vim.log.levels.ERROR)
end

return M
