## lcn-gen's Nim output [D29]: the committed modules are current, and the
## generated codecs round-trip, check every value against the schema, and agree
## with the hand-written INTERFACE §5.1 encoders.

import std/strutils
import unittest2
import ../src/logos_core/[cbor, hash]
import ../src/logos_core/iface/surface
import ../src/logos_core/codegen/nimgen
from ../src/logos_core/iface/outcome as oc import nil
import ./support/[specdata, genfixtures]
import
  ./generated/[meter_module_types, sensor_module_types, recursive_types, demo_types]

proc diag(s: string): seq[byte] =
  let v = parseDiag(s)
  if v.isErr:
    checkpoint v.error
  encodeCbor(v.get)

suite "ifc.nim-types: generated modules (D29)":
  test "the committed lcn-gen output is current (run `nimble regen` if not)":
    check generatedCommon().get == readFile(commonTypesPath)
    for f in nimFixtures:
      checkpoint f.module
      check f.generated.get == readFile(f.fixturePath)

  test "every generated module carries the provisional stamp":
    check "PROVISIONAL (spec f4f83471)" in readFile(commonTypesPath)
    for f in nimFixtures:
      check "PROVISIONAL (spec f4f83471)" in readFile(f.fixturePath)

  test "names Nim cannot tell apart are refused":
    # C keeps `logos_demo_a_b_t` and `logos_demo_ab_t` apart; Nim's identifier
    # equality does not.
    let s = acceptContractSet("demo.a_b = uint64\ndemo.ab = uint64\n").get
    let r = nimModule(s)
    check r.isErr
    check "Nim identifier collision" in r.error

suite "ifc.nim-types: checked codecs":
  test "[IFC-0362] [IFC-0364] §3.9.1 values round-trip as deterministic CBOR":
    let r = MeterReading(label: Opt.some("kitchen"), value: 42)
    let bytes = encode(r).get
    check bytes == diag("""{"label": "kitchen", "value": 42}""")
    let back = MeterReading.decode(bytes).get
    check back.label == Opt.some("kitchen")
    check back.value == 42
    check MeterReading.decode(diag("""{"value": 1}""")).get.label.isNone
    let resp = MeterReadResponse(label: "a", reading: MeterReading(value: 1))
    check encode(resp).get == diag("""{"label": "a", "reading": {"value": 1}}""")
    # The generated validator enforces `tstr .size (1..64)` (INTERFACE §2.2).
    check encode(MeterReadResponse(label: "", reading: MeterReading(value: 1))).isErr
    check encode(MeterReadResponse(label: 'x'.repeat(65), reading: MeterReading())).isErr

  test "[IFC-0125] decoders reject integers outside the declared width":
    check MeterReadRequest.decode(diag("""{"channel": 4294967295}""")).get.channel ==
      4294967295'u32
    check MeterReadRequest.decode(diag("""{"channel": 4294967296}""")).isErr
    check MeterReadRequest.decode(diag("""{"channel": -1}""")).isErr

  test "[IFC-0126] [IFC-0127] text holding U+0000 is rejected both ways":
    let v = cborMap((cbor("label"), cbor("a\0b")), (cbor("value"), cbor(1'u64)))
    check MeterReading.decode(encodeCbor(v)).isErr
    check MeterReading.fromCbor(v).isErr
    check encode(MeterReading(label: Opt.some("a\0b"), value: 1)).isErr

  test "[IFC-0141] [IFC-0151] encoders always emit the literal; decoders reject another":
    var s = SensorControlSettings(limit: 3)
    check s.kind == "sensor"
    let want = diag("""{"kind": "sensor", "limit": 3}""")
    check encode(s).get == want
    s.kind = "other"
    check encode(s).get == want
    check SensorControlSettings.decode(diag("""{"kind": "other", "limit": 3}""")).isErr
    check SensorControlSettings.decode(diag("""{"limit": 3}""")).isErr
    # A tagged map union: the arm's literal tag is emitted and checked.
    var dir = DemoEntryArm1Map(path: "/", entries: @["x"])
    dir.kind = "file"
    check encode(DemoEntry(kind: DemoEntryKind.arm1, arm1: dir)).get ==
      diag("""{"entries": ["x"], "kind": "dir", "path": "/"}""")

  test "decoders take only one deterministic-CBOR item (INTERFACE §4.4)":
    # Keys out of order, then a trailing byte.
    check MeterReading.decode(hexBytes("a2 6576616c7565 01 656c6162656c 6161")).isErr
    check MeterReading.decode(diag("""{"value": 1}""") & @[0x00'u8]).isErr
    check MeterReading.decode(diag("""{"value": 1, "extra": 2}""")).isErr

  test "[IFC-0384] [IFC-0386] §3.9.3 recursive values are boxed and round-trip":
    let n = RecursiveNode(next: Opt.some(boxed(RecursiveNode(value: 2))), value: 1)
    let bytes = encode(n).get
    check bytes == diag("""{"next": {"value": 2}, "value": 1}""")
    let back = RecursiveNode.decode(bytes).get
    check back.next.get[].value == 2
    check encode(back).get == bytes
    let left = RecursiveLeft(
      right: Opt.some(boxed(RecursiveRight(left: Opt.some(boxed(RecursiveLeft())))))
    )
    check encode(left).get == diag("""{"right": {"left": {}}}""")
    let branch = RecursiveBranch(node: RecursiveNode(value: 9))
    check RecursiveBranch.decode(encode(branch).get).get.node.value == 9

  test "[IFC-0142] [IFC-0145] [IFC-0146] [IFC-0148] choices decode by the selection plan, in canonical arm order":
    check DemoValue.decode(diag("true")).get.kind == DemoValueKind.arm0
    check DemoValue.decode(diag("\"s\"")).get.arm1 == "s"
    check DemoValue.decode(diag("7")).get.arm2 == 7
    check DemoValue.decode(diag("-1")).isErr
    let file = DemoEntry.decode(diag("""{"kind": "file", "path": "/a"}""")).get
    check file.kind == DemoEntryKind.arm0
    check file.arm0.path == "/a"
    check DemoEntry.decode(diag("""{"kind": "dir", "path": "/a"}""")).isErr
    let rec = DemoRecord.decode(diag("""{"sub": {"inner": "x"}}""")).get
    check rec.sub.inner.kind == DemoRecordSubInnerChoiceKind.arm0
    check rec.sub.inner.arm0 == "x"

  test "every Nim shape round-trips: tuples, lists, sized bytes, common types, keywords":
    var k = DemoK(
      d: newSeq[byte](32),
      e: @[@[1'u8, 2, 3, 4]],
      f: @[(1'u64, "a")],
      g: DemoKGChoice(kind: DemoKGChoiceKind.arm1, arm1: (1'u64, 2'u64)),
      h: Opt.some((5'u64, @[9'u8])),
      i: SchemaCommitment(schema_root: newSeq[byte](32)),
      m: -3,
      n: 65535,
      o: 7,
      p: ErrorCode.ecTimeout,
      q: @[1'u8],
      `type`: @["ab"],
    )
    let bytes = encode(k).get
    let back = DemoK.decode(bytes).get
    check encode(back).get == bytes
    check back.a == 7
    check back.b == low(int64)
    check back.c == "é1"
    check back.g.arm1 == (1'u64, 2'u64)
    check back.h.get == (5'u64, @[9'u8])
    check back.p == ErrorCode.ecTimeout
    check back.`type` == @["ab"]
    # Sizes, ranges and lengths are checked on encode as well.
    k.e = @[@[1'u8, 2, 3]]
    check encode(k).isErr
    k.e = @[]
    k.`type` = @["123456789"]
    check encode(k).isErr
    k.`type` = @[]
    k.q = @[]
    check encode(k).isErr
    k.q = @[1'u8]
    k.l = @[0'u8]
    check encode(k).isErr
    k.l = @[]
    k.g = DemoKGChoice(kind: DemoKGChoiceKind.arm2, arm2: DemoV(x: 4))
    check DemoK.decode(encode(k).get).get.g.arm2.x == 4
    let tree = DemoTree(
      kids: @[DemoTree()],
      left: Opt.some(boxed(DemoTree())),
      twin: Opt.some(boxed((boxed(DemoTree()), 3'u64))),
    )
    let tb = encode(tree).get
    check tb ==
      diag(
        """{"kids": [{"kids": [], "tag": "leaf"}], "left": {"kids": [], "tag": "leaf"},
            "tag": "leaf", "twin": [{"kids": [], "tag": "leaf"}, 3]}"""
      )
    check encode(DemoTree.decode(tb).get).get == tb

suite "ifc.nim-types: the common schema (INTERFACE §5.1)":
  test "logos.invalid_params_detail agrees with the hand-written encoder":
    let d = InvalidParamsDetail(
      reason: InvalidParamsReason(kind: InvalidParamsReasonKind.arm1),
      path: Opt.some(
        @[
          InvalidParamsPathSegment(kind: InvalidParamsPathSegmentKind.arm0, arm0: "x"),
          InvalidParamsPathSegment(kind: InvalidParamsPathSegmentKind.arm1, arm1: 2),
        ]
      ),
    )
    check encode(d).get ==
      oc.invalidParamsDetail(oc.iprSchemaMismatch, Opt.some(@[cbor("x"), cbor(2'u64)]))
    for reason in [oc.iprMalformedCbor, oc.iprNonDeterministicCbor]:
      let back = InvalidParamsDetail.decode(oc.invalidParamsDetail(reason)).get
      check back.path.isNone
      check encode(back).get == oc.invalidParamsDetail(reason)

  test "logos.schema_commitment and logos.schema_response agree with surface.nim":
    let s = acceptContractSet(
      mirror("IFC/3.9.2.module.cddl"),
      [mirror("IFC/3.9.2.interface.cddl")],
      [mirror("IFC/3.9.2.supporting.cddl")],
    ).get
    let root = s.primary.root
    check encode(SchemaCommitment(schema_root: @root)).get ==
      encodeCbor(schemaCommitment(root))
    check encode(SchemaCommitment(schema_root: @root[0 .. 30])).isErr
    let resp = encodeCbor(schemaResponse(s, root).get)
    let r = SchemaResponse.decode(resp).get
    check r.interface_schemas.len == 1
    check r.interface_schemas[0].namespace == "metrics_provider"
    check r.supporting_schemas[0].commitment.schema_root == @(s.supporting[0].root)
    check encode(r).get == resp
