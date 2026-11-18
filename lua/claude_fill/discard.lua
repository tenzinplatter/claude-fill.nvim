local config = require('claude_fill.config')

---@class claude_fill.SavedReplacement
---@field kind 'saved'
---@field register claude_fill.Register
---@field replacing string|nil

---@class claude_fill.FallbackReplacement
---@field kind 'fallback'
---@field wanted '+'|'*'
---@field replacing string|nil

---@class claude_fill.EmptyReplacement
---@field kind 'empty'

---@class claude_fill.NoReplacement
---@field kind 'none'

---@alias claude_fill.SaveResult claude_fill.SavedReplacement|claude_fill.FallbackReplacement|claude_fill.EmptyReplacement
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
local function is_clipboard(register)
  return register:match('^[+*]$') ~= nil
end

---@param register claude_fill.Register
---@return boolean
local function is_available(register)
  return vim.fn.has('clipboard') == 1 or not is_clipboard(register)
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

---@param configured claude_fill.Register
---@param replacing string|nil
---@return claude_fill.SavedReplacement|claude_fill.FallbackReplacement
local function outcome(configured, replacing)
  if is_available(configured) then
    return { kind = 'saved', register = configured, replacing = replacing }
  end
  return { kind = 'fallback', wanted = configured, replacing = replacing }
end

---@param instruction string
---@param lines string[]
---@return claude_fill.SaveResult
function M.save(instruction, lines)
  if #lines == 0 then
    return { kind = 'empty' }
  end
  local configured = config.get().discard_register
  local register = is_available(configured) and configured or FALLBACK_REGISTER
  return outcome(configured, deposit(instruction, lines, register))
end

---@param replacing string|nil
---@return string
local function replacing_detail(replacing)
  return replacing and (', replacing the replacement for %q'):format(replacing) or ''
end

---@param replacement claude_fill.SavedReplacement|claude_fill.FallbackReplacement
---@return string
local function saved_detail(replacement)
  if replacement.kind == 'saved' then
    return ('saved to register %s%s'):format(
      replacement.register,
      replacing_detail(replacement.replacing)
    )
  elseif replacement.kind == 'fallback' then
    return ('saved to register %s (no clipboard provider for register %s)%s'):format(
      FALLBACK_REGISTER,
      replacement.wanted,
      replacing_detail(replacement.replacing)
    )
  end
  error('unreachable replacement kind')
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
