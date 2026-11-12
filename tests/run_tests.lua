-- Script to run test
--
-- Note: run from repo root
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua;./tests/?.lua;./tests/?/init.lua"

common = require("common")
yaml_tests = require("yaml")

-- hardcoded for now
all_tests = {
  ["yaml.test_seq_simple"] = yaml_tests.test_seq_simple
}

io.stdout:write("Running tests:\n")

run = common.new_testrun()
for name, fn in pairs(all_tests) do
  common.start_test(run, name)
  fn(run)
  io.stdout:write(".")
  common.end_test(run)
end

io.stdout:write("\nFinished!\n")
io.stdout:write(string.format("%d test(s) were run: %d PASSED, %d FAILED\n", run.total, run.passes, run.failures))

for _, test_result in ipairs(run.tests) do
  if test_result.status ~= "pass" then
    io.stdout:write(string.format("%s: status '%s'\n\t%s", test_result.name, test_result.status, test_result.msg))
  end
end

