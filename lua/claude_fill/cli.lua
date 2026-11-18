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

---@class claude_fill.RunSpec
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
  local argv = { 'claude', '-p', spec.prompt, '--model', spec.model }
  vim.list_extend(argv, { '--tools', table.concat(spec.tools, ',') })
  vim.list_extend(argv, { '--allowedTools' })
  vim.list_extend(argv, spec.allowed_tools)
  vim.list_extend(argv, { '--permission-mode', 'dontAsk' })
  vim.list_extend(argv, { '--settings', vim.json.encode({ disableAllHooks = true }) })
  vim.list_extend(argv, { '--strict-mcp-config' })
  vim.list_extend(argv, { '--json-schema', vim.json.encode(spec.schema) })
  vim.list_extend(argv, { '--output-format', 'stream-json', '--verbose' })
  vim.list_extend(argv, { '--no-session-persistence' })
  return argv
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
    local message = result.result or result.subtype or ('claude exited with code %d'):format(code)
    return { kind = 'crashed', message = message, stderr = stderr }
  end
  local answer = result.structured_output and result.structured_output.answer
  if answer == nil then
    return { kind = 'crashed', message = 'claude returned no structured answer', stderr = stderr }
  end
  return { kind = 'done', answer = answer }
end

---@param spec claude_fill.RunSpec
---@param on_event fun(event: claude_fill.Event)
---@return claude_fill.Run
function M.run(spec, on_event)
  local emit = vim.schedule_wrap(on_event)
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

  local ok, process = pcall(vim.system, M.argv(spec), {
    cwd = spec.cwd,
    stdin = '',
    text = true,
    stdout = function(_, chunk)
      feed(chunk)
    end,
  }, function(completed)
    emit(terminal_event(result, completed.code, completed.stderr or ''))
  end)

  if not ok then
    emit({ kind = 'crashed', message = tostring(process), stderr = '' })
    return { cancel = function() end }
  end
  return {
    cancel = function()
      process:kill('sigterm')
    end,
  }
end

return M
