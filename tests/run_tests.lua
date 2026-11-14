-- Script to run test
--
-- Note: run from repo root
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua;./tests/?.lua;./tests/?/init.lua"

USAGE = [[
%s [options]
Run the tests!

Available options:
    -h, --help     : Print this message

]]

function usage(exit_code)
  io.stdout:write(string.format(USAGE, arg[0]))
  os.exit(exit_code)
end

function info(...)
  io.stdout:write(...)
end

DEBUG = true
for i, a in ipairs(arg) do
  if a == "-h" or a == "--help" then
    usage()
  else
    io.stdout:write(string.format("Unknown option: '%s'", a))
    usage(1)
  end
end

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
      table.insert(all_tests, test_name)
    end
  end
end

table.sort(all_tests)

info("Running tests:\n")

run = common.new_testrun()
run.hooks.on_pass = function (...) info(".") end
run.hooks.on_fail = function (...) info("!") end

for _, testname in ipairs(all_tests) do
  local testfn = all_tests[testname]
  assert(testfn)
  common.start_test(run, testname)
  local status, err = pcall(testfn, run)
  if not status then
    common.report_fail(run, err)
  end
  common.end_test(run)
end

info("\nFinished!\n")
info(string.format("%d test(s) were run: %d PASSED, %d FAILED\n", run.total, run.passes, run.failures))

for _, test_result in ipairs(run.tests) do
  if test_result.status ~= "pass" then
    info(string.format("%s: status '%s'\n\t%s\n", test_result.name, test_result.status, test_result.message))
  end
end

