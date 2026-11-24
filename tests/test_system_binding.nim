## The Package Manager's system-service binding (Tier 5 step 5-6a-2; plan §4.6, §10.2; DECISIONS
## G492, G493; RUNTIME §9, TRANSPORT §8.1.2): `liblogos_package_manager` realized `hosted_dynamic`
## as the marked instance (G490) under a test Runtime, with the reference fake as its storage, as
## `test_pm_module` hosts it. Its Module Host serves a second listener, the system-service endpoint
## (fd 6), and the Runtime's engine holds the binding to it: one session, `get_runtime_handoff`
## alone, its own call worker, a queue of one Request in flight and 64 parked.
##
## The engine's hooks (`runtime/engine.nim`, `lcnTestHooks`) show the binding, refuse the Hellos on
## fd 6, fail the client's peer check, hand out its tickets, and make handoff requests as 5-8 will;
## the facade's hook `LCN_TEST_HANDOFF_GATE` (`pm/facade.nim`) holds a handoff in the Package
## Manager while a file exists. The retry, the parked waits and the ticket expiry run on the
## engine's test clock. `test_system_binding.nims` lowers the shared call-worker pool to 2 + 2.
## A transport consumer (`trnowner`) presents tickets on either endpoint.

import
  std/[atomics, monotimes, os, osproc, sequtils, strutils, tables, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import logos_sdk/abi/[checks, types]
import ../src/logos_core/runtime/routes
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/iface/[accept, outcome, provider, surface]
import logos_sdk/codegen/common_types
import logos_sdk/pins
import logos_sdk/base/clock
import logos_sdk/testing/[kitbuild, kitruntime]
import logos_sdk/testing/fixtures/[meter_impl, fetch_fake_impl]
import logos_sdk/testing/generated/meter_module_calls
import logos_sdk/contracts/generated/lcn_storage_fetch_root
import ../src/logos_core/pins as core_pins

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "system-binding" / kitVariant
  cfgTypesDoc = readFile(repo / "spec/mirrors/CFG/9.configuration-types.cddl")
removeDir(work)
createDir(work)

include ./support/routefixture

when defined(posix):
  import logos_sdk/crypto/blake3
  import std/posix except Time, Clock
  import
    ./support/[lgxbuild, modulehostbuild, pmbuild, pmfixture, sanitizerenv, shortdir]
  import ../src/logos_core/pm/input_types
  import ./support/trnowner except Provider, now, binding, issue, live, release, gate
  from ../src/logos_core/runtime/plumbing import MaxCallWorkers, MaxNestedCallWorkers
  from logos_sdk/testing/generated/fetch_fake_module_calls import
    invoke, FetchFakeSetReadinessRequest, FetchFakeSetReadinessRequestReadinessChoice,
    FetchFakeSetReadinessRequestReadinessChoiceKind

  const
    Answer = 60 * Slow ## seconds: bounds a wait for the Package Manager
    Wait = 1000 * Answer ## ms
    PmModule = "logos_package_manager"
    MeterModule = "meter_module"
    InstalledEvent = "logos.package_manager.installed_packages_changed_event"

  let
    hostProgram = moduleHostProgram()
    fakeLib = buildKitLibrary("fetch_fake_impl.nim", "sbfake")
    meterLib = buildKitLibrary("meter_impl.nim", "sbmeter")
    pmLib = pmLibrary()
    shortBase = makeShortBase("lcnsb", "/e999/12345678/logos_fetch_fake_module.sock")
    contractDoc = readFile(repo / "sdk/src/logos_sdk/contracts/lcn_storage_fetch.cddl")
    fakeSet = acceptContractSet(
      readFile(repo / "sdk/src/logos_sdk/testing/fixtures/fetch_fake_module.cddl"),
      [contractDoc],
    ).tryGet
    fakeRoot = fakeSet.primary.root
    fakeSchema = encodeCbor(schemaResponse(fakeSet, fakeRoot).tryGet)
    # [G490; PM App A] The contract from the pinned documents, never from the kit.
    pmSet = acceptContractSet(
      core_pins.PackageManagerContractDocument,
      [],
      [core_pins.PackageManifestDocument, cfgTypesDoc],
      AcceptOptions(system: true),
    ).tryGet
    pmRoot = pmSet.primary.root
    pmSchema = encodeCbor(schemaResponse(pmSet, pmRoot).tryGet)
    # [plan §10.2] The facade's hold: while this file exists a system-service handoff waits in
    # the Package Manager, and each that begins to wait adds a line to `<gate>.held`.
    gate = work / "handoff-gate"
  putEnv("LCN_TEST_HANDOFF_GATE", gate)

  proc digestOf(path: string): array[32, byte] =
    let bytes = readFile(path)
    blake3(bytes.toOpenArrayByte(0, bytes.high))

  let
    fakeDigest = digestOf(fakeLib)
    meterDigest = digestOf(meterLib)
    pmDigest = digestOf(pmLib)

  # The packages, as `test_pm_module` has them: signed once, with a variant for each host the
  # suite runs on. `logos.example` is a module package whose module is `alpha_module`.
  const Hosts = [
    ("linux-x86_64", "linux", "x86_64"),
    ("linux-aarch64", "linux", "aarch64"),
    ("darwin-aarch64", "darwin", "aarch64"),
    ("darwin-x86_64", "darwin", "x86_64"),
  ]
  let
    (orgKey, orgPub) = testKey(1)
    app100 =
      packed(dataManifest("app", "1.0.0", [("lib", "1.0.0")], Hosts), "org", orgKey)
    lib120 = packed(dataManifest("lib", "1.2.0", variants = Hosts), "org", orgKey)
    example = modulePackage(allHosts = true).packed("org", orgKey)
    trust =
      trustOf([anchorOf("org", ["app", "lib", "logos.example"], orgPub)]).trustBytes
    objects =
      @[("app-1.0.0", app100), ("lib-1.2.0", lib120), ("logos.example-1.0.0", example)]
    document = catalogBytes(
      @[
        entryOf("app", "1.0.0", locator = "fetch-fake/state/app-1.0.0"),
        entryOf("lib", "1.2.0", locator = "fetch-fake/state/lib-1.2.0"),
        entryOf(
          "logos.example", "1.0.0", locator = "fetch-fake/state/logos.example-1.0.0"
        ),
      ]
    )

  proc pmInputBytes(): seq[byte] =
    pmValue(
      trust,
      document,
      bindings = [("main", "hf")],
      catalogLocator = "fetch-fake/state/catalog",
    ).encode.tryGet

  proc hosted(clock: Clock): EngineConfig =
    ## `config` with a state root, the Module Host program, a short endpoint directory, the
    ## Package Manager's protected input, `pm` marked (G490), and `clock`.
    result = config()
    result.stateRoot = Opt.some(result.workDir / "state")
    result.moduleHost = Opt.some(hostProgram)
    result.moduleHostEnv = @SanitizerEnv & @["LCN_TEST_HANDOFF_GATE"]
    result.endpointDir = shortBase / ("e" & $engines)
    var t = fastConfig()
    t.helloTimeout = int64(Answer) * 1000 * Ms
    t.admissionTimeout = int64(Answer) * 1000 * Ms
    t.writeStallTimeout = 10_000 * Ms * Slow
    result.transport = Opt.some(t)
    result.shutdownGrace = initDuration(seconds = 10 * Slow)
    result.protectedInputs = @[("pm", pmInputBytes())]
    result.packageManager = Opt.some("pm")
    result.clock = clock

  proc stateDir(cfg: EngineConfig, state: string): string =
    result = cfg.stateRoot.get / state
    createDir(result)

  proc stock(cfg: EngineConfig) =
    ## The fake's `objects/`: the catalog and the archives, written before the start.
    let dir = cfg.stateDir("f") / "objects"
    createDir(dir)
    writeFile(dir / "catalog", textOf(document))
    for (name, bytes) in objects:
      writeFile(dir / name, textOf(bytes))

  proc fakeRecord(): ModuleRecord =
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

  proc pmRecord(): ModuleRecord =
    ## [G491] The record `logosd` composes for the Package Manager, here under `pm`.
    ModuleRecord(
      module: PmModule,
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: PmModule, localPath: pmLib, hash: pmDigest, hashSuite: HashSuiteId
      ),
      primaryContract: Opt.some(pmRoot),
      stateAssignment: Opt.some("p"),
    )

  proc hostedMeter(): ModuleRecord =
    ModuleRecord(
      module: MeterModule,
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: "meter", localPath: meterLib, hash: meterDigest, hashSuite: HashSuiteId
      ),
      primaryContract: Opt.some(meterRoot),
      stateAssignment: Opt.some("m"),
    )

  proc startedLogging(
      e: Engine, r: ModuleRecord, instance, path: string
  ): InstanceView =
    ## `instance` started with its Module Host's fd 2 on `path`, as `test_pm_module` does.
    flushFile(stderr)
    let saved = dup(2)
    let fd = posix.open(cstring(path), O_WRONLY or O_CREAT or O_APPEND, 0o600)
    doAssert saved >= 0 and fd >= 0
    discard dup2(fd, 2)
    discard posix.close(fd)
    try:
      result = e.started(r, instance)
    finally:
      flushFile(stderr)
      discard dup2(saved, 2)
      discard posix.close(saved)

  # The client's handles: the fake's driver and an ordinary route to the Package Manager.
  var driver, pm: LogosRouteHandle
  var opened = 0

  proc open(
      rc: ptr LogosRuntimeControlBinding, root: Digest, schema: seq[byte]
  ): LogosRouteHandle =
    inc opened
    let made = rc.establish("k" & $opened, root)
    check made.code == ecOk
    if made.code != ecOk:
      return
    let (code, h) = rc.materialize(made.routesOf.routes[0].route, root, schema)
    check code == ecOk
    h

  proc releaseAll() =
    for h in [addr driver, addr pm]:
      if h[].vtable != nil:
        h[].release()
      h[] = LogosRouteHandle()

  proc drive(to: FetchFakeSetReadinessRequestReadinessChoiceKind): bool =
    invoke(
      addr driver,
      FetchFakeSetReadinessRequest(
        readiness: FetchFakeSetReadinessRequestReadinessChoice(kind: to)
      ),
    ).isOk

  # Requests and replies ----------------------------------------------------------------

  func identity(package, version: string): CborValue =
    cborMap((cbor("package"), cbor(package)), (cbor("version"), cbor(version)))

  proc call(h: var LogosRouteHandle, meth: string, request: CborValue): RcResult =
    raw(h, meth, encodeCbor(request))

  proc canonical(bytes: seq[byte]): bool =
    ## [G494] A reply is one deterministic-CBOR value: its own encoding.
    let v = decodeCbor(bytes)
    v.isOk and encodeCbor(v.get) == bytes

  proc valueOf(r: RcResult): CborValue =
    result = cborMap()
    check r.code == ecOk
    checkpoint r.message
    let v = decodeCbor(r.response)
    if v.isOk:
      result = v.get

  func codeOf(v: CborValue): string =
    ## The reply's `package_error` code; empty for a success.
    let e = v.lookup("error")
    if e.isSome:
      let c = e.get.lookup("code")
      if c.isSome:
        return c.get.getText.get("")

  func field(v: CborValue, names: varargs[string]): CborValue =
    ## The value at `names` below `v`; an empty map when one is missing.
    result = v
    for n in names:
      let x = result.lookup(n)
      if x.isNone:
        return cborMap()
      result = x.get

  proc inspected(package, version: string): RcResult =
    pm.call("inspect_package", identity(package, version))

  proc acquired(): bool =
    ## The catalog is in use: `app`'s inspection succeeds.
    waitUntil(
      proc(): bool =
        let r = inspected("app", "1.0.0")
        r.code == ecOk and decodeCbor(r.response).isOk and
          decodeCbor(r.response).get.lookup("inspection").isSome,
      Answer,
    )

  # The binding ---------------------------------------------------------------------------

  proc bindingReady(e: Engine): bool =
    ## The binding is `ready` and the engine's session to it established.
    waitUntil(
      proc(): bool =
        let v = e.systemBindingForTests()
        v.state == "bsReady" and v.established,
      Answer,
    )

  proc failuresReach(e: Engine, n: int): bool =
    waitUntil(
      proc(): bool =
        e.systemBindingForTests().failures >= n,
      Answer,
    )

  proc ask(
      e: Engine,
      package = "logos.example",
      version = "1.0.0",
      module = "alpha_module",
      timeoutMs = Wait,
  ): uint64 =
    e.requestHandoffForTests(package, version, module, timeoutMs)

  proc answered(e: Engine, id: uint64, seconds = Answer): HandoffResult =
    ## The request's outcome once it resumed; `done` is false after `seconds`.
    discard waitUntil(
      proc(): bool =
        e.handoffOutcomeForTests(id).done,
      seconds,
    )
    e.handoffOutcomeForTests(id)

  proc valueOf(r: HandoffResult): CborValue =
    ## The response map of a request that succeeded.
    result = cborMap()
    check r.done and r.ok
    checkpoint r.message
    check canonical(r.result)
    let v = decodeCbor(r.result)
    if v.isOk:
      result = v.get

  proc failed(r: HandoffResult, code: ErrorCode): bool =
    r.done and not r.ok and r.code == code

  proc attemptLines(e: Engine): seq[string] =
    e.diagnostics().filterIt("the system-service binding of pm: Hello attempt " in it)

  proc settle() =
    ## Real time for the I/O thread and the Runtime thread to act on what was asked;
    ## the engine's test clock does not move.
    sleep(200 * Slow)

  proc heldCount(path: string): int =
    try:
      readFile(path).splitLines.countIt(it.len > 0)
    except IOError:
      0

  proc heldAt(path: string, n: int): bool =
    waitUntil(
      proc(): bool =
        heldCount(path) >= n,
      Answer,
    )

  proc closeGate() =
    writeFile(gate, "")

  proc openGate() =
    removeFile(gate)

  # The transport consumer, which presents tickets --------------------------------------

  type Direct = object
    path: string
    ticket: RouteTicket

  proc toTicket(b: seq[byte]): RouteTicket =
    doAssert b.len == TicketBytes
    copyMem(addr result[0], unsafeAddr b[0], TicketBytes)

  proc directOf(rc: ptr LogosRuntimeControlBinding, root: Digest): Direct =
    ## A route to `root`'s provider, used directly: its invocation descriptor.
    inc opened
    let made = rc.establish("k" & $opened, root)
    doAssert made.code == ecOk, made.message
    let d = made.routesOf.routes[0].invocation
    doAssert d.isSome
    let i = d.get
    doAssert i.kind == LogosNSRuntimeControlInvocationDescriptorKind.Case0 and
      i.arm_0.ticket.len == TicketBytes
    result.path = i.arm_0.path
    result.ticket = toTicket(i.arm_0.ticket)

  var nextConn, nextTag: uint64

  proc seen(o: Owner, pred: proc(ev: IoEvent): bool, timeoutMs = Wait): Opt[IoEvent] =
    let until = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while true:
      for ev in o.log:
        if pred(ev):
          return Opt.some(ev)
      if getMonoTime() >= until:
        return Opt.none(IoEvent)
      discard o.pump(10)

  proc connected(
      o: Owner,
      path: string,
      t: RouteTicket,
      module = PmModule,
      root = pmRoot,
      schema = pmSchema,
      system = true,
  ): (ConnId, IoEvent) =
    ## A Hello at `path` with `t`: its connection and its outcome, `evConnected` or
    ## `evConnectFailed`.
    inc nextConn
    let conn = nextConn
    o.connect(
      conn,
      path,
      t,
      module = module,
      selected = ContractInput(root: root, schema: schema, system: system),
    )
    let ev = o.seen(
      proc(ev: IoEvent): bool =
        ev.conn == conn and ev.kind in {evConnected, evConnectFailed}
    )
    doAssert ev.isSome
    (conn, ev.get)

  proc refused(ev: IoEvent): bool =
    ## [TRN-0342] NOT_AUTHORISED, and no session.
    ev.kind == evConnectFailed and ev.failCode == ecNotAuthorised

  proc send(o: Owner, conn: ConnId, meth: string, request: CborValue): uint64 =
    inc nextTag
    o.call(conn, nextTag, meth, request)
    nextTag

  proc outcome(o: Owner, conn: ConnId, tag: uint64): Opt[CallOutcome] =
    let ev = o.seen(
      proc(ev: IoEvent): bool =
        ev.kind == evResponse and ev.conn == conn and ev.tag == tag
    )
    if ev.isNone:
      Opt.none(CallOutcome)
    else:
      Opt.some(ev.get.outcome)

  proc failureCode(o: Opt[CallOutcome]): Opt[ErrorCode] =
    if o.isSome and not o.get.ok:
      Opt.some(o.get.failure.code)
    else:
      Opt.none(ErrorCode)

  func holds(hay, needle: openArray[byte]): bool =
    if needle.len == 0 or needle.len > hay.len:
      return false
    for i in 0 .. hay.len - needle.len:
      if hay.toOpenArray(i, i + needle.len - 1) == needle:
        return true
    false

  func hexOf(b: openArray[byte]): string =
    for x in b:
      result.add(toHex(x, 2).toLowerAscii)

  # Set-up --------------------------------------------------------------------------------

  type Setup = object
    e: Engine
    rc: ptr LogosRuntimeControlBinding
    clock: Clock
    pmDir, log, meterDir: string

  proc setup(
      name: string, clock = systemClock(), refuse = false, meter = false
  ): Setup =
    ## The fake and the marked Package Manager started (with `refuse`, every Hello on fd 6
    ## is refused from the first), the fake ready, the catalog in use; with `meter`, a
    ## hosted meter too. The Package Manager's host logs to `<work>/<name>.log`.
    openGate()
    removeFile(gate & ".held")
    let cfg = hosted(clock)
    cfg.stock()
    result.clock = clock
    result.pmDir = cfg.stateDir("p")
    result.log = work / (name & ".log")
    removeFile(result.log)
    if meter:
      result.meterDir = cfg.stateDir("m")
    result.e = fixtureEngine(cfg)
    if refuse:
      result.e.refuseSystemHellosForTests(true)
    check result.e.systemBindingForTests().state == ""
    discard result.e.started(fakeRecord(), "hf")
    let v = result.e.startedLogging(pmRecord(), "pm", result.log)
    # [G493] Start does not wait for the binding: the instance's readiness is its own.
    check v.state == msReady
    check v.failure.isNone
    if meter:
      check result.e.started(hostedMeter(), "hm").state == msReady
    result.rc = result.e.startClient("c")[1]
    driver = result.rc.open(fakeRoot, fakeSchema)
    pm = result.rc.open(pmRoot, pmSchema)
    check drive(FetchFakeSetReadinessRequestReadinessChoiceKind.Ready)
    check acquired()

  proc install(package, version: string): CborValue =
    pm.call("install_package", identity(package, version)).valueOf

  proc stopPm(e: Engine) =
    if pm.vtable != nil:
      pm.release()
      pm = LogosRouteHandle()
    check e.stop("pm").isOk
    check waitUntil(
      proc(): bool =
        e.view("pm").tryGet.state == msUnloaded,
      Answer,
    )

  suite "the Package Manager's system-service binding (G492, G493; RUNTIME §9, TRANSPORT §8.1.2)":
    teardown:
      openGate()
      releaseAll()
      leftover()

    test "[RUN-0313] [RUN-0314] [RUN-0315] [RUN-0316] [RUN-0317] [RUN-0318] [RUN-0319] [RUN-0851] [TRN-0182] [TRN-0183] [TRN-0184] [TRN-0185] [TRN-0328] [TRN-0333] [IMPL-DECISION G492] [IMPL-DECISION G493] pending until the marked instance is ready and its first Hello succeeds, then ready; start waits for neither; the system-service endpoint is a listener of its own in a private directory":
      let clk = newTestClock()
      let s = setup("readiness", clk, refuse = true)
      let e = s.e
      # Made at the instance's readiness, `pending` while its first Hello is refused.
      check e.failuresReach(1)
      let pending = e.systemBindingForTests()
      check pending.state == "bsPending"
      check not pending.established
      check e.view("pm").tryGet.state == msReady
      # [IMPL; G492] Its own fresh private directory, beside the provider endpoint's.
      let provider = e.hostedEndpointForTests("pm")
      check pending.path.len > 0
      check pending.path != provider
      check pending.path.parentDir != provider.parentDir
      check getFilePermissions(pending.path.parentDir) ==
        {fpUserRead, fpUserWrite, fpUserExec}
      var st: Stat
      check lstat(cstring(pending.path), st) == 0 and S_ISSOCK(st.st_mode)
      # [RUN-0319] Nothing is sent while it is pending: a handoff waits.
      let h = e.ask("app", "1.0.0")
      settle()
      check not e.handoffOutcomeForTests(h).done
      check e.systemRequestsSentForTests() == 0
      # Let through: the next Hello, 1 s later on the engine's clock, succeeds.
      e.refuseSystemHellosForTests(false)
      clk.advance(1_000)
      check e.bindingReady()
      check e.diagnostics().countIt("the system-service binding of pm is ready" in it) ==
        1
      # [RUN-0318] The handoff is sent only now, and answered.
      let r = e.answered(h)
      check r.valueOf.codeOf == "package-not-installed"
      check e.systemRequestsSentForTests() == 1
      releaseAll()
      e.finish()

    test "[PKG-0380] [PKG-0388] [PKG-0650] [IMPL-DECISION G449] [IMPL-DECISION G496] [IMPL-DECISION G493] [IMPL-DECISION G495] [TRN-0349] [TRN-0192] [TRN-0194] a handoff through the binding: the bytes the Package Manager built, for the SYSTEM_SERVICE caller an ordinary route cannot be; refused for a module the package does not declare and an identity not installed; kept across the instance's restart":
      # [G496] The probe's handoff case, moved from `test_pm_hosted`: through the real module.
      let s = setup("handoff")
      let e = s.e
      let installed = install("logos.example", "1.0.0").field("installed")
      check installed.field("identity") == identity("logos.example", "1.0.0")
      check e.bindingReady()
      let r = e.answered(e.ask())
      let h = r.valueOf.field("handoff")
      check h.field("module") == cbor("alpha_module")
      check h.field("package") == identity("logos.example", "1.0.0")
      check h.field("signer") == installed.field("signer")
      check h.field("manifest_commitment") == installed.field("manifest_commitment")
      let art = h.field("artifact")
      var matched = false
      let arts = installed.field("artifacts")
      for a in (if arts.kind == ckArray: arts.items else: @[]):
        if a.field("id") == art.field("id"):
          matched = true
          check a.field("local_path") == art.field("local_path")
          check a.field("hash") == art.field("hash")
      check matched
      # [G495] The same request on an ordinary route: MODULE_ERROR, with no message.
      let ordinary = pm.call(
        "get_runtime_handoff",
        cborMap(
          (cbor("module"), cbor("alpha_module")),
          (cbor("package"), identity("logos.example", "1.0.0")),
        ),
      )
      check ordinary.code == ecModule
      check ordinary.message.len == 0
      check e.answered(e.ask(module = "no_such_module")).valueOf.codeOf ==
        "invalid-request"
      check e.answered(e.ask("app", "1.0.0")).valueOf.codeOf == "package-not-installed"
      check e.systemRequestsSentForTests() == 3
      # Stopped and started again: the start reads the record back from the index, and the
      # new realization is bound anew.
      e.stopPm()
      check e.start("pm").tryGet.state == msReady
      check e.bindingReady()
      check e.answered(e.ask()).valueOf.field("handoff", "module") ==
        cbor("alpha_module")
      releaseAll()
      e.finish()

    test "[TRN-0344] [TRN-0345] [TRN-0329] [RUN-0853] [IMPL-DECISION G492] a system-service session is get_runtime_handoff alone: the operations, the observations and a subscription are NOT_AUTHORISED from the Runtime; no route is made for it":
      let s = setup("scope")
      let e = s.e
      check e.bindingReady()
      let routesBefore = e.routes().len
      let o = newOwner(fastConfig())
      defer:
        o.stop()
      let (conn, ev) = o.connected(
        e.systemBindingForTests().path, toTicket(e.issueSystemTicketForTests().tryGet)
      )
      check ev.kind == evConnected
      for (meth, request) in [
        ("install_package", identity("app", "1.0.0")),
        ("inspect_package", identity("app", "1.0.0")),
        ("list_installed_packages", cborMap()),
        ("watch_installed_packages", cborMap()),
      ]:
        checkpoint meth
        check o.outcome(conn, o.send(conn, meth, request)).failureCode ==
          Opt.some(ecNotAuthorised)
      inc nextTag
      o.subscribe(conn, nextTag, InstalledEvent)
      let sub = o.seen(
        proc(ev: IoEvent): bool =
          ev.conn == conn and ev.kind == evSubscription and ev.subscriptionId == nextTag
      )
      check sub.isSome
      if sub.isSome:
        check sub.get.subscriptionFailure.isSome
        if sub.get.subscriptionFailure.isSome:
          check sub.get.subscriptionFailure.get.code == ecNotAuthorised
      # The one method in scope is answered on the same session.
      let inScope = o.outcome(
        conn,
        o.send(
          conn,
          "get_runtime_handoff",
          cborMap(
            (cbor("module"), cbor("x")), (cbor("package"), identity("app", "1.0.0"))
          ),
        ),
      )
      check inScope.isSome and inScope.get.ok
      # [TRN-0329] No route or consumer stands for it.
      check e.routes().len == routesBefore
      releaseAll()
      e.finish()

    test "[TRN-0330] [TRN-0331] [TRN-0332] [TRN-0334] [TRN-0335] [TRN-0336] [TRN-0337] [TRN-0338] [TRN-0342] [TRN-0343] [RUN-0852] system-service tickets: unknown to the provider endpoint and route tickets unknown to the system endpoint, each still good where it belongs; expired, replayed and wrong-purpose material is NOT_AUTHORISED; no ticket in a Runtime Control result or a log":
      let clk = newTestClock()
      let s = setup("tickets", clk)
      let e = s.e
      check e.bindingReady()
      let sysPath = e.systemBindingForTests().path
      let o = newOwner(fastConfig())
      defer:
        o.stop()
      # [TRN-0331, TRN-0332] Each acceptor redeems its own kind only, for the same provider
      # and contract; neither consumes the other's.
      let d = s.rc.directOf(pmRoot)
      let sys1 = toTicket(e.issueSystemTicketForTests().tryGet)
      check o.connected(d.path, sys1)[1].refused
      check o.connected(sysPath, d.ticket)[1].refused
      check o.connected(sysPath, sys1)[1].kind == evConnected
      check o.connected(d.path, d.ticket)[1].kind == evConnected
      # [TRN-0342] Replayed, wrong-purpose and expired material.
      check o.connected(sysPath, sys1)[1].refused
      check o.connected(sysPath, toTicket(e.issueSystemTicketForTests(false).tryGet))[1].refused
      let late = toTicket(e.issueSystemTicketForTests().tryGet)
      clk.advance(60_001)
      check o.connected(sysPath, late)[1].refused
      # [TRN-0337] A fresh one, issued while the binding stands, still works.
      check o.connected(sysPath, toTicket(e.issueSystemTicketForTests().tryGet))[1].kind ==
        evConnected
      # [RUN-0852; TRN-0338] The engine's own ticket, and the ones above, appear in no
      # Runtime Control result and no log line.
      let mine = e.lastSystemTicketForTests()
      check mine.len == TicketBytes
      let shown =
        e.diagnostics().join("\n").toLowerAscii & "\n" &
        (if fileExists(s.log): readFile(s.log).toLowerAscii else: "")
      for t in [mine, @sys1, @late]:
        check hexOf(t) notin shown
      for meth in ["list_routes", "list_modules"]:
        let req =
          if meth == "list_routes":
            encode(LogosNSRuntimeControlListRoutesRequest()).tryGet
          else:
            encode(LogosNSRuntimeControlListModulesRequest()).tryGet
        let r = rcCall(s.rc, meth, req)
        check r.code == ecOk
        for t in [mine, @sys1, @late]:
          check not r.response.holds(t)
      # The binding itself is untouched by all of it.
      check e.answered(e.ask("app", "1.0.0")).valueOf.codeOf == "package-not-installed"
      releaseAll()
      e.finish()

    test "[TRN-0187] [TRN-0188] [TRN-0189] [TRN-0190] [TRN-0191] [TRN-0339] [IMPL-DECISION G492] a failed attempt's ticket is deleted at once: the client's peer check fails, nothing is sent, the old ticket is refused afterwards, and the binding retries with a fresh one":
      let clk = newTestClock()
      let s = setup("peer", clk)
      let e = s.e
      check e.bindingReady()
      let first = e.lastSystemTicketForTests()
      let sysPath = e.systemBindingForTests().path
      # The session is lost; the next use makes it again, and its peer check fails.
      e.failNextSystemHelloForTests(cfPeerMismatch)
      check e.closeSystemSessionsForTests() == 1
      check waitUntil(
        proc(): bool =
          not e.systemBindingForTests().established,
        Answer,
      )
      let h = e.ask("app", "1.0.0")
      check e.failuresReach(1)
      check e.systemBindingForTests().state == "bsReady"
      let failedOne = e.lastSystemTicketForTests()
      check failedOne != first
      check e.attemptLines().len == 1
      check e.attemptLines()[0].contains(
        "Hello attempt 1 failed (the peer check failed"
      )
      check e.systemRequestsSentForTests() == 0
      # [TRN-0191] The failed attempt's ticket is refused when presented later.
      let o = newOwner(fastConfig())
      defer:
        o.stop()
      check o.connected(sysPath, toTicket(failedOne))[1].refused
      # The retry, 1 s later, with a fresh ticket: the session again, and the handoff.
      clk.advance(1_000)
      check e.bindingReady()
      check e.lastSystemTicketForTests() notin [first, failedOne]
      check e.answered(h).valueOf.codeOf == "package-not-installed"
      check e.systemRequestsSentForTests() == 1
      releaseAll()
      e.finish()

    test "[RUN-0700] [RUN-0854] [RUN-0855] [TRN-0341] [IMPL-DECISION G492] a stop during a parked handoff: it and the one in flight fail NOT_READY, the binding ends with its sessions and tickets; a restart binds again and the old tickets fail":
      let s = setup("stop")
      let e = s.e
      check e.bindingReady()
      let o = newOwner(fastConfig())
      defer:
        o.stop()
      let oldPath = e.systemBindingForTests().path
      let (dependent, ev) =
        o.connected(oldPath, toTicket(e.issueSystemTicketForTests().tryGet))
      check ev.kind == evConnected
      let unused = toTicket(e.issueSystemTicketForTests().tryGet)
      closeGate()
      let inflight = e.ask("app", "1.0.0")
      check heldAt(gate & ".held", 1)
      let parked = e.ask("app", "1.0.0")
      check e.systemRequestsSentForTests() == 1
      check pm.vtable != nil
      pm.release()
      pm = LogosRouteHandle()
      check e.stop("pm").isOk
      # [RUN-0854] Both fail at once; no Request more is sent.
      check e.answered(parked).failed(ecNotReady)
      check e.answered(inflight).failed(ecNotReady)
      check e.systemBindingForTests().state == "bsInvalid"
      # [RUN-0855] The dependent session ends with the binding's authority.
      check o.seen(
        proc(ev: IoEvent): bool =
          ev.conn == dependent and ev.kind == evClosed
      ).isSome
      openGate()
      check waitUntil(
        proc(): bool =
          e.view("pm").tryGet.state == msUnloaded,
        Answer,
      )
      check e.systemRequestsSentForTests() == 1
      check e.answered(e.ask("app", "1.0.0")).failed(ecNotReady)
      # [RUN-0700] A restart binds again after its own checks; the old tickets fail.
      check e.start("pm").tryGet.state == msReady
      check e.bindingReady()
      let newPath = e.systemBindingForTests().path
      check newPath != oldPath
      check o.connected(newPath, unused)[1].refused
      check e.answered(e.ask("app", "1.0.0")).valueOf.codeOf == "package-not-installed"
      releaseAll()
      e.finish()

    test "[IMPL-DECISION G493] [IMPL-DECISION I146] the binding's own worker: with every call worker of the shared pool held in a hosted provider, a handoff is still admitted and answered":
      check MaxCallWorkers + MaxNestedCallWorkers == 4
      let s = setup("worker", meter = true)
      let e = s.e
      check e.bindingReady()
      let o = newOwner(fastConfig())
      defer:
        o.stop()
      let d = s.rc.directOf(meterRoot)
      let (conn, ev) = o.connected(
        d.path,
        d.ticket,
        module = MeterModule,
        root = meterRoot,
        schema = meterSchema,
        system = false,
      )
      check ev.kind == evConnected
      # Channel 23 holds each call in the meter until the file `open` is there: four calls,
      # one on each call worker, sent at once. [I146] All four run in the meter's host: before
      # its dispatch pool claimed a worker at the post, the second of two calls posted together
      # could wait behind the first (orc-release: three of the four ran).
      var tags: seq[uint64]
      for _ in 0 ..< 4:
        tags.add(o.send(conn, "read", cborMap((cbor("channel"), cbor(23'u64)))))
      check heldAt(s.meterDir / "held", 4)
      let r = e.answered(e.ask("app", "1.0.0"))
      check r.valueOf.codeOf == "package-not-installed"
      check heldCount(s.meterDir / "held") == 4
      writeFile(s.meterDir / "open", "")
      for t in tags:
        let x = o.outcome(conn, t)
        check x.isSome and x.get.ok
      releaseAll()
      e.finish()

    test "[IMPL-DECISION G493] the call-worker pools are fixed: a build without the test hooks that sets lcnMaxCallWorkers or lcnMaxNestedCallWorkers does not compile, and a test-hook build may":
      # From the repository's root, which `tests/config.nims` (the test hooks) does not cover.
      let source = repo / "src/logos_core/runtime/plumbing.nim"
      proc checked(defines: seq[string]): tuple[output: string, exitCode: int] =
        execCmdEx(
          quoteShellCommand(
            @[getCurrentCompilerExe(), "check", "--hints:off", "--warnings:off"] &
              defines & hostPathArgs(source) &
              @["--nimcache:" & work / "pool-check", source]
          ),
          workingDir = repo,
        )

      for d in ["-d:lcnMaxCallWorkers=2", "-d:lcnMaxNestedCallWorkers=2"]:
        let (output, code) = checked(@[d])
        checkpoint(output)
        check code != 0
        check "only a test-hook build (lcnTestHooks) may set them" in output
      let hooked = checked(
        @["-d:lcnMaxCallWorkers=2", "-d:lcnMaxNestedCallWorkers=2", "-d:lcnTestHooks"]
      )
      checkpoint(hooked.output)
      check hooked.exitCode == 0

    test "[IMPL-DECISION G492] the engine's queue: with one Request in flight and 64 parked, a 65th fails MODULE_ERROR before anything is sent; the parked ones are sent and answered in order":
      let s = setup("queue")
      let e = s.e
      check e.bindingReady()
      closeGate()
      let first = e.ask("app", "1.0.0")
      check heldAt(gate & ".held", 1)
      var parked: seq[uint64]
      for i in 0 ..< 64:
        parked.add(e.ask("app", "1.0.0", module = "m" & $i))
      let over = e.ask("app", "1.0.0")
      let refusedOne = e.handoffOutcomeForTests(over)
      check refusedOne.failed(ecModule)
      check e.systemRequestsSentForTests() == 1
      for id in parked:
        check not e.handoffOutcomeForTests(id).done
      openGate()
      var last = e.answered(first).order
      check e.answered(first).valueOf.codeOf == "package-not-installed"
      for id in parked:
        let r = e.answered(id)
        check r.done and r.ok
        check r.order > last
        last = r.order
      check e.systemRequestsSentForTests() == 65
      releaseAll()
      e.finish()

    test "[IMPL-DECISION G492] [IMPL-DECISION G493] a request's own end: parked, one past its deadline and one withdrawn are removed and never sent, TIMEOUT and CANCELLED; in flight past its deadline, Cancel is sent, it resumes TIMEOUT and the next is sent at once":
      let clk = newTestClock()
      let s = setup("ends", clk)
      let e = s.e
      check e.bindingReady()
      closeGate()
      let h0 = e.ask("app", "1.0.0", timeoutMs = 5_000)
      check heldAt(gate & ".held", 1)
      let h1 = e.ask("app", "1.0.0", timeoutMs = 2_000)
      let h2 = e.ask("app", "1.0.0")
      let h3 = e.ask("app", "1.0.0")
      # Withdrawn: removed at once, never sent.
      e.withdrawHandoffForTests(h3)
      check e.handoffOutcomeForTests(h3).failed(ecCancelled)
      # Parked past its deadline: TIMEOUT, never sent.
      clk.advance(2_500)
      check e.answered(h1).failed(ecTimeout)
      check e.systemRequestsSentForTests() == 1
      check not e.handoffOutcomeForTests(h2).done
      # In flight past its deadline: Cancel, TIMEOUT, and the next sent at once.
      clk.advance(3_000)
      check e.answered(h0).failed(ecTimeout)
      check heldAt(gate & ".held", 2)
      check e.systemRequestsSentForTests() == 2
      check waitUntil(
        proc(): bool =
          readFile(s.log).contains("get_runtime_handoff cancelled by the Runtime"),
        Answer,
      )
      openGate()
      check e.answered(h2).valueOf.codeOf == "package-not-installed"
      check e.systemRequestsSentForTests() == 2
      releaseAll()
      e.finish()

    test "[RUN-0318] [RUN-0319] [IMPL-DECISION G493] the first Hello refused: create and start report nothing, the binding stays pending with one log line per attempt and retries with fresh tickets, 1 s doubling to 30 s; a handoff parked meanwhile fails NOT_READY after 10 s; once let through it is ready and answers; a stop ends the retries":
      let clk = newTestClock()
      let s = setup("first", clk, refuse = true)
      let e = s.e
      check e.failuresReach(1)
      var tickets = @[e.lastSystemTicketForTests()]
      # 1, 2, 4, 8, 16, then 30 s.
      for (wait, n) in [
        (1_000, 2), (2_000, 3), (4_000, 4), (8_000, 5), (16_000, 6), (30_000, 7)
      ]:
        if wait > 1_000:
          clk.advance(wait - 1)
          settle()
          check e.systemBindingForTests().failures == n - 1
          clk.advance(1)
        else:
          clk.advance(wait)
        check e.failuresReach(n)
        tickets.add(e.lastSystemTicketForTests())
      check tickets.deduplicate.len == tickets.len
      let lines = e.attemptLines()
      check lines.len == 7
      for i, next in [1, 2, 4, 8, 16, 30, 30]:
        if i < lines.len:
          check lines[i].contains("Hello attempt " & $(i + 1) & " failed")
          check lines[i].endsWith("the next in " & $next & " s")
      check e.systemBindingForTests().state == "bsPending"
      let v = e.view("pm").tryGet
      check v.state == msReady and v.failure.isNone
      # A handoff parked while it is pending: NOT_READY after 10 s.
      let h = e.ask("app", "1.0.0")
      clk.advance(9_999)
      settle()
      check not e.handoffOutcomeForTests(h).done
      clk.advance(1)
      check e.answered(h).failed(ecNotReady)
      check e.systemRequestsSentForTests() == 0
      # Let through at the next retry, 30 s after the last failure.
      e.refuseSystemHellosForTests(false)
      clk.advance(20_000)
      check e.bindingReady()
      check e.systemBindingForTests().failures == 7
      check e.answered(e.ask("app", "1.0.0")).valueOf.codeOf == "package-not-installed"
      # Refused again after a lost session, then stopped: no attempt after the stop.
      e.refuseSystemHellosForTests(true)
      check e.closeSystemSessionsForTests() == 1
      check waitUntil(
        proc(): bool =
          not e.systemBindingForTests().established,
        Answer,
      )
      let waiting = e.ask("app", "1.0.0")
      check e.failuresReach(8)
      e.stopPm()
      check e.answered(waiting).failed(ecNotReady)
      check e.systemBindingForTests().state == "bsInvalid"
      clk.advance(60_000)
      settle()
      check e.systemBindingForTests().failures == 8
      check e.attemptLines().len == 8
      releaseAll()
      e.finish()

    test "[IMPL-DECISION G493] a later Hello refused after a lost session: one log line per attempt, retries with fresh tickets; a request parked meanwhile ends at its own deadline with TIMEOUT; once let through the session is made again and a handoff answered":
      let clk = newTestClock()
      let s = setup("later", clk)
      let e = s.e
      check e.bindingReady()
      e.refuseSystemHellosForTests(true)
      check e.closeSystemSessionsForTests() == 1
      check waitUntil(
        proc(): bool =
          not e.systemBindingForTests().established,
        Answer,
      )
      check e.diagnostics().anyIt("its session was lost" in it)
      let h = e.ask("app", "1.0.0", timeoutMs = 5_000)
      check e.failuresReach(1)
      let t1 = e.lastSystemTicketForTests()
      clk.advance(1_000)
      check e.failuresReach(2)
      clk.advance(2_000)
      check e.failuresReach(3)
      check e.lastSystemTicketForTests() != t1
      check e.attemptLines().len == 3
      # [ruling 3] The binding is still `ready`: the request waits for its own deadline.
      check e.systemBindingForTests().state == "bsReady"
      check not e.handoffOutcomeForTests(h).done
      clk.advance(2_000)
      check e.answered(h).failed(ecTimeout)
      check e.systemRequestsSentForTests() == 0
      e.refuseSystemHellosForTests(false)
      clk.advance(2_000)
      check e.bindingReady()
      check e.answered(e.ask("app", "1.0.0")).valueOf.codeOf == "package-not-installed"
      check e.systemRequestsSentForTests() == 1
      releaseAll()
      e.finish()
else:
  suite "the Package Manager's system-service binding (POSIX only)":
    test "[IMPL] the binding's cases need a Module Host on local stream sockets and std/posix":
      skip()
