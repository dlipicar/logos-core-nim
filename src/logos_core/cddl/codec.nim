## Schema-as-data (cdCDDLe §8): the canonical model to and from CBOR, with the
## §10 decoder checks. Every decoder error has class `decode`.

{.push raises: [].}

import ../cbor
import ./model

# Encoding ----------------------------------------------------------------------

func node(kind: uint64, fields: varargs[(uint64, CborValue)]): CborValue =
  ## Keys are inserted in ascending order, which is also their canonical order.
  var v = cborMap((cbor(0'u64), cbor(kind)))
  for (k, x) in fields:
    v.entries.add((cbor(k), x))
  v

func toCbor*(l: Literal): CborValue =
  let value =
    case l.kind
    of lkUint:
      cbor(l.uint)
    of lkNint:
      cborNint(l.nint)
    of lkBool:
      cbor(l.boolean)
    of lkTstr:
      cbor(l.text)
    of lkBstr:
      cbor(l.bytes)
  node(6, (1'u64, cbor($l.kind)), (2'u64, value))

func toCbor*(t: CddlType): CborValue =
  case t.kind
  of tkReference:
    node(3, (1'u64, cbor(t.name)))
  of tkPrimitive:
    node(5, (1'u64, cbor($t.primitive)))
  of tkLiteral:
    toCbor(t.literal)
  of tkArray, tkMap:
    var members: seq[CborValue]
    for m in t.members:
      var member = node(10)
      if m.key.isSome:
        member.entries.add(
          (cbor(1'u64), node(21, (1'u64, toCbor(textLiteral(m.key.get)))))
        )
      member.entries.add((cbor(2'u64), toCbor(m.typ)))
      case m.occurrence
      of occOne:
        discard
      of occOptional:
        member.entries.add(
          (cbor(3'u64), node(11, (1'u64, cbor(0'u64)), (2'u64, cbor(1'u64))))
        )
      of occUnbounded:
        member.entries.add(
          (cbor(3'u64), node(11, (1'u64, cbor(0'u64)), (2'u64, cbor("unbounded"))))
        )
      members.add(member)
    let group = node(9, (1'u64, cborArray(members)))
    node(if t.kind == tkArray: 7 else: 8, (1'u64, group))
  of tkChoice:
    var alternatives: seq[CborValue]
    for a in t.alternatives:
      alternatives.add(toCbor(a))
    node(12, (1'u64, cborArray(alternatives)))
  of tkRange:
    node(
      13,
      (1'u64, toCbor(t.low)),
      (2'u64, toCbor(t.high)),
      (3'u64, cbor(true)),
      (4'u64, cbor(true)),
    )
  of tkSize:
    node(
      14,
      (1'u64, cbor("size")),
      (2'u64, node(5, (1'u64, cbor($t.target)))),
      (3'u64, toCbor(t.controller)),
    )

func toCbor*(doc: CddlDocument): CborValue =
  var rules: seq[CborValue]
  for r in doc.rules:
    rules.add(node(1, (1'u64, cbor(r.name)), (3'u64, toCbor(r.typ))))
  node(0, (1'u64, cborArray(rules)), (2'u64, cbor(CanonicalModelId)))

# Decoding ----------------------------------------------------------------------

func fail(path, msg: string): CddlError =
  cddlError(ecDecode, path & ": " & msg)

func nodeKind(v: CborValue, path: string): Result[uint64, CddlError] =
  if v.kind != ckMap:
    return err(fail(path, "a node must be a map"))
  let k = v.lookup(0'u64)
  if k.isNone or k.get.kind != ckUint:
    return err(fail(path, "key 0 (node kind) must be an unsigned integer"))
  ok(k.get.uint)

func checkFields(
    v: CborValue,
    path: string,
    required: openArray[uint64],
    optional: openArray[uint64] = [],
): Result[void, CddlError] =
  for (k, _) in v.entries:
    if k.kind != ckUint or (k.uint notin required and k.uint notin optional):
      return err(fail(path, "unknown field " & toDiag(k)))
  for r in required:
    if v.lookup(r).isNone:
      return err(fail(path, "missing field " & $r))
  ok()

func field(v: CborValue, k: uint64): CborValue =
  v.lookup(k).get

func textField(v: CborValue, k: uint64, path: string): Result[string, CddlError] =
  let t = v.field(k).getText
  if t.isNone:
    return err(fail(path, "field " & $k & " must be a text string"))
  ok(t.get)

func checkName(name, path: string): Result[void, CddlError] =
  if not name.isIdentifier:
    return err(fail(path, "invalid name " & name))
  if name.parsePrimitive.isSome:
    return err(fail(path, "a rule or reference cannot be named " & name))
  ok()

func decodeLiteral(v: CborValue, path: string): Result[Literal, CddlError] =
  if ?nodeKind(v, path) != 6:
    return err(fail(path, "expected a literal node"))
  ?v.checkFields(path, [0'u64, 1, 2])
  let kind = ?v.textField(1, path)
  let x = v.field(2)
  case kind
  of "uint":
    if x.kind == ckUint:
      return ok(uintLiteral(x.uint))
  of "nint":
    if x.kind == ckNint:
      return ok(nintLiteral(x.nint))
  of "bool":
    if x.isBool:
      return ok(boolLiteral(x.getBool.get))
  of "tstr":
    let t = x.getText
    if t.isSome:
      return ok(textLiteral(t.get))
  of "bstr":
    if x.kind == ckBytes:
      return ok(bytesLiteral(x.bytes))
  else:
    return err(fail(path, "unknown literal kind " & kind))
  err(fail(path, "literal value does not match its kind " & kind))

func decodeRange(v: CborValue, path: string): Result[CddlType, CddlError] =
  ?v.checkFields(path, [0'u64, 1, 2, 3, 4])
  let
    low = ?decodeLiteral(v.field(1), path & ".low")
    high = ?decodeLiteral(v.field(2), path & ".high")
  if not low.isIntegerLiteral or not high.isIntegerLiteral:
    return err(fail(path, "range bounds must be integer literals"))
  for k in [3'u64, 4]:
    if v.field(k).getBool != Opt.some(true):
      return err(fail(path, "range field " & $k & " must be true"))
  if cmpInteger(low, high) >= 0:
    return err(fail(path, "range lower bound must be less than its upper bound"))
  ok(CddlType(kind: tkRange, low: low, high: high))

func decodePrimitive(v: CborValue, path: string): Result[Primitive, CddlError] =
  if ?nodeKind(v, path) != 5:
    return err(fail(path, "expected a primitive node"))
  ?v.checkFields(path, [0'u64, 1])
  let name = ?v.textField(1, path)
  let prim = name.parsePrimitive
  if prim.isNone:
    return err(fail(path, "unknown primitive " & name))
  ok(prim.get)

func decodeType(v: CborValue, path: string): Result[CddlType, CddlError]

func decodeMember(v: CborValue, path: string): Result[Member, CddlError] =
  if ?nodeKind(v, path) != 10:
    return err(fail(path, "expected a member node"))
  ?v.checkFields(path, [0'u64, 2], [1'u64, 3])
  var member = Member(typ: ?decodeType(v.field(2), path & ".type"))
  let key = v.lookup(1'u64)
  if key.isSome:
    let kp = path & ".key"
    if ?nodeKind(key.get, kp) != 21:
      return err(fail(kp, "expected a member-key node"))
    ?key.get.checkFields(kp, [0'u64, 1])
    let l = ?decodeLiteral(key.get.field(1), kp)
    if l.kind != lkTstr:
      return err(fail(kp, "a member key must be a tstr literal"))
    member.key = Opt.some(l.text)
  let occ = v.lookup(3'u64)
  if occ.isSome:
    let op = path & ".occurrence"
    if ?nodeKind(occ.get, op) != 11:
      return err(fail(op, "expected an occurrence node"))
    ?occ.get.checkFields(op, [0'u64, 1, 2])
    if occ.get.field(1) != cbor(0'u64):
      return err(fail(op, "the lower bound must be 0"))
    let upper = occ.get.field(2)
    if upper == cbor(1'u64):
      member.occurrence = occOptional
    elif upper == cbor("unbounded"):
      member.occurrence = occUnbounded
    else:
      return err(fail(op, "the upper bound must be 1 or \"unbounded\""))
  ok(member)

func decodeGroup(
    v: CborValue, path: string, isMap: bool
): Result[seq[Member], CddlError] =
  if ?nodeKind(v, path) != 9:
    return err(fail(path, "expected a group node"))
  ?v.checkFields(path, [0'u64, 1])
  let items = v.field(1)
  if items.kind != ckArray:
    return err(fail(path, "group members must be an array"))
  var members: seq[Member]
  for i, item in items.items:
    let mp = path & "[" & $i & "]"
    let m = ?decodeMember(item, mp)
    if isMap:
      if m.key.isNone:
        return err(fail(mp, "a map member must have a key"))
      if m.occurrence == occUnbounded:
        return err(fail(mp, "a map member may only be optional"))
      if members.len > 0:
        let order = cmp(members[^1].key.get, m.key.get)
        if order == 0:
          return err(fail(mp, "duplicate map key " & m.key.get))
        if order > 0:
          return err(fail(mp, "map members are not in canonical order"))
    else:
      if m.key.isSome:
        return err(fail(mp, "an array member cannot have a key"))
      if m.occurrence == occOptional or
          (m.occurrence == occUnbounded and items.items.len != 1):
        return
          err(fail(mp, "an array is fixed-length or has exactly one unbounded member"))
    members.add(m)
  ok(members)

func decodeType(v: CborValue, path: string): Result[CddlType, CddlError] =
  let kind = ?nodeKind(v, path)
  case kind
  of 3:
    ?v.checkFields(path, [0'u64, 1])
    let name = ?v.textField(1, path)
    ?checkName(name, path)
    ok(CddlType(kind: tkReference, name: name))
  of 5:
    ok(CddlType(kind: tkPrimitive, primitive: ?decodePrimitive(v, path)))
  of 6:
    ok(CddlType(kind: tkLiteral, literal: ?decodeLiteral(v, path)))
  of 7, 8:
    ?v.checkFields(path, [0'u64, 1])
    let isMap = kind == 8
    let members = ?decodeGroup(v.field(1), path & ".group", isMap)
    if isMap:
      ok(CddlType(kind: tkMap, members: members))
    else:
      ok(CddlType(kind: tkArray, members: members))
  of 12:
    ?v.checkFields(path, [0'u64, 1])
    let items = v.field(1)
    if items.kind != ckArray or items.items.len < 2:
      return err(fail(path, "a choice needs at least two alternatives"))
    var node = CddlType(kind: tkChoice)
    for i, item in items.items:
      let t = ?decodeType(item, path & "|" & $i)
      if t.kind == tkChoice:
        return err(fail(path, "a choice cannot directly contain a choice [G13]"))
      node.alternatives.add(t)
    ok(node)
  of 13:
    decodeRange(v, path)
  of 14:
    ?v.checkFields(path, [0'u64, 1, 2, 3])
    if v.field(1) != cbor("size"):
      return err(fail(path, "unsupported control operator " & toDiag(v.field(1))))
    let target = ?decodePrimitive(v.field(2), path & ".target")
    if target == pBool:
      return err(fail(path, "the .size target must be uint, tstr or bstr"))
    let ctl = v.field(3)
    let cp = path & ".controller"
    let controller =
      case ?nodeKind(ctl, cp)
      of 6:
        let l = ?decodeLiteral(ctl, cp)
        if l.kind != lkUint:
          return err(fail(cp, "the .size controller must be a uint literal or a range"))
        CddlType(kind: tkLiteral, literal: l)
      of 13:
        let r = ?decodeRange(ctl, cp)
        if r.low.kind != lkUint or r.high.kind != lkUint:
          return err(fail(cp, "both .size range bounds must be non-negative"))
        r
      else:
        return err(fail(cp, "the .size controller must be a uint literal or a range"))
    ok(CddlType(kind: tkSize, target: target, controller: controller))
  of 0, 1, 9, 10, 11, 21:
    err(fail(path, "node kind " & $kind & " is not a type"))
  else:
    err(fail(path, "unknown node kind " & $kind))

func fromCbor*(v: CborValue): Result[CddlDocument, CddlError] =
  ## The canonical model in a decoded CBOR item, with every cdCDDLe §8 and §10
  ## check; nothing is reordered.
  if ?nodeKind(v, "document") != 0:
    return err(fail("document", "expected a document node"))
  ?v.checkFields("document", [0'u64, 1, 2])
  if v.field(2) != cbor(CanonicalModelId):
    return
      err(fail("document", "unknown canonical-model identifier " & toDiag(v.field(2))))
  let items = v.field(1)
  if items.kind != ckArray or items.items.len == 0:
    return err(fail("document", "a document needs at least one rule"))
  var doc: CddlDocument
  for i, item in items.items:
    let path = "rules[" & $i & "]"
    if ?nodeKind(item, path) != 1:
      return err(fail(path, "expected a type-rule node"))
    ?item.checkFields(path, [0'u64, 1, 3])
    let name = ?item.textField(1, path)
    ?checkName(name, path)
    if doc.rules.len > 0:
      let order = cmp(doc.rules[^1].name, name)
      if order == 0:
        return err(fail(path, "duplicate rule " & name))
      if order > 0:
        return err(fail(path, "rules are not in canonical order"))
    doc.rules.add(Rule(name: name, typ: ?decodeType(item.field(3), path & "." & name)))
  ok(doc)

func decodeCddl*(data: openArray[byte]): Result[CddlDocument, CddlError] =
  ## Checks that `data` is the deterministic encoding of a valid canonical model
  ## (cdCDDLe §10) and returns the model.
  let v = decodeCbor(data)
  if v.isErr:
    return err(cddlError(ecDecode, "not deterministic CBOR: " & $v.error))
  let doc = ?fromCbor(v.get)
  if encodeCbor(toCbor(doc)) != @data:
    return
      err(cddlError(ecDecode, "the bytes are not the canonical encoding of the model"))
  ok(doc)

func encodeCddl*(doc: CddlDocument): Result[seq[byte], CddlError] =
  ## The canonical bytes of a model; a model that breaks any §8 rule is refused.
  let v = toCbor(doc)
  discard ?fromCbor(v)
  ok(encodeCbor(v))
