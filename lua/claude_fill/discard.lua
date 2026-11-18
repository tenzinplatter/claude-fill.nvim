local config = require('claude_fill.config')

---@class claude_fill.SavedReplacement
---@field kind 'saved'
---@field register claude_fill.Register
---@field unavailable claude_fill.Register|nil
---@field replacing string|nil

---@class claude_fill.EmptyReplacement
---@field kind 'empty'

---@class claude_fill.NoReplacement
---@field kind 'none'

---@alias claude_fill.SaveResult claude_fill.SavedReplacement|claude_fill.EmptyReplacement
---@alias claude_fill.DiscardedReplacement claude_fill.SaveResult|claude_fill.NoReplacement

---@class claude_fill.Deposit
---@field instruction string
---@field lines string[]

local M = {}

local FALLBACK_REGISTER = '"'

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

---@param register claude_fill.Register
---@return boolean
local function is_available(register)
  return vim.fn.has('clipboard') == 1 or not register:match('^[+*]$')
end

---@param configured claude_fill.Register
---@return claude_fill.Register register
---@return claude_fill.Register|nil unavailable
local function writable_register(configured)
  if is_available(configured) then
    return configured, nil
  end
  return FALLBACK_REGISTER, configured
end

---@param instruction string
---@param lines string[]
---@param register claude_fill.Register
---@return string|nil replacing
local function deposit(instruction, lines, register)
  local replacing = replaced_instruction(register)
  vim.fn.setreg(register, lines, 'l')
  deposits[register] = { instruction = instruction, lines = lines }
  return replacing
end

---@param instruction string
---@param lines string[]
---@return claude_fill.SaveResult
function M.save(instruction, lines)
  if #lines == 0 then
    return { kind = 'empty' }
  end
  local register, unavailable = writable_register(config.get().discard_register)
  return {
    kind = 'saved',
    register = register,
    unavailable = unavailable,
    replacing = deposit(instruction, lines, register),
  }
end

---@param saved claude_fill.SavedReplacement
---@return string
local function saved_detail(saved)
  local fallback = saved.unavailable
      and (' (no clipboard provider for register %s)'):format(saved.unavailable)
    or ''
  local replacing = saved.replacing
      and (', replacing the replacement for %q'):format(saved.replacing)
    or ''
  return ('saved to register %s%s%s'):format(saved.register, fallback, replacing)
end

---@param instruction string
---@param replacement claude_fill.DiscardedReplacement
---@return string
function M.message(instruction, replacement)
  if replacement.kind == 'none' then
    return ('target changed or was removed; %q stopped before a replacement was produced'):format(
      instruction
    )
  end
  local head = ('target changed or was removed; replacement for %q not applied'):format(instruction)
  if replacement.kind == 'empty' then
    return head .. ' (nothing to save)'
  end
  return ('%s; %s'):format(head, saved_detail(replacement))
end

return M
