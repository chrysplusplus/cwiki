-- Utility features to extend the language
-- author: chrysplusplus

local M = {}

-- Create an enum-like table, whose keys are the elements of the received array
function M.enum(t)
  local ret = {}
  for i,v in ipairs(t) do
    ret[v] = i
  end
  return ret
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

