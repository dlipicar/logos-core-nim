## COMMITMENT §7-§9.3: the normalized Logos value model as a semantic value tree.
##
## A tree is what the commitment layer builds from decoded deterministic CBOR under
## a schema; HASH turns it into physical payloads (`hash/layout`). Each node carries
## the schema identity that gives it its meaning [SPEC COMMITMENT §8].
##
## List nodes also carry two values derived from the list schema that the §9.3
## shape does not hold, because HASH needs them: the element schema identity
## (`list-payload` field 3, which an empty list cannot supply from its elements)
## and, for a homogeneous packable scalar list, its scalar kind [SPEC HASH §4].

{.push raises: [].}

import std/[algorithm, sets]
import ../cbor
import ../hash/hashinput

type
  ScalarKind* = enum
    ## [SPEC COMMITMENT §9.1] `scalar-kind`.
    skBool = "bool"
    skUint8 = "uint8"
    skUint16 = "uint16"
    skUint32 = "uint32"
    skUint64 = "uint64"
    skInt8 = "int8"
    skInt16 = "int16"
    skInt32 = "int32"
    skInt64 = "int64"
    skTstr = "tstr"
    skBstr = "bstr"

  ScalarData* = object
    ## [SPEC COMMITMENT §9.3] `scalar-data`, tagged with the kind it was typed as.
    case kind*: ScalarKind
    of skBool:
      boolean*: bool
    of skUint8, skUint16, skUint32, skUint64:
      unsigned*: uint64
    of skInt8, skInt16, skInt32, skInt64:
      signed*: int64
    of skTstr:
      text*: string
    of skBstr:
      bytes*: seq[byte]

  ValueKind* = enum
    ## [SPEC COMMITMENT §8] semantic value node kinds (value root is `ValueRoot`).
    vkMap = "map"
    vkField = "field"
    vkAbsent = "absent"
    vkList = "list"
    vkListElement = "list-element"
    vkTuple = "tuple"
    vkTupleElement = "tuple-element"
    vkChoice = "choice"
    vkScalar = "scalar"
    vkReference = "reference-value"

  ValueNode* = ref object
    schema*: Digest
      ## The node's schema identity: field 1 of each §9.3 shape, field 2 of
      ## `field-value`, `list-element-value` and `tuple-element-value`.
    case kind*: ValueKind
    of vkMap:
      fields*: seq[ValueNode] ## `vkField` nodes in canonical field-name order
    of vkField:
      fieldName*: string
      fieldValue*: ValueNode ## `vkAbsent` for an absent optional field
    of vkAbsent:
      discard
    of vkList:
      elements*: seq[ValueNode] ## `vkListElement` nodes, index 0 to length - 1
      elementSchema*: Digest ## derived from the list schema, see above
      packKind*: Opt[ScalarKind]
        ## set exactly for a homogeneous packable scalar list (`packableKind`)
    of vkListElement:
      elementIndex*: uint64
      elementValue*: ValueNode
    of vkTuple:
      positions*: seq[ValueNode] ## `vkTupleElement` nodes, position 0 to arity - 1
    of vkTupleElement:
      position*: uint64
      positionValue*: ValueNode
    of vkChoice:
      armIndex*: uint64
      armSchema*: Digest
      armValue*: ValueNode
    of vkScalar:
      scalar*: ScalarData
    of vkReference:
      referencedRoot*: Digest
      referencedSubtree*: Digest
      referencedValue*: ValueNode

  ValueRoot* = object ## [SPEC COMMITMENT §9.3] `normalized-value-root`.
    modelId*: string
    schemaRoot*: Digest
    subtreeRoot*: Digest
    node*: ValueNode

const
  PackableKinds* = {skBool .. skInt64}
    ## [SPEC HASH §4] bool, uint8..uint64, int8..int64.
  UnsignedKinds* = {skUint8 .. skUint64}
  SignedKinds* = {skInt8 .. skInt64}

func parseScalarKind*(s: string): Opt[ScalarKind] =
  for k in ScalarKind:
    if $k == s:
      return Opt.some(k)
  Opt.none(ScalarKind)

# Constructors --------------------------------------------------------------------

func boolScalar*(v: bool): ScalarData =
  ScalarData(kind: skBool, boolean: v)

func uintScalar*(kind: ScalarKind, v: uint64): ScalarData =
  doAssert kind in UnsignedKinds
  case kind
  of skUint8:
    ScalarData(kind: skUint8, unsigned: v)
  of skUint16:
    ScalarData(kind: skUint16, unsigned: v)
  of skUint32:
    ScalarData(kind: skUint32, unsigned: v)
  else:
    ScalarData(kind: skUint64, unsigned: v)

func intScalar*(kind: ScalarKind, v: int64): ScalarData =
  doAssert kind in SignedKinds
  case kind
  of skInt8:
    ScalarData(kind: skInt8, signed: v)
  of skInt16:
    ScalarData(kind: skInt16, signed: v)
  of skInt32:
    ScalarData(kind: skInt32, signed: v)
  else:
    ScalarData(kind: skInt64, signed: v)

func textScalar*(v: string): ScalarData =
  ScalarData(kind: skTstr, text: v)

func bytesScalar*(v: openArray[byte]): ScalarData =
  ScalarData(kind: skBstr, bytes: @v)

func scalarNode*(schema: Digest, data: ScalarData): ValueNode =
  ValueNode(kind: vkScalar, schema: schema, scalar: data)

func fieldNode*(schema: Digest, name: string, value: ValueNode): ValueNode =
  ValueNode(kind: vkField, schema: schema, fieldName: name, fieldValue: value)

func absentField*(schema: Digest, name: string): ValueNode =
  ## An absent optional field: a field node holding an absent node.
  fieldNode(schema, name, ValueNode(kind: vkAbsent, schema: schema))

func mapNode*(schema: Digest, fields: openArray[ValueNode]): ValueNode =
  ## Sorts `fields` into canonical field-name order.
  var sorted = @fields
  sorted.sort(
    proc(a, b: ValueNode): int =
      cmp(a.fieldName, b.fieldName)
  )
  ValueNode(kind: vkMap, schema: schema, fields: sorted)

func listNode*(
    schema, elementSchema: Digest,
    values: openArray[ValueNode],
    packKind = Opt.none(ScalarKind),
): ValueNode =
  ## Wraps each value in a list-element node carrying `elementSchema`.
  var elements = newSeqOfCap[ValueNode](values.len)
  for i, v in values:
    elements.add(
      ValueNode(
        kind: vkListElement,
        schema: elementSchema,
        elementIndex: uint64(i),
        elementValue: v,
      )
    )
  ValueNode(
    kind: vkList,
    schema: schema,
    elements: elements,
    elementSchema: elementSchema,
    packKind: packKind,
  )

func tupleNode*(schema: Digest, positions: openArray[(Digest, ValueNode)]): ValueNode =
  ## `positions[i]` is the schema identity and value of position `i`.
  var elems = newSeqOfCap[ValueNode](positions.len)
  for i, (s, v) in positions:
    elems.add(
      ValueNode(kind: vkTupleElement, schema: s, position: uint64(i), positionValue: v)
    )
  ValueNode(kind: vkTuple, schema: schema, positions: elems)

func choiceNode*(
    schema: Digest, arm: uint64, armSchema: Digest, value: ValueNode
): ValueNode =
  ValueNode(
    kind: vkChoice, schema: schema, armIndex: arm, armSchema: armSchema, armValue: value
  )

func referenceNode*(
    schema, referencedRoot, referencedSubtree: Digest, value: ValueNode
): ValueNode =
  ValueNode(
    kind: vkReference,
    schema: schema,
    referencedRoot: referencedRoot,
    referencedSubtree: referencedSubtree,
    referencedValue: value,
  )

# §9.3 rules -----------------------------------------------------------------------

func scalarInRange*(d: ScalarData): bool =
  ## [SPEC COMMITMENT §9.3] the fixed-width range of the named alias.
  case d.kind
  of skUint8:
    d.unsigned <= uint64(high(uint8))
  of skUint16:
    d.unsigned <= uint64(high(uint16))
  of skUint32:
    d.unsigned <= uint64(high(uint32))
  of skInt8:
    d.signed >= int64(low(int8)) and d.signed <= int64(high(int8))
  of skInt16:
    d.signed >= int64(low(int16)) and d.signed <= int64(high(int16))
  of skInt32:
    d.signed >= int64(low(int32)) and d.signed <= int64(high(int32))
  of skTstr:
    isValidUtf8(d.text) and '\0' notin d.text
  of skBool, skUint64, skInt64, skBstr:
    true

func innerOf(n: ValueNode): ValueNode =
  case n.kind
  of vkField: n.fieldValue
  of vkListElement: n.elementValue
  of vkTupleElement: n.positionValue
  of vkChoice: n.armValue
  of vkReference: n.referencedValue
  else: nil

type CheckFrame = object ## A map, list or tuple whose members are being checked.
  n: ValueNode
  depth: int ## the maps, lists and tuples above `n`
  next: int ## the next member to check
  names: HashSet[string] ## map: the field names so far
  previous: string ## map: the last field name

func enterCheck(
    stack: var seq[CheckFrame], n: ValueNode, depth: int
): Result[void, string] =
  ## Checks `n` and the field, element, choice and reference nodes below it down
  ## to the next map, list, tuple, scalar or absent node; a container's frame is
  ## pushed for its members.
  var n = n
  while true:
    if n.isNil:
      return err("missing value node")
    if n.kind notin {vkField, vkListElement, vkTupleElement, vkChoice, vkReference}:
      break
    if n.kind == vkField:
      if not isValidUtf8(n.fieldName):
        return err("field name is not UTF-8")
      if n.fieldValue.isNil:
        return err("field " & n.fieldName & " has no value node")
      if n.fieldValue.kind == vkAbsent and n.fieldValue.schema != n.schema:
        return err("absent field " & n.fieldName & " changes schema identity")
    let child = n.innerOf
    if child.isNil:
      return err("missing value node")
    if child.kind in {vkField, vkListElement, vkTupleElement} or
        (child.kind == vkAbsent and n.kind != vkField):
      return
        err("a " & $child.kind & " node cannot appear under a " & $n.kind & " node")
    n = child
  if n.kind in {vkMap, vkList, vkTuple} and depth >= DefaultMaxDepth:
    return err("value tree nested deeper than " & $DefaultMaxDepth & " containers")
  case n.kind
  of vkMap, vkTuple:
    stack.add(CheckFrame(n: n, depth: depth))
  of vkList:
    if n.packKind.isSome and n.packKind.get notin PackableKinds:
      return err("list packed as a kind that is not packable")
    stack.add(CheckFrame(n: n, depth: depth))
  of vkAbsent:
    discard
  of vkScalar:
    if not n.scalar.scalarInRange:
      return err("scalar value outside the range of " & $n.scalar.kind)
  of vkField, vkListElement, vkTupleElement, vkChoice, vkReference:
    raiseAssert "followed above"
  ok()

func checkNode(n: ValueNode, depth: int): Result[void, string] =
  ## `depth` counts the maps, lists and tuples above `n`; field, element, choice
  ## and reference nodes add no level. Members are checked depth first in order,
  ## with the frames on the heap, so the native stack does not grow with the
  ## payload depth and every depth up to `DefaultMaxDepth` is supported on any
  ## thread [SPEC INTERFACE §4.5.1] (DECISIONS I51).
  var stack: seq[CheckFrame]
  ?stack.enterCheck(n, depth)
  while stack.len > 0:
    let t = stack.high
    let c = stack[t].n
    let i = stack[t].next
    case c.kind
    of vkMap:
      if i == c.fields.len:
        discard stack.pop()
        continue
      let f = c.fields[i]
      if f.isNil or f.kind != vkField:
        return err("a map member is not a field node")
      if stack[t].names.containsOrIncl(f.fieldName):
        return err("duplicate map field " & f.fieldName)
      if i > 0 and f.fieldName < stack[t].previous:
        return err("map fields are not in canonical field-name order")
      stack[t].previous = f.fieldName
      inc stack[t].next
      ?stack.enterCheck(f, stack[t].depth + 1)
    of vkList:
      if i == c.elements.len:
        discard stack.pop()
        continue
      let e = c.elements[i]
      if e.isNil or e.kind != vkListElement:
        return err("a list member is not a list-element node")
      if e.elementIndex != uint64(i):
        return err("list elements do not cover 0..length-1 in order")
      if e.schema != c.elementSchema:
        return err("list element identity differs from the element schema")
      if c.packKind.isSome:
        let v = e.elementValue
        if v.isNil or v.kind != vkScalar or v.scalar.kind != c.packKind.get or
            v.schema != c.elementSchema:
          return err("packed list element is not a scalar of the list's kind")
      inc stack[t].next
      ?stack.enterCheck(e, stack[t].depth + 1)
    of vkTuple:
      if i == c.positions.len:
        discard stack.pop()
        continue
      let e = c.positions[i]
      if e.isNil or e.kind != vkTupleElement:
        return err("a tuple member is not a tuple-element node")
      if e.position != uint64(i):
        return err("tuple elements do not cover 0..arity-1 in order")
      inc stack[t].next
      ?stack.enterCheck(e, stack[t].depth + 1)
    else:
      raiseAssert "frames hold maps, lists and tuples"
  ok()

func check*(n: ValueNode): Result[void, string] =
  ## The §9.3 rules a tree must meet before it is hashed.
  if n.isNil or n.kind in {vkField, vkAbsent, vkListElement, vkTupleElement}:
    return err("a value tree starts at a map, list, tuple, choice, scalar or reference")
  checkNode(n, 0)

func check*(r: ValueRoot): Result[void, string] =
  check(r.node)

# §9.3 deterministic CBOR shape -----------------------------------------------------

func toCbor*(d: ScalarData): CborValue =
  case d.kind
  of skBool:
    cbor(d.boolean)
  of skUint8, skUint16, skUint32, skUint64:
    cbor(d.unsigned)
  of skInt8, skInt16, skInt32, skInt64:
    cbor(d.signed)
  of skTstr:
    cbor(d.text)
  of skBstr:
    cbor(d.bytes)

func entry(k: uint64, v: CborValue): CborEntry =
  (cbor(k), v)

func toCbor*(n: ValueNode): CborValue =
  ## [SPEC COMMITMENT §9.3] `value-node`. The list annotations are not part of it.
  let kind = entry(0, cbor($n.kind))
  case n.kind
  of vkMap:
    var fields: seq[CborValue]
    for f in n.fields:
      fields.add(toCbor(f))
    cborMap(kind, entry(1, cbor(n.schema)), entry(2, cborArray(fields)))
  of vkField:
    cborMap(
      kind,
      entry(1, cbor(n.fieldName)),
      entry(2, cbor(n.schema)),
      entry(3, toCbor(n.fieldValue)),
    )
  of vkAbsent:
    cborMap(kind, entry(1, cbor(n.schema)))
  of vkList:
    var elems: seq[CborValue]
    for e in n.elements:
      elems.add(toCbor(e))
    cborMap(
      kind,
      entry(1, cbor(n.schema)),
      entry(2, cbor(uint64(n.elements.len))),
      entry(3, cborArray(elems)),
    )
  of vkListElement:
    cborMap(
      kind,
      entry(1, cbor(n.elementIndex)),
      entry(2, cbor(n.schema)),
      entry(3, toCbor(n.elementValue)),
    )
  of vkTuple:
    var elems: seq[CborValue]
    for e in n.positions:
      elems.add(toCbor(e))
    cborMap(
      kind,
      entry(1, cbor(n.schema)),
      entry(2, cbor(uint64(n.positions.len))),
      entry(3, cborArray(elems)),
    )
  of vkTupleElement:
    cborMap(
      kind,
      entry(1, cbor(n.position)),
      entry(2, cbor(n.schema)),
      entry(3, toCbor(n.positionValue)),
    )
  of vkChoice:
    cborMap(
      kind,
      entry(1, cbor(n.schema)),
      entry(2, cbor(n.armIndex)),
      entry(3, cbor(n.armSchema)),
      entry(4, toCbor(n.armValue)),
    )
  of vkScalar:
    cborMap(
      kind,
      entry(1, cbor(n.schema)),
      entry(2, cbor($n.scalar.kind)),
      entry(3, toCbor(n.scalar)),
    )
  of vkReference:
    cborMap(
      kind,
      entry(1, cbor(n.schema)),
      entry(2, cbor(n.referencedRoot)),
      entry(3, cbor(n.referencedSubtree)),
      entry(4, toCbor(n.referencedValue)),
    )

func toCbor*(r: ValueRoot): CborValue =
  ## [SPEC COMMITMENT §9.3] `normalized-value-root`.
  cborMap(
    entry(0, cbor("value-root")),
    entry(1, cbor(r.modelId)),
    entry(2, cbor(r.schemaRoot)),
    entry(3, cbor(r.subtreeRoot)),
    entry(4, toCbor(r.node)),
  )

# §9.3 objects received as CBOR -----------------------------------------------------

func digestAt(v: CborValue, k: uint64): Result[Digest, string] =
  let x = v.lookup(k)
  if x.isNone:
    return err("missing field " & $k)
  let d = toDigest(x.get)
  if d.isNone:
    return err("field " & $k & " is not a 32-byte digest")
  ok(d.get)

func uintAt(v: CborValue, k: uint64): Result[uint64, string] =
  let x = v.lookup(k)
  if x.isNone or x.get.kind != ckUint:
    return err("field " & $k & " is not an unsigned integer")
  ok(x.get.uint)

func textAt(v: CborValue, k: uint64): Result[string, string] =
  let x = v.lookup(k)
  if x.isNone or x.get.kind != ckText or not x.get.validUtf8:
    return err("field " & $k & " is not text")
  ok(x.get.text)

func arrayAt(v: CborValue, k: uint64): Result[seq[CborValue], string] =
  let x = v.lookup(k)
  if x.isNone or x.get.kind != ckArray:
    return err("field " & $k & " is not an array")
  ok(x.get.items)

func nodeAt(v: CborValue, k: uint64): Result[CborValue, string] =
  let x = v.lookup(k)
  if x.isNone:
    return err("missing field " & $k)
  ok(x.get)

func parseScalarData*(kind: ScalarKind, v: CborValue): Result[ScalarData, string] =
  ## [SPEC COMMITMENT §9.3] `scalar-data` of `kind`: the CBOR type must match and
  ## the value must lie in the kind's range.
  let d =
    case kind
    of skBool:
      if v.kind != ckSimple or v.simple notin {SimpleFalse, SimpleTrue}:
        return err("bool scalar data is not a Boolean")
      boolScalar(v.simple == SimpleTrue)
    of UnsignedKinds:
      if v.kind != ckUint:
        return err($kind & " scalar data is not a non-negative integer")
      uintScalar(kind, v.uint)
    of SignedKinds:
      if v.kind == ckUint and v.uint <= uint64(high(int64)):
        intScalar(kind, int64(v.uint))
      elif v.kind == ckNint and v.nint <= uint64(high(int64)):
        intScalar(kind, -int64(v.nint) - 1)
      else:
        return err($kind & " scalar data is not an int64")
    of skTstr:
      if v.kind != ckText or not v.validUtf8:
        return err("tstr scalar data is not text")
      textScalar(v.text)
    of skBstr:
      if v.kind != ckBytes:
        return err("bstr scalar data is not a byte string")
      bytesScalar(v.bytes)
  if not d.scalarInRange:
    return err("scalar value outside the range of " & $kind)
  ok(d)

func parseNode(v: CborValue, depth: int): Result[ValueNode, string] =
  if depth > DefaultMaxDepth:
    return err("value object nested deeper than " & $DefaultMaxDepth)
  if v.kind != ckMap:
    return err("a value node is not a map")
  let tag = ?v.textAt(0)
  var kind = Opt.none(ValueKind)
  for k in ValueKind:
    if $k == tag:
      kind = Opt.some(k)
  if kind.isNone:
    return err("unknown value node kind " & tag)
  let expected =
    case kind.get
    of vkAbsent: 2
    of vkMap: 3
    of vkChoice, vkReference: 5
    else: 4
  if v.entries.len != expected:
    return err("a " & tag & " value node has " & $v.entries.len & " fields")
  var n: ValueNode
  case kind.get
  of vkMap:
    n = ValueNode(kind: vkMap, schema: ?v.digestAt(1))
    for f in ?v.arrayAt(2):
      n.fields.add(?parseNode(f, depth + 1))
  of vkField:
    n = ValueNode(
      kind: vkField,
      fieldName: ?v.textAt(1),
      schema: ?v.digestAt(2),
      fieldValue: ?parseNode(?v.nodeAt(3), depth + 1),
    )
  of vkAbsent:
    n = ValueNode(kind: vkAbsent, schema: ?v.digestAt(1))
  of vkList:
    n = ValueNode(kind: vkList, schema: ?v.digestAt(1))
    let length = ?v.uintAt(2)
    for e in ?v.arrayAt(3):
      n.elements.add(?parseNode(e, depth + 1))
    if uint64(n.elements.len) != length:
      return err("list length differs from its element count")
    # The §9.3 object has no element schema field: it is the elements' own.
    if n.elements.len > 0:
      n.elementSchema = n.elements[0].schema
  of vkListElement:
    n = ValueNode(
      kind: vkListElement,
      elementIndex: ?v.uintAt(1),
      schema: ?v.digestAt(2),
      elementValue: ?parseNode(?v.nodeAt(3), depth + 1),
    )
  of vkTuple:
    n = ValueNode(kind: vkTuple, schema: ?v.digestAt(1))
    let arity = ?v.uintAt(2)
    for e in ?v.arrayAt(3):
      n.positions.add(?parseNode(e, depth + 1))
    if uint64(n.positions.len) != arity:
      return err("tuple arity differs from its element count")
  of vkTupleElement:
    n = ValueNode(
      kind: vkTupleElement,
      position: ?v.uintAt(1),
      schema: ?v.digestAt(2),
      positionValue: ?parseNode(?v.nodeAt(3), depth + 1),
    )
  of vkChoice:
    n = ValueNode(
      kind: vkChoice,
      schema: ?v.digestAt(1),
      armIndex: ?v.uintAt(2),
      armSchema: ?v.digestAt(3),
      armValue: ?parseNode(?v.nodeAt(4), depth + 1),
    )
  of vkScalar:
    let k = parseScalarKind(?v.textAt(2))
    if k.isNone:
      return err("unknown scalar kind")
    n = ValueNode(
      kind: vkScalar,
      schema: ?v.digestAt(1),
      scalar: ?parseScalarData(k.get, ?v.nodeAt(3)),
    )
  of vkReference:
    n = ValueNode(
      kind: vkReference,
      schema: ?v.digestAt(1),
      referencedRoot: ?v.digestAt(2),
      referencedSubtree: ?v.digestAt(3),
      referencedValue: ?parseNode(?v.nodeAt(4), depth + 1),
    )
  ok(n)

func parseValueNode*(v: CborValue): Result[ValueNode, string] =
  ## [SPEC COMMITMENT §9.3, §10] A `value-node` object, checked against the §9.3
  ## rules. List annotations (HASH layout input) are not part of the object: the
  ## element schema is taken from the elements and nothing is packed.
  let n = ?parseNode(v, 0)
  ?check(n)
  ok(n)

func parseValueRoot*(v: CborValue): Result[ValueRoot, string] =
  ## [SPEC COMMITMENT §9.3, §10] A `normalized-value-root` object.
  if v.kind != ckMap or v.entries.len != 5 or (?v.textAt(0)) != "value-root":
    return err("not a normalized-value-root")
  let r = ValueRoot(
    modelId: ?v.textAt(1),
    schemaRoot: ?v.digestAt(2),
    subtreeRoot: ?v.digestAt(3),
    node: ?parseNode(?v.nodeAt(4), 0),
  )
  ?check(r)
  ok(r)

func plainValue*(n: ValueNode): CborValue =
  ## The data a value tree normalizes: maps of present fields, arrays, the
  ## selected arm's value, and scalars. Encoding it gives the Logos deterministic
  ## CBOR the tree was decoded from.
  case n.kind
  of vkMap:
    var entries: seq[CborEntry]
    for f in n.fields:
      if f.fieldValue.kind != vkAbsent:
        entries.add((cbor(f.fieldName), plainValue(f.fieldValue)))
    cborMap(entries)
  of vkField:
    plainValue(n.fieldValue)
  of vkAbsent:
    nil
  of vkList:
    var items: seq[CborValue]
    for e in n.elements:
      items.add(plainValue(e.elementValue))
    cborArray(items)
  of vkListElement:
    plainValue(n.elementValue)
  of vkTuple:
    var items: seq[CborValue]
    for e in n.positions:
      items.add(plainValue(e.positionValue))
    cborArray(items)
  of vkTupleElement:
    plainValue(n.positionValue)
  of vkChoice:
    plainValue(n.armValue)
  of vkScalar:
    toCbor(n.scalar)
  of vkReference:
    plainValue(n.referencedValue)
