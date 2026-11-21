## The output of a marked response (Tier 5 step N-2d; INTERFACE §1.4.1
## l.360-361; DECISIONS G349's N-2d amendment): the line `present.done` writes
## for any response, G89's JSON envelope or diagnostic notation, with
## `terminalSafe`'s escapes, built in one buffer of its final size.
##
## A first pass counts the bytes and a second writes them, so no growth frees
## a partial copy, and the caller wipes the buffer after the write. Integers
## go through a stack buffer, zeroed after use. A map key that is not text is
## rendered into its own buffer of exact size, wiped after use: the keys of a
## map with free keys are payload. The text equals `terminalSafe` of what
## `render.jsonOf` with std/json's `$`, or `toDiag`, gives for the same value
## (test_cli checks it), so a marked response reads as any other.

{.push raises: [], gcsafe.}

import logos_sdk/cbor
import logos_sdk/base/wipe

const
  JsonSafe = 9_007_199_254_740_992'u64 ## 2^53, G89's integer bound
  Lower = "0123456789abcdef"
  Upper = "0123456789ABCDEF"
  NintMax = "18446744073709551616" ## the magnitude of -1 - high(uint64)

type Out = object
  count: bool ## the first pass: only `n` moves
  n: int
  pos: int
  buf: string

proc put(o: var Out, c: char) =
  if o.count:
    inc o.n
  else:
    o.buf[o.pos] = c
    inc o.pos

proc put(o: var Out, s: openArray[char]) =
  for c in s:
    o.put(c)

proc putUint(o: var Out, x: uint64) =
  ## Decimal, from a stack buffer zeroed after use.
  var d: array[20, char]
  var k = 0
  var y = x
  if y == 0:
    o.put('0')
    return
  while y > 0:
    d[k] = char(ord('0') + int(y mod 10))
    y = y div 10
    inc k
  while k > 0:
    dec k
    o.put(d[k])
  secureZero(addr d[0], sizeof(d))

proc putNintMagnitude(o: var Out, nint: uint64) =
  ## The magnitude of -1 - `nint`.
  if nint == high(uint64):
    o.put(NintMax)
  else:
    o.putUint(nint + 1)

proc putHex(o: var Out, bytes: openArray[byte]) =
  for b in bytes:
    o.put(Lower[int(b shr 4)])
    o.put(Lower[int(b and 15)])

proc putHexChars(o: var Out, s: openArray[char]) =
  for c in s:
    o.put(Lower[ord(c) shr 4])
    o.put(Lower[ord(c) and 15])

proc safeAt(o: var Out, s: openArray[char], i: var int): bool =
  ## [present.terminalSafe] DEL and a C1 control (UTF-8 C2 80 to C2 9F) as a
  ## `\u` escape; true when `s[i]` began one.
  let c = s[i]
  if c == '\x7F':
    o.put("\\u007f")
    inc i
    return true
  if c == '\xC2' and i + 1 < s.len and s[i + 1] in {'\x80' .. '\x9F'}:
    o.put("\\u00")
    o.put(Lower[ord(s[i + 1]) shr 4])
    o.put(Lower[ord(s[i + 1]) and 15])
    i += 2
    return true
  false

proc jsonText(o: var Out, s: openArray[char]) =
  ## A JSON string as std/json's `escapeJson` writes it, then `terminalSafe`.
  o.put('"')
  var i = 0
  while i < s.len:
    if o.safeAt(s, i):
      continue
    let c = s[i]
    case c
    of '\n':
      o.put("\\n")
    of '\b':
      o.put("\\b")
    of '\f':
      o.put("\\f")
    of '\t':
      o.put("\\t")
    of '\v':
      o.put("\\u000b")
    of '\r':
      o.put("\\r")
    of '"':
      o.put("\\\"")
    of '\0' .. '\7':
      o.put("\\u000")
      o.put(char(ord('0') + ord(c)))
    of '\14' .. '\31':
      o.put("\\u00")
      o.put(Upper[ord(c) shr 4])
      o.put(Upper[ord(c) and 15])
    of '\\':
      o.put("\\\\")
    else:
      o.put(c)
    inc i
  o.put('"')

proc diagText(o: var Out, s: openArray[char], safe: bool) =
  ## A text string as `toDiag` writes it; with `terminalSafe` when `safe`.
  o.put('"')
  var i = 0
  while i < s.len:
    if safe and o.safeAt(s, i):
      continue
    let c = s[i]
    case c
    of '"':
      o.put("\\\"")
    of '\\':
      o.put("\\\\")
    of '\n':
      o.put("\\n")
    of '\r':
      o.put("\\r")
    of '\t':
      o.put("\\t")
    elif c < ' ':
      o.put("\\u00")
      o.put(Lower[ord(c) shr 4])
      o.put(Lower[ord(c) and 15])
    else:
      o.put(c)
    inc i
  o.put('"')

proc diag(o: var Out, v: CborValue, safe: bool) =
  ## `toDiag`'s notation.
  case v.kind
  of ckUint:
    o.putUint(v.uint)
  of ckNint:
    o.put('-')
    o.putNintMagnitude(v.nint)
  of ckBytes:
    o.put("h'")
    o.putHex(v.bytes)
    o.put('\'')
  of ckText:
    if v.validUtf8:
      o.diagText(v.text, safe)
    else:
      o.put("h'")
      o.putHexChars(v.text)
      o.put("' / invalid UTF-8 text /")
  of ckArray:
    o.put('[')
    for i, x in v.items:
      if i > 0:
        o.put(", ")
      o.diag(x, safe)
    o.put(']')
  of ckMap:
    o.put('{')
    for i, (k, x) in v.entries:
      if i > 0:
        o.put(", ")
      o.diag(k, safe)
      o.put(": ")
      o.diag(x, safe)
    o.put('}')
  of ckTag:
    o.putUint(v.tag)
    o.put('(')
    o.diag(v.content, safe)
    o.put(')')
  of ckSimple:
    case v.simple
    of SimpleFalse:
      o.put("false")
    of SimpleTrue:
      o.put("true")
    of SimpleNull:
      o.put("null")
    of SimpleUndefined:
      o.put("undefined")
    else:
      o.put("simple(")
      o.putUint(v.simple)
      o.put(')')
  of ckFloat:
    # Logos CBOR has no floats (INTERFACE §4.4); a display may still meet one.
    var t = toDiag(v)
    o.put(t)
    wipe(t)

template exact(o: untyped, body: untyped): string =
  ## Runs `body` on a counting `Out`, then on one writing into a buffer of
  ## the counted size.
  var o = Out(count: true)
  body
  var exactBuf = newString(o.n)
  o = Out(count: false, buf: move exactBuf)
  body
  doAssert o.pos == o.buf.len
  move o.buf

proc diagOf(v: CborValue): string =
  ## `toDiag(v)` in a buffer of its exact size, for a JSON key.
  exact(k):
    k.diag(v, safe = false)

proc json(o: var Out, v: CborValue)

proc jsonMap(o: var Out, v: CborValue) =
  ## [render.jsonOf] Keys by their text, any other by its diagnostic
  ## notation; as std/json's ordered table, a key given twice keeps its first
  ## place and its last value. Only a key that is not text can repeat another.
  o.put('{')
  var mixed = false
  for (k, _) in v.entries:
    if k.kind != ckText:
      mixed = true
  if not mixed:
    for i, (k, x) in v.entries:
      if i > 0:
        o.put(',')
      o.jsonText(k.text)
      o.put(':')
      o.json(x)
  else:
    var keys = newSeq[string](v.entries.len)
    for i, (k, _) in v.entries:
      keys[i] = (if k.kind == ckText: k.text else: diagOf(k))
    var first = true
    for i in 0 ..< keys.len:
      var seen = false
      for j in 0 ..< i:
        if keys[j] == keys[i]:
          seen = true
          break
      if seen:
        continue
      var last = i
      for j in i + 1 ..< keys.len:
        if keys[j] == keys[i]:
          last = j
      if not first:
        o.put(',')
      first = false
      o.jsonText(keys[i])
      o.put(':')
      o.json(v.entries[last].value)
    for k in keys.mitems:
      wipe(k)
  o.put('}')

proc json(o: var Out, v: CborValue) =
  ## [G89; render.jsonOf] as std/json's `$` writes it.
  case v.kind
  of ckUint:
    if v.uint > JsonSafe:
      o.put('"')
      o.putUint(v.uint)
      o.put('"')
    else:
      o.putUint(v.uint)
  of ckNint:
    if v.nint >= JsonSafe:
      o.put("\"-")
      o.putNintMagnitude(v.nint)
      o.put('"')
    else:
      o.put('-')
      o.putUint(v.nint + 1)
  of ckBytes:
    o.put('"')
    o.putHex(v.bytes)
    o.put('"')
  of ckText:
    o.jsonText(v.text)
  of ckArray:
    o.put('[')
    for i, x in v.items:
      if i > 0:
        o.put(',')
      o.json(x)
    o.put(']')
  of ckMap:
    o.jsonMap(v)
  of ckTag:
    o.put("{\"tag\":")
    if v.tag > JsonSafe:
      o.put('"')
      o.putUint(v.tag)
      o.put('"')
    else:
      o.putUint(v.tag)
    o.put(",\"value\":")
    o.json(v.content)
    o.put('}')
  of ckSimple:
    case v.simple
    of SimpleFalse:
      o.put("false")
    of SimpleTrue:
      o.put("true")
    of SimpleNull:
      o.put("null")
    else:
      o.put("{\"simple\":")
      o.putUint(v.simple)
      o.put('}')
  of ckFloat:
    var t = toDiag(v)
    o.jsonText(t)
    wipe(t)

proc markedJsonLine*(deployment, command: string, v: CborValue): string =
  ## [G89] `{"deployment", "command", "status": "ok", "result"}` and a
  ## newline, as `present.done` writes a response's envelope.
  exact(o):
    o.put("{\"deployment\":")
    o.jsonText(deployment)
    o.put(",\"command\":")
    o.jsonText(command)
    o.put(",\"status\":\"ok\",\"result\":")
    o.json(v)
    o.put("}\n")

proc markedTextLine*(v: CborValue): string =
  ## The response in diagnostic notation and a newline.
  exact(o):
    o.diag(v, safe = true)
    o.put('\n')

{.pop.}
