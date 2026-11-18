local cli = require('claude_fill.cli')
local config = require('claude_fill.config')
local prompt = require('claude_fill.prompt')
local root = require('claude_fill.root')
local store = require('claude_fill.primer_store')
local uuid = require('claude_fill.uuid')

---@class claude_fill.PrimerReady
---@field kind 'ready'
---@field session_id string

---@class claude_fill.PrimerFailed
---@field kind 'failed'
---@field message string

---@alias claude_fill.PrimerResult claude_fill.PrimerReady|claude_fill.PrimerFailed
---@alias claude_fill.PrimerWaiter fun(result: claude_fill.PrimerResult)

---@class claude_fill.Waiters
---@field entries table<integer, claude_fill.PrimerWaiter>
---@field next_id integer
---@field reporter claude_fill.PrimerWaiter|nil

---@class claude_fill.PrimerHandle
---@field leave fun()

---@class claude_fill.ReadyPrimer
---@field kind 'ready'
---@field session_id string
---@field head claude_fill.Head
---@field failed_head claude_fill.Head|nil

---@alias claude_fill.PrimerState
---| { kind: 'absent' }
---| { kind: 'building', waiters: claude_fill.Waiters }
---| { kind: 'rebuilding', current: claude_fill.ReadyPrimer, waiters: claude_fill.Waiters }
---| claude_fill.ReadyPrimer

local M = {}

local FAILURE_PREFIX = 'primer build failed: '

---@type table<string, claude_fill.PrimerState>|nil
local states

---@return table<string, claude_fill.PrimerState>
local function all_states()
  if not states then
    states = {}
    for project_root, record in pairs(store.load()) do
      states[project_root] = { kind = 'ready', session_id = record.session_id, head = record.head }
    end
  end
  return states
end

---@param project_root string
---@return claude_fill.PrimerState
local function state_of(project_root)
  return all_states()[project_root] or { kind = 'absent' }
end

---@param project_root string
---@param record claude_fill.PrimerRecord|nil
local function persist(project_root, record)
  local ok, err = pcall(store.set, project_root, record)
  if not ok then
    vim.notify('claude-fill: could not save primer state: ' .. tostring(err), vim.log.levels.WARN)
  end
end

---@return claude_fill.Waiters
local function new_waiters()
  return { entries = {}, next_id = 1 }
end

---@param waiters claude_fill.Waiters
---@param waiter claude_fill.PrimerWaiter
---@return claude_fill.PrimerHandle
local function add_waiter(waiters, waiter)
  local id = waiters.next_id
  waiters.next_id = id + 1
  waiters.entries[id] = waiter
  return {
    leave = function()
      waiters.entries[id] = nil
    end,
  }
end

---@param waiter claude_fill.PrimerWaiter
---@param result claude_fill.PrimerResult
local function call_waiter(waiter, result)
  local ok, err = pcall(waiter, result)
  if not ok then
    vim.notify('claude-fill: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

---@param waiters claude_fill.Waiters
---@param result claude_fill.PrimerResult
local function notify_waiters(waiters, result)
  local ids = vim.tbl_keys(waiters.entries)
  table.sort(ids)
  for _, id in ipairs(ids) do
    call_waiter(waiters.entries[id], result)
  end
  if waiters.reporter then
    call_waiter(waiters.reporter, result)
  end
end

---@param state claude_fill.PrimerState
---@return claude_fill.Waiters
local function waiters_of(state)
  if state.kind == 'building' or state.kind == 'rebuilding' then
    return state.waiters
  end
  return new_waiters()
end

---@param waiter claude_fill.PrimerWaiter
---@param result claude_fill.PrimerResult
---@return claude_fill.PrimerHandle
local function deliver_later(waiter, result)
  local left = false
  vim.schedule(function()
    if not left then
      waiter(result)
    end
  end)
  return {
    leave = function()
      left = true
    end,
  }
end

---@param project_root string
---@param session_id string
---@param head claude_fill.Head
local function settle_ready(project_root, session_id, head)
  local waiters = waiters_of(state_of(project_root))
  all_states()[project_root] = { kind = 'ready', session_id = session_id, head = head }
  persist(project_root, { session_id = session_id, head = head })
  notify_waiters(waiters, { kind = 'ready', session_id = session_id })
end

---@param project_root string
---@param message string
---@param head claude_fill.Head
local function settle_failed(project_root, message, head)
  local state = state_of(project_root)
  if state.kind == 'rebuilding' then
    all_states()[project_root] = vim.tbl_extend('force', state.current, { failed_head = head })
  else
    all_states()[project_root] = nil
  end
  notify_waiters(waiters_of(state), { kind = 'failed', message = FAILURE_PREFIX .. message })
end

---@param session_id string
---@param project_root string
---@return claude_fill.RunSpec
local function build_spec(session_id, project_root)
  local cfg = config.get()
  return {
    prompt = prompt.primer(cfg.primer_prompt),
    session = { kind = 'primer', id = session_id },
    answer = 'ignored',
    schema = prompt.answer_schema(),
    model = cfg.model,
    tools = cfg.tools,
    allowed_tools = cfg.allowed_tools,
    cwd = project_root,
  }
end

---@param project_root string
---@param head claude_fill.Head
---@param session_id string
local function run_build(project_root, head, session_id)
  cli.run(build_spec(session_id, project_root), function(event)
    if event.kind == 'done' then
      settle_ready(project_root, session_id, head)
    elseif event.kind == 'crashed' then
      settle_failed(project_root, cli.crash_message(event), head)
    end
  end)
end

---@param project_root string
---@param previous claude_fill.ReadyPrimer|nil
---@param head claude_fill.Head
---@param reporter claude_fill.PrimerWaiter|nil
---@return claude_fill.Waiters
local function start_build(project_root, previous, head, reporter)
  local waiters = new_waiters()
  waiters.reporter = reporter
  if previous then
    all_states()[project_root] = { kind = 'rebuilding', current = previous, waiters = waiters }
  else
    all_states()[project_root] = { kind = 'building', waiters = waiters }
  end
  run_build(project_root, head, uuid.v4())
  return waiters
end

---@param result claude_fill.PrimerResult
local function report(result)
  if result.kind == 'ready' then
    vim.notify('claude-fill: primer ready')
  else
    vim.notify('claude-fill: ' .. result.message, vim.log.levels.ERROR)
  end
end

---@param primer claude_fill.ReadyPrimer
---@param head claude_fill.HeadReading
---@return boolean
local function is_stale(primer, head)
  if head.kind == 'unreadable' then
    return false
  end
  return not vim.deep_equal(primer.head, head.head)
    and not vim.deep_equal(primer.failed_head, head.head)
end

---@param project_root string
---@param primer claude_fill.ReadyPrimer
local function rebuild_if_stale(project_root, primer)
  local head = root.head(project_root)
  if is_stale(primer, head) then
    start_build(project_root, primer, head.head, report)
  end
end

---@param message string
---@return string
local function unreadable_message(message)
  return 'cannot read git HEAD: ' .. message
end

---@param project_root string
---@param waiter claude_fill.PrimerWaiter
---@return claude_fill.PrimerHandle
function M.acquire(project_root, waiter)
  local state = state_of(project_root)
  if state.kind == 'ready' then
    rebuild_if_stale(project_root, state)
    return deliver_later(waiter, { kind = 'ready', session_id = state.session_id })
  end
  if state.kind == 'rebuilding' then
    return deliver_later(waiter, { kind = 'ready', session_id = state.current.session_id })
  end
  if state.kind == 'building' then
    return add_waiter(state.waiters, waiter)
  end
  local head = root.head(project_root)
  if head.kind == 'unreadable' then
    return deliver_later(waiter, { kind = 'failed', message = unreadable_message(head.error) })
  end
  return add_waiter(start_build(project_root, nil, head.head, nil), waiter)
end

---@param project_root string
---@param session_id string
function M.invalidate(project_root, session_id)
  local state = state_of(project_root)
  if state.kind == 'ready' and state.session_id == session_id then
    all_states()[project_root] = nil
    persist(project_root, nil)
  elseif state.kind == 'rebuilding' and state.current.session_id == session_id then
    state.waiters.reporter = nil
    all_states()[project_root] = { kind = 'building', waiters = state.waiters }
    persist(project_root, nil)
  end
end

---@param project_root string
function M.prime(project_root)
  local state = state_of(project_root)
  if state.kind == 'building' or state.kind == 'rebuilding' then
    state.waiters.reporter = report
    return vim.notify('claude-fill: primer is already being built')
  end
  local head = root.head(project_root)
  if head.kind == 'unreadable' then
    return report({ kind = 'failed', message = unreadable_message(head.error) })
  end
  vim.notify('claude-fill: priming ' .. project_root)
  start_build(project_root, state.kind == 'ready' and state or nil, head.head, report)
end

return M
