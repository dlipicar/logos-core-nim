## The execution boundary does not change the contract (Tier 4b step 4b-3,
## part 4b-3.4; DECISIONS I91; plan §4.3; INTERFACE Abstract l.52-66; RUNTIME
## l.51-53, l.161, l.970): the case table of `support/invariance.nim` is run
## by `probe_module`, the consumer, through one route handle to a kit provider,
## in four placements: each of the two `direct_dynamic` or `hosted_dynamic`,
## the same libraries either way. A route with a hosted end is local-transport
## (G272), so the placements cover a direct route, the Runtime's own endpoint,
## a hosted provider's endpoint and a hosted consumer's handle.
##
## Every answer (code, message, validation detail, response bytes), every
## delivery (subscription, event name, data, in order) and every completion of
## an asynchronous call is compared with the direct run, as is the route's
## selected contract. A subscription's id is not compared: it names the
## subscription to its consumer only. After every case no host is left.

when defined(posix):
  import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
  import unittest2
  import ../src/logos_core/runtime/engine
  import ../src/logos_core/abi/types
  import ../src/logos_core/cbor
  import ../src/logos_core/cbor/decode
  import ../src/logos_core/commitment
  import ../src/logos_core/crypto/blake3
  import ../src/logos_core/iface/[accept, outcome, surface]
  import ../src/logos_core/iface/common_types
  import ../src/logos_core/pins
  from ../src/logos_core/transport/io/api import defaultTransportConfig
  import ./support/[invariance, kitbuild, kitruntime, modulehostbuild, shortdir]
  import ./support/testdirs
  import ./kit/meter_impl
  import ./generated/[meter_module_calls, meter_module_types]

  let
    repo = currentSourcePath().parentDir.parentDir
    work = repo / "build" / "boundary-invariance" / kitVariant
  removeDir(work)
  createDir(work)

  include ./support/routefixture

  let shortBase = makeShortBase("lcnbi", "/e999/12345678/logos_shapes_module.sock")

  const
    RuntimeId = "5d0c9a7e-3b21-4f68-a0d4-9e1f7c2b6a85"
      ## every engine: a caller's address is the same in each placement
    SanitizerEnv =
      ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
    Depth = MinMaxDepth ## `max_payload_depth`: the depth cases stay small
    Answer = 60 * Slow
      ## [IMPL] seconds: bounds a wait for the probe's answer or a note, which
      ## always come. With a hosted consumer and a hosted provider, a
      ## materialization and a call that publishes an Event (three carrier
      ## round trips more) took about 0.2 s with orc on an idle Mac, and more
      ## than the 30 s this replaces on a CI runner under x86 MSan with three
      ## other suites beside it (2026-11-15), so that a late answer was read
      ## as the next command's.

  let
    hostProgram = moduleHostProgram()
    probeLib = buildKitLibrary("probe_impl.nim", "probe")
    shapesSet =
      acceptContractSet(readFile(repo / fixtureDir / "shapes_module.cddl")).tryGet
    shapesRoot = shapesSet.primary.root
    shapesSchema = encodeCbor(schemaResponse(shapesSet, shapesRoot).tryGet)

  proc digestOf(path: string): array[32, byte] =
    var h: Blake3Hasher
    h.init()
    let bytes = readFile(path)
    h.update(bytes.toOpenArrayByte(0, bytes.high))
    h.finish()

  let probeDigest = digestOf(probeLib)

  type Placement = object
    consumerHosted, providerHosted: bool

  func `$`(p: Placement): string =
    (if p.consumerHosted: "hosted" else: "direct") & " consumer -> " &
      (if p.providerHosted: "hosted" else: "direct") & " provider"

  const Placements = [
    Placement(consumerHosted: false, providerHosted: false),
    Placement(consumerHosted: false, providerHosted: true),
    Placement(consumerHosted: true, providerHosted: false),
    Placement(consumerHosted: true, providerHosted: true),
  ]

  proc boundaryConfig(): EngineConfig =
    ## The fixture's configuration with a Module Host, a state root, a short
    ## endpoint directory, one Runtime id and the smallest payload depth.
    result = config()
    result.runtimeInstanceId = RuntimeId
    result.stateRoot = Opt.some(result.workDir / "state")
    result.moduleHost = Opt.some(hostProgram)
    result.moduleHostEnv = @SanitizerEnv
    result.endpointDir = shortBase / ("e" & $engines)
    result.maxPayloadDepth = Depth
    # [IMPL] The Hello and admission deadlines only bound how long the route's
    # own Hello and frames take, the rest of the transport configuration as
    # given. They are what a direct consumer's materialization waits on, and
    # one failed on a CI runner where this suite's build alone took nine
    # minutes (2026-11-15). The Hello's is `Answer`, as in test_wipe_routes
    # `hostedConfig`: a hosted provider's Hello crosses the carrier both ways,
    # since the Runtime judges it, about 1 s under MemorySanitizer on an idle
    # host, and test_wipe_routes' passed 15 s on a loaded CI runner (CI on
    # 5887c5a). The admission deadline is scaled by `Slow`.
    var transport = defaultTransportConfig()
    transport.helloTimeout = int64(Answer) * 1_000_000_000 # ns
    transport.admissionTimeout *= int64(Slow)
    result.transport = Opt.some(transport)

  proc record(
      module, lib: string, hosted: bool, state: string, contract = Opt.none(Digest)
  ): ModuleRecord =
    ModuleRecord(
      module: module,
      strategy: (if hosted: stHostedDynamic else: stDirectDynamic),
      placement: (if hosted: "process" else: ""),
      artifact: ArtifactRecord(
        id: lastPathPart(lib),
        localPath: lib,
        hash: digestOf(lib),
        hashSuite: HashSuiteId,
      ),
      primaryContract: contract,
      stateAssignment: Opt.some(state),
    )

  proc unhexOf(s: string): seq[byte] =
    var i = 0
    while i + 1 < s.len:
      result.add(byte(parseHexInt(s[i .. i + 1])))
      i += 2

  proc linesOf(dir, file: string): seq[string] =
    try:
      readFile(dir / file).splitLines.filterIt(it.len > 0)
    except IOError:
      @[]

  type Consumer = object ## The probe's command files.
    dir: string
    n: int

  proc post(c: var Consumer, line: string): int =
    inc c.n
    let path = c.dir / ("cmd-" & $c.n)
    writeFile(path & ".tmp", line)
    moveFile(path & ".tmp", path)
    c.n

  proc run(c: var Consumer, line: string): string =
    ## The probe's answer to `line`; `none` if it gave none in time.
    let path = c.dir / ("out-" & $c.post(line))
    if not waitUntil(
      proc(): bool =
        fileExists(path),
      Answer,
    ):
      return "none"
    readFile(path)

  proc noted(dir, file: string, n: int): bool =
    waitUntil(
      proc(): bool =
        linesOf(dir, file).len >= n,
      Answer,
    )

  proc noHostLeft(): bool =
    waitUntil(
      proc(): bool =
        hostPids(hostProgram).len == 0
    )

  proc observe(s: Script, at: Placement): seq[string] =
    ## What the probe saw running `s` in placement `at`: the route's selected
    ## contract, each line with its answer, then the deliveries and the
    ## completions.
    let cfg = boundaryConfig()
    let (root, schema) =
      if s.module == "shapes_module":
        (shapesRoot, shapesSchema)
      else:
        (meterRoot, meterSchema)
    let lib = buildKitLibrary(s.kit, "bi" & s.kit.split('.')[0])
    createDir(cfg.stateRoot.get / "m")
    var c = Consumer(dir: cfg.stateRoot.get / "c")
    createDir(c.dir)
    writeFile(c.dir / "probe.cmd", "serve\n")
    let e = fixtureEngine(cfg)
    check e.started(record(s.module, lib, at.providerHosted, "m", Opt.some(root)), "m").state ==
      msReady
    check e.started(record("probe_module", probeLib, at.consumerHosted, "c"), "c").state ==
      msReady
    let est = c.run("rc establish_route " & hexOf(establishReq("k", root)))
    check est.startsWith("0 ")
    let resp =
      LogosNSRuntimeControlEstablishRouteResponse.decode(unhexOf(est.split(' ', 1)[1]))
    check resp.isOk
    if resp.isErr:
      e.finish()
      return
    let rec = resp.get.routes[0]
    result.add("selected " & hexOf(encode(rec.expected_contract.get).tryGet))
    result.add(
      c.run("materialize 0 " & rec.route & " " & hexOf(root) & " " & hexOf(schema))
    )
    var sub = ""
    for line in s.lines:
      let w = line.splitWhitespace
      case w[0]
      of "wait-deliveries":
        check noted(c.dir, "deliveries", parseInt(w[1]))
      of "wait-done":
        check noted(c.dir, "done", parseInt(w[1]))
      else:
        var answer = c.run(line.replace("{sub}", sub))
        if w[0] == "subscribe" and answer.startsWith("0 "):
          sub = answer[2 ..^ 1]
          answer = "0 sub"
        result.add(line & " => " & answer)
    check noted(c.dir, "deliveries", s.deliveries)
    check noted(c.dir, "done", s.completions)
    sleep(50 * Slow) # nothing more arrives
    for d in linesOf(c.dir, "deliveries"):
      result.add("delivered " & d)
    for d in linesOf(c.dir, "done"):
      result.add("completed " & d)
    check c.run("release 0") == "0 "
    check linesOf(c.dir, "ends").len == 0
    e.finish()
    check noHostLeft()

  proc compare(s: Script) =
    let direct = observe(s, Placements[0])
    check direct.len > 0
    for at in Placements[1 .. ^1]:
      checkpoint $at
      let got = observe(s, at)
      check got.len == direct.len
      for i in 0 ..< min(got.len, direct.len):
        if got[i] != direct[i]:
          checkpoint "direct: " & direct[i]
          checkpoint "here:   " & got[i]
        check got[i] == direct[i]

  suite "run.boundary: the contract does not change with the execution boundary (INTERFACE Abstract; RUNTIME l.51-53, l.161, l.970)":
    teardown:
      leftover()
      check noHostLeft()

    test "[RUN-0007] [RUN-0008] [RUN-0014] [RUN-0181] [IFC-0007] [IFC-0008] [IFC-0009] [IFC-0011] [IFC-0012] [IFC-0013] [IFC-0014] [IFC-0015] the meter kit: calls, introspection, validation, failures, events and asynchronous calls are the same in four placements":
      compare(meterScript())

    test "[RUN-0181] [IFC-0011] [IFC-0014] a deferred provider (INTERFACE §2.9.2): the same in four placements":
      compare(deferredScript())

    test "[RUN-0181] [IFC-0013] [IFC-0014] [IFC-0923] the shapes kit: every C shape, a value outside the schema and the payload depth limit are the same in four placements":
      compare(shapesScript(Depth))
