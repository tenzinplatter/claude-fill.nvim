local M = {}

---@return string
function M.v4()
  local bytes = { vim.uv.random(16):byte(1, 16) }
  bytes[7] = bytes[7] % 16 + 0x40
  bytes[9] = bytes[9] % 64 + 0x80
  local hex = vim.tbl_map(function(byte)
    return ('%02x'):format(byte)
  end, bytes)
  local joined = table.concat(hex)
  return table.concat({
    joined:sub(1, 8),
    joined:sub(9, 12),
    joined:sub(13, 16),
    joined:sub(17, 20),
    joined:sub(21, 32),
  }, '-')
end

return M
