## HASH §7.6, §8: verified views over a value root.
##
## `viewOf` cuts a view from a normalized value: the disclosed item at a semantic
## path (COMMITMENT §9.4) and the complete payloads from it up to the value-root
## payload. `verifyView` replays those payloads from the value root down the path,
## so every selected record is the one the path and the canonical layout name.
##
## [IMPL-DECISION G7] A path ending at a field or tuple position discloses the
## inner value, as a list index does. [IMPL-DECISION G8] A path crosses a choice
## only through a `choice-arm` segment naming the selected arm. A path crosses an
## imported reference without a segment (none is defined). [IMPL-DECISION G120]
## `verifyView` takes the schema document and recomputes its root (HASH §8
## l.1214-1215). `verifyPhysicalProof` checks only the physical proof, for the
## synthetic HASH App B identities (TF-13); it is not a §8 verification and
## cannot descend a branched map.

{.push raises: [].}

import std/algorithm
import ../cbor
import ./[hashinput, layout, check]
import ../commitment/[value, schema, choice, normalize]

type
  SegmentKind* = enum
    ## [SPEC COMMITMENT §9.4] `path-segment` kinds.
    sgField = "field"
    sgListIndex = "list-index"
    sgTuplePosition = "tuple-position"
    sgChoiceArm = "choice-arm"
    sgBstrRange = "bstr-range"
    sgTstrRange = "tstr-utf8-range"

  Segment* = object
    case kind*: SegmentKind
    of sgField:
      field*: string
    of sgListIndex, sgTuplePosition, sgChoiceArm:
      index*: uint64
    of sgBstrRange, sgTstrRange:
      start*, length*: uint64

  DisclosedKind* = enum
    diValue = "value"
    diAbsence = "absence"
    diBstrRange = "bstr-range"
    diTstrRange = "tstr-utf8-range"

  Disclosed* = object ## [SPEC HASH §7.6] `disclosed-item`.
    case kind*: DisclosedKind
    of diValue:
      value*: CborValue ## a `normalized-value-root` or `value-node`
    of diAbsence:
      discard
    of diBstrRange, diTstrRange:
      total*, offset*, count*: uint64
      bytes*: seq[byte]

  ProofStep* = object
    domain*: Domain
    payload*: CborValue

  VerifiedView* = object ## [SPEC HASH §7.6] `verified-view`.
    schemaRoot*, subtreeRoot*, valueRoot*: Digest
    profileId*, suiteId*, modelId*: string
    path*: seq[Segment]
    disclosed*: Disclosed
    proof*: seq[ProofStep] ## from the disclosed item toward the value root

  ViewErrorKind* = enum
    veShape = "malformed-view"
    veProfile = "unknown-identifier"
    veSchema = "schema-mismatch"
    vePath = "invalid-path"
    veDisclosed = "disclosed-mismatch"
    veProof = "proof-mismatch"
    veRoot = "value-root-mismatch"

  ViewError* = object
    kind*: ViewErrorKind
    msg*: string

  ViewSchema* = object
    ## The schema a verifier checks a view against [IMPL-DECISION G120].
    set*: SchemaSet
    doc*: int

func `$`*(e: ViewError): string =
  $e.kind & ": " & e.msg

func fail[T](kind: ViewErrorKind, msg: string): Result[T, ViewError] =
  err(ViewError(kind: kind, msg: msg))

func fieldSegment*(name: string): Segment =
  Segment(kind: sgField, field: name)

func listIndex*(i: uint64): Segment =
  Segment(kind: sgListIndex, index: i)

func tuplePosition*(i: uint64): Segment =
  Segment(kind: sgTuplePosition, index: i)

func choiceArm*(i: uint64): Segment =
  Segment(kind: sgChoiceArm, index: i)

func bstrRange*(start, length: uint64): Segment =
  Segment(kind: sgBstrRange, start: start, length: length)

func tstrRange*(start, length: uint64): Segment =
  Segment(kind: sgTstrRange, start: start, length: length)

# CBOR shapes -------------------------------------------------------------------------

func entry(k: uint64, v: CborValue): CborEntry =
  (cbor(k), v)

func rangeDisclosure(
    text: bool, total, offset, count: uint64, bytes: seq[byte]
): Disclosed =
  var d =
    if text:
      Disclosed(kind: diTstrRange)
    else:
      Disclosed(kind: diBstrRange)
  d.total = total
  d.offset = offset
  d.count = count
  d.bytes = bytes
  d

func toCbor*(s: Segment): CborValue =
  ## [SPEC COMMITMENT §9.4] `path-segment`.
  case s.kind
  of sgField:
    cborMap(entry(0, cbor("field")), entry(1, cbor(s.field)))
  of sgListIndex, sgTuplePosition, sgChoiceArm:
    cborMap(entry(0, cbor($s.kind)), entry(1, cbor(s.index)))
  of sgBstrRange, sgTstrRange:
    cborMap(entry(0, cbor($s.kind)), entry(1, cbor(s.start)), entry(2, cbor(s.length)))

func toCbor*(path: openArray[Segment]): CborValue =
  var items: seq[CborValue]
  for s in path:
    items.add(toCbor(s))
  cborArray(items)

func toCbor*(d: Disclosed): CborValue =
  case d.kind
  of diValue:
    cborMap(entry(0, cbor("value")), entry(1, d.value))
  of diAbsence:
    cborMap(entry(0, cbor("absence")))
  of diBstrRange, diTstrRange:
    cborMap(
      entry(0, cbor($d.kind)),
      entry(1, cbor(d.total)),
      entry(2, cbor(d.offset)),
      entry(3, cbor(d.count)),
      entry(4, cbor(d.bytes)),
    )

func toCbor*(v: VerifiedView): CborValue =
  var steps: seq[CborValue]
  for s in v.proof:
    steps.add(cborMap(entry(0, cbor($s.domain)), entry(1, s.payload)))
  cborMap(
    entry(0, cbor("verified-view")),
    entry(1, cbor(v.schemaRoot)),
    entry(2, cbor(v.subtreeRoot)),
    entry(3, cbor(v.valueRoot)),
    entry(4, cbor(v.profileId)),
    entry(5, cbor(v.suiteId)),
    entry(6, cbor(v.modelId)),
    entry(7, toCbor(v.path)),
    entry(8, toCbor(v.disclosed)),
    entry(9, cborArray(steps)),
  )

func exact(v: CborValue, n: int, what: string): Result[seq[CborValue], ViewError] =
  ## The values under keys 0..n-1 of a map with exactly those keys.
  if v.isNil or v.kind != ckMap or v.entries.len != n:
    return fail[seq[CborValue]](veShape, what & " is not a map of " & $n & " fields")
  var f: seq[CborValue]
  for i in 0 ..< n:
    let x = v.lookup(uint64(i))
    if x.isNone:
      return fail[seq[CborValue]](veShape, what & " has no field " & $i)
    f.add(x.get)
  ok(f)

func uintOf(v: CborValue, what: string): Result[uint64, ViewError] =
  if v.kind != ckUint:
    return fail[uint64](veShape, what & " is not an unsigned integer")
  ok(v.uint)

func textOf(v: CborValue, what: string): Result[string, ViewError] =
  if v.kind != ckText or not v.validUtf8:
    return fail[string](veShape, what & " is not text")
  ok(v.text)

func digestField(v: CborValue, what: string): Result[Digest, ViewError] =
  let d = toDigest(v)
  if d.isNone:
    return fail[Digest](veShape, what & " is not a 32-byte digest")
  ok(d.get)

func parseSegment*(v: CborValue): Result[Segment, ViewError] =
  if v.kind != ckMap or v.entries.len == 0 or v.lookup(0'u64).isNone:
    return fail[Segment](veShape, "a path segment is not a tagged map")
  let tag = ?textOf(v.lookup(0'u64).get, "path segment kind")
  case tag
  of "field":
    let f = ?exact(v, 2, "field segment")
    ok(fieldSegment(?textOf(f[1], "field name")))
  of "list-index", "tuple-position", "choice-arm":
    let f = ?exact(v, 2, tag & " segment")
    let i = ?uintOf(f[1], tag)
    ok(
      case tag
      of "list-index":
        listIndex(i)
      of "tuple-position":
        tuplePosition(i)
      else:
        choiceArm(i)
    )
  of "bstr-range", "tstr-utf8-range":
    let f = ?exact(v, 3, tag & " segment")
    let a = ?uintOf(f[1], tag & " start")
    let b = ?uintOf(f[2], tag & " length")
    ok(
      if tag == "bstr-range":
        bstrRange(a, b)
      else:
        tstrRange(a, b)
    )
  else:
    fail[Segment](veShape, "unknown path segment " & tag)

func parseDisclosed(v: CborValue): Result[Disclosed, ViewError] =
  if v.kind != ckMap or v.lookup(0'u64).isNone:
    return fail[Disclosed](veShape, "the disclosed item is not a tagged map")
  let tag = ?textOf(v.lookup(0'u64).get, "disclosed item kind")
  case tag
  of "value":
    let f = ?exact(v, 2, "disclosed value")
    ok(Disclosed(kind: diValue, value: f[1]))
  of "absence":
    discard ?exact(v, 1, "disclosed absence")
    ok(Disclosed(kind: diAbsence))
  of "bstr-range", "tstr-utf8-range":
    let f = ?exact(v, 5, "disclosed range")
    if f[4].kind != ckBytes:
      return fail[Disclosed](veShape, "disclosed range bytes are not a byte string")
    ok(
      rangeDisclosure(
        tag != "bstr-range",
        ?uintOf(f[1], "range total"),
        ?uintOf(f[2], "range start"),
        ?uintOf(f[3], "range count"),
        f[4].bytes,
      )
    )
  else:
    fail[Disclosed](veShape, "unknown disclosed item " & tag)

func parseView*(v: CborValue): Result[VerifiedView, ViewError] =
  ## [SPEC HASH §7.6] A `verified-view` object, exactly.
  let f = ?exact(v, 10, "verified view")
  if (?textOf(f[0], "view tag")) != "verified-view":
    return fail[VerifiedView](veShape, "not a verified view")
  let schemaRoot = ?digestField(f[1], "schema root")
  let subtreeRoot = ?digestField(f[2], "schema subtree root")
  let valueRoot = ?digestField(f[3], "value root")
  let profileId = ?textOf(f[4], "hash profile id")
  let suiteId = ?textOf(f[5], "hash suite id")
  let modelId = ?textOf(f[6], "commitment model id")
  let disclosed = ?parseDisclosed(f[8])
  var view = VerifiedView(
    schemaRoot: schemaRoot,
    subtreeRoot: subtreeRoot,
    valueRoot: valueRoot,
    profileId: profileId,
    suiteId: suiteId,
    modelId: modelId,
    disclosed: disclosed,
  )
  if f[7].kind != ckArray:
    return fail[VerifiedView](veShape, "the path is not an array")
  for s in f[7].items:
    view.path.add(?parseSegment(s))
  if f[9].kind != ckArray:
    return fail[VerifiedView](veShape, "the proof material is not an array")
  for s in f[9].items:
    let g = ?exact(s, 2, "proof step")
    let d = parseDomain(?textOf(g[0], "proof step domain"))
    if d.isNone or d.get in {dSchemaRoot, dSchemaNode, dSchemaLeaf, dSchemaReference}:
      return fail[VerifiedView](veShape, "a proof step has no value domain")
    view.proof.add(ProofStep(domain: d.get, payload: g[1]))
  ok(view)

# Producer ----------------------------------------------------------------------------

func step(n: PhysNode): ProofStep =
  ProofStep(domain: domainOf(n.kind), payload: n.payload)

func isBranch(label: CborValue, k: uint64): bool =
  ## A branch label whose base-record range holds `k`.
  let l = parseLabel(label)
  l.isOk and l.get.kind == lkBranch and l.get.a <= k and k - l.get.a < l.get.b

func descend(
    node: PhysNode, leaf: CborValue, k: uint64, up: var seq[ProofStep]
): Result[Record, string] =
  ## The record labelled `leaf` below `node`, through the branches that cover base
  ## record `k`; each branch's payload is added to `up`.
  var records = node.children
  while true:
    var next: PhysNode = nil
    for r in records:
      if r.label == leaf:
        return ok(r)
      if r.label.isBranch(k):
        next = r.node
    if next.isNil:
      return err("no record for the path")
    up.add(step(next))
    records = next.children

func viewOf*(r: ValueRoot, path: openArray[Segment]): Result[VerifiedView, string] =
  ## [SPEC HASH §8] The verified view of the item at `path` in `r`.
  let phys = ?layout(r)
  var view = VerifiedView(
    schemaRoot: r.schemaRoot,
    subtreeRoot: r.subtreeRoot,
    valueRoot: phys.digest,
    profileId: SpecProfile.profileId,
    suiteId: SpecProfile.suiteId,
    modelId: r.modelId,
    path: @path,
  )
  if path.len == 0:
    view.disclosed = Disclosed(kind: diValue, value: toCbor(r))
    return ok(view)
  var
    up = @[ProofStep(domain: dValueRoot, payload: phys.payload)] # top-down
    v = r.node
    p = phys.child
    i = 0
    done = false
  while not done:
    while i < path.len and v.kind == vkReference:
      up.add(step(p))
      v = v.referencedValue
      p = p.children[0].node
    if i == path.len:
      view.disclosed = Disclosed(kind: diValue, value: toCbor(v))
      break
    let seg = path[i]
    let last = i == path.high
    case seg.kind
    of sgField:
      if v.kind != vkMap:
        return err("a field segment below a " & $v.kind & " value")
      var k = -1
      for j, f in v.fields:
        if f.fieldName == seg.field:
          k = j
      if k < 0:
        return err("no field " & seg.field)
      up.add(step(p))
      let rec = ?descend(p, fieldLabel(seg.field), uint64(k), up)
      if v.fields[k].fieldValue.kind == vkAbsent:
        if not last:
          return err("the path continues below an absent field")
        view.disclosed = Disclosed(kind: diAbsence)
        done = true
      else:
        up.add(step(rec.node))
        v = v.fields[k].fieldValue
        p = rec.node.children[0].node
    of sgListIndex:
      if v.kind != vkList or seg.index >= uint64(v.elements.len):
        return err("no list element " & $seg.index)
      let idx = seg.index
      let n = uint64(v.elements.len)
      up.add(step(p))
      var rec: Record
      if n <= ListChunk:
        rec = ?descend(p, indexLabel(idx), idx, up)
      else:
        let c = idx div ListChunk
        let start = c * ListChunk
        let chunk =
          ?descend(p, indexRangeLabel(start, min(ListChunk.uint64, n - start)), c, up)
        up.add(step(chunk.node))
        if chunk.node.kind == nkPackedChunk:
          if not last:
            return err("the path continues below a packed scalar")
          view.disclosed =
            Disclosed(kind: diValue, value: toCbor(v.elements[int(idx)].elementValue))
          break
        rec = ?descend(chunk.node, indexLabel(idx), idx, up)
      v = v.elements[int(idx)].elementValue
      p = rec.node
    of sgTuplePosition:
      if v.kind != vkTuple or seg.index >= uint64(v.positions.len):
        return err("no tuple position " & $seg.index)
      up.add(step(p))
      let rec = ?descend(p, tupleLabel(seg.index), seg.index, up)
      up.add(step(rec.node))
      v = v.positions[int(seg.index)].positionValue
      p = rec.node.children[0].node
    of sgChoiceArm:
      if v.kind != vkChoice or v.armIndex != seg.index:
        return err("arm " & $seg.index & " is not the selected arm")
      up.add(step(p))
      v = v.armValue
      p = p.children[0].node
    of sgBstrRange, sgTstrRange:
      let want = if seg.kind == sgBstrRange: skBstr else: skTstr
      if not last or v.kind != vkScalar or v.scalar.kind != want:
        return err("a range segment must end the path at a " & $want & " value")
      let data =
        if want == skBstr:
          v.scalar.bytes
        else:
          @(v.scalar.text.toOpenArrayByte(0, v.scalar.text.high))
      let total = uint64(data.len)
      if seg.length == 0 or seg.start > total or seg.length > total - seg.start:
        return err("the range is empty or ends past the string")
      if p.kind in {nkBstrDirect, nkTstrDirect}:
        up.add(step(p))
      else:
        up.add(step(p))
        let c = seg.start div StringChunk
        let cs = c * StringChunk
        let cn = min(StringChunk.uint64, total - cs)
        if seg.start + seg.length > cs + cn:
          return err("the range crosses a 4096-byte chunk boundary")
        let chunk = ?descend(p, byteRangeLabel(cs, cn), c, up)
        up.add(step(chunk.node))
      view.disclosed = rangeDisclosure(
        want == skTstr,
        total,
        seg.start,
        seg.length,
        data[int(seg.start) ..< int(seg.start + seg.length)],
      )
      done = true
    inc i
  view.proof = up.reversed
  ok(view)

# Verifier ----------------------------------------------------------------------------

type
  Expect = object
    kind: NodeKind
    digest, schema: Digest
    label: CborValue

  Replay = object
    steps: seq[ProofStep] ## top-down
    next: int
    root: Digest ## field 1 of the payloads at this depth
    schema: Opt[ViewSchema]

func expectOf(r: ParsedRecord, label: CborValue): Expect =
  Expect(kind: r.kind, digest: r.digest, schema: r.schema, label: label)

func take(rp: var Replay, e: Expect): Result[seq[CborValue], ViewError] =
  ## The next step: the complete canonical payload of the node `e` names.
  if rp.next >= rp.steps.len:
    return fail[seq[CborValue]](veProof, "a proof step is missing")
  let s = rp.steps[rp.next]
  inc rp.next
  if s.domain != domainOf(e.kind):
    return
      fail[seq[CborValue]](veProof, "step domain " & $s.domain & " is not " & $e.kind)
  let c = checkValuePayload(s.domain, s.payload)
  if c.isErr:
    return fail[seq[CborValue]](veProof, "step payload: " & $c.error)
  if hashinput.digestOf(s.domain, s.payload) != e.digest:
    return fail[seq[CborValue]](veProof, "a step does not hash to its record's digest")
  var f: seq[CborValue]
  for i in 0 ..< s.payload.entries.len:
    f.add(s.payload.lookup(uint64(i)).get)
  if toDigest(f[1]).get != rp.root or toDigest(f[2]).get != e.schema:
    return fail[seq[CborValue]](veProof, "a step's roots differ from its record's")
  ok(f)

func pick(
    rp: var Replay,
    records: CborValue,
    leaf: CborValue,
    k: Opt[uint64],
    parent: NodeKind,
    parentSchema: Digest,
): Result[Expect, ViewError] =
  ## The one record labelled `leaf`, through the branches covering base record `k`.
  var recs = records.items
  while true:
    var found: seq[Expect]
    for x in recs:
      let r = parseChildRecord(x).valueOr:
        return fail[Expect](veProof, $error)
      let label = x.lookup(0'u64).get
      if label == leaf or (k.isSome and r.kind == nkBranch and label.isBranch(k.get)):
        found.add(expectOf(r, label))
    if found.len != 1:
      return
        fail[Expect](veProof, "the path names " & $found.len & " records in a payload")
    let e = found[0]
    if e.kind != nkBranch:
      return ok(e)
    let f = ?rp.take(e)
    let l = parseLabel(e.label).get
    if f[3] != cbor($parent) or f[4] != cbor(l.a) or f[5] != cbor(l.b) or
        e.schema != parentSchema:
      return fail[Expect](veProof, "a branch does not match its record")
    recs = f[6].items

func finish(rp: Replay): Result[void, ViewError] =
  if rp.next != rp.steps.len:
    return fail[void](veProof, "the proof has steps the path does not need")
  ok()

func identityAt(rp: Replay, site: Site): Opt[Digest] =
  if rp.schema.isNone:
    return Opt.none(Digest)
  Opt.some(rp.schema.get.set.identityOf(site))

func needSchema(
    rp: Replay, got: Digest, site: Site, what: string
): Result[void, ViewError] =
  let want = rp.identityAt(site)
  if want.isSome and want.get != got:
    return
      fail[void](veSchema, what & " does not carry the schema identity of its path")
  ok()

func disclosedValue(
    rp: Replay, d: Disclosed, site: Site, e: Expect
): Result[void, ViewError] =
  ## [SPEC HASH §8 steps 4-5] Normalize the disclosed value under the schema at
  ## the path and recompute its physical digest.
  if d.kind != diValue:
    return fail[void](veDisclosed, "the path selects a value, not " & $d.kind)
  var node = parseValueNode(d.value).valueOr:
    return fail[void](veDisclosed, error)
  if rp.schema.isSome:
    let s = rp.schema.get
    let again = s.set.normalizeAt(site, plainValue(node)).valueOr:
      return
        fail[void](veDisclosed, "the disclosed value does not fit the schema: " & error)
    if toCbor(again) != d.value:
      return fail[void](veDisclosed, "the disclosed value is not its normalized form")
    node = again
  let p = layoutValue(rp.root, node).valueOr:
    return fail[void](veDisclosed, error)
  if p.kind != e.kind or p.digest != e.digest or p.schema != e.schema:
    return fail[void](veProof, "the disclosed value does not match its record")
  ok()

func verifyAgainst(
    view: VerifiedView, schema: Opt[ViewSchema], profile: HashProfile
): Result[void, ViewError] =
  ## [SPEC HASH §8] Checks `view` against its value root. Validity says nothing of
  ## whether that root is trusted.
  # Step 1: identifiers.
  if view.profileId != profile.profileId or view.suiteId != profile.suiteId or
      view.modelId != profile.modelId:
    return fail[void](veProfile, "unknown hash profile, suite or commitment model")
  # Step 2: the schema names the root and subtree [IMPL-DECISION G120].
  var site: Site
  if schema.isSome:
    let s = schema.get
    if s.doc < 0 or s.doc >= s.set.docs.len or
        schemaRoot(s.set.docs[s.doc]) != view.schemaRoot:
      return
        fail[void](veSchema, "the supplied schema does not have the view's schema root")
    let d = s.set.docs[s.doc].declarationBySubtree(view.subtreeRoot)
    if d.isNone or d.get.kind == dkMethod:
      return fail[void](veSchema, "the schema subtree root names no value declaration")
    site = declSite(s.doc, d.get)
  # The whole value: no proof, the value root recomputed from the disclosure.
  if view.path.len == 0:
    if view.proof.len > 0:
      return fail[void](veProof, "a whole-value view carries proof material")
    if view.disclosed.kind != diValue:
      return fail[void](veDisclosed, "a whole-value view discloses a value")
    var r = parseValueRoot(view.disclosed.value).valueOr:
      return fail[void](veDisclosed, error)
    if r.schemaRoot != view.schemaRoot or r.subtreeRoot != view.subtreeRoot or
        r.modelId != view.modelId:
      return fail[void](veDisclosed, "the disclosed value root has other roots")
    if schema.isSome:
      let again = schema.get.set.normalizeAt(site, plainValue(r.node)).valueOr:
        return fail[void](veDisclosed, error)
      if toCbor(again) != toCbor(r.node):
        return fail[void](veDisclosed, "the disclosed value is not its normalized form")
      r.node = again
    let got = valueRoot(r).valueOr:
      return fail[void](veDisclosed, error)
    if got != view.valueRoot:
      return
        fail[void](veRoot, "the disclosed value does not have the view's value root")
    return ok()
  # Steps 3-7, from the value root down the path.
  var rp = Replay(steps: view.proof.reversed, root: view.schemaRoot, schema: schema)
  if rp.steps.len == 0 or rp.steps[0].domain != dValueRoot:
    return fail[void](veProof, "the last proof step is not the value-root payload")
  let top = rp.steps[0].payload
  let c = checkValuePayload(dValueRoot, top)
  if c.isErr:
    return fail[void](veProof, $c.error)
  if hashinput.digestOf(dValueRoot, top) != view.valueRoot:
    return fail[void](veRoot, "the proof does not reach the view's value root")
  if top.lookup(1'u64).get != cbor(view.schemaRoot) or
      top.lookup(2'u64).get != cbor(view.subtreeRoot):
    return fail[void](veProof, "the value-root payload names other roots")
  rp.next = 1
  var e = expectOf(parseRootChildRecord(top.lookup(3'u64).get).get, nil)
  let has = schema.isSome
  var i = 0
  while true:
    let vsite =
      if has:
        schema.get.set.throughLocal(site).valueOr:
          return fail[void](veSchema, error)
      else:
        site
    ?rp.needSchema(e.schema, vsite, "a value")
    if i == view.path.len:
      ?rp.disclosedValue(view.disclosed, site, e)
      return rp.finish()
    let seg = view.path[i]
    let last = i == view.path.high
    case e.kind
    of nkReference:
      let f = ?rp.take(e)
      let target = toDigest(f[3]).get
      if has:
        if vsite.node.kind != snImportedRef or f[3] != cbor(vsite.node.imported.root) or
            f[4] != cbor(vsite.node.imported.subtree):
          return fail[void](veSchema, "the reference does not name the schema's import")
        site = schema.get.set.importedSite(vsite).valueOr:
          return fail[void](veSchema, error)
      rp.root = target # [IMPL-DECISION G2]
      e = expectOf(parseRootChildRecord(f[5]).get, nil)
      continue
    of nkMap:
      if seg.kind != sgField:
        return fail[void](vePath, "a " & $seg.kind & " segment at a map")
      var k = Opt.none(uint64)
      var optional = false
      var fsite: Site
      if has:
        if vsite.node.kind != snMap:
          return fail[void](veSchema, "the schema has no map here")
        for j, fd in vsite.node.fields:
          if fd.name == seg.field:
            k = Opt.some(uint64(j))
            optional = fd.optional
            fsite = vsite.child(PathSegment(kind: psField, field: fd.name), fd.node)
        if k.isNone:
          return fail[void](vePath, "the schema map has no field " & seg.field)
      let f = ?rp.take(e)
      if has and f[3] != cbor(uint64(vsite.node.fields.len)):
        return fail[void](veSchema, "the map's field count differs from its schema")
      let rec = ?rp.pick(f[4], fieldLabel(seg.field), k, nkMap, e.schema)
      ?rp.needSchema(rec.schema, fsite, "a field")
      case rec.kind
      of nkAbsent:
        if not last or view.disclosed.kind != diAbsence:
          return fail[void](veDisclosed, "the field is absent")
        if has and not optional:
          return fail[void](veSchema, "a required field cannot be absent")
        let absent = cborMap(
          entry(0, cbor("absent")),
          entry(1, cbor(rp.root)),
          entry(2, cbor(rec.schema)),
          entry(3, cbor(seg.field)),
        )
        if hashinput.digestOf(dAbsent, absent) != rec.digest:
          return fail[void](veProof, "the absent marker does not match its record")
        return rp.finish()
      of nkField:
        if view.disclosed.kind == diAbsence and last:
          return fail[void](veDisclosed, "the field is present")
        let g = ?rp.take(rec)
        if g[3] != cbor(seg.field):
          return fail[void](veProof, "the field payload names another field")
        e = expectOf(parseRootChildRecord(g[4]).get, nil)
        site = fsite
      else:
        return fail[void](veProof, "a map record is a " & $rec.kind)
    of nkList:
      if seg.kind != sgListIndex:
        return fail[void](vePath, "a " & $seg.kind & " segment at a list")
      let f = ?rp.take(e)
      let n = f[4].uint
      let idx = seg.index
      if idx >= n:
        return fail[void](vePath, "list index " & $idx & " is past the list's end")
      var esite: Site
      var pack = Opt.none(ScalarKind)
      if has:
        if vsite.node.kind != snList:
          return fail[void](veSchema, "the schema has no list here")
        esite = vsite.child(PathSegment(kind: psListElement), vsite.node.element)
        pack = packKindOf(vsite.node.element)
        ?rp.needSchema(toDigest(f[3]).get, esite, "the list element schema")
      var rec: Expect
      if n <= ListChunk:
        rec = ?rp.pick(f[5], indexLabel(idx), Opt.none(uint64), nkList, e.schema)
      else:
        let ci = idx div ListChunk
        let start = ci * ListChunk
        let chunk = ?rp.pick(
          f[5],
          indexRangeLabel(start, min(ListChunk.uint64, n - start)),
          Opt.some(ci),
          nkList,
          e.schema,
        )
        if chunk.kind == nkPackedChunk:
          if has and pack.isNone:
            return fail[void](veSchema, "the schema's list does not pack")
          if not last:
            return fail[void](vePath, "the path continues below a packed scalar")
          let g = ?rp.take(chunk)
          if g[3] != f[3] or g[5] != cbor(start):
            return fail[void](veProof, "the packed chunk does not match its list")
          if has and g[4] != cbor($pack.get):
            return fail[void](veSchema, "the packed chunk has another scalar kind")
          if view.disclosed.kind != diValue:
            return fail[void](veDisclosed, "a list element is a value")
          let node = parseValueNode(view.disclosed.value).valueOr:
            return fail[void](veDisclosed, error)
          if node.kind != vkScalar or cbor($node.scalar.kind) != g[4] or
              cbor(node.schema) != g[3] or
              toCbor(node.scalar) != g[7].items[int(idx - start)]:
            return fail[void](veDisclosed, "the disclosed scalar is not the packed one")
          if has:
            let again = schema.get.set.normalizeAt(esite, plainValue(node)).valueOr:
              return fail[void](veDisclosed, error)
            if toCbor(again) != view.disclosed.value:
              return fail[void](
                veDisclosed, "the disclosed value is not its normalized form"
              )
          return rp.finish()
        if chunk.kind != nkListChunk or (has and pack.isSome):
          return fail[void](veProof, "a list chunk record is a " & $chunk.kind)
        let g = ?rp.take(chunk)
        if g[3] != f[3] or g[4] != cbor(start):
          return fail[void](veProof, "the list chunk does not match its list")
        rec = ?rp.pick(g[6], indexLabel(idx), Opt.none(uint64), nkListChunk, e.schema)
      e = rec
      e.label = nil
      site = esite
    of nkTuple:
      if seg.kind != sgTuplePosition:
        return fail[void](vePath, "a " & $seg.kind & " segment at a tuple")
      let f = ?rp.take(e)
      if seg.index >= f[3].uint:
        return fail[void](vePath, "no tuple position " & $seg.index)
      var psite: Site
      if has:
        if vsite.node.kind != snTuple or f[3] != cbor(uint64(vsite.node.items.len)):
          return fail[void](veSchema, "the schema has no tuple of this arity here")
        psite = vsite.child(
          PathSegment(kind: psTuplePosition, index: seg.index),
          vsite.node.items[int(seg.index)],
        )
      let rec =
        ?rp.pick(f[4], tupleLabel(seg.index), Opt.some(seg.index), nkTuple, e.schema)
      if rec.kind != nkTupleElement:
        return fail[void](veProof, "a tuple record is a " & $rec.kind)
      ?rp.needSchema(rec.schema, psite, "a tuple position")
      let g = ?rp.take(rec)
      if g[3] != cbor(seg.index):
        return fail[void](veProof, "the tuple element names another position")
      e = expectOf(parseRootChildRecord(g[4]).get, nil)
      site = psite
    of nkChoice:
      if seg.kind != sgChoiceArm: # [IMPL-DECISION G8]
        return fail[void](vePath, "a choice is crossed only by its choice-arm segment")
      let f = ?rp.take(e)
      if f[3] != cbor(seg.index):
        return fail[void](vePath, "arm " & $seg.index & " is not the selected arm")
      var asite: Site
      if has:
        if vsite.node.kind != snChoice or seg.index >= uint64(vsite.node.arms.len):
          return fail[void](veSchema, "the schema has no such choice arm here")
        asite = vsite.child(
          PathSegment(kind: psChoiceArm, index: seg.index),
          vsite.node.arms[int(seg.index)],
        )
        ?rp.needSchema(toDigest(f[4]).get, asite, "the selected arm")
      let r = parseChildRecord(f[5]).get
      if f[5].lookup(0'u64).get != choiceLabel(seg.index):
        return fail[void](veProof, "the arm record has another label")
      e = expectOf(r, nil)
      site = asite
    of nkBstr, nkBstrDirect, nkTstr, nkTstrDirect:
      let text = e.kind in {nkTstr, nkTstrDirect}
      let want = if text: sgTstrRange else: sgBstrRange
      if seg.kind != want or not last:
        return fail[void](
          vePath, "a string is entered only by a final " & $want & " segment"
        )
      if has:
        let s = vsite.node
        let k =
          if s.kind == snPrimitive:
            s.scalar
          elif s.kind == snLiteral:
            s.literal.kind
          else:
            skBool
        if k != (if text: skTstr else: skBstr):
          return fail[void](veSchema, "the schema has no such string here")
      let d = view.disclosed
      if d.kind != (if text: diTstrRange else: diBstrRange) or d.offset != seg.start or
          d.count != seg.length or uint64(d.bytes.len) != seg.length:
        return fail[void](veDisclosed, "the disclosed range is not the path's")
      let f = ?rp.take(e)
      let total = f[3].uint
      if d.total != total or seg.length == 0 or seg.start > total or
          seg.length > total - seg.start:
        return fail[void](vePath, "the range is empty or ends past the string")
      var
        data: seq[byte]
        base = 0'u64
      if e.kind in {nkBstrDirect, nkTstrDirect}:
        data =
          if text:
            @(f[4].text.toOpenArrayByte(0, f[4].text.high))
          else:
            f[4].bytes
      else:
        let ci = seg.start div StringChunk
        let cs = ci * StringChunk
        let cn = min(StringChunk.uint64, total - cs)
        if seg.start + seg.length > cs + cn:
          return fail[void](vePath, "the range crosses a 4096-byte chunk boundary")
        let chunk =
          ?rp.pick(f[4], byteRangeLabel(cs, cn), Opt.some(ci), e.kind, e.schema)
        let g = ?rp.take(chunk)
        if g[3] != cbor(total) or g[4] != cbor(cs) or g[5] != cbor(cn):
          return fail[void](veProof, "the string chunk does not match its string")
        data = g[6].bytes
        base = cs
      let from0 = int(seg.start - base)
      if data[from0 ..< from0 + int(seg.length)] != d.bytes:
        return
          fail[void](veDisclosed, "the disclosed bytes differ from the committed ones")
      return rp.finish()
    else:
      return fail[void](vePath, "the path continues below a " & $e.kind)
    inc i

func verifyView*(
    view: VerifiedView, schema: ViewSchema, profile = SpecProfile
): Result[void, ViewError] =
  ## [SPEC HASH §8 l.1214-1215, l.1242] Checks `view` against its value root
  ## under `schema`, the schema construction input verification requires: its
  ## root must be the view's schema root and its subtree root a value
  ## declaration's [IMPL-DECISION G120]. Validity says nothing of whether that
  ## root is trusted.
  verifyAgainst(view, Opt.some(schema), profile)

func verifyPhysicalProof*(
    view: VerifiedView, profile = SpecProfile
): Result[void, ViewError] =
  ## Replays only the physical proof of `view`, with no schema. This is not a
  ## HASH §8 verification (l.1214-1215 requires the schema construction input):
  ## it exists for the synthetic HASH App B.1-B.3 identities, whose schema roots
  ## name no schema (TF-13), and cannot descend a branched map. Production code
  ## calls `verifyView`.
  verifyAgainst(view, Opt.none(ViewSchema), profile)
