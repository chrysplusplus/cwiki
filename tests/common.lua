-- Test framework

local M = {}

function M.new_testrun()
  return {
    passes = 0,
    failures = 0,
    total = 0,
    tests = {},
  }
end

local function add_test(testrun, status, msg)
  assert(testrun.current_name)
  testrun.total = testrun.total + 1
  table.insert(testrun.tests, { status = status, message = msg, name = testrun.current_name })
end

function M.report_pass(testrun, msg)
  local msg = msg or ""
  add_test(testrun, "pass", msg)
  testrun.passes = testrun.passes + 1
end

function M.report_fail(testrun, msg)
  local msg = msg or ""
  add_test(testrun, "fail", msg)
  testrun.failures = testrun.failures + 1
end

function M.start_test(testrun, name)
  assert(not testrun.current_name)
  testrun.current_name = name
end

function M.end_test(testrun)
  testrun.current_name = nil
end

return M
