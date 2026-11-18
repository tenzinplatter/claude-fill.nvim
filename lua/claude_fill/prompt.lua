---@alias claude_fill.Answer
---| { kind: 'filled', replacement: string }
---| { kind: 'declined', reason: string }

---@class claude_fill.FillPrompt
---@field path string
---@field filetype string
---@field before string[]
---@field target string[]
---@field after string[]
---@field instruction string

local M = {}

local TARGET_START = '<<<CLAUDE_FILL_TARGET_START>>>'
local TARGET_END = '<<<CLAUDE_FILL_TARGET_END>>>'

local RULES = table.concat({
  'Write the code that should replace the lines between the two sentinel lines.',
  'The replacement must be exactly the lines for that region, with absolute indentation',
  '(as it should appear in the file), and no markdown fences and no sentinel lines.',
  'An empty region is an insertion point.',
  'If the instruction is ambiguous or impossible, answer with kind "declined" and a reason',
  'instead of a replacement.',
}, ' ')

local PRIMER = table.concat({
  'Explore this project so that later requests to write code in it can be answered quickly.',
  'Read the top-level layout, the build and test configuration, the main modules,',
  'and any contributor docs such as CLAUDE.md or README files, and note the conventions in use.',
  'You will not be asked to write code now; when finished, answer with kind "filled"',
  'and an empty replacement.',
}, ' ')

---@param override string|nil
---@return string
function M.primer(override)
  return override or PRIMER
end

---@param spec claude_fill.FillPrompt
---@return string
function M.fill(spec)
  local buffer = {}
  vim.list_extend(buffer, spec.before)
  table.insert(buffer, TARGET_START)
  vim.list_extend(buffer, spec.target)
  table.insert(buffer, TARGET_END)
  vim.list_extend(buffer, spec.after)

  return table.concat({
    RULES,
    'File: ' .. spec.path,
    'Filetype: ' .. spec.filetype,
    'Current buffer:',
    table.concat(buffer, '\n'),
    'Instruction: ' .. spec.instruction,
  }, '\n\n')
end

---@return table
function M.answer_schema()
  return {
    type = 'object',
    properties = {
      answer = {
        oneOf = {
          {
            type = 'object',
            properties = {
              kind = { const = 'filled' },
              replacement = { type = 'string' },
            },
            required = { 'kind', 'replacement' },
            additionalProperties = false,
          },
          {
            type = 'object',
            properties = {
              kind = { const = 'declined' },
              reason = { type = 'string' },
            },
            required = { 'kind', 'reason' },
            additionalProperties = false,
          },
        },
      },
    },
    required = { 'answer' },
  }
end

---@param raw any
---@return claude_fill.Answer|nil
function M.decode_answer(raw)
  if type(raw) ~= 'table' then
    return nil
  end
  if raw.kind == 'filled' and type(raw.replacement) == 'string' then
    return { kind = 'filled', replacement = raw.replacement }
  end
  if raw.kind == 'declined' and type(raw.reason) == 'string' then
    return { kind = 'declined', reason = raw.reason }
  end
  return nil
end

---@param replacement string
---@return string[]
function M.replacement_lines(replacement)
  local trimmed = replacement:gsub('\n$', '')
  if trimmed == '' then
    return {}
  end
  return vim.split(trimmed, '\n', { plain = true })
end

return M
