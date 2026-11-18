local primer = require('claude_fill.primer')
local root = require('claude_fill.root')
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

---@param message string
local function notify_error(message)
  vim.notify('claude-fill: ' .. message, vim.log.levels.ERROR)
end

---@param opts vim.api.keyset.create_user_command.command_args
local function prime(opts)
  if opts.range ~= 0 then
    return notify_error('prime does not take a range')
  end
  local project_root = root.of_buffer(vim.api.nvim_get_current_buf())
  if not project_root then
    return notify_error('buffer is not a file inside a git repository')
  end
  primer.prime(project_root)
end

---@param opts vim.api.keyset.create_user_command.command_args
local function cancel(opts)
  if opts.range ~= 0 then
    return notify_error('cancel does not take a range')
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if not require('claude_fill.fill').cancel_at(vim.api.nvim_get_current_buf(), row) then
    notify_error('no active fill at the cursor')
  end
end

---@param ev { data: vim.event.progress.data }
local function on_progress(ev)
  if ev.data.status == 'cancel' then
    require('claude_fill.fill').cancel_by_progress(ev.data.id)
  end
end

---@param opts vim.api.keyset.create_user_command.command_args
local function run(opts)
  if opts.args == 'prime' then
    return prime(opts)
  end
  if opts.args == 'cancel' then
    return cancel(opts)
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
  vim.api.nvim_create_autocmd('Progress', {
    pattern = require('claude_fill.indicator').PROGRESS_SOURCE,
    callback = on_progress,
  })
  vim.api.nvim_create_user_command('ClaudeFill', run, { nargs = '*', range = true })
  vim.keymap.set('n', '<Plug>(ClaudeFill)', '<Cmd>ClaudeFill<CR>')
  vim.keymap.set('x', '<Plug>(ClaudeFill)', ':ClaudeFill<CR>')
end

return M
