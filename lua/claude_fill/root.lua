local M = {}

---@param buf integer
---@return string|nil
function M.of_buffer(buf)
  if vim.api.nvim_buf_get_name(buf) == '' then
    return nil
  end
  return vim.fs.root(buf, '.git')
end

return M
