local target_mod = require('claude_fill.target')

local M = {}

---@param opts vim.api.keyset.create_user_command.command_args
---@return claude_fill.Target
local function target_of(opts)
  local buf = vim.api.nvim_get_current_buf()
  if opts.range == 0 then
    return target_mod.at_cursor(buf, opts.line1)
  end
  return target_mod.from_range(buf, opts.line1, opts.line2)
end

---@param target claude_fill.Target
---@param instruction string
local function start_with(target, instruction)
  if instruction == '' then
    return target_mod.clear(target)
  end
  require('claude_fill.fill').start(target, instruction)
end

local function prime()
  local project_root = require('claude_fill.root').of_buffer(vim.api.nvim_get_current_buf())
  if not project_root then
    return vim.notify(
      'claude-fill: buffer is not a file inside a git repository',
      vim.log.levels.ERROR
    )
  end
  require('claude_fill.primer').prime(project_root)
end

---@param opts vim.api.keyset.create_user_command.command_args
local function run(opts)
  if opts.args == 'prime' and opts.range == 0 then
    return prime()
  end
  local target = target_of(opts)
  if opts.args ~= '' then
    return start_with(target, opts.args)
  end
  vim.ui.input({ prompt = 'Claude fill: ' }, function(input)
    start_with(target, input or '')
  end)
end

function M.register()
  vim.api.nvim_create_user_command('ClaudeFill', run, { nargs = '*', range = true })
  vim.keymap.set('n', '<Plug>(ClaudeFill)', '<Cmd>ClaudeFill<CR>')
  vim.keymap.set('x', '<Plug>(ClaudeFill)', ':ClaudeFill<CR>')
end

return M
