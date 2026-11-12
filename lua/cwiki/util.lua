-- Utility features to extend the language
-- author: chrysplusplus

local M = {}

-- Create an enum-like table, whose keys are the elements of the received array
--
-- Note: sets _val key to received array
function M.enum(t)
  local ret = {}
  for i,v in ipairs(t) do
    ret[v] = i
  end
  ret._val = t
  return ret
end

-- Return readable string of value in enum
function M.enum_to_string(enum, value)
  return enum._val[value]
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

