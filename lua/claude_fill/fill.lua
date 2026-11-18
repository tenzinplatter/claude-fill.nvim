local cli = require('claude_fill.cli')
local config = require('claude_fill.config')
local indicator_mod = require('claude_fill.indicator')
local prompt = require('claude_fill.prompt')
local root = require('claude_fill.root')
local target_mod = require('claude_fill.target')

---@alias claude_fill.Outcome
---| { kind: 'applied' }
---| { kind: 'failed', message: string }

---@alias claude_fill.Resolution
---| { kind: 'lines', lines: string[] }
---| claude_fill.Outcome

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
---@param outcome claude_fill.Outcome
local function leave_running(fill, outcome)
  fill.state = { kind = 'finished', outcome = outcome }
  running = vim.tbl_filter(function(other)
    return other ~= fill
  end, running)
end

---@param outcome claude_fill.Outcome
local function report(outcome)
  if outcome.kind == 'failed' then
    vim.notify('claude-fill: ' .. outcome.message, vim.log.levels.ERROR)
  end
end

---@param fill claude_fill.Fill
---@param outcome claude_fill.Outcome
local function finish(fill, outcome)
  leave_running(fill, outcome)
  report(outcome)
  indicator_mod.stop(fill.indicator)
  target_mod.clear(fill.target)
end

---@param answer claude_fill.Answer|nil
---@return claude_fill.Resolution
local function resolve(answer)
  if not answer then
    return { kind = 'failed', message = 'claude returned an answer in an unexpected shape' }
  end
  if answer.kind == 'declined' then
    return { kind = 'failed', message = 'Declined: ' .. answer.reason }
  end
  return { kind = 'lines', lines = prompt.replacement_lines(answer.replacement) }
end

---@param fill claude_fill.Fill
---@param lines string[]
---@return claude_fill.Outcome
local function write(fill, lines)
  local ok, err = pcall(target_mod.replace, fill.target, lines)
  if ok then
    return { kind = 'applied' }
  end
  return { kind = 'failed', message = 'could not write replacement: ' .. tostring(err) }
end

---@param fill claude_fill.Fill
---@param event claude_fill.Done
local function apply(fill, event)
  local resolution = resolve(prompt.decode_answer(event.answer))
  if resolution.kind == 'lines' then
    finish(fill, write(fill, resolution.lines))
  elseif resolution.kind == 'failed' then
    finish(fill, { kind = 'failed', message = resolution.message })
  end
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
  local context = target_mod.context(target, project_root)
  local cfg = config.get()
  return {
    prompt = prompt.fill({
      path = context.path,
      filetype = context.filetype,
      before = context.before,
      target = context.target,
      after = context.after,
      instruction = instruction,
    }),
    session = { kind = 'ephemeral' },
    schema = prompt.answer_schema(),
    model = cfg.model,
    tools = cfg.tools,
    allowed_tools = cfg.allowed_tools,
    cwd = project_root,
  }
end

---@param target claude_fill.Target
---@param message string
local function reject(target, message)
  target_mod.clear(target)
  vim.notify('claude-fill: ' .. message, vim.log.levels.ERROR)
end

---@param target claude_fill.Target
---@param project_root string
---@param instruction string
local function launch(target, project_root, instruction)
  local indicator = indicator_mod.start(target)
  ---@type claude_fill.Fill
  local fill
  local run = cli.run(run_spec(target, project_root, instruction), function(event)
    handle_event(fill, event)
  end)
  fill = { target = target, indicator = indicator, state = { kind = 'running', run = run } }
  table.insert(running, fill)
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
  launch(target, project_root, instruction)
end

return M
