---@class claude_fill.Step
---@field kind 'step'
---@field tool string
---@field input table<string, any>

---@class claude_fill.Done
---@field kind 'done'
---@field answer any

---@class claude_fill.Crashed
---@field kind 'crashed'
---@field message string
---@field stderr string

---@alias claude_fill.Event claude_fill.Step|claude_fill.Done|claude_fill.Crashed

---@alias claude_fill.Session { kind: 'ephemeral' }

---@class claude_fill.RunSpec
---@field session claude_fill.Session
---@field prompt string
---@field schema table
---@field model string
---@field tools string[]
---@field allowed_tools string[]
---@field cwd string

---@class claude_fill.Run
---@field cancel fun()

---@class claude_fill.ResultEvent
---@field is_error boolean
---@field subtype? string
---@field result? string
---@field structured_output? { answer?: any }

local M = {}

local ANSWER_TOOL = 'StructuredOutput'

---@param spec claude_fill.RunSpec
---@return string[]
function M.argv(spec)
  local argv = { 'claude', '-p', '--model', spec.model }
  vim.list_extend(argv, { '--tools', table.concat(spec.tools, ',') })
  vim.list_extend(argv, { '--allowedTools' })
  vim.list_extend(argv, spec.allowed_tools)
  vim.list_extend(argv, { '--permission-mode', 'dontAsk' })
  vim.list_extend(argv, { '--settings', vim.json.encode({ disableAllHooks = true }) })
  vim.list_extend(argv, { '--strict-mcp-config' })
  vim.list_extend(argv, { '--json-schema', vim.json.encode(spec.schema) })
  vim.list_extend(argv, { '--output-format', 'stream-json', '--verbose' })
  return argv
end

---@type table<string, string[]>
local SESSION_FLAGS = {
  ephemeral = { '--no-session-persistence' },
}

---@param spec claude_fill.RunSpec
---@return string[]
local function full_argv(spec)
  return vim.list_extend(M.argv(spec), SESSION_FLAGS[spec.session.kind])
end

---@param on_line fun(line: string)
---@return fun(chunk: string|nil)
local function line_feeder(on_line)
  local pending = ''
  return function(chunk)
    pending = pending .. (chunk or '')
    local lines = vim.split(pending, '\n', { plain = true })
    pending = chunk and table.remove(lines) or ''
    for _, line in ipairs(lines) do
      if line ~= '' then
        on_line(line)
      end
    end
  end
end

---@param line string
---@return table|nil
local function decode_line(line)
  local ok, event = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  return ok and type(event) == 'table' and event or nil
end

---@param event table
---@return claude_fill.Step[]
local function steps_of(event)
  local steps = {}
  local content = event.type == 'assistant' and event.message and event.message.content or {}
  for _, block in ipairs(content) do
    if block.type == 'tool_use' and block.name ~= ANSWER_TOOL then
      table.insert(steps, { kind = 'step', tool = block.name, input = block.input or {} })
    end
  end
  return steps
end

---@param result claude_fill.ResultEvent
---@param code integer
---@return string
local function failure_message(result, code)
  if result.is_error then
    return result.result or result.subtype or 'claude reported an error'
  end
  return ('claude exited with code %d (%s)'):format(code, result.subtype or 'no subtype')
end

---@param result claude_fill.ResultEvent|nil
---@param code integer
---@param stderr string
---@return claude_fill.Done|claude_fill.Crashed
local function terminal_event(result, code, stderr)
  if not result then
    return {
      kind = 'crashed',
      message = ('claude exited with code %d without a result'):format(code),
      stderr = stderr,
    }
  end
  if result.is_error or code ~= 0 then
    return { kind = 'crashed', message = failure_message(result, code), stderr = stderr }
  end
  local answer = result.structured_output and result.structured_output.answer
  if answer == nil then
    return { kind = 'crashed', message = 'claude returned no structured answer', stderr = stderr }
  end
  return { kind = 'done', answer = answer }
end

---@param emit fun(event: claude_fill.Event)
---@return fun(chunk: string|nil) feed
---@return fun(): claude_fill.ResultEvent|nil result
local function event_stream(emit)
  ---@type claude_fill.ResultEvent|nil
  local result
  local feed = line_feeder(function(line)
    local event = decode_line(line)
    if not event then
      return
    end
    if event.type == 'result' then
      result = event
    end
    for _, step in ipairs(steps_of(event)) do
      emit(step)
    end
  end)
  return feed, function()
    return result
  end
end

---@param spec claude_fill.RunSpec
---@param on_chunk fun(chunk: string|nil)
---@param on_exit fun(code: integer, stderr: string)
---@return vim.SystemObj|nil
---@return string|nil error
local function spawn(spec, on_chunk, on_exit)
  local ok, process = pcall(vim.system, full_argv(spec), {
    cwd = spec.cwd,
    stdin = spec.prompt,
    text = true,
    stdout = function(_, chunk)
      on_chunk(chunk)
    end,
  }, function(completed)
    on_exit(completed.code, completed.stderr or '')
  end)
  if not ok then
    return nil, tostring(process)
  end
  return process
end

---@param spec claude_fill.RunSpec
---@param on_event fun(event: claude_fill.Event)
---@return claude_fill.Run
function M.run(spec, on_event)
  local emit = vim.schedule_wrap(on_event)
  local feed, result = event_stream(emit)
  local process, err = spawn(spec, feed, function(code, stderr)
    emit(terminal_event(result(), code, stderr))
  end)
  if not process then
    emit({ kind = 'crashed', message = err or 'failed to start claude', stderr = '' })
    return { cancel = function() end }
  end
  return {
    cancel = function()
      process:kill('sigterm')
    end,
  }
end

return M
