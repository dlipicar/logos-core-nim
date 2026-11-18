## INTERFACE §3: the reverse mapper's C tokens.
##
## [SPEC INTERFACE §3, §3.1] The reverse mapping reads a source-level C profile
## without a preprocessor. This module performs the C17 translation phases that
## the profile needs and nothing more: phase 1 without trigraphs (IF l.2564; one
## is rejected rather than replaced), phase 2 (a backslash-newline is deleted) and
## phase 3 (each comment becomes one space, and the text is split into
## preprocessing tokens). Macros are never expanded and includes are never read
## here; `cparse` interprets directive lines and `rmap` resolves includes.
##
## [IMPL] The source must be UTF-8 (IF l.2563, IFC-0852) without NUL bytes; a
## leading UTF-8 byte-order mark is skipped. Line ends are LF or CRLF. Bytes above
## ASCII may appear only in comments and in string or character literals.

{.push raises: [].}

import std/strutils
import results
import ./creject

export results, creject

type
  TokenKind* = enum
    tkIdent ## an identifier or keyword
    tkNumber ## a preprocessing number
    tkString ## a string literal with its prefix, if any, and its quotes
    tkChar ## a character constant with its prefix, if any
    tkPunct ## a punctuator

  Token* = object
    kind*: TokenKind
    text*: string ## the spelling after line splicing
    line*: int ## the source line of its first character, 1-based
    lineStart*: bool ## the first token of its logical line
    spaceBefore*: bool ## whitespace or a comment precedes it on its line

const
  Punctuators3 = ["...", "<<=", ">>=", "%:%:"]
  Punctuators2 = [
    "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "*=", "/=", "%=",
    "+=", "-=", "&=", "^=", "|=", "##", "<:", ":>", "<%", "%>", "%:", "::",
  ]
  Punctuators1 = "[](){}.&*+-~!/%<>^|?:;=,#"
  TrigraphEnds = "=/'()!<>-"

func validUtf8(s: string): bool =
  var i = 0
  while i < s.len:
    let c = ord(s[i])
    var n = 0
    var lo = 0x80
    var hi = 0xBF
    if c < 0x80:
      inc i
      continue
    elif c >= 0xC2 and c <= 0xDF:
      n = 1
    elif c == 0xE0:
      n = 2
      lo = 0xA0
    elif c >= 0xE1 and c <= 0xEC or c == 0xEE or c == 0xEF:
      n = 2
    elif c == 0xED:
      n = 2
      hi = 0x9F
    elif c == 0xF0:
      n = 3
      lo = 0x90
    elif c >= 0xF1 and c <= 0xF3:
      n = 3
    elif c == 0xF4:
      n = 3
      hi = 0x8F
    else:
      return false
    if i + n > s.high:
      return false
    for k in 1 .. n:
      let b = ord(s[i + k])
      if k == 1:
        if b < lo or b > hi:
          return false
      elif b < 0x80 or b > 0xBF:
        return false
    i += n + 1
  true

func isUtf8*(s: string): bool =
  ## [SPEC INTERFACE §3.5 l.2562] well-formed UTF-8 (no surrogates, no overlongs).
  validUtf8(s)

proc splice(header, source: string): Result[(seq[char], seq[int]), Rejection] =
  ## Phases 1 and 2: line ends normalized to LF, each backslash-newline deleted;
  ## every remaining character keeps its source line.
  var chars: seq[char] = @[]
  var lines: seq[int] = @[]
  var line = 1
  var i = 0
  if source.startsWith("\xEF\xBB\xBF"):
    i = 3
  while i < source.len:
    let c = source[i]
    if c == '\0':
      return err(reject(rkSourceEncoding, header, line, "a NUL byte in the source"))
    if c == '?' and i + 2 < source.len and source[i + 1] == '?' and
        source[i + 2] in TrigraphEnds:
      return err(
        reject(
          rkSourceEncoding,
          header,
          line,
          "trigraph ??" & source[i + 2] & " (outside the profile, IF l.2564)",
        )
      )
    if c == '\r':
      if i + 1 < source.len and source[i + 1] == '\n':
        inc i
        continue
      return err(reject(rkSourceEncoding, header, line, "a carriage return without LF"))
    if c == '\\':
      var j = i + 1
      if j < source.len and source[j] == '\r' and j + 1 < source.len and
          source[j + 1] == '\n':
        inc j
      if j < source.len and source[j] == '\n':
        inc line
        i = j + 1
        continue
    chars.add(c)
    lines.add(line)
    if c == '\n':
      inc line
    inc i
  ok((chars, lines))

func isIdentStart(c: char): bool =
  c in {'A' .. 'Z', 'a' .. 'z', '_'}

func isIdentChar(c: char): bool =
  c in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}

proc lex*(header, source: string): Result[seq[Token], Rejection] =
  ## [SPEC INTERFACE §3] The preprocessing tokens of one header body, after
  ## phases 1 to 3. `header` is the logical name used in rejections.
  if not validUtf8(source):
    return err(reject(rkSourceEncoding, header, 0, "the source is not UTF-8"))
  let (chars, lines) = ?splice(header, source)
  var toks: seq[Token] = @[]
  var atStart = true
  var space = false
  var i = 0
  template here(): int =
    lines[i]

  template add(k: TokenKind, a, b: int) =
    var s = newStringOfCap(b - a)
    for x in a ..< b:
      s.add(chars[x])
    toks.add(
      Token(kind: k, text: s, line: lines[a], lineStart: atStart, spaceBefore: space)
    )
    atStart = false
    space = false

  proc quoted(
      chars: seq[char], lines: seq[int], header: string, start: int, q: char
  ): Result[int, Rejection] =
    ## The index just past the closing quote of the literal opening at `start`.
    var j = start + 1
    while j < chars.len:
      let c = chars[j]
      if c == q:
        return ok(j + 1)
      if c == '\n':
        break
      if c == '\\' and j + 1 < chars.len and chars[j + 1] != '\n':
        j += 2
        continue
      inc j
    err(reject(rkLexical, header, lines[start], "an unterminated literal"))

  while i < chars.len:
    let c = chars[i]
    case c
    of '\n':
      atStart = true
      space = false
      inc i
    of ' ', '\t', '\v', '\f':
      space = true
      inc i
    of '/':
      if i + 1 < chars.len and chars[i + 1] == '/':
        while i < chars.len and chars[i] != '\n':
          inc i
        space = true
      elif i + 1 < chars.len and chars[i + 1] == '*':
        let start = i
        i += 2
        while i + 1 < chars.len and not (chars[i] == '*' and chars[i + 1] == '/'):
          inc i
        if i + 1 >= chars.len:
          return err(reject(rkLexical, header, lines[start], "an unterminated comment"))
        i += 2
        space = true
      else:
        let a = i
        inc i
        if i < chars.len and chars[i] == '=':
          inc i
        add(tkPunct, a, i)
    of '"', '\'':
      let a = i
      i = ?quoted(chars, lines, header, i, c)
      add(if c == '"': tkString else: tkChar, a, i)
    of '0' .. '9':
      let a = i
      inc i
      while i < chars.len:
        let d = chars[i]
        if d in {'e', 'E', 'p', 'P'} and i + 1 < chars.len and chars[i + 1] in {
          '+', '-'
        }:
          i += 2
        elif d.isIdentChar or d == '.':
          inc i
        elif d == '\'' and i + 1 < chars.len and chars[i + 1].isIdentChar:
          i += 2 # a C23 digit separator stays in the number (rejected by §3.5)
        else:
          break
      add(tkNumber, a, i)
    elif c.isIdentStart:
      let a = i
      while i < chars.len and chars[i].isIdentChar:
        inc i
      var word = newStringOfCap(i - a)
      for x in a ..< i:
        word.add(chars[x])
      if word in ["u8", "u", "U", "L"] and i < chars.len and chars[i] in {'"', '\''}:
        let q = chars[i]
        i = ?quoted(chars, lines, header, i, q)
        add(if q == '"': tkString else: tkChar, a, i)
      else:
        add(tkIdent, a, i)
    else:
      if ord(c) >= 0x80:
        return err(
          reject(
            rkSourceEncoding,
            header,
            here(),
            "a non-ASCII character outside a comment or literal",
          )
        )
      if c == '.' and i + 1 < chars.len and chars[i + 1] in {'0' .. '9'}:
        let a = i
        inc i
        while i < chars.len and (chars[i].isIdentChar or chars[i] == '.'):
          inc i
        add(tkNumber, a, i)
        continue
      var matched = 0
      for p in Punctuators3:
        if matched == 0 and i + p.len <= chars.len:
          var same = true
          for k in 0 ..< p.len:
            if chars[i + k] != p[k]:
              same = false
          if same:
            matched = p.len
      for p in Punctuators2:
        if matched == 0 and i + 2 <= chars.len and chars[i] == p[0] and
            chars[i + 1] == p[1]:
          matched = 2
      if matched == 0 and c in Punctuators1:
        matched = 1
      if matched == 0:
        return
          err(reject(rkLexical, header, here(), "no C token begins with " & escape($c)))
      let a = i
      i += matched
      add(tkPunct, a, i)
  ok(toks)
