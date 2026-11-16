## INTERFACE §3.5: recognizing a literal macro's replacement.
##
## [SPEC INTERFACE §3.5 l.2537-2569] The reverse mapper accepts the generated
## literal forms of §2.3 (l.1085-1095) and the handwritten forms of §3.5, and
## recovers the same scalar kind and value from equivalent spellings. It never
## evaluates a macro: the standard macros `INTN_C`, `UINTN_C` (N = 8, 16, 32, 64),
## `INT64_MIN`, `true` and `false` are recognized by their specified meanings, and
## any other identifier rejects the replacement (l.2567-2568).

{.push raises: [].}

import std/strutils
import results
import ./[clex, creject]

export results, creject

const MaxLiteralParens* = 64
  ## [IMPL-DECISION G321] nested parentheses in one replacement

type
  CScalarKind* = enum
    cskBool = "bool"
    cskInt = "integer"
    cskText = "text"

  CScalar* = object
    ## A recognized scalar value: a Boolean, an integer in [-2^63, 2^64 - 1] as a
    ## sign and magnitude, or UTF-8 text without NUL.
    case kind*: CScalarKind
    of cskBool:
      boolean*: bool
    of cskInt:
      negative*: bool ## never set for zero
      magnitude*: uint64
    of cskText:
      text*: string

  IntConst = object
    value: uint64
    decimal: bool
    unsignedSuffix: bool
    suffixed: bool

const
  Int64Max = 9_223_372_036_854_775_807'u64
  Suffixes = [
    "", "u", "U", "l", "L", "ll", "LL", "ul", "uL", "Ul", "UL", "ull", "uLL", "Ull",
    "ULL", "lu", "lU", "Lu", "LU", "llu", "llU", "LLu", "LLU",
  ]
  StandardIntMacros* = [
    "INT8_C", "INT16_C", "INT32_C", "INT64_C", "UINT8_C", "UINT16_C", "UINT32_C",
    "UINT64_C",
  ]
  StandardMacros* = [
    "INT8_C", "INT16_C", "INT32_C", "INT64_C", "UINT8_C", "UINT16_C", "UINT32_C",
    "UINT64_C", "INT64_MIN", "true", "false",
  ] ## [SPEC INTERFACE §3.5 l.2568-2569] recognized, never redefined

func `==`*(a, b: CScalar): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of cskBool:
    a.boolean == b.boolean
  of cskInt:
    a.negative == b.negative and a.magnitude == b.magnitude
  of cskText:
    a.text == b.text

func `$`*(v: CScalar): string =
  case v.kind
  of cskBool:
    $v.boolean
  of cskInt:
    (if v.negative: "-" else: "") & $v.magnitude
  of cskText:
    escape(v.text)

func intScalar(negative: bool, magnitude: uint64): CScalar =
  CScalar(kind: cskInt, negative: negative and magnitude != 0, magnitude: magnitude)

proc fail(reason: RejectReason, header: string, line: int, msg: string): Rejection =
  reject(reason, header, line, msg)

func digitValue(c: char): int =
  case c
  of '0' .. '9':
    ord(c) - ord('0')
  of 'a' .. 'f':
    ord(c) - ord('a') + 10
  of 'A' .. 'F':
    ord(c) - ord('A') + 10
  else:
    99

proc intConst(t: Token, header: string): Result[IntConst, Rejection] =
  ## [SPEC INTERFACE §3.5 l.2544-2546] A decimal, octal or hexadecimal integer
  ## constant with the C suffixes; the value fits uint64.
  if t.kind != tkNumber:
    return
      err(fail(rkLiteralForm, header, t.line, t.text & " is not an integer constant"))
  let s = t.text
  var i = 0
  var base = 10
  if s.len >= 2 and s[0] == '0' and s[1] in {'x', 'X'}:
    base = 16
    i = 2
  elif s[0] == '0':
    base = 8
    i = 1
  let start = i
  var value = 0'u64
  var overflow = false
  while i < s.len and digitValue(s[i]) < base:
    let d = uint64(digitValue(s[i]))
    if value > (high(uint64) - d) div uint64(base):
      overflow = true
    else:
      value = value * uint64(base) + d
    inc i
  if base == 16 and i == start:
    return err(fail(rkLiteralForm, header, t.line, s & " has no hexadecimal digits"))
  let suffix = s[i .. ^1]
  if suffix notin Suffixes:
    return err(
      fail(rkLiteralForm, header, t.line, s & ": malformed integer constant or suffix")
    )
  if overflow:
    return err(fail(rkLiteralRange, header, t.line, s & " does not fit uint64"))
  # "0" itself (with any suffix) is a decimal zero, not an octal constant
  let decimalZero = base == 8 and i == start
  ok(
    IntConst(
      value: value,
      decimal: base == 10 or decimalZero,
      unsignedSuffix: 'u' in suffix or 'U' in suffix,
      suffixed: suffix.len > 0,
    )
  )

func isPunct(t: Token, p: string): bool =
  t.kind == tkPunct and t.text == p

proc closing(toks: openArray[Token], a, b: int): int =
  ## The index of the `)` matching the `(` at `a`, or -1; within [a, b).
  var depth = 0
  for i in a ..< b:
    if toks[i].isPunct("("):
      inc depth
    elif toks[i].isPunct(")"):
      dec depth
      if depth == 0:
        return i
  -1

proc strip(
    toks: openArray[Token], a, b: int, header: string
): Result[(int, int, int), Rejection] =
  ## Removes redundant parentheses around [a, b): (start, end, pairs removed).
  var a = a
  var b = b
  var pairs = 0
  while b - a >= 2 and toks[a].isPunct("(") and closing(toks, a, b) == b - 1:
    inc a
    dec b
    inc pairs
    if pairs > MaxLiteralParens:
      return err(
        fail(
          rkLimit, header, toks[a].line, "more than 64 nested parentheses in a literal"
        )
      )
  ok((a, b, pairs))

proc invocation(
    toks: openArray[Token], a, b: int, header: string
): Result[(bool, CScalar), Rejection] =
  ## [SPEC INTERFACE §3.5 l.2547] `INTN_C(c)` or `UINTN_C(c)`: one unsuffixed
  ## integer constant that fits the N-bit range. (false, _) when [a, b) is not an
  ## invocation.
  if b - a != 4 or toks[a].kind != tkIdent or toks[a].text notin StandardIntMacros or
      not toks[a + 1].isPunct("(") or not toks[a + 3].isPunct(")"):
    if b - a >= 1 and toks[a].kind == tkIdent and toks[a].text in StandardIntMacros:
      return err(
        fail(
          rkLiteralForm,
          header,
          toks[a].line,
          toks[a].text & " takes exactly one integer constant token",
        )
      )
    return ok((false, CScalar(kind: cskInt)))
  let name = toks[a].text
  let c = ?intConst(toks[a + 2], header)
  if c.suffixed:
    return err(
      fail(rkLiteralForm, header, toks[a].line, name & " takes an unsuffixed constant")
    )
  let signed = not name.startsWith("U")
  let bits =
    case name
    of "INT8_C", "UINT8_C": 8
    of "INT16_C", "UINT16_C": 16
    of "INT32_C", "UINT32_C": 32
    else: 64
  let limit =
    if signed:
      (1'u64 shl (bits - 1)) - 1
    elif bits == 64:
      high(uint64)
    else:
      (1'u64 shl bits) - 1
  if c.value > limit:
    return err(
      fail(
        rkLiteralRange,
        header,
        toks[a].line,
        name & "(" & toks[a + 2].text & ") is out of range",
      )
    )
  ok((true, intScalar(false, c.value)))

proc operand(
    toks: openArray[Token], a, b: int, header: string, sign: string
): Result[CScalar, Rejection] =
  ## An integer constant or integer-macro invocation, with the unary sign `sign`
  ## ("" for none) already consumed.
  let (a, b, _) = ?strip(toks, a, b, header)
  if a >= b:
    return
      err(fail(rkLiteralForm, header, toks[max(a - 1, 0)].line, "an empty operand"))
  let (isCall, called) = ?invocation(toks, a, b, header)
  if isCall:
    if sign == "-":
      if toks[a].text.startsWith("U"):
        return err(
          fail(
            rkLiteralForm,
            header,
            toks[a].line,
            "unary minus on " & toks[a].text & " (unsigned negation)",
          )
        )
      return ok(intScalar(true, called.magnitude))
    return ok(called)
  if b - a != 1:
    return err(
      fail(rkLiteralForm, header, toks[a].line, "not a literal form of INTERFACE §3.5")
    )
  let c = ?intConst(toks[a], header)
  if sign == "-":
    if not c.decimal or c.unsignedSuffix:
      return err(
        fail(
          rkLiteralForm,
          header,
          toks[a].line,
          "unary minus needs an unsigned-suffix-free decimal constant: -" & toks[a].text,
        )
      )
    if c.value > Int64Max:
      return err(
        fail(
          rkLiteralRange, header, toks[a].line, "-" & toks[a].text & " is below int64"
        )
      )
    return ok(intScalar(true, c.value))
  if c.decimal and not c.unsignedSuffix and c.value > Int64Max:
    return err(
      fail(
        rkLiteralRange,
        header,
        toks[a].line,
        toks[a].text & " exceeds int64 without a u suffix",
      )
    )
  ok(intScalar(false, c.value))

func utf8(cp: uint32): string =
  if cp < 0x80:
    $char(cp)
  elif cp < 0x800:
    $char(0xC0 or (cp shr 6)) & $char(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    $char(0xE0 or (cp shr 12)) & $char(0x80 or ((cp shr 6) and 0x3F)) &
      $char(0x80 or (cp and 0x3F))
  else:
    $char(0xF0 or (cp shr 18)) & $char(0x80 or ((cp shr 12) and 0x3F)) &
      $char(0x80 or ((cp shr 6) and 0x3F)) & $char(0x80 or (cp and 0x3F))

proc decodeString*(t: Token, header: string): Result[string, Rejection] =
  ## [SPEC INTERFACE §3.5 l.2558-2564] The bytes of one ordinary string literal
  ## token, without its quotes: UTF-8 source characters, simple escapes, octal
  ## and hexadecimal byte escapes (0-255; a hexadecimal escape takes every
  ## following hexadecimal digit) and C17 universal character names.
  if t.kind != tkString or not t.text.startsWith("\""):
    return err(
      fail(
        rkLiteralForm, header, t.line, t.text & " is not an unprefixed string literal"
      )
    )
  let s = t.text
  var o = ""
  var i = 1
  let last = s.len - 1
  while i < last:
    let c = s[i]
    if c != '\\':
      o.add(c)
      inc i
      continue
    inc i
    let e = s[i]
    case e
    of '\'', '"', '?', '\\':
      o.add(e)
      inc i
    of 'a':
      o.add('\a')
      inc i
    of 'b':
      o.add('\b')
      inc i
    of 'f':
      o.add('\f')
      inc i
    of 'n':
      o.add('\n')
      inc i
    of 'r':
      o.add('\r')
      inc i
    of 't':
      o.add('\t')
      inc i
    of 'v':
      o.add('\v')
      inc i
    of '0' .. '7':
      var v = 0
      var n = 0
      while n < 3 and i < last and s[i] in {'0' .. '7'}:
        v = v * 8 + ord(s[i]) - ord('0')
        inc i
        inc n
      if v > 255:
        return err(fail(rkLiteralText, header, t.line, "octal escape above 255"))
      o.add(char(v))
    of 'x':
      inc i
      var v = 0
      var n = 0
      while i < last and digitValue(s[i]) < 16:
        if v <= 255:
          v = v * 16 + digitValue(s[i])
        inc i
        inc n
      if n == 0:
        return
          err(fail(rkLiteralText, header, t.line, "\\x without hexadecimal digits"))
      if v > 255:
        return err(fail(rkLiteralText, header, t.line, "hexadecimal escape above 255"))
      o.add(char(v))
    of 'u', 'U':
      let n = if e == 'u': 4 else: 8
      inc i
      var cp = 0'u32
      for k in 0 ..< n:
        if i >= last or digitValue(s[i]) >= 16:
          return err(
            fail(rkLiteralText, header, t.line, "a universal character name is short")
          )
        cp = cp * 16 + uint32(digitValue(s[i]))
        inc i
      # [SPEC INTERFACE §3.5 l.2561] C17 §6.4.3p2: no surrogate, nothing beyond
      # U+10FFFF, and below U+00A0 only $, @ and `.
      if cp in 0xD800'u32 .. 0xDFFF'u32 or cp > 0x10FFFF'u32 or
          (cp < 0xA0'u32 and cp notin [0x24'u32, 0x40, 0x60]):
        return err(
          fail(
            rkLiteralText,
            header,
            t.line,
            "invalid universal character name U+" & toHex(cp, 4),
          )
        )
      o.add(utf8(cp))
    else:
      return err(fail(rkLiteralText, header, t.line, "unknown escape \\" & $e))
  ok(o)

proc recognizeLiteral*(
    toks: openArray[Token], header: string, line: int
): Result[CScalar, Rejection] =
  ## [SPEC INTERFACE §3.5] The scalar kind and value of a literal macro's
  ## replacement `toks`, or the reason it is outside the §3.5 forms.
  if toks.len == 0:
    return err(fail(rkLiteralForm, header, line, "an empty literal replacement"))
  let (a, b, pairs) = ?strip(toks, 0, toks.len, header)
  if a >= b:
    return err(fail(rkLiteralForm, header, line, "empty parentheses"))
  # [SPEC INTERFACE §2.3 l.1090, §3.5 l.2553] the exact generated int64
  # minimum, whose outer parentheses are part of it
  block minimum:
    const want =
      ["-", "INT64_C", "(", "9223372036854775807", ")", "-", "INT64_C", "(", "1", ")"]
    if pairs == 0 or b - a != want.len:
      break minimum
    for k, w in want:
      if toks[a + k].text != w:
        break minimum
    return ok(intScalar(true, 9_223_372_036_854_775_808'u64))
  let first = toks[a]
  if b - a == 1 and first.kind == tkIdent:
    case first.text
    of "true":
      return ok(CScalar(kind: cskBool, boolean: true))
    of "false":
      return ok(CScalar(kind: cskBool, boolean: false))
    of "INT64_MIN":
      return ok(intScalar(true, 9_223_372_036_854_775_808'u64))
    else:
      discard
  if first.kind == tkString:
    var text = ""
    for k in a ..< b:
      if toks[k].kind != tkString:
        return err(
          fail(
            rkLiteralForm, header, toks[k].line, "a string followed by " & toks[k].text
          )
        )
      text.add(?decodeString(toks[k], header))
    # [SPEC INTERFACE §3.5 l.2562] checked after concatenation
    if '\0' in text:
      return err(fail(rkLiteralText, header, first.line, "an embedded NUL"))
    if not isUtf8(text):
      return err(fail(rkLiteralText, header, first.line, "the text is not UTF-8"))
    return ok(CScalar(kind: cskText, text: text))
  if first.isPunct("-") or first.isPunct("+"):
    return operand(toks, a + 1, b, header, first.text)
  if first.kind == tkIdent and first.text notin StandardIntMacros:
    return err(
      fail(
        rkLiteralForm,
        header,
        first.line,
        first.text & " is not a permitted standard macro (user macros are not expanded)",
      )
    )
  operand(toks, a, b, header, "")
