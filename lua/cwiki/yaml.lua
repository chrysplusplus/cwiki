-- Lightweight YAML parser, or subset thereof
-- author: chrysplusplus

-- TODO:
-- - Add UTF-8 support

local M = {}

--local stream = require "cwiki.stream" -- too complex ??
local util = require "cwiki.util"
local enum = util.enum

local TokenType = enum{
  "Unknown",
  "Comment", "Scalar",
  "ScalarQuote", "ScalarLiteral", "ScalarFolded",
  "MapKey", "MapVal", "Seq",
  "MapBegin", "MapSep", "MapEnd",
  "SeqBegin", "SeqSep", "SeqEnd",
  "AnchorDef", "AnchorRef"
}

local TokeniserState = enum{
  "Indent", "Normal",
  "QuotedScalar", "ScalarLiteral", "ScalarFolded",
  "FlowMap", "FlowSeq",
  "Done"
}

local Tokeniser = {}

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

-- Advance the index to the next non-whitespace character; return the new index
local function consume_whitespace(s, idx)
  local i, _ = s:find("%S", idx)
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

function Tokeniser:new(s)
  local ret = {
    source = s,
    state = TokeniserState.Indent,
    index = 1,
  }
  setmetatable(ret, {__index = self})
  return ret
end

function Tokeniser:next()
  if self.state == TokeniserState.Done then
    return nil

  elseif self.state == TokeniserState.Indent then
    self.index = consume_whitespace(self.source, self.index)
    self.state = TokeniserState.Normal
    return self:next()

  elseif self.state == TokeniserState.Normal then
    local ch = peek(self.source, self.index)
    if #ch == 0 then
      self.state = TokeniserState.Done
      return nil

    elseif ch == "#" then
      local i, commentstring
      i, commentstring = consume_line(self.source, self.index)
      self.index = i
      return { type = TokenType.Comment, text = commentstring }

    elseif ch == '"' then
      self.index = self.index + 1
      self.state = TokeniserState.QuotedScalar
      return { type = TokenType.ScalarQuote, text = '"' }

    elseif ch == "|" then
      self.index, _ = consume_line(self.source, self.index)
      self.state = TokeniserState.ScalarLiteral
      return { type = TokenType.ScalarLiteral, text = "|" }

    elseif ch == ">" then
      self.index, _ = consume_line(self.source, self.index)
      self.state = TokeniserState.ScalarFolded
      return { type = TokenType.ScalarFolded, text = ">" }

    elseif ch == "?" then
      self.index = consume_whitespace(self.source, self.index + 1)
      return { type = TokenType.MapKey, text = "?" }

    elseif ch == ":" then
      self.index = consume_whitespace(self.source, self.index + 1)
      return { type = TokenType.MapVal, text = ":" }

    elseif ch == "-" then
      self.index = consume_whitespace(self.source, self.index + 1)
      return { type = TokenType.Seq, text = "-" }

    elseif ch == "{" then
      self.index, _ = consume_whitesapce(self.source, self.index + 1)
      self.state = TokeniserState.FlowMap
      return { type = TokenType.MapBegin, text = "{" }

    elseif ch == "," then
      self.state = TokeniserState.Done
      return { type = TokenType.Unknown, text = self.source:sub(self.index) }

    elseif ch == "}" then
      self.state = TokeniserState.Done
      return { type = TokenType.Unknown, text = self.source:sub(self.index) }

    elseif ch == "[" then
      self.index = consume_whitespace(self.source, self.index + 1)
      self.state = TokeniserState.FlowSeq
      return { type = TokenType.SeqBegin, text = "[" }

    elseif ch == "]" then
      self.state = TokeniserState.Done
      return { type = TokenType.Unknown, text = self.source:sub(self.index) }

    -- elseif ch == "&" then
    --   local i = consume_whitespace(self.source, self.index + 1)

    else
      self.state = TokeniserState.Done
      return { type = TokenType.Unknown, text = self.source:sub(self.index) }
    end

  else
    assert(false, "Unreachable")
  end
end

M.Tokeniser = Tokeniser
M.TokenType = TokenType
return M
