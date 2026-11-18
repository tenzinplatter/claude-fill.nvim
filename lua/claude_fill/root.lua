local M = {}

---@param buf integer
---@return string|nil
function M.of_buffer(buf)
  if vim.api.nvim_buf_get_name(buf) == '' then
    return nil
  end
  return vim.fs.root(buf, '.git')
end

---@param project_root string
---@return string|nil
function M.head(project_root)
  local result = vim
    .system({ 'git', 'rev-parse', 'HEAD' }, { cwd = project_root, text = true })
    :wait()
  if result.code ~= 0 then
    return nil
  end
  return vim.trim(result.stdout)
end

return M
