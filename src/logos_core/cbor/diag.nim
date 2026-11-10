## CBOR diagnostic notation (RFC 8949 §8): a printer, and a parser for the subset
## the specs' `cbor-diag` blocks use: maps, arrays, integers, "text", h'hex',
## true/false/null/undefined, tags `N(...)` and trailing commas.

{.push raises: [].}

import std/[strutils, unicode]
import ./[value, floats]

func diagText(s: string): string =
  var output = "\""
  for c in s:
    case c
    of '"':
      output.add("\\\"")
    of '\\':
      output.add("\\\\")
    of '\n':
      output.add("\\n")
    of '\r':
      output.add("\\r")
    of '\t':
      output.add("\\t")
    elif c < ' ':
      output.add("\\u" & toHex(ord(c), 4).toLowerAscii)
    else:
      output.add(c)
  output.add('"')
  output

func hexLower(bytes: openArray[byte]): string =
  const digits = "0123456789abcdef"
  var output = newStringOfCap(bytes.len * 2)
  for b in bytes:
    output.add(digits[int(b shr 4)])
    output.add(digits[int(b and 15)])
  output

func toDiag*(v: CborValue): string =
  ## One-line diagnostic notation; maps print in their stored entry order.
  case v.kind
  of ckUint:
    $v.uint
  of ckNint:
    if v.nint == high(uint64):
      "-18446744073709551616"
    else:
      "-" & $(v.nint + 1)
  of ckBytes:
    "h'" & hexLower(v.bytes) & "'"
  of ckText:
    if v.validUtf8:
      diagText(v.text)
    else:
      "h'" & hexLower(v.text.toOpenArrayByte(0, v.text.high)) &
        "' / invalid UTF-8 text /"
  of ckArray:
    var parts: seq[string]
    for item in v.items:
      parts.add(toDiag(item))
    "[" & parts.join(", ") & "]"
  of ckMap:
    var parts: seq[string]
    for (k, x) in v.entries:
      parts.add(toDiag(k) & ": " & toDiag(x))
    "{" & parts.join(", ") & "}"
  of ckTag:
    $v.tag & "(" & toDiag(v.content) & ")"
  of ckSimple:
    case v.simple
    of SimpleFalse:
      "false"
    of SimpleTrue:
      "true"
    of SimpleNull:
      "null"
    of SimpleUndefined:
      "undefined"
    else:
      "simple(" & $v.simple & ")"
  of ckFloat:
    let f = toFloat64(v)
    let suffix =
      case v.width
      of fw16: "_1"
      of fw32: "_2"
      of fw64: "_3"
    if f != f:
      "NaN" & suffix
    elif f == Inf:
      "Infinity" & suffix
    elif f == NegInf:
      "-Infinity" & suffix
    else:
      $f & suffix

# Parser ------------------------------------------------------------------------

type DiagParser = object
  s: string
  pos: int

func fail(p: DiagParser, msg: string): string =
  msg & " at offset " & $p.pos

func skipSpace(p: var DiagParser) =
  while p.pos < p.s.len and p.s[p.pos] in Whitespace:
    inc p.pos

func peek(p: DiagParser): char =
  if p.pos < p.s.len:
    p.s[p.pos]
  else:
    '\0'

func expect(p: var DiagParser, c: char): Result[void, string] =
  p.skipSpace()
  if p.peek != c:
    return err(p.fail("expected '" & c & "'"))
  inc p.pos
  ok()

func parseValue(p: var DiagParser, depth: int): Result[CborValue, string]

func parseHexBytes(p: var DiagParser): Result[seq[byte], string] =
  var
    output: seq[byte]
    digits: string
  while p.pos < p.s.len and p.s[p.pos] != '\'':
    let c = p.s[p.pos]
    if c in HexDigits:
      digits.add(c)
    elif c notin Whitespace:
      return err(p.fail("invalid character in h''"))
    inc p.pos
  if p.pos >= p.s.len:
    return err(p.fail("unterminated h''"))
  inc p.pos
  if digits.len mod 2 != 0:
    return err(p.fail("odd number of hex digits"))
  for i in countup(0, digits.len - 2, 2):
    try:
      output.add(uint8(parseHexInt(digits[i .. i + 1])))
    except ValueError:
      return err(p.fail("invalid hex"))
  ok(output)

func parseText(p: var DiagParser): Result[string, string] =
  var output: string
  while true:
    if p.pos >= p.s.len:
      return err(p.fail("unterminated text string"))
    let c = p.s[p.pos]
    inc p.pos
    if c == '"':
      return ok(output)
    if c != '\\':
      output.add(c)
      continue
    if p.pos >= p.s.len:
      return err(p.fail("unterminated escape"))
    let e = p.s[p.pos]
    inc p.pos
    case e
    of '"', '\\', '/':
      output.add(e)
    of 'b':
      output.add('\b')
    of 'f':
      output.add('\f')
    of 'n':
      output.add('\n')
    of 'r':
      output.add('\r')
    of 't':
      output.add('\t')
    of 'u':
      if p.pos + 4 > p.s.len:
        return err(p.fail("short \\u escape"))
      var code: int
      try:
        code = parseHexInt(p.s[p.pos ..< p.pos + 4])
      except ValueError:
        return err(p.fail("invalid \\u escape"))
      p.pos += 4
      if code >= 0xd800 and code <= 0xdbff:
        if p.pos + 6 > p.s.len or p.s[p.pos] != '\\' or p.s[p.pos + 1] != 'u':
          return err(p.fail("unpaired surrogate"))
        var low: int
        try:
          low = parseHexInt(p.s[p.pos + 2 ..< p.pos + 6])
        except ValueError:
          return err(p.fail("invalid \\u escape"))
        if low < 0xdc00 or low > 0xdfff:
          return err(p.fail("unpaired surrogate"))
        p.pos += 6
        code = 0x10000 + ((code - 0xd800) shl 10) + (low - 0xdc00)
      elif code >= 0xdc00 and code <= 0xdfff:
        return err(p.fail("unpaired surrogate"))
      output.add($Rune(code))
    else:
      return err(p.fail("unknown escape"))

func parseUnsigned(p: var DiagParser): Result[uint64, string] =
  let start = p.pos
  while p.pos < p.s.len and p.s[p.pos] in Digits:
    inc p.pos
  if p.pos == start:
    return err(p.fail("expected a digit"))
  var n = 0'u64
  for c in p.s[start ..< p.pos]:
    let d = uint64(ord(c) - ord('0'))
    if n > (high(uint64) - d) div 10:
      return err(p.fail("integer out of range"))
    n = n * 10 + d
  ok(n)

func parseValue(p: var DiagParser, depth: int): Result[CborValue, string] =
  if depth > 1024:
    return err(p.fail("nesting too deep"))
  p.skipSpace()
  let c = p.peek
  case c
  of '{':
    inc p.pos
    var node = CborValue(kind: ckMap)
    while true:
      p.skipSpace()
      if p.peek == '}':
        inc p.pos
        return ok(node)
      let k = ?p.parseValue(depth + 1)
      ?p.expect(':')
      let x = ?p.parseValue(depth + 1)
      node.entries.add((k, x))
      p.skipSpace()
      if p.peek == ',':
        inc p.pos
      elif p.peek != '}':
        return err(p.fail("expected ',' or '}'"))
  of '[':
    inc p.pos
    var node = CborValue(kind: ckArray)
    while true:
      p.skipSpace()
      if p.peek == ']':
        inc p.pos
        return ok(node)
      node.items.add(?p.parseValue(depth + 1))
      p.skipSpace()
      if p.peek == ',':
        inc p.pos
      elif p.peek != ']':
        return err(p.fail("expected ',' or ']'"))
  of '"':
    inc p.pos
    return ok(cbor(?p.parseText()))
  of 'h':
    if p.pos + 1 < p.s.len and p.s[p.pos + 1] == '\'':
      p.pos += 2
      return ok(cbor(?p.parseHexBytes()))
    else:
      return err(p.fail("unexpected 'h'"))
  of '-':
    inc p.pos
    const minNint = "18446744073709551616"
    if p.s.continuesWith(minNint, p.pos) and
        (p.pos + minNint.len == p.s.len or p.s[p.pos + minNint.len] notin Digits):
      p.pos += minNint.len
      return ok(cborNint(high(uint64)))
    let n = ?p.parseUnsigned()
    if n == 0:
      return err(p.fail("negative zero is not an integer"))
    return ok(cborNint(n - 1))
  of '0' .. '9':
    let n = ?p.parseUnsigned()
    p.skipSpace()
    if p.peek == '(':
      inc p.pos
      let content = ?p.parseValue(depth + 1)
      ?p.expect(')')
      return ok(cborTag(n, content))
    return ok(cbor(n))
  else:
    for (word, v) in [
      ("true", cbor(true)),
      ("false", cbor(false)),
      ("null", cborNull()),
      ("undefined", cborUndefined()),
    ]:
      if p.s.continuesWith(word, p.pos):
        p.pos += word.len
        return ok(v)
    if p.s.continuesWith("simple(", p.pos):
      p.pos += "simple(".len
      let n = ?p.parseUnsigned()
      ?p.expect(')')
      if n > 255 or n in 24'u64 .. 31'u64:
        return err(p.fail("invalid simple value"))
      return ok(cborSimple(uint8(n)))
    return err(p.fail("unexpected character"))

func parseDiag*(s: string): Result[CborValue, string] =
  ## Parses one value in the subset above; anything else is an error.
  var p = DiagParser(s: s)
  let v = ?p.parseValue(0)
  p.skipSpace()
  if p.pos != s.len:
    return err(p.fail("trailing text"))
  ok(v)
