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

---@alias claude_fill.PrimerState
---| { kind: 'absent' }
---| { kind: 'building', waiters: claude_fill.PrimerWaiter[] }
---| { kind: 'ready', session_id: string, head: string }

local M = {}

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

local function persist()
  local records = {}
  for project_root, state in pairs(all_states()) do
    if state.kind == 'ready' then
      records[project_root] = { session_id = state.session_id, head = state.head }
    end
  end
  store.save(records)
end

---@param project_root string
---@param waiters claude_fill.PrimerWaiter[]
---@param session_id string
---@param head string
local function succeed(project_root, waiters, session_id, head)
  all_states()[project_root] = { kind = 'ready', session_id = session_id, head = head }
  persist()
  for _, waiter in ipairs(waiters) do
    waiter({ kind = 'ready', session_id = session_id })
  end
end

---@param project_root string
---@param waiters claude_fill.PrimerWaiter[]
---@param message string
local function fail(project_root, waiters, message)
  all_states()[project_root] = nil
  for _, waiter in ipairs(waiters) do
    waiter({ kind = 'failed', message = 'primer build failed: ' .. message })
  end
end

---@param session_id string
---@param project_root string
---@return claude_fill.RunSpec
local function build_spec(session_id, project_root)
  local cfg = config.get()
  return {
    prompt = prompt.primer(cfg.primer_prompt),
    session = { kind = 'primer', id = session_id },
    schema = prompt.answer_schema(),
    model = cfg.model,
    tools = cfg.tools,
    allowed_tools = cfg.allowed_tools,
    cwd = project_root,
  }
end

---@param project_root string
---@param waiters claude_fill.PrimerWaiter[]
---@param head string
---@param session_id string
local function build(project_root, waiters, head, session_id)
  cli.run(build_spec(session_id, project_root), function(event)
    if event.kind == 'done' then
      succeed(project_root, waiters, session_id, head)
    elseif event.kind == 'crashed' then
      fail(project_root, waiters, cli.crash_message(event))
    end
  end)
end

---@param project_root string
---@param waiter claude_fill.PrimerWaiter
local function begin_build(project_root, waiter)
  local head = root.head(project_root)
  if not head then
    return waiter({ kind = 'failed', message = 'primer build failed: could not read git HEAD' })
  end
  local waiters = { waiter }
  all_states()[project_root] = { kind = 'building', waiters = waiters }
  build(project_root, waiters, head, uuid.v4())
end

---@param project_root string
---@param waiter claude_fill.PrimerWaiter
function M.acquire(project_root, waiter)
  local state = state_of(project_root)
  if state.kind == 'ready' then
    return waiter({ kind = 'ready', session_id = state.session_id })
  end
  if state.kind == 'building' then
    return table.insert(state.waiters, waiter)
  end
  begin_build(project_root, waiter)
end

---@param project_root string
function M.prime(project_root)
  vim.notify('claude-fill: priming ' .. project_root)
  M.acquire(project_root, function(result)
    if result.kind == 'ready' then
      vim.notify('claude-fill: primer ready for ' .. project_root)
    else
      vim.notify('claude-fill: ' .. result.message, vim.log.levels.ERROR)
    end
  end)
end

return M
