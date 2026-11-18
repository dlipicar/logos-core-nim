## RFC 8610 lexer and parser for the cdCDDLe §5.1 subset. Constructs outside the
## subset are recognized and rejected as `unsupported`; text that is not CDDL is
## a `syntax` error. Parsing stops at the first error in source order.

{.push raises: [].}

import std/[strutils, unicode]
import ../cbor/utf8
import ./model

type
  SrcKind* = enum
    skName
    skLiteral
    skArray
    skMap
    skChoice
    skRange
    skSize
    skParen

  SrcNode* = ref object
    pos*: int
    case kind*: SrcKind
    of skName:
      name*: string
    of skLiteral:
      literal*: Literal
    of skArray, skMap:
      members*: seq[SrcMember]
    of skChoice:
      alternatives*: seq[SrcNode]
    of skRange:
      low*, high*: SrcNode
    of skSize:
      target*, controller*: SrcNode
    of skParen:
      inner*: SrcNode

  SrcMember* = object
    pos*: int
    key*: Opt[string]
    occurrence*: Occurrence
    typ*: SrcNode

  SrcRule* = object
    pos*: int
    name*: string
    typ*: SrcNode

const MaxNesting* = 256

func errorAt*(src: string, pos: int, class: CddlErrorClass, msg: string): CddlError =
  var
    line = 1
    lineStart = 0
  for i in 0 ..< min(pos, src.len):
    if src[i] == '\n':
      inc line
      lineStart = i + 1
  cddlError(class, msg, line, pos - lineStart + 1)

func unwrap*(n: SrcNode): SrcNode =
  ## The node inside any number of parentheses (cdCDDLe §7.4 removes them).
  var x = n
  while x.kind == skParen:
    x = x.inner
  x

# Lexer -------------------------------------------------------------------------

type
  TokKind = enum
    tEof
    tErr
    tId
    tInt
    tBigInt
    tFloat
    tText
    tBytes
    tPunct
    tCtl

  Token = object
    kind: TokKind
    pos, stop: int
    text: string ## identifier, punctuation, control name or error message
    errClass: CddlErrorClass
    lit: Literal

func errTok(pos: int, msg: string, class = ecSyntax): Token =
  Token(kind: tErr, pos: pos, stop: pos, text: msg, errClass: class)

func isEalpha(c: char): bool =
  c in {'A' .. 'Z', 'a' .. 'z', '@', '_', '$'}

func at(s: string, i: int): char =
  if i < s.len:
    s[i]
  else:
    '\0'

func isC1(s: string, j: int): bool =
  ## Whether a C1 control (U+0080 to U+009F, UTF-8 `C2 80` to `C2 9F`) starts
  ## at `j`. RFC 9682's NONASCII (§2.1.2) excludes U+007F to U+009F from string
  ## literals; RFC 8610's PCHAR admits them in comments.
  s[j] == '\xC2' and s.at(j + 1) in {'\x80' .. '\x9F'}

func isTopNoncharacter(s: string, j: int): bool =
  ## Whether U+10FFFE or U+10FFFF (UTF-8 `F4 8F BF BE` or `F4 8F BF BF`) starts
  ## at `j`. Both RFCs stop at U+10FFFD: RFC 8610's PCHAR and RFC 9682's
  ## NONASCII.
  s[j] == '\xF4' and s.at(j + 1) == '\x8F' and s.at(j + 2) == '\xBF' and
    s.at(j + 3) in {'\xBE', '\xBF'}

func skipComment(s: string, i: int): Result[int, Token] =
  ## `COMMENT = ";" *PCHAR CRLF` with RFC 8610's `PCHAR = %x20-7E /
  ## %x80-10FFFD`: cdCDDLe §5 l.126-127 takes RFC 9682 for string literals
  ## only, so a C1 control is admitted here. Returns the index of the line
  ## break.
  var j = i + 1
  while j < s.len and s[j] notin {'\n', '\r'}:
    if s[j] < ' ' or s[j] == '\x7f':
      return err(errTok(j, "control character in a comment"))
    if s.isTopNoncharacter(j):
      return err(errTok(j, "U+10FFFE or U+10FFFF in a comment"))
    inc j
  if j >= s.len:
    return err(errTok(i, "a comment must end with a line break (RFC 8610 Appendix B)"))
  if not isValidUtf8(s.toOpenArrayByte(i + 1, j - 1)):
    return err(errTok(i, "invalid UTF-8 in a comment"))
  ok(j)

func skipLineBreak(s: string, i: int): Result[int, Token] =
  ## `CRLF = %x0A / %x0D.0A`; `s[i]` is CR or LF.
  if s[i] == '\n':
    return ok(i + 1)
  if s.at(i + 1) == '\n':
    return ok(i + 2)
  err(errTok(i, "a carriage return must be followed by a line feed"))

func mulAdd(hi, lo: var uint64, base, digit: uint64) =
  ## (hi, lo) = (hi, lo) * base + digit as a 128-bit value; hi saturates at 2.
  let
    p0 = (lo and 0xffff_ffff'u64) * base
    p1 = (lo shr 32) * base
    mid = p1 shl 32
    low = mid + p0
  var carry = (p1 shr 32) + (if low < mid: 1'u64 else: 0'u64)
  let sum = low + digit
  if sum < low:
    inc carry
  hi = min(hi, 2'u64) * base + carry
  lo = sum
  hi = min(hi, 2'u64)

func lexNumber(s: string, i: int): Token =
  ## `int = ["-"] uint`; floats and hexfloats are lexed only to be rejected.
  var j = i
  let negative = s[j] == '-'
  if negative:
    inc j
  var base = 10'u64
  if s[j] == '0' and s.at(j + 1) in {'x', 'X'}:
    base = 16
    j += 2
  elif s[j] == '0' and s.at(j + 1) in {'b', 'B'}:
    base = 2
    j += 2
  let digitsStart = j
  let valid =
    case base
    of 16:
      HexDigits
    of 2:
      {'0', '1'}
    else:
      Digits
  while j < s.len and s[j] in valid:
    inc j
  if j == digitsStart:
    return errTok(i, "missing digits after the base prefix")
  var isFloat = false
  if base == 10:
    if s.at(j) == '.' and isDigit(s.at(j + 1)):
      isFloat = true
    elif s.at(j) in {'e', 'E'}:
      let k =
        if s.at(j + 1) in {'+', '-'}:
          j + 2
        else:
          j + 1
      isFloat = isDigit(s.at(k))
  elif base == 16:
    isFloat = (s.at(j) == '.' and s.at(j + 1) in HexDigits) or s.at(j) in {'p', 'P'}
  if isFloat:
    while j < s.len and s[j] in HexDigits + {'.', 'p', 'P', 'x', 'X', '+', '-'}:
      if s[j] == '.' and s.at(j + 1) == '.':
        break
      inc j
    return Token(kind: tFloat, pos: i, stop: j)
  if base == 10 and j - digitsStart > 1 and s[digitsStart] == '0':
    return errTok(i, "integer literals cannot have leading zeros")
  var hi, lo: uint64
  for k in digitsStart ..< j:
    let c = s[k]
    let d =
      if c in Digits:
        uint64(ord(c) - ord('0'))
      elif c in {'a' .. 'f'}:
        uint64(ord(c) - ord('a') + 10)
      else:
        uint64(ord(c) - ord('A') + 10)
    mulAdd(hi, lo, base, d)
  var tok = Token(kind: tInt, pos: i, stop: j)
  if not negative:
    if hi == 0:
      tok.lit = uintLiteral(lo)
    else:
      tok.kind = tBigInt
  elif hi == 0 and lo == 0:
    tok.lit = uintLiteral(0)
  elif hi == 0:
    tok.lit = nintLiteral(lo - 1)
  elif hi == 1 and lo == 0:
    tok.lit = nintLiteral(high(uint64))
  else:
    tok.kind = tBigInt
  tok

func hex4(s: string, at: int): int =
  ## The value of four hex digits at `at`, or -1.
  if at + 4 > s.len:
    return -1
  var v = 0
  for k in at ..< at + 4:
    let c = s[k]
    if c notin HexDigits:
      return -1
    v =
      v * 16 + (
        if c in Digits: ord(c) - ord('0')
        else: (ord(c) or 0x20) - ord('a') + 10
      )
  v

func bracedScalar(s: string, j: var int): int =
  ## `"{" (1*"0" [hexscalar] / hexscalar) "}"` (RFC 9682 §2.1.1) at `j`: one or
  ## more hex digits naming a Unicode scalar value, leading zeros allowed.
  ## Returns the code point and moves `j` past the `}`, or returns -1.
  var
    k = j + 1
    code = 0
  while k < s.len and s[k] in HexDigits:
    let c = s[k]
    code =
      code * 16 +
      (if c in Digits: ord(c) - ord('0')
      else: (ord(c) or 0x20) - ord('a') + 10)
    if code > 0x10ffff:
      return -1
    inc k
  if k == j + 1 or s.at(k) != '}' or code in 0xd800 .. 0xdfff:
    return -1
  j = k + 1
  code

func readEscape(
    s: string, j: var int, output: var string, quote: char
): Result[void, Token] =
  ## `SESC` of RFC 9682 §2.1.1 (cdCDDLe §5): the RFC 8259 §7 escapes plus
  ## `\u{hex}` for any Unicode scalar value. `s[j]` is the backslash. A byte
  ## string may also escape its own quote character (`BCHAR`'s `"\'"`).
  let e = s.at(j + 1)
  case e
  of '"', '\\', '/':
    output.add(e)
    j += 2
  of '\'':
    if quote != '\'':
      return err(errTok(j, "\\' is not an RFC 8259 escape"))
    output.add(e)
    j += 2
  of 'b':
    output.add('\b')
    j += 2
  of 'f':
    output.add('\f')
    j += 2
  of 'n':
    output.add('\n')
    j += 2
  of 'r':
    output.add('\r')
    j += 2
  of 't':
    output.add('\t')
    j += 2
  of 'u':
    if s.at(j + 2) == '{':
      var k = j + 2
      let code = bracedScalar(s, k)
      if code < 0:
        return err(errTok(j, "\\u{...} needs hex digits naming a Unicode scalar value"))
      j = k
      output.add($Rune(code))
      return ok()
    var code = hex4(s, j + 2)
    if code < 0:
      return err(errTok(j, "\\u needs four hex digits"))
    j += 6
    if code in 0xd800 .. 0xdbff:
      let low =
        if s.at(j) == '\\' and s.at(j + 1) == 'u':
          hex4(s, j + 2)
        else:
          -1
      if low notin 0xdc00 .. 0xdfff:
        return err(errTok(j, "unpaired surrogate in a \\u escape"))
      code = 0x10000 + ((code - 0xd800) shl 10) + (low - 0xdc00)
      j += 6
    elif code in 0xdc00 .. 0xdfff:
      return err(errTok(j, "unpaired surrogate in a \\u escape"))
    output.add($Rune(code))
  else:
    return err(errTok(j, "unknown escape (RFC 9682 §2.1.1 escapes only)"))
  ok()

func lexQuoted(s: string, i: int, quote: char): Token =
  ## A text string, or an unprefixed byte string (its text's UTF-8 bytes).
  var
    j = i + 1
    output: string
  while true:
    if j >= s.len:
      return errTok(i, "unterminated string")
    let c = s[j]
    if c == quote:
      break
    if c == '\\':
      let r = readEscape(s, j, output, quote)
      if r.isErr:
        return r.error
    elif c in {'\n', '\r'} and quote == '\'':
      # RFC 9682's BCHAR admits CRLF, but neither it nor cdCDDLe says which
      # bytes a source line break contributes (G157).
      return errTok(
        j, "a line break inside an unprefixed byte string is not supported [G157]",
        ecUnsupported,
      )
    elif c < ' ' or c == '\x7f' or s.isC1(j):
      return errTok(j, "control character in a string")
    elif s.isTopNoncharacter(j):
      return errTok(j, "U+10FFFE or U+10FFFF in a string (RFC 9682 NONASCII)")
    else:
      output.add(c)
      inc j
  if not isValidUtf8(output):
    return errTok(i, "invalid UTF-8 in a string")
  if quote == '"':
    Token(kind: tText, pos: i, stop: j + 1, lit: textLiteral(output))
  else:
    var bytes = newSeq[byte](output.len)
    for k, c in output:
      bytes[k] = byte(c)
    Token(kind: tBytes, pos: i, stop: j + 1, lit: bytesLiteral(bytes))

func collectEncoded(
    s: string, i, start: int, alphabet: set[char]
): Result[(string, int), Token] =
  ## The characters of an `h''` or `b64''` literal; whitespace and comments
  ## inside it are ignored. Returns the characters and the index after `'`.
  var
    j = start
    chars: string
  while true:
    if j >= s.len:
      return err(errTok(i, "unterminated byte string"))
    let c = s[j]
    if c == '\'':
      return ok((chars, j + 1))
    if c in alphabet:
      chars.add(c)
      inc j
    elif c == ' ':
      inc j
    elif c in {'\n', '\r'}:
      j = ?skipLineBreak(s, j)
    elif c == ';':
      let stop = ?skipComment(s, j)
      if '\'' in s[j ..< stop]:
        return err(errTok(j, "a comment inside a byte string cannot contain '"))
      j = stop
    else:
      return err(errTok(j, "invalid character in a prefixed byte string"))

func lexHex(s: string, i, start: int): Token =
  let r = collectEncoded(s, i, start, HexDigits)
  if r.isErr:
    return r.error
  let (chars, stop) = r.get
  if chars.len mod 2 != 0:
    return errTok(i, "odd number of hex digits")
  var bytes = newSeq[byte](chars.len div 2)
  for k in 0 ..< bytes.len:
    try:
      bytes[k] = byte(parseHexInt(chars[2 * k .. 2 * k + 1]))
    except ValueError:
      return errTok(i, "invalid hex digit")
  Token(kind: tBytes, pos: i, stop: stop, lit: bytesLiteral(bytes))

func base64Value(c: char): uint32 =
  case c
  of 'A' .. 'Z':
    uint32(ord(c) - ord('A'))
  of 'a' .. 'z':
    uint32(ord(c) - ord('a') + 26)
  of '0' .. '9':
    uint32(ord(c) - ord('0') + 52)
  of '+', '-':
    62
  else:
    63

func lexBase64(s: string, i, start: int): Token =
  ## RFC 4648 §4 or §5 alphabet (not both in one literal); padding optional but
  ## complete when present; unused trailing bits must be zero.
  let r = collectEncoded(s, i, start, Letters + Digits + {'+', '/', '-', '_', '='})
  if r.isErr:
    return r.error
  var (chars, stop) = r.get
  var padding = 0
  while chars.len > 0 and chars[^1] == '=':
    chars.setLen(chars.len - 1)
    inc padding
  if '=' in chars or padding > 2 or (padding > 0 and (chars.len + padding) mod 4 != 0):
    return errTok(i, "invalid base64 padding")
  if chars.len mod 4 == 1:
    return errTok(i, "invalid base64 length")
  if (chars.contains({'+', '/'})) and (chars.contains({'-', '_'})):
    return errTok(i, "base64 literal mixes the RFC 4648 §4 and §5 alphabets")
  var
    bytes: seq[byte]
    acc = 0'u32
    bits = 0
  for c in chars:
    acc = (acc shl 6) or base64Value(c)
    bits += 6
    if bits >= 8:
      bits -= 8
      bytes.add(byte((acc shr bits) and 0xff))
  if (acc and ((1'u32 shl bits) - 1)) != 0:
    return errTok(i, "non-zero trailing bits in a base64 literal")
  Token(kind: tBytes, pos: i, stop: stop, lit: bytesLiteral(bytes))

func lexIdentifier(s: string, i: int): int =
  ## `id = EALPHA *(*("-" / ".") (EALPHA / DIGIT))`; returns the end index.
  var j = i + 1
  while true:
    var k = j
    while k < s.len and s[k] in {'-', '.'}:
      inc k
    if k < s.len and (isEalpha(s[k]) or isDigit(s[k])):
      j = k + 1
    else:
      return j

func lex(s: string, start: int): Token =
  var i = start
  while i < s.len:
    case s[i]
    of ' ':
      inc i
    of '\n', '\r':
      let r = skipLineBreak(s, i)
      if r.isErr:
        return r.error
      i = r.get
    of ';':
      let r = skipComment(s, i)
      if r.isErr:
        return r.error
      i = r.get
    of '\t':
      return errTok(i, "tab characters are not CDDL whitespace (RFC 8610 Appendix B)")
    else:
      break
  if i >= s.len:
    return Token(kind: tEof, pos: i, stop: i)
  let c = s[i]
  if c in {'h', 'H'} and s.at(i + 1) == '\'':
    return lexHex(s, i, i + 2)
  if c in {'b', 'B'} and s.at(i + 1) == '6' and s.at(i + 2) == '4' and
      s.at(i + 3) == '\'':
    return lexBase64(s, i, i + 4)
  if isEalpha(c):
    let j = lexIdentifier(s, i)
    return Token(kind: tId, pos: i, stop: j, text: s[i ..< j])
  if isDigit(c) or (c == '-' and isDigit(s.at(i + 1))):
    return lexNumber(s, i)
  if c == '"' or c == '\'':
    return lexQuoted(s, i, c)
  if c == '.':
    if s.at(i + 1) == '.':
      let n = if s.at(i + 2) == '.': 3 else: 2
      return Token(kind: tPunct, pos: i, stop: i + n, text: s[i ..< i + n])
    if isEalpha(s.at(i + 1)):
      let j = lexIdentifier(s, i + 1)
      return Token(kind: tCtl, pos: i, stop: j, text: s[i + 1 ..< j])
    return errTok(i, "unexpected '.'")
  for p in ["//=", "/=", "//", "=>"]:
    if s.continuesWith(p, i):
      return Token(kind: tPunct, pos: i, stop: i + p.len, text: p)
  if c in {
    '=', '/', '(', ')', '[', ']', '{', '}', ',', ':', '^', '?', '*', '+', '~', '&', '#',
    '<', '>',
  }:
    return Token(kind: tPunct, pos: i, stop: i + 1, text: $c)
  errTok(i, "unexpected character")

# Parser ------------------------------------------------------------------------

type Parser = object
  s: string
  tok: Token
  depth: int

func advance(p: var Parser) =
  p.tok = lex(p.s, p.tok.stop)

func peek(p: Parser): Token =
  lex(p.s, p.tok.stop)

func isPunct(t: Token, x: string): bool =
  t.kind == tPunct and t.text == x

func isPunct(p: Parser, x: string): bool =
  p.tok.isPunct(x)

func fail(p: Parser, pos: int, class: CddlErrorClass, msg: string): CddlError =
  errorAt(p.s, pos, class, msg)

func unsupported(p: Parser, pos: int, msg: string): CddlError =
  p.fail(pos, ecUnsupported, msg)

func unexpected(p: Parser): CddlError =
  case p.tok.kind
  of tErr:
    p.fail(p.tok.pos, p.tok.errClass, p.tok.text)
  of tEof:
    p.fail(p.tok.pos, ecSyntax, "unexpected end of input")
  else:
    p.fail(p.tok.pos, ecSyntax, "unexpected '" & p.s[p.tok.pos ..< p.tok.stop] & "'")

func groupError(p: Parser): CddlError =
  if p.isPunct("//"):
    p.unsupported(p.tok.pos, "group choices (//) are not supported")
  else:
    p.unsupported(p.tok.pos, "groups are not supported, only types (cdCDDLe §5.1)")

func atGroupEntry(p: Parser): bool =
  ## Whether the current token starts something only a group entry can start:
  ## an occurrence indicator or a member key.
  case p.tok.kind
  of tPunct:
    p.tok.text in ["?", "+", "*"]
  of tInt, tBigInt:
    let next = p.peek
    (next.isPunct("*") and next.pos == p.tok.stop) or next.isPunct(":")
  of tId, tFloat, tText, tBytes:
    p.peek.isPunct(":")
  else:
    false

func atGroupSeparator(p: Parser): bool =
  p.tok.kind == tPunct and p.tok.text in [",", "//", ":", "=>", "^"]

proc parseType(p: var Parser): Result[SrcNode, CddlError] {.gcsafe.}
proc parseType1(p: var Parser): Result[SrcNode, CddlError] {.gcsafe.}

proc parseChoiceRest(p: var Parser, first: SrcNode): Result[SrcNode, CddlError] =
  if not p.isPunct("/"):
    return ok(first)
  var node = SrcNode(kind: skChoice, pos: first.pos, alternatives: @[first])
  while p.isPunct("/"):
    p.advance()
    node.alternatives.add(?p.parseType1())
  ok(node)

proc parseType(p: var Parser): Result[SrcNode, CddlError] {.gcsafe.} =
  let first = ?p.parseType1()
  p.parseChoiceRest(first)

proc parseMember(p: var Parser, isMap: bool): Result[SrcMember, CddlError] =
  let start = p.tok.pos
  var occurrence = occOne
  if p.isPunct("?"):
    occurrence = occOptional
    p.advance()
  elif p.isPunct("+"):
    return err(p.unsupported(start, "the + occurrence is not supported"))
  elif p.tok.kind in {tInt, tBigInt}:
    let next = p.peek
    if next.isPunct("*") and next.pos == p.tok.stop:
      return
        err(p.unsupported(start, "occurrence bounds (n*m) are not supported [G10]"))
  elif p.isPunct("*"):
    let next = p.peek
    if next.kind in {tInt, tBigInt} and next.pos == p.tok.stop:
      return
        err(p.unsupported(start, "occurrence bounds (n*m) are not supported [G10]"))
    occurrence = occUnbounded
    p.advance()
  var key = Opt.none(string)
  if p.peek.isPunct(":"):
    if p.tok.kind == tId:
      if not isMap:
        return
          err(p.unsupported(p.tok.pos, "array members cannot have keys (cdCDDLe §8)"))
      key = Opt.some(p.tok.text)
      p.advance()
      p.advance()
    elif p.tok.kind == tText:
      # cdCDDLe §5.1, §7.4: a text-string literal key is the same member key
      # as the bareword with that text.
      if not isMap:
        return
          err(p.unsupported(p.tok.pos, "array members cannot have keys (cdCDDLe §8)"))
      key = Opt.some(p.tok.lit.text)
      p.advance()
      p.advance()
    elif p.tok.kind in {tInt, tBigInt, tFloat, tBytes}:
      return err(p.unsupported(p.tok.pos, "map keys must be barewords or text strings"))
  let first = ?p.parseType1()
  if p.isPunct("^"):
    return err(p.unsupported(p.tok.pos, "explicit cuts (^) are not supported"))
  if p.isPunct("=>"):
    return err(p.unsupported(p.tok.pos, "=> member keys are not supported"))
  let typ = ?p.parseChoiceRest(first)
  if isMap:
    if key.isNone:
      return err(p.unsupported(start, "map entries need a bareword or text-string key"))
    if occurrence == occUnbounded:
      return
        err(p.unsupported(start, "the * occurrence is only supported on array members"))
  elif occurrence == occOptional:
    return
      err(p.unsupported(start, "the ? occurrence is only supported on map members"))
  ok(SrcMember(pos: start, key: key, occurrence: occurrence, typ: typ))

proc parseGroup(p: var Parser, isMap: bool): Result[SrcNode, CddlError] =
  let open = p.tok.pos
  let close = if isMap: "}" else: "]"
  p.advance()
  var node =
    if isMap:
      SrcNode(kind: skMap, pos: open)
    else:
      SrcNode(kind: skArray, pos: open)
  while not p.isPunct(close):
    if p.tok.kind == tEof:
      return
        err(p.fail(open, ecSyntax, "unterminated " & (if isMap: "map" else: "array")))
    if p.isPunct("//"):
      return err(p.groupError())
    node.members.add(?p.parseMember(isMap))
    if p.isPunct(","):
      p.advance()
  p.advance()
  if not isMap and node.members.len != 1:
    for m in node.members:
      if m.occurrence == occUnbounded:
        return err(
          p.unsupported(m.pos, "a variable-length array has exactly one member: [* T]")
        )
  ok(node)

proc parseType2(p: var Parser): Result[SrcNode, CddlError] =
  let start = p.tok.pos
  case p.tok.kind
  of tInt, tText, tBytes:
    let node = SrcNode(kind: skLiteral, pos: start, literal: p.tok.lit)
    p.advance()
    ok(node)
  of tBigInt:
    err(p.unsupported(start, "integer literals must fit in 64 bits"))
  of tFloat:
    err(p.unsupported(start, "floating-point literals are not supported"))
  of tId:
    let name = p.tok.text
    if name[0] == '$':
      return err(p.unsupported(start, "sockets ($name) are not supported"))
    let stop = p.tok.stop
    p.advance()
    if p.isPunct("<") and p.tok.pos == stop:
      return err(p.unsupported(p.tok.pos, "generic arguments are not supported"))
    ok(SrcNode(kind: skName, pos: start, name: name))
  of tPunct:
    case p.tok.text
    of "(":
      p.advance()
      if p.atGroupEntry():
        return err(p.groupError())
      let inner = ?p.parseType()
      if p.atGroupSeparator():
        return err(p.groupError())
      if not p.isPunct(")"):
        return err(p.unexpected())
      p.advance()
      ok(SrcNode(kind: skParen, pos: start, inner: inner))
    of "[":
      p.parseGroup(false)
    of "{":
      p.parseGroup(true)
    of "~":
      err(p.unsupported(start, "unwrapped groups (~) are not supported"))
    of "&":
      err(p.unsupported(start, "enumerations (&) are not supported"))
    of "#":
      err(p.unsupported(start, "tags and major-type forms (#) are not supported"))
    else:
      err(p.unexpected())
  else:
    err(p.unexpected())

func checkRangeBound(p: Parser, n: SrcNode): Result[void, CddlError] =
  ## [SPEC cdCDDLe §5.1 l.181] A range bound is an integer literal written
  ## directly in the source: a name or a parenthesized bound is rejected.
  if n.kind == skLiteral and n.literal.isIntegerLiteral:
    return ok()
  if n.kind == skName:
    return err(p.unsupported(n.pos, "named range bounds are not supported [G12]"))
  err(p.unsupported(n.pos, "range bounds must be integer literals written directly"))

func checkSize(p: Parser, target, controller: SrcNode): Result[void, CddlError] =
  let t = unwrap(target)
  if t.kind != skName or t.name notin ["uint", "tstr", "bstr", "bool"]:
    return err(
      p.unsupported(
        t.pos, ".size applies only to uint, tstr or bstr written directly (cdCDDLe §8)"
      )
    )
  let c = unwrap(controller)
  if not (c.kind == skRange or (c.kind == skLiteral and c.literal.isIntegerLiteral)):
    return err(
      p.unsupported(
        c.pos, "the .size controller must be an integer or an integer range"
      )
    )
  ok()

proc parseType1(p: var Parser): Result[SrcNode, CddlError] {.gcsafe.} =
  inc p.depth
  if p.depth > MaxNesting:
    return
      err(p.unsupported(p.tok.pos, "nesting deeper than " & $MaxNesting & " levels"))
  let a = ?p.parseType2()
  var node = a
  if p.isPunct(".."):
    p.advance()
    let b = ?p.parseType2()
    ?p.checkRangeBound(a)
    ?p.checkRangeBound(b)
    node = SrcNode(kind: skRange, pos: a.pos, low: a, high: b)
  elif p.isPunct("..."):
    return err(p.unsupported(p.tok.pos, "exclusive ranges (...) are not supported"))
  elif p.tok.kind == tCtl:
    if p.tok.text != "size":
      return err(
        p.unsupported(
          p.tok.pos, "the ." & p.tok.text & " control is not supported (only .size)"
        )
      )
    p.advance()
    let b = ?p.parseType2()
    ?p.checkSize(a, b)
    node = SrcNode(kind: skSize, pos: a.pos, target: a, controller: b)
  dec p.depth
  ok(node)

proc parseRule(p: var Parser): Result[SrcRule, CddlError] =
  if p.tok.kind != tId:
    return err(p.unexpected())
  let start = p.tok.pos
  let name = p.tok.text
  if name[0] == '$':
    return err(p.unsupported(start, "sockets ($name) are not supported"))
  p.advance()
  if p.isPunct("<"):
    return err(p.unsupported(p.tok.pos, "generic rules are not supported"))
  if p.isPunct("/=") or p.isPunct("//="):
    return
      err(p.unsupported(p.tok.pos, "rule extensions (/= and //=) are not supported"))
  if not p.isPunct("="):
    return err(p.unexpected())
  p.advance()
  if p.atGroupEntry():
    return err(p.groupError())
  let typ = ?p.parseType()
  if p.atGroupSeparator():
    return err(p.groupError())
  if p.tok.kind notin {tEof, tId}:
    return err(p.unexpected())
  ok(SrcRule(pos: start, name: name, typ: typ))

proc parseSource*(s: string): Result[seq[SrcRule], CddlError] =
  ## Parses CDDL source text into rules in source order.
  var p = Parser(s: s)
  p.tok = lex(s, 0)
  if p.tok.kind == tEof:
    return err(p.fail(0, ecSyntax, "a CDDL document needs at least one rule"))
  var rules: seq[SrcRule]
  while p.tok.kind != tEof:
    rules.add(?p.parseRule())
  ok(rules)
