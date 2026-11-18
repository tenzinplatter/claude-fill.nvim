---@class claude_fill.PrimerRecord
---@field session_id string
---@field head claude_fill.Head

local M = {}

---@return string
local function path()
  return vim.fs.joinpath(vim.fn.stdpath('state') --[[@as string]], 'claude-fill', 'primers.json')
end

---@param head any
---@return boolean
local function is_head(head)
  if type(head) ~= 'table' then
    return false
  end
  return head.kind == 'unborn' or (head.kind == 'commit' and type(head.sha) == 'string')
end

---@param value any
---@return boolean
local function is_record(value)
  return type(value) == 'table' and type(value.session_id) == 'string' and is_head(value.head)
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
  local records = {}
  for project_root, record in pairs(decoded) do
    if is_record(record) then
      records[project_root] = record
    end
  end
  return records
end

---@param records table<string, claude_fill.PrimerRecord>
local function write_atomically(records)
  vim.fn.mkdir(vim.fs.dirname(path()), 'p')
  local temp = ('%s.%d.tmp'):format(path(), vim.uv.os_getpid())
  local file = assert(io.open(temp, 'w'))
  file:write(vim.json.encode(records))
  file:close()
  assert(os.rename(temp, path()))
end

---@param project_root string
---@param record claude_fill.PrimerRecord|nil
function M.set(project_root, record)
  local records = M.load()
  records[project_root] = record
  write_atomically(records)
end

return M
