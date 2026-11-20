## The CLI's arguments (Tier 5 step N-2; D26 (a); DECISIONS G349): a call's
## request value, typed from the method's request rule in the provider's
## accepted contract set. docs/DAEMON.md §7a.
##
## - `key=value`: one scalar field of the request map. Integers in decimal,
##   `true`/`false`, text as given, byte strings as hex, a text-literal choice
##   as its text. A structured field (map, list, tuple) is refused: the whole
##   request goes with `--json`.
## - `key=@FILE`: a text field (the bytes must be UTF-8) or a byte-string field,
##   from a descriptor the launcher passed.
## - `--json`: the whole request as one JSON object, read as G89 writes it:
##   byte strings as hex text, integers beyond ±2^53 as decimal text. JSON
##   numbers with a fraction or an exponent are floats, which Logos CBOR does
##   not have (INTERFACE §4.4); duplicate object keys are refused.
##
## Where the alternatives of a choice read the same input as different values,
## the input is refused as ambiguous rather than one reading picked: the
## schema's canonical arm order (COMMITMENT §9.1) is not the rule's order, and
## no order would be the user's. The value is validated against the request
## rule before it is sent; the provider's host validates it again.

{.push raises: [], gcsafe.}

import std/strutils except fromHex
from std/json import escapeJson
import results
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/base/hex
import logos_sdk/iface/surface

export results

const
  MaxJsonDepth = 256 ## [IMPL] nesting of `--json` arrays and objects
  JsonSafe = 9_007_199_254_740_992'u64 ## 2^53, G89's integer bound
  MaxRefHops = 64

type
  ArgInput* = object ## One `key=value` or `key=@FILE`.
    name*: string
    case isFile*: bool
    of true:
      data*: seq[byte]
    of false:
      text*: string

  RequestShape* = object ## A method's request rule, ready for typing.
    set: SchemaSet
    body: SchemaNode
    methodName*: string ## the bare method name, for messages

  Conv = object ## Why a node does not read an input.
    hard: bool ## refuse outright: not "this alternative does not apply"
    structured: bool ## the node is a map, list or tuple
    msg: string

func mismatch(msg: string, structured = false): Conv =
  Conv(hard: false, structured: structured, msg: msg)

func refusal(msg: string): Conv =
  Conv(hard: true, msg: msg)

# The request rule --------------------------------------------------------------------

func shapeOf(
    cs: ContractSet, doc: int, decl, what: string
): Result[RequestShape, string] =
  ## [SPEC INTERFACE §1.2] The declaration `decl` in the schema set of the
  ## document `doc` (the one the payload validator uses).
  let docs = cs.documents
  if doc < 0 or doc >= docs.len:
    return err(what & " names no document of the contract set")
  let set = schemaSetFor(docs[doc].model, cs.context)
  let d = set.docs[0].find(decl)
  if d.isNone or d.get.kind == dkMethod:
    return err(decl & " is not declared")
  ok(RequestShape(set: set, body: d.get.body, methodName: what))

func requestShape*(cs: ContractSet, m: SurfaceMethod): Result[RequestShape, string] =
  ## `m`'s request rule.
  shapeOf(cs, m.doc, m.request, m.bare)

func responseShape*(cs: ContractSet, m: SurfaceMethod): Result[RequestShape, string] =
  ## `m`'s response rule, for `describe`.
  shapeOf(cs, m.doc, m.response, m.bare)

func eventShape*(cs: ContractSet, e: SurfaceEvent): Result[RequestShape, string] =
  ## [SPEC INTERFACE §1.5] `e`'s payload rule: the event declaration's body.
  let docs = cs.documents
  if e.doc < 0 or e.doc >= docs.len:
    return err(e.id & " names no document of the contract set")
  let set = schemaSetFor(docs[e.doc].model, cs.context)
  let d = set.docs[0].find(e.id)
  if d.isNone or d.get.kind != dkEvent:
    return err(e.id & " is not declared as an event")
  ok(RequestShape(set: set, body: d.get.body, methodName: e.id))

func deref(s: SchemaSet, doc: int, n: SchemaNode): Result[(int, SchemaNode), string] =
  ## The node a chain of references names, and the document it is in.
  var d = doc
  var x = n
  var hops = 0
  while x.kind in {snLocalRef, snImportedRef}:
    inc hops
    if hops > MaxRefHops:
      return err("a reference chain longer than " & $MaxRefHops)
    if x.kind == snLocalRef:
      let decl = s.docs[d].find(x.target)
      if decl.isNone or decl.get.kind == dkMethod:
        return err(x.target & " is not declared")
      x = decl.get.body
    else:
      let r = s.resolveImport(x.imported).valueOr:
        return err("an imported reference resolves to no named type")
      d = r[0]
      x = r[1].body
  ok((d, x))

func typeText(s: SchemaSet, doc: int, n: SchemaNode, depth = 0): string =
  ## A short description of a field's type, for messages and `describe`.
  let refName =
    case n.kind
    of snLocalRef: n.target
    else: ""
  let r = deref(s, doc, n)
  if r.isErr:
    return "?"
  let (d, x) = r.get
  case x.kind
  of snPrimitive:
    $x.scalar
  of snLiteral:
    case x.literal.kind
    of skTstr:
      escapeJson(x.literal.text)
    of skBool:
      $x.literal.boolean
    of skUint8, skUint16, skUint32, skUint64:
      $x.literal.unsigned
    of skInt8, skInt16, skInt32, skInt64:
      $x.literal.signed
    of skBstr:
      "h'" & toHex(x.literal.bytes).toLowerAscii & "'"
  of snMap:
    if refName.len > 0:
      refName & " (map)"
    else:
      "map"
  of snList:
    if refName.len > 0:
      refName & " (list)"
    else:
      "list"
  of snTuple:
    if refName.len > 0:
      refName & " (tuple)"
    else:
      "tuple"
  of snChoice:
    if depth > 0 and refName.len > 0:
      refName
    else:
      var parts: seq[string] = @[]
      for a in x.arms:
        parts.add(typeText(s, d, a, depth + 1))
      parts.join(" / ")
  of snLocalRef, snImportedRef:
    "?"

func ruleText*(sh: RequestShape): string =
  ## The rule's type, as `describe` shows it.
  typeText(sh.set, 0, sh.body)

func isStructured(s: SchemaSet, doc: int, n: SchemaNode): bool =
  let r = deref(s, doc, n)
  if r.isErr:
    return false
  let (_, x) = r.get
  x.kind in {snMap, snList, snTuple}

func topMap(sh: RequestShape): Result[(int, SchemaNode), string] =
  let (d, x) = ?deref(sh.set, 0, sh.body)
  if x.kind != snMap:
    return err(
      "the request of " & sh.methodName &
        " is not one map: give the whole request with --json"
    )
  ok((d, x))

func fieldList*(sh: RequestShape): string =
  ## The request's fields: `name: type`, `name?:` for an optional one, and
  ## `(--json)` after a structured one.
  let t = sh.topMap()
  if t.isErr:
    return "(" & typeText(sh.set, 0, sh.body) & ")"
  let (d, m) = t.get
  if m.fields.len == 0:
    return "(none)"
  var parts: seq[string] = @[]
  for f in m.fields:
    var p = f.name & (if f.optional: "?: " else: ": ") & typeText(sh.set, d, f.node)
    if isStructured(sh.set, d, f.node):
      p.add(" (--json)")
    parts.add(p)
  parts.join(", ")

# Scalars -----------------------------------------------------------------------------

func parseMagnitude(s: string): Opt[uint64] =
  ## Decimal digits only, at least one, within uint64.
  if s.len == 0:
    return Opt.none(uint64)
  var v = 0'u64
  for c in s:
    if c notin {'0' .. '9'}:
      return Opt.none(uint64)
    let digit = uint64(ord(c) - ord('0'))
    if v > (high(uint64) - digit) div 10:
      return Opt.none(uint64)
    v = v * 10 + digit
  Opt.some(v)

func unsignedMax(k: ScalarKind): uint64 =
  case k
  of skUint8:
    255'u64
  of skUint16:
    65_535'u64
  of skUint32:
    4_294_967_295'u64
  else:
    high(uint64)

func signedRange(k: ScalarKind): (int64, int64) =
  case k
  of skInt8:
    (-128'i64, 127'i64)
  of skInt16:
    (-32_768'i64, 32_767'i64)
  of skInt32:
    (-2_147_483_648'i64, 2_147_483_647'i64)
  else:
    (low(int64), high(int64))

func integerFromText(k: ScalarKind, text: string): Result[CborValue, Conv] =
  ## A decimal integer of kind `k`, in its range.
  let neg = text.len > 0 and text[0] == '-'
  let mag = parseMagnitude(
    if neg:
      text[1 .. ^1]
    else:
      text
  ).valueOr:
    return err(mismatch(escapeJson(text) & " is not a decimal " & $k))
  case k
  of skUint8, skUint16, skUint32, skUint64:
    if neg or mag > unsignedMax(k):
      return err(mismatch(escapeJson(text) & " is outside " & $k))
    ok(cbor(mag))
  else:
    let (lo, hi) = signedRange(k)
    if neg:
      # -mag >= lo  <=>  mag - 1 <= -(lo + 1)
      if mag == 0:
        return ok(cbor(0'u64))
      if mag - 1 > uint64(-(lo + 1)):
        return err(mismatch(escapeJson(text) & " is outside " & $k))
      ok(cborNint(mag - 1))
    else:
      if mag > uint64(hi):
        return err(mismatch(escapeJson(text) & " is outside " & $k))
      ok(cbor(mag))

func sizeOk(n: SchemaNode, len: int): bool =
  if n.size.isNone:
    return true
  let (lo, hi) = n.size.get
  uint64(len) >= lo and uint64(len) <= hi

func sized(n: SchemaNode, v: CborValue, len: int): Result[CborValue, Conv] =
  if not sizeOk(n, len):
    let (lo, hi) = n.size.get
    return
      err(mismatch($n.scalar & " of " & $len & " bytes, not " & $lo & " to " & $hi))
  ok(v)

func scalarFromText(n: SchemaNode, text: string): Result[CborValue, Conv] =
  case n.scalar
  of skBool:
    case text
    of "true":
      ok(cbor(true))
    of "false":
      ok(cbor(false))
    else:
      err(mismatch(escapeJson(text) & " is not true or false"))
  of skUint8, skUint16, skUint32, skUint64, skInt8, skInt16, skInt32, skInt64:
    integerFromText(n.scalar, text)
  of skTstr:
    sized(n, cbor(text), text.len)
  of skBstr:
    let b = fromHex(text).valueOr:
      return err(mismatch(escapeJson(text) & " is not hex"))
    sized(n, cbor(b), b.len)

func literalValue(l: ScalarData): CborValue =
  case l.kind
  of skBool:
    cbor(l.boolean)
  of skUint8, skUint16, skUint32, skUint64:
    cbor(l.unsigned)
  of skInt8, skInt16, skInt32, skInt64:
    cbor(l.signed)
  of skTstr:
    cbor(l.text)
  of skBstr:
    cbor(l.bytes)

func anyInteger(text: string): Opt[CborValue] =
  ## A decimal integer of any width.
  let a = integerFromText(skInt64, text)
  if a.isOk:
    return Opt.some(a.get)
  let b = integerFromText(skUint64, text)
  if b.isOk:
    return Opt.some(b.get)
  Opt.none(CborValue)

func literalFromText(l: ScalarData, text: string): Result[CborValue, Conv] =
  let want = literalValue(l)
  var got = Opt.none(CborValue)
  case l.kind
  of skTstr:
    got = Opt.some(cbor(text))
  of skBool:
    if text == "true":
      got = Opt.some(cbor(true))
    elif text == "false":
      got = Opt.some(cbor(false))
  of skUint8, skUint16, skUint32, skUint64, skInt8, skInt16, skInt32, skInt64:
    got = anyInteger(text)
  of skBstr:
    let b = fromHex(text)
    if b.isOk:
      got = Opt.some(cbor(b.get))
  if got.isSome and encodeCbor(got.get) == encodeCbor(want):
    return ok(want)
  err(mismatch(escapeJson(text) & " is not " & toDiag(want)))

# Choices -----------------------------------------------------------------------------

type Reader =
  proc(d: int, arm: SchemaNode): Result[CborValue, Conv] {.gcsafe, raises: [].}

proc choose(
    s: SchemaSet, d: int, x: SchemaNode, path: string, read: Reader
): Result[CborValue, Conv] =
  ## [G349] The one value the alternatives read; none is a mismatch, several
  ## different ones are ambiguous.
  var found: seq[CborValue] = @[]
  var seen: seq[seq[byte]] = @[]
  var anyStructured = false
  var reasons: seq[string] = @[]
  for arm in x.arms:
    let r = read(d, arm)
    if r.isOk:
      if s.validatePath(d, arm, r.get).isErr:
        continue
      let e = encodeCbor(r.get)
      if e notin seen:
        seen.add(e)
        found.add(r.get)
    elif r.error.hard:
      return err(r.error)
    else:
      anyStructured = anyStructured or r.error.structured
      if r.error.msg.len > 0 and r.error.msg notin reasons:
        reasons.add(r.error.msg)
  if found.len == 1:
    return ok(found[0])
  if found.len > 1:
    return err(
      refusal(
        path & ": the alternatives of " & typeText(s, d, x) &
          " read it as different values; it is ambiguous"
      )
    )
  var msg = "matches none of " & typeText(s, d, x)
  if reasons.len > 0:
    msg.add(" (" & reasons.join("; ") & ")")
  err(mismatch(msg, anyStructured))

# key=value and key=@FILE -------------------------------------------------------------

proc readText(
    s: SchemaSet, doc: int, n: SchemaNode, text, path: string
): Result[CborValue, Conv] =
  let (d, x) = deref(s, doc, n).valueOr:
    return err(refusal(path & ": " & error))
  case x.kind
  of snPrimitive:
    scalarFromText(x, text)
  of snLiteral:
    literalFromText(x.literal, text)
  of snMap, snList, snTuple:
    err(mismatch("structured", structured = true))
  of snChoice:
    choose(
      s,
      d,
      x,
      path,
      proc(dd: int, arm: SchemaNode): Result[CborValue, Conv] =
        readText(s, dd, arm, text, path),
    )
  of snLocalRef, snImportedRef:
    err(refusal(path & ": an unresolved reference"))

proc readFileData(
    s: SchemaSet, doc: int, n: SchemaNode, data: seq[byte], path: string
): Result[CborValue, Conv] =
  let (d, x) = deref(s, doc, n).valueOr:
    return err(refusal(path & ": " & error))
  case x.kind
  of snPrimitive:
    case x.scalar
    of skTstr:
      if not isValidUtf8(data):
        return err(mismatch("the file is not UTF-8 text"))
      var t = newString(data.len)
      for i, b in data:
        t[i] = char(b)
      sized(x, cbor(t), data.len)
    of skBstr:
      sized(x, cbor(data), data.len)
    else:
      err(mismatch($x.scalar & " takes key=value, not a file"))
  of snLiteral:
    err(mismatch("a literal takes key=value, not a file"))
  of snMap, snList, snTuple:
    err(mismatch("structured", structured = true))
  of snChoice:
    choose(
      s,
      d,
      x,
      path,
      proc(dd: int, arm: SchemaNode): Result[CborValue, Conv] =
        readFileData(s, dd, arm, data, path),
    )
  of snLocalRef, snImportedRef:
    err(refusal(path & ": an unresolved reference"))

proc fromArgs*(sh: RequestShape, args: openArray[ArgInput]): Result[CborValue, string] =
  ## [D26 (a); G349] The request map from named arguments.
  let (d, m) = ?sh.topMap()
  var entries: seq[CborEntry] = @[]
  var given: seq[string] = @[]
  for a in args:
    if a.name in given:
      return err(a.name & " is given twice")
    given.add(a.name)
    var field = Opt.none(SchemaField)
    for f in m.fields:
      if f.name == a.name:
        field = Opt.some(f)
    if field.isNone:
      return err(
        sh.methodName & " has no field " & escapeJson(a.name) & "; its fields: " &
          sh.fieldList()
      )
    let f = field.get
    let r =
      if a.isFile:
        readFileData(sh.set, d, f.node, a.data, a.name)
      else:
        readText(sh.set, d, f.node, a.text, a.name)
    if r.isErr:
      let e = r.error
      if e.structured and not e.hard:
        return err(
          a.name & " is " & typeText(sh.set, d, f.node) &
            ": give the whole request with --json"
        )
      if e.hard:
        return err(e.msg)
      return err(a.name & ": " & e.msg)
    entries.add((cbor(a.name), r.get))
  var missing: seq[string] = @[]
  for f in m.fields:
    if not f.optional and f.name notin given:
      missing.add(f.name)
  if missing.len > 0:
    return err(
      sh.methodName & " needs " & missing.join(", ") & "; its fields: " & sh.fieldList()
    )
  ok(cborMap(entries))

# --json --------------------------------------------------------------------------------

type
  JKind = enum
    jNull
    jBool
    jInt
    jFloat
    jStr
    jArr
    jObj

  JVal = ref object
    case kind: JKind
    of jNull:
      discard
    of jBool:
      b: bool
    of jInt, jFloat:
      num: string ## the number's text
    of jStr:
      s: string
    of jArr:
      items: seq[JVal]
    of jObj:
      keys: seq[string]
      vals: seq[JVal]

  JParser = object
    i: int
    depth: int

func jerr(p: JParser, msg: string): string =
  "--json at byte " & $p.i & ": " & msg

proc skipWs(p: var JParser, t: string) =
  while p.i < t.len and t[p.i] in {' ', '\t', '\n', '\r'}:
    inc p.i

func hexVal(c: char): int =
  case c
  of '0' .. '9':
    ord(c) - ord('0')
  of 'a' .. 'f':
    ord(c) - ord('a') + 10
  of 'A' .. 'F':
    ord(c) - ord('A') + 10
  else:
    -1

proc addUtf8(s: var string, cp: int) =
  if cp < 0x80:
    s.add(char(cp))
  elif cp < 0x800:
    s.add(char(0xC0 or (cp shr 6)))
    s.add(char(0x80 or (cp and 0x3F)))
  elif cp < 0x10000:
    s.add(char(0xE0 or (cp shr 12)))
    s.add(char(0x80 or ((cp shr 6) and 0x3F)))
    s.add(char(0x80 or (cp and 0x3F)))
  else:
    s.add(char(0xF0 or (cp shr 18)))
    s.add(char(0x80 or ((cp shr 12) and 0x3F)))
    s.add(char(0x80 or ((cp shr 6) and 0x3F)))
    s.add(char(0x80 or (cp and 0x3F)))

proc hex4(p: var JParser, t: string): Result[int, string] =
  if p.i + 4 > t.len:
    return err(p.jerr("a short \\u escape"))
  var v = 0
  for k in 0 ..< 4:
    let h = hexVal(t[p.i + k])
    if h < 0:
      return err(p.jerr("a bad \\u escape"))
    v = v * 16 + h
  p.i += 4
  ok(v)

proc parseString(p: var JParser, t: string): Result[string, string] =
  inc p.i # the opening quote
  var s = ""
  while true:
    if p.i >= t.len:
      return err(p.jerr("an unterminated string"))
    let c = t[p.i]
    if c == '"':
      inc p.i
      return ok(s)
    if ord(c) < 0x20:
      return err(p.jerr("a control character in a string"))
    if c != '\\':
      s.add(c)
      inc p.i
      continue
    inc p.i
    if p.i >= t.len:
      return err(p.jerr("an unterminated escape"))
    let e = t[p.i]
    inc p.i
    case e
    of '"':
      s.add('"')
    of '\\':
      s.add('\\')
    of '/':
      s.add('/')
    of 'b':
      s.add('\b')
    of 'f':
      s.add('\f')
    of 'n':
      s.add('\n')
    of 'r':
      s.add('\r')
    of 't':
      s.add('\t')
    of 'u':
      var cp = ?p.hex4(t)
      if cp >= 0xD800 and cp <= 0xDBFF:
        if p.i + 1 >= t.len or t[p.i] != '\\' or t[p.i + 1] != 'u':
          return err(p.jerr("a lone surrogate"))
        p.i += 2
        let lo = ?p.hex4(t)
        if lo < 0xDC00 or lo > 0xDFFF:
          return err(p.jerr("a lone surrogate"))
        cp = 0x10000 + ((cp - 0xD800) shl 10) + (lo - 0xDC00)
      elif cp >= 0xDC00 and cp <= 0xDFFF:
        return err(p.jerr("a lone surrogate"))
      s.addUtf8(cp)
    else:
      return err(p.jerr("a bad escape"))

proc parseNumber(p: var JParser, t: string): Result[JVal, string] =
  let start = p.i
  if p.i < t.len and t[p.i] == '-':
    inc p.i
  if p.i >= t.len or t[p.i] notin {'0' .. '9'}:
    return err(p.jerr("a bad number"))
  if t[p.i] == '0':
    inc p.i
  else:
    while p.i < t.len and t[p.i] in {'0' .. '9'}:
      inc p.i
  var isFloat = false
  if p.i < t.len and t[p.i] == '.':
    isFloat = true
    inc p.i
    if p.i >= t.len or t[p.i] notin {'0' .. '9'}:
      return err(p.jerr("a bad number"))
    while p.i < t.len and t[p.i] in {'0' .. '9'}:
      inc p.i
  if p.i < t.len and t[p.i] in {'e', 'E'}:
    isFloat = true
    inc p.i
    if p.i < t.len and t[p.i] in {'+', '-'}:
      inc p.i
    if p.i >= t.len or t[p.i] notin {'0' .. '9'}:
      return err(p.jerr("a bad number"))
    while p.i < t.len and t[p.i] in {'0' .. '9'}:
      inc p.i
  let text = t[start ..< p.i]
  if isFloat:
    ok(JVal(kind: jFloat, num: text))
  else:
    ok(JVal(kind: jInt, num: text))

proc parseValue(p: var JParser, t: string): Result[JVal, string] =
  p.skipWs(t)
  if p.i >= t.len:
    return err(p.jerr("a value is missing"))
  let c = t[p.i]
  case c
  of '{':
    inc p.depth
    if p.depth > MaxJsonDepth:
      return err(p.jerr("nested deeper than " & $MaxJsonDepth))
    inc p.i
    var o = JVal(kind: jObj)
    p.skipWs(t)
    if p.i < t.len and t[p.i] == '}':
      inc p.i
      dec p.depth
      return ok(o)
    while true:
      p.skipWs(t)
      if p.i >= t.len or t[p.i] != '"':
        return err(p.jerr("an object key must be a string"))
      let k = ?p.parseString(t)
      if k in o.keys:
        return err(p.jerr("the key " & escapeJson(k) & " appears twice"))
      p.skipWs(t)
      if p.i >= t.len or t[p.i] != ':':
        return err(p.jerr("':' is missing"))
      inc p.i
      let v = ?p.parseValue(t)
      o.keys.add(k)
      o.vals.add(v)
      p.skipWs(t)
      if p.i < t.len and t[p.i] == ',':
        inc p.i
        continue
      if p.i < t.len and t[p.i] == '}':
        inc p.i
        dec p.depth
        return ok(o)
      return err(p.jerr("',' or '}' is missing"))
  of '[':
    inc p.depth
    if p.depth > MaxJsonDepth:
      return err(p.jerr("nested deeper than " & $MaxJsonDepth))
    inc p.i
    var a = JVal(kind: jArr)
    p.skipWs(t)
    if p.i < t.len and t[p.i] == ']':
      inc p.i
      dec p.depth
      return ok(a)
    while true:
      a.items.add(?p.parseValue(t))
      p.skipWs(t)
      if p.i < t.len and t[p.i] == ',':
        inc p.i
        continue
      if p.i < t.len and t[p.i] == ']':
        inc p.i
        dec p.depth
        return ok(a)
      return err(p.jerr("',' or ']' is missing"))
  of '"':
    let text = ?p.parseString(t)
    return ok(JVal(kind: jStr, s: text))
  of 't':
    if t.continuesWith("true", p.i):
      p.i += 4
      return ok(JVal(kind: jBool, b: true))
    return err(p.jerr("an unknown literal"))
  of 'f':
    if t.continuesWith("false", p.i):
      p.i += 5
      return ok(JVal(kind: jBool, b: false))
    return err(p.jerr("an unknown literal"))
  of 'n':
    if t.continuesWith("null", p.i):
      p.i += 4
      return ok(JVal(kind: jNull))
    return err(p.jerr("an unknown literal"))
  of '-', '0' .. '9':
    return p.parseNumber(t)
  else:
    return err(p.jerr("an unexpected character"))

proc parseJsonText(t: string): Result[JVal, string] =
  if not isValidUtf8(t):
    return err("--json is not UTF-8")
  var p = JParser()
  let v = ?p.parseValue(t)
  p.skipWs(t)
  if p.i != t.len:
    return err(p.jerr("text after the value"))
  ok(v)

func jsonKind(j: JVal): string =
  case j.kind
  of jNull: "null"
  of jBool: "a boolean"
  of jInt: "an integer"
  of jFloat: "a float"
  of jStr: "a string"
  of jArr: "an array"
  of jObj: "an object"

func integerFromJson(k: ScalarKind, j: JVal): Result[CborValue, Conv] =
  ## A JSON integer, or (as G89 writes it) a decimal string beyond ±2^53.
  case j.kind
  of jInt:
    integerFromText(k, j.num)
  of jStr:
    let neg = j.s.len > 0 and j.s[0] == '-'
    let mag = parseMagnitude(
      if neg:
        j.s[1 .. ^1]
      else:
        j.s
    ).valueOr:
      return err(mismatch("a string, not " & $k))
    if mag <= JsonSafe:
      return err(mismatch("an integer within ±2^53 is a JSON number, not a string"))
    integerFromText(k, j.s)
  else:
    err(mismatch(j.jsonKind & ", not " & $k))

proc readJson(
    s: SchemaSet, doc: int, n: SchemaNode, j: JVal, path: string
): Result[CborValue, Conv] =
  if j.kind == jFloat:
    return err(
      refusal(
        path & ": " & j.num & " is a float; Logos CBOR has none (INTERFACE §4.4)"
      )
    )
  let (d, x) = deref(s, doc, n).valueOr:
    return err(refusal(path & ": " & error))
  case x.kind
  of snPrimitive:
    case x.scalar
    of skBool:
      if j.kind != jBool:
        return err(mismatch(path & ": " & j.jsonKind & ", not bool"))
      ok(cbor(j.b))
    of skUint8, skUint16, skUint32, skUint64, skInt8, skInt16, skInt32, skInt64:
      let r = integerFromJson(x.scalar, j)
      if r.isErr:
        return err(mismatch(path & ": " & r.error.msg))
      r
    of skTstr:
      if j.kind != jStr:
        return err(mismatch(path & ": " & j.jsonKind & ", not tstr"))
      let r = sized(x, cbor(j.s), j.s.len)
      if r.isErr:
        return err(mismatch(path & ": " & r.error.msg))
      r
    of skBstr:
      if j.kind != jStr:
        return err(mismatch(path & ": " & j.jsonKind & ", not bstr (hex text)"))
      let b = fromHex(j.s).valueOr:
        return err(mismatch(path & ": not hex"))
      let r = sized(x, cbor(b), b.len)
      if r.isErr:
        return err(mismatch(path & ": " & r.error.msg))
      r
  of snLiteral:
    let want = literalValue(x.literal)
    var got = Opt.none(CborValue)
    case j.kind
    of jBool:
      got = Opt.some(cbor(j.b))
    of jInt:
      got = anyInteger(j.num)
    of jStr:
      case x.literal.kind
      of skTstr:
        got = Opt.some(cbor(j.s))
      of skBstr:
        let b = fromHex(j.s)
        if b.isOk:
          got = Opt.some(cbor(b.get))
      of skBool:
        discard
      of skUint8, skUint16, skUint32, skUint64, skInt8, skInt16, skInt32, skInt64:
        # G89 writes an integer beyond ±2^53 as decimal text.
        let a = integerFromJson(skInt64, j)
        let b = integerFromJson(skUint64, j)
        if a.isOk:
          got = Opt.some(a.get)
        elif b.isOk:
          got = Opt.some(b.get)
    else:
      discard
    if got.isSome and encodeCbor(got.get) == encodeCbor(want):
      return ok(want)
    err(mismatch(path & ": not " & toDiag(want)))
  of snMap:
    if j.kind != jObj:
      return err(mismatch(path & ": " & j.jsonKind & ", not a map", structured = true))
    var entries: seq[CborEntry] = @[]
    for i, k in j.keys:
      var field = Opt.none(SchemaField)
      for f in x.fields:
        if f.name == k:
          field = Opt.some(f)
      if field.isNone:
        return err(mismatch(path & ": no field " & escapeJson(k)))
      let v = ?readJson(s, d, field.get.node, j.vals[i], path & "." & k)
      entries.add((cbor(k), v))
    for f in x.fields:
      if not f.optional and f.name notin j.keys:
        return err(mismatch(path & ": " & f.name & " is missing"))
    ok(cborMap(entries))
  of snList:
    if j.kind != jArr:
      return err(mismatch(path & ": " & j.jsonKind & ", not a list", structured = true))
    var items: seq[CborValue] = @[]
    for i, e in j.items:
      items.add(?readJson(s, d, x.element, e, path & "[" & $i & "]"))
    ok(cborArray(items))
  of snTuple:
    if j.kind != jArr or j.items.len != x.items.len:
      return err(
        mismatch(
          path & ": not an array of " & $x.items.len & " items", structured = true
        )
      )
    var items: seq[CborValue] = @[]
    for i, e in j.items:
      items.add(?readJson(s, d, x.items[i], e, path & "[" & $i & "]"))
    ok(cborArray(items))
  of snChoice:
    choose(
      s,
      d,
      x,
      path,
      proc(dd: int, arm: SchemaNode): Result[CborValue, Conv] =
        readJson(s, dd, arm, j, path),
    )
  of snLocalRef, snImportedRef:
    err(refusal(path & ": an unresolved reference"))

proc fromJson*(sh: RequestShape, text: string): Result[CborValue, string] =
  ## [D26 (a); G349] The whole request from one JSON value.
  let j = ?parseJsonText(text)
  let r = readJson(sh.set, 0, sh.body, j, "request")
  if r.isErr:
    return err(r.error.msg)
  ok(r.get)

proc checkRequest*(sh: RequestShape, v: CborValue): Result[void, string] =
  ## The assembled value against the request rule, before anything is sent.
  sh.set.validatePath(0, sh.body, v).isOkOr:
    var parts: seq[string] = @[]
    for p in error:
      parts.add(toDiag(p))
    return err(
      "the request does not match " & sh.methodName & "'s request rule at [" &
        parts.join(", ") & "]"
    )
  ok()

{.pop.}
