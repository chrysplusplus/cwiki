-- Lightweight YAML parser, or subset thereof
-- author: chrysplusplus

-- TODO:
-- - Add UTF-8 support

local M = {}

--local stream = require "cwiki.stream" -- too complex ??
local util = require "cwiki.util"
local enum = util.enum
local enum_to_string = util.enum_to_string

-- Table of recognised YAML indicators; anything commented out is recognised in
-- YAML but not by this parser
local INDICATORS = {
  EOF          = -1,
  EOL          = "\n",
  COMMENT      = "#",
  SINGLE_QUOTE = "'",
  DOUBLE_QUOTE = '"',
  -- LITERAL      = "|",
  FOLDED       = ">",
  -- CHOMP_STRIP  = "-",
  -- CHOMP_KEEP   = "+",
  SEQ          = "-",
  -- MAP_KEY      = "?",
  MAP_VALUE    = ":",
  SEQ_BEGIN    = "[",
  SEQ_END      = "]",
  MAP_BEGIN    = "{",
  MAP_END      = "}",
  COLLECT      = ",",
  ANCHOR       = "&",
  ALIAS        = "*",
}

-- Table of escape characters recognised by YAML; again, anything commented out
-- is not recognised by this parser
local ESCAPES = { -- to the country
  -- ["0"] = "",   -- null
  -- ["a"] = "",   -- bell
  -- ["b"] = "",   -- backspace
  ["t"] = "\t", -- tab
  ["n"] = "\n", -- linefeed
  -- ["v"] = "",   -- verticaltab
  -- ["f"] = "",   -- formfeed
  -- ["r"] = "",   -- carriagereturn
  -- ["e"] = "",   -- escape
  -- [" "] = "",   -- space
  ['"'] = "\"", -- doublequote
  -- ["/"] = "",   -- slash
  ["\\"]  = "\\", -- backslash
  -- ["N"] = "",   -- nextline
  -- ["_"] = "",   -- nonbreakingspace
  -- ["L"] = "",   -- lineseparator
  -- ["P"] = "",   -- paragraphseparator
  -- ["x"] = "",   -- unicode8  (may be implemented at some point)
  -- ["u"] = "",   -- unicode16
  -- ["U"] = "",   -- unicode32
}

local ESCAPE = "\\"

-- Return the character or INDICATORS.EOF at index
local function peek(s, i)
  local ch = s:sub(i, i)
  if #ch == 0 then
    return INDICATORS.EOF
  else
    return ch
  end
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
  "Seq",
  "PlainScalar",
  "UnescapedScalar",
  "EscapedScalar",
}

local TokeniserState = enum{
  "Finished",
  "EmitBlockIndent",
  "FindBlockTokenStart",
  "FindBlockUnescapedScalarEnd",
  "FindBlockEscapedScalarEnd",
  "FindBlockPlainScalarEnd",
  "FindBlockAnchorName",
  "EmitBlockSingleQuote",
  "EmitBlockDoubleQuote",
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
    state = TokeniserState.EmitBlockIndent,
    index = 1,
    line = { nr = 1, index = 0 },
    accumulator = "",
    acc_line = { nr = 1, col = 1 },
  }
  setmetatable(ret, {__index = self})
  return ret
end

-- Return the line, col position of the Tokeniser in the source
function Tokeniser:position()
  return self.line.nr, self.index - self.line.index
end

-- Return the line, col of the save accumulator position
function Tokeniser:accumulator_position()
  return self.acc_line.nr, self.acc_line.col
end

-- Initialise accumulator to received value
function Tokeniser:set_accumulator(value)
  local line, col = self:position()
  self.acc_line = { nr = line, col = col }
  self.accumulator = value
end

-- Return a new token of type `type` with optional values
--
-- Note: the text key of the returned table is defaulted to an empty string if
-- not provided
function Tokeniser:emit_token(type_, vars)
  assert(type_, "Not a member of TokenType")
  local token = vars or {}
  token.type = type_
  token.text = token.text or ""
  return token
end

SIMPLE_TOKEN_MAP = {
  [INDICATORS.SINGLE_QUOTE] = TokenType.SingleQuote,
  [INDICATORS.DOUBLE_QUOTE] = TokenType.DoubleQuote,
  [INDICATORS.FOLDED]       = TokenType.Folded,
  [INDICATORS.SEQ]          = TokenType.Seq,
  [INDICATORS.MAP_VALUE]    = TokenType.MapValue,
  [INDICATORS.SEQ_BEGIN]    = TokenType.SeqBegin,
  [INDICATORS.SEQ_END]      = TokenType.SeqEnd,
  [INDICATORS.MAP_BEGIN]    = TokenType.MapBegin,
  [INDICATORS.MAP_END]      = TokenType.MapEnd,
  [INDICATORS.COLLECT]      = TokenType.Collect,
  [INDICATORS.ANCHOR]       = TokenType.Anchor,
  [INDICATORS.ALIAS]        = TokenType.Alias,
}

-- Return a token representing a special character with optional values
function Tokeniser:emit_character_token(ch, vars)
  local type_ = SIMPLE_TOKEN_MAP[ch]
  if DEBUG and not type_ then error(string.format("Unrecognised special character: '%s'", ch)) end
  local vars = vars or {}
  vars.text = ch
  return self:emit_token(type_, vars)
end

-- Return true if the tokeniser is finished, otherwise return false
function Tokeniser:is_finished()
  return self.state == TokeniserState.Finished
end

-- Set the tokeniser state to next_state
function Tokeniser:transition_state(next_state)
  assert(next_state, "Not a member of TokeniserState")
  self.state = next_state
end

function Tokeniser:next()
  local ch = peek(self.source, self.index)
  if self.state == TokeniserState.Finished then
    return nil

  elseif self.state == TokeniserState.EmitBlockIndent then
    local line, _ = self:position()
    local new_index = consume_indent(self.source, self.index)
    local indent = new_index - self.index
    self.index = new_index
    self:transition_state(TokeniserState.FindBlockTokenStart)
    return self:emit_token(TokenType.Indent, { indent = indent, line = line })

  elseif self.state == TokeniserState.FindBlockTokenStart then
    local lookahead = peek(self.source, self.index + 1)
    if ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.Finished)
      return self:emit_token(TokenType.DocumentEnd)

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self:transition_state(TokeniserState.EmitBlockIndent)
      return self:next()

    elseif ch == INDICATORS.COMMENT then
      self.index = consume_line(self.source, self.index)
      self:transition_state(TokeniserState.EmitBlockIndent)
      return self:next()

    elseif ch == INDICATORS.SINGLE_QUOTE then
      local line, col = self:position()
      self.index = self.index + 1
      self:set_accumulator("")
      self:transition_state(TokeniserState.FindBlockUnescapedScalarEnd)
      return self:emit_character_token(ch, { line = line, col = col })

    elseif ch == INDICATORS.DOUBLE_QUOTE then
      local line, col = self:position()
      self.index = self.index + 1
      self:set_accumulator("")
      self:transition_state(TokeniserState.FindBlockEscapedScalarEnd)
      return self:emit_character_token(ch, { line = line, col = col })

    elseif ch == INDICATORS.SEQ and lookahead == " " then
      local line, col = self:position()
      self.index = self.index + 2
      return self:emit_character_token(ch, { line = line, col = col })

    elseif ch == INDICATORS.ANCHOR or ch == INDICATORS.ALIAS then
      local line, col = self:position()
      self.index = self.index + 1
      self:transition_state(TokeniserState.FindBlockAnchorName)
      return self.emit_character_token(ch, { line = line, col = col })

    elseif ch == INDICATORS.SEQ_BEGIN or ch == INDICATORS.MAP_BEGIN or ch == INDICATORS.FOLDED or ch == INDICATORS.MAP_VALUE or ch == INDICATORS.SEQ_END or ch == INDICATORS.MAP_END or ch == INDICATORS.COLLECT then
      local line, col = self:position()
      self.index = self.index + 1
      return self:emit_character_token(ch, { line = line, col = col })

    elseif ch == " " or ch == "\t" then
      self.index = self.index + 1
      return self:next()

    else
      self:set_accumulator(ch)
      self.index = self.index + 1
      self:transition_state(TokeniserState.FindBlockPlainScalarEnd)
      return self:next()
    end

  elseif self.state == TokeniserState.FindBlockPlainScalarEnd then
    if ch == INDICATORS.EOF or ch == INDICATORS.EOL or ch == INDICATORS.COMMENT or ch == INDICATORS.DOUBLE_QUOTE or ch == INDICATORS.MAP_VALUE or ch == INDICATORS.SEQ_BEGIN or ch == INDICATORS.SEQ_END or ch == INDICATORS.MAP_BEGIN or ch == INDICATORS.MAP_END or ch == INDICATORS.ANCHOR or ch == INDICATORS.ALIAS then
      local line, col = self:accumulator_position()
      local text = trim_trailing(self.accumulator)
      self:transition_state(TokeniserState.FindBlockTokenStart)
      return self:emit_token(TokenType.PlainScalar, { text = text, line = line, col = col })

    else
      self.accumulator = self.accumulator .. ch
      self.index = self.index + 1
      return self:next()
    end

  elseif self.state == TokeniserState.FindBlockUnescapedScalarEnd then
    local lookahead = peek(self.source, self.index + 1)
    if ch == INDICATORS.EOF then
      local line, col = self:accumulator_position()
      self:transition_state(TokeniserState.FindBlockTokenStart)
      return self:emit_token(TokenType.UnescapedScalar, { text = self.accumulator, line = line, col = col })

    elseif ch == INDICATORS.EOL and lookahead == INDICATORS.EOL then
      self.index = self.index + 2
      self.accumulator = self.accumulator .. "\n"
      return self:next()

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self.accumulator = self.accumulator .. " "
      return self:next()

    elseif ch == INDICATORS.SINGLE_QUOTE and lookahead == INDICATORS.SINGLE_QUOTE then
      self.index = self.index + 2
      self.accumulator = self.accumulator .. "'"
      return self:next()

    elseif ch == INDICATORS.SINGLE_QUOTE then
      local line, col = self:accumulator_position()
      self:transition_state(TokeniserState.EmitBlockSingleQuote)
      return self:emit_token(TokenType.UnescapedScalar, { text = self.accumulator, line = line, col = col })

    else
      self.accumulator = self.accumulator .. ch
      self.index = self.index + 1
      return self:next()
    end

  elseif self.state == TokeniserState.EmitBlockSingleQuote then
    local line, col = self:position()
    self.index = self.index + 1
    self:transition_state(TokeniserState.FindBlockTokenStart)
    return self:emit_character_token(INDICATORS.SINGLE_QUOTE, { line = line, col = col })

  elseif self.state == TokeniserState.FindBlockEscapedScalarEnd then
    local lookahead = peek(self.source, self.index + 1)
    if nil then
    elseif ch == INDICATORS.EOF then
      local line, col = self:accumulator_position()
      self:transition_state(TokeniserState.FindBlockTokenStart)
      return self:emit_token(TokenType.EscapedScalar, { text = self.accumulator, line = line, col = col })

    elseif ch == INDICATORS.EOL and lookahead == INDICATORS.EOL then
      self.index = self.index + 2
      self.accumulator = self.accumulator .. "\n"
      return self:next()

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self.accumulator = self.accumulator .. " "
      return self:next()

    elseif ch == INDICATORS.DOUBLE_QUOTE then
      local line, col = self:accumulator_position()
      self:transition_state(TokeniserState.EmitBlockDoubleQuote)
      return self:emit_token(TokenType.EscapedScalar, { text = self.accumulator, line = line, col = col })

    elseif ch == ESCAPE and lookahead == INDICATORS.EOF then
      local line, col = self:position()
      error(string.format("Lone escape character at end-of-file: line %d, col %d", line, col))

    elseif ch == ESCAPE then
      local escaped = ESCAPES[lookahead]
      if not escaped then local line, col = self:position(); error(string.format("Unrecognised escape character \\%s: line %d, col %d", lookahead, line, col)) end
      self.index = self.index + 2
      self.accumulator = self.accumulator .. escaped
      return self:next()

    else
      self.index = self.index + 1
      self.accumulator = self.accumulator .. ch
      return self:next()
    end

  elseif self.state == TokeniserState.EmitBlockDoubleQuote then
    local line, col = self:position()
    self.index = self.index + 1
    self:transition_state(TokeniserState.FindBlockTokenStart)
    return self:emit_character_token(INDICATORS.DOUBLE_QUOTE, { line = line, col = col })

  elseif self.state == TokeniserState.FindBlockAnchorName then
  end

  if DEBUG then assert(false, "Unreachable") end
end

M.Tokeniser = Tokeniser
M.TokenType = TokenType
return M
