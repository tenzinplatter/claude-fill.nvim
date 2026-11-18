local cli = require('claude_fill.cli')
local config = require('claude_fill.config')
local indicator_mod = require('claude_fill.indicator')
local prompt = require('claude_fill.prompt')
local root = require('claude_fill.root')
local target_mod = require('claude_fill.target')

---@alias claude_fill.Outcome
---| { kind: 'applied' }
---| { kind: 'failed', message: string }

---@class claude_fill.Fill
---@field target claude_fill.Target
---@field indicator claude_fill.Indicator
---@field state { kind: 'running', run: claude_fill.Run }|{ kind: 'finished', outcome: claude_fill.Outcome }

local M = {}

---@type claude_fill.Fill[]
local running = {}

---@param target claude_fill.Target
---@return boolean
local function overlaps_running(target)
  for _, fill in ipairs(running) do
    if target_mod.overlaps(fill.target, target) then
      return true
    end
  end
  return false
end

---@param fill claude_fill.Fill
local function untrack(fill)
  running = vim.tbl_filter(function(other)
    return other ~= fill
  end, running)
end

---@param answer claude_fill.Answer|nil
---@return claude_fill.Outcome|string[]
local function outcome_of(answer)
  if not answer then
    return { kind = 'failed', message = 'claude returned an answer in an unexpected shape' }
  end
  if answer.kind == 'declined' then
    return { kind = 'failed', message = 'Declined: ' .. answer.reason }
  end
  return prompt.replacement_lines(answer.replacement)
end

---@param event claude_fill.Crashed
---@return claude_fill.Outcome
local function crash_outcome(event)
  local message = event.message
  if event.stderr ~= '' then
    message = message .. '\n' .. event.stderr
  end
  return { kind = 'failed', message = message }
end

---@param fill claude_fill.Fill
---@param outcome claude_fill.Outcome
local function finish(fill, outcome)
  fill.state = { kind = 'finished', outcome = outcome }
  indicator_mod.stop(fill.indicator)
  untrack(fill)
  target_mod.clear(fill.target)
  if outcome.kind == 'failed' then
    vim.notify('claude-fill: ' .. outcome.message, vim.log.levels.ERROR)
  end
end

---@param fill claude_fill.Fill
---@param event claude_fill.Done
local function apply(fill, event)
  local result = outcome_of(prompt.decode_answer(event.answer))
  if result.kind == 'failed' then
    return finish(fill, result)
  end
  target_mod.replace(fill.target, result)
  finish(fill, { kind = 'applied' })
end

---@param fill claude_fill.Fill
---@param event claude_fill.Event
local function handle_event(fill, event)
  if fill.state.kind == 'finished' then
    return
  end
  if event.kind == 'step' then
    indicator_mod.show_step(fill.indicator, event)
  elseif event.kind == 'done' then
    apply(fill, event)
  else
    finish(fill, crash_outcome(event))
  end
end

---@param target claude_fill.Target
---@param project_root string
---@param instruction string
---@return claude_fill.RunSpec
local function run_spec(target, project_root, instruction)
  local before, after = target_mod.surroundings(target)
  local cfg = config.get()
  return {
    prompt = prompt.fill({
      path = vim.fs.relpath(project_root, vim.api.nvim_buf_get_name(target.buf)) or '',
      filetype = vim.bo[target.buf].filetype,
      before = before,
      target = target_mod.lines(target),
      after = after,
      instruction = instruction,
    }),
    schema = prompt.answer_schema(),
    model = cfg.model,
    tools = cfg.tools,
    allowed_tools = cfg.allowed_tools,
    cwd = project_root,
  }
end

---@param message string
local function reject(target, message)
  target_mod.clear(target)
  vim.notify('claude-fill: ' .. message, vim.log.levels.ERROR)
end

---@param target claude_fill.Target
---@param instruction string
function M.start(target, instruction)
  local project_root = root.of_buffer(target.buf)
  if not project_root then
    return reject(target, 'buffer is not a file inside a git repository')
  end
  if overlaps_running(target) then
    return reject(target, 'target overlaps a running fill')
  end

  ---@type claude_fill.Fill
  local fill = {
    target = target,
    indicator = indicator_mod.start(target),
    state = { kind = 'running', run = { cancel = function() end } },
  }
  table.insert(running, fill)
  fill.state.run = cli.run(run_spec(target, project_root, instruction), function(event)
    handle_event(fill, event)
  end)
end

return M
