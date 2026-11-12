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
  "Error",
  "Indent",
  "LineBreak",
  "DocumentEnd",
  "SeqIndicator",
  "SeqEntry",
  "MapKey",
}

local TokeniserState = enum{
  "Finished",
  "ParseIndent",
  "ExpectPlainOrIndicator",
  "ExpectSeqSepOrFallback",
  "ExpectSeqEntryStart",
  "ExpectSeqEntry",
  "EmitMap",
  "EmitDocumentEnd",
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

    print("{ " .. table.concat(keyvals, ", ") .. " }")
  end
end

local Tokeniser = {}
function Tokeniser:new(s)
  local ret = {
    source = s,
    state = TokeniserState.ParseIndent,
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

-- Set the TokeniserState to `next_state`, then return a new token of type
-- `type` with optional values
--
-- Note: the text key of the returned table is defaulted to an empty string if
-- not provided
function Tokeniser:emit_token(type, next_state, vars)
  assert(type)
  assert(next_state)
  local vars = vars or {}

  self.state = next_state
  local ret = { type = type }
  for k,v in pairs(vars) do
    assert(k ~= "type")
    ret[k] = v
  end

  ret.text = ret.text or ""
  return ret
end

-- Create fallback point for backtracking state but not the accumulator
function Tokeniser:create_fallback()
  table.insert(self.fallback_stack, self.state)
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

  elseif self.state == TokeniserState.ParseIndent then
    local new_index = consume_indent(self.source, self.index)
    local indent = new_index - self.index
    self.index = new_index
    return self:emit_token(TokenType.Indent, TokeniserState.ExpectPlainOrIndicator, { indent = indent })

  elseif self.state == TokeniserState.ExpectPlainOrIndicator then
    if ch == INDICATORS.MAP_VALUE or ch == INDICATORS.SEQ_END or ch == INDICATORS.MAP_END or ch == INDICATORS.COLLECT then
      return self:emit_error_token("Unexpected symbol")

    elseif ch == INDICATORS.EOF then
      return self:emit_token(TokenType.DocumentEnd, TokeniserState.Finished)

    elseif ch == INDICATORS.EOL then
      self.index = self.index + 1
      self:_line_start_at(self.index)
      return self:emit_token(TokenType.LineBreak, TokeniserState.ParseIndent)

    elseif ch == INDICATORS.COMMENT then
      self.index, _ = consume_line(self.source, self.index)
      self:_line_start_at(self.index)
      return self:emit_token(TokenType.LineBreak, TokeniserState.ParseIndent)

    elseif ch == INDICATORS.SINGLE_QUOTE then
      assert(false, "Not implemented")
    elseif ch == INDICATORS.DOUBLE_QUOTE then
      assert(false, "Not implemented")
    elseif ch == INDICATORS.FOLDED then
      assert(false, "Not implemented")

    elseif ch == INDICATORS.SEQ then
      local line, col = self:position()
      self.index = self.index + 1
      self:create_fallback()
      return self:emit_token(TokenType.SeqIndicator, TokeniserState.ExpectSeqSepOrFallback, { text = INDICATORS.SEQ, line = line, col = col })

    elseif ch == INDICATORS.SEQ_BEGIN then
      assert(false, "Not implemented")
    elseif ch == INDICATORS.MAP_BEGIN then
      assert(false, "Not implemented")
    elseif ch == INDICATORS.ANCHOR then
      assert(false, "Not implemented")
    elseif ch == INDICATORS.ALIAS then
      assert(false, "Not implemented")
    else
      assert(false, "Not implemented")
    end

  elseif self.state == TokeniserState.ExpectSeqSepOrFallback then
    -- YAML spec can have any amount of whitespace; I'm allowing one space only
    if ch == " " then
      self.index = self.index + 1
      self.state = TokeniserState.ExpectSeqEntryStart
      self:remove_fallback()
      return self:next()
    else -- assume seq indicator would match fallback state
      self.accumulator = self.accumulator .. INDICATORS.SEQ
      self:fall_back()
      return self:next()
    end

  elseif self.state == TokeniserState.ExpectSeqEntryStart then
    if util.contains({ INDICATORS.EOF, INDICATORS.EOL, INDICATORS.COMMENT, INDICATORS.MAP_VALUE, INDICATORS.SEQ_END, INDICATORS.MAP_END, INDICATORS.COLLECT }, ch) then
      return self:emit_error_token("Expected sequence entry")

    elseif ch == INDICATORS.SINGLE_QUOTE then
      assert(false, "Not implemented")
    elseif ch == INDICATORS.DOUBLE_QUOTE then
      assert(false, "Not implemented")
    elseif ch == INDICATORS.FOLDED then
      assert(false, "Not implemented")
    elseif ch == INDICATORS.SEQ_BEGIN then
      assert(false, "Not implemented")
    elseif ch == INDICATORS.MAP_BEGIN then
      assert(false, "Not implemented")
    elseif ch == INDICATORS.ANCHOR then
      assert(false, "Not implemented")
    elseif ch == INDICATORS.ALIAS then
      assert(false, "Not implemented")

    else
      self.accumulator = self.accumulator .. ch
      self.index = self.index + 1
      self.state = TokeniserState.ExpectSeqEntry
      return self:next()
    end

  elseif self.state == TokeniserState.ExpectSeqEntry then
    if util.contains({ INDICATORS.DOUBLE_QUOTE, INDICATORS.SEQ_BEGIN, INDICATORS.SEQ_END, INDICATORS.MAP_BEGIN, INDICATORS.MAP_END, INDICATORS.COLLECT }, ch) then
      return self:emit_error_token("Symbol not allowed in plain scalars; use quotes")

    elseif ch == INDICATORS.EOF then
      local text = trim_trailing(self.accumulator)
      self.accumulator = ""
      return self:emit_token(TokenType.SeqEntry, TokeniserState.EmitDocumentEnd, {text = text })

    elseif ch == INDICATORS.EOL then
      local text = trim_trailing(self.accumulator)
      self.accumulator = ""
      self.index = self.index + 1
      return self:emit_token(TokenType.SeqEntry, TokeniserState.ParseIndent, { text = text })

    elseif ch == INDICATORS.COMMENT then
      local text = trim_trailing(self.accumulator)
      self.accumulator = ""
      self.index = consume_line(self.source, self.index)
      return self:emit_token(TokenType.SeqEntry, TokeniserState.ParseIndent, { text = text })

    elseif ch == INDICATORS.FOLDED then
      assert(false, "Not implemented")

    elseif ch == INDICATORS.MAP_VALUE then
      local text = trim_trailing(self.accumulator)
      self.accumulator = ""
      return self.emit_token(TokenType.MapKey, TokeniserState.EmitMap, { text = text })

    else
      self.accumulator = self.accumulator .. ch
      self.index = self.index + 1
      return self:next()
    end

  elseif self.state == TokeniserState.EmitMap then
    assert(false, "Not implemented")

  elseif self.state == TokeniserState.EmitDocumentEnd then
    return self:emit_token(TokenType.DocumentEnd, TokeniserState.Finished)

  else
    assert(false, "Unreachable")
  end
end

M.Tokeniser = Tokeniser
M.TokenType = TokenType
return M
