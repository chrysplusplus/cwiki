-- Unit testing for lua/cwiki/yaml.lua

local common = require("tests.common")
local report_pass = common.report_pass
local report_fail = common.report_fail

local yaml = require("cwiki.yaml")

local M = {}

function M.test_seq_simple(testrun)
  local tokens = {}

  local tokeniser = yaml.Tokeniser:new("- test")
  for i = 1, 4 do
    table.insert(tokens, tokeniser:next())
  end

  local test_values = {
    { type = yaml.TokenType.Indent, indent = 0 },
    { type = yaml.TokenType.SeqIndicator },
    { type = yaml.TokenType.SeqEntry, text = "test" },
    { type = yaml.TokenType.DocumentEnd }
  }

  local ntokens = #tokens
  local ntest_values = #test_values
  if ntokens < ntest_values then
    return report_fail(testrun, string.format("Too few tokens: expected %d, got %d", ntest_values, ntokens))
  elseif ntokens > ntest_values then
    return report_fail(testrun, string.format("Too many tokens: expected %d, got %d", ntest_values, ntokens))
  end

  for i = 1, ntokens do
    local token = tokens[i]
    for k, v in pairs(test_values[i]) do
      if token[k] ~= v then
        return report_fail(testrun, string.format("Token %d has the wrong %s: expected %s, got %s", i, k, v, token[k]))
      end
    end
  end

  return report_pass(testrun)
end

return M
