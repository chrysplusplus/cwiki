-- Test framework

local M = {}

function M.new_testrun()
  return {
    passes = 0,
    failures = 0,
    total = 0,
    tests = {},
    hooks = {
      on_pass = nil, -- function (testrun, msg) | nil
      on_fail = nil, -- function (testrun, msg) | nil
    }
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
  if testrun.hooks.on_pass then testrun.hooks.on_pass(testrun, msg) end
  testrun.passes = testrun.passes + 1
end

function M.report_fail(testrun, msg)
  local msg = msg or ""
  add_test(testrun, "fail", msg)
  if testrun.hooks.on_fail then testrun.hooks.on_fail(testrun, msg) end
  testrun.failures = testrun.failures + 1
end

function M.start_test(testrun, name)
  assert(not testrun.current_name)
  testrun.current_name = name
end

function M.end_test(testrun)
  testrun.current_name = nil
end

function M.dummy_test(testrun)
  if DEBUG then return M.report_fail(testrun, "Dummy test") end
end

return M
