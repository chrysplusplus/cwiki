-- Implementation for character and generic streams
-- author: chrysplusplus

local M = {}

local Stream = {}
M.Stream = Stream

-- Create a new Stream object from the received table
--
-- The table MUST have the following keys:
--  next_fn: function(invariance, control) -> control, yielded_value
--  invar: the invariance state, typically another stream
--  ctrl: the control variable, typically a counter or accumulator
function Stream:new(o)
  assert(o, "table must be provided")
  assert(o.next_fn, "next_fn must be provided")
  assert(o.invar, "invar must be provided")
  assert(o.ctrl, "ctrl must be provided")
  setmetatable(o, {__index = self})
  return o
end

function Stream:next()
  local ret
  if self.ctrl then
    self.ctrl, ret = self.next_fn(self.invar, self.ctrl)
    if ret then
      return ret
    end
  end
end

function Stream:iter()
  return function (...) return self:next() end, nil, nil
end

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

return M

