## HASH §4, §5, §7.3, §7.4: the physical layout of a semantic value tree.
##
## `layout` turns a checked `ValueRoot` into physical objects: every payload, its
## digest and the records that link them. Nothing here is an implementation choice
## [SPEC HASH §5]: chunk sizes, fanout, labels, node kinds and ordering are the
## profile's constants and rules. The resulting `PhysNode` tree keeps every payload
## so verified views can be cut from it.

{.push raises: [].}

import ../cbor
import ./hashinput
import ../commitment/value

export hashinput, value

const
  Fanout* = 256 ## [SPEC HASH §5] branch fanout and direct-collection limit
  ListChunk* = 256 ## [SPEC HASH §4] list and packed-scalar chunk size
  StringChunk* = 4096 ## [SPEC HASH §4] byte- and text-string chunk size

type
  NodeKind* = enum
    ## [SPEC HASH §5] `node-kind`, the closed registry of physical node kinds.
    nkMap = "map"
    nkField = "field"
    nkAbsent = "absent"
    nkList = "list"
    nkListChunk = "list-chunk"
    nkPackedChunk = "packed-scalar-list-chunk"
    nkTuple = "tuple"
    nkTupleElement = "tuple-element"
    nkChoice = "choice"
    nkScalar = "scalar"
    nkBstr = "bstr"
    nkBstrDirect = "bstr-direct"
    nkBstrChunk = "bstr-chunk"
    nkTstr = "tstr"
    nkTstrDirect = "tstr-direct"
    nkTstrChunk = "tstr-chunk"
    nkReference = "reference-value"
    nkBranch = "branch"

  PhysNode* = ref object
    ## One physical object. `payload` is nil only for synthetic records (tests).
    kind*: NodeKind
    schema*: Digest ## field 2 of the payload, which every record of it repeats
    digest*: Digest
    payload*: CborValue
    children*: seq[Record] ## in payload order; empty for leaves

  Record* = object
    ## A `child-record` (with a label) or `root-child-record` (label nil).
    label*: CborValue
    node*: PhysNode

  PhysRoot* = object ## The value-root object: its payload, digest and sole child.
    digest*: Digest
    payload*: CborValue
    child*: PhysNode

const BranchParentKinds* = {nkMap, nkList, nkTuple, nkBstr, nkTstr}
  ## [SPEC HASH §7.4] `branch-parent-kind`.

func parseNodeKind*(s: string): Opt[NodeKind] =
  for k in NodeKind:
    if $k == s:
      return Opt.some(k)
  Opt.none(NodeKind)

func domainOf*(k: NodeKind): Domain =
  ## [SPEC HASH §5, §7.5] the domain of each node kind's payload.
  case k
  of nkMap: dMap
  of nkField: dField
  of nkAbsent: dAbsent
  of nkList: dList
  of nkListChunk: dListChunk
  of nkPackedChunk: dPackedChunk
  of nkTuple: dTuple
  of nkTupleElement: dTupleElement
  of nkChoice: dChoice
  of nkScalar: dScalar
  of nkBstr: dBstr
  of nkBstrDirect: dBstrDirect
  of nkBstrChunk: dBstrChunk
  of nkTstr: dTstr
  of nkTstrDirect: dTstrDirect
  of nkTstrChunk: dTstrChunk
  of nkReference: dReference
  of nkBranch: dBranch

# Payload building blocks -------------------------------------------------------------

func entry(k: uint64, v: CborValue): CborEntry =
  (cbor(k), v)

func fieldLabel*(name: string): CborValue =
  cborMap(entry(0, cbor("field")), entry(1, cbor(name)))

func indexLabel*(i: uint64): CborValue =
  cborMap(entry(0, cbor("index")), entry(1, cbor(i)))

func indexRangeLabel*(start, count: uint64): CborValue =
  cborMap(entry(0, cbor("index-range")), entry(1, cbor(start)), entry(2, cbor(count)))

func tupleLabel*(position: uint64): CborValue =
  cborMap(entry(0, cbor("tuple-position")), entry(1, cbor(position)))

func choiceLabel*(arm: uint64): CborValue =
  cborMap(entry(0, cbor("choice-arm")), entry(1, cbor(arm)))

func byteRangeLabel*(offset, count: uint64): CborValue =
  cborMap(entry(0, cbor("byte-range")), entry(1, cbor(offset)), entry(2, cbor(count)))

func branchLabel*(start, count: uint64): CborValue =
  cborMap(entry(0, cbor("branch")), entry(1, cbor(start)), entry(2, cbor(count)))

func rootChildRecord*(n: PhysNode): CborValue =
  ## [SPEC HASH §7.3] `{0: node-kind, 1: digest, 2: schema-subtree-root}`.
  cborMap(entry(0, cbor($n.kind)), entry(1, cbor(n.digest)), entry(2, cbor(n.schema)))

func childRecord*(r: Record): CborValue =
  ## [SPEC HASH §7.3] `{0: child-label, 1: node-kind, 2: digest, 3: schema-subtree-root}`.
  cborMap(
    entry(0, r.label),
    entry(1, cbor($r.node.kind)),
    entry(2, cbor(r.node.digest)),
    entry(3, cbor(r.node.schema)),
  )

func childRecords(rs: openArray[Record]): CborValue =
  var items = newSeqOfCap[CborValue](rs.len)
  for r in rs:
    items.add(childRecord(r))
  cborArray(items)

func made(
    kind: NodeKind, schema: Digest, payload: CborValue, children: seq[Record] = @[]
): PhysNode =
  ## A physical object whose record schema is its payload's field 2
  ## [SPEC HASH §7.3] and whose digest is taken in its kind's domain.
  PhysNode(
    kind: kind,
    schema: schema,
    digest: digestOf(domainOf(kind), payload),
    payload: payload,
    children: children,
  )

func header(kind: string, root, schema: Digest): seq[CborEntry] =
  @[entry(0, cbor(kind)), entry(1, cbor(root)), entry(2, cbor(schema))]

# Branches ------------------------------------------------------------------------

func branchUp*(
    root: Digest, parentKind: NodeKind, parentSchema: Digest, records: seq[Record]
): seq[Record] =
  ## [SPEC HASH §5] At most 256 records stay as they are. Otherwise every record
  ## is grouped into branches of 256 (the last holds the remaining one to 256),
  ## and the branch records are grouped again until at most 256 remain. A branch
  ## names the base-record range it represents.
  doAssert parentKind in BranchParentKinds
  if records.len <= Fanout:
    return records
  var
    level = records
    starts = newSeqOfCap[uint64](records.len)
    counts = newSeqOfCap[uint64](records.len)
  for i in 0 ..< records.len:
    starts.add(uint64(i))
    counts.add(1)
  while level.len > Fanout:
    var
      next: seq[Record]
      nextStarts, nextCounts: seq[uint64]
    var g = 0
    while g < level.len:
      let last = min(g + Fanout, level.len)
      var count = 0'u64
      for i in g ..< last:
        count += counts[i]
      let
        start = starts[g]
        group = level[g ..< last]
        payload = cborMap(
          header("branch", root, parentSchema) &
            @[
              entry(3, cbor($parentKind)),
              entry(4, cbor(start)),
              entry(5, cbor(count)),
              entry(6, childRecords(group)),
            ]
        )
      next.add(
        Record(
          label: branchLabel(start, count),
          node: made(nkBranch, parentSchema, payload, group),
        )
      )
      nextStarts.add(start)
      nextCounts.add(count)
      g = last
    level = next
    starts = nextStarts
    counts = nextCounts
  level

# Strings -------------------------------------------------------------------------

func stringNode(root, schema: Digest, text: bool, data: openArray[byte]): PhysNode =
  ## [SPEC HASH §4, §5] Direct through 4096 bytes; above that, one aggregate over
  ## 4096-byte chunks (the last holds the remaining one to 4096 bytes).
  let
    total = uint64(data.len)
    (direct, aggregate, chunk) =
      if text:
        (nkTstrDirect, nkTstr, nkTstrChunk)
      else:
        (nkBstrDirect, nkBstr, nkBstrChunk)
  if data.len <= StringChunk:
    let body =
      if text:
        var s = newString(data.len)
        for i, b in data:
          s[i] = char(b)
        cbor(s)
      else:
        cbor(data)
    return made(
      direct,
      schema,
      cborMap(header($direct, root, schema) & @[entry(3, cbor(total)), entry(4, body)]),
    )
  var records: seq[Record]
  var off = 0
  while off < data.len:
    let n = min(StringChunk, data.len - off)
    let payload = cborMap(
      header($chunk, root, schema) &
        @[
          entry(3, cbor(total)),
          entry(4, cbor(uint64(off))),
          entry(5, cbor(uint64(n))),
          entry(6, cbor(data.toOpenArray(off, off + n - 1))),
        ]
    )
    records.add(
      Record(
        label: byteRangeLabel(uint64(off), uint64(n)),
        node: made(chunk, schema, payload),
      )
    )
    off += n
  let top = branchUp(root, aggregate, schema, records)
  made(
    aggregate,
    schema,
    cborMap(
      header($aggregate, root, schema) &
        @[entry(3, cbor(total)), entry(4, childRecords(top))]
    ),
    top,
  )

# Values --------------------------------------------------------------------------

func rootBelowReference*(n: ValueNode): Digest =
  ## [IMPL-DECISION G2] Payloads below a reference value carry the referenced
  ## schema root in field 1, not the root of the value that contains it.
  doAssert n.kind == vkReference
  n.referencedRoot

func wrap(
    kind: NodeKind, root, schema: Digest, extra: seq[CborEntry], child: PhysNode
): PhysNode =
  ## A payload whose last field is the `root-child-record` of its one child.
  let fieldNo = uint64(extra.len + 3)
  made(
    kind,
    schema,
    cborMap(
      header($kind, root, schema) & extra & @[entry(fieldNo, rootChildRecord(child))]
    ),
    @[Record(label: nil, node: child)],
  )

func scalarPayloadNode(root: Digest, n: ValueNode): PhysNode =
  ## [SPEC HASH §5] bool and integer scalars use `scalar`; strings use the
  ## direct or chunked string objects.
  case n.scalar.kind
  of skBstr:
    stringNode(root, n.schema, false, n.scalar.bytes)
  of skTstr:
    stringNode(
      root, n.schema, true, n.scalar.text.toOpenArrayByte(0, n.scalar.text.high)
    )
  else:
    made(
      nkScalar,
      n.schema,
      cborMap(
        header("scalar", root, n.schema) &
          @[entry(3, cbor($n.scalar.kind)), entry(4, toCbor(n.scalar))]
      ),
    )

func listNode(root: Digest, n: ValueNode, elements: seq[PhysNode]): PhysNode =
  ## [SPEC HASH §4] At most 256 elements: index-labelled element records. Longer:
  ## 256-element chunks, packed when the list is a homogeneous packable scalar list.
  ## `elements` are the laid-out element values, empty for a packed long list.
  let length = n.elements.len
  var records: seq[Record]
  if length <= ListChunk:
    for i, e in n.elements:
      records.add(Record(label: indexLabel(e.elementIndex), node: elements[i]))
  else:
    var start = 0
    while start < length:
      let count = min(ListChunk, length - start)
      var chunk: PhysNode
      if n.packKind.isSome:
        var values = newSeqOfCap[CborValue](count)
        for i in start ..< start + count:
          values.add(toCbor(n.elements[i].elementValue.scalar))
        chunk = made(
          nkPackedChunk,
          n.schema,
          cborMap(
            header($nkPackedChunk, root, n.schema) &
              @[
                entry(3, cbor(n.elementSchema)),
                entry(4, cbor($n.packKind.get)),
                entry(5, cbor(uint64(start))),
                entry(6, cbor(uint64(count))),
                entry(7, cborArray(values)),
              ]
          ),
        )
      else:
        var inner: seq[Record]
        for i in start ..< start + count:
          let e = n.elements[i]
          inner.add(Record(label: indexLabel(e.elementIndex), node: elements[i]))
        chunk = made(
          nkListChunk,
          n.schema,
          cborMap(
            header($nkListChunk, root, n.schema) &
              @[
                entry(3, cbor(n.elementSchema)),
                entry(4, cbor(uint64(start))),
                entry(5, cbor(uint64(count))),
                entry(6, childRecords(inner)),
              ]
          ),
          inner,
        )
      records.add(
        Record(label: indexRangeLabel(uint64(start), uint64(count)), node: chunk)
      )
      start += count
    records = branchUp(root, nkList, n.schema, records)
  made(
    nkList,
    n.schema,
    cborMap(
      header("list", root, n.schema) &
        @[
          entry(3, cbor(n.elementSchema)),
          entry(4, cbor(uint64(length))),
          entry(5, childRecords(records)),
        ]
    ),
    records,
  )

func choicePhys(root: Digest, n: ValueNode, arm: PhysNode): PhysNode =
  let rec = Record(label: choiceLabel(n.armIndex), node: arm)
  made(
    nkChoice,
    n.schema,
    cborMap(
      header("choice", root, n.schema) &
        @[
          entry(3, cbor(n.armIndex)),
          entry(4, cbor(n.armSchema)),
          entry(5, childRecord(rec)),
        ]
    ),
    @[rec],
  )

type LayoutFrame = object ## A map, list or tuple whose children are being laid out.
  root: Digest
  n: ValueNode
  wrappers: seq[(Digest, ValueNode)] ## the choice and reference nodes around `n`
  next: int ## the next child to lay out
  records: seq[Record] ## map and tuple: the records so far
  elements: seq[PhysNode] ## list: the element objects so far

func rewrap(node: PhysNode, wrappers: seq[(Digest, ValueNode)]): PhysNode =
  ## `node` inside its choice and reference objects, innermost first.
  result = node
  for i in countdown(wrappers.high, 0):
    let (r, w) = wrappers[i]
    result =
      if w.kind == vkChoice:
        choicePhys(r, w, result)
      else:
        wrap(
          nkReference,
          r,
          w.schema,
          @[entry(3, cbor(w.referencedRoot)), entry(4, cbor(w.referencedSubtree))],
          result,
        )

func enter(stack: var seq[LayoutFrame], root: Digest, n: ValueNode): PhysNode =
  ## The object of `n` if it is a scalar; otherwise pushes its frame and gives nil.
  ## Choice and reference nodes are followed here and wrapped when it finishes.
  var
    root = root
    n = n
    wrappers: seq[(Digest, ValueNode)]
  while n.kind in {vkChoice, vkReference}:
    wrappers.add((root, n))
    if n.kind == vkChoice:
      n = n.armValue
    else:
      root = rootBelowReference(n)
      n = n.referencedValue
  case n.kind
  of vkScalar:
    rewrap(scalarPayloadNode(root, n), wrappers)
  of vkMap, vkList, vkTuple:
    stack.add(LayoutFrame(root: root, n: n, wrappers: wrappers))
    nil
  of vkChoice, vkReference, vkField, vkAbsent, vkListElement, vkTupleElement:
    raiseAssert "checked trees have no " & $n.kind & " node here"

func finish(f: LayoutFrame): PhysNode =
  ## The object of a frame whose children are all laid out.
  let (root, n) = (f.root, f.n)
  let node =
    case n.kind
    of vkMap:
      let records = branchUp(root, nkMap, n.schema, f.records)
      made(
        nkMap,
        n.schema,
        cborMap(
          header("map", root, n.schema) &
            @[entry(3, cbor(uint64(n.fields.len))), entry(4, childRecords(records))]
        ),
        records,
      )
    of vkList:
      listNode(root, n, f.elements)
    of vkTuple:
      let records = branchUp(root, nkTuple, n.schema, f.records)
      made(
        nkTuple,
        n.schema,
        cborMap(
          header("tuple", root, n.schema) &
            @[entry(3, cbor(uint64(n.positions.len))), entry(4, childRecords(records))]
        ),
        records,
      )
    else:
      raiseAssert "frames hold maps, lists and tuples"
  rewrap(node, f.wrappers)

func layoutNode(root: Digest, n: ValueNode): PhysNode =
  ## The physical object of a checked value node. The walk keeps its frames on the
  ## heap, so the native stack does not grow with the payload depth and every depth
  ## up to `DefaultMaxDepth` is supported on any thread [SPEC INTERFACE §4.5.1]
  ## (DECISIONS I51).
  var
    stack: seq[LayoutFrame]
    produced = stack.enter(root, n)
  while true:
    if not produced.isNil:
      # Hand the finished child to the frame that started it.
      if stack.len == 0:
        return produced
      let t = stack.high
      let (r, c) = (stack[t].root, stack[t].n)
      case c.kind
      of vkMap:
        let f = c.fields[stack[t].next - 1]
        stack[t].records.add(
          Record(
            label: fieldLabel(f.fieldName),
            node: wrap(nkField, r, f.schema, @[entry(3, cbor(f.fieldName))], produced),
          )
        )
      of vkList:
        stack[t].elements.add(produced)
      of vkTuple:
        let e = c.positions[stack[t].next - 1]
        stack[t].records.add(
          Record(
            label: tupleLabel(e.position),
            node:
              wrap(nkTupleElement, r, e.schema, @[entry(3, cbor(e.position))], produced),
          )
        )
      else:
        raiseAssert "frames hold maps, lists and tuples"
      produced = nil
    # Start the top frame's next child, or finish the frame.
    let t = stack.high
    let (r, c) = (stack[t].root, stack[t].n)
    var started = false
    case c.kind
    of vkMap:
      while not started and stack[t].next < c.fields.len:
        let f = c.fields[stack[t].next]
        inc stack[t].next
        if f.fieldValue.kind == vkAbsent:
          # [SPEC HASH §7.4] the map record carries the absent payload directly.
          stack[t].records.add(
            Record(
              label: fieldLabel(f.fieldName),
              node: made(
                nkAbsent,
                f.schema,
                cborMap(header("absent", r, f.schema) & @[entry(3, cbor(f.fieldName))]),
              ),
            )
          )
        else:
          started = true
          produced = stack.enter(r, f.fieldValue)
    of vkList:
      # A packed long list lays its scalars out in its chunks: no element objects.
      if (c.elements.len <= ListChunk or c.packKind.isNone) and
          stack[t].next < c.elements.len:
        let e = c.elements[stack[t].next]
        inc stack[t].next
        started = true
        produced = stack.enter(r, e.elementValue)
    of vkTuple:
      if stack[t].next < c.positions.len:
        let e = c.positions[stack[t].next]
        inc stack[t].next
        started = true
        produced = stack.enter(r, e.positionValue)
    else:
      raiseAssert "frames hold maps, lists and tuples"
    if not started:
      produced = finish(stack.pop())

func layoutValue*(root: Digest, n: ValueNode): Result[PhysNode, string] =
  ## The physical object of one value node whose payloads carry `root` in field 1
  ## (a verified view's disclosed value), after the §9.3 checks.
  ?check(n)
  ok(layoutNode(root, n))

func valueRootPayload*(schemaRoot, subtreeRoot: Digest, child: PhysNode): CborValue =
  ## [SPEC HASH §7.4] `value-root-payload`.
  cborMap(
    entry(0, cbor("value-root")),
    entry(1, cbor(schemaRoot)),
    entry(2, cbor(subtreeRoot)),
    entry(3, rootChildRecord(child)),
  )

func layout*(r: ValueRoot): Result[PhysRoot, string] =
  ## The physical layout of a normalized value root, after the §9.3 checks.
  if r.modelId != SpecProfile.modelId:
    return err("value root is for commitment model " & r.modelId)
  ?check(r)
  let
    child = layoutNode(r.schemaRoot, r.node)
    payload = valueRootPayload(r.schemaRoot, r.subtreeRoot, child)
  ok(PhysRoot(digest: digestOf(dValueRoot, payload), payload: payload, child: child))

func valueRoot*(r: ValueRoot): Result[Digest, string] =
  ## The value root of a normalized value root.
  ok((?layout(r)).digest)
