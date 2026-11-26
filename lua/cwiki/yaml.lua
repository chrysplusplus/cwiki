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

-- Return true if character is end-of-line or end-of-file
local function is_eof_or_eol(ch)
  return ch == INDICATORS.EOL or ch == INDICATORS.EOF
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
  "FoldEnd",
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
  "FindFoldIndent",
  "EmitFoldIndent", -- maybe unused
  "EmitFoldEnd",
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
    fold_indent = 0,
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
  self.state = TokeniserState.FindFoldIndent
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

  elseif self.state == TokeniserState.FindFoldIndent then
    local new_index = consume_indent(self.source, self.index)
    if peek(self.source, new_index) == INDICATORS.EOL then
      self.index = new_index + 1
      return self:emit_token(TokenType.FoldNewline)
    end
    self.fold_indent = new_index - self.index
    self.index = new_index
    self:transition_state(TokeniserState.FindFoldLineStart)
    return self:emit_token(TokenType.FoldIndent, self:position_table{ indent = 0 })

  elseif self.state == TokeniserState.EmitFoldIndent then
    local new_index = consume_indent(self.source, self.index)
    local indent = new_index - self.index
    local relative_indent = indent - self.fold_indent
    if relative_indent < 0 and not is_eof_or_eol(peek(self.source, new_index)) then
      self.index = new_index
      self:transition_state(TokeniserState.EmitFoldEnd)
      return self:next()

    elseif relative_indent < 0 then
      self.index = new_index
      self:transition_state(TokeniserState.FindFoldLineStart)
      return self:next()
    end

    local token = self:emit_token(TokenType.FoldIndent, self:position_table{ indent = relative_indent })
    self.index = new_index
    self:transition_state(TokeniserState.FindFoldLineStart)
    return token

  elseif self.state == TokeniserState.FindFoldLineStart then
    local ch = peek(self.source, self.index)
    if ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.EmitFoldEnd)
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

  elseif self.state == TokeniserState.EmitFoldEnd then
    self:transition_state(TokeniserState.Finished)
    return self:emit_token(TokenType.FoldEnd)

  elseif self.state == TokeniserState.FindFoldLineEnd then
    local ch = peek(self.source, self.index)
    if ch == INDICATORS.EOF then
      self:transition_state(TokeniserState.EmitFoldEnd)
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

-- Predicate for whether the token type is considered a scalar type
local function is_scalar_token(token)
  local ttype = dassert(token.type)
  return ttype == TokenType.PlainScalar or ttype == TokenType.UnescapedScalar or ttype == TokenType.EscapedScalar
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

local DocumentNode = enum {
  "Root",
  "Scalar",
  "Sequence",
  "Mapping",
  "MappingEntry",
  "Anchor",
  "Alias",
}

-- Return a readable representation of a document tree
local function print_document_tree(tree)
  local visit_children, impl

  visit_children = function (lines, t, depth)
    local indent = string.rep(" ", depth)
    for _, node in ipairs(t.content) do
      table.insert(lines, indent .. "  {")
      for _, line in ipairs(impl(node, depth + 4)) do
        table.insert(lines, line)
      end
      table.insert(lines, indent .. "  }")
    end
  end

  impl = function (t, depth)
    if not t then return nil end
    local indent = string.rep(" ", depth)
    local lines = {}
    if t.type == DocumentNode.Root then
      table.insert(lines, "{")
      table.insert(lines, "  type = Root")
      table.insert(lines, "  content = {")
      for _, line in ipairs(impl(t.content, 4)) do
        table.insert(lines, line)
      end
      table.insert(lines, "  }")
      table.insert(lines, "}")
      return lines

    elseif t.type == DocumentNode.Scalar then
      table.insert(lines, indent .. "type = Scalar")
      table.insert(lines, indent .. string.format("content = '%s'", t.content))
      return lines

    elseif t.type == DocumentNode.Sequence then
      table.insert(lines, indent .. "type = Sequence")
      table.insert(lines, indent .. "content = {")
      for _, node in ipairs(t.content) do
        table.insert(lines, indent .. "  {")
        for _, line in ipairs(impl(node, depth + 4)) do
          table.insert(lines, line)
        end
        table.insert(lines, indent .. "  }")
      end
      table.insert(lines, indent .. "}")
      return lines

    elseif t.type == DocumentNode.Mapping then
      table.insert(lines, indent .. "type = Mapping")
      table.insert(lines, indent .. "content = {")
      for _, node in ipairs(t.content) do
        table.insert(lines, indent .. "  {")
        for _, line in ipairs(impl(node, depth + 4)) do
          table.insert(lines, line)
        end
        table.insert(lines, indent .. "  }")
      end
      table.insert(lines, indent .. "}")
      return lines

    elseif t.type == DocumentNode.MappingEntry then
      table.insert(lines, indent .. "type = MappingEntry")
      table.insert(lines, indent .. "key = {")
      for _, line in ipairs(impl(t.key, depth + 2)) do
        table.insert(lines, line)
      end
      table.insert(lines, indent .. "}")
      table.insert(lines, indent .. "value = {")
      for _, line in ipairs(impl(t.value, depth + 2)) do
        table.insert(lines, line)
      end
      table.insert(lines, indent .. "}")
      return lines
    end
  end

  return table.concat(impl(tree, 0), "\n")
end

local BlockSequenceParserState = enum {
  "Finished",
  "FindIndent",
  "FindChildIndent",
  "ExpectEntry",
  "PostEntry",
}

local function parse_block_sequence(token_stream, indent, dispatch_fn)
  local state = BlockSequenceParserState.FindIndent
  local token_stream = assert(token_stream)
  local dispatch_fn = dispatch_fn or function (...) return nil end
  local indent = indent or 0

  local sequence_node = {
    type = DocumentNode.Sequence,
    content = {},
    indent = -1,
    child_indent = -1,
  }

  local parser
  parser = function ()
    if state == BlockSequenceParserState.Finished then return nil, "Parser finished" end

    local token = token_stream:next()
    if not token then
      state = BlockSequenceParserState.Finished
      return nil, "Nil token"
    end

    if state == BlockSequenceParserState.FindIndent and token.type == TokenType.BlockIndent then
      indent = token.indent
      return parser()

    elseif state == BlockSequenceParserState.FindIndent and token.type == TokenType.Seq then
      sequence_node.indent = indent
      state = BlockSequenceParserState.FindChildIndent
      return parser()

    elseif state == BlockSequenceParserState.FindIndent then
      return token, "Unsupported token; you may be using the wrong parser type"

    elseif state == BlockSequenceParserState.FindChildIndent  and token.type == TokenType.BlockIndent then
      indent = token.indent
      return parser()

    elseif state == BlockSequenceParserState.FindChildIndent then
      if indent < sequence_node.indent then return token, "Sequence entries cannot be empty" end
      if indent == sequence_node.indent then indent = token.col - 1 end
      sequence_node.child_indent = indent
      token_stream:push(token)
      state = BlockSequenceParserState.ExpectEntry
      return parser()

    elseif state == BlockSequenceParserState.ExpectEntry and is_scalar_token(token) then
      if indent == sequence_node.indent then indent = token.col - 1 end
      if indent ~= sequence_node.child_indent then return token, "Ambiguous indentation" end
      table.insert(sequence_node.content, {
        type = DocumentNode.Scalar,
        content = token.text,
        indent = indent,
        _token = token,
      })
      state = BlockSequenceParserState.PostEntry
      return parser()

    elseif state == BlockSequenceParserState then
      error "Not implemented"

    elseif state == BlockSequenceParserState.PostEntry and token.type == TokenType.BlockIndent then
      indent = token.indent
      return parser()

    elseif state == BlockSequenceParserState.PostEntry and token.type == TokenType.DocumentEnd then
      state = BlockSequenceParserState.Finished
      return sequence_node

    elseif state == BlockSequenceParserState.PostEntry and token.type == TokenType.Seq and indent > sequence_node.indent then
      return token, "Bad indentation in sequence"

    elseif state == BlockSequenceParserState.PostEntry and token.type == TokenType.Seq and indent == sequence_node.indent then
      state = BlockSequenceParserState.ExpectEntry
      return parser()

    elseif state == BlockSequenceParserState.PostEntry and token.type == TokenType.Seq then
      token_stream:push(token)
      state = BlockSequenceParserState.Finished
      return sequence_node

    elseif state == BlockSequenceParserState.PostEntry and token.type == TokenType.MapValue then
      error "Not implemented"

    elseif state == BlockSequenceParserState.PostEntry then
      return token, "Unexpected"
    end

    if DEBUG then error "Unreachable" end
  end

  return parser()
end

local BlockMappingParserState = enum {
  "Finished",
  "ExpectMapValueToken",
  "ExpectMappingValue",
  "PostValue",
}

local function parse_block_mapping(token_stream, initial_node, dispatch_fn)
  local state = BlockMappingParserState.ExpectMapValueToken
  local token_stream = assert(token_stream)
  local dispatch_fn = dispatch_fn or function (...) return nil end

  if initial_node.type ~= DocumentNode.Scalar then error "Initial mapping key must be a scalar" end

  local mapping_node = {
    type = DocumentNode.Mapping,
    content = {
      {
        type = DocumentNode.MappingEntry,
        key = initial_node,
        value = {},
        indent = initial_node.indent,
      },
    },
    indent = initial_node.indent,
  }
  local indent = initial_node.indent

  local set_last_value = function (val)
    mapping_node.content[#mapping_node.content].value = val
  end

  local parser
  parser = function ()
    if state == BlockMappingParserState.Finished then return nil, "Parser finished" end

    local token = token_stream:next()
    if not token then
      state = BlockMappingParserState.Finished
      return nil, "Nil token"
    end

    if state == BlockMappingParserState.ExpectMapValueToken and token.type == TokenType.MapValue then
      state = BlockMappingParserState.ExpectMappingValue
      return parser()

    elseif state == BlockMappingParserState.ExpectMapValueToken then
      return token, string.format("Expected mapping indicator '%s'", INDICATORS.MAP_VALUE)

    elseif state == BlockMappingParserState.ExpectMappingValue and token.type == TokenType.BlockIndent then
      indent = token.indent
      return parser()

    elseif state == BlockMappingParserState.ExpectMappingValue and is_scalar_token(token) then
      set_last_value {
        type = DocumentNode.Scalar,
        content = token.text,
        indent = indent,
        _token = token,
      }
      state = BlockMappingParserState.PostValue
      return parser()

    elseif state == BlockMappingParserState.ExpectMappingValue and token.type == TokenType.MapValue then
      state = BlockMappingParserState.Finished
      return token, "Unexpected symbol after mapping indicator"

    elseif state == BlockMappingParserState.ExpectMappingValue and token.type == TokenType.DocumentEnd then
      state = BlockMappingParserState.Finished
      return token, "Expected a value for mapping"

    elseif state == BlockMappingParserState.ExpectMappingValue then
      error "Not implemented"

    elseif state == BlockMappingParserState.PostValue and token.type == TokenType.BlockIndent then
      indent = token.indent
      return parser()

    elseif state == BlockMappingParserState.PostValue and token.type == TokenType.DocumentEnd then
      state = BlockMappingParserState.Finished
      return mapping_node

    elseif state == BlockMappingParserState.PostValue and is_scalar_token(token) and indent >= mapping_node.indent then
      table.insert(mapping_node.content, {
        type = DocumentNode.MappingEntry,
        key = {
          type = DocumentNode.Scalar,
          content = token.text,
          indent = indent,
        },
        value = {},
        indent = indent,
      })
      state = BlockMappingParserState.ExpectMapValueToken
      return parser()

    elseif state == BlockMappingParserState.PostValue and is_scalar_token(token) and indent < mapping_node.indent then
      state = BlockMappingParserState.Finished
      return mapping_node
    end
  end

  return parser()
end

local function parse_document(token_stream)
  local token_stream = assert(token_stream)
  local doc, root_type

  local indent = 0

  local parser, parse_token

  parse_token = function (token)
    if token.type == TokenType.BlockIndent then
      indent = token.indent
      return parser()

    elseif token.type == TokenType.DocumentEnd then
      return doc or {}

    elseif token.type == TokenType.Seq and not root_type then
      root_type = DocumentNode.Sequence
      token_stream:push(token)
      local token_or_doc, err = parse_block_sequence(token_stream, indent, parse_token)
      if err then return token_or_doc, err end
      doc = token_or_doc
      return parser()

    elseif token.type == TokenType.Seq then
      return token, "Cannot have mixed sequences and mappings at the document root"

    elseif is_scalar_token(token) and root_type ~= DocumentNode.Sequence then
      root_type = DocumentNode.Scalar
      doc = {
        type = DocumentNode.Scalar,
        content = token.text,
        indent = indent,
        _token = token,
      }
      return parser()

    elseif is_scalar_token(token) then
      return token, "Cannot have mixed sequences and mappings at the document root"

    elseif token.type == TokenType.MapValue and root_type == DocumentNode.Scalar then
      root_type = DocumentNode.Mapping
      token_stream:push(token)
      local token_or_doc, err = parse_block_mapping(token_stream, doc, parse_token)
      if err then return token_or_doc, err end
      doc = token_or_doc
      return parser()

    else
      error "Not implemented"
    end

    if DEBUG then error "Unreachable" end
  end

  parser = function ()
    local token = token_stream:next()
    if not token then
      return doc or {}
    end

    return parse_token(token)
  end

  local token_or_document_node, err = parser()
  if err then
    return token_or_document_node, err
  else
    return {
      type = DocumentNode.Root,
      content = token_or_document_node,
    }
  end

  return parser()
end












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
  "ExpectFlowMapValueIndicator",
  "ExpectFlowMapValue",
  "PostFlowMapValue",
  "PostFlowSequenceEntry",
  "ExpectFoldIndent",
  "FoldedScalarParagraphStart",
  "FoldedScalarIndentedParagraph",
  "FoldedScalarParagraph",
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
  setmetatable(DocumentNode, _debug_restrict_accessor_tbl)
  setmetatable(ParserContext, _debug_restrict_accessor_tbl)
  setmetatable(BlockSequenceParserState, _debug_restrict_accessor_tbl)
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
    folded_indent = 0,
  }
  setmetatable(obj, {__index = self})
  return obj
end

function Parser:set_context(context)
  self.context, _ = dassert(context, "Not a member of ParserContext")
end

-- Nest a child node within a parent and return the result
local function adopt_node(parent, child)
  if parent.type == DocumentNode.Sequence then
    table.insert(parent.content, child)
  elseif parent.type == DocumentNode.Mapping then
    dassert(child.type == DocumentNode.MappingEntry)
    table.insert(parent.content, child)
  elseif parent.type == DocumentNode.Root then
    parent.content = child
  elseif parent.type == DocumentNode.MappingEntry then
    parent.value = child
  else
    if TRACE then
      print(string.format("parent DocumentNode.%s, child DocumentNode.%s", enum_to_string(DocumentNode, parent.type), enum_to_string(DocumentNode, child.type)))
    end
    error "Invalid token type for parent node"
  end
  return parent
end

-- Return the indent of the node at the top of the node stack
function Parser:get_last_node()
  return dassert(self.node_stack[#self.node_stack])
end

-- Pop the nodes of the stack and adopt them as child nodes until the indent
-- level of the top node in the stack matches the received indent
function Parser:pop_stack_to_indent_level(indent)
  local prev_indent = dassert(self:get_last_node().indent)
  while indent ~= prev_indent do
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
    type = DocumentNode.Root,
    content = table.remove(self.node_stack) or {}
  }
end

-- Fold lines according to folded scalar rules
local function fold_lines(lines)
  local nlines = #lines
  if nlines == 0 then return "" end
  if nlines == 1 then return lines[1] end
  local text = lines[1]
  local was_last_indented = false
  for i = 2, nlines do
    local l = lines[i]
    if l:find("^ ") then
      text = text .. "\n" .. l
      was_last_indented = true
    elseif l:find("^$") then
      text = text .. "\n"
    elseif was_last_indented then
      text = text .. "\n" .. l
      was_last_indented = false
    elseif text:find("\n$") then
      text = text .. l
    else
      text = text .. " " .. l
    end
  end
  return text
end

if DEBUG then
  M.fold_lines = fold_lines
end

-- Fold the lines table in the received token to its text field and return the result
local function fold_lines_in_token(token)
  token.text = fold_lines(dassert(token.lines))
  return token
end

-- TODO test TokenType coverage
-- TODO test ParserContext coverage
-- TODO better error handling
function Parser:parse_token(token)
  local ttype = dassert(token.type)
  if self.context == ParserContext.Finished then return end

  if TRACE then
    print("TRACE: " .. print_token(token))
    print("TRACE: " .. enum_to_string(ParserContext, self.context))
  end

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
      self.tokeniser:use_folded_context()
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectFoldIndent)

    elseif ttype == TokenType.MapValue then
      local key_node = dassert(table.remove(self.node_stack))
      self:push_node_to_stack{
        type = DocumentNode.Mapping,
        content = {},
        indent = self.current_indent,
        _token = token,
      }
      self:push_node_to_stack{
        type = DocumentNode.MappingEntry,
        key = key_node,
        value = {},
        indent = self.current_indent,
        _token = token,
      }
      return self:set_context(ParserContext.ExpectMappingValue)

    elseif ttype == TokenType.SeqBegin then
      self:push_node_to_stack{
        type = DocumentNode.Sequence,
        content = {},
        indent = self.current_indent,
        _restore_context = self.context,
        _token = token,
      }
      self.tokeniser:use_flow_context()
      return self:set_context(ParserContext.InFlowSequence)

    elseif ttype == TokenType.MapBegin then
      self:push_node_to_stack{
        type = DocumentNode.Mapping,
        content = {},
        indent = self.current_indent,
        _restore_context = self.context,
        _token = token,
      }
      self.tokeniser:use_flow_context()
      return self:set_context(ParserContext.InFlowMapping)

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
        type = DocumentNode.Sequence,
        content = {},
        indent = self.current_indent,
        child_indent = 0,
        _token = token,
      }
      return self:set_context(ParserContext.DetermineBlockSequenceIndent)

    elseif is_scalar_token(token) then
      dassert(#self.node_stack == 0, "Unexpected token")
      self:push_node_to_stack{
        type = DocumentNode.Scalar,
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
    dassert(parent.type == DocumentNode.Sequence)
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
        type = DocumentNode.Scalar,
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

    elseif ttype == TokenType.SeqBegin then
      error "Not implemented"

    elseif ttype == TokenType.MapBegin then
      error "Not implemented"

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
      local key_node = dassert(table.remove(self.node_stack))
      self:push_node_to_stack{
        type = DocumentNode.Mapping,
        content = {},
        indent = self.current_indent,
        _token = token,
      }
      self:push_node_to_stack{
        type = DocumentNode.MappingEntry,
        key = key_node,
        value = {},
        indent = self.current_indent,
        _token = token,
      }
      return self:set_context(ParserContext.ExpectMappingValue)

    elseif ttype == TokenType.Seq then
      local parent = dassert(self:get_last_node())
      if parent.type == DocumentNode.Scalar then
        self:pop_and_adopt()
        parent = dassert(self:get_last_node())
      end

      dassert(self.current_indent <= parent.indent, "Ambiguous indentation")
      if self.current_indent == parent.indent then
        return self:set_context(ParserContext.ExpectSequenceEntry)
      else
        self.token_stream:push(token)
        self:pop_stack_to_indent_level(self.current_indent)
        parent = dassert(self:get_last_node())

        if parent.type == DocumentNode.Sequence then
          return self:set_context(ParserContext.HandleSequenceContinuation)
        elseif parent.type == DocumentNode.Mapping then
          return self:set_context(ParserContext.HandleMappingContinuation)
        elseif parent.type == DocumentNode.MappingEntry then
          return self:set_context(ParserContext.HandleMappingContinuation)
        elseif parent.type == DocumentNode.Root then
          return self:set_context(ParserContext.AtRoot)
        else
          error "Invalid node stack"
        end
      end

    else
      local parent = dassert(self:get_last_node())
      if self.current_indent >= parent.indent then error "Unexpected token in sequnce" end
      self:pop_stack_to_indent_level(self.current_indent)
      parent = dassert(self:get_last_node())
      self.token_stream:push(token)

      if parent.type == DocumentNode.Sequence then
        return self:set_context(ParserContext.HandleSequenceContinuation)
      elseif parent.type == DocumentNode.Mapping then
        return self:set_context(ParserContext.HandleMappingContinuation)
      elseif parent.type == DocumentNode.MappingEntry then
        return self:set_context(ParserContext.HandleMappingContinuation)
      elseif parent.type == DocumentNode.Root then
        return self:set_context(ParserContext.AtRoot)
      else
        error "Invalid node stack"
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
      self.tokeniser:use_folded_context()
      self.restore_context = self.context
      return self:set_context(ParserContext.ExpectFoldIndent)

    elseif ttype == TokenType.MapValue then
      error "Not implemented"

    elseif ttype == TokenType.SeqBegin then
      self:push_node_to_stack{
        type = DocumentNode.Sequence,
        content = {},
        indent = self.current_indent,
        _restore_context = ParserContext.HandleMappingContinuation,
        _token = token,
      }
      self.tokeniser:use_flow_context()
      return self:set_context(ParserContext.InFlowSequence)

    elseif ttype == TokenType.MapBegin then
      self:push_node_to_stack{
        type = DocumentNode.Mapping,
        content = {},
        indent = self.current_indent,
        _restore_context = ParserContext.HandleMappingContinuation,
        _token = token,
      }
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
      self:push_node_to_stack{
        type = DocumentNode.Sequence,
        content = {},
        indent = self.current_indent,
        child_indent = 0,
        _token = token,
      }
      return self:set_context(ParserContext.DetermineBlockSequenceIndent)

    elseif is_scalar_token(token) then
      self:push_node_to_stack{
        type = DocumentNode.Scalar,
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
      local key_node = dassert(table.remove(self.node_stack))
      self:push_node_to_stack{
        type = DocumentNode.Mapping,
        indent = self.current_indent,
        content = {},
        _token = token,
      }
      self:push_node_to_stack{
        type = DocumentNode.MappingEntry,
        indent = self.current_indent,
        key = key_node,
        value = {},
        _token = token,
      }
      return self:set_context(ParserContext.ExpectMappingValue)

    elseif is_scalar_token(token) then
      local parent = dassert(self:get_last_node())
      if parent.type == DocumentNode.Scalar then
        self:pop_and_adopt()
        parent = dassert(self:get_last_node())
      end

      if parent.type == DocumentNode.MappingEntry then
        self:pop_and_adopt()
        parent = dassert(self:get_last_node())
      end

      dassert(self.current_indent <= parent.indent, "Ambiguous indentation")
      if self.current_indent == parent.indent then
        self:push_node_to_stack{
          type = DocumentNode.MappingEntry,
          key = {
            type = DocumentNode.Scalar,
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
        self:pop_and_adopt(self.current_indent)
        parent = dassert(self:get_last_node())
        if parent.type == DocumentNode.Sequence then
          return self:set_context(ParserContext.HandleSequenceContinuation)
        elseif parent.type == DocumentNode.MappingEntry then
          return self:set_context(ParserContext.HandleMappingContinuation)
        elseif parent.type == DocumentNode.Root then
          return self:set_context(ParserContext.AtRoot)
        else error "Invalid node stack"
        end
      end

    else
      local parent = dassert(self:get_last_node())
      if self.current_indent >= parent.indent then error "Unexpected token after mapping" end
      self:pop_stack_to_indent_level(self.current_indent)
      parent = dassert(self:get_last_node())
      self.token_stream:push(token)

      if parent.type == DocumentNode.Sequence then
        return self:set_context(ParserContext.HandleSequenceContinuation)
      elseif parent.type == DocumentNode.Mapping then
        return self:set_context(ParserContext.HandleMappingContinuation)
      elseif parent.type == DocumentNode.MappingEntry then
        return self:set_context(ParserContext.HandleMappingContinuation)
      elseif parent.type == DocumentNode.Root then
        return self:set_context(ParserContext.AtRoot)
      else error "Invalid node stack"
      end
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
    if ttype == TokenType.DocumentEnd then
      error "Expected end of sequence indicator"

    elseif ttype == TokenType.SingleQuote then
      error "Not implemented"

    elseif ttype == TokenType.DoubleQuote then
      error "Not implemented"

    elseif ttype == TokenType.SeqBegin then
      self:push_node_to_stack{
        type = DocumentNode.Sequence,
        content = {},
        _token = token,
        _restore_context = ParserContext.PostFlowSequenceEntry,
      }
      return self:set_context(ParserContext.InFlowSequence)

    elseif ttype == TokenType.SeqEnd then
      local parent = dassert(self:get_last_node())
      return self:set_context(dassert(parent._restore_context))

    elseif ttype == TokenType.MapBegin then
      self:push_node_to_stack{
        type = DocumentNode.Mapping,
        content = {},
        _token = token,
        _restore_context = ParserContext.PostFlowSequenceEntry,
      }
      return self:set_context(ParserContext.InFlowMapping)

    elseif ttype == TokenType.MapEnd then
      error "Unexpected end of mapping indicator in sequence"

    elseif ttype == TokenType.Collect then
      error "Expected a value; got a separator"

    elseif ttype == TokenType.Anchor then
      error "Not implemented"

    elseif ttype == TokenType.Alias then
      error "Not implemented"

    elseif is_scalar_token(token) then
      self:push_node_to_stack{
        type = DocumentNode.Scalar,
        content = dassert(token.text),
        _token = token,
      }
      return self:set_context(ParserContext.PostFlowSequenceEntry)

    else error "Unexpected token"
    end

  elseif self.context == ParserContext.PostFlowSequenceEntry then
    if ttype == TokenType.SeqEnd then
      self.token_stream:push(token)
      self.token_stream:push{ type = TokenType.Collect, }
      return

    elseif ttype == TokenType.Collect then
      self:pop_and_adopt()
      return self:set_context(ParserContext.InFlowSequence)

    else error "Unexpected token"
    end

  elseif self.context == ParserContext.InFlowMapping then
    if ttype == TokenType.DocumentEnd then
      error "Expected end of sequence indicator"

    elseif ttype == TokenType.SingleQuote then
      error "Not implemented"

    elseif ttype == TokenType.DoubleQuote then
      error "Not implemented"

    elseif ttype == TokenType.SeqEnd then
      error "Unexpected end of sequence indicator in mapping"

    elseif ttype == TokenType.MapEnd then
      local parent = dassert(self:get_last_node())
      return self:set_context(dassert(parent._restore_context))

    elseif is_scalar_token(token) then
      self:push_node_to_stack{
        type = DocumentNode.MappingEntry,
        key = {
          type = DocumentNode.Scalar,
          content = dassert(token.text),
          _token = token,
        },
        value = {},
      }
      return self:set_context(ParserContext.ExpectFlowMapValueIndicator)

    else error "Unexpected token; note that only scalars can be used as mapping keys"
    end

  elseif self.context == ParserContext.ExpectFlowMapValueIndicator then
    if ttype ~= TokenType.MapValue then error "Expected mapping indicator" end
    return self:set_context(ParserContext.ExpectFlowMapValue)

  elseif self.context == ParserContext.ExpectFlowMapValue then
    if ttype == TokenType.SeqBegin then
      self:push_node_to_stack{
        type = DocumentNode.Sequence,
        content = {},
        _token = token,
        _restore_context = ParserContext.PostFlowMapValue,
      }
      return self:set_context(ParserContext.InFlowSequence)

    elseif ttype == TokenType.MapBegin then
      self:push_node_to_stack{
        type = DocumentNode.Mapping,
        content = {},
        _token = token,
        _restore_context = ParserContext.PostFlowMapValue,
      }
      return self:set_context(ParserContext.InFlowMapping)

    elseif ttype == TokenType.Anchor then
      error "Not implemented"

    elseif ttype == TokenType.Alias then
      error "Not implemented"

    elseif is_scalar_token(token) then
      self:push_node_to_stack{
        type = DocumentNode.Scalar,
        content = dassert(token.text),
        _token = token,
      }
      return self:set_context(ParserContext.PostFlowMapValue)

    else error "Unexpected token"
    end

  elseif self.context == ParserContext.PostFlowMapValue then
    if ttype == TokenType.Collect then
      self:pop_and_adopt()
      self:pop_and_adopt()
      return self:set_context(ParserContext.InFlowMapping)

    elseif ttype == TokenType.MapEnd then
      self.token_stream:push(token)
      self.token_stream:push{ type = TokenType.Collect, }
      return

    else error "Unexpected token"
    end

  -- folded token parsing behaves differently to the rest of the function so
  -- maybe could be its own thing
  elseif self.context == ParserContext.ExpectFoldIndent then
    if ttype == TokenType.FoldNewline then return end
    if ttype ~= TokenType.FoldIndent then error "Expected indented line after fold indicator" end
    self.current_scalar_token = {
      type = TokenType.PlainScalar,
      indent = self.current_indent,
      lines = {},
    }
    self.current_indent = dassert(token.indent)
    return self:set_context(ParserContext.FoldedScalarParagraph)

  elseif self.context == ParserContext.FoldedScalarParagraphStart then
    if ttype == TokenType.FoldIndent then
      self.current_indent = dassert(token.indent)
      if self.current_indent > 0 then
        return self:set_context(ParserContext.FoldedScalarIndentedParagraph)
      else
        return self:set_context(ParserContext.FoldedScalarParagraph)
      end

    elseif ttype == TokenType.FoldLine then
      error "Expected indent token before line"

    elseif ttype == TokenType.FoldNewline then
      return table.insert(self.current_scalar_token.lines, "")

    elseif ttype == TokenType.FoldEnd then
      self.tokeniser:use_block_context()
      self.current_indent = self.current_scalar_token.indent
      self.token_stream:push(fold_lines_in_token(self.current_scalar_token))
      local restore_context = dassert(self.restore_context)
      self.restore_context = nil
      return self:set_context(restore_context)

    elseif DEBUG and ttype == TokenType.DocumentEnd then return
    elseif DEBUG then error "Unreachable"
    end

  elseif self.context == ParserContext.FoldedScalarIndentedParagraph then
    if ttype == TokenType.FoldIndent then
      self.current_indent = dassert(token.indent)
      return

    elseif ttype == TokenType.FoldLine then
      table.insert(self.current_scalar_token.lines, string.rep(" ", self.current_indent) .. dassert(token.text))
      return

    elseif ttype == TokenType.FoldNewline then
      table.insert(self.current_scalar_token.lines, "")
      return self:set_context(ParserContext.FoldedScalarParagraphStart)

    elseif ttype == TokenType.FoldEnd then
      self.tokeniser:use_block_context()
      self.current_indent = self.current_scalar_token.indent
      self.token_stream:push(fold_lines_in_token(self.current_scalar_token))
      local restore_context = dassert(self.restore_context)
      self.restore_context = nil
      return self:set_context(restore_context)

    elseif DEBUG and ttype == TokenType.DocumentEnd then return
    elseif DEBUG then error "Unreachable"
    end

  elseif self.context == ParserContext.FoldedScalarParagraph then
    if ttype == TokenType.FoldIndent then return

    elseif ttype == TokenType.FoldLine then
      table.insert(self.current_scalar_token.lines, dassert(token.text))
      return

    elseif ttype == TokenType.FoldNewline then
      table.insert(self.current_scalar_token.lines, "")
      return self:set_context(ParserContext.FoldedScalarParagraphStart)

    elseif ttype == TokenType.FoldEnd then
      self.tokeniser:use_block_context()
      self.current_indent = self.current_scalar_token.indent
      self.token_stream:push(fold_lines_in_token(self.current_scalar_token))
      local restore_context = dassert(self.restore_context)
      self.restore_context = nil
      return self:set_context(restore_context)

    elseif DEBUG and ttype == TokenType.DocumentEnd then return
    elseif DEBUG then error "Unreachable"
    end
  end

  if DEBUG then error "Unreachable" end
end

-- Module Exports
M.Tokeniser           = Tokeniser
M.TokenType           = TokenType
M.DocumentNode        = DocumentNode
M.BlockSequenceParser = BlockSequenceParser
M.Parser              = Parser

M.tokeniser_stream_adaptor = tokeniser_stream_adaptor

M.parse_block_sequence = parse_block_sequence
M.parse_block_mapping  = parse_block_mapping
M.parse_document       = parse_document

if DEBUG then
  M.TokeniserState           = TokeniserState
  M.BlockSequenceParserState = BlockSequenceParserState
  M.ParserContext            = ParserContext

  M.print_tokeniser     = print_tokeniser
  M.print_token         = print_token
  M.print_document_tree = print_document_tree
end

return M
