## Value trees and verified views: COMMITMENT §7, §8, §9.3, §9.4, §10 and App B
## (a value decoded under a schema), HASH §7.6, §8, §9 and App B.1/B.2 (views over
## its value root).

import std/[sequtils, sets, strformat, strutils, tables]
import unittest2
import ../src/logos_core/[cbor, hash, commitment]
import ../src/logos_core/base/hex
import ./support/[cddlshape, specdata, valuevec]

# Schemas and values ------------------------------------------------------------------

proc module(body: string): string =
  "_module = \"demo_module\"\n" & body

proc build(source: string, ctx = pinnedContext()): SchemaModel =
  let m = buildSchema(source, ctx)
  doAssert m.isOk, "schema rejected: " & m.error
  m.get

proc diag(s: string): CborValue =
  let v = parseDiag(s)
  doAssert v.isOk, "diagnostic notation: " & v.error
  v.get

let
  appB = build(mirror("CMT/app-b.input.cddl"))
  supporting = build(mirror("IFC/3.9.2.supporting.cddl"))
  iface = build(mirror("IFC/3.9.2.interface.cddl"))
  common = pinnedContext().commonModel

proc sensorContext(): SchemaContext =
  var ctx = pinnedContext()
  ctx.supporting = @[supporting]
  ctx.interfaces = @[iface]
  ctx

let sensor = build(mirror("IFC/3.9.2.module.cddl"), sensorContext())

proc setOf(m: SchemaModel, ctx = pinnedContext()): SchemaSet =
  schemaSetFor(m, ctx)

proc norm(
    m: SchemaModel, decl: string, v: CborValue, ctx = pinnedContext()
): Result[ValueRoot, string] =
  setOf(m, ctx).normalize(0, decl, v)

proc typed(m: SchemaModel, decl, data: string, ctx = pinnedContext()): ValueRoot =
  ## The value tree of `data` (diagnostic notation) under `decl`.
  let r = m.norm(decl, diag(data), ctx)
  doAssert r.isOk, decl & " rejected " & data & ": " & r.error
  r.get

proc rejects(m: SchemaModel, decl: string, v: CborValue, ctx = pinnedContext()): bool =
  let r = m.norm(decl, v, ctx)
  if r.isOk:
    checkpoint decl & " accepted " & toDiag(v)
  r.isErr

proc rejectsBytes(m: SchemaModel, decl, data: string): bool =
  setOf(m).normalizeBytes(0, decl, hexBytes(data)).isErr

proc fieldSeg(name: string): PathSegment =
  PathSegment(kind: psField, field: name)

proc elemSeg(): PathSegment =
  PathSegment(kind: psListElement)

proc posSeg(i: int): PathSegment =
  PathSegment(kind: psTuplePosition, index: uint64(i))

proc armSeg(i: int): PathSegment =
  PathSegment(kind: psChoiceArm, index: uint64(i))

proc idAt(m: SchemaModel, decl: string, path: openArray[PathSegment]): Digest =
  nodeIdentity(m, m.find(decl).get, path).get

proc rootOf(m: SchemaModel, decl: string): Digest =
  declarationRoot(m, m.find(decl).get)

proc bytesLiteral(d: Digest): string =
  "h'" & toHex(d) & "'"

proc vroot(r: ValueRoot): Digest =
  valueRoot(r).get

proc member(n: ValueNode, name: string): ValueNode =
  for f in n.fields:
    if f.fieldName == name:
      return f
  raiseAssert "no field " & name

proc nodes(n: ValueNode): seq[ValueNode] =
  ## `n` and every node below it.
  var acc = @[n]
  case n.kind
  of vkMap:
    for f in n.fields:
      acc.add(nodes(f))
  of vkField:
    acc.add(nodes(n.fieldValue))
  of vkList:
    for e in n.elements:
      acc.add(nodes(e))
  of vkListElement:
    acc.add(nodes(n.elementValue))
  of vkTuple:
    for e in n.positions:
      acc.add(nodes(e))
  of vkTupleElement:
    acc.add(nodes(n.positionValue))
  of vkChoice:
    acc.add(nodes(n.armValue))
  of vkReference:
    acc.add(nodes(n.referencedValue))
  of vkAbsent, vkScalar:
    discard
  acc

proc findKind(n: PhysNode, k: NodeKind): PhysNode =
  ## The first physical node of kind `k`, depth first.
  if n.kind == k:
    return n
  for r in n.children:
    let x = findKind(r.node, k)
    if not x.isNil:
      return x
  nil

# The mirrored CDDL of COMMITMENT §9.3-§9.4 and HASH §7.3-§7.6 as a shape checker.
let shapes = block:
  var sh = loadShapes(
    [
      "HSH/5.node-kind.cddl", "HSH/6.hash-input.cddl", "HSH/7.domain-tag.cddl",
      "HSH/7.1.hash-input.cddl", "HSH/7.3.child-records.cddl",
      "HSH/7.4.value-payloads.cddl", "HSH/7.5.domain-payloads.cddl",
      "HSH/7.6.verified-view.cddl", "CMT/9.revision.cddl", "CMT/9.3.value-objects.cddl",
      "CMT/9.4.semantic-path.cddl",
    ]
  )
  for r in [
    "schema-hash-payload", "schema-root-payload", "schema-node-payload",
    "schema-structural-node-payload", "schema-leaf-payload", "schema-reference-payload",
  ]:
    sh.opaque.incl(r)
  sh

const valueRules = [
  vkMap: "map-value",
  vkField: "field-value",
  vkAbsent: "absent-value",
  vkList: "list-value",
  vkListElement: "list-element-value",
  vkTuple: "tuple-value",
  vkTupleElement: "tuple-element-value",
  vkChoice: "choice-value",
  vkScalar: "scalar-value",
  vkReference: "reference-value",
]

const allKinds = module(
  """
demo.all = {
  m: {x: uint8},
  ? gone: tstr,
  l: [* int16],
  t: [uint8, tstr],
  c: uint32 / tstr,
  r: logos.error_code,
  b: bstr,
}
"""
)

const allKindsValue =
  """{"m": {"x": 1}, "l": [-1, 2], "t": [3, "t"], "c": "z", "r": 2, "b": h'0102'}"""

# Views -------------------------------------------------------------------------------

let noPath = newSeq[Segment]()

proc viewSchema(m: SchemaModel, ctx = pinnedContext()): Opt[ViewSchema] =
  Opt.some(ViewSchema(set: setOf(m, ctx), doc: 0))

proc viewAt(r: ValueRoot, path: openArray[Segment]): VerifiedView =
  let v = viewOf(r, path)
  doAssert v.isOk, "no view: " & v.error
  v.get

proc wire(v: VerifiedView): CborValue =
  ## The view as a verifier receives it.
  decodeCbor(encodeCbor(toCbor(v))).get

proc verdict(w: CborValue, schema = Opt.none(ViewSchema)): Result[void, ViewError] =
  let v = parseView(w)
  if v.isErr:
    return err(v.error)
  verifyView(v.get, schema)

proc accepted(w: CborValue, schema = Opt.none(ViewSchema)): bool =
  let r = verdict(w, schema)
  if r.isErr:
    checkpoint $r.error
  r.isOk

proc failure(w: CborValue, schema = Opt.none(ViewSchema)): Opt[ViewErrorKind] =
  let r = verdict(w, schema)
  if r.isOk:
    return Opt.none(ViewErrorKind)
  Opt.some(r.error.kind)

proc domains(v: VerifiedView): seq[Domain] =
  v.proof.mapIt(it.domain)

proc stepHashes(v: VerifiedView): seq[string] =
  v.proof.mapIt(toHex(digestOf(it.domain, it.payload)))

proc clone(v: CborValue): CborValue =
  decodeCbor(encodeCbor(v)).get

proc dig(v: CborValue, at: openArray[int]): CborValue =
  ## The item at `at`: map keys and array indexes in turn.
  var p = v
  for k in at:
    p = (if p.kind == ckMap: p.lookup(uint64(k)).get else: p.items[k])
  p

proc put(v: CborValue, at: openArray[int], x: CborValue): CborValue =
  ## A copy of `v` with the item at `at` replaced by `x`.
  let c = clone(v)
  let parent = c.dig(at.toOpenArray(0, at.high - 1))
  if parent.kind == ckMap:
    for i in 0 ..< parent.entries.len:
      if parent.entries[i].key == cbor(uint64(at[^1])):
        parent.entries[i] = (parent.entries[i].key, x)
  else:
    parent.items[at[^1]] = x
  c

proc steps(w: CborValue): seq[CborValue] =
  w.dig([9]).items

proc withSteps(w: CborValue, s: seq[CborValue]): CborValue =
  w.put([9], cborArray(s))

proc otherKind(kind: string): string =
  if kind == "map": "list" else: "map"

proc mutations(w: CborValue): seq[(string, CborValue)] =
  ## [SPEC HASH §9] The mutation classes a verifier must reject, applied to every
  ## envelope field, every proof step and every record a step carries.
  var cases: seq[(string, CborValue)]
  let s = w.steps
  cases.add(("value root", w.put([3], cbor(ident(0x55)))))
  cases.add(("schema root", w.put([1], cbor(ident(0x56)))))
  cases.add(("schema subtree root", w.put([2], cbor(ident(0x57)))))
  cases.add(("hash profile", w.put([4], cbor("logos.hash-profile.2026-09"))))
  cases.add(("hash suite", w.put([5], cbor("logos.hash-suite.sha-256"))))
  cases.add(("commitment model", w.put([6], cbor("logos.commitment-model.2027-01"))))
  if s.len > 1:
    cases.add(("step order", w.withSteps(@[s[1], s[0]] & s[2 ..^ 1])))
    cases.add(("missing step", w.withSteps(s[1 ..^ 1])))
    cases.add(("extra step below", w.withSteps(@[s[0]] & s)))
    cases.add(("extra step above", w.withSteps(s & @[s[^1]])))
  for i, step in s:
    let domain = step.dig([0]).text
    cases.add(
      (
        &"step {i} domain tag",
        w.put(
          [9, i, 0],
          cbor(
            if domain == $dMap:
              $dList
            else:
              $dMap
          ),
        ),
      )
    )
    let payload = step.dig([1])
    cases.add(
      (
        &"step {i} discriminator",
        w.put([9, i, 1, 0], cbor(otherKind(payload.dig([0]).text))),
      )
    )
    cases.add((&"step {i} payload schema root", w.put([9, i, 1, 1], cbor(ident(0x58)))))
    cases.add(
      (&"step {i} payload schema identity", w.put([9, i, 1, 2], cbor(ident(0x59))))
    )
    for (key, x) in payload.entries:
      let k = int(key.uint)
      if k < 3:
        continue
      cases.add((&"step {i} field {k}", w.put([9, i, 1, k], cbor("x"))))
      if x.kind == ckArray and x.items.len > 0 and x.items[0].kind == ckMap and
          x.items[0].entries.len == 4:
        # child records: label, node kind, digest, schema identity
        for j in 0 ..< x.items.len:
          let at = @[9, i, 1, k, j]
          let kind = x.items[j].dig([1]).text
          cases.add(
            (
              &"step {i} record {j} label",
              w.put(at & 0, diag("""{0: "index", 1: 9999}""")),
            )
          )
          cases.add((&"step {i} record {j} kind", w.put(at & 1, cbor(otherKind(kind)))))
          cases.add(
            (&"step {i} record {j} placeholder digest", w.put(at & 2, cbor(ident(0))))
          )
          cases.add(
            (&"step {i} record {j} short digest", w.put(at & 2, cbor(newSeq[byte](31))))
          )
          cases.add((&"step {i} record {j} schema", w.put(at & 3, cbor(ident(0x5a)))))
        let records = x.items
        cases.add(
          (&"step {i} omitted record", w.put([9, i, 1, k], cborArray(records[1 ..^ 1])))
        )
        cases.add(
          (
            &"step {i} duplicate record",
            w.put([9, i, 1, k], cborArray(records & records[0])),
          )
        )
      elif x.kind == ckMap and x.entries.len in {3, 4} and x.dig([0]).kind == ckText:
        # a root-child record: node kind, digest, schema identity
        cases.add(
          (
            &"step {i} child kind",
            w.put([9, i, 1, k, 0], cbor(otherKind(x.dig([0]).text))),
          )
        )
        cases.add((&"step {i} child digest", w.put([9, i, 1, k, 1], cbor(ident(0)))))
        cases.add((&"step {i} child schema", w.put([9, i, 1, k, 2], cbor(ident(0x5b)))))
  cases

proc acceptedMutations(
    w: CborValue, cases: seq[(string, CborValue)], schema = Opt.none(ViewSchema)
): seq[string] =
  ## The names of the mutations the verifier accepted (none, for a correct one).
  var bad: seq[string]
  for (name, m) in cases:
    if verdict(m, schema).isOk:
      bad.add(name)
  bad

proc occurrences(h, n: openArray[byte]): seq[int] =
  var at: seq[int]
  for i in 0 .. h.len - n.len:
    if h[i ..< i + n.len] == @n:
      at.add(i)
  at

# COMMITMENT App B ---------------------------------------------------------------------

suite "commitment: App B":
  test "[CMT-0192] [CMT-0193] [CMT-0194] [CMT-0195] [CMT-0196] [CMT-0174] App B: the input module builds to the mirrored schema object":
    check toCbor(appB) == diag(mirror("CMT/app-b.schema.diag"))

  test "[CMT-0197] App B: the ok field's schema-node path, and its node is a schema leaf":
    let d = appB.find("demo.ping_response").get
    check toCbor(@[fieldSeg("ok")]) == diag(mirror("CMT/app-b.ok-schema-path.diag"))
    check nodeAt(d, [fieldSeg("ok")]).get.isLeaf
    check appB.idAt("demo.ping_response", [fieldSeg("ok")]) ==
      leafHash(appB, d, [fieldSeg("ok")]).get

  test "[CMT-0192] [CMT-0198] [CMT-0199] [CMT-0176] [CMT-0078] [CMT-0079] [CMT-0080] [CMT-0081] [CMT-0082] App B: the value decodes under demo.ping_response to the mirrored value tree":
    let r = appB.typed("demo.ping_response", mirror("CMT/app-b.value.diag"))
    let want = mirror("CMT/app-b.value-tree.diag").multiReplace(
        ("h'...schema-root...'", bytesLiteral(schemaRoot(appB))),
        (
          "h'...demo.ping_response-subtree-root...'",
          bytesLiteral(appB.rootOf("demo.ping_response")),
        ),
        (
          "h'...ok-field-schema-identity...'",
          bytesLiteral(appB.idAt("demo.ping_response", [fieldSeg("ok")])),
        ),
      )
    check "..." notin want
    check toCbor(r) == diag(want)
    check r.modelId == CommitmentModelId
    check plainValue(r.node) == diag(mirror("CMT/app-b.value.diag"))
    check shapes.conforms(toCbor(r), "normalized-value-root")

  test "[CMT-0200] [CMT-0201] [CMT-0192] App B: the semantic paths of the whole value and of the ok field":
    check toCbor(noPath) == diag(mirror("CMT/app-b.root-path.diag"))
    check toCbor([fieldSegment("ok")]) == diag(mirror("CMT/app-b.ok-path.diag"))
    let r = appB.typed("demo.ping_response", mirror("CMT/app-b.value.diag"))
    let whole = viewAt(r, noPath)
    check whole.disclosed.value == toCbor(r)
    let ok = viewAt(r, [fieldSegment("ok")])
    check ok.disclosed.value == toCbor(member(r.node, "ok").fieldValue)
    check accepted(wire(whole), viewSchema(appB))
    check accepted(wire(ok), viewSchema(appB))

  test "[CMT-0224] [CMT-0225] [CMT-0226] [CMT-0234] [CMT-0235] [CMT-0236] [CMT-0237] [CMT-0238] [CMT-0239] App B.1: through a local reference chain the root keeps the referring identity and the value takes the terminal one":
    let m = build(mirror("CMT/app-b1.input.cddl"))
    check m.role == srSupporting
    let r = m.typed("a.x", "\"hello\"")
    let want = mirror("CMT/app-b1.value-tree.diag").multiReplace(
        ("h'...schema-root...'", bytesLiteral(schemaRoot(m))),
        ("h'...a.x-subtree-root...'", bytesLiteral(m.rootOf("a.x"))),
        ("h'...a.z-subtree-root...'", bytesLiteral(m.rootOf("a.z"))),
      )
    check "..." notin want
    check toCbor(r) == diag(want)
    # The model keeps all three declarations and both local-reference nodes.
    check m.declarations.len == 3
    check m.find("a.x").get.body.kind == snLocalRef
    check m.find("a.y").get.body.kind == snLocalRef

# COMMITMENT §7-§10 --------------------------------------------------------------------

suite "commitment: value trees":
  test "[CMT-0070] [CMT-0071] [CMT-0078] [CMT-0079] [CMT-0080] [CMT-0081] [CMT-0082] [CMT-0083] the same data under another declaration or schema root is another value commitment":
    let m1 = build(module("demo.a = {x: uint8}\ndemo.b = {x: uint8}"))
    let m2 = build(module("demo.a = {x: uint8}\ndemo.c = bool"))
    let data = """{"x": 7}"""
    let (a1, b1, a2) =
      (m1.typed("demo.a", data), m1.typed("demo.b", data), m2.typed("demo.a", data))
    check a1.modelId == CommitmentModelId
    check a1.schemaRoot == schemaRoot(m1)
    check a2.schemaRoot == schemaRoot(m2)
    check a1.subtreeRoot == m1.rootOf("demo.a")
    check b1.subtreeRoot == m1.rootOf("demo.b")
    # demo.a has the same text in both documents: only the schema root differs.
    check a1.subtreeRoot == a2.subtreeRoot
    check plainValue(a1.node) == plainValue(b1.node)
    check plainValue(a1.node) == plainValue(a2.node)
    check @[vroot(a1), vroot(b1), vroot(a2)].deduplicate.len == 3
    # The binding is kept inside the tree too: each node carries its own identity.
    check a1.node.schema == m1.rootOf("demo.a")
    check b1.node.schema == m1.rootOf("demo.b")
    check member(a1.node, "x").schema == m1.idAt("demo.a", [fieldSeg("x")])
    check member(b1.node, "x").schema == m1.idAt("demo.b", [fieldSeg("x")])
    check member(a1.node, "x").schema != member(b1.node, "x").schema
    # A method declaration has no values.
    check appB.rejects("demo.ping", diag("{}"))

  test "[CMT-0072] [CMT-0084] [CMT-0073] [CMT-0085] required fields must be present and unknown fields are rejected":
    let m = build(module("demo.t = {x: uint8, ? y: tstr}"))
    check m.rejects("demo.t", diag("{}"))
    check m.rejects("demo.t", diag("""{"y": "a"}"""))
    check m.rejects("demo.t", diag("""{"x": 1, "z": 2}"""))
    check m.rejects("demo.t", diag("""{"x": 1, "y": "a", "z": 2}"""))
    check m.rejects("demo.t", diag("""{"x": 1, 1: 2}"""))
    check m.typed("demo.t", """{"x": 1}""").node.fields.len == 2
    check m.typed("demo.t", """{"x": 1, "y": "a"}""").node.fields.len == 2

  test "[SPEC COMMITMENT §7] values must have their schema types; floats, tags and non-deterministic encodings never reach the value model":
    let m = build(module("demo.t = {b: bool, i: int8, s: tstr, x: uint8}"))
    check m.typed("demo.t", """{"b": true, "i": -128, "s": "a", "x": 255}""").node.fields.len ==
      4
    for bad in [
      """{"b": true, "i": -129, "s": "a", "x": 1}""",
      """{"b": true, "i": 128, "s": "a", "x": 1}""",
      """{"b": true, "i": 0, "s": "a", "x": 256}""",
      """{"b": true, "i": 0, "s": "a", "x": -1}""",
      """{"b": true, "i": 0, "s": "a", "x": "1"}""",
      """{"b": 1, "i": 0, "s": "a", "x": 1}""",
      """{"b": true, "i": 0, "s": h'61', "x": 1}""",
      """{"b": true, "i": 0, "s": "a", "x": [1]}""",
      """{"b": null, "i": 0, "s": "a", "x": 1}""",
    ]:
      check m.rejects("demo.t", diag(bad))
    # {"b": true, "i": -1, "s": "a", "x": 1} and variants of "x" as bytes.
    let head = "a4 6162 f5 6169 20 6173 6161 6178 "
    check not m.rejectsBytes("demo.t", head & "01")
    check m.rejectsBytes("demo.t", head & "f93c00") # 1.0 as a float
    check m.rejectsBytes("demo.t", head & "c24101") # tag 2 (bignum 1)
    check m.rejectsBytes("demo.t", head & "1801") # 1 not in shortest form
    check m.rejectsBytes("demo.t", "bf 6162 f5 6169 20 6173 6161 6178 01 ff")
      # indefinite
    check m.rejectsBytes("demo.t", "a4 6162 f5 6169 20 6178 01 6173 6161") # key order

  test "[CMT-0086] [CMT-0223] an absent optional field is an explicit absent node, never omitted or defaulted":
    let m = build(module("demo.t = {? note: tstr, n: uint8}"))
    let r = m.typed("demo.t", """{"n": 1}""")
    check r.node.fields.mapIt(it.fieldName) == @["n", "note"]
    let note = member(r.node, "note")
    check note.schema == m.idAt("demo.t", [fieldSeg("note")])
    check note.fieldValue.kind == vkAbsent
    check note.fieldValue.schema == note.schema
    check toCbor(note.fieldValue) ==
      diag("""{0: "absent", 1: """ & bytesLiteral(note.schema) & "}")
    let present = m.typed("demo.t", """{"n": 1, "note": ""}""")
    check member(present.node, "note").fieldValue.kind == vkScalar
    check vroot(r) != vroot(present)
    check plainValue(r.node) == diag("""{"n": 1}""")

  test "[CMT-0075] [CMT-0087] a choice value keeps its selected arm index and arm schema identity":
    let m = build(module("demo.t = {v: uint32 / tstr}"))
    let arms = m.find("demo.t").get.body.fields[0].node.arms
    var textArm = -1
    for i, a in arms:
      if a.kind == snPrimitive and a.scalar == skTstr:
        textArm = i
    check textArm in 0 .. 1
    for (data, arm) in [("""{"v": "a"}""", textArm), ("""{"v": 5}""", 1 - textArm)]:
      checkpoint data
      let c = member(m.typed("demo.t", data).node, "v").fieldValue
      check c.kind == vkChoice
      check c.schema == m.idAt("demo.t", [fieldSeg("v")])
      check c.armIndex == uint64(arm)
      check c.armSchema == m.idAt("demo.t", [fieldSeg("v"), armSeg(arm)])
      check c.armValue.kind == vkScalar
      check c.armValue.schema == c.armSchema
      check toCbor(c).dig([2]) == cbor(uint64(arm))
      check toCbor(c).dig([3]) == cbor(c.armSchema)

  test "[CMT-0076] [CMT-0161] text values are valid UTF-8 without U+0000":
    let m = build(module("demo.t = {s: tstr}"))
    check member(m.norm("demo.t", cborMap((cbor("s"), cbor("é")))).get.node, "s").fieldValue.scalar.text ==
      "é"
    check m.rejects("demo.t", cborMap((cbor("s"), cbor("a\0b"))))
    check m.rejects(
      "demo.t",
      cborMap((cbor("s"), CborValue(kind: ckText, text: "a\xff", validUtf8: false))),
    )
    check m.rejectsBytes("demo.t", "a1 6173 62 61ff")
    check parseValueNode(toCbor(scalarNode(ident(1), textScalar("a\0b")))).isErr
    check parseValueNode(
      diag(
        """{0: "scalar", 1: """ & bytesLiteral(ident(1)) & """, 2: "tstr", 3: "a"}"""
      )
        .put([3], CborValue(kind: ckText, text: "\xff", validUtf8: false))
    ).isErr

  test "[IMPL-DECISION G1] a local reference adds no node; the value carries the innermost declaration's identity":
    let m = build(
      module(
        """
demo.inner = {x: uint8}
demo.alias = demo.inner
demo.outer = {a: demo.alias, b: [* demo.alias]}
"""
      )
    )
    let r = m.typed("demo.outer", """{"a": {"x": 1}, "b": [{"x": 2}]}""")
    let a = member(r.node, "a")
    check a.schema == m.idAt("demo.outer", [fieldSeg("a")]) # the referring location
    check a.fieldValue.kind == vkMap # no reference-value node
    check a.fieldValue.schema == m.rootOf("demo.inner")
    check a.fieldValue.schema != m.rootOf("demo.alias")
    check member(a.fieldValue, "x").schema == m.idAt("demo.inner", [fieldSeg("x")])
    let b = member(r.node, "b").fieldValue
    check b.elementSchema == m.idAt("demo.outer", [fieldSeg("b"), elemSeg()])
    check b.elements[0].elementValue.schema == m.rootOf("demo.inner")
    # Decoded under the alias: the root binds the alias, the value the innermost type.
    let viaAlias = m.typed("demo.alias", """{"x": 1}""")
    check viaAlias.subtreeRoot == m.rootOf("demo.alias")
    check viaAlias.node.schema == m.rootOf("demo.inner")

  test "[CMT-0156] [IMPL-DECISION G2] an imported reference is a reference-value node; payloads below it use the referenced schema root":
    let ctx = sensorContext()
    let r = sensor.typed(
      "sensor.control.configure_request",
      """{"settings": {"kind": "sensor", "limit": 7}}""", ctx,
    )
    let settings = member(r.node, "settings").fieldValue
    check settings.schema == sensor.rootOf("sensor.control.settings")
    let limit = member(settings, "limit")
    check limit.schema == sensor.idAt("sensor.control.settings", [fieldSeg("limit")])
    let rv = limit.fieldValue
    check rv.kind == vkReference
    check rv.schema == limit.schema
    check rv.referencedRoot == schemaRoot(supporting)
    check rv.referencedSubtree == supporting.rootOf("metrics_types.counter")
    # [IMPL-DECISION G152] a leaf-bodied declaration's value takes its subtree root.
    check rv.referencedValue.schema == supporting.rootOf("metrics_types.counter")
    check rv.referencedValue.scalar.kind == skUint64
    check rv.referencedValue.scalar.unsigned == 7
    let phys = layout(r).get
    let reference = findKind(phys.child, nkReference)
    check reference.payload.dig([1]) == cbor(schemaRoot(sensor))
    check reference.children[0].node.payload.dig([1]) == cbor(schemaRoot(supporting))
    check accepted(
      wire(viewAt(r, [fieldSegment("settings"), fieldSegment("limit")])),
      viewSchema(sensor, ctx),
    )

  test "[CMT-0156] imported common types: reference nodes carry the pinned common roots, and local references inside the common schema follow G1":
    let m =
      build(module("demo.t = {d: logos.invalid_params_detail, c: logos.error_code}"))
    let r = m.typed(
      "demo.t", """{"c": 3, "d": {"reason": "schema-mismatch", "path": ["a", 3]}}"""
    )
    let d = member(r.node, "d").fieldValue
    check d.kind == vkReference
    check d.referencedRoot == pinnedContext().commonRoot
    check toHex(d.referencedSubtree) == pin("common-subtree-invalid-params-detail")
    let detail = d.referencedValue
    check detail.schema == common.rootOf("logos.invalid_params_detail")
    let reason = member(detail, "reason").fieldValue
    check reason.kind == vkChoice
    check reason.schema == common.rootOf("logos.invalid_params_reason")
    check reason.armValue.scalar.text == "schema-mismatch"
    let path = member(detail, "path").fieldValue
    check path.packKind.isNone
    let segment = path.elements[1].elementValue
    check segment.kind == vkChoice
    check segment.schema == common.rootOf("logos.invalid_params_path_segment")
    check segment.armValue.scalar.unsigned == 3
    let c = member(r.node, "c").fieldValue
    check c.kind == vkReference
    check toHex(c.referencedSubtree) == pin("common-subtree-error-code")
    check c.referencedValue.kind == vkChoice
    check c.referencedValue.schema == common.rootOf("logos.error_code")

  test "[SPEC COMMITMENT §8] [IMPL-DECISION G152] a supporting-schema declaration's value takes the supporting root and the declaration's subtree root":
    let c = supporting.typed("metrics_types.counter", "5")
    check c.schemaRoot == schemaRoot(supporting)
    check c.subtreeRoot == supporting.rootOf("metrics_types.counter")
    check c.node.schema == c.subtreeRoot

  test "[CMT-0178] [CMT-0179] an implemented interface method's values bind the interface schema root, which the module commits to implementing":
    let r = iface.typed("metrics_provider.snapshot_response", """{"count": 3}""")
    check r.schemaRoot == schemaRoot(iface)
    check r.schemaRoot != schemaRoot(sensor)
    check r.subtreeRoot == iface.rootOf("metrics_provider.snapshot_response")
    check sensor.implemented == @[schemaRoot(iface)]
    let w = wire(viewAt(r, [fieldSegment("count")]))
    check accepted(w, viewSchema(iface))
    check failure(w, viewSchema(sensor, sensorContext())) == Opt.some(veSchema)

  test "[IMPL-DECISION G119] [IMPL-DECISION CM-07] lists of a packable primitive or literal pack; references and text never do (DECISIONS I15)":
    let m = build(
      module(
        """
demo.n = uint16
demo.t = {
  p: [* uint16],
  five: [* 5],
  yes: [* true],
  via_ref: [* demo.n],
  text: [* tstr],
}
"""
      )
    )
    let many = cborArray(toSeq(0'u64 ..< 300'u64).mapIt(cbor(it)))
    let r = m.norm(
      "demo.t",
      cborMap(
        (cbor("p"), many),
        (cbor("five"), cborArray(toSeq(0 ..< 300).mapIt(cbor(5'u64)))),
        (cbor("yes"), diag("[true, true]")),
        (cbor("via_ref"), many),
        (cbor("text"), diag("""["a"]""")),
      ),
    ).get
    check member(r.node, "p").fieldValue.packKind == Opt.some(skUint16)
    let five = member(r.node, "five").fieldValue
    check five.packKind.isSome
    check five.packKind.get == five.elements[0].elementValue.scalar.kind
    check member(r.node, "yes").fieldValue.packKind == Opt.some(skBool)
    check member(r.node, "via_ref").fieldValue.packKind.isNone
    check member(r.node, "text").fieldValue.packKind.isNone
    let schema = viewSchema(m)
    for (name, kind) in [
      ("p", dPackedChunk), ("five", dPackedChunk), ("via_ref", dListChunk)
    ]:
      checkpoint name
      let v = viewAt(r, [fieldSegment(name), listIndex(299)])
      check v.domains[0] == kind
      check accepted(wire(v), schema)
      check accepted(wire(v))

  test "[CMT-0145] [CMT-0146] [CMT-0147] [CMT-0148] [CMT-0149] [CMT-0150] [CMT-0151] [CMT-0152] [CMT-0153] [CMT-0154] [CMT-0155] [CMT-0156] [CMT-0157] [CMT-0174] every value node kind has its §9.3 shape, and value objects round-trip":
    let m = build(allKinds)
    let r = m.typed("demo.all", allKindsValue)
    let all = nodes(r.node)
    var kinds: set[ValueKind]
    for n in all:
      kinds.incl(n.kind)
      let v = toCbor(n)
      check shapes.conforms(v, valueRules[n.kind])
      check shapes.conforms(v, "value-node")
    check kinds == {ValueKind.low .. ValueKind.high}
    check shapes.conforms(toCbor(r), "normalized-value-root")
    check toCbor(parseValueRoot(toCbor(r)).get) == toCbor(r)
    check toCbor(parseValueNode(toCbor(r.node)).get) == toCbor(r.node)
    check plainValue(r.node) == diag(allKindsValue)
    # intN data is a CBOR integer of either sign; uintN data is non-negative.
    let l = member(r.node, "l").fieldValue.elements
    check toCbor(l[0].elementValue).dig([3]).kind == ckNint
    check toCbor(l[1].elementValue).dig([3]).kind == ckUint

  test "[CMT-0175] [CMT-0177] [CMT-0158] [CMT-0159] [CMT-0160] [CMT-0161] [CMT-0162] [CMT-0163] malformed value objects are rejected":
    let id = bytesLiteral(ident(0x21))
    let other = bytesLiteral(ident(0x22))
    proc parses(s: string): bool =
      parseValueNode(diag(s.replace("ID", id).replace("OTHER", other))).isOk

    check parses("""{0: "scalar", 1: ID, 2: "int8", 3: -5}""")
    check parses("""{0: "scalar", 1: ID, 2: "int8", 3: 5}""")
    check not parses("""{0: "scalar", 1: ID, 2: "int8", 3: -129}""")
    check not parses("""{0: "scalar", 1: ID, 2: "bool", 3: 1}""")
    check not parses("""{0: "scalar", 1: ID, 2: "uint8", 3: -1}""")
    check not parses("""{0: "scalar", 1: ID, 2: "uint8", 3: 256}""")
    check not parses("""{0: "scalar", 1: ID, 2: "uint64", 3: "1"}""")
    check not parses("""{0: "scalar", 1: ID, 2: "tstr", 3: h'61'}""")
    check not parses("""{0: "scalar", 1: ID, 2: "bstr", 3: "a"}""")
    check not parses("""{0: "scalar", 1: ID, 2: "float", 3: 1}""")
    check not parses("""{0: "scalar", 1: ID, 2: "tstr", 3: "a", 4: 0}""")
    check not parses("""{0: "scalar", 1: h'00', 2: "tstr", 3: "a"}""")
    check not parses("""{0: "set", 1: ID}""")
    # The shortest-encoding rule holds for negative integers too: -1 as 0x38 0x00.
    check decodeCbor(@[0x38'u8, 0x00]).isErr
    let scalar = """{0: "scalar", 1: ID, 2: "uint8", 3: 1}"""
    let e0 = """{0: "list-element", 1: 0, 2: ID, 3: """ & scalar & "}"
    let e1 = e0.replace("1: 0,", "1: 1,")
    let e2 = e0.replace("1: 0,", "1: 2,")
    check parses("""{0: "list", 1: ID, 2: 2, 3: [""" & e0 & ", " & e1 & "]}")
    check not parses("""{0: "list", 1: ID, 2: 2, 3: [""" & e1 & ", " & e0 & "]}")
    check not parses("""{0: "list", 1: ID, 2: 2, 3: [""" & e0 & ", " & e2 & "]}")
    check not parses("""{0: "list", 1: ID, 2: 3, 3: [""" & e0 & ", " & e1 & "]}")
    check not parses("""{0: "list", 1: ID, 2: 1, 3: [""" & scalar & "]}")
    let t0 = """{0: "tuple-element", 1: 0, 2: ID, 3: """ & scalar & "}"
    let t1 = t0.replace("1: 0,", "1: 1,")
    let t2 = t0.replace("1: 0,", "1: 2,")
    check parses("""{0: "tuple", 1: ID, 2: 2, 3: [""" & t0 & ", " & t1 & "]}")
    check not parses("""{0: "tuple", 1: ID, 2: 2, 3: [""" & t1 & ", " & t0 & "]}")
    check not parses("""{0: "tuple", 1: ID, 2: 2, 3: [""" & t0 & ", " & t2 & "]}")
    check not parses("""{0: "tuple", 1: ID, 2: 1, 3: [""" & t0 & ", " & t1 & "]}")
    let fa = """{0: "field", 1: "a", 2: ID, 3: """ & scalar & "}"
    let fb = fa.replace("\"a\"", "\"b\"")
    check parses("""{0: "map", 1: ID, 2: [""" & fa & ", " & fb & "]}")
    check not parses("""{0: "map", 1: ID, 2: [""" & fb & ", " & fa & "]}")
    check not parses("""{0: "map", 1: ID, 2: [""" & fa & ", " & fa & "]}")
    check not parses("""{0: "map", 1: ID, 2: [""" & scalar & "]}")
    check parses(
      """{0: "map", 1: ID, 2: [{0: "field", 1: "a", 2: ID, 3: {0: "absent", 1: ID}}]}"""
    )
    check not parses(
      """{0: "map", 1: ID, 2: [{0: "field", 1: "a", 2: ID, 3: {0: "absent", 1: OTHER}}]}"""
    )
    check not parses("""{0: "choice", 1: ID, 2: 0, 3: ID, 4: {0: "absent", 1: ID}}""")
    check not parses("""{0: "choice", 1: ID, 2: 0, 3: ID, 4: """ & fa & "}")
    check not parses("""{0: "reference-value", 1: ID, 2: ID, 3: ID, 4: """ & e0 & "}")
    check not parses(fa) # a tree starts at a value, not a field
    let root =
      """{0: "value-root", 1: """" & CommitmentModelId & """", 2: ID, 3: ID, 4: """
    check parseValueRoot(diag((root & scalar & "}").replace("ID", id))).isOk
    check parseValueRoot(diag((root & fa & "}").replace("ID", id))).isErr
    check parseValueRoot(diag((root & scalar & ", 5: 0}").replace("ID", id))).isErr

  test "[CMT-0165] [CMT-0166] [CMT-0167] [CMT-0168] [CMT-0169] [CMT-0170] [CMT-0171] [CMT-0172] semantic path segments have their §9.4 shapes and parse back exactly":
    let path = [
      fieldSegment("a"),
      listIndex(3),
      tuplePosition(1),
      choiceArm(2),
      bstrRange(4, 5),
      tstrRange(6, 7),
    ]
    check shapes.conforms(toCbor(path), "semantic-path")
    for s in path:
      check shapes.conforms(toCbor(s), "path-segment")
      check toCbor(parseSegment(toCbor(s)).get) == toCbor(s)
    check toCbor(path) ==
      diag(
        """[{0: "field", 1: "a"}, {0: "list-index", 1: 3}, {0: "tuple-position", 1: 1},
            {0: "choice-arm", 1: 2}, {0: "bstr-range", 1: 4, 2: 5},
            {0: "tstr-utf8-range", 1: 6, 2: 7}]"""
      )
    for bad in [
      """{0: "field", 1: 3}""", """{0: "field", 1: "a", 2: 0}""",
      """{0: "list-index", 1: -1}""", """{0: "list-index"}""",
      """{0: "bstr-range", 1: 0}""", """{0: "slice", 1: 0}""", """{1: "a"}""",
      """["field", "a"]""", """{0: "choice-arm", 1: "0"}""",
    ]:
      checkpoint bad
      check parseSegment(diag(bad)).isErr

# HASH verified views -------------------------------------------------------------------

suite "hash: verified views":
  test "[HSH-0173] [HSH-0151] [HSH-0152] [HSH-0153] [HSH-0156] [HSH-0157] [HSH-0166] App B.1: the view of list index 256 discloses uint16 256 over the final packed chunk, the list and the value root":
    let v = viewAt(hashAppB1(), [listIndex(256)])
    check toCbor(v.path) == diag("""[{0: "list-index", 1: 256}]""")
    check v.disclosed.kind == diValue
    check v.disclosed.value == toCbor(
      scalarNode(ident(0x12), uintScalar(skUint16, 256))
    )
    check v.domains == @[dPackedChunk, dList, dValueRoot]
    check v.stepHashes ==
      @[pin("hsh-b1-final-chunk"), pin("hsh-b1-list"), pin("hsh-b1-value-root")]
    check toHex(v.valueRoot) == pin("hsh-b1-value-root")
    check accepted(wire(v))
    let first = viewAt(hashAppB1(), [listIndex(3)])
    check first.stepHashes[0] == pin("hsh-b1-first-chunk")
    check accepted(wire(first))

  test "[HSH-0175] [HSH-0155] [HSH-0166] App B.2: the view of bytes 4096..4097 discloses the final byte over the final chunk, the aggregate and the value root":
    let v = viewAt(hashAppB2(), [bstrRange(4096, 1)])
    check toCbor(v.path) == diag("""[{0: "bstr-range", 1: 4096, 2: 1}]""")
    check v.disclosed.kind == diBstrRange
    check (v.disclosed.total, v.disclosed.offset, v.disclosed.count) ==
      (4097'u64, 4096'u64, 1'u64)
    check v.disclosed.bytes == @[byte(4096 mod 251)]
    check v.domains == @[dBstrChunk, dBstr, dValueRoot]
    check v.stepHashes ==
      @[pin("hsh-b2-final-chunk"), pin("hsh-b2-aggregate"), pin("hsh-b2-value-root")]
    check accepted(wire(v))
    let first = viewAt(hashAppB2(), [bstrRange(10, 20)])
    check first.stepHashes[0] == pin("hsh-b2-first-chunk")
    check first.disclosed.bytes == toSeq(10 ..< 30).mapIt(byte(it))
    check accepted(wire(first))

  test "[HSH-0166] [HSH-0159] [HSH-0147] [HSH-0146] App B views: every mutation of a value, path, range, label, count, identity, kind, digest, discriminator, domain tag, step or root is rejected":
    let b1 = wire(viewAt(hashAppB1(), [listIndex(256)]))
    var cases = mutations(b1)
    cases.add(("disclosed value", b1.put([8, 1, 3], cbor(255'u64))))
    cases.add(("disclosed schema identity", b1.put([8, 1, 1], cbor(ident(0x14)))))
    cases.add(("disclosed scalar kind", b1.put([8, 1, 2], cbor("uint32"))))
    cases.add(("path index", b1.put([7, 0, 1], cbor(255'u64))))
    cases.add(("path segment kind", b1.put([7, 0, 0], cbor("tuple-position"))))
    cases.add(("packed value", b1.put([9, 0, 1, 7, 0], cbor(255'u64))))
    cases.add(("packed chunk count", b1.put([9, 0, 1, 6], cbor(2'u64))))
    cases.add(("list length", b1.put([9, 1, 1, 4], cbor(258'u64))))
    cases.add(("absence instead of value", b1.put([8], diag("""{0: "absence"}"""))))
    check cases.len >= 40
    check acceptedMutations(b1, cases) == newSeq[string]()
    check failure(b1.put([3], cbor(ident(0x55)))) == Opt.some(veRoot)
    check failure(b1.put([4], cbor("x"))) == Opt.some(veProfile)
    check failure(b1.put([7, 0, 0], cbor("tuple-position"))) == Opt.some(vePath)

    let b2 = wire(viewAt(hashAppB2(), [bstrRange(4096, 1)]))
    cases = mutations(b2)
    cases.add(("disclosed bytes", b2.put([8, 4], cbor(@[0x51'u8]))))
    cases.add(("disclosed total", b2.put([8, 1], cbor(4098'u64))))
    cases.add(("disclosed offset", b2.put([8, 2], cbor(4095'u64))))
    cases.add(("disclosed count", b2.put([8, 3], cbor(2'u64))))
    cases.add(("path start", b2.put([7, 0, 1], cbor(4095'u64))))
    cases.add(("path length", b2.put([7, 0, 2], cbor(2'u64))))
    cases.add(
      (
        "range kind",
        b2.put([7, 0, 0], cbor("tstr-utf8-range")).put([8, 0], cbor("tstr-utf8-range")),
      )
    )
    cases.add(("chunk bytes", b2.put([9, 0, 1, 6], cbor(@[0x51'u8]))))
    cases.add(("chunk offset", b2.put([9, 0, 1, 4], cbor(4095'u64))))
    cases.add(("aggregate total", b2.put([9, 1, 1, 3], cbor(4098'u64))))
    check cases.len >= 40
    check acceptedMutations(b2, cases) == newSeq[string]()

  test "[HSH-0166] [HSH-0159] [HSH-0147] [HSH-0154] a schema-backed view through an imported reference, a list and a choice rejects every mutation":
    let m =
      build(module("demo.t = {d: logos.invalid_params_detail, c: logos.error_code}"))
    let r = m.typed(
      "demo.t", """{"c": 3, "d": {"reason": "schema-mismatch", "path": ["a", 3]}}"""
    )
    let detail = member(r.node, "d").fieldValue.referencedValue
    let segment = member(detail, "path").fieldValue.elements[1].elementValue
    let v = viewAt(
      r,
      [
        fieldSegment("d"),
        fieldSegment("path"),
        listIndex(1),
        choiceArm(segment.armIndex),
      ],
    )
    check v.disclosed.value == toCbor(segment.armValue)
    check dReference in v.domains
    check dChoice in v.domains
    let w = wire(v)
    let schema = viewSchema(m)
    check accepted(w, schema)
    check accepted(w)
    var cases = mutations(w)
    cases.add(("disclosed value", w.put([8, 1, 3], cbor(4'u64))))
    cases.add(("disclosed schema identity", w.put([8, 1, 1], cbor(ident(0x14)))))
    cases.add(("path field", w.put([7, 0, 1], cbor("c"))))
    cases.add(("path arm", w.put([7, 3, 1], cbor(1'u64 - segment.armIndex))))
    cases.add(("path list index", w.put([7, 2, 1], cbor(0'u64))))
    check cases.len >= 40
    check acceptedMutations(w, cases, schema) == newSeq[string]()
    check acceptedMutations(w, cases) == newSeq[string]()
    check failure(w, viewSchema(appB)) == Opt.some(veSchema)

  test "[HSH-0149] [HSH-0150] [HSH-0142] [HSH-0143] a whole-value view discloses the normalized value root and carries no proof material":
    let r = appB.typed("demo.ping_response", """{"ok": true}""")
    let v = viewAt(r, noPath)
    check v.proof.len == 0
    check v.disclosed.value == toCbor(r)
    let w = wire(v)
    let schema = viewSchema(appB)
    check accepted(w)
    check accepted(w, schema)
    let ok = wire(viewAt(r, [fieldSegment("ok")]))
    check failure(w.put([9], cborArray(ok.steps[^1])), schema) == Opt.some(veProof)
    let flipped = w.put([8, 1, 4, 2, 0, 3, 3], cbor(false))
    check failure(flipped) == Opt.some(veRoot)
    check failure(flipped, schema) == Opt.some(veRoot)
    check failure(w.put([8, 1, 2], cbor(ident(0x14)))) == Opt.some(veDisclosed)
    check failure(w.put([8, 1, 3], cbor(ident(0x14)))) == Opt.some(veDisclosed)
    check failure(w.put([8, 1, 1], cbor("logos.commitment-model.2027-01"))) ==
      Opt.some(veDisclosed)
    check failure(w.put([8, 1], toCbor(r.node))) == Opt.some(veDisclosed)
    check failure(w.put([8], diag("""{0: "absence"}"""))) == Opt.some(veDisclosed)
    # A tree with other schema identities and its own recomputed root is physically
    # sound; only the schema shows it is not the normalized form of its data.
    let other = w.put([8, 1, 4, 2, 0, 2], cbor(ident(0x66))).put(
        [8, 1, 4, 2, 0, 3, 1], cbor(ident(0x66))
      )
    let forged =
      other.put([3], cbor(valueRoot(parseValueRoot(other.dig([8, 1])).get).get))
    check accepted(forged)
    check failure(forged, schema) == Opt.some(veDisclosed)

  test "[IMPL-DECISION G7] [HSH-0154] a path ending at a field or a tuple position discloses the inner value":
    let r = appB.typed("demo.ping_response", """{"ok": true}""")
    let ok = viewAt(r, [fieldSegment("ok")])
    let field = member(r.node, "ok")
    check ok.disclosed.value == toCbor(field.fieldValue)
    check ok.disclosed.value != toCbor(field)
    check ok.domains == @[dField, dMap, dValueRoot]
    check accepted(wire(ok), viewSchema(appB))
    check failure(wire(ok).put([8, 1], toCbor(field)), viewSchema(appB)).isSome
    let m = build(module("demo.p = {pair: [uint8, tstr]}"))
    let p = m.typed("demo.p", """{"pair": [1, "x"]}""")
    let v = viewAt(p, [fieldSegment("pair"), tuplePosition(1)])
    check v.disclosed.value ==
      toCbor(member(p.node, "pair").fieldValue.positions[1].positionValue)
    check v.domains == @[dTupleElement, dTuple, dField, dMap, dValueRoot]
    check accepted(wire(v), viewSchema(m))
    check accepted(wire(v))
    check failure(wire(v).put([7, 1, 1], cbor(0'u64)), viewSchema(m)).isSome
    check viewOf(p, [fieldSegment("pair"), tuplePosition(2)]).isErr

  test "[IMPL-DECISION G8] [HSH-0154] [CMT-0230] a path crosses a choice only through the choice-arm segment of the selected arm":
    let m = build(module("demo.t = {v: {a: uint8} / {b: tstr}}"))
    let arms = m.find("demo.t").get.body.fields[0].node.arms
    let aArm = (if arms[0].fields[0].name == "a": 0 else: 1)
    let r = m.typed("demo.t", """{"v": {"a": 1}}""")
    let schema = viewSchema(m)
    check viewOf(r, [fieldSegment("v"), fieldSegment("a")]).isErr
    check viewOf(r, [fieldSegment("v"), choiceArm(uint64(1 - aArm)), fieldSegment("a")]).isErr
    let v = viewAt(r, [fieldSegment("v"), choiceArm(uint64(aArm)), fieldSegment("a")])
    check v.domains == @[dField, dMap, dChoice, dField, dMap, dValueRoot]
    let w = wire(v)
    check accepted(w, schema)
    check accepted(w)
    # The same path without the segment, and without the choice payload it crosses.
    let s = w.steps
    let path = w.dig([7]).items
    let skipped =
      w.put([7], cborArray(path[0], path[2])).withSteps(s[0 .. 1] & s[3 ..^ 1])
    check failure(skipped, schema) == Opt.some(vePath)
    check failure(skipped) == Opt.some(vePath)
    check failure(w.put([7, 1, 1], cbor(uint64(1 - aArm))), schema) == Opt.some(vePath)
    # A path ending at the choice discloses the choice value with its selected arm.
    let c = viewAt(r, [fieldSegment("v")])
    check c.disclosed.value == toCbor(member(r.node, "v").fieldValue)
    check accepted(wire(c), schema)

  test "[HSH-0139] [CMT-0086] an absent optional field is proven by its absent marker, not by leaving it out":
    let m = build(module("demo.t = {? note: tstr, n: uint8}"))
    let r = m.typed("demo.t", """{"n": 1}""")
    let schema = viewSchema(m)
    let v = viewAt(r, [fieldSegment("note")])
    check v.disclosed.kind == diAbsence
    check v.domains == @[dMap, dValueRoot]
    let w = wire(v)
    check shapes.conforms(w.dig([8]), "disclosed-absence")
    check accepted(w, schema)
    check accepted(w)
    let marker =
      """{0: "absent", 1: """ & bytesLiteral(member(r.node, "note").schema) & "}"
    check failure(w.put([8], diag("""{0: "value", 1: """ & marker & "}")), schema).isSome
    check failure(w.put([7, 0, 1], cbor("n")), schema) == Opt.some(veDisclosed)
    check viewOf(r, [fieldSegment("note"), tstrRange(0, 1)]).isErr
    let present = m.typed("demo.t", """{"n": 1, "note": "x"}""")
    let pw = wire(viewAt(present, [fieldSegment("note")]))
    check accepted(pw, schema)
    check failure(pw.put([8], diag("""{0: "absence"}""")), schema) ==
      Opt.some(veDisclosed)

  test "[HSH-0160] [HSH-0161] [HSH-0155] [HSH-0140] [HSH-0141] string range views select a non-empty range inside the string and inside one 4096-byte chunk":
    let b2 = hashAppB2()
    for bad in [
      bstrRange(4095, 2),
      bstrRange(4097, 1),
      bstrRange(0, 0),
      bstrRange(4096, 2),
      bstrRange(5000, 1),
      tstrRange(0, 1),
    ]:
      checkpoint $toCbor(bad).toDiag
      check viewOf(b2, [bad]).isErr
    let w = wire(viewAt(b2, [bstrRange(4094, 2)]))
    check accepted(w)
    check shapes.conforms(w.dig([8]), "disclosed-bstr-range")
    let across = w.put([7, 0, 1], cbor(4095'u64)).put([8, 2], cbor(4095'u64))
    check failure(across) == Opt.some(vePath)
    let empty = w.put([7, 0, 2], cbor(0'u64)).put([8, 3], cbor(0'u64)).put(
        [8, 4], cbor(newSeq[byte]())
      )
    check failure(empty) == Opt.some(vePath)
    let m = build(module("demo.s = {s: tstr}"))
    let schema = viewSchema(m)
    let short = m.norm("demo.s", cborMap((cbor("s"), cbor("héllo")))).get
    let v = viewAt(short, [fieldSegment("s"), tstrRange(1, 2)])
    check v.disclosed.kind == diTstrRange
    check v.disclosed.bytes == @[0xc3'u8, 0xa9]
    check v.disclosed.total == 6
    check v.domains == @[dTstrDirect, dField, dMap, dValueRoot]
    check shapes.conforms(wire(v).dig([8]), "disclosed-tstr-utf8-range")
    check accepted(wire(v), schema)
    check viewOf(short, [fieldSegment("s"), bstrRange(1, 2)]).isErr
    let asBytes =
      wire(v).put([7, 1, 0], cbor("bstr-range")).put([8, 0], cbor("bstr-range"))
    check failure(asBytes, schema) == Opt.some(vePath)
    let long = m.norm("demo.s", cborMap((cbor("s"), cbor("a".repeat(5000))))).get
    let lv = viewAt(long, [fieldSegment("s"), tstrRange(4096, 10)])
    check lv.domains == @[dTstrChunk, dTstr, dField, dMap, dValueRoot]
    check accepted(wire(lv), schema)
    check viewOf(long, [fieldSegment("s"), tstrRange(4090, 10)]).isErr

  test "[HSH-0155] [HSH-0157] chunked lists and branched collections: the proof carries every chunk and branch payload":
    let tl = generated("tstr-list", 300)
    let v = viewAt(tl, [listIndex(299)])
    check v.domains == @[dListChunk, dList, dValueRoot]
    check accepted(wire(v))
    check acceptedMutations(wire(v), mutations(wire(v))) == newSeq[string]()
    let tu = generated("uint8-tuple", 300)
    let t = viewAt(tu, [tuplePosition(280)])
    check t.domains == @[dTupleElement, dBranch, dTuple, dValueRoot]
    check accepted(wire(t))
    check acceptedMutations(wire(t), mutations(wire(t))) == newSeq[string]()

  test "[IMPL-DECISION G120] the verifier checks a view against the caller's schema; without one it checks the physical proof only":
    let r = appB.typed("demo.ping_response", """{"ok": true}""")
    let w = wire(viewAt(r, [fieldSegment("ok")]))
    check accepted(w)
    check accepted(w, viewSchema(appB))
    let other = build(module("demo.ping_request = {}\ndemo.ping_response = {ok: bool}"))
    check failure(w, viewSchema(other)) == Opt.some(veSchema)
    check failure(w, Opt.some(ViewSchema(set: setOf(appB), doc: 7))) ==
      Opt.some(veSchema)
    check failure(w.put([2], cbor(appB.rootOf("demo.ping"))), viewSchema(appB)) ==
      Opt.some(veSchema)
    # Forged identities can be physically sound; the schema rejects them.
    let x = ident(0x66)
    let forged = ValueRoot(
      modelId: r.modelId,
      schemaRoot: r.schemaRoot,
      subtreeRoot: r.subtreeRoot,
      node:
        mapNode(r.node.schema, [fieldNode(x, "ok", scalarNode(x, boolScalar(true)))]),
    )
    let fw = wire(viewAt(forged, [fieldSegment("ok")]))
    check accepted(fw)
    check failure(fw, viewSchema(appB)) == Opt.some(veSchema)
    # Without the schema a branched map cannot be descended: no field index.
    let names = toSeq(0 ..< 257).mapIt(&"f{it:03d}")
    let wide = build(
      module("demo.wide = {\n" & names.mapIt("  " & it & ": uint8").join(",\n") & "\n}")
    )
    var entries: seq[CborEntry]
    for n in names:
      entries.add((cbor(n), cbor(1'u64)))
    let wv =
      viewAt(wide.norm("demo.wide", cborMap(entries)).get, [fieldSegment("f200")])
    check dBranch in wv.domains
    check accepted(wire(wv), viewSchema(wide))
    check failure(wire(wv)) == Opt.some(veProof)

  test "[HSH-0164] [HSH-0163] unknown identifiers, wrong digest lengths, wrong domain tags and non-canonical encodings are rejected":
    let v = viewAt(hashAppB2(), [bstrRange(4096, 1)])
    let w = wire(v)
    check failure(w.put([4], cbor("logos.hash-profile.2026-09"))) == Opt.some(veProfile)
    check failure(w.put([5], cbor("logos.hash-suite.sha-256"))) == Opt.some(veProfile)
    check failure(w.put([6], cbor("logos.commitment-model.2027-01"))) ==
      Opt.some(veProfile)
    check failure(w.put([3], cbor(newSeq[byte](31)))) == Opt.some(veShape)
    check failure(w.put([1], cbor(newSeq[byte](33)))) == Opt.some(veShape)
    check failure(w.put([9, 0, 0], cbor("logos.value.nope"))) == Opt.some(veShape)
    check failure(w.put([9, 0, 0], cbor($dSchemaNode))) == Opt.some(veShape)
    check failure(w.put([9, 0, 0], cbor($dBstrDirect))) == Opt.some(veProof)
    check failure(w.put([9, 1, 1, 4, 0, 2], cbor(newSeq[byte](31)))) == Opt.some(
      veProof
    )
    let bytes = encodeCbor(toCbor(v))
    check decodeCbor(bytes).isOk
    let at = occurrences(bytes, [0x04'u8, 0x41, 0x50]) # key 4: h'50'
    check at.len == 1
    if at.len == 1:
      let i = at[0]
      let longer = bytes[0 .. i] & @[0x58'u8, 0x01, 0x50] & bytes[i + 3 .. ^1]
      check decodeCbor(longer).isErr

  test "[HSH-0136] [HSH-0137] [HSH-0138] [HSH-0139] [HSH-0140] [HSH-0141] [HSH-0144] [HSH-0145] [HSH-0158] [HSH-0163] every view has the §7.6 shape, and every proof step is one complete domain-tagged payload":
    let r = appB.typed("demo.ping_response", """{"ok": true}""")
    let opt = build(module("demo.t = {? note: tstr, s: tstr}"))
    let o = opt.typed("demo.t", """{"s": "héllo"}""")
    let views = @[
      viewAt(hashAppB1(), [listIndex(256)]),
      viewAt(hashAppB2(), [bstrRange(4096, 1)]),
      viewAt(r, noPath),
      viewAt(r, [fieldSegment("ok")]),
      viewAt(o, [fieldSegment("note")]),
      viewAt(o, [fieldSegment("s"), tstrRange(0, 3)]),
      viewAt(generated("uint8-tuple", 300), [tuplePosition(280)]),
    ]
    for v in views:
      let w = toCbor(v)
      check shapes.conforms(w, "verified-view")
      check toCbor(parseView(w).get) == w
      for s in v.proof:
        check shapes.conforms(s.payload, "value-hash-payload")
        check checkValuePayload(s.domain, s.payload).isOk
        check encodeCbor(decodeCbor(encodeCbor(s.payload)).get) == encodeCbor(s.payload)

# HASH App B.4 -------------------------------------------------------------------------

proc tableRows(rel: string): seq[seq[string]] =
  ## The body rows of a mirrored Markdown table, each cell without its backticks.
  let lines = mirror(rel).strip.splitLines()
  for line in lines[2 ..^ 1]:
    result.add(
      line.strip(chars = {'|'}).split('|').mapIt(it.strip.strip(chars = {'`'}))
    )

proc kid(n: PhysNode, i = 0): PhysNode =
  n.children[i].node

proc swapBytes(v: CborValue, old, new: Digest): CborValue =
  ## `v` with every byte string equal to `old` replaced by `new`.
  case v.kind
  of ckBytes:
    if v.bytes == @old:
      cbor(new)
    else:
      v
  of ckArray:
    cborArray(v.items.mapIt(swapBytes(it, old, new)))
  of ckMap:
    cborMap(v.entries.mapIt((it.key, swapBytes(it.value, old, new))))
  else:
    v

proc withField(v: CborValue, k: uint64, x: CborValue): CborValue =
  cborMap(v.entries.mapIt((if it.key == cbor(k): (it.key, x) else: it)))

type Edit = tuple[target: Digest, field: uint64, value: Digest]

proc remade(
    n: PhysNode, edits: openArray[Edit], payloads: var seq[(Digest, CborValue)]
): Digest =
  ## [SPEC HASH App B.4] Rebuilds `n` after `edits`, recomputing every affected
  ## digest and child record; records each payload under its original digest.
  var payload = n.payload
  for e in edits:
    if e.target == n.digest:
      payload = payload.withField(e.field, cbor(e.value))
  for r in n.children:
    let d = remade(r.node, edits, payloads)
    if d != r.node.digest:
      payload = swapBytes(payload, r.node.digest, d)
  payloads.add((n.digest, payload))
  digestOf(domainOf(n.kind), payload)

suite "hash: App B.4 imported reference context":
  let
    types = build(mirror("HSH/app-b4.types.cddl"))
    ctx = block:
      var c = pinnedContext()
      c.supporting = @[types]
      c
    a = build(mirror("HSH/app-b4.a.cddl"), ctx)
    c = build(mirror("HSH/app-b4.c.cddl"), ctx)
    value = diag(mirror("HSH/app-b4.value.diag"))
    ra = setOf(a, ctx).normalize(0, "a.value", value).get
    rc = setOf(c, ctx).normalize(0, "c.value", value).get
    rb = setOf(types).normalize(0, "types.alias", value.lookup("amount").get).get
    la = layout(ra).get
    lc = layout(rc).get
    lb = layout(rb).get
  var docs, digests: seq[(string, string)]
  for row in tableRows("HSH/app-b4.documents.md"):
    docs.add((row[0], row[2]))
  for row in tableRows("HSH/app-b4.payloads.md"):
    digests.add((row[0], row[2]))

  proc docRoot(sym: string): Digest =
    for (k, v) in docs:
      if k == sym:
        return toDigest(cbor(hex.fromHex(v).get)).get
    raiseAssert "no document " & sym

  proc digestNamed(name: string): string =
    for (k, v) in digests:
      if k == name:
        return v
    raiseAssert "no payload " & name

  test "[HSH-0195] [HSH-0196] [HSH-0197] [HSH-0198] [HSH-0199] [HSH-0200] [HSH-0201] [HSH-0202] [HSH-0203] [HSH-0204] [HSH-0205] [HSH-0206] [HSH-0183] [HSH-0184] [HSH-0185] [HSH-0186] App B.4: document roots and every payload digest":
    check toHex(docRoot("A")) == toHex(schemaRoot(a))
    check toHex(docRoot("B")) == toHex(schemaRoot(types))
    check toHex(docRoot("C")) == toHex(schemaRoot(c))
    check toHex(docRoot("L")) == CommonSchemaRoot
    let
      am = la.child
      af = am.kid(0)
      ar = af.kid
      b = ar.kid
      d = b.kid(0)
      r = d.kid
      e = r.kid
      v = b.kid(1)
      n = v.kid
      aq = am.kid(1)
      az = aq.kid
      cm = lc.child
      cf = cm.kid(0)
      cr = cf.kid
      cq = cm.kid(1)
      cz = cq.kid
    for (name, node) in [
      ("e", e),
      ("r", r),
      ("d", d),
      ("n", n),
      ("v", v),
      ("b", b),
      ("ar", ar),
      ("af", af),
      ("az", az),
      ("aq", aq),
      ("am", am),
      ("cr", cr),
      ("cf", cf),
      ("cz", cz),
      ("cq", cq),
      ("cm", cm),
    ]:
      checkpoint name
      check toHex(node.digest) == digestNamed(name)
    check toHex(la.digest) == digestNamed("a0")
    check toHex(lc.digest) == digestNamed("c0")
    check toHex(lb.digest) == digestNamed("b0")
    # The imported subtree is the same under both importers and directly.
    check cr.kid.digest == b.digest and lb.child.digest == b.digest
    # Field 1 is the document context: A above the reference, B below it, L
    # below the common reference; local aliases add nothing (HASH §7.4).
    for (node, sym) in [(am, "A"), (ar, "A"), (b, "B"), (r, "B"), (e, "L"), (cr, "C")]:
      check node.payload.lookup(1'u64).get == cbor(docRoot(sym))
    check ar.schema == a.rootOf("a.import")
    check b.schema == types.rootOf("types.record")

  test "[HSH-0207] [HSH-0208] [HSH-0187] [HSH-0188] [HSH-0189] App B.4: complete and partial views validate, with the proof payloads in the given order":
    let schema = viewSchema(a, ctx)
    for (r, s) in [(ra, schema), (rc, viewSchema(c, ctx)), (rb, viewSchema(types))]:
      let whole = viewAt(r, noPath)
      check whole.proof.len == 0
      check accepted(wire(whole), s)
    for row in tableRows("HSH/app-b4.views.md"):
      checkpoint row[0]
      let path = diag(row[0]).items.mapIt(parseSegment(it).get)
      let view = viewAt(ra, path)
      check stepHashes(view) == row[2].split(", ").mapIt(digestNamed(it))
      check accepted(wire(view), schema)

  test "[HSH-0209] [HSH-0191] [HSH-0192] [HSH-0193] [HSH-0166] App B.4: a wrong document context is rejected even when every hash is consistent":
    let
      schema = viewSchema(a, ctx)
      am = la.child
      ar = am.kid(0).kid
      b = ar.kid
      d = b.kid(0)
      r = d.kid
      e = r.kid
      v = b.kid(1)
      n = v.kid
      aq = am.kid(1)
      recordRoot = types.rootOf("types.record")
      views = tableRows("HSH/app-b4.views.md")
      partial = {
        "amount, value": views[0][0],
        "amount, detail, range": views[2][0],
        "z": views[3][0],
      }
    let cases: seq[(string, seq[Edit])] = @[
      ("N1", @[(n.digest, 1'u64, docRoot("A"))]),
      ("N2", @[(e.digest, 1'u64, docRoot("B"))]),
      ("N3", @[(ar.digest, 1'u64, docRoot("B"))]),
      ("N4", @[(r.digest, 1'u64, docRoot("L"))]),
      ("N5", @[(ar.digest, 3'u64, docRoot("C"))]),
      ("N6", @[(ar.digest, 4'u64, recordRoot)]),
      ("N7", @[(aq.digest, 1'u64, docRoot("B"))]),
      ("N8", [e, r, d, n, v, b].mapIt((it.digest, 1'u64, docRoot("A")))),
    ]
    let negative = tableRows("HSH/app-b4.negative.md")
    check negative.len == cases.len
    for (row, item) in zip(negative, cases):
      let (name, edits) = item
      checkpoint name
      check row[0] == name
      var payloads: seq[(Digest, CborValue)]
      let child = remade(la.child, edits, payloads)
      let root = digestOf(dValueRoot, swapBytes(la.payload, la.child.digest, child))
      check toHex(root) == row[3]
      var whole = viewAt(ra, noPath)
      whole.valueRoot = root
      check not accepted(wire(whole), schema)
      var view =
        viewAt(ra, diag(partial.toTable[row[2]]).items.mapIt(parseSegment(it).get))
      for i in 0 ..< view.proof.len:
        let old = digestOf(view.proof[i].domain, view.proof[i].payload)
        for (k, x) in payloads:
          if k == old:
            view.proof[i].payload = x
      view.valueRoot = root
      check not accepted(wire(view), schema)

suite "commitment: payload depth":
  test "[IFC-0925] [IFC-0927] [IMPL-DECISION I51] validation, normalization and hashing support every payload depth up to the limit: references, choice arms, fields and elements add no level":
    let m = build(
      module(
        """
demo.list = [* demo.list]
demo.either = [* demo.either] / uint64
demo.chain = demo.either
demo.record = { ? next: demo.record }
demo.single = [demo.single] / uint64
"""
      )
    )
    let s = setOf(m)

    proc arrays(levels: int, inner: CborValue): CborValue =
      var v = inner
      for _ in 0 ..< levels:
        v = cborArray(v)
      v

    proc records(levels: int): CborValue =
      var v = cborMap()
      for _ in 1 ..< levels:
        v = cborMap((cbor("next"), v))
      v

    proc at(decl: string, d: int): CborValue =
      ## A value of `decl` with exactly `d` maps or arrays on its deepest path.
      case decl
      of "demo.list":
        arrays(d - 1, cborArray())
      of "demo.record":
        records(d)
      else:
        arrays(d, cbor(1'u64))

    for decl in ["demo.list", "demo.either", "demo.chain", "demo.record", "demo.single"]:
      checkpoint decl
      let body = m.find(decl).get.body
      for d in [MinMaxDepth, 513, DefaultMaxDepth]:
        let v = at(decl, d)
        # The value survives the decoder at this depth too.
        check decodeCbor(encodeCbor(v)).isOk
        check s.validates(0, body, v)
        let r = m.norm(decl, v)
        check r.isOk
        check valueRoot(r.get).isOk
      # One container more is refused as too deep, never as a schema mismatch.
      let over = at(decl, DefaultMaxDepth + 1)
      check not s.validates(0, body, over)
      check "deeper than" in m.norm(decl, over).error

    # The value roots at the limit are deterministic and distinct per declaration.
    check valueRoot(m.norm("demo.either", arrays(DefaultMaxDepth, cbor(1'u64))).get).get ==
      valueRoot(m.norm("demo.either", arrays(DefaultMaxDepth, cbor(1'u64))).get).get
    check valueRoot(m.norm("demo.either", arrays(DefaultMaxDepth, cbor(1'u64))).get).get !=
      valueRoot(m.norm("demo.chain", arrays(DefaultMaxDepth, cbor(1'u64))).get).get
