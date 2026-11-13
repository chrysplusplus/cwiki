-- Script to run test
--
-- Note: run from repo root
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua;./tests/?.lua;./tests/?/init.lua"

DEBUG = true

common = require("common")
yaml_tests = require("yaml")

test_modinfos = {
  { name = "yaml", module = yaml_tests },
}

all_tests = {}
for _, module_info in ipairs(test_modinfos) do
  for k, v in pairs(module_info.module) do
    if k:find("^test_") then
      local test_name = string.format("%s.%s", module_info.name, k)
      all_tests[test_name] = v
    end
  end
end

io.stdout:write("Running tests:\n")

run = common.new_testrun()
for name, fn in pairs(all_tests) do
  common.start_test(run, name)
  local status, err = pcall(fn, run)
  io.stdout:write(".")
  if not status then
    common.report_fail(run, err)
  end
  common.end_test(run)
end

io.stdout:write("\nFinished!\n")
io.stdout:write(string.format("%d test(s) were run: %d PASSED, %d FAILED\n", run.total, run.passes, run.failures))

for _, test_result in ipairs(run.tests) do
  if test_result.status ~= "pass" then
    io.stdout:write(string.format("%s: status '%s'\n\t%s\n", test_result.name, test_result.status, test_result.message))
  end
end

