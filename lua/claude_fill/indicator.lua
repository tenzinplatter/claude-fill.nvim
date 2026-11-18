local target_mod = require('claude_fill.target')

---@class claude_fill.Timer
---@field start fun(self: claude_fill.Timer, timeout: integer, repeat_ms: integer, callback: fun())
---@field stop fun(self: claude_fill.Timer)
---@field close fun(self: claude_fill.Timer)

---@alias claude_fill.ProgressStatus 'running'|'success'|'failed'|'cancel'

---@class claude_fill.Indicator
---@field target claude_fill.Target
---@field title string
---@field progress_id integer
---@field mark integer
---@field frame integer
---@field text string
---@field state { kind: 'spinning', timer: claude_fill.Timer }|{ kind: 'stopped' }

local M = {}

local NS = vim.api.nvim_create_namespace('claude_fill.indicator')
local FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local FRAME_MS = 100
M.PROGRESS_SOURCE = 'claude-fill'

vim.api.nvim_set_hl(0, 'ClaudeFillTarget', { link = 'Visual', default = true })
vim.api.nvim_set_hl(0, 'ClaudeFillStatus', { link = 'Comment', default = true })

---@type table<string, fun(input: table<string, any>): string>
local DESCRIBERS = {
  Read = function(input)
    return 'Reading ' .. vim.fn.fnamemodify(tostring(input.file_path), ':~:.')
  end,
  Grep = function(input)
    return 'Searching ' .. tostring(input.pattern)
  end,
  Glob = function(input)
    return 'Finding ' .. tostring(input.pattern)
  end,
  WebFetch = function(input)
    return 'Fetching ' .. tostring(input.url)
  end,
  WebSearch = function(input)
    return 'Searching the web for ' .. tostring(input.query)
  end,
  Bash = function(input)
    return 'Running ' .. tostring(input.description or input.command)
  end,
}

---@param step claude_fill.Step
---@return string
function M.describe(step)
  local describer = DESCRIBERS[step.tool]
  return describer and describer(step.input) or step.tool
end

---@param title string
---@param text string
---@param status claude_fill.ProgressStatus
---@param progress_id? integer
---@return integer
local function echo_progress(title, text, status, progress_id)
  local id = vim.api.nvim_echo({ { text } }, true, {
    id = progress_id,
    kind = 'progress',
    source = M.PROGRESS_SOURCE,
    title = title,
    status = status,
  })
  return tonumber(id) --[[@as integer]]
end

---@param indicator claude_fill.Indicator
local function render(indicator)
  local buf = indicator.target.buf
  if indicator.state.kind == 'stopped' or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local first, stop = target_mod.span(indicator.target)
  if not first or not stop then
    return
  end
  local last_row = math.max(vim.api.nvim_buf_line_count(buf) - 1, 0)
  local row = math.min(first, last_row)
  indicator.frame = indicator.frame % #FRAMES + 1
  vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
    id = indicator.mark,
    end_row = stop,
    end_col = 0,
    hl_group = 'ClaudeFillTarget',
    hl_eol = true,
    virt_text = { { FRAMES[indicator.frame] .. ' ' .. indicator.text, 'ClaudeFillStatus' } },
    virt_text_pos = 'eol',
    strict = false,
  })
end

---@param target claude_fill.Target
---@param title string
---@return claude_fill.Indicator
function M.start(target, title)
  local timer = assert(vim.uv.new_timer()) --[[@as claude_fill.Timer]]
  ---@type claude_fill.Indicator
  local indicator = {
    target = target,
    title = title,
    progress_id = echo_progress(title, 'Working', 'running'),
    mark = vim.api.nvim_buf_set_extmark(target.buf, NS, 0, 0, { strict = false }),
    frame = 0,
    text = 'Working',
    state = { kind = 'spinning', timer = timer },
  }
  timer:start(
    0,
    FRAME_MS,
    vim.schedule_wrap(function()
      render(indicator)
    end)
  )
  return indicator
end

---@param indicator claude_fill.Indicator
---@param step claude_fill.Step
function M.show_step(indicator, step)
  indicator.text = M.describe(step)
  echo_progress(indicator.title, indicator.text, 'running', indicator.progress_id)
end

---@param indicator claude_fill.Indicator
---@param status claude_fill.ProgressStatus
function M.stop(indicator, status)
  local state = indicator.state
  if state.kind == 'stopped' then
    return
  end
  indicator.state = { kind = 'stopped' }
  echo_progress(indicator.title, status, status, indicator.progress_id)
  state.timer:stop()
  state.timer:close()
  if vim.api.nvim_buf_is_valid(indicator.target.buf) then
    vim.api.nvim_buf_del_extmark(indicator.target.buf, NS, indicator.mark)
  end
end

return M
