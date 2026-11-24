## `lcn.storage_fetch` under a test Runtime [DECISIONS G395; G91, G136] (`sdk/docs/
## STORAGE-FETCH.md`): the SDK's conformance harness (`logos_sdk/testing/storagefetch`) against
## the reference fake (`fetch_fake_module`) realized `direct_static` and `hosted_dynamic`, called by
## the route fixture's client module through four route handles that subscribe, the fake's
## readiness driven through a fifth route to its own contract; and the Package Manager's data
## path (C1; plan §2.2): a hosted consumer (`probe_module`) reads a 4 MiB object from the hosted
## fake, and P-13's carrier trace finds none of its bytes in a frame of either host.

import std/[atomics, monotimes, os, strutils, tables, times, typedthreads]
import unittest2
import ./support/sanitizerenv
import ../src/logos_core/runtime/engine
import logos_sdk/abi/[checks, types]
import ../src/logos_core/runtime/routes
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

proc materializeAll(
    rc: ptr LogosRuntimeControlBinding, prefix: string, driver = true
): bool =
  ## The four handles to the contract, and with `driver` the fake's own route.
  for i in 0 .. 3:
    let made = rc.establish(prefix & $i, LcnStorageFetchRoot)
    if made.code != ecOk:
      return false
    let (code, h) =
      rc.materialize(made.routesOf.routes[0].route, LcnStorageFetchRoot, fetchSchema)
    if code != ecOk:
      return false
    fetchHandles[i] = h
  if not driver:
    return true
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
    result.add("set_fault failed: " & fault.error.message.get(""))
  let offset = uint64(MaxReadLength)
  let first = h.read(big, offset, 16)
  if first.isErr:
    result.add("the injected fault: " & first.error)
  elif first.get.failureOf != Opt.some(FetchFailure.Unavailable):
    result.add("the injected fault did not answer unavailable")
  let again = h.read(big, offset, 16)
  if again.isErr:
    result.add("the read after the fault: " & again.error)
  elif again.get.failureOf.isSome or
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

  const Answer = 60 * Slow ## seconds: bounds a wait for the probe's answer

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
    ## as `test_hosted_routes` makes it; Hello and admission deadlines no case here is about,
    ## and a write-stall deadline that 1 MiB responses on four routes at once do not reach in a
    ## sanitizer build (as `transport_io_body`'s multi-MiB cases set it).
    result = config(extra = @[fakeReg])
    result.stateRoot = Opt.some(result.workDir / "state")
    result.moduleHost = Opt.some(hostProgram)
    result.moduleHostEnv = @SanitizerEnv
    result.endpointDir = shortBase / ("e" & $engines)
    var t = fastConfig()
    t.helloTimeout = int64(Answer) * 1000 * Ms
    t.admissionTimeout = int64(Answer) * 1000 * Ms
    # Every host takes the Runtime's Transport limits. fastConfig's 500 ms x Slow closed a
    # host's connection under TSan while the Runtime's reader drained four 1 MiB responses
    # (CI, 4fdc140, ubuntu-24.04-arm): no case here is about a write stall.
    t.writeStallTimeout = 10_000 * Ms * Slow
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

  const Mi = 1_048_576

  proc probeReads(probe: var Probe, locator, whole: seq[byte]) =
    ## The probe's route to the contract, then `whole` read in four 1 MiB calls under
    ## P-13's carrier trace: no frame of either host holds the locator or a slice of any
    ## MiB, while the trace does see what crosses, a dispatch's method name.
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
      let locator = fakeLocator(4 * Mi, "hosted-to-hosted")
      probe.probeReads(locator, fakeObject(locator))
      releaseAll()
      e.finish()

  # storage_module as the provider, opt in [Tier 5 step N-4.5; N-4 plan §7.2] -------------
  #
  # Core never builds or imports storage's code. `LCN_STORAGE_FETCH_PROVIDER` names the
  # bundle storage_module's `tools/fetch_bundle.nim` writes: the module library (a test
  # build, strict destroy on), its contract and configuration documents, a provisioned
  # value with no network, a state directory holding the objects, and their fixture.
  # Unset, the cases skip and say so, so core's own CI is unchanged and the skip shows.
  # The direct_static case stays the fake's: storage_module has no static build.

  import std/[json, osproc]
  import ../src/logos_core/runtime/configcheck

  const ProviderVar = "LCN_STORAGE_FETCH_PROVIDER"

  type StorageBundle = object
    dir: string
    record: ModuleRecord
    accepted: AcceptedConfiguration
    fixture: FetchFixture
    probe: seq[byte] ## the 4 MiB object's locator
    probeBytes: seq[byte] ## its bytes, which the bundle's `content` names

  proc loadBundle(dir: string): Result[StorageBundle, string] =
    ## The bundle at `dir`, refused when it was built for another core commit.
    let (head, code) =
      execCmdEx(quoteShellCommand(["git", "-C", repo, "rev-parse", "HEAD"]))
    if code != 0:
      return err("this checkout's commit: " & head)
    if not fileExists(dir / "core-commit"):
      return err(dir & " is not a provider bundle: it has no core-commit")
    let built = readFile(dir / "core-commit").strip
    if built != head.strip:
      return err(
        "the bundle at " & dir & " was built for core " & built &
          ", and this checkout is " & head.strip &
          ": rebuild it with storage_module's tools/fetch_bundle.nim"
      )
    let set = acceptContractSet(readFile(dir / "storage_module.cddl"), [contractDoc]).valueOr:
      return err("storage_module's contract: " & $error)
    let accepted = acceptConfiguration(
      bytesOf(readFile(dir / "configuration-declaration.cbor")),
      Opt.some(bytesOf(readFile(dir / "configuration.cbor"))),
    ).valueOr:
      return err("storage_module's configuration: " & error)
    let lib = dir / "lib" / (DynlibFormat % "logos_storage_module")
    if not fileExists(lib):
      return err(lib & " is missing")
    var b = StorageBundle(dir: dir, accepted: accepted)
    b.record = ModuleRecord(
      module: "storage_module",
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: "storage", localPath: lib, hash: digestOf(lib), hashSuite: HashSuiteId
      ),
      primaryContract: Opt.some(set.primary.root),
      implements: @[LcnStorageFetchRoot],
      stateAssignment: Opt.some("s"),
      configuration: Opt.some(accepted.digest),
    )
    let fx = parseJson(readFile(dir / "fixture.json"))
    for o in fx["objects"]:
      var digest: Blake3Digest
      let d = unhexOf(o["blake3"].getStr)
      if d.len != digest.len:
        return err("fixture.json: a BLAKE3 of " & $d.len & " bytes")
      for i, x in d:
        digest[i] = x
      let locator = unhexOf(o["locator"].getStr)
      b.fixture.objects.add(
        FetchObject(locator: locator, size: uint64(o["size"].getInt), digest: digest)
      )
      if o["locator"].getStr == fx["probe"].getStr:
        b.probe = locator
        b.probeBytes = fakeObject(bytesOf(o["content"].getStr))
        if blake3(b.probeBytes) != digest:
          return err("fixture.json: the probe's content is not its BLAKE3")
    b.fixture.absent = unhexOf(fx["absent"].getStr)
    if b.probe.len == 0 or b.probeBytes.len != 4 * Mi:
      return err("fixture.json names no 4 MiB probe object")
    ok(b)

  proc bundleOrSkip(): Opt[StorageBundle] =
    ## The bundle `LCN_STORAGE_FETCH_PROVIDER` names; none, after saying why, when it is
    ## unset (the caller skips) or refused (the caller fails).
    let at = getEnv(ProviderVar)
    if at.len == 0:
      echo "  [skipped] ",
        ProviderVar, " is not set: storage_module's case did not run (N-4 plan §7.2)"
      return Opt.none(StorageBundle)
    let b = loadBundle(at)
    if b.isErr:
      echo "  ", b.error
      return Opt.none(StorageBundle)
    Opt.some(b.get)

  proc startStorage(e: Engine, cfg: EngineConfig, b: StorageBundle) =
    ## storage_module from the bundle, its state directory a copy of the bundle's.
    copyDirWithPermissions(b.dir / "state", cfg.stateRoot.get / "s")
    discard e.create(b.record, "hs", configuration = Opt.some(b.accepted)).tryGet
    check e.start("hs").tryGet.state == msReady

  proc storageTarget(): FetchTarget =
    ## The four handles, no driver: storage's readiness is observed, not driven.
    result = target()
    result.drive = Opt.none(ReadinessDriver)

  suite "lcn.storage_fetch with storage_module as the provider (N-4 plan §7.2; G395, G428)":
    teardown:
      releaseAll()
      leftover()

    test "[IMPL-DECISION G395] [IMPL-DECISION G428] the harness against storage_module realized hosted_dynamic, called from the test's client":
      let at = getEnv(ProviderVar)
      let b = bundleOrSkip()
      if at.len == 0:
        skip()
      elif b.isNone:
        fail()
      else:
        let cfg = hosted()
        let e = fixtureEngine(cfg)
        e.startStorage(cfg, b.get)
        let (_, rc) = e.startClient("c")
        check rc.materializeAll("h", driver = false)
        let problems =
          readinessChecks(storageTarget(), b.get.fixture) &
          callChecks(storageTarget(), b.get.fixture)
        for p in problems:
          checkpoint p
        check problems.len == 0
        releaseAll()
        e.finish()

    test "[RUN-0815] [IMPL-DECISION G428] hosted to hosted: the probe reads a 4 MiB object from storage_module in four calls, and no carrier frame holds its bytes or its request":
      let at = getEnv(ProviderVar)
      let b = bundleOrSkip()
      if at.len == 0:
        skip()
      elif b.isNone:
        fail()
      else:
        let cfg = hosted()
        var probe = Probe(dir: cfg.stateDir("p"))
        writeFile(probe.dir / "probe.cmd", "serve\n")
        let e = fixtureEngine(cfg)
        e.startStorage(cfg, b.get)
        discard e.started(hostedProbe(), "probe")
        # The test's client waits for storage to be ready; the probe reads.
        let (_, rc) = e.startClient("c")
        check rc.materializeAll("h", driver = false)
        check waitUntil(
          proc(): bool =
            let r = (addr fetchHandles[0]).readiness()
            r.isOk and r.get == FetchReadiness.Ready,
          Answer,
        )
        probe.probeReads(b.get.probe, b.get.probeBytes)
        releaseAll()
        e.finish()
