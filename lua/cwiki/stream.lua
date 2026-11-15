-- Implementation for character and generic streams
-- author: chrysplusplus

local M = {}


-- Create a new Stream object from the received table
--
-- The table MUST have the following keys:
--  next_fn: function(invariance, control) -> control, yielded_value
--  invar: the invariance state, typically another stream
--  ctrl: the control variable, typically a counter or accumulator
local Stream = {}
function Stream:new(o)
  assert(o, "table must be provided")
  assert(o.next_fn, "next_fn must be provided")
  assert(o.invar, "invar must be provided")
  assert(o.ctrl, "ctrl must be provided")
  setmetatable(o, {__index = self})
  return o
end

-- Create a new Stream object from an `iterator` function that would work with
-- for ... in, called with provided arguments
function Stream:new_from_iter(iter_fn, ...)
  local n, i, c = iter_fn(...)
  return self:new{ next_fn = n, invar = i, ctrl = c }
end

-- Return the next iteration of the stream object
function Stream:next()
  local ret
  if self.ctrl then
    self.ctrl, ret = self.next_fn(self.invar, self.ctrl)
    if ret then
      return ret
    end
  end
end

-- Iterator function for the stream object; compatible with for ... in
function Stream:iter()
  return function (...) return self:next() end, nil, nil
end

-- StackStream objects yield values from an internal stack storage, which the
-- user can push values onto, and yield from an upstream object, if provided,
-- when the stack is empty
local StackStream = {}
function StackStream:new(upstream)
  return setmetatable({
    stack = {},
    upstream = upstream,
  }, {__index = self})
end

-- Return the next value on the stack or from the upstream
function StackStream:next()
  if #self.stack > 0 then
    return table.remove(self.stack)
  elseif self.upstream then
    return self.upstream:next()
  end
end

-- Push value onto the stack
function StackStream:push(value)
  table.insert(self.stack, value)
end

-- Iterator function for a StackStream, for completeness
function StackStream:iter()
  return function (...) return self:next() end, nil, nil
end

-- Create a stream object that streams each individual character in the
-- received string
function M.char_stream(s)
  return Stream:new{
    next_fn = function(s, i)
      i = i + 1
      if i <= #s then
        return i, s:sub(i, i)
      end
    end,
    invar = s,
    ctrl = 0
  }
end

M.Stream      = Stream
M.StackStream = StackStream

return M

