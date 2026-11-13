## lcn-gen's Nim output [D29]: the committed modules are current, and the
## generated codecs round-trip, check every value against the schema, and agree
## with the hand-written INTERFACE §5.1 encoders.

import std/[atomics, os, osproc, strutils, typedthreads]
import unittest2
import ../src/logos_core/[cbor, hash, pins]
import ../src/logos_core/iface/surface
import ../src/logos_core/base/perthread
import ../src/logos_core/codegen/nimgen
from ../src/logos_core/iface/outcome as oc import nil
import ../src/logos_core/authority/[policy_types, logos_capability_authority_types]
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
    check generatedCommonMirrors().get == readFile(commonMirrorsPath)
    check generatedRcTypes().get == readFile(rcTypesPath)
    check generatedHostConfigTypes().get == readFile(hostConfigTypesPath)
    check generatedStoreTypes().get == readFile(storeTypesPath)
    check generatedCaTypes().get == readFile(caTypesPath)
    check generatedCaKit().get == readFile(caKitPath)
    check generatedLdrTypes().get == readFile(ldrTypesPath)
    check generatedLdrKit().get == readFile(ldrKitPath)
    check generatedPolicyTypes().get == readFile(policyTypesPath)
    check generatedStateTypes().get == readFile(stateTypesPath)
    for f in nimFixtures:
      checkpoint f.module
      check f.generated.get == readFile(f.fixturePath)
    for f in headerFixtures:
      checkpoint f.header
      check f.generated.get == readFile(f.fixturePath)

  test "every generated module carries the provisional stamp of the pinned spec":
    let stamp = "PROVISIONAL (spec " & SpecRevision[0 .. 7] & ")"
    check stamp in readFile(commonTypesPath)
    check stamp in readFile(commonMirrorsPath)
    check stamp in readFile(rcTypesPath)
    check stamp in readFile(hostConfigTypesPath)
    check stamp in readFile(storeTypesPath)
    for path in [
      caTypesPath, caKitPath, ldrTypesPath, ldrKitPath, policyTypesPath, stateTypesPath
    ]:
      checkpoint path
      check stamp in readFile(path)
    for f in nimFixtures:
      check stamp in readFile(f.fixturePath)

  test "[IMPL] the policy's lcn.ap_commitment repeats logos.capability_authority.commitment_requirements":
    # policy.cddl names no CA type (DECISIONS I84): its commitment map is a
    # copy, and both must take and make the same bytes.
    check "logos.capability_authority.commitment_retention = \"retain-root\"" in
      readFile("spec/mirrors/CAP/4.commitments.cddl")
    for value in [
      "{}", "{\"request\": \"retain-root\"}", "{\"response\": \"retain-root\"}",
      "{\"request\": \"retain-root\", \"response\": \"retain-root\"}",
      "{\"request\": \"keep\"}", "{\"other\": 1}",
    ]:
      checkpoint value
      let bytes = diag(value)
      let a = decode(LcnApCommitment, bytes)
      let b = decode(LogosNSCapabilityAuthorityCommitmentRequirements, bytes)
      check a.isOk == b.isOk
      if a.isOk and b.isOk:
        check encode(a.get).get == bytes
        check encode(b.get).get == bytes

  test "[IMPL] the stored module record repeats the host configuration's rules":
    # store.cddl's lcn.rs_record is lcn.app_module without `instance`, plus
    # the configuration commitment CONFIG will need (DECISIONS I82).
    proc rules(path: string): seq[(string, string)] =
      var name, body: string
      for line in readFile(path).splitLines & @[""]:
        if line.startsWith(";"):
          continue
        if line.len == 0:
          if name.len > 0:
            result.add((name, body))
          name = ""
          body = ""
        elif name.len == 0 and " =" in line:
          name = line.split(" =")[0]
          body = line.split(" =", 1)[1] & "\n"
        else:
          body.add(line & "\n")

    proc normal(body: string): string =
      for line in body.splitLines:
        let t = line.strip
        # The record keeps the accepted binding's digest; the host config
        # carries the declaration and the instance's provisioned value.
        if t.startsWith("instance:") or t.startsWith("? configuration_commitment:") or
            t.startsWith("? configuration:") or
            t.startsWith("? provisioned_configuration:"):
          continue
        result.add(t.replace("lcn.app_", "lcn.rs_") & "\n")

    var app, rs: seq[(string, string)]
    for (n, b) in rules(hostConfigPrimary):
      app.add(
        (n.replace("lcn.app_module", "lcn.rs_record").replace("lcn.app_", "lcn.rs_"), b)
      )
    rs = rules(storePrimary)
    for name in [
      "lcn.rs_record", "lcn.rs_path", "lcn.rs_implementation", "lcn.rs_artifact",
      "lcn.rs_requirement", "lcn.rs_permission",
    ]:
      checkpoint name
      var a, r: string
      for (n, b) in app:
        if n == name:
          a = normal(b)
      for (n, b) in rs:
        if n == name:
          r = normal(b)
      check a.len > 0
      check a == r

  test "names Nim cannot tell apart are refused":
    # C keeps `logos_demo_A_b_t` and `logos_demo_Ab_t` apart; Nim's identifier
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
    var s = SensorNSControlSettings(limit: 3)
    check s.kind == "sensor"
    let want = diag("""{"kind": "sensor", "limit": 3}""")
    check encode(s).get == want
    s.kind = "other"
    check encode(s).get == want
    check SensorNSControlSettings.decode(diag("""{"kind": "other", "limit": 3}""")).isErr
    check SensorNSControlSettings.decode(diag("""{"limit": 3}""")).isErr
    # A tagged map union: the arm's literal tag is emitted and checked.
    var dir = DemoEntryARDirMap(path: "/", entries: @["x"])
    dir.kind = "file"
    check encode(DemoEntry(kind: DemoEntryKind.Dir, arm_Dir: dir)).get ==
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

  test "[IFC-0142] [IFC-0145] [IFC-0146] [IFC-0148] [IFC-0642] [IFC-0643] choices decode by the selection plan; kinds follow the C labels":
    check DemoValue.decode(diag("true")).get.kind == DemoValueKind.Bool
    check DemoValue.decode(diag("\"s\"")).get.arm_Tstr == "s"
    check DemoValue.decode(diag("7")).get.arm_Uint64 == 7
    check DemoValue.decode(diag("-1")).isErr
    let file = DemoEntry.decode(diag("""{"kind": "file", "path": "/a"}""")).get
    check file.kind == DemoEntryKind.File
    check file.arm_File.path == "/a"
    check DemoEntry.decode(diag("""{"kind": "dir", "path": "/a"}""")).isErr
    # The kind is the C discriminant (labels in ASCII order: Dir 0, File 1),
    # not the canonical arm index (file 0, dir 1).
    check ord(DemoEntryKind.Dir) == 0
    check ord(DemoEntryKind.File) == 1
    let rec = DemoRecord.decode(diag("""{"sub": {"inner": "x"}}""")).get
    check rec.sub.inner.kind == DemoRecordSubInnerChoiceKind.Tstr
    check rec.sub.inner.arm_Tstr == "x"

  test "every Nim shape round-trips: tuples, lists, sized bytes, common types, keywords":
    var k = DemoK(
      d: newSeq[byte](32),
      e: @[@[1'u8, 2, 3, 4]],
      f: @[(1'u64, "a")],
      g: DemoKGChoice(kind: DemoKGChoiceKind.Tuple2, arm_Tuple2: (1'u64, 2'u64)),
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
    check back.g.arm_Tuple2 == (1'u64, 2'u64)
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
    k.g = DemoKGChoice(kind: DemoKGChoiceKind.demo_V, arm_demo_V: DemoV(x: 4))
    check DemoK.decode(encode(k).get).get.g.arm_demo_V.x == 4
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
      reason: InvalidParamsReason(kind: InvalidParamsReasonKind.Schema_mismatch),
      path: Opt.some(
        @[
          InvalidParamsPathSegment(
            kind: InvalidParamsPathSegmentKind.Tstr, arm_Tstr: "x"
          ),
          InvalidParamsPathSegment(
            kind: InvalidParamsPathSegmentKind.Uint64, arm_Uint64: 2
          ),
        ]
      ),
    )
    check encode(d).get ==
      oc.invalidParamsDetail(oc.iprSchemaMismatch, Opt.some(@[cbor("x"), cbor(2'u64)]))
    for reason in [
      oc.iprMalformedCbor, oc.iprNonDeterministicCbor, oc.iprConfigurationSchemaMismatch
    ]:
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

# Concurrency ----------------------------------------------------------------------

var concurrentFailures: Atomic[int]

proc codecWorker(seed: int) {.thread.} =
  ## Generated codecs, the pinned common schema and a library table used from
  ## one of several threads at once (`base/perthread`).
  for i in 0 ..< 200:
    let label = "t" & $seed & "-" & $i
    let r = MeterReadResponse(
      label: label, reading: MeterReading(label: Opt.some(label), value: uint64(i))
    )
    let bytes = encode(r)
    if bytes.isErr or MeterReadResponse.decode(bytes.get).get.label != label:
      concurrentFailures += 1
    if MeterReadResponse.decode(@[0x40'u8]).isOk: # not a map
      concurrentFailures += 1
    if oc.checkDetail(oc.ecInvalidParams, oc.invalidParamsDetail(oc.iprSchemaMismatch)).isErr:
      concurrentFailures += 1
    if i == 100:
      # Released halfway: the next use loads this thread's tables again.
      releasePerThread()

{.compile: "support/cthread.c".}

proc runCThread(
  fn: proc() {.cdecl, gcsafe, raises: [].}
): cint {.importc: "lcn_test_run_c_thread", cdecl.}

proc runCThreadOn(
  fn: proc() {.cdecl, gcsafe, raises: [].}, stack: csize_t
): cint {.importc: "lcn_test_run_c_thread_on", cdecl.}

var released: Atomic[int]

proc countRelease() {.nimcall, gcsafe, raises: [].} =
  released += 1

proc useTables() {.gcsafe, raises: [].} =
  if MeterReadResponse.decode(@[0x40'u8]).isOk:
    concurrentFailures += 1
  onThreadRelease(countRelease)

proc nimThreadBody() {.thread.} =
  useTables()

proc cThreadBody() {.cdecl, gcsafe, raises: [].} =
  # As the module kit's entry points: register before the first allocation.
  setupForeignThreadGc()
  enterThread()
  useTables()
  when not defined(gcDestructors):
    # Under refc a C thread releases itself (`base/perthread`).
    releasePerThread()
    tearDownForeignThreadGc()

suite "ifc.nim-types: concurrent use [IMPL]":
  test "generated codecs and library tables work from several threads at once":
    var threads: array[4, Thread[int]]
    for i in 0 ..< threads.len:
      createThread(threads[i], codecWorker, i)
    joinThreads(threads)
    check concurrentFailures.load == 0

  test "a thread's tables are released when it ends, whoever started it":
    released.store(0)
    var t: Thread[void]
    createThread(t, nimThreadBody)
    joinThread(t)
    check released.load == 1
    check runCThread(cThreadBody) == 0
    check released.load == 2
    check concurrentFailures.load == 0

# Payload depth -------------------------------------------------------------------------

const codecStack =
  # [IMPL] A macOS or iOS secondary thread's default stack (I79); instrumented
  # frames are larger, as in tests/support/typedharness.
  when defined(asan) or defined(tsan) or defined(msan):
    2048 * 1024
  else:
    512 * 1024

var deepChecks: Atomic[int]

proc chain(levels: int): RecursiveNode =
  ## `levels` nested `recursive.node` maps, numbered from the innermost.
  ## The boxed copy is a separate temporary: under refc, `n = T(f: Opt.some(g(n)))`
  ## builds `n` in place before `g` reads it (upstream draft 20).
  result = RecursiveNode(value: 0)
  for i in 1 ..< levels:
    let inner = boxed(result)
    result = RecursiveNode(next: Opt.some(inner), value: uint64(i))

proc deepCodecs() {.cdecl, gcsafe, raises: [].} =
  ## Each check that holds adds its bit to `deepChecks`.
  setupForeignThreadGc()
  enterThread()
  block:
    let bytes = encode(chain(DefaultMaxDepth))
    if bytes.isOk:
      deepChecks += 1
      let back = RecursiveNode.decode(bytes.get)
      if back.isOk:
        # Every level came back, walked without recursion.
        var levels = 1
        var same = back.get.value == uint64(DefaultMaxDepth - 1)
        var next = back.get.next
        while next.isSome:
          let node = next.get
          inc levels
          same = same and node.value == uint64(DefaultMaxDepth - levels)
          next = node.next
        if same and levels == DefaultMaxDepth and encode(back.get) == bytes:
          deepChecks += 2
    # One map more: the checked encoder and the decoder refuse it.
    let over = chain(DefaultMaxDepth + 1)
    if encode(over).isErr:
      deepChecks += 4
    if RecursiveNode.decode(encodeCbor(toCbor(over))).isErr:
      deepChecks += 8
  when not defined(gcDestructors):
    releasePerThread()
    tearDownForeignThreadGc()

suite "ifc.nim-types: payload depth [IMPL]":
  test "[IFC-0925] [IFC-0927] generated codecs convert values at the payload depth limit on a thread with 512 KiB of stack (I79)":
    deepChecks.store(0)
    check runCThreadOn(deepCodecs, csize_t(codecStack)) == 0
    check deepChecks.load == 15

suite "ifc.nim-types: lcn-gen kit with a configuration (DECISIONS I87) [IMPL]":
  test "[CFG-0068] the command line writes the committed types, configuration types and kit; its configuration options go together":
    let exe = "build/tools/lcn_gen_cli"
    let (built, code) = execCmdEx(
      quoteShellCommand(
        [
          getCurrentCompilerExe(),
          "c",
          "--hints:off",
          "--nimcache:build/nimcache/lcn_gen_cli",
          "-o:" & exe,
          "src/lcn_gen.nim",
        ]
      )
    )
    checkpoint built
    check code == 0
    let dir = "build/lcn_gen_cli"
    removeDir(dir)
    proc run(args: openArray[string]): int =
      let (output, code) =
        execCmdEx(quoteShellCommand(@[exe] & @args), options = {poStdErrToStdOut})
      checkpoint output
      code

    check run(
      [
        "kit",
        "--out:" & dir,
        "--import-prefix:" & fixturePrefix,
        "tests/kit/tuner_module.cddl",
        "--configuration:tests/kit/tuner_config.cddl",
        "--configuration-root:tuner.config",
        "--live-reconfiguration",
      ]
    ) == 0
    for name in [
      "tuner_module_types.nim", "tuner_module_configuration_types.nim",
      "tuner_module_kit.nim",
    ]:
      checkpoint name
      check readFile(dir / name) == readFile("tests/generated" / name)
    for bad in [
      @[
        "kit", "tests/kit/tuner_module.cddl",
        "--configuration:tests/kit/tuner_config.cddl",
      ],
      @["kit", "tests/kit/tuner_module.cddl", "--configuration-root:tuner.config"],
      @["kit", "tests/kit/tuner_module.cddl", "--live-reconfiguration"],
      @[
        "nim", "tests/kit/tuner_module.cddl",
        "--configuration:tests/kit/tuner_config.cddl",
        "--configuration-root:tuner.config",
      ],
      @[
        "kit",
        "--out:" & dir / "x",
        "tests/kit/tuner_module.cddl",
        "--configuration:tests/kit/tuner_config.cddl",
        "--configuration-root:tuner.nothing",
      ],
    ]:
      check run(bad) == 1
    check not dirExists(dir / "x")
