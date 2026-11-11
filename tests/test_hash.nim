import std/[algorithm, sequtils, sets, strutils, tables]
import unittest2
import ../src/logos_core/[cbor, hash]
import ../src/logos_core/base/hex
import ./support/[cddlshape, specdata, valuevec]

let
  # [SPEC HASH App B] synthetic identities
  schemaRoot = ident(0x10)
  listSchema = ident(0x11)
  elementSchema = ident(0x12)
  bstrSchema = ident(0x13)

proc digestHex(d: Digest): string =
  toHex(d)

proc b1(): ValueRoot =
  hashAppB1()

proc b2(): ValueRoot =
  hashAppB2()

# Oracle vectors ---------------------------------------------------------------------

type OracleVector = object
  name: string
  root: ValueRoot
  digest, childDigest: string
  childKind: string

proc oracleVectors(): seq[OracleVector] =
  ## tests/vectors/hash/layout.cbor, written by oracle/gen_hash_vectors.py [G17].
  let file = decodeCbor(readRepoFile("tests/vectors/hash/layout.cbor")).get
  for v in file.lookup("vectors").get.items:
    result.add(
      OracleVector(
        name: v.lookup("name").get.getText.get,
        root: vectorRoot(v.lookup("tree").get),
        digest: toHex(v.lookup("root").get.getBytes.get),
        childKind: v.lookup("child-kind").get.getText.get,
        childDigest: toHex(v.lookup("child-digest").get.getBytes.get),
      )
    )
  for v in file.lookup("generated").get.items:
    let
      name = v.lookup("generator").get.getText.get
      n = int(v.lookup("n").get.getUint64.get)
    result.add(
      OracleVector(
        name: name & " " & $n,
        root: generated(name, n),
        digest: toHex(v.lookup("root").get.getBytes.get),
        childKind: v.lookup("child-kind").get.getText.get,
        childDigest: toHex(v.lookup("child-digest").get.getBytes.get),
      )
    )

let
  vectors = oracleVectors()
  physical = vectors.mapIt(layout(it.root).get)

proc byName(name: string): PhysRoot =
  for i, v in vectors:
    if v.name == name:
      return physical[i]
  raiseAssert "no vector " & name

iterator nodes(n: PhysNode): PhysNode =
  var stack = @[n]
  while stack.len > 0:
    let x = stack.pop()
    yield x
    for r in x.children:
      stack.add(r.node)

iterator allNodes(): PhysNode =
  for p in physical:
    for n in nodes(p.child):
      yield n

proc count(p: PhysRoot, kind: NodeKind): int =
  for n in nodes(p.child):
    if n.kind == kind:
      inc result

# The mirrored CDDL of HASH §5-§7 as a shape checker --------------------------------

let shapes = block:
  var sh = loadShapes(
    [
      "HSH/5.node-kind.cddl", "HSH/6.hash-input.cddl", "HSH/7.domain-tag.cddl",
      "HSH/7.1.hash-input.cddl", "HSH/7.3.child-records.cddl",
      "HSH/7.4.value-payloads.cddl", "HSH/7.5.domain-payloads.cddl",
    ]
  )
  # COMMITMENT §9.2 shapes, checked by the COMMITMENT suite.
  for r in [
    "schema-hash-payload", "schema-root-payload", "schema-node-payload",
    "schema-structural-node-payload", "schema-leaf-payload", "schema-reference-payload",
  ]:
    sh.opaque.incl(r)
  sh

proc conforms(v: CborValue, typ: string): bool =
  shapes.conforms(v, typ)

proc tableRows(rel: string): seq[seq[string]] =
  ## The cells of a mirrored Markdown table, header and rule lines dropped.
  for i, line in mirror(rel).strip.splitLines.toSeq:
    if i >= 2:
      result.add(
        line.strip(chars = {'|'}).split('|').mapIt(it.strip.strip(chars = {'`'}))
      )

let payloadRuleOf = block:
  var t: OrderedTable[string, string]
  for row in tableRows("HSH/7.5.domain-payloads.md"):
    t[row[0]] = row[1]
  t

# Mutation helpers ------------------------------------------------------------------

proc copyValue(v: CborValue): CborValue =
  decodeCbor(encodeCbor(v)).get

proc withField(v: CborValue, k: uint64, x: CborValue): CborValue =
  result = copyValue(v)
  for e in result.entries.mitems:
    if e.key == cbor(k):
      e.value = x
      return
  result.entries.add((cbor(k), x))
  result = copyValue(result)

proc withoutField(v: CborValue, k: uint64): CborValue =
  result = copyValue(v)
  result.entries.keepItIf(it.key != cbor(k))

proc rejected(d: Domain, p: CborValue): HashErrorKind =
  let r = checkValuePayload(d, p)
  doAssert r.isErr, "accepted: " & toDiag(p)[0 ..< min(200, toDiag(p).len)]
  r.error.kind

proc firstNode(p: PhysRoot, kind: NodeKind): PhysNode =
  for n in nodes(p.child):
    if n.kind == kind:
      return n
  raiseAssert "no " & $kind

# Tests -----------------------------------------------------------------------------

suite "hash: hash input and suite":
  test "[HSH-0169] [HSH-0194] [HSH-0044] [HSH-0086] App A: the mirrored hash input has the pinned length, ids and root":
    let bytes = mirrorHex("HSH/app-a.hash-input.hex")
    check bytes.len == parseInt(pin("hsh-app-a-input-length"))
    check digestOfInput(bytes).digestHex == pin("hsh-app-a-root")
    check digestOfInput(bytes).digestHex ==
      mirror("HSH/app-a.root.hex").strip.replace("\n", "")
    let v = decodeCbor(bytes).get
    check conforms(v, "hash-input")
    check v.lookup(1'u64).get.getText.get == HashProfileId
    check v.lookup(2'u64).get.getText.get == HashSuiteId
    check v.lookup(3'u64).get.getText.get == CommitmentModelId

  test "[HSH-0165] [HSH-0006] [HSH-0007] [HSH-0038] [HSH-0050] [HSH-0052] [HSH-0065] [HSH-0066] [HSH-0087] [HSH-0089] App A: hashing the COMMITMENT App A schema object reproduces the input and root":
    let payload = parseDiag(mirror("CMT/app-a.schema.diag")).get
    check encodeCbor(hashInput(dSchemaRoot, payload)) ==
      mirrorHex("HSH/app-a.hash-input.hex")
    check digestOf(dSchemaRoot, payload).digestHex == pin("hsh-app-a-root")
    check decodeHashInput(mirrorHex("HSH/app-a.hash-input.hex")).get.domain ==
      dSchemaRoot

  test "[HSH-0034] [HSH-0133] node kinds and domain tags are exactly the mirrored registry and tables":
    check shapes.alternatives("node-kind") == NodeKind.toSeq.mapIt("\"" & $it & "\"")
    var physical: seq[(string, string)]
    for row in tableRows("HSH/5.domain-tags.md"):
      physical.add((row[0], row[1]))
    check physical.len == NodeKind.toSeq.len + 1
    check physical[0][1] == $dValueRoot
    check physical[1 ..^ 1].mapIt(it[1]) == NodeKind.toSeq.mapIt($domainOf(it))
    check toSeq(payloadRuleOf.keys) ==
      @[$dValueRoot] & NodeKind.toSeq.mapIt($domainOf(it))
    for k in NodeKind:
      # Each payload rule's discriminator is its node kind.
      check shapes.keyTypes(payloadRuleOf[$domainOf(k)])[0] == "\"" & $k & "\""
    check tableRows("HSH/7.2.schema-domains.md").mapIt(it[0]) ==
      @[$dSchemaRoot, $dSchemaNode, $dSchemaLeaf, $dSchemaReference]

  test "[HSH-0039] [HSH-0061] [HSH-0134] [HSH-0036] a payload is accepted only in its own domain":
    let p = b1().layout.get.child.payload
    check digestOf(dList, p) != digestOf(dListChunk, p)
    check checkValuePayload(dList, p).isOk
    for d in [dListChunk, dMap, dTuple, dBranch, dValueRoot]:
      check rejected(d, p) == heDomain
    let input = encodeCbor(hashInput(dTuple, p))
    check decodeHashInput(input).error.kind == heDomain
    check decodeHashInput(encodeCbor(hashInput(dList, p))).isOk

  test "[HSH-0056] [HSH-0040] [HSH-0041] [HSH-0043] [HSH-0057] [HSH-0058] [HSH-0059] [HSH-0062] [HSH-0063] hash inputs with unknown ids or bad encodings are rejected":
    let p = b1().layout.get.child.payload
    let good = hashInput(dList, p)
    check decodeHashInput(encodeCbor(good)).isOk
    var other = SpecProfile
    other.profileId = "logos.hash-profile.2099-01.other"
    check digestOf(dList, p, other) != digestOf(dList, p)
    check decodeHashInput(encodeCbor(hashInput(dList, p, other))).error.kind == heProfile
    other = SpecProfile
    other.suiteId = "logos.hash-suite.sha256"
    check decodeHashInput(encodeCbor(hashInput(dList, p, other))).error.kind == heSuite
    other = SpecProfile
    other.modelId = "logos.commitment-model.2099-01"
    let otherModel = encodeCbor(hashInput(dList, p, other))
    check decodeHashInput(otherModel).error.kind == heModel
    # A verifier policy that allows that revision accepts it.
    check decodeHashInput(otherModel, other).isOk
    check decodeHashInput(encodeCbor(good.withField(0, cbor("logos.value.nope")))).error.kind ==
      heDomain
    check decodeHashInput(encodeCbor(good.withField(5, cbor(1)))).error.kind == heShape
    check decodeHashInput(encodeCbor(good.withoutField(4))).error.kind == heShape
    var bytes = encodeCbor(good)
    check decodeHashInput(bytes & @[0'u8]).error.kind == heMalformedCbor
    # Key 0 written in a two-byte head: well formed, not deterministic.
    check bytes[1] == 0x00
    bytes = @[bytes[0], 0x18'u8, 0x00] & bytes[2 ..^ 1]
    check decodeHashInput(bytes).error.kind == heNonCanonical

  test "[HSH-0042] [HSH-0060] digests and identities must be 32 bytes":
    let p = b1().layout.get.child.payload
    check rejected(dList, p.withField(2, cbor(newSeq[byte](31)))) == heDigestLength
    check rejected(dList, p.withField(1, cbor(newSeq[byte](33)))) == heDigestLength
    var rec = p.lookup(5'u64).get.items[0]
    rec = rec.withField(2, cbor(newSeq[byte](16)))
    var items = p.lookup(5'u64).get.items
    items[0] = rec
    check rejected(dList, p.withField(5, cborArray(items))) == heDigestLength
    check toDigest(cbor(newSeq[byte](32))).isSome
    check toDigest(cbor(newSeq[byte](64))).isNone

suite "hash: App B boundary vectors":
  test "[HSH-0165] [HSH-0024] [HSH-0025] [HSH-0026] [HSH-0027] [HSH-0028] [HSH-0029] [HSH-0030] [HSH-0109] App B.1: 257 uint16 values make two packed chunks":
    let phys = layout(b1()).get
    let list = phys.child
    check list.kind == nkList
    check list.children.len == 2
    check list.children[0].node.kind == nkPackedChunk
    check list.children[0].node.digest.digestHex == pin("hsh-b1-first-chunk")
    check list.children[1].node.digest.digestHex == pin("hsh-b1-final-chunk")
    check list.digest.digestHex == pin("hsh-b1-list")
    check phys.digest.digestHex == pin("hsh-b1-value-root")

  test "[HSH-0010] [HSH-0011] [HSH-0012] a packed chunk keeps every element's identity and address":
    let list = layout(b1()).get.child
    for r in list.children:
      let p = r.node.payload
      check p.lookup(2'u64).get == cbor(listSchema)
      check p.lookup(3'u64).get == cbor(elementSchema)
      check p.lookup(4'u64).get == cbor("uint16")
      check r.label.lookup(1'u64).get == p.lookup(5'u64).get
      check r.label.lookup(2'u64).get == p.lookup(6'u64).get
    # Every list index is found from the labels alone, at its value.
    for i in 0'u64 .. 256'u64:
      var found = 0
      for r in list.children:
        let
          start = r.label.lookup(1'u64).get.uint
          count = r.label.lookup(2'u64).get.uint
        if i >= start and i < start + count:
          inc found
          check r.node.payload.lookup(7'u64).get.items[int(i - start)] == cbor(i)
      check found == 1

  test "[HSH-0165] [HSH-0116] [HSH-0115] [HSH-0117] App B.2: 4097 bytes make one aggregate over two chunks":
    let phys = layout(b2()).get
    let agg = phys.child
    check agg.kind == nkBstr
    check agg.children.mapIt(it.node.kind) == @[nkBstrChunk, nkBstrChunk]
    check agg.children[0].node.digest.digestHex == pin("hsh-b2-first-chunk")
    check agg.children[1].node.digest.digestHex == pin("hsh-b2-final-chunk")
    check agg.digest.digestHex == pin("hsh-b2-aggregate")
    check phys.digest.digestHex == pin("hsh-b2-value-root")

  test "[HSH-0165] [HSH-0100] [HSH-0122] [HSH-0123] App B.3: 257 records make two branches":
    var records: seq[Record]
    for i in 0'u64 .. 256'u64:
      var d: Digest
      d[28] = byte(i shr 24)
      d[29] = byte(i shr 16)
      d[30] = byte(i shr 8)
      d[31] = byte(i)
      records.add(
        Record(
          label: indexRangeLabel(i * 256, 256),
          node: PhysNode(kind: nkPackedChunk, schema: listSchema, digest: d),
        )
      )
    let top = branchUp(schemaRoot, nkList, listSchema, records)
    check top.len == 2
    check top[0].node.digest.digestHex == pin("hsh-b3-branch-0-255")
    check top[1].node.digest.digestHex == pin("hsh-b3-branch-256")
    check top[0].label == branchLabel(0, 256)
    check top[1].label == branchLabel(256, 1)
    check top.mapIt(it.node.payload.lookup(6'u64).get.items.len) == @[256, 1]

suite "hash: physical layout":
  test "[IMPL-DECISION G17] every oracle vector has the oracle's value root":
    check vectors.len > 50
    for i, v in vectors:
      checkpoint v.name
      check physical[i].digest.digestHex == v.digest
      check $physical[i].child.kind == v.childKind
      check physical[i].child.digest.digestHex == v.childDigest

  test "[HSH-0091] [HSH-0092] [HSH-0093] [HSH-0094] [HSH-0095] [HSH-0096] [HSH-0097] [HSH-0098] [HSH-0099] [HSH-0103] [HSH-0104] [HSH-0105] [HSH-0106] [HSH-0107] [HSH-0108] [HSH-0110] [HSH-0111] [HSH-0112] [HSH-0113] [HSH-0114] [HSH-0118] [HSH-0119] [HSH-0120] [HSH-0121] [HSH-0045] [HSH-0046] [HSH-0047] [HSH-0048] [HSH-0049] [HSH-0072] [HSH-0073] [HSH-0074] [HSH-0075] [HSH-0076] [HSH-0077] [HSH-0078] [HSH-0079] [HSH-0080] [HSH-0081] [HSH-0082] [HSH-0083] [HSH-0084] [HSH-0069] every payload has its domain's mirrored CDDL shape":
    var seen: set[NodeKind]
    for p in physical:
      check conforms(p.payload, payloadRuleOf[$dValueRoot])
      check conforms(hashInput(dValueRoot, p.payload), "hash-input")
    for n in allNodes():
      seen.incl(n.kind)
      let rule = payloadRuleOf[$domainOf(n.kind)]
      if not conforms(n.payload, rule):
        checkpoint toDiag(n.payload)[0 ..< 300]
        fail()
      check conforms(n.payload, "value-hash-payload")
    check seen == {low(NodeKind) .. high(NodeKind)}

  test "[HSH-0035] [HSH-0101] [HSH-0054] [HSH-0055] every record carries its child's kind, digest and payload schema":
    var checked = 0
    for p in physical:
      let rootRec = parseRootChildRecord(p.payload.lookup(3'u64).get).get
      check rootRec.kind == p.child.kind
      check rootRec.digest == p.child.digest
      check p.digest == digestOf(dValueRoot, p.payload)
    for n in allNodes():
      check n.digest == digestOf(domainOf(n.kind), n.payload)
      check n.payload.lookup(0'u64).get == cbor($n.kind)
      check toDigest(n.payload.lookup(2'u64).get).get == n.schema
      for r in n.children:
        let rec =
          if r.label.isNil:
            parseRootChildRecord(rootChildRecord(r.node)).get
          else:
            parseChildRecord(childRecord(r)).get
        check rec.kind == r.node.kind
        check rec.digest == r.node.digest
        check rec.schema == toDigest(r.node.payload.lookup(2'u64).get).get
        inc checked
    check checked > 100_000

  test "[HSH-0124] [HSH-0125] [HSH-0126] [HSH-0127] [HSH-0128] [HSH-0129] [HSH-0130] [HSH-0131] every payload the layout makes passes the verifier's checks":
    for p in physical:
      check checkValuePayload(dValueRoot, p.payload).isOk
    for n in allNodes():
      let r = checkValuePayload(domainOf(n.kind), n.payload)
      if r.isErr:
        checkpoint $r.error
      check r.isOk

  test "[HSH-0070] [HSH-0071] map records follow bytewise UTF-8 field-name order; lists and tuples keep position order":
    let m = byName("map field order is bytewise UTF-8").child
    check m.children.mapIt(it.label.lookup(1'u64).get.text) ==
      @["Z", "a-b", "a_b", "ab", "z", "é"]
    let t = byName("tuple equal positions stay distinct").child
    check t.children.mapIt(it.label) == @[tupleLabel(0), tupleLabel(1)]
    check t.children[0].node.digest != t.children[1].node.digest
    let l = byName("list of maps").child
    check l.children.mapIt(it.label) == @[indexLabel(0), indexLabel(1), indexLabel(2)]

  test "[HSH-0014] [HSH-0015] [HSH-0016] [HSH-0017] [HSH-0018] [HSH-0019] [HSH-0020] scalars are never packed across fields, tuple positions, choice arms, references or parents":
    for name in ["uint8-map 300", "uint8-map 65537", "uint8-tuple 257"]:
      let p = byName(name)
      check p.count(nkPackedChunk) == 0
    let notPackable = byName("list 257 uint8 not packable (reference element)")
    check notPackable.count(nkPackedChunk) == 0
    check notPackable.count(nkListChunk) == 2
    let nested = byName("list of lists")
    check nested.count(nkPackedChunk) == 0
    for n in nodes(byName("map present and absent fields").child):
      check n.kind != nkPackedChunk
    # A choice and a reference each wrap exactly one child record.
    check byName("choice arm 1 same value").child.children.len == 1
    check byName("reference value at the root [G2]").child.children.len == 1

  test "[HSH-0021] [HSH-0022] [HSH-0032] one layout per value: no adaptive layout or chunk size":
    for i in [0, 10, 40]:
      check layout(vectors[i].root).get.digest == physical[i].digest
    let big = byName("bstr 1048576").child
    check big.children.len == 256
    check big.children.allIt(it.node.payload.lookup(5'u64).get == cbor(4096'u64))
    check byName("bstr 1048577").child.children.mapIt(it.node.kind) ==
      @[nkBranch, nkBranch]
    check byName("tstr 4096 bytes is direct").child.kind == nkTstrDirect
    check byName("tstr 4097 bytes is chunked").child.kind == nkTstr
    check byName("bstr 4096 bytes is direct").child.kind == nkBstrDirect
    check byName("list 256 packable is direct").count(nkPackedChunk) == 0

  test "branches nest when one level leaves more than 256 records":
    let m = byName("uint8-map 65537").child
    check m.children.mapIt(it.label) == @[branchLabel(0, 65536), branchLabel(65536, 1)]
    check m.children[0].node.children.len == 256
    check m.children[0].node.children[255].label == branchLabel(65280, 256)
    check m.children[1].node.children.mapIt(it.label) == @[branchLabel(65536, 1)]
    check m.children[1].node.children[0].node.children[0].label == fieldLabel("f065536")

  test "[IMPL-DECISION G2] payloads below a reference value carry the referenced schema root":
    let outer = byName("reference value below a field [G2]")
    let reference = firstNode(outer, nkReference)
    check reference.payload.lookup(1'u64).get == cbor(schemaRoot)
    check reference.payload.lookup(3'u64).get == cbor(ident(0x20))
    let inner = reference.children[0].node
    check inner.kind == nkMap
    check inner.payload.lookup(1'u64).get == cbor(ident(0x20))
    for n in nodes(inner):
      check n.payload.lookup(1'u64).get == cbor(ident(0x20))
    check rootBelowReference(
      referenceNode(
        listSchema, ident(0x20), ident(0x21), scalarNode(ident(0x21), boolScalar(true))
      )
    ) == ident(0x20)

  test "[HSH-0031] text is checked as UTF-8, without U+0000, before it is chunked":
    proc textRoot(s: string): ValueRoot =
      ValueRoot(
        modelId: CommitmentModelId,
        schemaRoot: schemaRoot,
        subtreeRoot: bstrSchema,
        node: scalarNode(bstrSchema, textScalar(s)),
      )

    check layout(textRoot("ok" & "x".repeat(5000))).isOk
    check layout(textRoot("x".repeat(5000) & "\xff")).isErr
    check layout(textRoot("x".repeat(5000) & "\xed\xa0\x80")).isErr
    check layout(textRoot("a\0b")).isErr

  test "value trees that break COMMITMENT §9.3 are refused":
    proc rootOf(n: ValueNode): ValueRoot =
      ValueRoot(
        modelId: CommitmentModelId,
        schemaRoot: schemaRoot,
        subtreeRoot: listSchema,
        node: n,
      )

    let s = scalarNode(elementSchema, uintScalar(skUint8, 1))
    check layout(rootOf(scalarNode(elementSchema, uintScalar(skUint8, 256)))).isErr
    check layout(rootOf(scalarNode(elementSchema, intScalar(skInt16, -40000)))).isErr
    var m = mapNode(
      listSchema, [fieldNode(elementSchema, "b", s), fieldNode(elementSchema, "a", s)]
    )
    check layout(rootOf(m)).isOk
    m.fields = m.fields.reversed
    check layout(rootOf(m)).isErr
    m = mapNode(
      listSchema, [fieldNode(elementSchema, "a", s), fieldNode(elementSchema, "a", s)]
    )
    check layout(rootOf(m)).isErr
    var l = listNode(listSchema, elementSchema, [s, s])
    l.elements[1].elementIndex = 5
    check layout(rootOf(l)).isErr
    l = listNode(
      listSchema,
      elementSchema,
      [s, scalarNode(elementSchema, uintScalar(skUint16, 1))],
      Opt.some(skUint8),
    )
    check layout(rootOf(l)).isErr
    l = listNode(listSchema, elementSchema, [s], Opt.some(skTstr))
    check layout(rootOf(l)).isErr
    check layout(rootOf(fieldNode(listSchema, "x", s))).isErr
    var r = rootOf(s)
    r.modelId = "logos.commitment-model.2099-01"
    check layout(r).isErr

suite "hash: verifier rejections":
  test "[HSH-0036] unknown or misplaced node kinds are rejected":
    let list = layout(b1()).get.child.payload
    var items = list.lookup(5'u64).get.items
    items[0] = items[0].withField(1, cbor("list-element"))
    check rejected(dList, list.withField(5, cborArray(items))) == heNodeKind
    items[0] = items[0].withField(1, cbor("list-chunk"))
    # A chunked list cannot mix chunk kinds.
    check rejected(dList, list.withField(5, cborArray(items))) == heLayout
    items[0] = items[0].withField(1, cbor("map"))
    check rejected(dList, list.withField(5, cborArray(items))) == heNodeKind
    let field = firstNode(byName("map present and absent fields"), nkField).payload
    let rec = field.lookup(4'u64).get.withField(0, cbor("branch"))
    check rejected(dField, field.withField(4, rec)) == heNodeKind

  test "[HSH-0125] [HSH-0126] [HSH-0127] counts, ranges and coverage must agree":
    let list = layout(b1()).get.child.payload
    check rejected(dList, list.withField(4, cbor(258'u64))) == heLayout
    check rejected(dList, list.withField(4, cbor(256'u64))) == heLayout
    let items = list.lookup(5'u64).get.items
    check rejected(dList, list.withField(5, cborArray(items[1], items[0]))) == heLayout
    check rejected(dList, list.withField(5, cborArray(items[0]))) == heLayout
    check rejected(dList, list.withField(5, cborArray(items & items[1]))) == heLayout
    let m = byName("map present and absent fields").child.payload
    check rejected(dMap, m.withField(3, cbor(2'u64))) == heLayout
    let recs = m.lookup(4'u64).get.items
    check rejected(dMap, m.withField(4, cborArray(recs[1], recs[0], recs[2]))) ==
      heLayout
    check rejected(dMap, m.withField(4, cborArray(recs[0], recs[0], recs[2]))) ==
      heLayout
    let t = byName("tuple equal positions stay distinct").child.payload
    let pos = t.lookup(4'u64).get.items
    check rejected(dTuple, t.withField(4, cborArray(pos[1], pos[0]))) == heLayout
    let c = byName("choice arm 1 same value").child.payload
    check rejected(dChoice, c.withField(3, cbor(0'u64))) == heLayout
    let lc = firstNode(byName("list 512 tstr is two full chunks"), nkListChunk).payload
    check checkValuePayload(dListChunk, lc).isOk
    check rejected(dListChunk, lc.withField(4, cbor(1'u64))) == heLayout
    check rejected(dListChunk, lc.withField(5, cbor(255'u64))) == heLayout

  test "[HSH-0124] a branch holds 1 to 256 records over a canonical range":
    let m = byName("map 257 fields is branched").child
    let b = m.children[0].node.payload
    check checkValuePayload(dBranch, b).isOk
    check checkValuePayload(dMap, m.payload).isOk
    let recs = b.lookup(6'u64).get.items
    check rejected(dBranch, b.withField(6, cborArray())) == heLayout
    check rejected(dBranch, b.withField(6, cborArray(recs & recs[0]))) == heLayout
    check rejected(dBranch, b.withField(5, cbor(255'u64))) == heLayout
    check rejected(dBranch, b.withField(4, cbor(1'u64))) == heLayout
    check rejected(dBranch, b.withField(3, cbor("choice"))) == heShape
    let top = m.payload.lookup(4'u64).get.items
    check rejected(dMap, m.payload.withField(4, cborArray(top[0]))) == heLayout
    let deep = byName("uint8-map 65537").child
    let level2 = deep.children[0].node.payload
    check checkValuePayload(dBranch, level2).isOk
    let kids = level2.lookup(6'u64).get.items
    check rejected(dBranch, level2.withField(6, cborArray(kids[0 ..< 255]))) == heLayout

  test "[HSH-0128] a packed chunk holds 1 to 256 values of a packable kind":
    let chunk = layout(b1()).get.child.children[1].node.payload
    check checkValuePayload(dPackedChunk, chunk).isOk
    check rejected(dPackedChunk, chunk.withField(6, cbor(2'u64))) == heLayout
    check rejected(dPackedChunk, chunk.withField(7, cborArray())) == heLayout
    check rejected(dPackedChunk, chunk.withField(4, cbor("tstr"))) == heShape
    check rejected(dPackedChunk, chunk.withField(7, cborArray(cbor(70000'u64)))) ==
      heShape
    check rejected(dPackedChunk, chunk.withField(7, cborArray(cbor(-1)))) == heShape
    check rejected(dPackedChunk, chunk.withField(5, cbor(100'u64))) == heLayout

  test "[HSH-0129] [HSH-0130] [HSH-0131] string payloads keep their 4096-byte rules":
    let direct = byName("bstr 4096 bytes is direct").child.payload
    check checkValuePayload(dBstrDirect, direct).isOk
    check rejected(dBstrDirect, direct.withField(3, cbor(4095'u64))) == heLayout
    check rejected(
      dBstrDirect,
      direct.withField(3, cbor(4097'u64)).withField(4, cbor(newSeq[byte](4097))),
    ) == heLayout
    let text = byName("tstr non-ASCII").child.payload
    check checkValuePayload(dTstrDirect, text).isOk
    check rejected(dTstrDirect, text.withField(3, cbor(4'u64))) == heLayout
    let agg = byName("bstr 8193 bytes is three chunks").child
    check checkValuePayload(dBstr, agg.payload).isOk
    check rejected(dBstr, agg.payload.withField(3, cbor(4096'u64))) == heLayout
    check rejected(dBstr, agg.payload.withField(3, cbor(8194'u64))) == heLayout
    let recs = agg.payload.lookup(4'u64).get.items
    check rejected(dBstr, agg.payload.withField(4, cborArray(recs[0], recs[1]))) ==
      heLayout
    let chunk = agg.children[2].node.payload
    check checkValuePayload(dBstrChunk, chunk).isOk
    check rejected(dBstrChunk, chunk.withField(4, cbor(8191'u64))) == heLayout
    check rejected(dBstrChunk, chunk.withField(6, cbor(newSeq[byte](2)))) == heLayout
    let tchunk =
      firstNode(byName("tstr chunk boundary inside a UTF-8 sequence"), nkTstrChunk)
    check checkValuePayload(dTstrChunk, tchunk.payload).isOk
