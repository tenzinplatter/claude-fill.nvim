local cli = require('claude_fill.cli')
local config = require('claude_fill.config')
local discard = require('claude_fill.discard')
local indicator_mod = require('claude_fill.indicator')
local notify = require('claude_fill.notify')
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

---@class claude_fill.Cancelled
---@field kind 'cancelled'

---@class claude_fill.Declined
---@field kind 'declined'
---@field instruction string
---@field reason string

---@class claude_fill.Discarded
---@field kind 'discarded'
---@field instruction string
---@field replacement claude_fill.DiscardedReplacement

---@alias claude_fill.Outcome claude_fill.Applied|claude_fill.Failed|claude_fill.Cancelled|claude_fill.Declined|claude_fill.Discarded
---@alias claude_fill.Attempt 'first'|'retry'
---@alias claude_fill.Resolution claude_fill.Lines|claude_fill.Failed|claude_fill.Declined

---@alias claude_fill.FillState
---| { kind: 'awaiting_primer', handle: claude_fill.PrimerHandle }
---| { kind: 'running', run: claude_fill.Run }

---@class claude_fill.Fill
---@field snapshot claude_fill.TargetSnapshot
---@field project_root string
---@field instruction string
---@field indicator claude_fill.Indicator

---@class claude_fill.RunContext
---@field primer_id string
---@field attempt claude_fill.Attempt

local M = {}

local await_primer

---@type table<claude_fill.Fill, claude_fill.FillState>
local states = {}

---@param fill claude_fill.Fill
---@return claude_fill.Target
local function target_of(fill)
  return target_mod.of(fill.snapshot)
end

---@param target claude_fill.Target
---@return claude_fill.Target|nil
local function conflicting_target(target)
  for fill in pairs(states) do
    local active = target_of(fill)
    if target_mod.span(active) and target_mod.overlaps(active, target) then
      return active
    end
  end
  return nil
end

---@param target claude_fill.Target
---@param active claude_fill.Target
---@return string
local function conflict_message(target, active)
  if target_mod.adjoins_start(target, active) then
    return 'target is adjacent to the start of an active fill'
  end
  return 'target overlaps an active fill'
end

---@param outcome claude_fill.Outcome
---@return claude_fill.ProgressStatus
local function status_of(outcome)
  local kind = outcome.kind
  if kind == 'applied' then
    return 'success'
  elseif kind == 'failed' or kind == 'declined' or kind == 'discarded' then
    return 'failed'
  elseif kind == 'cancelled' then
    return 'cancel'
  end
  error('unhandled outcome ' .. kind)
end

---@param outcome claude_fill.Outcome
local function report(outcome)
  if outcome.kind == 'failed' then
    notify.error(outcome.message)
  elseif outcome.kind == 'declined' then
    notify.warn(('declined %q: %s'):format(outcome.instruction, outcome.reason))
  elseif outcome.kind == 'discarded' then
    notify.warn(discard.message(outcome.instruction, outcome.replacement))
  end
end

---@param fill claude_fill.Fill
---@param outcome claude_fill.Outcome
local function finish(fill, outcome)
  states[fill] = nil
  target_mod.release(fill.snapshot)
  report(outcome)
  indicator_mod.stop(fill.indicator, status_of(outcome))
end

---@param answer claude_fill.Answer|nil
---@param instruction string
---@return claude_fill.Resolution
local function resolve(answer, instruction)
  if not answer then
    return { kind = 'failed', message = 'claude returned an answer in an unexpected shape' }
  end
  if answer.kind == 'declined' then
    return { kind = 'declined', instruction = instruction, reason = answer.reason }
  end
  return { kind = 'lines', lines = prompt.replacement_lines(answer.replacement) }
end

---@param fill claude_fill.Fill
---@param lines string[]
---@return claude_fill.Outcome
local function write(fill, lines)
  local ok, err = pcall(target_mod.replace, target_of(fill), lines)
  if ok then
    return { kind = 'applied' }
  end
  return { kind = 'failed', message = 'could not write replacement: ' .. tostring(err) }
end

---@param fill claude_fill.Fill
---@param lines string[]
---@return claude_fill.Outcome
local function discard_lines(fill, lines)
  local ok, replacement = pcall(discard.save, fill.instruction, lines)
  if not ok then
    return { kind = 'failed', message = 'could not save replacement: ' .. tostring(replacement) }
  end
  return { kind = 'discarded', instruction = fill.instruction, replacement = replacement }
end

---@param fill claude_fill.Fill
---@param lines string[]
---@return claude_fill.Outcome
local function apply_lines(fill, lines)
  if target_mod.edited_since(fill.snapshot) then
    return discard_lines(fill, lines)
  end
  return write(fill, lines)
end

---@param fill claude_fill.Fill
---@param resolution claude_fill.Resolution
---@return claude_fill.Outcome
local function outcome_of(fill, resolution)
  if resolution.kind == 'lines' then
    return apply_lines(fill, resolution.lines)
  end
  return resolution
end

---@param fill claude_fill.Fill
---@param event claude_fill.Done
local function apply(fill, event)
  finish(fill, outcome_of(fill, resolve(prompt.decode_answer(event.answer), fill.instruction)))
end

---@param event claude_fill.Crashed
---@return claude_fill.Outcome
local function crash_outcome(event)
  return { kind = 'failed', message = cli.crash_message(event) }
end

---@param fill claude_fill.Fill
---@param primer_id string
local function refork(fill, primer_id)
  primer.invalidate(fill.project_root, primer_id)
  indicator_mod.show_working(fill.indicator)
  states[fill] = await_primer(fill, 'retry')
end

---@param event claude_fill.Crashed
---@param context claude_fill.RunContext
---@return boolean
local function should_refork(event, context)
  return event.missing_session and context.attempt == 'first'
end

---@param fill claude_fill.Fill
---@param event claude_fill.Event
---@param context claude_fill.RunContext
local function handle_event(fill, event, context)
  if not states[fill] then
    return
  end
  if event.kind == 'step' then
    indicator_mod.show_step(fill.indicator, event)
  elseif event.kind == 'done' then
    apply(fill, event)
  elseif should_refork(event, context) then
    refork(fill, context.primer_id)
  else
    finish(fill, crash_outcome(event))
  end
end

---@param snapshot claude_fill.TargetSnapshot
---@param project_root string
---@param instruction string
---@param primer_id string
---@return claude_fill.RunSpec
local function run_spec(snapshot, project_root, instruction, primer_id)
  local context = target_mod.context(snapshot, project_root)
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
  notify.error(message)
end

---@param fill claude_fill.Fill
---@param context claude_fill.RunContext
---@return claude_fill.FillState
local function run_forked(fill, context)
  local spec = run_spec(fill.snapshot, fill.project_root, fill.instruction, context.primer_id)
  local run = cli.run(spec, function(event)
    handle_event(fill, event, context)
  end)
  return { kind = 'running', run = run }
end

---@param fill claude_fill.Fill
---@param attempt claude_fill.Attempt
---@param result claude_fill.PrimerResult
local function on_primer(fill, attempt, result)
  if not states[fill] then
    return
  end
  if result.kind == 'failed' then
    return finish(fill, { kind = 'failed', message = result.message })
  end
  if target_mod.edited_since(fill.snapshot) then
    return finish(fill, {
      kind = 'discarded',
      instruction = fill.instruction,
      replacement = { kind = 'none' },
    })
  end
  states[fill] = run_forked(fill, { primer_id = result.session_id, attempt = attempt })
end

---@param fill claude_fill.Fill
---@param attempt claude_fill.Attempt
---@return claude_fill.FillState
function await_primer(fill, attempt)
  local handle = primer.acquire(fill.project_root, function(result)
    on_primer(fill, attempt, result)
  end)
  return { kind = 'awaiting_primer', handle = handle }
end

---@param target claude_fill.Target
---@param project_root string
---@param instruction string
local function launch(target, project_root, instruction)
  ---@type claude_fill.Fill
  local fill = {
    snapshot = target_mod.snapshot(target),
    project_root = project_root,
    instruction = instruction,
    indicator = indicator_mod.start(target, instruction),
  }
  states[fill] = await_primer(fill, 'first')
end

---@param state claude_fill.FillState
local function stop_work(state)
  if state.kind == 'awaiting_primer' then
    state.handle.leave()
  elseif state.kind == 'running' then
    state.run.cancel()
  end
end

---@param fill claude_fill.Fill
function M.cancel(fill)
  local state = states[fill]
  if not state then
    return
  end
  stop_work(state)
  finish(fill, { kind = 'cancelled' })
end

---@param predicate fun(fill: claude_fill.Fill): boolean
---@return boolean cancelled
local function cancel_first(predicate)
  for fill in pairs(states) do
    if predicate(fill) then
      M.cancel(fill)
      return true
    end
  end
  return false
end

---@param progress_id integer
function M.cancel_by_progress(progress_id)
  cancel_first(function(fill)
    return fill.indicator.progress_id == progress_id
  end)
end

---@param buf integer
---@param row integer 0-based
---@return boolean cancelled
function M.cancel_at(buf, row)
  return cancel_first(function(fill)
    local target = target_of(fill)
    return target.buf == buf and target_mod.contains_row(target, row)
  end) or cancel_first(function(fill)
    local target = target_of(fill)
    return target.buf == buf and target_mod.is_insertion_above(target, row)
  end)
end

---@param target claude_fill.Target
---@param instruction string
function M.start(target, instruction)
  local project_root = root.of_buffer(target.buf)
  if not project_root then
    return reject(target, 'buffer is not a file inside a git repository')
  end
  local active = conflicting_target(target)
  if active then
    return reject(target, conflict_message(target, active))
  end
  launch(target, project_root, instruction)
end

return M
