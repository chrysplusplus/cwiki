-- Utility features to extend the language
-- author: chrysplusplus

local M = {}

-- Create an enum-like table, whose keys are the elements of the received array
--
-- Note: sets _val key to received array; sets _max key to the maximum value
-- for the purposes of iteration
function M.enum(t)
  local ret = {}
  local max = 0
  for i,v in ipairs(t) do
    ret[v] = i
    max = i
  end
  ret._val = t
  ret._max = max
  return ret
end

-- Return readable string of value in enum
function M.enum_to_string(enum, value)
  return enum._val[value]
end

-- Return the maximum value that can be represented by the received enum
function M.enum_max(enum)
  return enum._max
end

function M.contains(tbl, elem)
  for _,v in ipairs(tbl) do
    if elem == v then
      return true
    end
  end
  return false
end

return M

