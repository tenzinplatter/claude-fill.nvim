local M = {}

---@param message string
function M.error(message)
  vim.notify('claude-fill: ' .. message, vim.log.levels.ERROR)
end

---@param message string
function M.warn(message)
  vim.notify('claude-fill: ' .. message, vim.log.levels.WARN)
end

return M
