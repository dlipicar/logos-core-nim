## `lcn.storage_fetch` under a test Runtime [DECISIONS G395; G91, G136] (`sdk/docs/
## STORAGE-FETCH.md`): the SDK's conformance harness (`logos_sdk/testing/storagefetch`) against
## the reference fake (`fetch_fake_module`) realized `direct_static` and `hosted_dynamic`, called by
## the route fixture's client module through four route handles that subscribe, the fake's
## readiness driven through a fifth route to its own contract; and the Package Manager's data
## path (C1; plan §2.2): a hosted consumer (`probe_module`) reads a 4 MiB object from the hosted
## fake, and P-13's carrier trace finds none of its bytes in a frame of either host.

import std/[atomics, monotimes, os, sequtils, strutils, tables, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import logos_sdk/abi/[checks, types]
import ../src/logos_core/runtime/[invoke, remotemarked, routes]
import ./support/rcaddresses
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/iface/[accept, outcome, provider, surface]
import logos_sdk/codegen/common_types
import logos_sdk/pins
import logos_sdk/testing/[kitbuild, kitruntime, storagefetch]
import logos_sdk/testing/fixtures/[meter_impl, fetch_fake_impl]
import logos_sdk/testing/generated/meter_module_calls
import logos_sdk/contracts/generated/lcn_storage_fetch_root
from logos_sdk/testing/generated/fetch_fake_module_calls import
  invoke, FetchFakeSetReadinessRequest, FetchFakeSetReadinessRequestReadinessChoice,
  FetchFakeSetReadinessRequestReadinessChoiceKind, FetchFakeSetFaultRequest

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "storage-fetch" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

let
  contractDoc = readFile(repo / "sdk/src/logos_sdk/contracts/lcn_storage_fetch.cddl")
  fetchSet = acceptContractSet(contractDoc).tryGet
  fetchSchema = encodeCbor(schemaResponse(fetchSet, LcnStorageFetchRoot).tryGet)
  fakeSet = acceptContractSet(
    readFile(repo / "sdk/src/logos_sdk/testing/fixtures/fetch_fake_module.cddl"),
    [contractDoc],
  ).tryGet
  fakeRoot = fakeSet.primary.root
  fakeSchema = encodeCbor(schemaResponse(fakeSet, fakeRoot).tryGet)
  fakeReg = checkStaticRegistration("fetchfake", fetchFakeModuleStaticSymbols()).tryGet
  big = fakeLocator(3 * 1_048_576 + 7, "big")
  small = fakeLocator(1000, "small")
  fixture = FetchFixture(
    objects: @[objectOf(big, fakeObject(big)), objectOf(small, fakeObject(small))],
    absent: fakeLocator(10, AbsentPrefix & "x"),
  )

proc fakeRecord(): ModuleRecord =
  ModuleRecord(
    module: "fetch_fake_module",
    strategy: stDirectStatic,
    binding: "fetchfake",
    primaryContract: Opt.some(fakeRoot),
    implements: @[LcnStorageFetchRoot],
  )

# The client's handles: four to the contract, one to the fake's own methods. Each is a route
# of its own, so a hosted provider's ticket is used once (G258).
var
  fetchHandles: array[4, LogosRouteHandle]
  driverHandle: LogosRouteHandle

proc materializeAll(rc: ptr LogosRuntimeControlBinding, prefix: string): bool =
  for i in 0 .. 3:
    let made = rc.establish(prefix & $i, LcnStorageFetchRoot)
    if made.code != ecOk:
      return false
    let (code, h) =
      rc.materialize(made.routesOf.routes[0].route, LcnStorageFetchRoot, fetchSchema)
    if code != ecOk:
      return false
    fetchHandles[i] = h
  let made = rc.establish(prefix & "-driver", fakeRoot)
  if made.code != ecOk:
    return false
  let (code, h) = rc.materialize(made.routesOf.routes[0].route, fakeRoot, fakeSchema)
  driverHandle = h
  code == ecOk

proc releaseAll() =
  for h in fetchHandles.mitems:
    if h.vtable != nil:
      h.release()
    h = LogosRouteHandle()
  if driverHandle.vtable != nil:
    driverHandle.release()
  driverHandle = LogosRouteHandle()

proc drive(
    to: FetchReadiness, held: seq[seq[byte]]
): Result[void, string] {.gcsafe, raises: [].} =
  ## The fake's `set_readiness`, through the driver's route.
  type K = FetchFakeSetReadinessRequestReadinessChoiceKind
  let kind =
    case to
    of FetchReadiness.Starting: K.Starting
    of FetchReadiness.Ready: K.Ready
    of FetchReadiness.Offline: K.Offline
  {.cast(gcsafe).}:
    let r = invoke(
      addr driverHandle,
      FetchFakeSetReadinessRequest(
        readiness: FetchFakeSetReadinessRequestReadinessChoice(kind: kind), held: held
      ),
    )
  if r.isErr:
    err("set_readiness: " & $r.error.code)
  else:
    ok()

proc target(): FetchTarget =
  FetchTarget(
    handles: @[
      addr fetchHandles[0],
      addr fetchHandles[1],
      addr fetchHandles[2],
      addr fetchHandles[3],
    ],
    subscribes: true,
    drive: Opt.some(ReadinessDriver(drive)),
    wait: initDuration(seconds = 30 * Slow),
  )

proc harness(): seq[string] =
  ## The readiness checks (the fake starts `starting` and is left `ready`), then the call
  ## checks, then the fake's injected fault: `unavailable` once, then the same offset reads.
  result = readinessChecks(target(), fixture) & callChecks(target(), fixture)
  let h = addr fetchHandles[0]
  {.cast(gcsafe).}:
    let fault = invoke(
      addr driverHandle,
      FetchFakeSetFaultRequest(`object`: big, unavailable: 1, delay_ms: 0),
    )
  if fault.isErr:
    result.add("set_fault failed")
  let offset = uint64(MaxReadLength)
  let first = h.read(big, offset, 16)
  if first.isErr or first.get.failureOf != Opt.some(FetchFailure.Unavailable):
    result.add("the injected fault did not answer unavailable")
  let again = h.read(big, offset, 16)
  if again.isErr or again.get.failureOf.isSome or
      again.get.arm_Map_data.data != fakeObject(big)[int(offset) ..< int(offset) + 16]:
    result.add("the read after the fault did not resume at its offset")

suite "lcn.storage_fetch under a test Runtime (G395)":
  teardown:
    releaseAll()
    leftover()

  test "[IMPL-DECISION G395] [IMPL-DECISION G136] the harness against the fake realized direct_static: calls, readiness events through subscriptions, the injected fault":
    let e = fixtureEngine(config(extra = @[fakeReg]))
    discard e.started(fakeRecord(), "f")
    let (_, rc) = e.startClient("c")
    check rc.materializeAll("d")
    let problems = harness()
    for p in problems:
      checkpoint p
    check problems.len == 0
    releaseAll()
    e.finish()

when defined(posix):
  import ./support/[modulehostbuild, shortdir]
  import logos_sdk/crypto/blake3
  from ./support/trnowner import fastConfig, Ms
  from ../src/logos_core/runtime/hostsup import traceMarkers, traced

  const
    SanitizerEnv =
      ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
    Answer = 60 * Slow ## seconds: bounds a wait for the probe's answer

  let
    hostProgram = moduleHostProgram()
    fakeLib = buildKitLibrary("fetch_fake_impl.nim", "sffake")
    probeLib = buildKitLibrary("probe_impl.nim", "sfprobe")
    shortBase = makeShortBase("lcnsf", "/e999/12345678/logos_fetch_fake_module.sock")

  proc digestOf(path: string): array[32, byte] =
    let bytes = readFile(path)
    blake3(bytes.toOpenArrayByte(0, bytes.high))

  let
    fakeDigest = digestOf(fakeLib)
    probeDigest = digestOf(probeLib)

  proc hosted(): EngineConfig =
    ## `config` with a state root, the Module Host program and a short endpoint directory,
    ## as `test_hosted_routes` makes it; Hello and admission deadlines no case here is about.
    result = config(extra = @[fakeReg])
    result.stateRoot = Opt.some(result.workDir / "state")
    result.moduleHost = Opt.some(hostProgram)
    result.moduleHostEnv = @SanitizerEnv
    result.endpointDir = shortBase / ("e" & $engines)
    var t = fastConfig()
    t.helloTimeout = int64(Answer) * 1000 * Ms
    t.admissionTimeout = int64(Answer) * 1000 * Ms
    result.transport = Opt.some(t)
    result.shutdownGrace = initDuration(seconds = 10 * Slow)

  proc stateDir(cfg: EngineConfig, state: string): string =
    result = cfg.stateRoot.get / state
    createDir(result)

  proc hostedFake(): ModuleRecord =
    ModuleRecord(
      module: "fetch_fake_module",
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: "fetchfake", localPath: fakeLib, hash: fakeDigest, hashSuite: HashSuiteId
      ),
      primaryContract: Opt.some(fakeRoot),
      implements: @[LcnStorageFetchRoot],
      stateAssignment: Opt.some("f"),
    )

  proc hostedProbe(): ModuleRecord =
    ModuleRecord(
      module: "probe_module",
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: "probe", localPath: probeLib, hash: probeDigest, hashSuite: HashSuiteId
      ),
      stateAssignment: Opt.some("p"),
    )

  # The probe's command files (`tests/kit/probe_impl.nim`), as `test_hosted_routes` writes
  # them: `cmd-<n>` in, `out-<n>` back, `<code> <hex value or message>`.
  type Probe = object
    dir: string
    n: int

  func hexOf(b: openArray[byte]): string =
    for x in b:
      result.add(toHex(x, 2).toLowerAscii)

  proc unhexOf(s: string): seq[byte] =
    result = newSeqOfCap[byte](s.len div 2)
    var i = 0
    while i + 1 < s.len:
      result.add(byte(parseHexInt(s[i .. i + 1])))
      i += 2

  proc run(p: var Probe, line: string): (string, seq[byte]) =
    ## The probe's code and value for one command; ("none", @[]) if it gave none in time.
    inc p.n
    let path = p.dir / ("cmd-" & $p.n)
    writeFile(path & ".tmp", line)
    moveFile(path & ".tmp", path)
    let answer = p.dir / ("out-" & $p.n)
    if not waitUntil(
      proc(): bool =
        fileExists(answer),
      Answer,
    ):
      return ("none", @[])
    let w = readFile(answer).split(' ', 1)
    (w[0], (if w[0] == "0" and w.len > 1: unhexOf(w[1].strip)
      else: @[]))

  suite "lcn.storage_fetch with hosted modules (G395; C1)":
    teardown:
      releaseAll()
      leftover()

    test "[IMPL-DECISION G395] [IMPL-DECISION G136] the harness against the fake realized hosted_dynamic, called from the test's client":
      let cfg = hosted()
      discard cfg.stateDir("f")
      let e = fixtureEngine(cfg)
      discard e.started(hostedFake(), "hf")
      let (_, rc) = e.startClient("c")
      check rc.materializeAll("h")
      let problems = harness()
      for p in problems:
        checkpoint p
      check problems.len == 0
      releaseAll()
      e.finish()

    test "[RUN-0815] [IMPL-DECISION G395] hosted to hosted: the probe reads a 4 MiB object from the fake in four calls, and no carrier frame holds its bytes or its request":
      let cfg = hosted()
      discard cfg.stateDir("f")
      var probe = Probe(dir: cfg.stateDir("p"))
      writeFile(probe.dir / "probe.cmd", "serve\n")
      let e = fixtureEngine(cfg)
      discard e.started(hostedFake(), "hf")
      discard e.started(hostedProbe(), "probe")
      # The test's client makes the fake ready; the probe reads.
      let (_, rc) = e.startClient("c")
      check rc.materializeAll("h")
      check drive(FetchReadiness.Ready, @[]).isOk
      const Mi = 1_048_576
      let locator = fakeLocator(4 * Mi, "hosted-to-hosted")
      let whole = fakeObject(locator)
      let (made, routeBytes) =
        probe.run("rc establish_route " & hexOf(establishReq("p", LcnStorageFetchRoot)))
      check made == "0"
      let routes = LogosNSRuntimeControlEstablishRouteResponse.decode(routeBytes)
      check routes.isOk
      if routes.isOk:
        let route = routes.get.routes[0].route
        check probe.run(
          "materialize 0 " & route & " " & hexOf(LcnStorageFetchRoot) & " " &
            hexOf(fetchSchema)
        )[0] == "0"
        # [plan §3.1.6] Markers: the locator (the request's payload) and a slice of each
        # MiB the four responses carry.
        var marks = @[locator]
        for i in 0 .. 3:
          marks.add(whole[i * Mi + 4096 ..< i * Mi + 4096 + 32])
        traceMarkers(marks)
        var got: seq[byte]
        for i in 0 .. 3:
          let params = encode(
            LcnNSStorageFetchReadObjectRequest(
              `object`: locator, offset: uint64(i * Mi), length: MaxReadLength
            )
          ).tryGet
          let (code, value) = probe.run("call 0 read_object " & hexOf(params))
          check code == "0"
          let r = LcnNSStorageFetchReadObjectResponse.decode(value)
          check r.isOk and r.get.failureOf.isNone
          if r.isOk and r.get.failureOf.isNone:
            got.add(r.get.arm_Map_data.data)
        check got.len == whole.len
        check got == whole
        let (frames, hits) = traced()
        check frames > 0
        check hits == 0
        # The trace sees what does cross: the method name of each dispatch.
        traceMarkers([bytesOf("read_object")])
        check probe.run(
          "call 0 read_object " &
            hexOf(
              encode(
                LcnNSStorageFetchReadObjectRequest(
                  `object`: locator, offset: 0, length: 1
                )
              ).tryGet
            )
        )[0] == "0"
        check traced().hits > 0
        traceMarkers([])
        discard probe.run("release 0")
      releaseAll()
      e.finish()
