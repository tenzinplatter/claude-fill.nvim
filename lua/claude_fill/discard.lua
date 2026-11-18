local config = require('claude_fill.config')

---@alias claude_fill.Saved
---| { kind: 'register', register: claude_fill.Register, replacing: string|nil }
---| { kind: 'empty' }
---| { kind: 'unfilled' }

---@class claude_fill.Deposit
---@field instruction string
---@field lines string[]

local M = {}

---@type table<claude_fill.Register, claude_fill.Deposit>
local deposits = {}

---@param register claude_fill.Register
---@return string|nil
local function replaced_instruction(register)
  local deposit = deposits[register]
  if
    deposit
    and vim.fn.getregtype(register) == 'V'
    and vim.deep_equal(vim.fn.getreg(register, 1, true), deposit.lines)
  then
    return deposit.instruction
  end
  return nil
end

---@param instruction string
---@param lines string[]
---@return claude_fill.Saved
function M.save(instruction, lines)
  if #lines == 0 then
    return { kind = 'empty' }
  end
  local register = config.get().discard_register
  local replacing = replaced_instruction(register)
  vim.fn.setreg(register, lines, 'l')
  deposits[register] = { instruction = instruction, lines = lines }
  return { kind = 'register', register = register, replacing = replacing }
end

---@param instruction string
---@param saved claude_fill.Saved
---@return string
function M.message(instruction, saved)
  local head = ('target changed or was removed; replacement for %q not applied'):format(instruction)
  if saved.kind == 'unfilled' then
    return ('target changed before the fill ran; %q not run'):format(instruction)
  end
  if saved.kind == 'empty' then
    return head .. ' (nothing to save)'
  end
  local tail = saved.replacing and (', replacing the replacement for %q'):format(saved.replacing)
    or ''
  return ('%s; saved to register %s%s'):format(head, saved.register, tail)
end

return M
