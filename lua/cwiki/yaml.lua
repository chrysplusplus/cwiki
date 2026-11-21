-- Lightweight YAML parser, or subset thereof
-- author: chrysplusplus

-- TODO:
-- - Add UTF-8 support

local M = {}

local util = require "cwiki.util"
local dassert = util.dassert
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
  local i, _ = s:find("[^ \t]", idx)
  return i or #s + 1
end

-- Advance the index past the indentation whitespace; return the new index
local function consume_indent(s, idx)
  local i, _ = s:find("[^ ]", idx)
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

local ANCHOR_NAME_PATTERN = "^[%a_][%w_]*"

-- Match the anchor name at the received index in the received string; if a
-- match was found, return the index of the character past the match and the
-- match itself, otherwise return the received index and a nil value,
-- representing no match
local function consume_anchor_name(s, idx)
  local b, e = s:find(ANCHOR_NAME_PATTERN, idx)
  if not b then return idx, nil end
  return e + 1, s:sub(b, e)
end

-- Trim trailing spaces from string
local function trim_trailing(s)
  local i, _ = s:find("%s+$")
  if not i then return s end
  return s:sub(1, i - 1)
end

local TokenType = enum{
  "BlockIndent",
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
  "AnchorName",
  "FoldIndent",
  "FoldLine",
  "FoldNewline",
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
  "FindFlowTokenStart",
  "FindFlowUnescapedScalarEnd",
  "FindFlowEscapedScalarEnd",
  "FindFlowPlainScalarEnd",
  "FindFlowAnchorName",
  "EmitFlowSingleQuote",
  "EmitFlowDoubleQuote",
  "FindFoldLineStart",
  "FindFoldLineEnd",
  "EmitFoldIndent",
  "EmitFoldDocumentEnd",
}

-- Tokeniser objects represent a generator that emits a sequence of lexical
-- tokens that represents the received source string
local Tokeniser = {}
function Tokeniser:new(s)
  local ret = {
    source = s,
    state = TokeniserState.EmitBlockIndent,
    index = 1,
    line = { nr = 1, index = 0 },
    acc = { text = "", nr = 1, col = 1 },
  }
  setmetatable(ret, {__index = self})
  return ret
end

-- Return the line, col position of the Tokeniser in the source
function Tokeniser:position()
  return self.line.nr, self.index - self.line.index
end

-- Return a table of { line = line, col = col }
function Tokeniser:position_table(t)
  local t = t or {}
  t.line, t.col = self:position()
  return t
end

-- Signal new line
function Tokeniser:newline()
  self.line.nr = self.line.nr + 1
  self.line.index = self.index - 1
end

-- Return the line, col of the save accumulator position
function Tokeniser:accumulator_position()
  return self.acc.nr, self.acc.col
end

-- Initialise accumulator to received value
function Tokeniser:set_accumulator(value)
  self.acc.nr, self.acc.col = self:position()
  self.acc.text = value
end

-- Return a table representing the token stored in the accumulator, optionally
-- using a transform function on the text
function Tokeniser:use_accumulator(transform)
  local transform = transform or function (...) return ... end
  local line, col = self:accumulator_position()
  return { text = transform(self.acc.text), line = line, col = col }
end

-- Return a new token of type `type` with optional values
--
-- Note: the text key of the returned table is defaulted to an empty string if
-- not provided
function Tokeniser:emit_token(type_, vars)
  if SINGLE_TEST and not type_ then print(debug.traceback("", 2)) end
  dassert(type_, "Not a member of TokenType")
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
  if SINGLE_TEST and not next_state then print(debug.traceback("", 2)) end
  dassert(next_state, "Not a member of TokeniserState")
  self.state = next_state
end

-- Set the tokeniser to a block context
function Tokeniser:use_block_context()
  self.state = TokeniserState.FindBlockTokenStart
end

-- Set the tokeniser to a flow context
function Tokeniser:use_flow_context()
  self.state = TokeniserState.FindFlowTokenStart
end

-- Set the tokeniser to a folded context
function Tokeniser:use_folded_context()
  self.state = TokeniserState.EmitFoldIndent
end

-- Advance the tokeniser state machine to emit the next token in the source, or
-- nil if the tokeniser is finished
function Tokeniser:next()
  if self.state == TokeniserState.Finished then
    return nil

  elseif self.state == TokeniserState.EmitBlockIndent then
    local ch = peek(self.source, self.index)
    local new_index = consume_indent(self.source, self.index)
    local indent = new_index - self.index
    self.index = new_index
    self:transition_state(TokeniserState.FindBlockTokenStart)
    return self:emit_token(TokenType.BlockIndent, self:position_table{ indent = indent })

  elseif self.state == TokeniserState.FindBlockTokenStart then
    local ch = peek(self.source, self.index)
    local lookahead = peek(self.source, self.index + 1)
    if ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.Finished)
      return self:emit_token(TokenType.DocumentEnd)

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      self:transition_state(TokeniserState.EmitBlockIndent)
      return self:next()

    elseif ch == INDICATORS.COMMENT then
      self.index = consume_line(self.source, self.index)
      self:newline()
      self:transition_state(TokeniserState.EmitBlockIndent)
      return self:next()

    elseif ch == INDICATORS.SINGLE_QUOTE then
      self:transition_state(TokeniserState.FindBlockUnescapedScalarEnd)
      local token = self:emit_character_token(ch, self:position_table())
      self.index = self.index + 1
      self:set_accumulator("")
      return token

    elseif ch == INDICATORS.DOUBLE_QUOTE then
      self:transition_state(TokeniserState.FindBlockEscapedScalarEnd)
      local token = self:emit_character_token(ch, self:position_table())
      self.index = self.index + 1
      self:set_accumulator("")
      return token

    elseif ch == INDICATORS.SEQ and lookahead == " " then
      local token = self:emit_character_token(ch, self:position_table())
      self.index = self.index + 2
      return token

    elseif ch == INDICATORS.ANCHOR or ch == INDICATORS.ALIAS then
      self:transition_state(TokeniserState.FindBlockAnchorName)
      local token = self:emit_character_token(ch, self:position_table())
      self.index = self.index + 1
      return token

    elseif ch == INDICATORS.SEQ_BEGIN or ch == INDICATORS.MAP_BEGIN or ch == INDICATORS.FOLDED or ch == INDICATORS.MAP_VALUE or ch == INDICATORS.SEQ_END or ch == INDICATORS.MAP_END or ch == INDICATORS.COLLECT then
      local token = self:emit_character_token(ch, self:position_table())
      self.index = self.index + 1
      return token

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
    local ch = peek(self.source, self.index)
    if ch == INDICATORS.EOF or ch == INDICATORS.EOL or ch == INDICATORS.COMMENT or ch == INDICATORS.DOUBLE_QUOTE or ch == INDICATORS.MAP_VALUE or ch == INDICATORS.SEQ_BEGIN or ch == INDICATORS.SEQ_END or ch == INDICATORS.MAP_BEGIN or ch == INDICATORS.MAP_END or ch == INDICATORS.ANCHOR or ch == INDICATORS.ALIAS then
      self:transition_state(TokeniserState.FindBlockTokenStart)
      return self:emit_token(TokenType.PlainScalar, self:use_accumulator(trim_trailing))

    else
      self.acc.text = self.acc.text .. ch
      self.index = self.index + 1
      return self:next()
    end

  elseif self.state == TokeniserState.FindBlockUnescapedScalarEnd then
    local ch = peek(self.source, self.index)
    local lookahead = peek(self.source, self.index + 1)
    if ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.FindBlockTokenStart)
      return self:emit_token(TokenType.UnescapedScalar, self:use_accumulator())

    elseif ch == INDICATORS.EOL and lookahead == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      self.index = self.index + 1
      self:newline()
      self.acc.text = self.acc.text .. "\n"
      return self:next()

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      self.acc.text = self.acc.text .. " "
      return self:next()

    elseif ch == INDICATORS.SINGLE_QUOTE and lookahead == INDICATORS.SINGLE_QUOTE then
      self.index = self.index + 2
      self.acc.text = self.acc.text .. "'"
      return self:next()

    elseif ch == INDICATORS.SINGLE_QUOTE then
      self:transition_state(TokeniserState.EmitBlockSingleQuote)
      return self:emit_token(TokenType.UnescapedScalar, self:use_accumulator())

    else
      self.acc.text = self.acc.text .. ch
      self.index = self.index + 1
      return self:next()
    end

  elseif self.state == TokeniserState.EmitBlockSingleQuote then
    local ch = peek(self.source, self.index)
    self:transition_state(TokeniserState.FindBlockTokenStart)
    local token = self:emit_character_token(INDICATORS.SINGLE_QUOTE, self:position_table())
    self.index = self.index + 1
    return token

  elseif self.state == TokeniserState.FindBlockEscapedScalarEnd then
    local ch = peek(self.source, self.index)
    local lookahead = peek(self.source, self.index + 1)
    if nil then
    elseif ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.FindBlockTokenStart)
      return self:emit_token(TokenType.EscapedScalar, self:use_accumulator())

    elseif ch == INDICATORS.EOL and lookahead == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      self.index = self.index + 1
      self:newline()
      self.acc.text = self.acc.text .. "\n"
      return self:next()

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      self.acc.text = self.acc.text .. " "
      return self:next()

    elseif ch == INDICATORS.DOUBLE_QUOTE then
      self:transition_state(TokeniserState.EmitBlockDoubleQuote)
      return self:emit_token(TokenType.EscapedScalar, self:use_accumulator())

    elseif ch == ESCAPE and lookahead == INDICATORS.EOF then
      error(string.format("Lone escape character at end-of-file: line %d, col %d", self:position()))

    elseif ch == ESCAPE then
      local escaped = ESCAPES[lookahead]
      if not escaped then error(string.format("Unrecognised escape character \\%s: line %d, col %d", lookahead, self:position())) end
      self.index = self.index + 2
      self.acc.text = self.acc.text .. escaped
      return self:next()

    else
      self.index = self.index + 1
      self.acc.text = self.acc.text .. ch
      return self:next()
    end

  elseif self.state == TokeniserState.EmitBlockDoubleQuote then
    local ch = peek(self.source, self.index)
    self:transition_state(TokeniserState.FindBlockTokenStart)
    local token = self:emit_character_token(INDICATORS.DOUBLE_QUOTE, self:position_table())
    self.index = self.index + 1
    return token

  elseif self.state == TokeniserState.FindBlockAnchorName then
    local ch = peek(self.source, self.index)
    local new_index, anchor_name = consume_anchor_name(self.source, self.index)
    self:transition_state(TokeniserState.FindBlockTokenStart)
    if not anchor_name then return self:next() end
    local token = self:emit_token(TokenType.AnchorName, self:position_table{ text = anchor_name })
    self.index = new_index
    return token

  elseif self.state == TokeniserState.FindFlowTokenStart then
    local ch = peek(self.source, self.index)
    if ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.Finished)
      return self:emit_token(TokenType.DocumentEnd)

    elseif ch == " " or ch == "\t" then
      self.index = self.index + 1
      return self:next()

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      return self:next()

    elseif ch == INDICATORS.COMMENT then
      self.index = consume_line(self.source, self.index)
      self:newline()
      return self:next()

    elseif ch == INDICATORS.SINGLE_QUOTE then
      self:transition_state(TokeniserState.FindFlowUnescapedScalarEnd)
      local token = self:emit_character_token(ch, self:position_table())
      self.index = self.index + 1
      self:set_accumulator("")
      return token

    elseif ch == INDICATORS.DOUBLE_QUOTE then
      self:transition_state(TokeniserState.FindFlowEscapedScalarEnd)
      local token = self:emit_character_token(ch, self:position_table())
      self.index = self.index + 1
      self:set_accumulator("")
      return token

    elseif ch == INDICATORS.FOLDED or ch == INDICATORS.SEQ or ch == INDICATORS.MAP_VALUE or ch == INDICATORS.SEQ_BEGIN or ch == INDICATORS.SEQ_END or ch == INDICATORS.MAP_BEGIN or ch == INDICATORS.MAP_END or ch == INDICATORS.COLLECT then
      local token = self:emit_character_token(ch, self:position_table())
      self.index = self.index + 1
      return token

    elseif ch == INDICATORS.ANCHOR or ch == INDICATORS.ALIAS then
      self:transition_state(TokeniserState.FindFlowAnchorName)
      local token = self:emit_character_token(ch, self:position_table())
      self.index = self.index + 1
      return token

    else
      self:set_accumulator(ch)
      self.index = self.index + 1
      self:transition_state(TokeniserState.FindFlowPlainScalarEnd)
      return self:next()
    end

  elseif self.state == TokeniserState.FindFlowPlainScalarEnd then
    local ch = peek(self.source, self.index)
    if ch == INDICATORS.EOF or ch == INDICATORS.EOL or ch == INDICATORS.COMMENT or ch == INDICATORS.DOUBLE_QUOTE or ch == INDICATORS.MAP_VALUE or ch == INDICATORS.SEQ_BEGIN or ch == INDICATORS.SEQ_END or ch == INDICATORS.MAP_BEGIN or ch == INDICATORS.MAP_END or ch == INDICATORS.COLLECT or ch == INDICATORS.ANCHOR or ch == INDICATORS.ALIAS then
      self:transition_state(TokeniserState.FindFlowTokenStart)
      return self:emit_token(TokenType.PlainScalar, self:use_accumulator(trim_trailing))

    else
      self.acc.text = self.acc.text .. ch
      self.index = self.index + 1
      return self:next()
    end

  elseif self.state == TokeniserState.FindFlowUnescapedScalarEnd then
    local ch = peek(self.source, self.index)
    local lookahead = peek(self.source, self.index + 1)
    if ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.FindFlowTokenStart)
      return self:emit_token(TokenType.UnescapedScalar, self:use_accumulator())

    elseif ch == INDICATORS.EOL and lookahead == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      self.index = self.index + 1
      self:newline()
      self.acc.text = self.acc.text .. "\n"
      return self:next()

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      self.acc.text = self.acc.text .. " "
      return self:next()

    elseif ch == INDICATORS.SINGLE_QUOTE and lookahead == INDICATORS.SINGLE_QUOTE then
      self.index = self.index + 2
      self.acc.text = self.acc.text .. "'"
      return self:next()

    elseif ch == INDICATORS.SINGLE_QUOTE then
      self:transition_state(TokeniserState.EmitFlowSingleQuote)
      return self:emit_token(TokenType.UnescapedScalar, self:use_accumulator())

    else
      self.acc.text = self.acc.text .. ch
      self.index = self.index + 1
      return self:next()
    end

  elseif self.state == TokeniserState.EmitFlowSingleQuote then
    local ch = peek(self.source, self.index)
    self:transition_state(TokeniserState.FindFlowTokenStart)
    local token = self:emit_character_token(INDICATORS.SINGLE_QUOTE, self:position_table())
    self.index = self.index + 1
    return token

  elseif self.state == TokeniserState.EmitFlowDoubleQuote then
    local ch = peek(self.source, self.index)
    self:transition_state(TokeniserState.FindFlowTokenStart)
    local token = self:emit_character_token(INDICATORS.DOUBLE_QUOTE, self:position_table())
    self.index = self.index + 1
    return token

  elseif self.state == TokeniserState.FindFlowEscapedScalarEnd then
    local ch = peek(self.source, self.index)
    local lookahead = peek(self.source, self.index + 1)
    if nil then
    elseif ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.FindFlowTokenStart)
      return self:emit_token(TokenType.EscapedScalar, self:use_accumulator())

    elseif ch == INDICATORS.EOL and lookahead == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      self.index = self.index + 1
      self:newline()
      self.acc.text = self.acc.text .. "\n"
      return self:next()

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      self.acc.text = self.acc.text .. " "
      return self:next()

    elseif ch == INDICATORS.DOUBLE_QUOTE then
      self:transition_state(TokeniserState.EmitFlowDoubleQuote)
      return self:emit_token(TokenType.EscapedScalar, self:use_accumulator())

    elseif ch == ESCAPE and lookahead == INDICATORS.EOF then
      error(string.format("Lone escape character at end-of-file: line %d, col %d", self:position()))

    elseif ch == ESCAPE then
      local escaped = ESCAPES[lookahead]
      if not escaped then local line, col = self:position(); error(string.format("Unrecognised escape character \\%s: line %d, col %d", lookahead, line, col)) end
      self.index = self.index + 2
      self.acc.text = self.acc.text .. escaped
      return self:next()

    else
      self.index = self.index + 1
      self.acc.text = self.acc.text .. ch
      return self:next()
    end

  elseif self.state == TokeniserState.FindFlowAnchorName then
    local ch = peek(self.source, self.index)
    local new_index, anchor_name = consume_anchor_name(self.source, self.index)
    self:transition_state(TokeniserState.FindFlowTokenStart)
    if not anchor_name then return self:next() end
    local token = self:emit_token(TokenType.AnchorName, self:position_table{ text = anchor_name })
    self.index = new_index
    return token

  elseif self.state == TokeniserState.EmitFoldIndent then
    local new_index = consume_indent(self.source, self.index)
    local indent = new_index - self.index
    local token = self:emit_token(TokenType.FoldIndent, self:position_table{ indent = indent })
    self.index = new_index
    self:transition_state(TokeniserState.FindFoldLineStart)
    return token

  elseif self.state == TokeniserState.FindFoldLineStart then
    local ch = peek(self.source, self.index)
    if ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.EmitFoldDocumentEnd)
      return self:emit_token(TokenType.FoldNewline)

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      self:transition_state(TokeniserState.EmitFoldIndent)
      return self:emit_token(TokenType.FoldNewline)

    else
      self:set_accumulator(ch)
      self.index = self.index + 1
      self:transition_state(TokeniserState.FindFoldLineEnd)
      return self:next()
    end

  elseif self.state == TokeniserState.EmitFoldDocumentEnd then
    self:transition_state(TokeniserState.Finished)
    return self:emit_token(TokenType.DocumentEnd)

  elseif self.state == TokeniserState.FindFoldLineEnd then
    local ch = peek(self.source, self.index)
    if ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.EmitFoldDocumentEnd)
      return self:emit_token(TokenType.FoldLine, self:use_accumulator())

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self:newline()
      self:transition_state(TokeniserState.EmitFoldIndent)
      return self:emit_token(TokenType.FoldLine, self:use_accumulator())

    else
      self.index = self.index + 1
      self.acc.text = self.acc.text .. ch
      return self:next()
    end
  end

  if DEBUG then error "Unreachable" end
end

-- Return a readable representation of the tokeniser state
local function print_tokeniser(t)
  return string.format(
    "{ source = \"...\", state = %s, index = %d, ... }",
    enum_to_string(TokeniserState, t.state),
    t.index)
end

-- Return a readable representation of a token
local function print_token(t)
  if not t then return nil end
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

  return string.format("{ %s }", table.concat(keyvals, ", "))
end

-- Return a StackStream object wrapping a tokeniser
local function tokeniser_stream_adaptor(tokeniser)
  -- couldn't the tokeniser just be the upstream, since it has a :next method?
  local stream = require "cwiki.stream"
  local upstream = stream.Stream:new {
    next_fn = function (tknsr, ctrl)
      return ctrl, tknsr:next()
    end,
    invar = tokeniser,
    ctrl = 0,
  }
  return stream.StackStream:new(upstream)
end

local ParserNodeType = enum {
  "Root",
  "Scalar",
  "Sequence",
  "Mapping",
  "MappingEntry",
}

local ParserContext = enum {
  "Finished",
  "AtRoot",
  "DetermineBlockSequenceIndent",
  "ExpectAnchorAlias",
  "ExpectAnchorDefinition",
  "ExpectEscapedScalar",
  "ExpectMappingValue",
  "ExpectMappingValueIndicator",
  "ExpectSequenceEntry",
  "ExpectUnescapedScalar",
  "HandleMappingContinuation",
  "HandleSequenceContinuation",
  "InFlowSequence",
  "InFlowMapping",
  "ExpectDoubleQuote",
  "ExpectSingleQuote",
}

if DEBUG then
  local _debug_restrict_accessor_tbl = {
    __index = function (t, k)
      dassert(type(t) == "table")
      return dassert(rawget(t, k), string.format("Missing key: %s", tostring(k)))
    end,
    __newindex = function (...) error("Operation not permitted") end
  }

  -- debug accessor for enums
  setmetatable(ParserNodeType, _debug_restrict_accessor_tbl)
  setmetatable(ParserContext, _debug_restrict_accessor_tbl)
end

-- Parser objects present a YAML document builder that accepts tokens from a
-- tokeniser (see Tokeniser) and manages the document context of that tokeniser
local Parser = {}
function Parser:new(source)
  local tokeniser = Tokeniser:new(source)
  local obj = {
    tokeniser = tokeniser,
    token_stream = tokeniser_stream_adaptor(tokeniser),
    context = ParserContext.AtRoot,
    document_tree = {},
    node_stack = {},
    current_indent = 0,
    restore_context = nil,
    current_anchor = nil,
    anchor_definitions = {},
    current_scalar_token = nil,
  }
  setmetatable(obj, {__index = self})
  return obj
end

function Parser:set_context(context)
  self.context, _ = dassert(context, "Not a member of ParserContext")
end

-- Nest a child node within a parent and return the result
local function adopt_node(parent, child)
  if parent.type == ParserNodeType.Sequence then
    table.insert(parent.content, child)
  elseif parent.type == ParserNodeType.Mapping then
    dassert(child.type == ParserNodeType.MappingEntry)
    table.insert(parent.content, child)
  elseif parent.type == ParserNodeType.Root then
    parent.content = child
  elseif parent.type == ParserNodeType.MappingEntry then
    parent.value = child
  else
    if TRACE then
      print(string.format("parent ParserNodeType.%s, child ParserNodeType.%s", enum_to_string(ParserNodeType, parent.type), enum_to_string(ParserNodeType, child.type)))
    end
    error "Invalid token type for parent node"
  end
  return parent
end

-- Return the indent of the node at the top of the node stack
function Parser:get_last_node()
  return dassert(self.node_stack[#self.node_stack])
end

-- Pop the nodes the stack and adopt them as child nodes until the indent level
-- of the top node in the stack matches the received indent
function Parser:pop_stack_to_indent_level(indent)
  local prev_indent = dassert(self:get_last_node().indent)
  while indent < prev_indent do
    local child = table.remove(self.node_stack)
    if child.anchor_name then self.anchor_definitions[child.anchor_name] = child end
    adopt_node(self:get_last_node(), child)
    prev_indent = dassert(self:get_last_node().indent)
  end
end

-- Pop the node at the top of the stack and adopt it as the child of the node
-- that used to be below it in the stack
function Parser:pop_and_adopt()
  local child = table.remove(self.node_stack)
  if child.anchor_name then self.anchor_definitions[child.anchor_name] = child end
  adopt_node(self:get_last_node(), child)
end

-- Push a node onto the parser stack, combining the stack if the indent of the
-- received node is less than that at the top of the stack
function Parser:push_node_to_stack(node)
  if self.current_anchor then
    node.anchor_name = self.current_anchor
    self.current_anchor = nil
  end
  if #self.node_stack == 0 then self.node_stack[1] = node; return end
  -- self:pop_stack_to_indent_level(dassert(node.indent)) -- maybe remove
  table.insert(self.node_stack, node)
end

-- Repeatedly combine the stack until only one node is left, then assign the
-- result to the parser document tree
function Parser:pop_all_nodes()
  while #self.node_stack >= 2 do
    local child = table.remove(self.node_stack)
    if child.anchor_name then self.anchor_definitions[child.anchor_name] = child end
    adopt_node(self:get_last_node(), child)
  end
  self.document_tree = {
    type = ParserNodeType.Root,
    content = table.remove(self.node_stack) or {}
  }
end

local function is_scalar_token(token)
  local ttype = dassert(token.type)
  return ttype == TokenType.PlainScalar or ttype == TokenType.UnescapedScalar or ttype == TokenType.EscapedScalar
end

-- TODO test TokenType coverage
-- TODO test ParserContext coverage
-- TODO better error handling
function Parser:parse_token(token)
  local ttype = dassert(token.type)
  if self.context == ParserContext.Finished then return end

  if TRACE then print(print_token(token)) end

  if self.context == ParserContext.AtRoot then
    if ttype == TokenType.BlockIndent then
      self.current_indent = dassert(token.indent)
      return

    elseif ttype == TokenType.DocumentEnd then
      self:pop_all_nodes()
      return self:set_context(ParserContext.Finished)

    elseif ttype == TokenType.SingleQuote then
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectUnescapedScalar)

    elseif ttype == TokenType.DoubleQuote then
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectEscapedScalar)

    elseif ttype == TokenType.Folded then
      error "Not implemented"

    elseif ttype == TokenType.MapValue then
      local key_node = dassert(table.remove(self.node_stack))
      self:push_node_to_stack{
        type = ParserNodeType.Mapping,
        content = {},
        indent = self.current_indent,
      }
      self:push_node_to_stack{
        type = ParserNodeType.MappingEntry,
        key = key_node,
        value = {},
        indent = self.current_indent,
      }
      return self:set_context(ParserContext.ExpectMappingValue)

    elseif ttype == TokenType.SeqBegin then
      self.tokeniser:use_flow_context()
      return self:set_context(ParserContext.InFlowSequence)

    elseif ttype == TokenType.MapBegin then
      self.tokeniser:use_flow_context()
      return self:set_context(ParserContext.InFlowSequence)

    elseif ttype == TokenType.Anchor then
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectAnchorDefinition)

    elseif ttype == TokenType.Alias then
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectAnchorAlias)

    elseif ttype == TokenType.AnchorName then
      local node = self:get_last_node()
      dassert(node.anchor_name == token.text)
      return

    elseif ttype == TokenType.Seq then
      dassert(#self.node_stack == 0, "Unexpected token")
      self:push_node_to_stack{
        type = ParserNodeType.Sequence,
        content = {},
        indent = self.current_indent,
        child_indent = 0,
        _token = token,
      }
      return self:set_context(ParserContext.DetermineBlockSequenceIndent)

    elseif is_scalar_token(token) then
      dassert(#self.node_stack == 0, "Unexpected token")
      self:push_node_to_stack{
        type = ParserNodeType.Scalar,
        content = dassert(token.text),
        indent = self.current_indent,
        _token = token,
      }
      return
    end

  elseif self.context == ParserContext.DetermineBlockSequenceIndent then
    if ttype == TokenType.BlockIndent then
      self.current_indent = dassert(token.indent)
      return
    end

    dassert(#self.node_stack >= 1)
    local parent = self:get_last_node()
    dassert(parent.type == ParserNodeType.Sequence)
    dassert(self.current_indent >= parent.indent, "Ambiguous indentation")
    self.current_indent = (self.current_indent == parent.indent) and (dassert(token.col) - 1) or self.current_indent
    parent.child_indent = self.current_indent
    self.token_stream:push(token)
    return self:set_context(ParserContext.ExpectSequenceEntry)

  elseif self.context == ParserContext.ExpectSequenceEntry then
    if is_scalar_token(token) then
      local parent = dassert(self:get_last_node())
      self.current_indent = (self.current_indent == parent.indent) and (dassert(token.col) - 1) or self.current_indent
      dassert(self.current_indent == parent.child_indent, "Ambiguous indentation")
      self:push_node_to_stack{
        type = ParserNodeType.Scalar,
        content = dassert(token.text),
        indent = self.current_indent,
        _token = token,
      }
      return self:set_context(ParserContext.HandleSequenceContinuation)

    elseif ttype == TokenType.Anchor then
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectAnchorDefinition)

    elseif ttype == TokenType.Alias then
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectAnchorAlias)

    elseif ttype == TokenType.AnchorName then
      local node = self:get_last_node()
      dassert(node.anchor_name == token.text)
      return self:set_context(ParserContext.HandleSequenceContinuation)

    else
      error(string.format("Token at line %d, column %d is disallowed", token.line or 0, token.col or 0))
    end

  elseif self.context == ParserContext.HandleSequenceContinuation then
    if ttype == TokenType.BlockIndent then
      self.current_indent = dassert(token.indent)
      return

    elseif ttype == TokenType.DocumentEnd then
      self:pop_all_nodes()
      return self:set_context(ParserContext.Finished)

    elseif ttype == TokenType.MapValue then
      error "Not implemented"

    elseif ttype == TokenType.Seq then
      self:pop_and_adopt()
      local parent = dassert(self:get_last_node())
      dassert(parent.type == ParserNodeType.Sequence)
      dassert(parent.indent)
      dassert(self.current_indent <= parent.indent, "Ambiguous indentation")
      if self.current_indent == parent.indent then
        return self:set_context(ParserContext.ExpectSequenceEntry)
      else
        self.token_stream:push(token)
        error "Not implemented"
      end
    end

  elseif self.context == ParserContext.ExpectMappingValue then
    if ttype == TokenType.BlockIndent then
      self.current_indent = dassert(token.indent)
      return

    elseif ttype == TokenType.SingleQuote then
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectUnescapedScalar)

    elseif ttype == TokenType.DoubleQuote then
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectEscapedScalar)

    elseif ttype == TokenType.Folded then
      error "Not implemented"

    elseif ttype == TokenType.MapValue then
      error "Not implemented"

    elseif ttype == TokenType.SeqBegin then
      self.tokeniser:use_flow_context()
      return self:set_context(ParserContext.InFlowSequence)

    elseif ttype == TokenType.MapBegin then
      self.tokeniser:use_flow_context()
      return self:set_context(ParserContext.InFlowMapping)

    elseif ttype == TokenType.Anchor then
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectAnchorDefinition)

    elseif ttype == TokenType.Alias then
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectAnchorAlias)

    elseif ttype == TokenType.Alias then
      local node = self:get_last_node()
      dassert(node.anchor_name == token.text)
      return self:set_context(ParserContext.HandleMappingContinuation)

    elseif ttype == TokenType.Seq then
      error "Not implemented"

    elseif is_scalar_token(token) then
      self:push_node_to_stack{
        type = ParserNodeType.Scalar,
        content = dassert(token.text),
        indent = self.current_indent,
        _token = token,
      }
      return self:set_context(ParserContext.HandleMappingContinuation)

    else
      error "Expected value for mapping"
    end

  elseif self.context == ParserContext.HandleMappingContinuation then
    if ttype == TokenType.BlockIndent then
      self.current_indent = dassert(token.indent)
      return

    elseif ttype == TokenType.DocumentEnd then
      self:pop_all_nodes()
      return self:set_context(ParserContext.Finished)

    elseif ttype == TokenType.MapValue then
      error "Not implemented"

    elseif is_scalar_token(token) then
      self:pop_and_adopt() -- value into entry
      self:pop_and_adopt() -- entry into mapping
      local parent = dassert(self:get_last_node())
      dassert(parent.type == ParserNodeType.Mapping)
      dassert(self.current_indent <= parent.indent, "Ambiguous indentation")
      if self.current_indent == parent.indent then
        self:push_node_to_stack{
          type = ParserNodeType.MappingEntry,
          key = {
            type = ParserNodeType.Scalar,
            content = dassert(token.text),
            indent = self.current_indent,
            _token = token,
          },
          value = {},
          indent = self.current_indent,
        }
        return self:set_context(ParserContext.ExpectMappingValueIndicator)
      else
        self.token_stream:push(token)
        error "Not implemented"
      end

    else
      error "Unexpected token after mapping"
    end

  elseif self.context == ParserContext.ExpectMappingValueIndicator then
    dassert(ttype == TokenType.MapValue)
    return self:set_context(ParserContext.ExpectMappingValue)

  elseif self.context == ParserContext.ExpectAnchorAlias then
    dassert(ttype == TokenType.AnchorName, "Expected anchor name")
    local node = self.anchor_definitions[dassert(token.text)]
    if not node then error(string.format("Undefined anchor: %s", token.text)) end
    self:push_node_to_stack(node)
    self.token_stream:push(token)
    local restore_context = dassert(self.restore_context)
    self.restore_context = nil
    return self:set_context(restore_context)

  elseif self.context == ParserContext.ExpectAnchorDefinition then
    dassert(ttype == TokenType.AnchorName, "Expected anchor name")
    self.current_anchor = dassert(token.text)
    local restore_context = dassert(self.restore_context)
    self.restore_context = nil
    return self:set_context(restore_context)

  elseif self.context == ParserContext.ExpectEscapedScalar then
    dassert(ttype == TokenType.EscapedScalar)
    self.current_scalar_token = token
    return self:set_context(ParserContext.ExpectDoubleQuote)

  elseif self.context == ParserContext.ExpectDoubleQuote then
    assert(ttype == TokenType.DoubleQuote)
    self.token_stream:push(self.current_scalar_token)
    self.current_scalar_token = nil
    local restore_context = self.restore_context
    self.restore_context = nil
    return self:set_context(restore_context)

  elseif self.context == ParserContext.ExpectUnescapedScalar then
    assert(ttype == TokenType.UnescapedScalar)
    self.current_scalar_token = token
    return self:set_context(ParserContext.ExpectSingleQuote)

  elseif self.context == ParserContext.ExpectSingleQuote then
    assert(ttype == TokenType.SingleQuote)
    self.token_stream:push(self.current_scalar_token)
    self.current_scalar_token = nil
    local restore_context = self.restore_context
    self.restore_context = nil
    return self:set_context(restore_context)

  elseif self.context == ParserContext.InFlowSequence then
    error "Not implemented"

  elseif self.context == ParserContext.InFlowMapping then
    error "Not implemented"
  end

  if DEBUG then error "Unreachable" end
end

-- Module Exports
M.Tokeniser      = Tokeniser
M.TokenType      = TokenType
M.ParserNodeType = ParserNodeType
M.Parser         = Parser

M.tokeniser_stream_adaptor = tokeniser_stream_adaptor

if DEBUG then
  M.TokeniserState = TokeniserState
  M.ParserContext  = ParserContext

  M.print_tokeniser = print_tokeniser
  M.print_token     = print_token
end

return M
