-- Utility features to extend the language
-- author: chrysplusplus

local M = {}

-- Debug assert
if DEBUG then
  M.dassert = assert
else
  M.dassert = function (...) return ... end
end

-- Dump a table to a string
function M.dump_table(t)
  if type(t) == "table" then
    local str = "{ "
    for k,v in pairs(t) do
      if type(k) ~= "number" then k = '"'..k..'"' end
      str = str .. '['..k..'] = ' .. M.dump_table(v) .. ','
    end
    return str .. '} '
  else
    return tostring(t)
  end
end

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

return M

