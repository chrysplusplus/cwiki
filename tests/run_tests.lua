-- Script to run test
--
-- Note: run from repo root
package.path = package.path .. ";./lua/?.lua;./lua/?/init.lua;./tests/?.lua;./tests/?/init.lua"

USAGE = [[
%s [options] [test]
Run the tests!

If specified, test is the fully-qualified name of the test to run. For failing tests, this might display more information about why the test isn't passing, such as printing tracebacks at points of failure.

Available options:
    -h, --help     : Print this message
        --trace    : Turn on line tracing (only for single tests)
        --no-debug : Don't run debug tests
        --no-dummy : Don't run dummy tests

]]

function usage(exit_code)
  io.stdout:write(string.format(USAGE, arg[0]))
  os.exit(exit_code)
end

function info(...)
  io.stdout:write(...)
end

DEBUG = true
DUMMY = true
SINGLE_TEST = nil
TRACE = false
for i, a in ipairs(arg) do
  if a == "-h" or a == "--help" then
    usage()
  elseif a == "--no-debug" then
    DEBUG = false
  elseif a == "--no-dummy" then
    DUMMY = false
  elseif a == "--trace" then
    TRACE = true
  elseif a:find("^--?") then
    io.stdout:write(string.format("Unknown option: '%s'", a))
    usage(1)
  elseif SINGLE_TEST then
    io.stdout:write("Error: more than one test specified")
  else
    SINGLE_TEST = a
  end
end

if TRACE and not SINGLE_TEST then
  io.stdout:write("--trace can only be set for single tests\n")
  os.exit(1)
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

NO_FILTER = "."
FAIL_FILTER = "^fail$"

function print_report(run, opts)
  local opts = opts or {}
  local filter = opts.filter or FAIL_FILTER
  info("\nFinished!\n")
  info(string.format("%d test(s) were run: %d PASSED, %d FAILED\n", run.total, run.passes, run.failures))

  for _, test_result in ipairs(run.tests) do
    if test_result.status:find(filter) then
      info(string.format("%s: status '%s'\n\t%s\n", test_result.name, test_result.status, test_result.message))
    end
  end
end

function enable_trace()
  debug.sethook(function (_, line)
    print(string.format("%s:%s", debug.getinfo(2).short_src, line))
  end, "l")
end

function disable_trace()
  debug.sethook()
end

function run_all_tests()
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

  print_report(run)
end

function run_single_test()
  local testfn = all_tests[SINGLE_TEST]
  if not testfn then
    io.stdout:write(string.format("Unknown test: '%s'\n\n", SINGLE_TEST))
    os.exit(1)
  end

  info(string.format("Running test %s:\n", SINGLE_TEST))

  local run = common.new_testrun()
  common.start_test(run, SINGLE_TEST)

  if TRACE then enable_trace() end
  local status, err = pcall(testfn, run)
  if TRACE then disable_trace() end

  if not status then
    common.report_fail(run, err)
  end
  common.end_test(run)
  print_report(run, { filter = NO_FILTER })
end

if SINGLE_TEST then
  run_single_test()
else
  run_all_tests()
end

