---@class claude_fill.PrimerRecord
---@field session_id string
---@field head string

local M = {}

---@return string
local function path()
  return vim.fs.joinpath(vim.fn.stdpath('state') --[[@as string]], 'claude-fill', 'primers.json')
end

---@param value any
---@return boolean
local function is_record(value)
  return type(value) == 'table'
    and type(value.session_id) == 'string'
    and type(value.head) == 'string'
end

---@return table<string, claude_fill.PrimerRecord>
function M.load()
  local file = io.open(path(), 'r')
  if not file then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, file:read('*a'))
  file:close()
  if not ok or type(decoded) ~= 'table' then
    return {}
  end
  return vim.tbl_filter(is_record, decoded)
end

---@param records table<string, claude_fill.PrimerRecord>
function M.save(records)
  vim.fn.mkdir(vim.fs.dirname(path()), 'p')
  local file = assert(io.open(path(), 'w'))
  file:write(vim.json.encode(records))
  file:close()
end

return M
