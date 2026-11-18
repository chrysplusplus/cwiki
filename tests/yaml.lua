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

-- Return list of tokens yielded by tokenising the received source in block
-- context, iterating up to a received limit
local function generate_block_tokens(source, limit)
  local tokens = {}
  local tokeniser = yaml.Tokeniser:new(source)
  for _ = 1, limit do
    table.insert(tokens, tokeniser:next())
  end
  return tokens
end

-- Return list of tokens yielded by tokenising the received source in flow
-- context, iterating up to a received limit
local function generate_flow_tokens(source, limit)
  local tokens = {}
  local tokeniser = yaml.Tokeniser:new(source)
  tokeniser:use_flow_context()
  for _ = 1, limit do
    table.insert(tokens, tokeniser:next())
  end
  return tokens
end

-- Return list of tokens yielded by tokenising the received source in folded
-- context, iterating up to a received limit
local function generate_folded_tokens(source, limit)
  local tokens = {}
  local tokeniser = yaml.Tokeniser:new(source)
  tokeniser:use_folded_context()
  for _ = 1, limit do
    table.insert(tokens, tokeniser:next())
  end
  return tokens
end

-- Return the document tree at the end of parsing the received source
local function generate_document(source)
  local parser = yaml.Parser:new(source)
  for t in parser.token_stream:iter() do
    parser:parse_token(t)
  end
  return parser.document_tree
end

-- Check the structure of the received document matches that of the expected
-- table; return "pass" or "fail" and a message
local function check_document(expected, received)
  local nodes_to_check = { { "root", expected, received } }
  while #nodes_to_check > 0 do
    local _next = table.remove(nodes_to_check, 1)
    local loc, expect_node, rec_node = _next[1], _next[2], _next[3]
    if rec_node == nil then
      return "fail", string.format("Node at %s is nil", loc)
    end

    for k, v in pairs(expect_node) do
      local node_loc = loc .. "." .. k
      local rec_v = rec_node[k]
      if type(v) == "table" then
        table.insert(nodes_to_check, { node_loc, v, rec_v })
      elseif rec_v ~= v then
        return "fail", string.format("Wrong value at %s: expected %s, got %s", node_loc, tostring(v), tostring(rec_v))
      end
    end
  end

  return "pass", ""
end

function M.test_empty_source_tokens(testrun)
  local expected = {
    { text = "", indent = 0, type = TokenType.BlockIndent, line = 1 },
    { type = TokenType.DocumentEnd, text = "" }
  }
  local tokens = generate_block_tokens("", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_comment_tokens(testrun)
  local expected = {
    { text = "", indent = 0, type = TokenType.BlockIndent, line = 1 },
    { text = "one", type = TokenType.PlainScalar, line = 1, col = 1 },
    { text = "", indent = 0, type = TokenType.BlockIndent, line = 2 },
    { text = "two", type = TokenType.PlainScalar, line = 2, col = 1 },
    { type = TokenType.DocumentEnd, text = "" }
  }
  local tokens = generate_block_tokens("one # comment\ntwo", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_plain_scalar(testrun)
  local expected = {
    { text = "", indent = 0, type = TokenType.BlockIndent, line = 1 },
    { line = 1, text = "test", type = TokenType.PlainScalar, col = 1 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens("test", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_seq_single_entry_tokens(testrun)
  local expected = {
    { text = "", indent = 0, type = TokenType.BlockIndent, line = 1 },
    { line = 1, text = "-", type = TokenType.Seq, col = 1 },
    { line = 1, text = "entry", type = TokenType.PlainScalar, col = 3 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens("- entry", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_seq_multi_entry_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.BlockIndent },
    { type = TokenType.Seq, text = "-", line = 1, col = 1 },
    { type = TokenType.PlainScalar, col = 3, text = "one", line = 1 },
    { text = "", indent = 0, line = 2, type = TokenType.BlockIndent },
    { type = TokenType.Seq, text = "-", line = 2, col = 1 },
    { type = TokenType.PlainScalar, col = 3, text = "two", line = 2 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens("- one\n- two", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_unescaped_scalar_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.BlockIndent },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 1 },
    { type = TokenType.UnescapedScalar, col = 2, text = "apple", line = 1 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 7 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens("'apple'", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_empty_unescaped_scalar_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.BlockIndent },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 1 },
    { type = TokenType.UnescapedScalar, col = 2, text = "", line = 1 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 2 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens("''", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_unescaped_scalar_with_quote_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.BlockIndent },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 1 },
    { type = TokenType.UnescapedScalar, col = 2, text = "tom's ball", line = 1 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 13 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens("'tom''s ball'", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_unescaped_scalar_with_one_newline_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.BlockIndent },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 1 },
    { type = TokenType.UnescapedScalar, col = 2, text = "one two", line = 1 },
    { type = TokenType.SingleQuote, text = "'", line = 2, col = 4 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens("'one\ntwo'", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_unescaped_scalar_with_multi_newline_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.BlockIndent },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 1 },
    { type = TokenType.UnescapedScalar, col = 2, text = "one\ntwo", line = 1 },
    { type = TokenType.SingleQuote, text = "'", line = 3, col = 4 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens("'one\n\ntwo'", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_escaped_scalar_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.BlockIndent },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 1 },
    { type = TokenType.EscapedScalar, col = 2, text = "apple", line = 1 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 7 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens('"apple"', #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_escaped_scalar_with_multi_newline_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.BlockIndent },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 1 },
    { type = TokenType.EscapedScalar, col = 2, text = "one\ntwo", line = 1 },
    { type = TokenType.DoubleQuote, text = "\"", line = 3, col = 4 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens('"one\n\ntwo"', #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_escaped_scalar_with_one_newline_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.BlockIndent },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 1 },
    { type = TokenType.EscapedScalar, col = 2, text = "one two", line = 1 },
    { type = TokenType.DoubleQuote, text = "\"", line = 2, col = 4 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens('"one\ntwo"', #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_empty_escaped_scalar_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.BlockIndent },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 1 },
    { type = TokenType.EscapedScalar, col = 2, text = "", line = 1 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 2 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens('""', #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_escaped_scalar_with_escaped_newline_tokens(testrun)
  local expected = {
    { text = "", indent = 0, line = 1, type = TokenType.BlockIndent },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 1 },
    { type = TokenType.EscapedScalar, col = 2, text = "one\ntwo", line = 1 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 10 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens('"one\\ntwo"', #expected)
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
    { line = 1, indent = 0, text = "", type = TokenType.BlockIndent },
    { line = 1, type = TokenType.Anchor, text = "&", col = 1 },
    { line = 1, type = TokenType.AnchorName, text = "anchor_name_1", col = 2 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens("&anchor_name_1", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_alias_tokens(testrun)
  local expected = {
    { line = 1, indent = 0, text = "", type = TokenType.BlockIndent },
    { line = 1, type = TokenType.Alias, text = "*", col = 1 },
    { line = 1, type = TokenType.AnchorName, text = "anchor_name_1", col = 2 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens("*anchor_name_1", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_bad_anchor_name_tokens(testrun)
  local expected = {
    { line = 1, indent = 0, text = "", type = TokenType.BlockIndent },
    { line = 1, type = TokenType.Anchor, text = "&", col = 1 },
    { line = 1, type = TokenType.PlainScalar, text = "6anchor", col = 2 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_block_tokens("&6anchor", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_debug_tokeniser_state_coverage(testrun)
  if not DEBUG then return end
  for state = 1, util.enum_max(yaml.TokeniserState) do
    local tokeniser = yaml.Tokeniser:new ""
    tokeniser.state = state
    local status, err = pcall(tokeniser.next, tokeniser)
    if not status and err:find("Unreachable") then
      return report_fail(testrun, string.format("Missing coverage for %s", util.enum_to_string(yaml.TokeniserState, state)))
    elseif not status then
      return report_fail(testrun, string.format("Error for %s: %s", util.enum_to_string(yaml.TokeniserState, state), err))
    end
  end
  return report_pass(testrun)
end

function M.test_flow_empty_tokens(testrun)
  local expected = {
    { type = DocumentEnd, text = "" }
  }
  local tokens = generate_flow_tokens("", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_flow_whitespace_tokens(testrun)
  local expected = {
    { type = TokenType.PlainScalar, text = "one", line = 1, col = 1 },
    { type = TokenType.PlainScalar, text = "two", line = 3, col = 1 },
    { type = TokenType.PlainScalar, text = "three", line = 4, col = 1 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_flow_tokens("one\n\t\ntwo\nthree", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_flow_comment_tokens(testrun)
  local expected = {
    { type = TokenType.PlainScalar, text = "one", line = 1, col = 1 },
    { type = TokenType.PlainScalar, text = "two", line = 2, col = 1 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_flow_tokens("one # comment\ntwo", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_flow_special_characters_tokens(testrun)
  local expected = {
    { type = TokenType.Folded, text = ">", line = 1, col = 1 },
    { type = TokenType.Seq, text = "-", line = 1, col = 2 },
    { type = TokenType.MapValue, text = ":", line = 1, col = 3 },
    { type = TokenType.SeqBegin, text = "[", line = 1, col = 4 },
    { type = TokenType.SeqEnd, text = "]", line = 1, col = 5 },
    { type = TokenType.MapBegin, text = "{", line = 1, col = 6 },
    { type = TokenType.MapEnd, text = "}", line = 1, col = 7 },
    { type = TokenType.Collect, text = ",", line = 1, col = 8 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_flow_tokens(">-:[]{},", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_flow_plain_scalar_tokens(testrun)
  local expected = {
    { type = TokenType.PlainScalar, text = "one", line = 1, col = 1 },
    { type = TokenType.Alias, text = "*", line = 1, col = 4 },
    { type = TokenType.PlainScalar, text = "two", line = 1, col = 6 },
    { type = TokenType.Anchor, text = "&", line = 1, col = 9 },
    { type = TokenType.PlainScalar, text = "three", line = 1, col = 11 },
    { type = TokenType.Collect, text = ",", line = 1, col = 16 },
    { type = TokenType.PlainScalar, text = "four", line = 1, col = 18 },
    { type = TokenType.MapEnd, text = "}", line = 1, col = 22 },
    { type = TokenType.PlainScalar, text = "five", line = 1, col = 24 },
    { type = TokenType.MapBegin, text = "{", line = 1, col = 28 },
    { type = TokenType.PlainScalar, text = "six", line = 1, col = 30 },
    { type = TokenType.SeqEnd, text = "]", line = 1, col = 33 },
    { type = TokenType.PlainScalar, text = "seven", line = 1, col = 35 },
    { type = TokenType.SeqBegin, text = "[", line = 1, col = 40 },
    { type = TokenType.PlainScalar, text = "eight", line = 1, col = 42 },
    { type = TokenType.MapValue, text = ":", line = 1, col = 47 },
    { type = TokenType.PlainScalar, text = "nine", line = 1, col = 49 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 53 },
    { type = TokenType.EscapedScalar, text = "", line = 1, col = 54 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 54 },
    { type = TokenType.PlainScalar, text = "ten", line = 1, col = 56 },
    { type = TokenType.PlainScalar, text = "eleven", line = 2, col = 1 },
    { type = TokenType.PlainScalar, text = "twelve'", line = 3, col = 1 },
    { type = TokenType.PlainScalar, text = "thirteen", line = 4, col = 1 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_flow_tokens("one* two& three, four} five{ six] seven[ eight: nine\"\" ten# comment\neleven\ntwelve'\nthirteen", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_flow_unescaped_scalar_tokens(testrun)
  local expected = {
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 1 },
    { type = TokenType.UnescapedScalar, text = "one", line = 1, col = 2 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 5 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 7 },
    { type = TokenType.UnescapedScalar, text = "two'", line = 1, col = 8 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 13 },
    { type = TokenType.SingleQuote, text = "'", line = 1, col = 15 },
    { type = TokenType.UnescapedScalar, text = "three next word", line = 1, col = 16 },
    { type = TokenType.SingleQuote, text = "'", line = 2, col = 10 },
    { type = TokenType.SingleQuote, text = "'", line = 2, col = 12 },
    { type = TokenType.UnescapedScalar, text = "four\nnext line", line = 2, col = 13 },
    { type = TokenType.SingleQuote, text = "'", line = 4, col = 10 },
    { type = TokenType.SingleQuote, text = "'", line = 4, col = 12 },
    { type = TokenType.UnescapedScalar, text = "five", line = 4, col = 13 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_flow_tokens("'one' 'two''' 'three\nnext word' 'four\n\nnext line' 'five", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_tokeniser_state_find_flow_escaped_scalar_end(testrun)
  local expected = {
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 1 },
    { type = TokenType.EscapedScalar, text = "one", line = 1, col = 2 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 5 },
    { type = TokenType.DoubleQuote, text = "\"", line = 1, col = 7 },
    { type = TokenType.EscapedScalar, text = "two next word", line = 1, col = 8 },
    { type = TokenType.DoubleQuote, text = "\"", line = 2, col = 10 },
    { type = TokenType.DoubleQuote, text = "\"", line = 2, col = 12 },
    { type = TokenType.EscapedScalar, text = "three\nnext line", line = 2, col = 13 },
    { type = TokenType.DoubleQuote, text = "\"", line = 4, col = 10 },
    { type = TokenType.DoubleQuote, text = "\"", line = 4, col = 12 },
    { type = TokenType.EscapedScalar, text = "four", line = 4, col = 13 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_flow_tokens('"one" "two\nnext word" "three\n\nnext line" "four', #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_flow_anchor_name_tokens(testrun)
  local expected = {
    { type = TokenType.Anchor, text = "&", line = 1, col = 1 },
    { type = TokenType.AnchorName, text = "anchor", line = 1, col = 2 },
    { type = TokenType.Alias, text = "*", line = 1, col = 9 },
    { type = TokenType.AnchorName, text = "anchor", line = 1, col = 10 },
    { type = TokenType.PlainScalar, text = "two", line = 1, col = 17 },
    { type = TokenType.DocumentEnd, text = "" },
  }
  local tokens = generate_flow_tokens("&anchor *anchor two", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_folded_scalar_tokens(testrun)
  local expected = {
    { type = TokenType.FoldIndent,  indent = 2,                              line = 1 },
    { type = TokenType.FoldLine,    text = "line one.",                      line = 1,  col = 3 },
    { type = TokenType.FoldIndent,  indent = 2,                              line = 2 },
    { type = TokenType.FoldLine,    text = "still line one.",                line = 2,  col = 3 },
    { type = TokenType.FoldIndent,  indent = 0,                              line = 3 },
    { type = TokenType.FoldNewline },
    { type = TokenType.FoldIndent,  indent = 2,                              line = 4 },
    { type = TokenType.FoldLine,    text = "line two.",                      line = 4,  col = 3 },
    { type = TokenType.FoldIndent,  indent = 4,                              line = 5 },
    { type = TokenType.FoldLine,    text = "still line two, despite indent", line = 5,  col = 5 },
    { type = TokenType.FoldIndent,  indent = 0,                              line = 6 },
    { type = TokenType.FoldNewline },
    { type = TokenType.FoldIndent,  indent = 4,                              line = 7 },
    { type = TokenType.FoldLine,    text = "line three, indented",           line = 7,  col = 5 },
    { type = TokenType.FoldIndent,  indent = 4,                              line = 8 },
    { type = TokenType.FoldLine,    text = "line four, indented",            line = 8,  col = 5 },
    { type = TokenType.FoldIndent,  indent = 0,                              line = 9 },
    { type = TokenType.FoldNewline },
    { type = TokenType.FoldIndent,  indent = 0,                              line = 10 },
    { type = TokenType.FoldLine,    text = "next scalar",                    line = 10, col = 1 },
    { type = TokenType.DocumentEnd },
  }
  local tokens = generate_folded_tokens("  line one.\n  still line one.\n\n  line two.\n    still line two, despite indent\n\n    line three, indented\n    line four, indented\n\nnext scalar", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_folded_scalar_empty_newline_ending_tokens(testrun)
  local expected = {
    { type = TokenType.FoldIndent,  indent = 2,        line = 1 },
    { type = TokenType.FoldLine,    text = "line one", line = 1, col = 3 },
    { type = TokenType.FoldIndent,  indent = 0,        line = 2 },
    { type = TokenType.FoldNewline },
  }
  local tokens = generate_folded_tokens("  line one\n", #expected)
  local status, msg = check_tokens(expected, tokens)
  return test_result(testrun, status, msg)
end

function M.test_single_plain_scalar_document(testrun)
  local source = "yaml"
  local expected = {
    type = yaml.ParserNodeType.Root,
    content = {
      type = yaml.ParserNodeType.Scalar,
      content = "yaml",
      indent = 0,
    },
  }

  local document = generate_document(source)
  local status, msg = check_document(expected, document)
  return test_result(testrun, status, msg)
end

function M.test_simple_sequence_document(testrun)
  local source = [[
- item 1
- item 2]]
  local expected = {
    type = yaml.ParserNodeType.Root,
    content = {
      type = yaml.ParserNodeType.Sequence,
      indent = 0,
      content = {
        {
          type = yaml.ParserNodeType.Scalar,
          content = "item 1",
          indent = 2,
        },
        {
          type = yaml.ParserNodeType.Scalar,
          content = "item 2",
          indent = 2,
        },
      },
    },
  }

  local document = generate_document(source)
  local status, msg = check_document(expected, document)
  return test_result(testrun, status, msg)
end

return M
