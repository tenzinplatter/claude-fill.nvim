local cli = require('claude_fill.cli')
local config = require('claude_fill.config')
local indicator_mod = require('claude_fill.indicator')
local primer = require('claude_fill.primer')
local prompt = require('claude_fill.prompt')
local root = require('claude_fill.root')
local target_mod = require('claude_fill.target')

---@class claude_fill.Applied
---@field kind 'applied'

---@class claude_fill.Failed
---@field kind 'failed'
---@field message string

---@class claude_fill.Lines
---@field kind 'lines'
---@field lines string[]

---@alias claude_fill.Outcome claude_fill.Applied|claude_fill.Failed
---@alias claude_fill.Resolution claude_fill.Lines|claude_fill.Failed

---@class claude_fill.Fill
---@field target claude_fill.Target
---@field indicator claude_fill.Indicator
---@field state { kind: 'awaiting_primer', handle: claude_fill.PrimerHandle }|{ kind: 'running', run: claude_fill.Run }|{ kind: 'finished', outcome: claude_fill.Outcome }

local M = {}

local on_primer

---@type claude_fill.Fill[]
local active = {}

---@param target claude_fill.Target
---@return boolean
local function overlaps_active(target)
  for _, fill in ipairs(active) do
    if target_mod.span(fill.target) and target_mod.overlaps(fill.target, target) then
      return true
    end
  end
  return false
end

---@param fill claude_fill.Fill
---@param outcome claude_fill.Outcome
local function leave_active(fill, outcome)
  fill.state = { kind = 'finished', outcome = outcome }
  active = vim.tbl_filter(function(other)
    return other ~= fill
  end, active)
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
  leave_active(fill, outcome)
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
    finish(fill, resolution)
  end
end

---@param event claude_fill.Crashed
---@return claude_fill.Outcome
local function crash_outcome(event)
  return { kind = 'failed', message = cli.crash_message(event) }
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
---@param primer_id string
---@return claude_fill.RunSpec
local function run_spec(target, project_root, instruction, primer_id)
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
    session = { kind = 'fork', primer_id = primer_id },
    answer = 'required',
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

---@param get_fill fun(): claude_fill.Fill
---@param project_root string
---@param instruction string
---@param can_rebuild boolean
---@return claude_fill.PrimerHandle
local function request_primer(get_fill, project_root, instruction, can_rebuild)
  return primer.acquire(project_root, function(result)
    on_primer(get_fill(), project_root, instruction, can_rebuild, result)
  end)
end

---@param fill claude_fill.Fill
---@param project_root string
---@param instruction string
---@param primer_id string
---@param can_rebuild boolean
local function run_forked(fill, project_root, instruction, primer_id, can_rebuild)
  local spec = run_spec(fill.target, project_root, instruction, primer_id)
  local run = cli.run(spec, function(event)
    if event.kind == 'crashed' and event.missing_session and can_rebuild then
      primer.invalidate(project_root, primer_id)
      local handle = request_primer(function()
        return fill
      end, project_root, instruction, false)
      fill.state = { kind = 'awaiting_primer', handle = handle }
      return
    end
    handle_event(fill, event)
  end)
  fill.state = { kind = 'running', run = run }
end

---@param fill claude_fill.Fill
---@param project_root string
---@param instruction string
---@param can_rebuild boolean
---@param result claude_fill.PrimerResult
function on_primer(fill, project_root, instruction, can_rebuild, result)
  if fill.state.kind == 'finished' then
    return
  end
  if result.kind == 'failed' then
    return finish(fill, { kind = 'failed', message = result.message })
  end
  if not target_mod.span(fill.target) then
    return finish(fill, { kind = 'failed', message = 'target no longer exists' })
  end
  run_forked(fill, project_root, instruction, result.session_id, can_rebuild)
end

---@param target claude_fill.Target
---@param project_root string
---@param instruction string
local function launch(target, project_root, instruction)
  ---@type claude_fill.Fill
  local fill
  local handle = request_primer(function()
    return fill
  end, project_root, instruction, true)
  fill = {
    target = target,
    indicator = indicator_mod.start(target),
    state = { kind = 'awaiting_primer', handle = handle },
  }
  table.insert(active, fill)
end

---@param target claude_fill.Target
---@param instruction string
function M.start(target, instruction)
  local project_root = root.of_buffer(target.buf)
  if not project_root then
    return reject(target, 'buffer is not a file inside a git repository')
  end
  if overlaps_active(target) then
    return reject(target, 'target overlaps an active fill')
  end
  launch(target, project_root, instruction)
end

return M
