## HASH §5-§7.5, verifier side: decoding a hash input and checking a value payload.
##
## A verifier rebuilds digests only from payloads that pass these checks: known
## ids, a domain whose payload shape it is, 32-byte digests, known node kinds,
## labels of the right kind, and counts, ranges and coverage that agree with the
## canonical layout [SPEC HASH §6, §7.4, §7.5]. What a single payload cannot show
## (that a record's digest, kind and schema match its child) is checked when a
## proof is walked.

{.push raises: [].}

import std/strutils
import ../cbor
import ./[hashinput, layout]
import ../commitment/value

type
  HashErrorKind* = enum
    heMalformedCbor = "malformed-cbor"
    heNonCanonical = "non-canonical-cbor"
    heShape = "malformed-hash-input"
    heProfile = "unknown-hash-profile"
    heSuite = "unknown-hash-suite"
    heModel = "unknown-commitment-model"
    heDomain = "domain-mismatch"
    heDigestLength = "digest-length"
    heNodeKind = "node-kind"
    heLayout = "layout-mismatch"

  HashError* = object
    kind*: HashErrorKind
    msg*: string

func hashError*(kind: HashErrorKind, msg: string): HashError =
  HashError(kind: kind, msg: msg)

func `$`*(e: HashError): string =
  $e.kind & ": " & e.msg

template fail(kind: HashErrorKind, msg: string): untyped =
  err(hashError(kind, msg))

# Readers -------------------------------------------------------------------------

func fields(v: CborValue, n: int, what: string): Result[seq[CborValue], HashError] =
  ## A map whose keys are exactly 0 .. n-1, values in key order.
  if v.isNil or v.kind != ckMap:
    return fail(heShape, what & " is not a map")
  if v.entries.len != n:
    return fail(heShape, what & " has " & $v.entries.len & " fields, expected " & $n)
  var output = newSeq[CborValue](n)
  for i, (k, x) in v.entries:
    # Decoded maps are in deterministic order, so key i is at position i.
    if k.kind != ckUint or k.uint != uint64(i):
      return fail(heShape, what & " has unexpected key " & toDiag(k))
    output[i] = x
  ok(output)

func asUint(v: CborValue, what: string): Result[uint64, HashError] =
  if v.kind != ckUint:
    return fail(heShape, what & " is not an unsigned integer")
  ok(v.uint)

func asText(v: CborValue, what: string): Result[string, HashError] =
  if v.kind != ckText or not v.validUtf8:
    return fail(heShape, what & " is not a text string")
  ok(v.text)

func asDigest(v: CborValue, what: string): Result[Digest, HashError] =
  if v.kind != ckBytes:
    return fail(heShape, what & " is not a byte string")
  let d = toDigest(v).valueOr:
    return fail(heDigestLength, what & " is " & $v.bytes.len & " bytes, not 32")
  ok(d)

func asArray(v: CborValue, what: string): Result[seq[CborValue], HashError] =
  if v.kind != ckArray:
    return fail(heShape, what & " is not an array")
  ok(v.items)

func asNodeKind(v: CborValue, what: string): Result[NodeKind, HashError] =
  let s = ?asText(v, what)
  let k = parseNodeKind(s).valueOr:
    return fail(heNodeKind, "unknown node kind " & s)
  ok(k)

# Records and labels --------------------------------------------------------------

type
  LabelKind* = enum
    lkField = "field"
    lkIndex = "index"
    lkIndexRange = "index-range"
    lkTuple = "tuple-position"
    lkChoice = "choice-arm"
    lkByteRange = "byte-range"
    lkBranch = "branch"

  Label* = object
    kind*: LabelKind
    name*: string ## lkField
    a*, b*: uint64 ## index / position / arm, or start and count

  ParsedRecord* = object
    label*: Label ## unset for a root-child-record
    kind*: NodeKind
    digest*: Digest
    schema*: Digest

func parseLabel*(v: CborValue): Result[Label, HashError] =
  ## [SPEC HASH §7.3] `child-label`.
  if v.isNil or v.kind != ckMap or v.entries.len == 0:
    return fail(heShape, "child label is not a map")
  let tag = ?asText(v.lookup(0'u64).valueOr(cborNull()), "child label field 0")
  var kind = lkField
  var found = false
  for k in LabelKind:
    if $k == tag:
      kind = k
      found = true
  if not found:
    return fail(heShape, "unknown child label " & tag)
  case kind
  of lkField:
    let f = ?fields(v, 2, "field label")
    ok(Label(kind: kind, name: ?asText(f[1], "field label name")))
  of lkIndex, lkTuple, lkChoice:
    let f = ?fields(v, 2, tag & " label")
    ok(Label(kind: kind, a: ?asUint(f[1], tag & " label")))
  of lkIndexRange, lkByteRange, lkBranch:
    let f = ?fields(v, 3, tag & " label")
    ok(
      Label(
        kind: kind, a: ?asUint(f[1], tag & " start"), b: ?asUint(f[2], tag & " count")
      )
    )

func parseRootChildRecord*(v: CborValue): Result[ParsedRecord, HashError] =
  ## [SPEC HASH §7.3] `root-child-record`.
  let f = ?fields(v, 3, "root-child-record")
  ok(
    ParsedRecord(
      kind: ?asNodeKind(f[0], "record node kind"),
      digest: ?asDigest(f[1], "record digest"),
      schema: ?asDigest(f[2], "record schema identity"),
    )
  )

func parseChildRecord*(v: CborValue): Result[ParsedRecord, HashError] =
  ## [SPEC HASH §7.3] `child-record`.
  let f = ?fields(v, 4, "child-record")
  ok(
    ParsedRecord(
      label: ?parseLabel(f[0]),
      kind: ?asNodeKind(f[1], "record node kind"),
      digest: ?asDigest(f[2], "record digest"),
      schema: ?asDigest(f[3], "record schema identity"),
    )
  )

func parseRecords(v: CborValue, what: string): Result[seq[ParsedRecord], HashError] =
  var output: seq[ParsedRecord]
  for x in ?asArray(v, what):
    output.add(?parseChildRecord(x))
  ok(output)

const ValueNodeKinds* = {
  nkMap, nkList, nkTuple, nkChoice, nkScalar, nkBstr, nkBstrDirect, nkTstr,
  nkTstrDirect, nkReference,
}
  ## Node kinds that can carry a whole value: the child of a field, tuple
  ## element, choice arm, reference, value root, or a list element.

func ceilDiv(a, b: uint64): uint64 =
  (a + b - 1) div b

func checkKind(
    r: ParsedRecord, allowed: set[NodeKind], where: string
): Result[void, HashError] =
  if r.kind notin allowed:
    return fail(heNodeKind, "a " & $r.kind & " record cannot appear in " & where)
  ok()

type BaseCheck = object
  ## Checks the base records of one collection, in order (HASH §5, §7.4).
  parent: NodeKind ## map, list (chunked), tuple, bstr or tstr
  directList: bool ## a list of at most 256 elements: index-labelled elements
  schema: Digest ## the collection's schema identity
  total: Opt[uint64] ## list length or string byte length, when known
  chunkKind: Opt[NodeKind]
  previous: Opt[string]

func unit(c: BaseCheck): uint64 =
  if c.parent in {nkBstr, nkTstr}:
    uint64(StringChunk)
  else:
    uint64(ListChunk)

func checkBase(
    c: var BaseCheck, index: uint64, r: ParsedRecord
): Result[void, HashError] =
  ## Base record number `index` of the collection.
  let where = "a " & $c.parent
  if c.directList:
    ?checkKind(r, ValueNodeKinds, "a direct list")
    if r.label.kind != lkIndex or r.label.a != index:
      return fail(heLayout, "direct list record " & $index & " has the wrong label")
    return ok()
  case c.parent
  of nkMap:
    ?checkKind(r, {nkField, nkAbsent}, where)
    if r.label.kind != lkField:
      return fail(heLayout, "a map record is not field-labelled")
    if c.previous.isSome and r.label.name <= c.previous.get:
      return fail(heLayout, "map records are not in canonical field-name order")
    c.previous = Opt.some(r.label.name)
  of nkTuple:
    ?checkKind(r, {nkTupleElement}, where)
    if r.label.kind != lkTuple or r.label.a != index:
      return fail(heLayout, "tuple record " & $index & " has the wrong label")
  of nkList, nkBstr, nkTstr:
    let allowed =
      case c.parent
      of nkList:
        {nkListChunk, nkPackedChunk}
      of nkBstr:
        {nkBstrChunk}
      else:
        {nkTstrChunk}
    ?checkKind(r, allowed, where)
    if c.chunkKind.isSome and c.chunkKind.get != r.kind:
      return fail(heLayout, "a chunked list mixes packed and ordinary chunks")
    c.chunkKind = Opt.some(r.kind)
    let
      wanted = if c.parent == nkList: lkIndexRange else: lkByteRange
      start = index * c.unit
      fits =
        if c.total.isSome:
          start < c.total.get and r.label.b == min(c.unit, c.total.get - start)
        else:
          r.label.b >= 1 and r.label.b <= c.unit
    if r.label.kind != wanted or r.label.a != start or not fits:
      return fail(heLayout, "chunk " & $index & " of " & where & " has the wrong range")
    if r.schema != c.schema:
      return fail(heLayout, "a chunk record of " & where & " changes schema identity")
  else:
    raiseAssert "not a collection kind"
  ok()

func branchSize(baseCount: uint64): uint64 =
  ## [SPEC HASH §5] The base records each top-level branch represents: the
  ## smallest 256^k that leaves at most 256 branches.
  var size = uint64(Fanout)
  while (baseCount + size - 1) div size > uint64(Fanout):
    size *= uint64(Fanout)
  size

func checkBranchRanges(
    records: seq[ParsedRecord], start, count, size: uint64, schema: Digest
): Result[void, HashError] =
  ## Branch records covering `count` base records from `start`, `size` each
  ## (the last one the rest).
  if uint64(records.len) != (count + size - 1) div size:
    return fail(heLayout, "wrong number of branch records")
  for i, r in records:
    ?checkKind(r, {nkBranch}, "a branch list")
    let at = start + uint64(i) * size
    if r.label.kind != lkBranch or r.label.a != at or
        r.label.b != min(size, start + count - at):
      return fail(heLayout, "branch record " & $i & " has the wrong range")
    if r.schema != schema:
      return fail(heLayout, "a branch record changes schema identity")
  ok()

func checkCollection(
    c: var BaseCheck, records: seq[ParsedRecord], baseCount: uint64
): Result[void, HashError] =
  ## Direct base records when there are at most 256, branches otherwise
  ## [SPEC HASH §5].
  if baseCount > uint64(Fanout):
    return checkBranchRanges(records, 0, baseCount, branchSize(baseCount), c.schema)
  if uint64(records.len) != baseCount:
    return fail(
      heLayout,
      "a " & $c.parent & " has " & $records.len & " records, expected " & $baseCount,
    )
  for i, r in records:
    ?c.checkBase(uint64(i), r)
  ok()

# Scalars -------------------------------------------------------------------------

func checkScalarData*(kind: ScalarKind, v: CborValue): Result[void, HashError] =
  ## [SPEC COMMITMENT §9.3] `scalar-data` matches its kind and range.
  let good =
    case kind
    of skBool:
      v.isBool
    of skUint8 .. skUint64:
      v.kind == ckUint and scalarInRange(uintScalar(kind, v.uint))
    of skInt8 .. skInt64:
      let i = v.getInt64
      i.isSome and scalarInRange(intScalar(kind, i.get))
    of skTstr:
      v.kind == ckText and scalarInRange(textScalar(v.text))
    of skBstr:
      v.kind == ckBytes
  if not good:
    return fail(heShape, "scalar data does not match " & $kind)
  ok()

func asPackableKind(v: CborValue): Result[ScalarKind, HashError] =
  let s = ?asText(v, "scalar kind")
  let k = parseScalarKind(s).valueOr:
    return fail(heShape, "unknown scalar kind " & s)
  if k notin PackableKinds:
    return fail(heShape, s & " is not a packable scalar kind")
  ok(k)

# Payloads ------------------------------------------------------------------------

func payloadKind(d: Domain): Opt[NodeKind] =
  for k in NodeKind:
    if domainOf(k) == d:
      return Opt.some(k)
  Opt.none(NodeKind)

func checkStringAggregate(
    f: seq[CborValue], kind: NodeKind, schema: Digest
): Result[void, HashError] =
  let total = ?asUint(f[3], "total byte length")
  if total <= uint64(StringChunk):
    return fail(heLayout, "a string aggregate holds more than 4096 bytes")
  var c = BaseCheck(parent: kind, schema: schema, total: Opt.some(total))
  c.checkCollection(
    ?parseRecords(f[4], "aggregate records"), ceilDiv(total, uint64(StringChunk))
  )

func checkStringChunk(f: seq[CborValue]): Result[void, HashError] =
  let
    total = ?asUint(f[3], "total byte length")
    off = ?asUint(f[4], "chunk offset")
    count = ?asUint(f[5], "chunk byte count")
  if f[6].kind != ckBytes:
    return fail(heShape, "chunk bytes are not a byte string")
  if total <= uint64(StringChunk) or off mod uint64(StringChunk) != 0 or off >= total or
      count != min(uint64(StringChunk), total - off) or uint64(f[6].bytes.len) != count:
    return fail(heLayout, "string chunk is not a canonical byte range")
  ok()

func checkBranch(f: seq[CborValue], schema: Digest): Result[void, HashError] =
  let
    parentText = ?asText(f[3], "branch parent kind")
    parent = parseNodeKind(parentText).valueOr(nkBranch)
    start = ?asUint(f[4], "branch start")
    count = ?asUint(f[5], "branch count")
    records = ?parseRecords(f[6], "branch records")
  if parent notin BranchParentKinds:
    return fail(heShape, "unknown branch parent kind " & parentText)
  if records.len == 0 or records.len > Fanout:
    return fail(heLayout, "a branch holds " & $records.len & " records, not 1 to 256")
  if records[0].kind == nkBranch:
    # Children are branches of one size, 256^k, except a shorter last one.
    let size = records[0].label.b
    var power = uint64(Fanout)
    while power < size and power <= high(uint64) div uint64(Fanout):
      power *= uint64(Fanout)
    if records.len > 1 and power != size:
      return fail(heLayout, "child branches are not of a canonical size")
    if count > size * uint64(Fanout) or start mod (size * uint64(Fanout)) != 0:
      return fail(heLayout, "branch range is not canonical")
    return checkBranchRanges(records, start, count, size, schema)
  if count != uint64(records.len) or start mod uint64(Fanout) != 0:
    return fail(heLayout, "branch range does not match its records")
  var c = BaseCheck(parent: parent, schema: schema)
  for i, r in records:
    ?c.checkBase(start + uint64(i), r)
  ok()

func checkValuePayload*(domain: Domain, payload: CborValue): Result[void, HashError] =
  ## [SPEC HASH §7.4, §7.5] `payload` is the payload shape of `domain`, and its
  ## counts, labels and ranges agree with the canonical layout.
  if payload.isNil or payload.kind != ckMap or payload.entries.len == 0 or
      payload.entries[0].key != cbor(0'u64):
    return fail(heShape, "payload is not a map with a discriminator")
  let disc = ?asText(payload.entries[0].value, "payload discriminator")
  if domain == dValueRoot:
    if disc != "value-root":
      return fail(heDomain, "domain " & $domain & " carries a " & disc & " payload")
    let f = ?fields(payload, 4, "value-root payload")
    discard ?asDigest(f[1], "schema root")
    discard ?asDigest(f[2], "schema subtree root")
    return checkKind(?parseRootChildRecord(f[3]), ValueNodeKinds, "a value root")
  let kind = payloadKind(domain).valueOr:
    return fail(heDomain, $domain & " is not a value domain")
  if disc != $kind:
    return fail(heDomain, "domain " & $domain & " carries a " & disc & " payload")
  let n =
    case kind
    of nkAbsent:
      4
    of nkField, nkTupleElement, nkBstrDirect, nkTstrDirect, nkMap, nkTuple, nkScalar,
        nkBstr, nkTstr:
      5
    of nkList, nkChoice, nkReference:
      6
    of nkListChunk, nkBstrChunk, nkTstrChunk, nkBranch:
      7
    of nkPackedChunk:
      8
  let f = ?fields(payload, n, disc & " payload")
  discard ?asDigest(f[1], "schema root")
  let schema = ?asDigest(f[2], "schema subtree root")
  case kind
  of nkField:
    discard ?asText(f[3], "field name")
    ?checkKind(?parseRootChildRecord(f[4]), ValueNodeKinds, "a field")
  of nkAbsent:
    discard ?asText(f[3], "field name")
  of nkMap:
    var c = BaseCheck(parent: nkMap, schema: schema)
    ?c.checkCollection(?parseRecords(f[4], "map records"), ?asUint(f[3], "field count"))
  of nkList:
    discard ?asDigest(f[3], "element schema identity")
    let
      length = ?asUint(f[4], "list length")
      records = ?parseRecords(f[5], "list records")
    var c = BaseCheck(
      parent: nkList,
      directList: length <= uint64(ListChunk),
      schema: schema,
      total: Opt.some(length),
    )
    let baseCount =
      if c.directList:
        length
      else:
        ceilDiv(length, uint64(ListChunk))
    ?c.checkCollection(records, baseCount)
  of nkListChunk:
    discard ?asDigest(f[3], "element schema identity")
    let
      start = ?asUint(f[4], "chunk start")
      count = ?asUint(f[5], "chunk count")
      records = ?parseRecords(f[6], "chunk records")
    if start mod uint64(ListChunk) != 0 or count == 0 or count > uint64(ListChunk) or
        uint64(records.len) != count:
      return fail(heLayout, "list chunk is not a canonical range")
    for i, r in records:
      ?checkKind(r, ValueNodeKinds, "a list chunk")
      if r.label.kind != lkIndex or r.label.a != start + uint64(i):
        return fail(heLayout, "list chunk record " & $i & " has the wrong label")
  of nkPackedChunk:
    discard ?asDigest(f[3], "element schema identity")
    let
      scalarKind = ?asPackableKind(f[4])
      start = ?asUint(f[5], "chunk start")
      count = ?asUint(f[6], "chunk count")
      values = ?asArray(f[7], "packed values")
    if start mod uint64(ListChunk) != 0 or count == 0 or count > uint64(ListChunk) or
        uint64(values.len) != count:
      return fail(heLayout, "packed chunk is not a canonical range of 1 to 256 values")
    for v in values:
      ?checkScalarData(scalarKind, v)
  of nkTuple:
    var c = BaseCheck(parent: nkTuple, schema: schema)
    ?c.checkCollection(
      ?parseRecords(f[4], "tuple records"), ?asUint(f[3], "tuple arity")
    )
  of nkTupleElement:
    discard ?asUint(f[3], "tuple position")
    ?checkKind(?parseRootChildRecord(f[4]), ValueNodeKinds, "a tuple element")
  of nkChoice:
    let arm = ?asUint(f[3], "arm index")
    discard ?asDigest(f[4], "arm schema identity")
    let r = ?parseChildRecord(f[5])
    ?checkKind(r, ValueNodeKinds, "a choice")
    if r.label.kind != lkChoice or r.label.a != arm:
      return fail(heLayout, "the choice record does not name the selected arm")
  of nkScalar:
    ?checkScalarData(?asPackableKind(f[3]), f[4])
  of nkBstr, nkTstr:
    ?checkStringAggregate(f, kind, schema)
  of nkBstrDirect, nkTstrDirect:
    let length = ?asUint(f[3], "byte length")
    var body: int
    if kind == nkBstrDirect:
      if f[4].kind != ckBytes:
        return fail(heShape, "bstr-direct body is not a byte string")
      body = f[4].bytes.len
    else:
      ?checkScalarData(skTstr, f[4])
      body = f[4].text.len
    if length > uint64(StringChunk) or uint64(body) != length:
      return fail(heLayout, "direct string length is wrong or above 4096 bytes")
  of nkBstrChunk, nkTstrChunk:
    ?checkStringChunk(f)
  of nkReference:
    discard ?asDigest(f[3], "referenced schema root")
    discard ?asDigest(f[4], "referenced schema subtree root")
    ?checkKind(?parseRootChildRecord(f[5]), ValueNodeKinds, "a reference value")
  of nkBranch:
    ?checkBranch(f, schema)
  ok()

# Hash inputs ---------------------------------------------------------------------

func decodeHashInput*(
    data: openArray[byte], profile = SpecProfile
): Result[tuple[domain: Domain, payload: CborValue], HashError] =
  ## [SPEC HASH §6] Decodes and checks a canonical hash input: deterministic
  ## CBOR, the five fields, the ids `profile` accepts (the verifier's policy),
  ## and, for a value domain, a payload of that domain's shape. Schema payloads
  ## are the COMMITMENT layer's to check.
  let v = decodeCbor(data).valueOr:
    return
      if error.kind == cekNonDeterministic:
        fail(heNonCanonical, $error)
      else:
        fail(heMalformedCbor, $error)
  let f = ?fields(v, 5, "hash input")
  let tag = ?asText(f[0], "domain tag")
  if (?asText(f[1], "hash profile id")) != profile.profileId:
    return fail(heProfile, "hash profile " & f[1].text)
  if (?asText(f[2], "hash suite id")) != profile.suiteId:
    return fail(heSuite, "hash suite " & f[2].text)
  if (?asText(f[3], "commitment model")) != profile.modelId:
    return fail(heModel, "commitment model " & f[3].text)
  let domain = parseDomain(tag).valueOr:
    return fail(heDomain, "unknown domain tag " & tag)
  if not ($domain).startsWith("logos.schema."):
    ?checkValuePayload(domain, f[4])
  ok((domain, f[4]))
