---@alias claude_fill.Head
---| { kind: 'commit', sha: string }
---| { kind: 'unborn' }

---@alias claude_fill.HeadReading
---| { kind: 'read', head: claude_fill.Head }
---| { kind: 'unreadable', error: string }

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
---@return claude_fill.HeadReading
function M.head(project_root)
  local result = vim
    .system({ 'git', 'rev-parse', '--verify', '-q', 'HEAD' }, { cwd = project_root, text = true })
    :wait()
  if result.code == 1 and vim.trim(result.stderr or '') == '' then
    return { kind = 'read', head = { kind = 'unborn' } }
  end
  if result.code ~= 0 then
    return { kind = 'unreadable', error = vim.trim(result.stderr or '') }
  end
  return { kind = 'read', head = { kind = 'commit', sha = vim.trim(result.stdout) } }
end

return M
