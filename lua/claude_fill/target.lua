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

---@class claude_fill.Position
---@field row integer
---@field col integer

---@alias claude_fill.WatchStatus 'tracking'|'displaced'|'released'

---@class claude_fill.InsertionWatch
---@field package status claude_fill.WatchStatus

---@class claude_fill.RangeSnapshot
---@field package kind 'range'
---@field package target claude_fill.Target
---@field package lines string[]

---@class claude_fill.InsertionSnapshot
---@field package kind 'insertion'
---@field package target claude_fill.Target
---@field package watch claude_fill.InsertionWatch

---@alias claude_fill.TargetSnapshot claude_fill.RangeSnapshot|claude_fill.InsertionSnapshot

---@param a claude_fill.Position
---@param b claude_fill.Position
---@return boolean
local function precedes(a, b)
  return a.row < b.row or (a.row == b.row and a.col < b.col)
end

---@param start_row integer
---@param start_col integer
---@param old_end_row integer
---@param old_end_col integer
---@return claude_fill.Position first
---@return claude_fill.Position stop
local function removed_span(start_row, start_col, old_end_row, old_end_col)
  local stop_col = old_end_row == 0 and start_col + old_end_col or old_end_col
  return { row = start_row, col = start_col }, { row = start_row + old_end_row, col = stop_col }
end

---@param first claude_fill.Position
---@param stop claude_fill.Position
---@param point claude_fill.Position
---@return boolean
local function encloses(first, stop, point)
  return precedes(first, point) and precedes(point, stop)
end

---@param first claude_fill.Position
---@param stop claude_fill.Position
---@param point claude_fill.Position
---@return boolean
local function joins_across(first, stop, point)
  return vim.deep_equal(stop, point) and first.row < point.row and first.col > 0
end

---@param first claude_fill.Position
---@param stop claude_fill.Position
---@param point claude_fill.Position
---@return boolean
local function displaces(first, stop, point)
  return encloses(first, stop, point) or joins_across(first, stop, point)
end

---@param target claude_fill.Target
---@return claude_fill.Position|nil
local function insertion_point(target)
  local first = M.span(target)
  return first and { row = first, col = 0 }
end

---@param watch claude_fill.InsertionWatch
local function displace(watch)
  if watch.status == 'tracking' then
    watch.status = 'displaced'
  end
end

---@param target claude_fill.Target
---@param watch claude_fill.InsertionWatch
---@param first claude_fill.Position
---@param stop claude_fill.Position
local function observe_removal(target, watch, first, stop)
  local point = insertion_point(target)
  if not point or displaces(first, stop, point) then
    displace(watch)
  end
end

---@param target claude_fill.Target
---@return claude_fill.InsertionWatch
local function watch_insertion(target)
  ---@type claude_fill.InsertionWatch
  local watch = { status = 'tracking' }
  local attached = vim.api.nvim_buf_attach(target.buf, false, {
    on_bytes = function(_, _, _, start_row, start_col, _, old_end_row, old_end_col)
      if watch.status == 'tracking' then
        observe_removal(target, watch, removed_span(start_row, start_col, old_end_row, old_end_col))
      end
      return watch.status ~= 'tracking'
    end,
    on_reload = function()
      displace(watch)
    end,
    on_detach = function()
      displace(watch)
    end,
  })
  if not attached then
    watch.status = 'displaced'
  end
  return watch
end

---@param target claude_fill.Target
---@return claude_fill.TargetSnapshot
function M.snapshot(target)
  local first, stop = must_span(target)
  if first == stop then
    return { kind = 'insertion', target = target, watch = watch_insertion(target) }
  end
  return { kind = 'range', target = target, lines = M.lines(target) }
end

---@param snapshot claude_fill.TargetSnapshot
---@return claude_fill.Target
function M.of(snapshot)
  return snapshot.target
end

---@param snapshot claude_fill.TargetSnapshot
---@return string[]
local function snapshot_lines(snapshot)
  if snapshot.kind == 'range' then
    return snapshot.lines
  end
  return {}
end

---@param snapshot claude_fill.RangeSnapshot
---@return boolean
local function range_edited(snapshot)
  return not vim.deep_equal(M.lines(snapshot.target), snapshot.lines)
end

---@param snapshot claude_fill.TargetSnapshot
---@return boolean
function M.edited_since(snapshot)
  if not M.span(snapshot.target) then
    return true
  end
  if snapshot.kind == 'insertion' then
    return snapshot.watch.status ~= 'tracking'
  end
  return range_edited(snapshot)
end

---@param snapshot claude_fill.TargetSnapshot
function M.release(snapshot)
  if snapshot.kind == 'insertion' then
    snapshot.watch.status = 'released'
  end
  M.clear(snapshot.target)
end

---@param a claude_fill.Target
---@param b claude_fill.Target
---@return boolean
function M.adjoins_start(a, b)
  if a.buf ~= b.buf then
    return false
  end
  local a_first, a_stop = must_span(a)
  local b_first, b_stop = must_span(b)
  return (a_first == a_stop) ~= (b_first == b_stop) and a_first == b_first
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
    target = snapshot_lines(snapshot),
    after = after,
  }
end

return M
