---@class claude_fill.Target
---@field buf integer
---@field mark integer

local M = {}

local NS = vim.api.nvim_create_namespace('claude_fill.target')

---@param buf integer
---@param first integer 0-based first row
---@param stop integer 0-based exclusive end row
---@return claude_fill.Target
local function create(buf, first, stop)
  local mark = vim.api.nvim_buf_set_extmark(buf, NS, first, 0, {
    end_row = stop,
    end_col = 0,
    strict = false,
  })
  return { buf = buf, mark = mark }
end

---@param buf integer
---@param line1 integer 1-based first line
---@param line2 integer 1-based last line
---@return claude_fill.Target
function M.from_range(buf, line1, line2)
  return create(buf, line1 - 1, line2)
end

---@param buf integer
---@param line integer 1-based cursor line; the Target is the empty region below it
---@return claude_fill.Target
function M.at_cursor(buf, line)
  return create(buf, line, line)
end

---@param target claude_fill.Target
---@return integer first 0-based first row
---@return integer stop 0-based exclusive end row
function M.span(target)
  local details =
    vim.api.nvim_buf_get_extmark_by_id(target.buf, NS, target.mark, { details = true })
  return details[1], details[3].end_row
end

---@param target claude_fill.Target
---@return string[]
function M.lines(target)
  local first, stop = M.span(target)
  return vim.api.nvim_buf_get_lines(target.buf, first, stop, false)
end

---@param target claude_fill.Target
---@return string[] before
---@return string[] after
function M.surroundings(target)
  local first, stop = M.span(target)
  return vim.api.nvim_buf_get_lines(target.buf, 0, first, false),
    vim.api.nvim_buf_get_lines(target.buf, stop, -1, false)
end

---@param target claude_fill.Target
---@param lines string[]
function M.replace(target, lines)
  local first, stop = M.span(target)
  vim.api.nvim_buf_set_lines(target.buf, first, stop, false, lines)
end

---@param a claude_fill.Target
---@param b claude_fill.Target
---@return boolean
function M.overlaps(a, b)
  if a.buf ~= b.buf then
    return false
  end
  local a_first, a_stop = M.span(a)
  local b_first, b_stop = M.span(b)
  local a_end, b_end = math.max(a_stop, a_first + 1), math.max(b_stop, b_first + 1)
  return a_first < b_end and b_first < a_end
end

---@param target claude_fill.Target
function M.clear(target)
  vim.api.nvim_buf_del_extmark(target.buf, NS, target.mark)
end

return M
