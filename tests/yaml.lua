-- Unit testing for lua/cwiki/yaml.lua

local common = require("tests.common")
local report_pass = common.report_pass
local report_fail = common.report_fail

local yaml = require("cwiki.yaml")
local TokenType = yaml.TokenType

local util = require("cwiki.util")

local M = {}

-- Check structed of received tokens matches expected; return "pass" or "fail"
-- and a message
local function check_tokens(expected, received)
  local nreceived = #received
  local nexpected = #expected
  if nreceived < nexpected then
    return "fail", string.format("Too few tokens: expected %d, got %d", nexpected, nreceived)
  elseif nreceived > nexpected then
    return "fail", string.format("Too many tokens: expected %d, got %d", nexpected, nreceived)
  end

  for i = 1, nreceived do
    local token = received[i]
    for k, v in pairs(expected[i]) do
      if token[k] ~= v then
        return "fail", string.format("Token %d has the wrong %s: expected %s, got %s", i, k, v, token[k])
      end
    end
  end

  return "pass", ""
end

-- Return test status and message as test result/report
local function test_result(testrun, status, msg)
  if status == "pass" then
    return report_pass(testrun)
  elseif status == "fail" then
    return report_fail(testrun, msg)
  else
    error(string.format("Unknown test status: %s", status))
  end
end

-- Return list of tokens yielded by tokenising the received source, iterating
-- up to a received limit
local function generate_tokens(source, limit)
  local tokens = {}

  local tokeniser = yaml.Tokeniser:new(source)
  for _ = 1, limit do
    table.insert(tokens, tokeniser:next())
  end

  return tokens
end

function M.test_empty_source_tokens(testrun)
  local expected = {
    { text = "", indent = 0, type = TokenType.Indent, line = 1 },
    { type = TokenType.DocumentEnd, text = "" }
  }
  local tokens = generate_tokens("", 2)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_comment_tokens(testrun)
  local expected = {
    { text = "", indent = 0, type = TokenType.Indent, line = 1 },
    { text = "", indent = 0, type = TokenType.Indent, line = 1 },
    { type = TokenType.DocumentEnd, text = "" }
  }
  local tokens = generate_tokens("# comment", 3)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_plain_scalar(testrun)
  local expected = {
    { text = "", indent = 0, type = TokenType.Indent, line = 1 },
    { line = 1, text = "test", type = TokenType.PlainScalar, col = 1 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens("test", 3)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_seq_single_entry_tokens(testrun)
  local expected = {
    { text = "", indent = 0, type = TokenType.Indent, line = 1 },
    { line = 1, text = "-", type = TokenType.Seq, col = 1 },
    { line = 1, text = "entry", type = TokenType.PlainScalar, col = 3 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens("- entry", 4)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_seq_multi_entry_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.Seq, text = "-", line = 1, col = 1 },
    { type = TokenType.PlainScalar, col = 3, text = "one", line = 1 },
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.Seq, text = "-", line = 1, col = 7 },
    { type = TokenType.PlainScalar, col = 9, text = "two", line = 1 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens("- one\n- two", 7)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_unescaped_scalar_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 1 },
    { type = TokenType.UnescapedScalar, col = 2, text = "apple", line = 1 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 7 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens("'apple'", 5)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_empty_unescaped_scalar_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 1 },
    { type = TokenType.UnescapedScalar, col = 2, text = "", line = 1 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 2 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens("''", 5)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_unescaped_scalar_with_quote_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 1 },
    { type = TokenType.UnescapedScalar, col = 2, text = "tom's ball", line = 1 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 13 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens("'tom''s ball'", 5)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_unescaped_scalar_with_one_newline_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 1 },
    { type = TokenType.UnescapedScalar, col = 2, text = "one two", line = 1 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 9 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens("'one\ntwo'", 5)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_unescaped_scalar_with_multi_newline_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 1 },
    { type = TokenType.UnescapedScalar, col = 2, text = "one\ntwo", line = 1 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 10 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens("'one\n\ntwo'", 5)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_escaped_scalar_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 1 },
    { type = TokenType.EscapedScalar, col = 2, text = "apple", line = 1 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 7 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens('"apple"', 5)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_escaped_scalar_with_multi_newline_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 1 },
    { type = TokenType.EscapedScalar, col = 2, text = "one\ntwo", line = 1 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 10 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens('"one\n\ntwo"', 5)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_escaped_scalar_with_one_newline_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 1 },
    { type = TokenType.EscapedScalar, col = 2, text = "one two", line = 1 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 9 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens('"one\ntwo"', 5)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_empty_escaped_scalar_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 1 },
    { type = TokenType.EscapedScalar, col = 2, text = "", line = 1 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 2 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens('""', 5)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_escaped_scalar_with_escaped_newline_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.Indent },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 1 },
    { type = TokenType.EscapedScalar, col = 2, text = "one\ntwo", line = 1 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 10 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens('"one\\ntwo"', 5)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_escaped_scalar_with_bad_escaped_character(testrun)
  local status, err = pcall(function ()
    local tokeniser = yaml.Tokeniser:new '"ba\\d"'
    for _ = 1, 3 do
      tokeniser:next()
    end
  end)
  if not status and err:find("Unrecognised escape character \\d: line 1, col 4") then
    return report_pass(testrun)
  elseif not status then
    return report_fail(testrun, "Error message has been changed")
  else
    return report_fail(testrun, "Tokeniser did not yield an error")
  end
end

function M.test_escaped_scalar_with_last_character_escaped(testrun)
  local status, err = pcall(function ()
    local tokeniser = yaml.Tokeniser:new '"\\'
    for _ = 1, 3 do
      tokeniser:next()
    end
  end)
  if not status and err:find("Lone escape character at end%-of%-file: line 1, col 2") then
    return report_pass(testrun)
  elseif not status then
    return report_fail(testrun, "Error message has been changed")
  else
    return report_fail(testrun, "Tokeniser did not yield an error")
  end
end

function M.test_anchor_name_tokens(testrun)
  local expected = {
    { line = 1, indent = 0, text = "", type = TokenType.Indent },
    { line = 1, type = TokenType.Anchor, text = "&", col = 1 },
    { line = 1, type = TokenType.AnchorName, text = "anchor_name_1", col = 2 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens("&anchor_name_1", 4)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_alias_tokens(testrun)
  local expected = {
    { line = 1, indent = 0, text = "", type = TokenType.Indent },
    { line = 1, type = TokenType.Alias, text = "*", col = 1 },
    { line = 1, type = TokenType.AnchorName, text = "anchor_name_1", col = 2 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens("*anchor_name_1", 4)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_bad_anchor_name_tokens(testrun)
  local expected = {
    { line = 1, indent = 0, text = "", type = TokenType.Indent },
    { line = 1, type = TokenType.Anchor, text = "&", col = 1 },
    { line = 1, type = TokenType.PlainScalar, text = "6anchor", col = 2 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_tokens("&6anchor", 4)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_debug_tokeniser_state_coverage(testrun)
  if not DEBUG then return end
  for state = 1, util.enum_max(yaml.TokeniserState) do
    local tokeniser = yaml.Tokeniser:new ""
    tokeniser.state = state
    local status, _ = pcall(tokeniser.next, tokeniser)
    if not status then
      return report_fail(testrun, string.format("Missing coverage for %s", util.enum_to_string(yaml.TokeniserState, state)))
    end
  end
  return report_pass(testrun)
end

function M.test_tokeniser_state_find_flow_token_start(testrun)
  return common.dummy_test(testrun)
end

function M.test_tokeniser_state_find_flow_plain_scalar_end(testrun)
  return common.dummy_test(testrun)
end

function M.test_tokeniser_state_find_flow_unescaped_scalar_end(testrun)
  return common.dummy_test(testrun)
end

function M.test_tokeniser_state_emit_flow_single_quote(testrun)
  return common.dummy_test(testrun)
end

function M.test_tokeniser_state_find_flow_escaped_scalar_end(testrun)
  return common.dummy_test(testrun)
end

function M.test_tokeniser_state_find_flow_anchor_name(testrun)
  return common.dummy_test(testrun)
end

return M
