## TRANSPORT §1.1 and §1.3 as data: a reader for the envelope CDDL, and a checker
## of decoded messages against it.
##
## The envelope CDDL is outside the cdCDDLe subset: integer map keys, `any`, an
## unsized `uint`, `lo..hi` ranges and `{ * tstr => any }` payload maps. cdCDDLe
## has no generic mode for it (G15), so this reader takes exactly the constructs
## the mirrored blocks use and rejects anything else. A spec revision that adds a
## construct then fails when the pinned documents load, instead of being
## misread [IMPL-DECISION G15].
##
## Names outside the documents resolve to declarations of the pinned common
## schema (`logos.schema_commitment`, `logos.error_code`, `logos.error_detail`),
## which are checked with the INTERFACE §5.1 schema model.

{.push raises: [].}

import std/[strutils, tables]
import results
import ../cbor
import ../commitment

export results

type
  PKind* = enum
    pkUint ## `uint`: any CBOR unsigned integer
    pkIntLit ## an integer literal
    pkIntRange ## `lo..hi`
    pkText ## `tstr`, optionally with `.size`
    pkBytes ## `bstr`, optionally with `.size`
    pkTextLit ## a text literal
    pkAny ## `any`
    pkMap ## a closed map of members
    pkTextMap ## `{ * tstr => any }`: an opaque schema payload map
    pkRef ## a rule of these documents
    pkCommon ## a declaration of the pinned common schema
    pkChoice ## `a / b`

  PKey* = object
    case isInt*: bool
    of true:
      intKey*: uint64
    of false:
      textKey*: string

  PMember* = object
    key*: PKey
    optional*: bool
    typ*: PType

  PType* = ref PTypeObj

  PTypeObj* = object
    case kind*: PKind
    of pkIntLit:
      lit*: int64
    of pkIntRange:
      lo*, hi*: int64
    of pkText, pkBytes:
      sized*: bool
      minSize*, maxSize*: uint64 ## in bytes
    of pkTextLit:
      text*: string
    of pkMap:
      members*: seq[PMember]
    of pkRef, pkCommon:
      name*: string
    of pkChoice:
      arms*: seq[PType]
    of pkUint, pkAny, pkTextMap:
      discard

  ProtocolSchema* = object
    names*: seq[string] ## rule names in document order
    rules: Table[string, PType]
    common: SchemaModel

func `$`*(k: PKey): string =
  if k.isInt:
    $k.intKey
  else:
    k.textKey

# Lexer ---------------------------------------------------------------------------

type
  TokKind = enum
    tkName
    tkInt
    tkText
    tkCtl ## a control operator such as `.size`
    tkPunct
    tkEnd

  Tok = object
    kind: TokKind
    s: string
    i: int64
    line: int

func isNameStart(c: char): bool =
  c in {'a' .. 'z', 'A' .. 'Z', '_'}

func isNameChar(c: char): bool =
  c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-', '.'}

func lex(src: string): Result[seq[Tok], string] =
  var toks: seq[Tok]
  var i = 0
  var line = 1
  while i < src.len:
    let c = src[i]
    if c == '\n':
      inc line
      inc i
    elif c in {' ', '\t', '\r'}:
      inc i
    elif c == ';':
      while i < src.len and src[i] != '\n':
        inc i
    elif c == '"':
      var j = i + 1
      while j < src.len and src[j] != '"':
        if src[j] in {'\\', '\n'}:
          return err("line " & $line & ": unsupported text literal")
        inc j
      if j >= src.len:
        return err("line " & $line & ": unterminated text literal")
      toks.add(Tok(kind: tkText, s: src[i + 1 ..< j], line: line))
      i = j + 1
    elif c in {'0' .. '9'} or
        (c == '-' and i + 1 < src.len and src[i + 1] in {'0' .. '9'}):
      var j = i + 1
      while j < src.len and src[j] in {'0' .. '9'}:
        inc j
      let n =
        try:
          parseBiggestInt(src[i ..< j])
        except ValueError:
          return err("line " & $line & ": integer out of range")
      toks.add(Tok(kind: tkInt, i: n, line: line))
      i = j
    elif c.isNameStart:
      var j = i + 1
      while j < src.len and src[j].isNameChar and
          not (src[j] == '.' and j + 1 < src.len and src[j + 1] == '.'):
        inc j
      toks.add(Tok(kind: tkName, s: src[i ..< j], line: line))
      i = j
    elif c == '.':
      if i + 1 < src.len and src[i + 1] == '.':
        toks.add(Tok(kind: tkPunct, s: "..", line: line))
        i += 2
      else:
        var j = i + 1
        while j < src.len and src[j] in {'a' .. 'z'}:
          inc j
        toks.add(Tok(kind: tkCtl, s: src[i ..< j], line: line))
        i = j
    elif c == '=':
      if i + 1 < src.len and src[i + 1] == '>':
        toks.add(Tok(kind: tkPunct, s: "=>", line: line))
        i += 2
      else:
        toks.add(Tok(kind: tkPunct, s: "=", line: line))
        inc i
    elif c in {'/', '{', '}', '(', ')', ',', ':', '?', '*'}:
      toks.add(Tok(kind: tkPunct, s: $c, line: line))
      inc i
    else:
      return err("line " & $line & ": unexpected character " & c.repr)
  toks.add(Tok(kind: tkEnd, line: line))
  ok(toks)

# Parser ----------------------------------------------------------------------------

type Parser = object
  toks: seq[Tok]
  pos: int

func peek(p: Parser): Tok =
  p.toks[p.pos]

func isPunct(t: Tok, s: string): bool =
  t.kind == tkPunct and t.s == s

func fail(t: Tok, msg: string): string =
  "line " & $t.line & ": " & msg

func next(p: var Parser): Tok =
  let t = p.toks[p.pos]
  if p.pos < p.toks.high:
    inc p.pos
  t

func expect(p: var Parser, s: string): Result[void, string] =
  let t = p.next
  if not t.isPunct(s):
    return err(t.fail("expected `" & s & "`"))
  ok()

func expectInt(p: var Parser): Result[int64, string] =
  let t = p.next
  if t.kind != tkInt:
    return err(t.fail("expected an integer"))
  ok(t.i)

func parseType(p: var Parser): Result[PType, string]

func parseSize(p: var Parser, t: PType): Result[void, string] =
  ## `.size n` or `.size (lo..hi)` on `tstr` / `bstr`.
  let ctl = p.next
  if ctl.s != ".size":
    return err(ctl.fail("unsupported control operator " & ctl.s))
  if t.kind notin {pkText, pkBytes}:
    return err(ctl.fail(".size on something other than tstr or bstr"))
  var lo, hi: int64
  if p.peek.isPunct("("):
    discard p.next
    lo = ?p.expectInt
    ?p.expect("..")
    hi = ?p.expectInt
    ?p.expect(")")
  else:
    lo = ?p.expectInt
    hi = lo
  if lo < 0 or hi < lo:
    return err(ctl.fail("invalid size range"))
  t.sized = true
  t.minSize = uint64(lo)
  t.maxSize = uint64(hi)
  ok()

func parseMap(p: var Parser): Result[PType, string] =
  ## After `{`: `* tstr => any }`, or members `[?] key: type` separated by commas.
  if p.peek.isPunct("*"):
    discard p.next
    for want in ["tstr", "=>", "any"]:
      let t = p.next
      if t.s != want:
        return err(t.fail("only `{ * tstr => any }` is supported"))
    ?p.expect("}")
    return ok(PType(kind: pkTextMap))
  var members: seq[PMember]
  while not p.peek.isPunct("}"):
    var m = PMember()
    if p.peek.isPunct("?"):
      discard p.next
      m.optional = true
    let k = p.next
    case k.kind
    of tkInt:
      if k.i < 0:
        return err(k.fail("negative map key"))
      m.key = PKey(isInt: true, intKey: uint64(k.i))
    of tkName:
      if '.' in k.s:
        return err(k.fail("a map key is a bare word"))
      m.key = PKey(isInt: false, textKey: k.s)
    else:
      return err(k.fail("expected a map key"))
    for other in members:
      if $other.key == $m.key and other.key.isInt == m.key.isInt:
        return err(k.fail("duplicate map key " & $m.key))
    ?p.expect(":")
    m.typ = ?p.parseType
    members.add(m)
    if p.peek.isPunct(","):
      discard p.next
    elif not p.peek.isPunct("}"):
      return err(p.peek.fail("expected `,` or `}`"))
  discard p.next
  ok(PType(kind: pkMap, members: members))

func parseType1(p: var Parser): Result[PType, string] =
  let t = p.next
  var r: PType
  case t.kind
  of tkInt:
    if p.peek.isPunct(".."):
      discard p.next
      let hi = ?p.expectInt
      if hi < t.i:
        return err(t.fail("empty range"))
      r = PType(kind: pkIntRange, lo: t.i, hi: hi)
    else:
      r = PType(kind: pkIntLit, lit: t.i)
  of tkText:
    r = PType(kind: pkTextLit, text: t.s)
  of tkName:
    r =
      case t.s
      of "uint":
        PType(kind: pkUint)
      of "tstr":
        PType(kind: pkText)
      of "bstr":
        PType(kind: pkBytes)
      of "any":
        PType(kind: pkAny)
      else:
        PType(kind: pkRef, name: t.s)
  of tkPunct:
    if t.s != "{":
      return err(t.fail("unexpected `" & t.s & "`"))
    r = ?p.parseMap
  else:
    return err(t.fail("expected a type"))
  if p.peek.kind == tkCtl:
    ?p.parseSize(r)
  ok(r)

func parseType(p: var Parser): Result[PType, string] =
  var arms = @[?p.parseType1]
  while p.peek.isPunct("/"):
    discard p.next
    arms.add(?p.parseType1)
  if arms.len == 1:
    ok(arms[0])
  else:
    ok(PType(kind: pkChoice, arms: arms))

func parseRules(src: string, s: var ProtocolSchema): Result[void, string] =
  var p = Parser(toks: ?lex(src))
  while p.peek.kind != tkEnd:
    let name = p.next
    if name.kind != tkName:
      return err(name.fail("expected a rule name"))
    ?p.expect("=")
    let t = ?p.parseType
    if name.s in s.rules:
      return err(name.fail("duplicate rule " & name.s))
    s.rules[name.s] = t
    s.names.add(name.s)
  ok()

func resolveRefs(s: var ProtocolSchema, t: PType): Result[void, string] =
  case t.kind
  of pkRef:
    if t.name notin s.rules:
      if s.common.find(t.name).isNone:
        return err("unresolved name " & t.name)
      t[] = PTypeObj(kind: pkCommon, name: t.name)
  of pkMap:
    for m in t.members:
      ?s.resolveRefs(m.typ)
  of pkChoice:
    for a in t.arms:
      ?s.resolveRefs(a)
  else:
    discard
  ok()

proc loadProtocolSchema*(
    documents: openArray[string], common: SchemaModel
): Result[ProtocolSchema, string] =
  ## The rules of `documents`, with names they do not define resolved against the
  ## common schema `common`.
  var s = ProtocolSchema(common: common)
  for d in documents:
    ?parseRules(d, s)
  for name in s.names:
    ?s.resolveRefs(s.rules.getOrDefault(name, nil))
  ok(s)

func rule*(s: ProtocolSchema, name: string): Opt[PType] =
  let t = s.rules.getOrDefault(name, nil)
  if t.isNil:
    Opt.none(PType)
  else:
    Opt.some(t)

func deref*(s: ProtocolSchema, t: PType): PType =
  ## `t` with rule references followed.
  var x = t
  var hops = 0
  while x.kind == pkRef and hops <= s.names.len:
    x = s.rule(x.name).get(x)
    inc hops
  x

func mapArms*(s: ProtocolSchema, t: PType): seq[PType] =
  ## The closed maps a (possibly choice-of-maps) rule allows, in document order.
  let x = s.deref(t)
  case x.kind
  of pkMap:
    @[x]
  of pkChoice:
    var all: seq[PType]
    for a in x.arms:
      all.add(s.mapArms(a))
    all
  else:
    @[]

func intValue*(s: ProtocolSchema, t: PType): Opt[int64] =
  ## The value of an integer-literal rule.
  let x = s.deref(t)
  if x.kind == pkIntLit:
    Opt.some(x.lit)
  else:
    Opt.none(int64)

# Checking ---------------------------------------------------------------------------

func keyMatches(k: PKey, v: CborValue): bool =
  if k.isInt:
    v.kind == ckUint and v.uint == k.intKey
  else:
    v.kind == ckText and v.validUtf8 and v.text == k.textKey

func member*(t: PType, key: CborValue): Opt[PMember] =
  for m in t.members:
    if m.key.keyMatches(key):
      return Opt.some(m)
  Opt.none(PMember)

func inSize(t: PType, n: int): bool =
  not t.sized or (uint64(n) >= t.minSize and uint64(n) <= t.maxSize)

func matches*(s: ProtocolSchema, t: PType, v: CborValue, depth = 0): bool =
  ## Whether the decoded value `v` is valid under `t`. Maps are closed.
  if v.isNil or depth > s.names.len + 64:
    return false
  case t.kind
  of pkUint:
    v.kind == ckUint
  of pkIntLit:
    v.getInt64 == Opt.some(t.lit)
  of pkIntRange:
    let n = v.getInt64
    n.isSome and n.get >= t.lo and n.get <= t.hi
  of pkText:
    v.kind == ckText and v.validUtf8 and t.inSize(v.text.len)
  of pkBytes:
    v.kind == ckBytes and t.inSize(v.bytes.len)
  of pkTextLit:
    v.kind == ckText and v.validUtf8 and v.text == t.text
  of pkAny:
    true
  of pkTextMap:
    # [IMPL] Only the shape the envelope names: a map with text keys. What the
    # text holds, UTF-8 validity included, is the schema-aware boundary's to
    # judge (INTERFACE §4.5), as it would be in direct mode (TRANSPORT Abstract).
    if v.kind != ckMap:
      return false
    for (k, _) in v.entries:
      if k.kind != ckText:
        return false
    true
  of pkMap:
    if v.kind != ckMap:
      return false
    for (k, _) in v.entries:
      if t.member(k).isNone:
        return false
    for m in t.members:
      var found = false
      for (k, x) in v.entries:
        if m.key.keyMatches(k):
          found = true
          if not s.matches(m.typ, x, depth + 1):
            return false
      if not found and not m.optional:
        return false
    true
  of pkRef:
    let r = s.rule(t.name)
    r.isSome and s.matches(r.get, v, depth + 1)
  of pkCommon:
    let d = s.common.find(t.name)
    d.isSome and schemaSet(s.common).validates(0, d.get.body, v)
  of pkChoice:
    for a in t.arms:
      if s.matches(a, v, depth + 1):
        return true
    false
