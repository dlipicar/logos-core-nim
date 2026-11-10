import std/[algorithm, sequtils, strutils]
import unittest2
import ../src/logos_core/[cbor, cddl, hash, commitment]
import ../src/logos_core/base/hex
import ./support/[cddlshape, specdata]

proc build(source: string, ctx = pinnedContext()): SchemaModel =
  let m = buildSchema(source, ctx)
  if m.isErr:
    checkpoint m.error
  m.get

proc buildErr(source: string, ctx = pinnedContext()): string =
  let m = buildSchema(source, ctx)
  doAssert m.isErr, "accepted:\n" & source
  m.error

proc module(body: string): string =
  "_module = \"demo_module\"\n" & body

proc body(m: SchemaModel, name: string): SchemaNode =
  m.find(name).get.body

proc fieldSeg(name: string): PathSegment =
  PathSegment(kind: psField, field: name)

proc elemSeg(): PathSegment =
  PathSegment(kind: psListElement)

proc posSeg(i: int): PathSegment =
  PathSegment(kind: psTuplePosition, index: uint64(i))

proc armSeg(i: int): PathSegment =
  PathSegment(kind: psChoiceArm, index: uint64(i))

proc diag(n: SchemaNode): string =
  toDiag(toCbor(n))

proc bytesLiteral(d: Digest): string =
  "h'" & toHex(d) & "'"

proc digestOfHex(s: string): Digest =
  toDigest(cbor(hex.fromHex(s).get)).get

let
  common = buildCommonSchema(mirror("IFC/5.1.common-schema.cddl"))
  shapes = loadShapes(
    [
      "CMT/9.revision.cddl", "CMT/9.3.value-objects.cddl",
      "CMT/9.1.schema-objects.cddl", "CMT/9.2.schema-payloads.cddl",
    ]
  )
  supporting = buildSchema(mirror("IFC/3.9.2.supporting.cddl"), pinnedContext())
  iface = buildSchema(mirror("IFC/3.9.2.interface.cddl"), pinnedContext())

proc sensorContext(): SchemaContext =
  var ctx = pinnedContext()
  ctx.supporting = @[supporting.get]
  ctx.interfaces = @[iface.get]
  ctx

# Every schema node of a model with its path, for the identity and shape tests.
proc walk(n: SchemaNode, path: seq[PathSegment], acc: var seq[seq[PathSegment]]) =
  acc.add(path)
  case n.kind
  of snMap:
    for f in n.fields:
      walk(f.node, path & fieldSeg(f.name), acc)
  of snList:
    walk(n.element, path & elemSeg(), acc)
  of snTuple:
    for i, x in n.items:
      walk(x, path & posSeg(i), acc)
  of snChoice:
    for i, x in n.arms:
      walk(x, path & armSeg(i), acc)
  else:
    discard

proc paths(d: Declaration): seq[seq[PathSegment]] =
  var acc: seq[seq[PathSegment]]
  if d.kind != dkMethod:
    walk(d.body, @[], acc)
  acc

const everyKind = module(
  """
demo.thing = {
  flag: bool,
  ? note: tstr .size (1..64),
  tag: "thing",
  small: -5,
  big: 18446744073709551615,
  items: [* {x: uint8, y: int64}],
  pair: [uint16, bstr .size 32],
  either: uint32 / tstr,
  next: demo.other,
  code: logos.error_code,
}
demo.other = int8
demo.ping_request = {}
demo.ping_response = {} / {error: bstr}
demo.changed_event = {thing: demo.thing}
"""
)

suite "commitment: pinned roots":
  test "[CMT-0047] [CMT-0048] the common schema document builds from exactly the pinned INTERFACE §5.1 text":
    if common.isErr:
      checkpoint common.error
    check common.isOk
    let m = common.get
    check m.namespace == "logos"
    check m.role == srCommon
    check m.implemented.len == 0
    # The prelude aliases are neither declarations nor part of the namespace.
    check m.declarations.allIt(it.name.startsWith("logos."))
    check CommonSchemaDocument == mirror("IFC/5.1.common-schema.cddl")
    check schemaRoot(pinnedContext().commonModel) == schemaRoot(m)

  test "[CMT-0043] [CMT-0049] [CMT-0050] the common schema root and every registry subtree root recompute from the mirrored INTERFACE §5.1 text":
    let m = common.get
    check toHex(schemaRoot(m)) == pin("common-schema-root")
    check m.declarations.mapIt(it.name) == CommonRegistry.mapIt(it[0])
    for d in m.declarations:
      checkpoint d.name
      let row = CommonRegistry.filterIt(it[0] == d.name)[0]
      check parseDeclKind(row[1]).get == d.kind
      check toHex(declarationRoot(m, d)) == row[2]
    check toHex(pinnedContext().commonRoot) == pin("common-schema-root")

  test "[CMT-0043] [CMT-0050] imported common references carry the pinned registry roots, not ones derived from another document":
    var ctx = pinnedContext()
    # A different common document: its roots must never replace the registry's.
    ctx.commonModel = build(module("demo.x = uint8"))
    let m = build(module("demo.t = {code: logos.error_code}"), ctx)
    let code = m.body("demo.t").fields[0].node
    check code.kind == snImportedRef
    check toHex(code.imported.root) == pin("common-schema-root")
    check toHex(code.imported.subtree) == pin("common-subtree-error-code")

  test "[CMT-0182] [CMT-0183] [CMT-0184] [CMT-0185] [CMT-0186] [CMT-0187] [CMT-0188] [CMT-0189] [CMT-0190] [CMT-0006] App A: the COMMITMENT App A source builds to the mirrored schema object and the HASH App A root":
    let m = build(mirror("CMT/app-a.input.cddl"))
    check m.role == srModule
    check toCbor(m) == parseDiag(mirror("CMT/app-a.schema.diag")).get
    check encodeCbor(hashInput(dSchemaRoot, toCbor(m))) ==
      mirrorHex("HSH/app-a.hash-input.hex")
    check toHex(schemaRoot(m)) == pin("hsh-app-a-root")

  test "App B: the COMMITMENT App B source builds to the mirrored schema object":
    let m = build(mirror("CMT/app-b.input.cddl"))
    check toCbor(m) == parseDiag(mirror("CMT/app-b.schema.diag")).get
    let path = parseDiag(mirror("CMT/app-b.ok-schema-path.diag")).get
    check toCbor([fieldSeg("ok")]) == path
    let d = m.find("demo.ping_response").get
    check nodeIdentity(m, d, [fieldSeg("ok")]).get ==
      leafHash(m, d, [fieldSeg("ok")]).get
    check nodeIdentity(m, d, []).get == declarationRoot(m, d)

  test "[CMT-0041] [CMT-0022] [CMT-0107] [CMT-0108] INTERFACE §3.9.2: the interface root is the pinned one and the module carries recomputed supporting roots":
    check supporting.isOk and iface.isOk
    check supporting.get.role == srSupporting
    check iface.get.role == srInterface
    check toHex(schemaRoot(iface.get)) == pin("ifc-3-9-2-interface-root")
    let m = build(mirror("IFC/3.9.2.module.cddl"), sensorContext())
    check m.namespace == "sensor.control"
    check m.implemented == @[schemaRoot(iface.get)]
    let limit =
      m.body("sensor.control.settings").fields.filterIt(it.name == "limit")[0].node
    let counter = supporting.get.find("metrics_types.counter").get
    check limit.kind == snImportedRef
    check limit.imported.root == schemaRoot(supporting.get)
    check limit.imported.subtree == declarationRoot(supporting.get, counter)
    check m.find("sensor.control.configure").get.kind == dkMethod

  test "[CMT-0128] imported references resolve to exactly one supplied named type":
    let ctx = sensorContext()
    let m = build(mirror("IFC/3.9.2.module.cddl"), ctx)
    let set = schemaSetFor(m, ctx)
    check set.checkImports().isOk
    let limit =
      m.body("sensor.control.settings").fields.filterIt(it.name == "limit")[0].node
    let (doc, decl) = set.resolveImport(limit.imported).get
    check set.docs[doc].namespace == "metrics_types"
    check decl.name == "metrics_types.counter"
    let e = build(module("demo.t = {c: logos.error_code}"))
    check schemaSetFor(e, pinnedContext()).checkImports().isOk
    # A pair naming no declaration, or a callable one, does not resolve.
    let common = pinnedContext()
    let request = common.common.filterIt(it[0] == "logos.schema_request")[0][2]
    for forged in [
      SchemaImport(root: common.commonRoot, subtree: request),
      SchemaImport(root: common.commonRoot, subtree: schemaRoot(m)),
      SchemaImport(root: schemaRoot(m), subtree: limit.imported.subtree),
    ]:
      check set.resolveImport(forged).isNone
    var bad = e
    bad.declarations[0].body.fields[0].node = SchemaNode(
      kind: snImportedRef,
      imported: SchemaImport(root: common.commonRoot, subtree: request),
    )
    check schemaSetFor(bad, pinnedContext()).checkImports().isErr

suite "commitment: schema-model construction":
  test "a document's role comes from its metadata":
    check buildErr("_module = \"a\"\n_interface = \"demo\"\ndemo.t = uint8").contains(
      "both"
    )
    check buildErr("_interface = \"demo\"\n_implements = [h'00']\ndemo.t = uint8")
      .contains("_implements")
    check buildErr("_implements = [h'00']\ndemo.t = uint8").contains("_implements")
    # Every declaration of a supporting schema is a named type, whatever its suffix.
    let s = build("demo.x_request = {}\ndemo.y_event = uint8")
    check s.role == srSupporting
    check s.declarations.allIt(it.kind == dkType)

  test "[CMT-0020] one namespace: the longest common dot-segment prefix, a proper prefix of every name":
    check build(module("a.b.x = uint8\na.b.y = uint8")).namespace == "a.b"
    check buildErr(module("x = uint8")).contains("namespace")
    check buildErr(module("a.x = uint8\nb.y = uint8")).contains("namespace")
    check buildErr(module("a.b.x = uint8\na.c.y = uint8")).contains("G4")
    check build("_interface = \"demo\"\ndemo.t = uint8").role == srInterface
    check buildErr("_interface = \"other\"\ndemo.t = uint8").contains("_interface")
    check buildErr("_interface = 5\ndemo.t = uint8").contains("_interface")

  test "[CMT-0021] callable bodies are maps or choices of maps, methods pair up and names stay distinct":
    let m = build(module("demo.ping_request = {}\ndemo.ping_response = {} / {e: bstr}"))
    check m.declarations.mapIt($it.kind) ==
      @["method", "method-request", "method-response"]
    check m.find("demo.ping").get.request == "demo.ping_request"
    check m.find("demo.ping").get.response == "demo.ping_response"
    check buildErr(module("demo.x_event = uint8")).contains("map")
    check buildErr(module("demo.x_event = {} / uint8")).contains("map")
    check buildErr(module("demo.ping_request = {}")).contains("no matching")
    check buildErr(module("demo.ping_response = {}")).contains("no matching")
    check buildErr(
      module("demo.ping_request = {}\ndemo.ping_response = {}\ndemo.ping = uint8")
    )
      .contains("collides")

  test "[CMT-0023] literals: bool, text, uint64 and int64, and nothing else":
    let m = build(
      module(
        "demo.t = {a: true, b: \"x\", c: 18446744073709551615, d: -9223372036854775808}"
      )
    )
    check m.body("demo.t").fields.mapIt(diag(it.node)) ==
      @[
        "{0: \"literal\", 1: \"bool\", 2: true}",
        "{0: \"literal\", 1: \"tstr\", 2: \"x\"}",
        "{0: \"literal\", 1: \"uint64\", 2: 18446744073709551615}",
        "{0: \"literal\", 1: \"int64\", 2: -9223372036854775808}",
      ]
    check buildErr(module("demo.t = -9223372036854775809")).contains("int64")
    check buildErr(module("demo.t = h'00'")).contains("byte-string literal")

  test "[CMT-0129] primitives: prelude aliases, bool, tstr, bstr; sizes only on tstr and bstr":
    let m =
      build(module("demo.t = [uint8, int32, bool, tstr .size 4, bstr .size (1..3)]"))
    check m.body("demo.t").items.mapIt(diag(it)) ==
      @[
        "{0: \"primitive\", 1: \"uint8\"}", "{0: \"primitive\", 1: \"int32\"}",
        "{0: \"primitive\", 1: \"bool\"}",
        "{0: \"primitive\", 1: \"tstr\", 2: {0: \"size\", 1: 4, 2: 4}}",
        "{0: \"primitive\", 1: \"bstr\", 2: {0: \"size\", 1: 1, 2: 3}}",
      ]
    check buildErr(module("demo.t = uint")).contains("bare uint")
    check buildErr(module("demo.t = uint .size 2")).contains(".size")
    check buildErr(module("demo.t = 1..5")).contains("range")
    # Two arms with the same canonical node make the choice invalid.
    check buildErr(module("demo.t = uint8 / uint8")).len > 0

  test "[CMT-0024] [CMT-0025] [CMT-0013] [CMT-0016] local references keep the name and are never inlined":
    let src =
      "demo.a = {x: uint8}\ndemo.b = {x: uint8}\ndemo.c = {p: demo.a, q: demo.b}"
    let m = build(module(src))
    let c = m.find("demo.c").get
    check c.body.fields.mapIt(diag(it.node)) ==
      @[
        "{0: \"local-reference\", 1: \"demo.a\"}",
        "{0: \"local-reference\", 1: \"demo.b\"}",
      ]
    # Same structure, different names: two declarations, two roots.
    check declarationRoot(m, m.find("demo.a").get) !=
      declarationRoot(m, m.find("demo.b").get)
    # Changing a referenced body changes neither the referrer's subtree root nor
    # its leaf hashes.
    let m2 = build(module(src.replace("demo.a = {x: uint8}", "demo.a = {x: uint16}")))
    let c2 = m2.find("demo.c").get
    check declarationRoot(m, c) == declarationRoot(m2, c2)
    check leafHash(m, c, [fieldSeg("p")]).get == leafHash(m2, c2, [fieldSeg("p")]).get
    check schemaRoot(m) != schemaRoot(m2)

  test "[CMT-0026] [CMT-0015] [CMT-0033] recursive and mutually recursive local types":
    let m = build(
      module(
        "demo.node = {value: uint8, ? next: demo.node}\ndemo.a = {? b: demo.b}\ndemo.b = {? a: demo.a}"
      )
    )
    check m.body("demo.node").fields[0].node.target == "demo.node"
    check m.declarations.len == 3

  test "[CMT-0042] references: local types, common types and supplied supporting types only":
    check buildErr(
      module("demo.x_request = {}\ndemo.x_response = {}\ndemo.t = {r: demo.x_request}")
    )
      .contains("callable")
    check buildErr(module("demo.t = {r: logos.schema_request}")).contains("G6")
    check buildErr(module("demo.t = {r: logos.schema}")).contains("G6")
    check buildErr(module("demo.t = {r: demo.missing}")).contains("undefined name")
    # Interfaces and supporting schemas see only local and common definitions.
    var ctx = pinnedContext()
    ctx.supporting = @[supporting.get]
    check buildErr("_interface = \"demo\"\ndemo.t = {c: metrics_types.counter}", ctx)
      .contains("undefined name")
    check buildErr("other.t = {c: metrics_types.counter}", ctx).contains(
      "undefined name"
    )
    check build("other.t = {c: logos.error_code}").role == srSupporting
    # A module cannot import an interface's types.
    check buildErr(
      module("demo.t = {c: metrics_provider.snapshot_response}"), sensorContext()
    )
      .contains("undefined name")
    # A supplied dependency must be a supporting schema.
    ctx.supporting = @[iface.get]
    check buildErr(module("demo.t = uint8"), ctx).contains("role")

  test "[CMT-0022] [CMT-0107] [CMT-0108] [CMT-0109] _implements: ascending 32-byte roots, each one supplied interface document, none unused":
    let one = iface.get
    let two = build(
      "_interface = \"status_provider\"\nstatus_provider.status_request = {}\nstatus_provider.status_response = {up: bool}"
    )
    let same = build(
      "_interface = \"metrics_provider\"\nmetrics_provider.snapshot_request = {}\nmetrics_provider.snapshot_response = {count: uint32}"
    )
    var roots = @[schemaRoot(one), schemaRoot(two)]
    roots.sort(
      proc(a, b: Digest): int =
        cmpBytes(a, b)
    )
    var ctx = pinnedContext()
    ctx.interfaces = @[one, two]
    let src =
      "_module = \"m\"\n_implements = [" & roots.mapIt(bytesLiteral(it)).join(", ") &
      "]\ndemo.t = uint8"
    check build(src, ctx).implemented == roots
    let reversed =
      "_module = \"m\"\n_implements = [" &
      roots.reversed.mapIt(bytesLiteral(it)).join(", ") & "]\ndemo.t = uint8"
    check buildErr(reversed, ctx).contains("ascending")
    let twice =
      "_module = \"m\"\n_implements = [" & bytesLiteral(roots[0]) & ", " &
      bytesLiteral(roots[0]) & "]\ndemo.t = uint8"
    check buildErr(twice, ctx).contains("twice")
    check buildErr("_module = \"m\"\n_implements = []\ndemo.t = uint8", ctx).len > 0
    check buildErr("_module = \"m\"\n_implements = [h'00']\ndemo.t = uint8", ctx)
      .contains("32-byte")
    # A root no supplied document has, and a supplied document no root names.
    ctx.interfaces = @[one]
    check buildErr(src, ctx).contains("names no supplied")
    ctx.interfaces = @[one, two]
    check buildErr(module("demo.t = uint8"), ctx).contains("not in _implements")
    # Two implemented interfaces in one namespace.
    var both = @[schemaRoot(one), schemaRoot(same)]
    both.sort(
      proc(a, b: Digest): int =
        cmpBytes(a, b)
    )
    ctx.interfaces = @[one, same]
    check buildErr(
      "_module = \"m\"\n_implements = [" & both.mapIt(bytesLiteral(it)).join(", ") &
        "]\ndemo.t = uint8",
      ctx,
    )
      .contains("namespace")
    # Field 4 is empty for interfaces, supporting schemas and the common schema.
    check one.implemented.len == 0 and supporting.get.implemented.len == 0
    check common.get.implemented.len == 0

  test "[CMT-0011] [CMT-0018] [CMT-0030] [CMT-0044] [CMT-0045] [CMT-0046] [CMT-0092] identity ignores source order, layout, comments and directive-like comments":
    let a = build(
      module(
        "demo.b = {z: uint8, a: tstr}\ndemo.a = demo.b / tstr / {q: bool}\ndemo.c = [uint8, tstr]"
      )
    )
    let b = build(
      """
; ;# include "elsewhere.cddl"
;# import demo from "./types"
_module = "demo_module"
demo.c = [ uint8 , tstr ]   ; a tuple
demo.a = {q: bool} / tstr / demo.b
demo.b = {
  a: tstr,
  z: uint8,
}
"""
    )
    check encodeCbor(toCbor(a)) == encodeCbor(toCbor(b))
    check schemaRoot(a) == schemaRoot(b)
    check a.declarations.mapIt(it.name) == @["demo.a", "demo.b", "demo.c"]
    check a.body("demo.b").fields.mapIt(it.name) == @["a", "z"]
    let arms = a.body("demo.a").arms.mapIt(encodeCbor(toCbor(it)))
    check arms ==
      arms.sorted(
        proc(a, b: seq[byte]): int =
          cmpBytes(a, b)
      )

  test "[CMT-0090] [CMT-0091] optional members are omitted and tuples keep their order":
    let m = build(
      module("demo.t = {x: tstr}\ndemo.u = [uint8, tstr]\ndemo.v = [tstr, uint8]")
    )
    check toCbor(m.body("demo.t").fields[0].node).entries.len == 2
    check m.body("demo.u").items.mapIt($it.scalar) == @["uint8", "tstr"]
    check declarationRoot(m, m.find("demo.u").get) !=
      declarationRoot(m, m.find("demo.v").get)

suite "commitment: schema identities":
  test "[CMT-0037] [CMT-0143] [CMT-0038] [CMT-0061] structural roots, leaf hashes and subtree roots of every node":
    let m = build(everyKind)
    var structural, leaves = 0
    for d in m.declarations:
      for path in d.paths:
        checkpoint d.name & " " & toDiag(toCbor(path))
        let node = nodeAt(d, path).get
        let id = nodeIdentity(m, d, path).get
        if path.len == 0:
          check id == declarationRoot(m, d)
        elif node.isLeaf:
          inc leaves
          check id == digestOf(dSchemaLeaf, leafPayload(m.modelId, d, path, node))
          check structuralRoot(m, d, path).isErr
        else:
          inc structural
          check id == digestOf(dSchemaNode, structuralPayload(m.modelId, d, path, node))
          check leafHash(m, d, path).isErr
          # The same payload under the leaf domain is another hash.
          check id != digestOf(dSchemaLeaf, structuralPayload(m.modelId, d, path, node))
        # A structural root or leaf hash never names a declaration.
        if path.len > 0:
          check m.declarationBySubtree(id).isNone
          check id != schemaRoot(m)
    check structural > 0 and leaves > 0
    for d in m.declarations:
      check m.declarationBySubtree(declarationRoot(m, d)).get.name == d.name
    let t = m.find("demo.thing").get
    check structuralRoot(m, t, []).isErr
    check nodeAt(t, [fieldSeg("missing")]).isErr
    check nodeAt(t, [fieldSeg("flag"), fieldSeg("x")]).isErr
    check nodeAt(t, [fieldSeg("pair"), posSeg(2)]).isErr
    check nodeAt(t, [fieldSeg("either"), armSeg(2)]).isErr
    check nodeAt(t, [fieldSeg("items"), posSeg(0)]).isErr
    check nodeAt(m.find("demo.ping").get, []).isErr

  test "[IMPL-DECISION G152] a leaf-bodied declaration's node at the empty path is identified by its subtree root":
    let m = build(module("demo.id = uint8"))
    let d = m.find("demo.id").get
    check nodeIdentity(m, d, []).get == declarationRoot(m, d)
    check leafHash(m, d, []).get != declarationRoot(m, d)

  test "[IMPL-DECISION G122] [CMT-0136] the reference hash is the schema import under logos.schema.reference":
    let i = SchemaImport(
      root: digestOfHex(pin("common-schema-root")),
      subtree: digestOfHex(pin("common-subtree-error-code")),
    )
    check referenceHash(i) == digestOf(dSchemaReference, toCbor(i))
    check shapes.conforms(toCbor(i), "schema-reference-payload")
    check referenceHash(i) != digestOf(dSchemaNode, toCbor(i))

  test "[CMT-0060] [CMT-0056] hash inputs commit to the domain tag and the commitment-model revision":
    let m = build(everyKind)
    let input = hashInput(dSchemaRoot, toCbor(m))
    check input.lookup(0'u64).get == cbor("logos.schema.root")
    check input.lookup(3'u64).get == cbor(CommitmentModelId)
    check toCbor(m).lookup(1'u64).get == cbor(CommitmentModelId)
    var other = SpecProfile
    other.modelId = "logos.commitment-model.2027-01"
    check digestOf(dSchemaRoot, toCbor(m), other) != schemaRoot(m)
    var renamed = m
    renamed.modelId = "logos.commitment-model.2026-08.r1"
    check schemaRoot(renamed) != schemaRoot(m)

suite "commitment: canonical data shapes":
  test "[CMT-0093] [CMT-0094] [CMT-0095] [CMT-0096] [CMT-0097] [CMT-0098] [CMT-0099] [CMT-0100] [CMT-0101] [CMT-0102] [CMT-0103] [CMT-0106] [CMT-0110] [CMT-0111] [CMT-0112] [CMT-0113] [CMT-0114] [CMT-0115] [CMT-0116] [CMT-0117] [CMT-0118] [CMT-0119] [CMT-0120] [CMT-0121] [CMT-0122] [CMT-0123] [CMT-0124] [CMT-0125] [CMT-0126] [CMT-0127] [CMT-0130] schema objects have the mirrored §9 and §9.1 shapes":
    var models = @[common.get, build(mirror("CMT/app-a.input.cddl")), build(everyKind)]
    models.add(build(mirror("IFC/3.9.2.module.cddl"), sensorContext()))
    for m in models:
      checkpoint m.namespace
      check shapes.conforms(toCbor(m), "normalized-schema-root")
      for d in m.declarations:
        check shapes.conforms(toCbor(d), "schema-declaration")
        for path in d.paths:
          let n = nodeAt(d, path).get
          check shapes.conforms(toCbor(n), "schema-node")
          if n.kind == snImportedRef:
            check shapes.conforms(toCbor(n.imported), "schema-import")
    check shapes.alternatives("scalar-kind") == ScalarKind.toSeq.mapIt(
      "\"" & $it & "\""
    )
    check shapes.alternatives("schema-declaration-kind") ==
      DeclKind.toSeq.mapIt("\"" & $it & "\"")

  test "[CMT-0104] uint64 and int64 are the prelude aliases":
    let prelude = loadShapes(["IFC/1.3.prelude.cddl"])
    for name in ["uint64", "int64"]:
      check shapes.alternatives(name) == prelude.alternatives(name)

  test "[CMT-0132] [CMT-0133] [CMT-0134] [CMT-0135] [CMT-0137] [CMT-0138] [CMT-0139] [CMT-0140] [CMT-0141] [CMT-0142] [CMT-0037] hash payloads and paths have the mirrored §4 and §9.2 shapes":
    let structural = loadShapes(["CMT/4.structural-node.cddl"])
    check structural.keyTypes("schema-structural-node-payload") ==
      shapes.keyTypes("schema-structural-node-payload")
    let m = build(everyKind)
    check shapes.conforms(toCbor(m), "schema-root-payload")
    for d in m.declarations:
      check shapes.conforms(schemaNodePayload(m.modelId, d), "schema-node-payload")
      for path in d.paths:
        check shapes.conforms(toCbor(path), "schema-node-path")
        if path.len == 0:
          continue
        let n = nodeAt(d, path).get
        if n.isLeaf:
          check shapes.conforms(
            leafPayload(m.modelId, d, path, n), "schema-leaf-payload"
          )
        else:
          check shapes.conforms(
            structuralPayload(m.modelId, d, path, n), "schema-structural-node-payload"
          )

  test "[CMT-0008] [CMT-0009] [CMT-0010] the Logos schema object is not cdCDDLe's canonical schema":
    let source = mirror("CMT/app-a.input.cddl")
    let m = build(source)
    let generic = encodeCddl(parseCddl(source).get).get
    check generic != encodeCbor(toCbor(m))
    check digestOf(dSchemaRoot, cbor(generic)) != schemaRoot(m)

suite "commitment: commitment-model revision":
  test "[CMT-0054] [CMT-0055] [CMT-0052] the revision identifier and its grammar":
    check isCommitmentModelRevision(CommitmentModelId)
    check CommitmentModelId == "logos.commitment-model.2026-08"
    for good in [
      "logos.commitment-model.2026-08.r2", "logos.commitment-model.1999-12.a-b-0"
    ]:
      check isCommitmentModelRevision(good)
    for bad in [
      "logos.commitment-model.2026-8", "logos.commitment-model.2026-08.",
      "logos.commitment-model.2026-08.R2", "logos.commitment-model.2026_08",
      "Logos.commitment-model.2026-08", "logos.commitment-model.2026-08.r 2",
    ]:
      check not isCommitmentModelRevision(bad)

  test "[CMT-0053] [CMT-0057] [CMT-0062] [CMT-0063] [CMT-0064] [CMT-0066] [CMT-0068] a dependency under another revision is rejected, whatever its spelling suggests":
    for id in ["logos.commitment-model.2026-09", "logos.commitment-model.2026-08.r1"]:
      var other = supporting.get
      other.modelId = id
      var ctx = pinnedContext()
      ctx.supporting = @[other]
      check buildErr(module("demo.t = {c: metrics_types.counter}"), ctx).contains(
        "commitment model"
      )

proc planOf(src: string, name = "demo.t", ctx = pinnedContext()): SelectionPlan =
  let m = build(module(src), ctx)
  schemaSetFor(m, ctx).selectionPlan(0, m.body(name)).get

suite "commitment: choice selection plans":
  test "[CMT-0029] [CMT-0031] [CMT-0032] the normative plan-construction examples":
    check planOf("demo.t = uint64 / tstr").test == ptMajorType
    check planOf("demo.t = [uint64] / [uint64, uint64]").test == ptTupleLength
    for (src, field) in [
      (
        "demo.t = { status: \"failed\", error: bstr } / { status: \"failed\", realization: bstr }",
        "error",
      ),
      ("demo.t = { request: bstr, ? response: bstr } / { response: bstr }", "request"),
      ("demo.t = {} / { error: bstr }", "error"),
    ]:
      let p = planOf(src)
      check p.test == ptFieldLiteral
      check p.field == field
    let three = planOf(
      "demo.t = { operation: \"evaluate\", outcome: \"allow\" } / { operation: \"evaluate\", outcome: \"deny\" } / { operation: \"issue-grant\", outcome: \"deny\" }"
    )
    check three.test == ptFieldLiteral and three.field == "operation"
    let evaluate = three.branches.filterIt(
      it[0].kind == ocLiteral and it[0].literal == cbor("evaluate")
    )[0][1]
    check evaluate.test == ptFieldLiteral and evaluate.field == "outcome"
    check buildErr(module("demo.t = tstr / \"fixed\"")).contains("selection plan")
    let tagged = planOf(
      "demo.a = {kind: \"a\", ? next: demo.a / demo.b}\ndemo.b = {kind: \"b\", ? next: demo.a / demo.b}\ndemo.t = demo.a / demo.b"
    )
    check tagged.test == ptFieldLiteral and tagged.field == "kind"
    check buildErr(module("demo.a = demo.b\ndemo.b = demo.a\ndemo.t = demo.a / demo.b")).len >
      0

  test "[CMT-0032] references are followed into imported and supporting documents":
    check planOf("demo.t = logos.error_code / tstr").test == ptMajorType
    check buildErr(module("demo.t = logos.error_code / uint8")).contains(
      "selection plan"
    )
    check planOf("demo.t = 10 / logos.error_code").test == ptScalarLiteral
    var ctx = pinnedContext()
    ctx.supporting = @[supporting.get]
    check buildErr(module("demo.t = metrics_types.counter / uint8"), ctx).contains(
      "selection plan"
    )
    check planOf("demo.t = metrics_types.counter / tstr", ctx = ctx).test == ptMajorType
    # Exact ranges decide: 300 is no uint8.
    check planOf("demo.t = uint8 / 300").test == ptScalarLiteral
    check planOf("demo.t = true / false").test == ptScalarLiteral
    check buildErr(module("demo.t = bool / true")).contains("selection plan")
    check buildErr(module("demo.t = uint16 / 300")).contains("selection plan")
    check buildErr(module("demo.t = uint8 / int8")).contains("selection plan")
    check buildErr(module("demo.t = [* uint8] / [uint8]")).contains("selection plan")
    check buildErr(module("demo.t = {? a: uint8} / {? b: uint8}")).contains(
      "selection plan"
    )
    check planOf("demo.t = {a: uint8} / {? b: uint8}").test == ptFieldLiteral

  test "[IMPL-DECISION G9] outcome literals sit on the observed value, through references and nested choices":
    # A literal one level down does not separate the arms.
    check buildErr(module("demo.t = {a: {k: \"x\"}} / {a: {k: \"y\"}}")).contains(
      "selection plan"
    )
    let viaRef = planOf(
      "demo.k1 = \"a\"\ndemo.k2 = \"b\"\ndemo.t = {kind: demo.k1} / {kind: demo.k2}"
    )
    check viaRef.test == ptFieldLiteral and viaRef.field == "kind"
    check viaRef.branches.countIt(it[0].kind == ocLiteral) == 2
    let nested = planOf("demo.t = {kind: \"a\" / \"b\"} / {kind: \"c\"}")
    check nested.branches.countIt(it[0].kind == ocLiteral) == 3

  test "[CMT-0018] [CMT-0030] arm order in the source changes neither the arms nor the plan":
    let a = build(module("demo.t = [uint8] / tstr / {k: \"x\"} / {k: \"y\"} / true"))
    let b = build(module("demo.t = true / {k: \"y\"} / tstr / {k: \"x\"} / [uint8]"))
    check a.body("demo.t").arms.mapIt(diag(it)) == b.body("demo.t").arms.mapIt(diag(it))
    let pa = schemaSetFor(a, pinnedContext()).selectionPlan(0, a.body("demo.t")).get
    let pb = schemaSetFor(b, pinnedContext()).selectionPlan(0, b.body("demo.t")).get
    for v in ["[1]", "\"s\"", "{\"k\": \"x\"}", "{\"k\": \"y\"}", "true", "false", "{}"]:
      let value = parseDiag(v).get
      check pa.select(value) == pb.select(value)

  test "[CMT-0034] [CMT-0035] a value selects at most one arm and is then validated against all of it":
    let m = build(
      module(
        "demo.t = { operation: \"evaluate\", outcome: \"allow\" } / { operation: \"evaluate\", outcome: \"deny\" } / { operation: \"issue-grant\", outcome: \"deny\" }"
      )
    )
    let set = schemaSetFor(m, pinnedContext())
    let t = m.body("demo.t")
    let plan = set.selectionPlan(0, t).get
    proc chosen(v: string): string =
      let arm = plan.select(parseDiag(v).get)
      if arm.isNone:
        ""
      else:
        diag(t.arms[arm.get])

    check chosen("{\"operation\": \"evaluate\", \"outcome\": \"deny\"}").contains(
      "\"deny\""
    )
    check chosen("{\"operation\": \"evaluate\", \"outcome\": \"deny\"}").contains(
      "\"evaluate\""
    )
    check chosen("{\"operation\": \"issue-grant\", \"outcome\": \"allow\"}").contains(
      "issue-grant"
    )
    check chosen("{\"operation\": \"other\"}") == ""
    check chosen("[]") == ""
    # Selection alone is not validity: the selected arm must accept all of it.
    check set.validates(
      0, t, parseDiag("{\"operation\": \"evaluate\", \"outcome\": \"deny\"}").get
    )
    check not set.validates(
      0, t, parseDiag("{\"operation\": \"issue-grant\", \"outcome\": \"allow\"}").get
    )
    check not set.validates(
      0,
      t,
      parseDiag("{\"operation\": \"evaluate\", \"outcome\": \"deny\", \"x\": 1}").get,
    )

  test "values are validated through references, ranges, sizes and closed maps":
    let m = build(everyKind)
    let set = schemaSetFor(m, pinnedContext())
    let thing = m.body("demo.thing")
    let good =
      """{"flag": true, "tag": "thing", "small": -5, "big": 18446744073709551615,
          "items": [{"x": 1, "y": -2}], "pair": [65535, h'""" &
      "00".repeat(32) & """'], "either": "s", "next": -128, "code": 9}"""
    check set.validates(0, thing, parseDiag(good).get)
    check set.validates(
      0,
      thing,
      parseDiag(good.replace("\"flag\": true", "\"flag\": true, \"note\": \"n\"")).get,
    )
    for bad in [
      good.replace("\"flag\": true", "\"flag\": 1"),
      good.replace("\"tag\": \"thing\"", "\"tag\": \"other\""),
      good.replace("\"small\": -5", "\"small\": -6"),
      good.replace("\"x\": 1", "\"x\": 256"),
      good.replace("[65535,", "[65536,"),
      good.replace("\"next\": -128", "\"next\": -129"),
      good.replace("\"code\": 9", "\"code\": 10"),
      good.replace("\"either\": \"s\"", "\"either\": true"),
      good.replace("\"flag\": true", "\"flag\": true, \"note\": \"\""),
      good.replace("\"flag\": true", "\"flag\": true, \"extra\": 1"),
      good.replace("\"flag\": true, ", ""),
      good.replace("\"items\": [{\"x\": 1, \"y\": -2}]", "\"items\": [{\"x\": 1}]"),
    ]:
      checkpoint bad
      check not set.validates(0, thing, parseDiag(bad).get)
