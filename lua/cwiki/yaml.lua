-- Lightweight YAML parser, or subset thereof
-- author: chrysplusplus

-- TODO:
-- - Add UTF-8 support

local M = {}

--local stream = require "cwiki.stream" -- too complex ??
local util = require "cwiki.util"
local enum = util.enum
local enum_to_string = util.enum_to_string

-- Peek at the character at index
local function peek(s, i)
  return s:sub(i, i)
end

-- Advance index to the next non-empty line; return the rest of the current
-- line and the new index
local function consume_line(s, idx)
  local b, e = s:find("\n+.", idx)
  if not b then
    return #s + 1, s:sub(idx)
  else
    return e, s:sub(idx, b - 1)
  end
end

-- Advance the index past whitespace; return the new index
local function consume_whitespace(s, idx)
  local i
  i, _ = s:find("[^ \t]", idx)
  return i or #s + 1
end

-- Advance the index past the indentation whitespace; return the new index
local function consume_indent(s, idx)
  local i
  i, _ = s:find("[^ ]", idx)
  return i or #s + 1
end

-- Advance the index just past the next word-boundary; return the new index and
-- matched word
local function consume_word(s, idx)
  local b, e = s:find("[%w_]+", idx)
  if not b then
    return #s + 1, ""
  else
    return e + 1, s:sub(b, e)
  end
end

-- Trim trailing spaces from string
local function trim_trailing(s)
  local i, _ = s:find("%s+$")
  if not i then return s end
  return s:sub(1, i - 1)
end

-- Table of recognised YAML indicators; anything commented out is recognised in
-- YAML but not by this parser
local INDICATORS = {
  EOF = -1,
  EOL = "\n",
  COMMENT = "#",
  SINGLE_QUOTE = "'",
  DOUBLE_QUOTE = '"',
  -- LITERAL = "|",
  FOLDED = ">",
  -- CHOMP_STRIP = "-",
  -- CHOMP_KEEP = "+",
  SEQ = "-",
  -- MAP_KEY = "?",
  MAP_VALUE = ":",
  SEQ_BEGIN = "[",
  SEQ_END = "]",
  MAP_BEGIN = "{",
  MAP_END = "}",
  COLLECT = ",",
  ANCHOR = "&",
  ALIAS = "*",
}

local TokenType = enum{
  "Indent",
  "DocumentEnd",
  "SingleQuote",
  "DoubleQuote",
  "Folded",
  "MapValue",
  "SeqBegin",
  "SeqEnd",
  "MapBegin",
  "MapEnd",
  "Collect",
  "Anchor",
  "Alias",
}

local TokeniserState = enum{
  "Finished",
  "EmitIndent",
  "FindTokenStart",
  "FindUnescapedFlowScalarEnd",
  "FindEscapedFlowScalarEnd",
  "EmitIndentForFoldedScalar",
  "EmitSeqOrFallback",
  "FindTokenStartInFlow",
  "FindPlainScalarEnd"
}

if DEBUG then
  print_tokeniser = function(t)
    print(string.format(
      "{ source = \"...\", state = %s, index = %d, ... }",
      enum_to_string(TokeniserState, t.state),
      t.index
    ))
  end

  print_token = function(t)
    if not t then print(nil); return end
    local keyvals = {}
    for k, v in pairs(t) do
      if k == "type" then
        table.insert(keyvals, string.format("type = %s", enum_to_string(TokenType, v)))
      elseif type(v) == "string" then
        table.insert(keyvals, string.format("%s = \"%s\"", k, v))
      elseif type(v) == "number" then
        table.insert(keyvals, string.format("%s = %d", k, v))
      elseif type(v) == "table" then
        table.insert(keyvals, string.format("%s = { ... }", k))
      end
    end

    print(string.format("{ %s }", table.concat(keyvals, ", ")))
  end
end

-- Tokeniser objects represent a generator that emits a sequence of lexical
-- tokens that represents the received source string
local Tokeniser = {}
function Tokeniser:new(s)
  local ret = {
    source = s,
    state = TokeniserState.EmitIndent,
    index = 1,
    line = { nr = 1, index = 0 },
    fallback_stack = {},
    accumulator = "",
  }
  setmetatable(ret, {__index = self})
  return ret
end

-- Indicate start of a new line, with index pointing to the first character of
-- the new line
function Tokeniser:_line_start_at(index)
  self.line.nr = self.line.nr + 1
  self.line.index = index - 1
end

-- Return the line, col position of the Tokeniser in the source
function Tokeniser:position()
  return self.line.nr, self.index - self.line.index
end

-- Set the Tokeniser state to Finished and return a token with error type and
-- the received message
function Tokeniser:emit_error_token(msg)
  local msg = msg or ""
  local line, col = self:position()
  self.state = TokeniserState.Finished
  return { type = TokenType.Error, text = msg, line = line, col = col }
end

-- Return a new token of type `type` with optional values
--
-- Note: the text key of the returned table is defaulted to an empty string if
-- not provided
function Tokeniser:emit_token(type_, vars)
  assert(type_, "Not a member of TokenType")
  local vars = vars or {}

  if DEBUG and type(vars) ~= "table" then
    print(string.format("vars: %s", vars))
  end

  local ret = { type = type_ }
  for k,v in pairs(vars) do
    ret[k] = v
  end

  ret.text = ret.text or ""
  return ret
end

function Tokeniser:transition_state(next_state)
  assert(next_state, "Not a member of TokeniserState")
  self.state = next_state
end

-- Set the tokeniser state to `next_state`, then return a new token of type
-- `type` with optional values
--
-- Note: the text key of the returned table is defaulted to an empty string if
-- not provided
function Tokeniser:set_emit_type_and_transition_state_and_emit_token(type_, next_state, vars)
  self:transition_state(next_state)
  return self:emit_token(type_, vars)
end

-- Set the tokeniser state to `next_state`, then return a new token of type
-- `type` with optional values
--
-- Note: the text key of the returned table is defaulted to an empty string if
-- not provided
function Tokeniser:transition_state_and_emit_token(next_state, type_, vars)
  self:transition_state(next_state)
  return self:emit_token(type_, vars)
end

-- Create fallback point for backtracking state but not the accumulator
function Tokeniser:create_fallback()
  table.insert(self.fallback_stack, self.state)
end

-- Create fallback point for backtracking state to explicit state
function Tokeniser:create_fallback_to_state(state)
  assert(state)
  table.insert(self.fallback_stack, state)
end

-- Remove last fallback point
function Tokeniser:remove_fallback()
  table.remove(self.fallback_stack)
end

-- Pop fallback pop for backtracking state but not the accumulator
function Tokeniser:fall_back()
  self.state = table.remove(self.fallback_stack)
end

function Tokeniser:next()
  local ch = peek(self.source, self.index)
  if #ch == 0 then
    ch = INDICATORS.EOF
  end

  if self.state == TokeniserState.Finished then
    return nil

  elseif self.state == TokeniserState.EmitIndent then
    local line, _ = self:position()
    local new_index = consume_indent(self.source, self.index)
    local indent = new_index - self.index
    self.index = new_index
    return self:transition_state_and_emit_token(TokeniserState.FindTokenStart, TokenType.Indent, { index =  indent, line = line })

  elseif self.state == TokeniserState.FindTokenStart then
    if ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.Finished)
      return self:emit_token(TokenType.DocumentEnd)

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self:transition_state(TokeniserState.EmitIndent)
      return self:next()

    elseif ch == INDICATORS.COMMENT then
      self.index = consume_line(self.source, self.index)
      self:transition_state(TokeniserState.EmitIndent)
      return self:next()

    elseif ch == INDICATORS.SINGLE_QUOTE then
      local line, col = self:position()
      self.index = self.index + 1
      self:transition_state(TokeniserState.FindUnescapedFlowScalarEnd)
      return self:emit_token(TokenType.SingleQuote, { text = INDICATORS.SINGLE_QUOTE, line = line, col = col })

    elseif ch == INDICATORS.DOUBLE_QUOTE then
      local line, col = self:position()
      self.index = self.index + 1
      self:transition_state(TokeniserState.FindEscapedFlowScalarEnd)
      return self:emit_token(TokenType.DoubleQuote, { text = INDICATORS.DOUBLE_QUOTE, line = line, col = col })

    elseif ch == INDICATORS.FOLDED then
      local line, col = self:position()
      self.index = self.index + 1
      self:transition_state(TokeniserState.EmitIndentForFoldedScalar)
      return self:emit_token(TokenType.Folded, { text = INDICATORS.FOLDED, line = line, col = col })

    elseif ch == INDICATORS.SEQ then
      local line, col = self:position()
      self.index = self.index + 1
      self:transition_state(TokeniserState.EmitSeqOrFallback)
      return self:next()

    elseif ch == INDICATORS.MAP_VALUE then
      local line, col = self:position()
      self.index = self.index + 1
      return self:emit_token(TokenType.MapValue, { text = INDICATORS.MAP_VALUE, line = line, col = col })

    elseif ch == INDICATORS.SEQ_BEGIN then
      local line, col = self:position()
      self.index = self.index + 1
      self:transition_state(TokeniserState.FindTokenStartInFlow)
      return self:emit_token(TokenType.SeqBegin, { text = INDICATORS.SEQ_BEGIN, line = line, col = col })

    elseif ch == INDICATORS.SEQ_END then
      local line, col = self:position()
      self.index = self.index + 1
      return self:emit_token(TokenType.SeqEnd, { text = INDICATORS.SEQ_END, line = line, col = col })

    elseif ch == INDICATORS.MAP_BEGIN then
      local line, col = self.position()
      self.index = self.index + 1
      self:transition_state(TokeniserState.FindTokenStartInFlow)
      return self:emit_token(TokenType.MapBegin, { text = INDICATORS.MAP_BEGIN, line = line, col = col })

    elseif ch == INDICATORS.MAP_END then
      local line, col = self:position()
      self.index = self.index + 1
      return self:emit_token(TokenType.MapEnd, { text = INDICATORS.MAP_END, line = line, col = col })

    elseif ch == INDICATORS.COLLECT then
      local line, col = self:position()
      self.index = self.index + 1
      return self:emit_token(TokenType.Collect, { text = INDICATORS.COLLECT, line = line, col = col })

    elseif ch == INDICATORS.ANCHOR then
      local line, col = self:position()
      self.index = self.index + 1
      return self:emit_token(TokenType.Anchor, { text = INDICATORS.ANCHOR, line = line, col = col })

    elseif ch == INDICATORS.ALIAS then
      local line, col = self:position()
      self.index = self.index + 1
      return self:emit_token(TokenType.Alias, { text = INDICATORS.ALIAS, line = line, col = col })

    elseif ch == " " or ch == "\t" then
      self.index = self.index + 1
      return self:next()

    else
      self.accumulator = ch
      self.index = self.index + 1
      self:transition_state(TokeniserState.FindPlainScalarEnd)
      return self:next()
    end

    if DEBUG then assert(false, "Unreachable") end

  else
    assert(false, "Unreachable")
  end
end

M.Tokeniser = Tokeniser
M.TokenType = TokenType
return M
