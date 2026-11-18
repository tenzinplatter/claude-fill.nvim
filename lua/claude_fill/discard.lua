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
---@return '+'|'*'|nil
local function missing_clipboard(register)
  if vim.fn.has('clipboard') == 1 then
    return nil
  end
  if register == '+' then
    return '+'
  end
  if register == '*' then
    return '*'
  end
  return nil
end

---@param configured claude_fill.Register
---@return claude_fill.SavedReplacement|claude_fill.FallbackReplacement
local function destination(configured)
  local wanted = missing_clipboard(configured)
  if wanted then
    ---@type claude_fill.FallbackReplacement
    local fallback = { kind = 'fallback', wanted = wanted }
    return fallback
  end
  ---@type claude_fill.SavedReplacement
  local saved = { kind = 'saved', register = configured }
  return saved
end

---@param variant claude_fill.SavedReplacement|claude_fill.FallbackReplacement
---@return claude_fill.Register
local function register_of(variant)
  if variant.kind == 'saved' then
    return variant.register
  elseif variant.kind == 'fallback' then
    return FALLBACK_REGISTER
  end
  error('unreachable replacement kind')
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
  local variant = destination(config.get().discard_register)
  variant.replacing = deposit(instruction, lines, register_of(variant))
  return variant
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
      register_of(replacement),
      replacing_detail(replacement.replacing)
    )
  elseif replacement.kind == 'fallback' then
    return ('saved to register %s (no clipboard provider for register %s)%s'):format(
      register_of(replacement),
      replacement.wanted,
      replacing_detail(replacement.replacing)
    )
  end
  error('unreachable replacement kind')
end

---@param replacement claude_fill.SaveResult
---@return string
function M.detail(replacement)
  if replacement.kind == 'empty' then
    return 'nothing to save'
  end
  return saved_detail(replacement)
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
  return ('target changed or was removed; replacement for %q not applied; %s'):format(
    instruction,
    M.detail(replacement)
  )
end

return M
