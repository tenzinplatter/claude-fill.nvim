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
    end_right_gravity = first == stop,
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
---@return integer|nil first 0-based first row
---@return integer|nil stop 0-based exclusive end row
function M.span(target)
  if not vim.api.nvim_buf_is_valid(target.buf) then
    return nil, nil
  end
  local details =
    vim.api.nvim_buf_get_extmark_by_id(target.buf, NS, target.mark, { details = true })
  if #details == 0 then
    return nil, nil
  end
  return details[1], math.max(details[1], details[3].end_row)
end

---@param target claude_fill.Target
---@return integer first
---@return integer stop
local function must_span(target)
  local first, stop = M.span(target)
  assert(first and stop, 'target no longer exists')
  return first, stop
end

---@param target claude_fill.Target
---@return string[]
function M.lines(target)
  local first, stop = must_span(target)
  return vim.api.nvim_buf_get_lines(target.buf, first, stop, false)
end

---@param target claude_fill.Target
---@return string[] before
---@return string[] after
function M.surroundings(target)
  local first, stop = must_span(target)
  return vim.api.nvim_buf_get_lines(target.buf, 0, first, false),
    vim.api.nvim_buf_get_lines(target.buf, stop, -1, false)
end

---@param target claude_fill.Target
---@param lines string[]
function M.replace(target, lines)
  local first, stop = must_span(target)
  vim.api.nvim_buf_set_lines(target.buf, first, stop, false, lines)
end

---@param a claude_fill.Target
---@param b claude_fill.Target
---@return boolean
function M.overlaps(a, b)
  if a.buf ~= b.buf then
    return false
  end
  local a_first, a_stop = must_span(a)
  local b_first, b_stop = must_span(b)
  local a_end, b_end = math.max(a_stop, a_first + 1), math.max(b_stop, b_first + 1)
  return a_first < b_end and b_first < a_end
end

---@class claude_fill.TargetSnapshot
---@field target claude_fill.Target
---@field lines string[]

---@param target claude_fill.Target
---@return claude_fill.TargetSnapshot
function M.snapshot(target)
  return { target = target, lines = M.lines(target) }
end

---@param snapshot claude_fill.TargetSnapshot
---@return claude_fill.Target
function M.of(snapshot)
  return snapshot.target
end

---@param snapshot claude_fill.TargetSnapshot
---@return boolean
function M.edited_since(snapshot)
  local first, stop = M.span(snapshot.target)
  if not (first and stop) then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(snapshot.target.buf, first, stop, false)
  return not vim.deep_equal(lines, snapshot.lines)
end

---@param target claude_fill.Target
---@param row integer 0-based
---@return boolean
function M.contains_row(target, row)
  local first, stop = M.span(target)
  if not first or not stop then
    return false
  end
  return row >= first and row < math.max(stop, first + 1)
end

---@param target claude_fill.Target
---@param row integer 0-based
---@return boolean
function M.is_insertion_above(target, row)
  local first, stop = M.span(target)
  return first ~= nil and first == stop and row == first - 1
end

---@param target claude_fill.Target
function M.clear(target)
  if vim.api.nvim_buf_is_valid(target.buf) then
    vim.api.nvim_buf_del_extmark(target.buf, NS, target.mark)
  end
end

---@class claude_fill.TargetContext
---@field path string
---@field filetype string
---@field before string[]
---@field target string[]
---@field after string[]

---@param snapshot claude_fill.TargetSnapshot
---@param project_root string
---@return claude_fill.TargetContext
function M.context(snapshot, project_root)
  local target = snapshot.target
  local absolute = vim.api.nvim_buf_get_name(target.buf)
  local before, after = M.surroundings(target)
  return {
    path = vim.fs.relpath(project_root, absolute) or absolute,
    filetype = vim.bo[target.buf].filetype,
    before = before,
    target = snapshot.lines,
    after = after,
  }
end

return M
