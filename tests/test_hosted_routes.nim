## Hosted providers and consumers (Tier 4b step 4b-3, parts 4b-3.2 and
## 4b-3.3; DECISIONS I91, G267, G273, G274; plan §4.3 P-1 to P-14, R10, C-1 to
## C-8, S-18; part 4b-3.4: C-9, G261 for a hosted consumer, and C-10, G244):
## the meter kit module built as a
## shared library and realized `hosted_dynamic` in a `logos-module-host`
## process, which serves the endpoint the Runtime made for it with its own
## transport loop. Payloads go between the caller and the host directly (the
## owner's direct layout): the host reports each session event and call
## without its payload, and the Runtime judges every Hello, admits every call,
## subscription and delivery, keeps every session and writes every call
## record, as for the endpoint it serves itself (4b-2), so the caller sees the
## same protocol. A test-owned transport loop (`support/trnowner.nim`)
## connects with a route's descriptor as a consumer's binding does, and the
## client module calls through materialized handles.
##
## A hosted consumer is `probe_module` realized `hosted_dynamic` with its
## `serve` command thread: the case writes it commands and reads its answers in
## its state directory. The host connects to the provider's endpoint itself
## with the material it kept, and the Runtime admits each of its steps.
##
## The test process cannot reach the hosted meter's globals: channel 22 holds
## a call until the file `open` is in the meter's state directory or the call
## is cancelled, and adds a line to `held` there when it starts. After every
## case no host of this build is left. Waits that only bound a test scale
## with `Slow`.

when defined(posix):
  import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
  import std/posix except Time
  import unittest2
  import ./support/sanitizerenv
  import ../src/logos_core/runtime/[engine, hostsup]
  import logos_sdk/abi/types
  import logos_sdk/base/clock
  from logos_sdk/base/wipe import ChannelsMove, MarkedUnsupported
  import logos_sdk/cbor
  import logos_sdk/commitment
  import logos_sdk/crypto/blake3
  import logos_sdk/iface/[accept, cmap, outcome, provider, surface]
  import logos_sdk/codegen/common_types
  import ../src/logos_core/loader/contract
  import logos_sdk/pins
  import ../src/logos_core/authority/scopes except
    LogosNSRuntimeModuleInstanceAddress, LogosNSRuntimeModuleInstanceId,
    LogosNSRuntimeModuleName, LogosNSRuntimeModuleProviderAddress,
    LogosNSRuntimeModuleProviderId, LogosNSRuntimeModuleStateAssignmentId,
    LogosNSRuntimeRouteId, LogosNSRuntimeRuntimeInstanceId
  import
    ./support/[fakeca, modulehostbuild, shortdir],
    logos_sdk/testing/[kitbuild, kitruntime]
  import ./kit/bulk_impl, logos_sdk/testing/fixtures/meter_impl
  import
    ./generated/[bulk_module_calls, bulk_module_types],
    logos_sdk/testing/generated/[meter_module_calls, meter_module_types]
  import ./support/trnowner except Provider, now, binding, issue, live, release, gate
  from ../src/logos_core/host/selected import
    earlierInputOf, keepProvider, publishedBy, schemaAnswer, selectedFor
  from ../src/logos_core/transport/limits import MaxPayloadDepth
  from ../src/logos_core/transport/boundary import knowsEvent

  let
    repo = currentSourcePath().parentDir.parentDir
    work = repo / "build" / "hosted-routes" / kitVariant
  removeDir(work)
  createDir(work)

  include ./support/routefixture

  # The endpoints go under a short private base: `<base>/e<n>/<8
  # hex>/logos_meter_module.sock`.
  let shortBase = makeShortBase("lcnhr", "/e999/12345678/logos_meter_module.sock")

  const
    # [IMPL] Bounds a wait for what comes: a response, an end, a held call, a
    # delivery, a record or the probe's answer. A hosted path crosses the
    # carrier, a call that publishes an Event three more times, and on a CI
    # runner under x86 MSan, with three other suites building and running
    # beside it, such steps outlasted the 15 s and 30 s bounds this replaces
    # (2026-11-15; 0.1-0.3 s with orc on an idle Mac). A wait for what comes
    # costs nothing more while it comes in time.
    Answer = 60 * Slow ## seconds
    Wait = 1000 * Answer ## ms
    MeterModule = "meter_module"

  let
    hostProgram = moduleHostProgram()
    meterLib = buildKitLibrary("meter_impl.nim", "hrmeter")
    deferredLib = buildKitLibrary("deferred_adapter.nim", "hrdeferred")
    probeLib = buildKitLibrary("probe_impl.nim", "probe")
    listenerLib = buildKitLibrary("listener_impl.nim", "hrlistener")

  proc digestOf(path: string): array[32, byte] =
    var h: Blake3Hasher
    h.init()
    let bytes = readFile(path)
    h.update(bytes.toOpenArrayByte(0, bytes.high))
    h.finish()

  let
    meterDigest = digestOf(meterLib)
    deferredDigest = digestOf(deferredLib)
    probeDigest = digestOf(probeLib)
    listenerDigest = digestOf(listenerLib)

  # Set-up -------------------------------------------------------------------------------

  proc roomy(): TransportConfig =
    ## `fastConfig` whose Hello and admission deadlines are `Wait`: no case
    ## here is about them, and a Hello with a host asks the Runtime about the
    ## ticket over the carrier.
    result = fastConfig()
    result.helloTimeout = int64(Wait) * Ms
    result.admissionTimeout = int64(Wait) * Ms

  proc hosted(policy = allowAll(), clock = systemClock()): EngineConfig =
    ## `config` with a state root, the Module Host program and a short
    ## endpoint directory; no routing rule, so a route with a hosted end is
    ## `local-transport` (R10).
    result = config(policy)
    result.stateRoot = Opt.some(result.workDir / "state")
    result.moduleHost = Opt.some(hostProgram)
    result.moduleHostEnv = @SanitizerEnv
    result.endpointDir = shortBase / ("e" & $engines)
    result.transport = Opt.some(roomy())
    result.clock = clock
    # [IMPL] Only a bound on the hosts' graceful ends, which no case here is
    # about (test_wipe_routes `hostedConfig`): P-5b's shutdown completed with
    # an error after 32.9 s on a loaded x86_64 MSan runner (CI on b3af640).
    result.shutdownGrace = initDuration(seconds = 10 * Slow)

  proc hostedMeter(
      state = "m", lib = meterLib, digest = meterDigest, id = "meter"
  ): ModuleRecord =
    ModuleRecord(
      module: MeterModule,
      strategy: stHostedDynamic,
      placement: "process",
      artifact:
        ArtifactRecord(id: id, localPath: lib, hash: digest, hashSuite: HashSuiteId),
      primaryContract: Opt.some(meterRoot),
      stateAssignment: Opt.some(state),
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

  proc stateOf(cfg: EngineConfig, state = "m"): string =
    ## The meter's state directory, made before its start.
    result = cfg.stateRoot.get / state
    createDir(result)

  proc heldCalls(dir: string): int =
    try:
      readFile(dir / "held").splitLines.countIt(it.len > 0)
    except IOError:
      0

  proc heldAt(dir: string, n: int, seconds = Answer): bool =
    waitUntil(
      proc(): bool =
        heldCalls(dir) == n,
      seconds,
    )

  proc open(dir: string) =
    ## Every call held on channel 22 returns.
    writeFile(dir / "open", "")

  proc noHostLeft(): bool =
    waitUntil(
      proc(): bool =
        hostPids(hostProgram).len == 0
    )

  proc failureOf(v: InstanceView): string =
    if v.failure.isSome: v.failure.get.classification else: ""

  proc modeOf(path: string): int =
    var s: Stat
    if lstat(cstring(path), s) != 0:
      return -1
    int(s.st_mode) and 0o7777

  proc isSocket(path: string): bool =
    var s: Stat
    lstat(cstring(path), s) == 0 and S_ISSOCK(s.st_mode)

  proc socketsUnder(dir: string): seq[string] =
    for path in walkDirRec(dir):
      if path.isSocket:
        result.add(path)

  var startReply: Atomic[int] ## the state `startOn` got, or -1; -2 while it waits

  proc startOn(arg: (Engine, string)) {.thread.} =
    let r = arg[0].start(arg[1])
    startReply.store(
      if r.isOk:
        ord(r.get.state)
      else:
        -1
    )
    releasePerThread()

  proc stalledStart(
      e: Engine, instance: string, t: var Thread[(Engine, string)]
  ): bool =
    ## Starts `instance` from `t` with the Loader's `realize` reply held: the
    ## host runs and serves, and the Runtime has not adopted it. [IMPL] The
    ## wait for the hold is `Answer`: under ASan on a host at load 100 a
    ## hosted realize took longer than 10 s times Slow (4b-8's closing
    ## check). If it never comes, the start is let through (the release is
    ## kept for a reply that is still to be held) and joined, and the case
    ## checks nothing more.
    check e.setLoaderFaultsForTests(LoaderFaults(stall: {lmRealize})).isOk
    startReply.store(-2)
    createThread(t, startOn, (e, instance))
    result = waitUntil(
      proc(): bool =
        e.stalledLoaderCallsForTests() == 1,
      Answer,
    )
    check result
    if not result:
      e.releaseLoaderStallForTests()
      joinThread(t)

  # The caller ------------------------------------------------------------------------------

  type Invocation = object
    path: string
    ticket: RouteTicket

  proc recordOf(r: RcResult): LogosNSRuntimeControlRouteRecord =
    r.routesOf.routes[0]

  proc invocationOf(rec: LogosNSRuntimeControlRouteRecord): Opt[Invocation] =
    if rec.invocation.isNone:
      return Opt.none(Invocation)
    let d = rec.invocation.get
    if d.kind != LogosNSRuntimeControlInvocationDescriptorKind.Case0 or
        d.arm_0.ticket.len != TicketBytes:
      return Opt.none(Invocation)
    var t: RouteTicket
    copyMem(addr t[0], unsafeAddr d.arm_0.ticket[0], TicketBytes)
    Opt.some(Invocation(path: d.arm_0.path, ticket: t))

  proc renewed(r: RcResult): LogosNSRuntimeControlRouteRecord =
    LogosNSRuntimeControlRenewRouteResponse.decode(r.response).tryGet.route

  proc meterInput(): ContractInput =
    ContractInput(root: meterRoot, schema: meterSchema, system: false)

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

  proc open(o: Owner, inv: Invocation, selected = meterInput()): (ConnId, IoEvent) =
    inc nextConn
    let conn = nextConn
    o.connect(conn, inv.path, inv.ticket, module = MeterModule, selected = selected)
    let ev = o.seen(
      proc(ev: IoEvent): bool =
        ev.conn == conn and ev.kind in {evConnected, evConnectFailed}
    )
    doAssert ev.isSome, "no outcome for connection " & $conn
    (conn, ev.get)

  proc refusal(o: Owner, inv: Invocation, selected = meterInput()): ErrorCode =
    let (_, ev) = o.open(inv, selected)
    if ev.kind == evConnectFailed: ev.failCode else: ecOk

  proc session(o: Owner, inv: Invocation): ConnId =
    let (conn, ev) = o.open(inv)
    check ev.kind == evConnected
    conn

  proc send(o: Owner, conn: ConnId, channel: uint64, name = "read"): uint64 =
    inc nextTag
    o.call(conn, nextTag, name, cborMap((cbor("channel"), cbor(channel))))
    nextTag

  proc outcome(
      o: Owner, conn: ConnId, tag: uint64, timeoutMs = Wait
  ): Opt[CallOutcome] =
    let ev = o.seen(
      proc(ev: IoEvent): bool =
        ev.kind == evResponse and ev.conn == conn and ev.tag == tag,
      timeoutMs,
    )
    if ev.isNone:
      Opt.none(CallOutcome)
    else:
      Opt.some(ev.get.outcome)

  proc codeOf(o: Opt[CallOutcome]): Opt[ErrorCode] =
    if o.isNone:
      Opt.none(ErrorCode)
    elif o.get.ok:
      Opt.some(ecOk)
    else:
      Opt.some(o.get.failure.code)

  proc reading(o: Opt[CallOutcome]): MeterReadResponse =
    doAssert o.isSome and o.get.ok
    MeterReadResponse.decode(o.get.result).tryGet

  proc responses(o: Owner, conn: ConnId, tag: uint64): int =
    for ev in o.log:
      if ev.kind == evResponse and ev.conn == conn and ev.tag == tag:
        inc result

  proc closedOf(o: Owner, conn: ConnId, timeoutMs = Wait): Opt[IoEvent] =
    o.seen(
      proc(ev: IoEvent): bool =
        ev.kind == evClosed and ev.conn == conn,
      timeoutMs,
    )

  # Events -------------------------------------------------------------------------------

  type Heard = object ## One subscription's deliveries.
    count: Atomic[int]
    last: Atomic[int]

  var heard: array[2, Heard]

  proc onHeard(
      name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
  ) {.cdecl, gcsafe, raises: [].} =
    let s = cast[ptr Heard](userData)
    if len > 0:
      let ev = MeterChangedEvent.decode(toOpenArray(data, 0, int(len) - 1))
      if ev.isOk:
        s.last.store(int(ev.get.value))
    s.count += 1

  proc hear(
      h: var LogosRouteHandle, slot: int, id: var LogosSubscriptionId
  ): ErrorCode =
    if h.vtable == nil:
      return ecNotReady # not materialized: the case fails here, not in a crash
    toResult(
      h.vtable.subscribe(
        addr h, cstring("meter.changed_event"), onHeard, addr heard[slot], addr id
      )
    ).code

  # Call records ---------------------------------------------------------------------------

  type Kept = object ## One call record's outcome and commitments.
    success: bool
    request, response: Opt[LogosNSCapabilityAuthorityAuditValueCommitment]

  proc routeOf(e: Engine, route: string): Opt[LogosNSRuntimeControlRouteRecord] =
    for rec in e.routes():
      if rec.route == route:
        return Opt.some(rec)
    Opt.none(LogosNSRuntimeControlRouteRecord)

  proc keptReach(e: Engine, n: int): bool =
    waitUntil(
      proc(): bool =
        e.audit.records.len >= n,
      Answer,
    )

  proc lastKept(e: Engine): Kept =
    ## The newest call record.
    let rs = e.audit.records
    doAssert rs.len > 0, "no call record"
    let r = AuditRecord.decode(rs[^1].bytes).tryGet
    type K = AuditKind
    var c: Opt[LogosNSCapabilityAuthorityCallCommitments]
    case r.kind
    of K.Call_success:
      result.success = true
      c = Opt.some(r.arm_Call_success.commitments)
    of K.Call_failure:
      c = r.arm_Call_failure.commitments
    else:
      doAssert false, "not a call record"
    if c.isSome:
      type C = LogosNSCapabilityAuthorityCallCommitmentsKind
      case c.get.kind
      of C.Map_request:
        result.request = Opt.some(c.get.arm_Map_request.request)
        result.response = c.get.arm_Map_request.response
      of C.Map_response:
        result.response = Opt.some(c.get.arm_Map_response.response)

  func textBytes(s: string): seq[byte] =
    for c in s:
      result.add(byte(c))

  proc heardAt(slot, n: int): bool =
    waitUntil(
      proc(): bool =
        heard[slot].count.load >= n,
      Answer,
    )

  type SubEnds = object ## [G225] What a handle's subscription-end handler saw.
    count: Atomic[int]
    id: Atomic[uint64]
    reason: Atomic[int]

  var subEnds: SubEnds

  proc onSubEnd(
      id: LogosSubscriptionId, reason: CErrorCode, userData: pointer
  ) {.cdecl, gcsafe, raises: [].} =
    let e = cast[ptr SubEnds](userData)
    e.id.store(uint64(id))
    e.reason.store(int(reason))
    e.count += 1

  proc observeSubEnd(h: var LogosRouteHandle): ErrorCode =
    subEnds.count.store(0)
    toResult(h.vtable.observeSubscriptionEnd(addr h, onSubEnd, addr subEnds)).code

  proc unsubscribe(h: var LogosRouteHandle, id: LogosSubscriptionId): ErrorCode =
    toResult(h.vtable.unsubscribe(addr h, id)).code

  proc underAuthority(): EngineConfig =
    ## `hosted` with the fake Capability Authority bound (instance "ca").
    resetFake()
    result = hosted()
    result.statics.add(fakeCaRegistration())
    result.authority = Opt.some(
      AuthorityPolicy(instance: "ca", evaluationDeadline: initDuration(seconds = 60))
    )

  proc startAuthority(e: Engine) =
    discard e.create(fakeCaRecord(), "ca").tryGet
    doAssert e.start("ca").tryGet.state == msReady

  # P-1 to P-5 -------------------------------------------------------------------------

  suite "run.hosted: a hosted provider's endpoint (LOADER §5.3; RUNTIME §3.4; TRANSPORT §8.2)":
    teardown:
      leftover()
      check noHostLeft()

    test "[RUN-0200] [TRN-0185] [RUN-0223] [RUN-0228] [LDR-0145] [LDR-0047] [LDR-0048] [LDR-0049] [LDR-0101] [LDR-0102] [IMPL-DECISION G272] P-1 P-3 the Runtime makes a hosted provider's endpoint, private, before the host serves it; a route with no rule is local-transport; consumer-only and direct realizations serve none":
      let cfg = hosted()
      discard cfg.stateOf()
      discard cfg.stateOf("p")
      writeFile(cfg.stateRoot.get / "p" / "probe.cmd", "\n")
      let e = fixtureEngine(cfg)
      let hm = e.started(hostedMeter(), "hm")
      check hm.state == msReady
      check hostPids(hostProgram).len == 1
      # The endpoint the Runtime made and the record named (the engine adopts
      # a hosted provider only when its record names exactly that path).
      let path = e.hostedEndpointForTests("hm")
      check path.startsWith(cfg.endpointDir & "/")
      check path.endsWith("/logos_meter_module.sock")
      check path.isSocket
      check path.modeOf == 0o600
      check path.parentDir.modeOf == 0o700
      check cfg.endpointDir.modeOf == 0o700
      # No rule names the meter: the route is local-transport, to that path.
      let (_, rc) = e.startClient("c")
      let rec = rc.establish("k").recordOf
      let inv = rec.invocationOf
      check inv.isSome
      if inv.isSome:
        check inv.get.path == path
      var h = rc.handle(rec.route)
      let r = h.read(5)
      check r.isOk
      if r.isOk:
        check r.get.reading.value == 50
      h.release()
      # A consumer-only hosted realization and a direct one serve none.
      discard e.create(hostedProbe(), "p").tryGet
      check e.start("p").tryGet.state == msReady
      check e.hostedEndpointForTests("p") == ""
      discard e.started(meter(), "dm")
      check e.hostedEndpointForTests("dm") == ""
      check cfg.endpointDir.socketsUnder.len == 1
      # The endpoint goes with the realization.
      check e.stop("hm").tryGet.state == msUnloaded
      check not path.isSocket
      check not path.parentDir.dirExists
      e.finish()

    test "[RUN-0221] [RUN-0222] [RUN-0224] [RUN-0225] [LDR-0050] [LDR-0083] [PKG-0288] P-2 a hosted provider is not ready until the Runtime adopted its served endpoint; a route to it is NOT_READY until then":
      let cfg = hosted()
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      let (_, rc) = e.startClient("c")
      discard e.create(hostedMeter(), "hm").tryGet
      var t: Thread[(Engine, string)]
      if e.stalledStart("hm", t):
        # The host serves already (it answered `initialized` only then), and
        # the Runtime has not adopted it.
        check hostPids(hostProgram).len == 1
        check e.hostedEndpointForTests("hm").isSocket
        check e.view("hm").tryGet.state != msReady
        check rc.establish("early").code == ecNotReady
        e.releaseLoaderStallForTests()
        joinThread(t)
        check startReply.load == ord(msReady)
        check rc.establish("k").code == ecOk
      e.finish()

    test "[TRN-0186] [LDR-0089] [LDR-0165] [BCP-0028] [BCP-0036] [BCP-0049] [BCP-0050] P-4 a listener that does not reach the host fails the placement; nothing falls back to direct and nothing is left served":
      let cfg = hosted()
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.create(hostedMeter(), "hm").tryGet
      dropNextListener()
      let r = e.start("hm")
      check r.isErr or r.get.state != msReady
      let v = e.view("hm").tryGet
      check v.state == msError
      check v.failureOf == "loader-realization-failed"
      check noHostLeft()
      for j in e.loaderJournalForTests():
        if j.meth == $lmRealize:
          check j.strategy == "hosted_dynamic"
      check cfg.endpointDir.socketsUnder.len == 0
      e.finish()

    test "[TRN-0185] [RUN-0223] P-5 an endpoint path replaced after the host serves it fails validation before ready: the start fails and nothing is served":
      let cfg = hosted()
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.create(hostedMeter(), "hm").tryGet
      var t: Thread[(Engine, string)]
      if e.stalledStart("hm", t):
        let path = e.hostedEndpointForTests("hm")
        check path.isSocket
        moveFile(path, path & ".moved")
        e.releaseLoaderStallForTests()
        joinThread(t)
        check startReply.load != ord(msReady)
        check e.view("hm").tryGet.state == msError
        check e.diagnostics().anyIt("is not valid" in it)
        check noHostLeft()
      e.finish()

    test "[RUN-0705] [RUN-1074] P-5b a shutdown accepted while a hosted provider's realize reply is held stops its endpoint at once; the reply that then names it is no Loader failure: the attempt fails and nothing is left":
      # Tier 4b step 4b-6 (test_logosd's unclean-end case found it): the
      # record names the endpoint made for it, which shutdown has stopped.
      let cfg = hosted()
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.create(hostedMeter(), "hm").tryGet
      var t: Thread[(Engine, string)]
      if e.stalledStart("hm", t):
        let path = e.hostedEndpointForTests("hm")
        check path.isSocket
        e.requestShutdown()
        # [SPEC RUNTIME l.3846-3849] Shutdown's first step: no endpoint serves.
        check waitUntil(
          proc(): bool =
            not path.isSocket
        )
        e.releaseLoaderStallForTests()
        joinThread(t)
        check startReply.load != ord(msReady)
        let down = e.awaitShutdown()
        if down.isErr:
          checkpoint "shutdown: " & down.error.message
          checkpoint "engine: " & e.diagnostics().join(" | ")
        check down.isOk
        check not e.diagnostics().anyIt("invalid response" in it)
        check not e.diagnostics().anyIt("Module Loader has failed" in it)
        check e.view("hm").tryGet.state != msReady
        check noHostLeft()
      e.finish()

    test "[IMPL-DECISION G272] R10 a direct routing rule meeting a hosted end: establish_route is NOT_READY with the reason":
      var cfg = hosted()
      cfg.routing = @[RoutingRule(callee: MeterModule, mode: rmDirect)]
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      let (_, rc) = e.startClient("c")
      let r = rc.establish("k")
      check r.code == ecNotReady
      check "Module Host" in r.message
      e.finish()

  # P-6 to P-12 ------------------------------------------------------------------------

  suite "run.hosted: sessions at a hosted provider (TRANSPORT §3.1, §6, §8.1; RUNTIME §7.5)":
    setup:
      for h in heard.mitems:
        h.count.store(0)
        h.last.store(0)
    teardown:
      setCancelMarkDelayForTests(0)
      leftover()
      check noHostLeft()

    test "[RUN-0226] [LDR-0147] [CAP-0254] [TRN-0153] P-6 at a hosted endpoint a ticket opens one session; the path alone, a forged, used or expired ticket is NOT_AUTHORISED; a wrong schema is VERSION_MISMATCH; another provider's ticket is NOT_AUTHORISED and stays live":
      var clock = newTestClock()
      defer:
        clock.freeClock()
      let cfg = hosted(clock = clock)
      discard cfg.stateOf("m1")
      discard cfg.stateOf("m2")
      let e = fixtureEngine(cfg)
      let one = e.started(hostedMeter("m1"), "h1")
      let two = e.started(hostedMeter("m2"), "h2")
      let (_, rc) = e.startClient("c")
      let rec =
        rc.establish("k", provider = Opt.some(providerAddress(one.providerId))).recordOf
      let inv = rec.invocationOf.get
      check inv.path == e.hostedEndpointForTests("h1")
      let o = newOwner(roomy())
      defer:
        o.stop()
      # The path alone: a ticket the Runtime never issued.
      var forged = inv
      for i in 0 ..< forged.ticket.len:
        forged.ticket[i] = byte(i)
      check o.refusal(forged) == ecNotAuthorised
      check o.refusal(inv, storageInput()) == ecVersionMismatch
      # [Rev R24; TRANSPORT l.960] h1's ticket at h2's endpoint: refused, and
      # still live for its own.
      var elsewhere = inv
      elsewhere.path = e.hostedEndpointForTests("h2")
      check elsewhere.path != inv.path
      check o.refusal(elsewhere) == ecNotAuthorised
      let conn = o.session(inv)
      check o.outcome(conn, o.send(conn, 4)).reading.reading.value == 40
      check o.refusal(inv) == ecNotAuthorised
      let fresh = rc.renew("r", rec.route).renewed.invocationOf.get
      clock.advance(61_000)
      check o.refusal(fresh) == ecNotAuthorised
      discard two
      e.finish()

    test "[RUN-0226] [RUN-0220] [RUN-0229] [RUN-0230] [RUN-0231] [RUN-0815] P-8 calls on two sessions run at once in the host and answer out of order; the caller is the ticket's consumer; logos.schema is served; a deferred provider completes":
      let cfg = hosted()
      let dir = cfg.stateOf()
      discard cfg.stateOf("d")
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      let (c1, rc1) = e.startClient("c1")
      let (c2, rc2) = e.startClient("c2")
      let o = newOwner(roomy())
      defer:
        o.stop()
      let a = o.session(rc1.establish("k").recordOf.invocationOf.get)
      let b = o.session(rc2.establish("k").recordOf.invocationOf.get)
      # Each session's caller is its route's consumer.
      let whoA = o.outcome(a, o.send(a, 18)).reading
      let whoB = o.outcome(b, o.send(b, 18)).reading
      check whoA.label == c1.instance
      check whoB.label == c2.instance
      check whoA.reading.label == Opt.some(e.runtimeInstanceId)
      # A held call holds neither its session nor the other.
      let slow = o.send(a, 22)
      check dir.heldAt(1)
      check o.outcome(a, o.send(a, 5)).reading.reading.value == 50
      check o.outcome(b, o.send(b, 6)).reading.reading.value == 60
      check o.responses(a, slow) == 0
      dir.open()
      check o.outcome(a, slow).codeOf == Opt.some(ecOk)
      # Introspection over the session (E3).
      inc nextTag
      o.call(b, nextTag, "schema", cborMap())
      let s = o.outcome(b, nextTag)
      check s.codeOf == Opt.some(ecOk)
      if s.isSome and s.get.ok:
        check s.get.result == meterSchema
      # A deferred provider in a host: `submit` completes the invocation.
      let d = e.started(hostedMeter("d", deferredLib, deferredDigest, "deferred"), "hd")
      let rd =
        rc1.establish("kd", provider = Opt.some(providerAddress(d.providerId))).recordOf
      let cd = o.session(rd.invocationOf.get)
      check o.outcome(cd, o.send(cd, 7)).reading.reading.value == 70
      check o.outcome(cd, o.send(cd, 13)).codeOf == Opt.some(ecModule)
      e.finish()

    test "[IFC-0979] [IFC-0980] [TXT-0034] [RUN-0815] [IMPL-DECISION G274] P-9 a hosted provider's failure passes through; an invalid status, a status outside the provider set or a response outside the schema is MODULE_ERROR, as direct, checked in the Module Host":
      let cfg = hosted()
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      discard e.started(meter(), "dm")
      let (_, rc) = e.startClient("c")
      let hm = e.view("hm").tryGet
      let dm = e.view("dm").tryGet
      var hh = rc.handle(
        rc.establish("kh", provider = Opt.some(providerAddress(hm.providerId))).recordOf.route
      )
      var hd = rc.handle(
        rc.establish("kd", provider = Opt.some(providerAddress(dm.providerId))).recordOf.route
      )
      for channel in [13'u32, 14, 16, 9001, 9002, 9003, 9004, 9005]:
        checkpoint("channel " & $channel)
        let viaHost = hh.read(channel)
        let direct = hd.read(channel)
        check viaHost.isErr and direct.isErr
        if viaHost.isErr and direct.isErr:
          check viaHost.error.code == direct.error.code
          check viaHost.error.code == ecModule
          check viaHost.error.message == direct.error.message
          if channel >= 9001:
            check viaHost.error.message.isNone
      hh.release()
      hd.release()
      e.finish()

    test "[CAP-0210] [CAP-0211] [CAP-0213] [RUN-0815] [IMPL-DECISION G274] P-14 under a Capability Authority whose allow retains both sides, a hosted call's record holds the provider host's commitments, the same as the direct provider's for the same call; a provider failure's holds the request side only":
      resetFake()
      var cfg = hosted()
      cfg.statics.add(fakeCaRegistration())
      cfg.authority = Opt.some(
        AuthorityPolicy(instance: "ca", evaluationDeadline: initDuration(seconds = 60))
      )
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.create(fakeCaRecord(), "ca").tryGet
      check e.start("ca").tryGet.state == msReady
      check e.authorityBound()[0]
      discard e.started(hostedMeter(), "hm")
      discard e.started(meter(), "dm")
      let (_, rc) = e.startClient("c")
      let hm = e.view("hm").tryGet
      let dm = e.view("dm").tryGet
      var hh = rc.handle(
        rc.establish("kh", provider = Opt.some(providerAddress(hm.providerId))).recordOf.route
      )
      var hd = rc.handle(
        rc.establish("kd", provider = Opt.some(providerAddress(dm.providerId))).recordOf.route
      )
      var both = allow("call", validMs = 0)
      both.retainRequest = true
      both.retainResponse = true
      setScript(both)
      # The consumer has the host's Response before the Runtime has the
      # call's end, so a hosted call's record is waited for, as an
      # asynchronous call's is.
      check hh.read(5).isOk
      check e.keptReach(1)
      let viaHost = e.lastKept
      check hd.read(5).isOk
      check e.keptReach(2)
      let direct = e.lastKept
      check viaHost.success and direct.success
      check viaHost.request.isSome and viaHost.response.isSome
      check viaHost.request == direct.request
      check viaHost.response == direct.response
      # [CAP-0213] A provider failure committed the request only.
      check hh.read(13).isErr
      check e.keptReach(3)
      let failedHost = e.lastKept
      check hd.read(13).isErr
      check e.keptReach(4)
      let failedDirect = e.lastKept
      check e.audit.records.len == 4
      check not failedHost.success and not failedDirect.success
      check failedHost.request.isSome and failedHost.response.isNone
      check failedHost.request == failedDirect.request
      hh.release()
      hd.release()
      e.finish()

    test "[TRN-0392] [RUN-1095] [TXT-0088] [IMPL-DECISION G175] [IMPL-DECISION G225] P-15 under a Capability Authority, a subscribe-event deny at a hosted provider's delivery ends the subscription: the host's session sends the SubscriptionEnd, the subscriber's handle reports NOT_AUTHORISED once and its unsubscribe is LOGOS_OK once":
      let cfg = underAuthority()
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      e.startAuthority()
      discard e.started(hostedMeter(), "hm")
      let (_, rc) = e.startClient("c")
      var k = rc.handle(rc.establish("k").recordOf.route)
      heard[0].count.store(0)
      check k.observeSubEnd() == ecOk
      var a: LogosSubscriptionId
      check k.hear(0, a) == ecOk
      check k.read(15).isOk
      check heardAt(0, 1)
      setScript(rule(vDeny, "subscribe-event"))
      check publish(PolicyChangedName, policyChanged(0, 1))
      check k.read(15).isOk
      check waitUntil(
        proc(): bool =
          subEnds.count.load >= 1,
        Answer,
      )
      sleep(100 * Slow)
      check heard[0].count.load == 1
      check subEnds.count.load == 1
      check subEnds.id.load == uint64(a)
      check subEnds.reason.load == ord(ecNotAuthorised)
      check k.unsubscribe(a) == ecOk
      check k.unsubscribe(a) == ecInvalidParams
      setScript()
      k.release()
      e.finish()

    test "[RUN-0226] [IMPL-DECISION G244] P-7 per-call admission at a hosted provider: a method outside the route's access is NOT_AUTHORISED and reaches no provider":
      let cfg = hosted()
      let dir = cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      let (_, rc) = e.startClient("c")
      let o = newOwner(roomy())
      defer:
        o.stop()
      let rec =
        rc.establish("k", scope = access(methods = Opt.some(newSeq[seq[byte]]())))
      if rec.code == ecOk:
        let conn = o.session(rec.recordOf.invocationOf.get)
        check o.outcome(conn, o.send(conn, 22)).codeOf == Opt.some(ecNotAuthorised)
        check dir.heldCalls == 0
      else:
        check rec.code in {ecInvalidParams, ecNotAuthorised}
      e.finish()

    test "[TRN-0317] [RUN-1101] [IMPL-DECISION G260] P-11 [TXT-0124] revocation leaves a hosted provider's in-flight Request unanswered and ends the session NOT_AUTHORISED, at which the caller fails it TRANSPORT_ERROR; close_route drains, then ProtocolError NOT_READY":
      let cfg =
        hosted(denying(deny(action = Opt.some(aaRoute), operation = "renew_route")))
      let dir = cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      let (_, rc) = e.startClient("c")
      let o = newOwner(roomy())
      defer:
        o.stop()
      block revoked:
        let rec = rc.establish("k").recordOf
        let conn = o.session(rec.invocationOf.get)
        let tag = o.send(conn, 22)
        check dir.heldAt(1)
        check rc.renew("r", rec.route).code == ecNotAuthorised
        check o.outcome(conn, tag).codeOf == Opt.some(ecTransport)
        let closed = o.closedOf(conn)
        check closed.isSome
        if closed.isSome:
          check closed.get.cause == ccPeerError
          check closed.get.code == ecNotAuthorised
          check tag in closed.get.ids # [P5 Q3 (a)] the close failed it
        dir.open()
        o.settle(50 * Slow)
        check o.responses(conn, tag) == 1
      removeFile(dir / "open")
      removeFile(dir / "held")
      block closing:
        # Channel 23: the provider goes on after its invocation is marked
        # cancelled, as every route's end marks its admitted calls (INTERFACE
        # l.2101).
        let rec = rc.establish("k2").recordOf
        let conn = o.session(rec.invocationOf.get)
        let tag = o.send(conn, 23)
        check dir.heldAt(1)
        check rc.close(rec.route).code == ecOk
        check o.outcome(conn, o.send(conn, 4)).codeOf == Opt.some(ecNotReady)
        check o.closedOf(conn, 50 * Slow).isNone # still draining
        # [IMPL] The call's cancel reaches the host behind what the Runtime
        # ordered first (I91), and 50 ms times Slow was not always enough for
        # it under MSan on a host at load 100 (4b-8's closing check): the
        # provider tells when it sees it.
        check waitUntil(
          proc(): bool =
            fileExists(dir / "cancelled"),
          Answer,
        )
        dir.open()
        let late = o.outcome(conn, tag)
        check late.codeOf == Opt.some(ecOk)
        if late.codeOf == Opt.some(ecOk):
          check late.reading.reading.value == 1 # it saw `is_cancelled`
        let closed = o.closedOf(conn)
        check closed.isSome
        if closed.isSome:
          check closed.get.cause == ccPeerError
          check closed.get.code == ecNotReady
      e.finish()

    test "[TRN-0317] [RUN-1101] P-11b a revoked route's termination reaches a hosted provider's host before its call's cancel: the provider, which returns once cancelled, commits nothing, even while the Runtime thread is slow to go on after marking the call cancelled; the caller fails the Request TRANSPORT_ERROR at the close":
      # [IMPL; I91] The Runtime thread waits after it marks the route's call
      # cancelled, so the call worker forwards the cancel long before the
      # thread goes on. The meter returns on the cancel (channel 22). No
      # Runtime answer comes any more (P5 Q3 (a)): the host must have ended
      # the call at the terminate order, which comes first, so the provider's
      # OK is not committed (CI on dc2e7ef: P-11 under refc got it).
      let cfg =
        hosted(denying(deny(action = Opt.some(aaRoute), operation = "renew_route")))
      let dir = cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      let (_, rc) = e.startClient("c")
      let o = newOwner(roomy())
      defer:
        o.stop()
      let rec = rc.establish("k").recordOf
      let conn = o.session(rec.invocationOf.get)
      let tag = o.send(conn, 22)
      check dir.heldAt(1)
      setCancelMarkDelayForTests(300 * Slow)
      check rc.renew("r", rec.route).code == ecNotAuthorised
      let got = o.outcome(conn, tag)
      setCancelMarkDelayForTests(0)
      check got.codeOf == Opt.some(ecTransport)
      if got.codeOf == Opt.some(ecOk):
        checkpoint "the provider's own result was committed: value " &
          $got.reading.reading.value
      let closed = o.closedOf(conn)
      check closed.isSome
      if closed.isSome:
        check closed.get.cause == ccPeerError
        check closed.get.code == ecNotAuthorised
        check tag in closed.get.ids
      o.settle(50 * Slow)
      check o.responses(conn, tag) == 1
      e.finish()

    test "[TRN-0317] [CAP-0254] [RUN-1101] P-11c under a Capability Authority a hosted provider's session ends with the decision its ticket carried while the renewed route stays ready: the in-flight Request gets no Response, the caller fails it TRANSPORT_ERROR at the close, and the call is not recorded as a success though the provider returned one":
      resetFake()
      var clock = newTestClock()
      useClock(clock)
      defer:
        useClock(systemClock())
        clock.freeClock()
      var cfg = hosted(clock = clock)
      cfg.statics.add(fakeCaRegistration())
      cfg.authority = Opt.some(
        AuthorityPolicy(instance: "ca", evaluationDeadline: initDuration(seconds = 60))
      )
      let dir = cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.create(fakeCaRecord(), "ca").tryGet
      check e.start("ca").tryGet.state == msReady
      check e.authorityBound()[0]
      discard e.started(hostedMeter(), "hm")
      let (_, rc) = e.startClient("c")
      # A call decision that retains a side, so the call is recorded (CA
      # l.1176-1180).
      var retained = allow("call", validMs = 0)
      retained.retainRequest = true
      setScript(
        allow("establish-route", validMs = 1000),
        allow("renew-route", validMs = 10_000),
        retained,
      )
      let rec = rc.establish("k").recordOf
      let o = newOwner(roomy())
      defer:
        o.stop()
      let conn = o.session(rec.invocationOf.get)
      check rc.renew("r", rec.route).code == ecOk
      let kept = e.audit.records.len
      # Channel 22 returns its reading once the call is cancelled.
      let tag = o.send(conn, 22)
      check dir.heldAt(1)
      # [IMPL; I91] The Runtime thread waits after it decides the session's
      # call and after it marks it cancelled: a cancel forwarded to the host
      # meanwhile must not overtake the terminate order (as in P-11b).
      setCancelMarkDelayForTests(300 * Slow)
      clock.advance(1500)
      # Each look is a request, after which the Runtime thread checks its
      # deadlines on the test clock.
      check waitUntil(
        proc(): bool =
          discard e.routes()
          o.pump(1) or o.responses(conn, tag) > 0,
        Answer,
      )
      let got = o.outcome(conn, tag)
      setCancelMarkDelayForTests(0)
      check got.codeOf == Opt.some(ecTransport)
      if got.codeOf == Opt.some(ecOk):
        checkpoint "the provider's own result was committed: value " &
          $got.reading.reading.value
      let closed = o.closedOf(conn)
      check closed.isSome
      if closed.isSome:
        check closed.get.cause == ccPeerError
        check closed.get.code == ecNotAuthorised
        check tag in closed.get.ids
      check e.routeOf(rec.route).get.state.kind ==
        LogosNSRuntimeControlRouteStateKind.Ready
      check e.keptReach(kept + 1)
      check not e.lastKept.success
      o.settle(50 * Slow)
      check o.responses(conn, tag) == 1
      e.finish()

    test "[IFC-0729] [RUN-0230] P-12 Cancel to a hosted provider: the call ends CANCELLED, the provider sees is_cancelled, and its late result is not sent":
      let cfg = hosted()
      let dir = cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      let (_, rc) = e.startClient("c")
      let o = newOwner(roomy())
      defer:
        o.stop()
      let conn = o.session(rc.establish("k").recordOf.invocationOf.get)
      let tag = o.send(conn, 22)
      check dir.heldAt(1)
      o.cancel(conn, tag)
      check o.outcome(conn, tag).codeOf == Opt.some(ecCancelled)
      # The provider's wait ends on `is_cancelled`, not on `open`.
      o.settle(100 * Slow)
      check o.responses(conn, tag) == 1
      check o.outcome(conn, o.send(conn, 4)).codeOf == Opt.some(ecOk)
      e.finish()

    test "[RUN-0234] [RUN-0246] [IMPL-DECISION G175] P-10 a hosted provider's Event reaches transported subscribers on two connections; a per-delivery deny skips only one":
      let cfg =
        hosted(denying(deny(action = Opt.some(aaPublishEvent), target = "second")))
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      let (_, rf) = e.startClient("first")
      let (_, rs) = e.startClient("second")
      var k1 = rf.handle(rf.establish("k").recordOf.route)
      var k2 = rs.handle(rs.establish("k").recordOf.route)
      var a, b: LogosSubscriptionId
      check k1.hear(0, a) == ecOk
      check k2.hear(1, b) == ecOk
      # Channel 15 publishes `meter.changed_event` (value 150) from the host.
      let r = k1.read(15)
      check r.isOk
      check heardAt(0, 1)
      check heard[0].last.load == 150
      sleep(100 * Slow)
      check heard[1].count.load == 0
      check k2.read(4).isOk # skipped, with no signal: the session goes on
      k1.release()
      k2.release()
      e.finish()

    test "[TXT-0099] [IMPL-DECISION I106] P-10b a hosted provider's publish result is decided in its Module Host: an undeclared event and a nonconforming payload INVALID_PARAMS, unheard of by the Runtime; a valid one LOGOS_OK and delivered":
      let cfg = hosted()
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      let (_, rc) = e.startClient("c")
      var k = rc.handle(rc.establish("k").recordOf.route)
      heard[0].count.store(0)
      heard[0].last.store(0)
      var a: LogosSubscriptionId
      check k.hear(0, a) == ecOk
      # Channel 26: bit 0 the undeclared event refused, bit 1 the text value
      # refused, bit 2 the valid one taken.
      let r = k.read(26)
      check r.isOk and r.get.reading.value == 7
      check heardAt(0, 1)
      check heard[0].last.load == 260
      sleep(100 * Slow)
      check heard[0].count.load == 1
      check not e.diagnostics().anyIt("meter.unknown_event" in it)
      k.release()
      e.finish()

    test "[RUN-0815] [IMPL-DECISION G273] [IMPL-DECISION G274] P-13 payloads go between the consumer's process and the host directly: no carrier frame holds a request, a response or an event payload, and the call, its events and its schema answer still pass":
      # [plan §2.7; the owner's direct layout] Distinct payloads: the request
      # (channel 0x6C636E31), its response label, and the two events channel
      # 24 publishes, ordinary and scoped.
      let cfg = hosted()
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      let (_, rc) = e.startClient("c")
      var k = rc.handle(rc.establish("k").recordOf.route)
      heard[0].count.store(0)
      heard[0].last.store(0)
      var a: LogosSubscriptionId
      check k.hear(0, a) == ecOk
      let channel = 0x6C636E31'u32
      traceMarkers(
        [
          encodeCbor(cbor(uint64(channel))),
          textBytes("ch" & $channel),
          encodeCbor(cbor(0x6C636E32'u64)),
          encodeCbor(cbor(0x6C636E33'u64)),
        ]
      )
      let r = k.read(channel)
      check r.isOk
      if r.isOk:
        check r.get.label == "ch" & $channel
      check k.read(24).isOk
      check heardAt(0, 2)
      check heard[0].last.load == 0x6C636E33
      let (frames, hits) = traced()
      check frames > 0
      check hits == 0
      # The trace sees what does cross: the method name of each dispatch.
      traceMarkers([textBytes("read")])
      check k.read(5).isOk
      check traced().hits > 0
      traceMarkers([])
      k.release()
      e.finish()

  # A hosted consumer (part 4b-3.3) --------------------------------------------------------
  #
  # `probe_module` with `serve` runs commands from its state directory on its
  # own binding and route handles (`tests/kit/probe_impl.nim`). Realized
  # `hosted_dynamic`, its route handles live in the host, which connects to
  # the provider with the material it kept (RUN-0174); the Runtime admits
  # each materialization and operation (lane 1) and keeps the handle's codes.

  # `bulk_module` publishes an Event of any size (G165), as in `test_transported`.
  let
    bulkStatic = checkStaticRegistration("bulk", bulkModuleStaticSymbols()).tryGet
    bulkSet = acceptContractSet(readFile(repo / "tests/kit/bulk_module.cddl")).tryGet
    bulkRoot = bulkSet.primary.root
    bulkSchema = encodeCbor(schemaResponse(bulkSet, bulkRoot).tryGet)

  proc bulkRecord(): ModuleRecord =
    ModuleRecord(
      module: "bulk_module",
      strategy: stDirectStatic,
      binding: "bulk",
      primaryContract: Opt.some(bulkRoot),
    )

  # `vault_module` marks payloads (`_sensitive`): C-10 makes a route to it and
  # calls nothing. Its entries other than init and destroy are never reached;
  # calls on marked payloads are `test_wipe_routes`'s.
  const VaultDoc =
    "_module = \"vault_module\"\n" &
    "_sensitive = [\"vault.get_response\", \"vault.store_request\"]\n\n" &
    "vault.store_request = {\n  secret: bstr,\n}\n\n" &
    "vault.store_response = {\n  ok: bool,\n}\n\n" &
    "vault.get_request = {\n  slot: uint32,\n}\n\n" &
    "vault.get_response = {\n  secret: bstr,\n}\n"

  let
    vaultBinding = acceptBinding("vault_module", Opt.some(VaultDoc)).tryGet
    vaultRoot = vaultBinding.primary.get.root
    vaultSurfaceBytes = callSurfaceDescriptor(vaultBinding).tryGet
  var vaultSurface: ptr UncheckedArray[uint8]
  vaultSurface = cast[ptr UncheckedArray[uint8]](allocShared0(vaultSurfaceBytes.len))
  for i, b in vaultSurfaceBytes:
    vaultSurface[i] = b
  let vaultSurfaceLen = vaultSurfaceBytes.len

  proc vaultName(): cstring {.cdecl, gcsafe, raises: [].} =
    "vault_module"

  proc vaultCallSurface(outLen: ptr csize_t): ptr uint8 {.cdecl, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      outLen[] = csize_t(vaultSurfaceLen)
      cast[ptr uint8](vaultSurface)

  proc vaultInit(
      input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
  ): LogosResult {.cdecl, gcsafe, raises: [].} =
    outContext[] = cast[ptr LogosModuleContext](allocShared0(8))

  proc vaultDestroy(module: ptr LogosModuleContext) {.cdecl, gcsafe, raises: [].} =
    deallocShared(module)

  proc vaultFree(
      module: ptr LogosModuleContext, p: pointer
  ) {.cdecl, gcsafe, raises: [].} =
    if p != nil:
      deallocShared(p)

  proc vaultDispatch(
      module: ptr LogosModuleContext,
      methodName: cstring,
      params: ptr UncheckedArray[uint8],
      paramsLen: csize_t,
      outResp: ptr ptr UncheckedArray[uint8],
      outLen: ptr csize_t,
  ): LogosResult {.cdecl, gcsafe, raises: [].} =
    LogosResult(code: CErrorCode(ord(ecModule)))

  proc vaultTable(): seq[(string, pointer)] =
    result = @[
      ("logos_vault_module_MODULE_name", cast[pointer](vaultName)),
      ("logos_vault_module_MODULE_call_surface", cast[pointer](vaultCallSurface)),
      ("logos_vault_module_MODULE_init", cast[pointer](vaultInit)),
      ("logos_vault_module_MODULE_destroy", cast[pointer](vaultDestroy)),
      ("logos_vault_module_MODULE_dispatch", cast[pointer](vaultDispatch)),
      ("logos_vault_module_MODULE_free", cast[pointer](vaultFree)),
    ]
    for c in cLayout(cSchemaSet(vaultBinding)).tryGet.calls:
      result.add((c.symbol, cast[pointer](vaultDispatch)))

  proc consumerRecord(hosted = true, state = "c"): ModuleRecord =
    ModuleRecord(
      module: "probe_module",
      strategy: (if hosted: stHostedDynamic else: stDirectDynamic),
      placement: (if hosted: "process" else: ""),
      artifact: ArtifactRecord(
        id: "probe", localPath: probeLib, hash: probeDigest, hashSuite: HashSuiteId
      ),
      stateAssignment: Opt.some(state),
    )

  # `listener_impl` is a consumer written with lcn-gen's typed helpers (G339):
  # the beacon kit's provider, which opens its route to the meter with
  # `kit/routes` at initialization (`tests/kit/listener_impl.nim`).
  let beaconRoot = acceptContractSet(
    readFile(repo / "sdk/src/logos_sdk/testing/fixtures/beacon_module.cddl")
  ).tryGet.primary.root

  proc listenerRecord(hosted = true, state = "l"): ModuleRecord =
    ModuleRecord(
      module: "beacon_module",
      strategy: (if hosted: stHostedDynamic else: stDirectDynamic),
      placement: (if hosted: "process" else: ""),
      artifact: ArtifactRecord(
        id: "listener",
        localPath: listenerLib,
        hash: listenerDigest,
        hashSuite: HashSuiteId,
      ),
      primaryContract: Opt.some(beaconRoot),
      stateAssignment: Opt.some(state),
    )

  type Consumer = object ## The probe's command files.
    dir: string ## its state directory
    n: int ## the commands posted

  proc serving(cfg: EngineConfig, state = "c", extra = ""): Consumer =
    ## The probe's state directory, with `serve` and `extra` as its commands.
    let dir = cfg.stateOf(state)
    writeFile(dir / "probe.cmd", "serve\n" & extra)
    Consumer(dir: dir)

  func hexOf(b: openArray[byte]): string =
    for x in b:
      result.add(toHex(x, 2).toLowerAscii)

  proc unhexOf(s: string): seq[byte] =
    var i = 0
    while i + 1 < s.len:
      result.add(byte(parseHexInt(s[i .. i + 1])))
      i += 2

  proc post(c: var Consumer, line: string): int =
    ## Hands the probe's command thread one command, written whole; its number.
    inc c.n
    let path = c.dir / ("cmd-" & $c.n)
    writeFile(path & ".tmp", line)
    moveFile(path & ".tmp", path)
    c.n

  proc outcome(c: Consumer, n: int, seconds = Answer): string =
    ## The probe's answer to command `n`, `<code> <hex value or message>`;
    ## `none` if it gave none in time.
    let path = c.dir / ("out-" & $n)
    if not waitUntil(
      proc(): bool =
        fileExists(path),
      seconds,
    ):
      return "none"
    readFile(path)

  proc run(c: var Consumer, line: string): string =
    c.outcome(c.post(line))

  proc codeIn(line: string): Opt[ErrorCode] =
    try:
      errorCode(parseBiggestInt(line.split(' ', 1)[0]))
    except ValueError:
      Opt.none(ErrorCode)

  func valueIn(line: string): string =
    let w = line.split(' ', 1)
    if w.len > 1:
      w[1]
    else:
      ""

  proc linesOf(c: Consumer, file: string): seq[string] =
    try:
      readFile(c.dir / file).splitLines.filterIt(it.len > 0)
    except IOError:
      @[]

  proc noted(c: Consumer, file, prefix: string, n = 1, seconds = Answer): bool =
    ## `file` has `n` lines that start with `prefix`.
    waitUntil(
      proc(): bool =
        c.linesOf(file).countIt(it.startsWith(prefix)) >= n,
      seconds,
    )

  proc establishRecVia(
      c: var Consumer, key: string, root = meterRoot
  ): Opt[LogosNSRuntimeControlRouteRecord] =
    ## The route record `establish_route` gave the probe.
    let line = c.run("rc establish_route " & hexOf(establishReq(key, root)))
    check codeIn(line) == Opt.some(ecOk)
    if codeIn(line) != Opt.some(ecOk):
      return
    let resp =
      LogosNSRuntimeControlEstablishRouteResponse.decode(unhexOf(valueIn(line)))
    check resp.isOk and resp.get.routes.len == 1
    if resp.isErr or resp.get.routes.len != 1:
      return
    Opt.some(resp.get.routes[0])

  proc establishVia(c: var Consumer, key: string): string =
    ## The route `establish_route` gave the probe, or "".
    let rec = c.establishRecVia(key)
    if rec.isNone: "" else: rec.get.route

  proc closeVia(c: var Consumer, route: string): Opt[ErrorCode] =
    codeIn(
      c.run(
        "rc close_route " &
          hexOf(encode(LogosNSRuntimeControlCloseRouteRequest(route: route)).tryGet)
      )
    )

  proc renewLine(c: var Consumer, key, route: string): string =
    c.run(
      "rc renew_route " &
        hexOf(
          encode(LogosNSRuntimeControlRenewRouteRequest(request_key: key, route: route)).tryGet
        )
    )

  proc renewVia(c: var Consumer, key, route: string): Opt[ErrorCode] =
    codeIn(c.renewLine(key, route))

  proc materializeVia(c: var Consumer, slot: int, route: string): Opt[ErrorCode] =
    let line = c.run(
      "materialize " & $slot & " " & route & " " & hexOf(meterRoot) & " " &
        hexOf(meterSchema)
    )
    checkpoint("materialize: " & line)
    codeIn(line)

  proc readLine(slot: int, channel: uint32): string =
    "call " & $slot & " read " & hexOf(
      encode(MeterReadRequest(channel: channel)).tryGet
    )

  proc readVia(c: var Consumer, slot: int, channel: uint32): string =
    c.run(readLine(slot, channel))

  proc prepareLine(call: int, channel: uint32, timeout: string): string =
    ## Prepares call `call` on slot 0's handle; `timeout` in ms, or `-`.
    "prepare 0 " & $call & " read " &
      hexOf(encode(MeterReadRequest(channel: channel)).tryGet) & " " & timeout

  proc doneOf(c: Consumer, call: int): string =
    ## Prepared call `call`'s completion, `<code> <hex value or message>`.
    for line in c.linesOf("done"):
      if line.startsWith($call & " "):
        return line.split(' ', 1)[1]
    "none"

  let malformedRead = hexOf(encodeCbor(cborMap(@[(cbor("channel"), cbor("x"))])))
    ## a `read` request whose `channel` is not a uint

  proc malformedVia(
      c: var Consumer, slot, call: int
  ): (Opt[ErrorCode], Opt[ErrorCode]) =
    ## The codes of a malformed `read` through slot `slot`: called, then
    ## prepared as call `call` and submitted (a refused preparation's code).
    let sync = codeIn(c.run("call " & $slot & " read " & malformedRead))
    let prepared =
      codeIn(c.run("prepare " & $slot & " " & $call & " read " & malformedRead & " -"))
    if prepared != Opt.some(ecOk):
      return (sync, prepared)
    check codeIn(c.run("submit " & $call)) == Opt.some(ecOk)
    check c.noted("done", $call & " ")
    var outcome = Opt.none(ErrorCode)
    for line in c.linesOf("done"):
      if line.startsWith($call & " "):
        outcome = codeIn(line.split(' ', 1)[1])
    check codeIn(c.run("release-call " & $call)) == Opt.some(ecOk)
    (sync, outcome)

  proc readingOf(line: string): Opt[MeterReadResponse] =
    if codeIn(line) != Opt.some(ecOk):
      return Opt.none(MeterReadResponse)
    let r = MeterReadResponse.decode(unhexOf(valueIn(line)))
    if r.isErr:
      Opt.none(MeterReadResponse)
    else:
      Opt.some(r.get)

  proc failedWith(e: Engine, route: string, code: string): bool =
    waitUntil(
      proc(): bool =
        let rec = e.routeOf(route)
        rec.isSome and rec.get.state.kind == LogosNSRuntimeControlRouteStateKind.Failed and
          rec.get.failure.isSome and rec.get.failure.get.code == code
    )

  proc killHost(e: Engine, instance: string): bool =
    ## SIGKILL to the instance's host process, from outside the Runtime.
    let h = e.moduleHostForTests(instance)
    if h.isNil:
      return false
    let pid = pidOf(h)
    dropHost(h)
    pid > 0 and posix.kill(Pid(pid), SIGKILL) == 0

  func endLine(tag: string, code: ErrorCode): string =
    tag & " " & $ord(code)

  suite "run.hosted: a hosted consumer's routes (RUNTIME §4.2.1; INTERFACE §2.5, §5.2)":
    teardown:
      leftover()
      check noHostLeft()

    test "[RUN-0173] [RUN-0174] [RUN-0177] [RUN-0181] [RUN-0800] [TRN-0187] [IMPL-DECISION G267] C-1 a hosted consumer establishes, materializes, calls, subscribes, observes the end and releases, to a direct provider and to a hosted one":
      for providerHosted in [false, true]:
        let cfg = hosted()
        discard cfg.stateOf()
        var c = cfg.serving()
        let e = fixtureEngine(cfg)
        discard e.started(
          if providerHosted:
            hostedMeter()
          else:
            meter(),
          "m",
        )
        check e.started(consumerRecord(), "c").state == msReady
        check hostPids(hostProgram).len == (if providerHosted: 2 else: 1)
        let rec = c.establishRecVia("k")
        let route = (if rec.isSome: rec.get.route else: "")
        # A route with a hosted end is local-transport (R10), also to a direct
        # provider: the answer carries its `invocation`, as a direct consumer's
        # local-transport route's does (RUNTIME l.3004, l.3009). The host keeps
        # it (RUN-0174) and connects with it to the peer identity the Runtime
        # names (TRN-0187).
        check rec.isSome and rec.get.invocationOf.isSome
        check c.materializeVia(0, route) == Opt.some(ecOk)
        let r = readingOf(c.readVia(0, 4))
        check r.isSome and r.get.label == "ch4" and r.get.reading.value == 40
        let sub = c.run("subscribe 0 meter.changed_event s1")
        check codeIn(sub) == Opt.some(ecOk)
        # Channel 21 publishes `meter.changed_event` (210) and answers with
        # its caller: the probe's own instance.
        let who = readingOf(c.readVia(0, 21))
        check who.isSome and who.get.label == "c"
        check c.noted("deliveries", "s1 meter.changed_event ")
        let delivered = c.linesOf("deliveries")
        if delivered.len > 0:
          let ev = MeterChangedEvent.decode(unhexOf(delivered[0].split(' ')[2]))
          check ev.isOk and ev.get.value == 210
        check codeIn(c.run("observe-end 0 e1")) == Opt.some(ecOk)
        check codeIn(c.run("unsubscribe 0 " & valueIn(sub))) == Opt.some(ecOk)
        check codeIn(c.run("unsubscribe 0 " & valueIn(sub))) != Opt.some(ecOk)
        discard c.readVia(0, 21)
        sleep(50 * Slow)
        check c.linesOf("deliveries").len == 1
        check codeIn(c.run("release 0")) == Opt.some(ecOk)
        # The route stays ready after the handle's release; the end handler
        # is not called (INTERFACE l.1461-1468).
        check e.routeOf(route).get.state.kind ==
          LogosNSRuntimeControlRouteStateKind.Ready
        check c.linesOf("ends").len == 0
        # `renew_route` gives the host a fresh invocation too (RUNTIME l.3468),
        # which it keeps for the next materialization.
        let renewed = c.renewLine("r", route)
        check codeIn(renewed) == Opt.some(ecOk)
        if codeIn(renewed) == Opt.some(ecOk):
          let rr =
            LogosNSRuntimeControlRenewRouteResponse.decode(unhexOf(valueIn(renewed)))
          check rr.isOk and rr.get.route.invocationOf.isSome
        check c.materializeVia(1, route) == Opt.some(ecOk)
        let again = readingOf(c.readVia(1, 4))
        check again.isSome and again.get.reading.value == 40
        check codeIn(c.run("release 1")) == Opt.some(ecOk)
        e.finish()
        check noHostLeft()

    test "[RUN-0177] [RUN-0178] [RUN-0179] C-2 the Runtime's own checks at materialization: another contract's construction input is VERSION_MISMATCH and malformed input INVALID_PARAMS, the host keeping its material; a route closed between establishment and materialization is NOT_READY":
      let cfg = hosted()
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(meter(), "m")
      discard e.started(consumerRecord(), "c")
      let route = c.establishVia("k")
      # The host sends the construction input as the module gave it, and the
      # Runtime rebuilds the contract itself (RUN-0177): a valid input for
      # another contract passes the host's local checks and is refused by the
      # Runtime, as for a direct consumer.
      const OtherDoc =
        "_module = \"other_module\"\n\n" & "other.ping_request = {\n  n: uint32,\n}\n\n" &
        "other.ping_response = {\n  n: uint32,\n}\n"
      let otherSet = acceptContractSet(OtherDoc).tryGet
      let otherSchema =
        encodeCbor(schemaResponse(otherSet, otherSet.primary.root).tryGet)
      proc materializeWith(c: var Consumer, schema: openArray[byte]): Opt[ErrorCode] =
        codeIn(
          c.run("materialize 0 " & route & " " & hexOf(meterRoot) & " " & hexOf(schema))
        )

      check c.materializeWith(otherSchema) == Opt.some(ecVersionMismatch)
      check c.materializeWith([0x00'u8]) == Opt.some(ecInvalidParams)
      # Neither used the material the host kept for the route.
      check c.materializeVia(0, route) == Opt.some(ecOk)
      check readingOf(c.readVia(0, 4)).isSome
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      let closed = c.establishVia("k2")
      check c.closeVia(closed) == Opt.some(ecOk)
      check c.materializeVia(1, closed) == Opt.some(ecNotReady)
      e.finish()

    test "[RUN-0174] [RUN-0177] C-2b a prepared establish_route or renew_route keeps the route's material in the host, as a synchronous one does: the handle materializes (Tier 5 step N-2b)":
      let cfg = hosted()
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(meter(), "m")
      discard e.started(consumerRecord(), "c")
      check codeIn(
        c.run("prepare rc 0 establish_route " & hexOf(establishReq("k")) & " -")
      ) == Opt.some(ecOk)
      check codeIn(c.run("submit 0")) == Opt.some(ecOk)
      check c.noted("done", "0 ")
      let made = c.doneOf(0).split(' ', 1)
      check made.len == 2 and made[0] == "0"
      var route = ""
      if made.len == 2:
        let resp = LogosNSRuntimeControlEstablishRouteResponse.decode(unhexOf(made[1]))
        check resp.isOk and resp.get.routes.len == 1
        if resp.isOk and resp.get.routes.len == 1:
          route = resp.get.routes[0].route
      check codeIn(c.run("release-call 0")) == Opt.some(ecOk)
      check c.materializeVia(0, route) == Opt.some(ecOk)
      check readingOf(c.readVia(0, 4)).isSome
      # The ticket is used: a renewal through a prepared call issues the next.
      check c.materializeVia(1, route) == Opt.some(ecNotAuthorised)
      let renew = encode(
        LogosNSRuntimeControlRenewRouteRequest(request_key: "k2", route: route)
      ).tryGet
      check codeIn(c.run("prepare rc 1 renew_route " & hexOf(renew) & " -")) ==
        Opt.some(ecOk)
      check codeIn(c.run("submit 1")) == Opt.some(ecOk)
      check c.noted("done", "1 ")
      check c.doneOf(1).startsWith("0 ")
      check codeIn(c.run("release-call 1")) == Opt.some(ecOk)
      check c.materializeVia(1, route) == Opt.some(ecOk)
      check readingOf(c.readVia(1, 5)).isSome
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      check codeIn(c.run("release 1")) == Opt.some(ecOk)
      e.finish()

    test "[RUN-0175] [RUN-0176] C-3 a hosted consumer cannot materialize another consumer's route: NOT_AUTHORISED; its own still works":
      let cfg = hosted()
      var first = cfg.serving("c")
      var second = cfg.serving("d")
      let e = fixtureEngine(cfg)
      discard e.started(meter(), "m")
      discard e.started(consumerRecord(state = "c"), "c")
      discard e.started(consumerRecord(state = "d"), "d")
      let route = first.establishVia("k")
      check second.materializeVia(0, route) == Opt.some(ecNotAuthorised)
      check first.materializeVia(0, route) == Opt.some(ecOk)
      check readingOf(first.readVia(0, 4)).isSome
      check codeIn(first.run("release 0")) == Opt.some(ecOk)
      e.finish()

    test "[RUN-1113] [RUN-1114] [TXT-0160] C-3b a hosted consumer's stale start and retire: the carrier brings back the response's error arm with the current revision, and nothing changes":
      # [re-pin P4a] A typed outcome is a successful response (RUNTIME
      # l.1818-1822): the host's binding carries its bytes back unchanged.
      let cfg = hosted()
      var c = cfg.serving("c")
      let e = fixtureEngine(cfg)
      discard e.create(meter(), "m").tryGet
      discard e.started(consumerRecord(state = "c"), "c")
      let rev = e.view("m").tryGet.execution.revision
      let start = c.run(
        "rc start_module " &
          hexOf(
            encode(
              LogosNSRuntimeControlStartModuleRequest(
                module: "meter_module",
                instance: Opt.some("m"),
                expected_execution_revision: Opt.some(rev + 1),
              )
            ).tryGet
          )
      )
      check codeIn(start) == Opt.some(ecOk)
      let started =
        LogosNSRuntimeControlStartModuleResponse.decode(unhexOf(valueIn(start))).tryGet
      check started.refusal.get.code.kind ==
        LogosNSRuntimeControlErrorCodeKind.Stale_revision
      check started.refusal.get.current_revision == Opt.some(rev)
      let retire = c.run(
        "rc retire_module " &
          hexOf(
            encode(
              LogosNSRuntimeControlRetireModuleRequest(
                target: LogosNSRuntimeModuleInstanceAddress(
                  runtime_instance_id: e.runtimeInstanceId, module_instance_id: "m"
                ),
                expected_execution_revision: rev + 1,
              )
            ).tryGet
          )
      )
      check codeIn(retire) == Opt.some(ecOk)
      let retired = LogosNSRuntimeControlRetireModuleResponse.decode(
        unhexOf(valueIn(retire))
      ).tryGet
      check retired.refusal.get.current_revision == Opt.some(rev)
      let v = e.view("m").tryGet
      check v.execution.revision == rev and v.state == msUnloaded
      e.finish()

    test "[RUN-0182] [RUN-0837] C-4 a provider restarted under a hosted consumer's open handle: the handle ends NOT_READY and is never retargeted":
      let cfg = hosted()
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(meter(), "m")
      discard e.started(consumerRecord(), "c")
      let route = c.establishVia("k")
      check c.materializeVia(0, route) == Opt.some(ecOk)
      check codeIn(c.run("observe-end 0 e1")) == Opt.some(ecOk)
      check e.stop("m").tryGet.state == msUnloaded
      check c.noted("ends", "e1 ")
      check c.linesOf("ends") == @[endLine("e1", ecNotReady)]
      check e.start("m").tryGet.state == msReady
      check codeIn(c.readVia(0, 4)) == Opt.some(ecNotReady)
      check e.failedWith(route, "provider-unavailable")
      check c.renewVia("r", route) == Opt.some(ecNotReady)
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      e.finish()

    test "[RUN-0805] [RUN-0256] [RUN-0837] [RUN-0838] [RUN-1101] C-5 a hosted provider's host killed during a hosted consumer's call: the call is TRANSPORT_ERROR, the end is reported once and never changes, and the failed route answers NOT_READY":
      let cfg = hosted()
      let mdir = cfg.stateOf()
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      discard e.started(consumerRecord(), "c")
      let route = c.establishVia("k")
      check c.materializeVia(0, route) == Opt.some(ecOk)
      check codeIn(c.run("observe-end 0 e1")) == Opt.some(ecOk)
      # Channel 23 holds the call in the provider until `open`.
      let n = c.post(readLine(0, 23))
      check mdir.heldAt(1)
      check e.killHost("hm")
      check codeIn(c.outcome(n)) == Opt.some(ecTransport)
      check c.noted("ends", "e1 ")
      let first = c.linesOf("ends")
      check first.len == 1
      if first.len == 1:
        check first[0] in [endLine("e1", ecTransport), endLine("e1", ecNotReady)]
      check e.failedWith(route, "provider-unavailable")
      check codeIn(c.readVia(0, 4)) == Opt.some(ecNotReady)
      sleep(50 * Slow)
      check c.linesOf("ends") == first
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      e.finish()

    test "[TRN-0191] [IMPL-DECISION G259] C-6 a peer that is not the expected identity, met for a hosted consumer: materialize is TRANSPORT_ERROR, the route fails transport-error and its ticket is dead":
      let cfg = hosted()
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(meter(), "m")
      discard e.started(consumerRecord(), "c")
      let route = c.establishVia("k")
      check e.failNextConnectForTests(cfPeerMismatch).isOk
      check c.materializeVia(0, route) == Opt.some(ecTransport)
      check e.failedWith(route, "transport-error")
      check e.diagnostics().anyIt("peer identity mismatch" in it)
      check c.renewVia("r", route) == Opt.some(ecNotReady)
      check c.materializeVia(1, route) == Opt.some(ecNotReady)
      e.finish()

    test "[RUN-0256] [RUN-0837] [IMPL-DECISION G260] C-7 close_route under a hosted consumer's open handle: the end and later calls are NOT_READY, not TRANSPORT_ERROR":
      let cfg = hosted()
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(meter(), "m")
      discard e.started(consumerRecord(), "c")
      let route = c.establishVia("k")
      check c.materializeVia(0, route) == Opt.some(ecOk)
      check codeIn(c.run("observe-end 0 e1")) == Opt.some(ecOk)
      check c.closeVia(route) == Opt.some(ecOk)
      check c.noted("ends", "e1 ")
      check c.linesOf("ends") == @[endLine("e1", ecNotReady)]
      check codeIn(c.readVia(0, 4)) == Opt.some(ecNotReady)
      check codeIn(c.run("observe-end 0 e2")) == Opt.some(ecNotReady)
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      e.finish()

    test "[IFC-0981] [TXT-0085] C-7b observe_subscription_end under a hosted consumer: one registration per binding and per handle, none called, none on a terminal handle (DECISIONS I105)":
      let cfg = hosted()
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(meter(), "m")
      discard e.started(consumerRecord(), "c")
      check codeIn(c.run("sub-end rc null")) == Opt.some(ecInvalidParams)
      check codeIn(c.run("sub-end rc s0")) == Opt.some(ecOk)
      check codeIn(c.run("sub-end rc s1")) == Opt.some(ecInvalidParams)
      let route = c.establishVia("k")
      check c.materializeVia(0, route) == Opt.some(ecOk)
      # A second handle on the route needs a fresh ticket (RUNTIME l.3468).
      check codeIn(c.renewLine("r", route)) == Opt.some(ecOk)
      check c.materializeVia(1, route) == Opt.some(ecOk)
      check codeIn(c.run("sub-end 0 null")) == Opt.some(ecInvalidParams)
      check codeIn(c.run("sub-end 0 s2")) == Opt.some(ecOk)
      check codeIn(c.run("sub-end 0 s3")) == Opt.some(ecInvalidParams)
      check codeIn(c.run("observe-end 0 e1")) == Opt.some(ecOk)
      check c.closeVia(route) == Opt.some(ecOk)
      check c.noted("ends", "e1 ")
      # [SPEC INTERFACE l.1459; I105] the Runtime's retained code, and nothing
      # installed: the same refusal again.
      check codeIn(c.run("sub-end 1 s4")) == Opt.some(ecNotReady)
      check codeIn(c.run("sub-end 1 s5")) == Opt.some(ecNotReady)
      # [IF l.1474] A route's end is not a binding end: nothing is reported.
      check c.linesOf("subends").len == 0
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      check codeIn(c.run("release 1")) == Opt.some(ecOk)
      e.finish()

    test "[TRN-0392] [RUN-1095] [TXT-0088] [IMPL-DECISION G225] C-11 under a Capability Authority, a hosted consumer's subscription ended by a subscribe-event deny at delivery is reported once by its handle, in the host, with NOT_AUTHORISED; its unsubscribe is LOGOS_OK once":
      let cfg = underAuthority()
      discard cfg.stateOf()
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      e.startAuthority()
      discard e.started(meter(), "m")
      check e.started(consumerRecord(), "c").state == msReady
      let route = c.establishVia("k")
      check c.materializeVia(0, route) == Opt.some(ecOk)
      check codeIn(c.run("sub-end 0 s1")) == Opt.some(ecOk)
      let sub = c.run("subscribe 0 meter.changed_event d1")
      check codeIn(sub) == Opt.some(ecOk)
      discard c.readVia(0, 21)
      check c.noted("deliveries", "d1 meter.changed_event ")
      setScript(rule(vDeny, "subscribe-event"))
      check publish(PolicyChangedName, policyChanged(0, 1))
      discard c.readVia(0, 21)
      check c.noted("subends", "s1 " & valueIn(sub) & " " & $ord(ecNotAuthorised))
      sleep(50 * Slow)
      check c.linesOf("deliveries").len == 1
      check c.linesOf("subends").len == 1
      check codeIn(c.run("unsubscribe 0 " & valueIn(sub))) == Opt.some(ecOk)
      check codeIn(c.run("unsubscribe 0 " & valueIn(sub))) == Opt.some(ecInvalidParams)
      setScript()
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      e.finish()

    test "[IMPL-DECISION G171] [RUN-1117] [RUN-1118] C-12 a hosted consumer's malformed call, synchronous and prepared: the Runtime's route access checks come before the host validates it; a call the provider's side denies is INVALID_PARAMS, as over local transport (l.1824-1828)":
      let cfg = hosted(
        denying(
          deny(action = Opt.some(aaCall), operation = "read", consumer = "c"),
          deny(action = Opt.some(aaRoute), operation = "renew_route", consumer = "c"),
        )
      )
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(meter(), "m")
      check e.started(consumerRecord(), "c").state == msReady
      let route = c.establishVia("k")
      check c.materializeVia(0, route) == Opt.some(ecOk)
      # [DECISIONS G171, interim reading] The provider's side decides the call
      # after its session dispatches the Request; the host's session cannot
      # commit a malformed payload (TRANSPORT §4.1) and refuses it first.
      check codeIn(c.readVia(0, 4)) == Opt.some(ecNotAuthorised)
      check c.malformedVia(0, 1) ==
        (Opt.some(ecInvalidParams), Opt.some(ecInvalidParams))
      # Step 2's route access checks, the Runtime's admission (`rc_link_admit`)
      # before the host's session: a method outside the route's access, then
      # a revoked route.
      let narrow = c.run(
        "rc establish_route " &
          hexOf(
            establishReq("n", scope = access(methods = Opt.some(newSeq[seq[byte]]())))
          )
      )
      check codeIn(narrow) == Opt.some(ecOk)
      let narrowed =
        LogosNSRuntimeControlEstablishRouteResponse.decode(unhexOf(valueIn(narrow)))
      check narrowed.isOk
      if narrowed.isOk:
        check c.materializeVia(1, narrowed.get.routes[0].route) == Opt.some(ecOk)
        check c.malformedVia(1, 2) ==
          (Opt.some(ecNotAuthorised), Opt.some(ecNotAuthorised))
        check codeIn(c.run("release 1")) == Opt.some(ecOk)
      check c.renewVia("r1", route) == Opt.some(ecNotAuthorised)
      check c.malformedVia(0, 3) ==
        (Opt.some(ecNotAuthorised), Opt.some(ecNotAuthorised))
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      e.finish()

    test "[IFC-0729] [RUN-0181] [IMPL-DECISION G267] C-8 prepared calls from a hosted consumer to a hosted provider: a response, a timeout that cancels the provider's call, an expiry at submission, a cancellation before it, and the connection kept until the last completes":
      let cfg = hosted()
      let mdir = cfg.stateOf()
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      discard e.started(consumerRecord(), "c")
      let route = c.establishVia("k")
      check c.materializeVia(0, route) == Opt.some(ecOk)
      check codeIn(c.run(prepareLine(1, 4, "-"))) == Opt.some(ecOk)
      check codeIn(c.run(prepareLine(3, 4, "0"))) == Opt.some(ecOk)
      check codeIn(c.run(prepareLine(4, 4, "-"))) == Opt.some(ecOk)
      check codeIn(c.run(prepareLine(5, 22, "-"))) == Opt.some(ecOk)
      check codeIn(c.run("cancel 4")) == Opt.some(ecOk)
      let submitted = getMonoTime()
      for i in [1, 3, 4]:
        check codeIn(c.run("submit " & $i)) == Opt.some(ecOk)
      check c.noted("done", "", 3)
      let roundTrip = (getMonoTime() - submitted).inMilliseconds
      let r = readingOf(c.doneOf(1))
      check r.isSome and r.get.reading.value == 40
      check codeIn(c.doneOf(3)) == Opt.some(ecTimeout)
      check codeIn(c.doneOf(4)) == Opt.some(ecCancelled)
      # [IMPL] Call 2's timeout must pass only once the provider holds it, and
      # its way there is part of call 1's round trip: five times that round
      # trip on this machine now, and at least 10 s. Under ASan the way took
      # 0.8-1.2 s on a loaded Mac (the round trip 1.2-1.4 s) and longer than
      # 10 s on a CI runner (2026-11-15). At most 5 minutes, half of channel
      # 22's hold: under TSan on a host at load 100 the hold, then a minute,
      # ended first and call 2 was OK (4b-8's closing check).
      let holdTimeout = min(max(10_000'i64, 5 * roundTrip), 300_000)
      let bound = int(holdTimeout div 1000) + 10 * Slow
      check codeIn(c.run(prepareLine(2, 22, $holdTimeout))) == Opt.some(ecOk)
      # Channel 22 holds the call in the provider until it is cancelled: the
      # timeout ends it, and the Cancel goes to the provider.
      check codeIn(c.run("submit 2")) == Opt.some(ecOk)
      check mdir.heldAt(1, bound)
      check c.doneOf(2) == "none" # held before the timeout passed
      check c.noted("done", "2 ", seconds = bound)
      checkpoint "call 1's round trip " & $roundTrip & " ms; call 2: " & c.doneOf(2)
      check codeIn(c.doneOf(2)) == Opt.some(ecTimeout)
      # A released handle keeps its connection for the call still running.
      check codeIn(c.run("submit 5")) == Opt.some(ecOk)
      check mdir.heldAt(2, bound)
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      mdir.open()
      check c.noted("done", "5 ")
      let five = readingOf(c.doneOf(5))
      # Answered to the caller, and not cancelled by the handle's release.
      check five.isSome and five.get.label == "c" and five.get.reading.value == 0
      for i in 1 .. 5:
        check codeIn(c.run("release-call " & $i)) == Opt.some(ecOk)
      check e.routeOf(route).get.state.kind == LogosNSRuntimeControlRouteStateKind.Ready
      e.finish()

    test "[RUN-1101] [IMPL-DECISION G260] H-1 a route revoked under a hosted consumer: its prepared call that a hosted provider runs is TRANSPORT_ERROR, though the provider returns once cancelled; a call submitted after the revocation is NOT_AUTHORISED":
      let cfg =
        hosted(denying(deny(action = Opt.some(aaRoute), operation = "renew_route")))
      let mdir = cfg.stateOf()
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      discard e.started(consumerRecord(), "c")
      let route = c.establishVia("k")
      check c.materializeVia(0, route) == Opt.some(ecOk)
      # Channel 22 holds the call in the provider until it is cancelled.
      check codeIn(c.run(prepareLine(1, 22, "-"))) == Opt.some(ecOk)
      check codeIn(c.run(prepareLine(2, 4, "-"))) == Opt.some(ecOk)
      check codeIn(c.run("submit 1")) == Opt.some(ecOk)
      check mdir.heldAt(1)
      # [G260] A denied renewal revokes the route.
      check c.renewVia("r", route) == Opt.some(ecNotAuthorised)
      check c.noted("done", "1 ")
      check codeIn(c.doneOf(1)) == Opt.some(ecTransport)
      # [RUNTIME l.1261] A new operation on the revoked route.
      check codeIn(c.run("submit 2")) == Opt.some(ecOk)
      check c.noted("done", "2 ")
      check codeIn(c.doneOf(2)) == Opt.some(ecNotAuthorised)
      check e.routeOf(route).get.state.kind ==
        LogosNSRuntimeControlRouteStateKind.Revoked
      sleep(50 * Slow)
      check c.linesOf("done").len == 2
      for i in 1 .. 2:
        check codeIn(c.run("release-call " & $i)) == Opt.some(ecOk)
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      e.finish()

    test "[RUN-0234] [IMPL-DECISION G261] [IMPL-DECISION G267] C-9 a hosted consumer whose route handler does not keep up: the publisher is not held, the connection closes TRANSPORT_ERROR and the host's end handler is called once":
      # [G261] As for a direct consumer's transported handle (`test_transported`):
      # the host's loop keeps an Event's bytes until its handler returns
      # (G178), so a handler that does not return fills the handle's
      # undelivered allowance and then the provider's connection output, at the
      # smallest Event output TRANSPORT §2.1 allows, and the connection closes.
      # The host's limits are the Runtime's (`init.transport`).
      var cfg = hosted()
      cfg.statics.add(bulkStatic)
      var limits = fastConfig()
      limits.callerUndeliveredBytes = int(limits.frameLimit)
      limits.connOutputBytes = int(limits.peerFrameLimit) + limits.controlReserve + 4
      cfg.transport = Opt.some(limits)
      var c = cfg.serving(extra = "block-handler\n")
      let e = fixtureEngine(cfg)
      discard e.started(bulkRecord(), "b")
      check e.started(consumerRecord(), "c").state == msReady
      let rec = c.establishRecVia("k", bulkRoot)
      check rec.isSome
      let route = (if rec.isSome: rec.get.route else: "")
      check codeIn(
        c.run(
          "materialize 0 " & route & " " & hexOf(bulkRoot) & " " & hexOf(bulkSchema)
        )
      ) == Opt.some(ecOk)
      const Carried = "bulk.carried_event"
      check codeIn(c.run("subscribe 0 " & Carried & " s1")) == Opt.some(ecOk)
      check codeIn(c.run("observe-end 0 e1")) == Opt.some(ecOk)
      # The publisher: a direct consumer on a direct route.
      let (_, rc) = e.startClient()
      var (code, direct) = rc.materialize(
        rc.establish("p", root = bulkRoot).recordOf.route, bulkRoot, bulkSchema
      )
      check code == ecOk
      const Size = 2 * 1024 * 1024
      const Count = 30
      var failed = 0
      for i in 1 .. Count:
        if invoke(addr direct, BulkSendRequest(size: Size)).isErr:
          inc failed
      check failed == 0
      # Every publication returned while the host's handler held its first Event.
      check c.linesOf("deliveries").len <= 1
      writeFile(c.dir / "go-handler", "")
      check c.noted("ends", "e1 ")
      check c.linesOf("ends") == @[endLine("e1", ecTransport)]
      check c.linesOf("deliveries").len < Count
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      direct.release()
      e.finish()
      check noHostLeft()

    test "[IMPL-DECISION G244] [IMPL-DECISION G277] C-10 a route with a hosted end to a contract that marks a payload is made (G244 lifted, step 4b-3b); on a path kind without erasure, and in a refc build, it is refused MODULE_ERROR before readiness, as a direct one, and the host keeps no material":
      # [SPEC INTERFACE l.388] The host erases marked payloads (step 4b-3b),
      # so a route with a hosted end is made; `erasureMissing` stands for a
      # path kind without erasure, refused in `establish_route`. A refc build
      # refuses every marked route itself (`ChannelsMove`), with no hook.
      var cfg = hosted()
      cfg.statics.add(checkStaticRegistration("vault", vaultTable()).tryGet)
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(
        ModuleRecord(
          module: "vault_module",
          strategy: stDirectStatic,
          binding: "vault",
          primaryContract: Opt.some(vaultRoot),
        ),
        "v",
      )
      check e.started(consumerRecord(), "c").state == msReady
      when ChannelsMove:
        let made = c.run("rc establish_route " & hexOf(establishReq("k", vaultRoot)))
        check codeIn(made) == Opt.some(ecOk)
        check e.setErasureMissingForTests({rmLocalTransport}).isOk
      let line = c.run("rc establish_route " & hexOf(establishReq("k2", vaultRoot)))
      check codeIn(line) == Opt.some(ecModule)
      check MarkedUnsupported in line
      when ChannelsMove:
        check e.setErasureMissingForTests({}).isOk
        check e.routes().len == 1
      else:
        check e.routes().len == 0
      e.finish()
      check noHostLeft()

    test "[IFC-0957] [TXT-0535] [TXT-0551] [IMPL-DECISION G394] C-13 a hosted consumer's session on an earlier view of a provider (synthesis Q4): the session selects the earlier root with that contract's own input, B's implementation answers, only the view's methods resolve, and logos.schema answers the view":
      # As C-10, a scripted static table with a hosted end: the route is
      # local-transport, and the host connects to the Runtime's endpoint for
      # the relay with the material it kept.
      var cfg = hosted()
      cfg.statics.add(relayStatic())
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(relayRecord(), "r")
      check e.started(consumerRecord(), "c").state == msReady
      let rec = c.establishRecVia("k", relayA2Root)
      require rec.isSome
      check rec.get.expected_contract.get.schema_root == @relayA2Root
      let made = c.run(
        "materialize 0 " & rec.get.route & " " & hexOf(relayA2Root) & " " &
          hexOf(relaySchema(relayA2Root))
      )
      check codeIn(made) == Opt.some(ecOk)
      let before = relayCalls.load
      let read = c.run(
        "call 0 read " & hexOf(encodeCbor(cborMap((cbor("channel"), cbor(2'u64)))))
      )
      check codeIn(read) == Opt.some(ecOk)
      check decodeCbor(unhexOf(valueIn(read))).tryGet.lookup("value").get.getUint64 ==
        Opt.some(RelayValue)
      check relayCalls.load == before + 1
      check codeIn(c.run("call 0 ping a0")) == Opt.some(ecMethodNotFound)
      let schema = c.run("call 0 schema a0")
      check codeIn(schema) == Opt.some(ecOk)
      check unhexOf(valueIn(schema)) == relaySchema(relayA2Root)
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      e.finish()
      check noHostLeft()

    test "[IMPL-DECISION G394] a Module Host keeps an extending provider's contracts in process (synthesis Q4): an earlier view's input is its own answer, built on first use, and the view adds no publication contract":
      check keepProvider(relayBinding(), false, MaxPayloadDepth, relayDescriptor).isOk
      check earlierInputOf(relayRoot).isNone
      check earlierInputOf(pulseRoot).isNone
      for root in [relayA1Root, relayA2Root]:
        let input = earlierInputOf(root)
        check input.isSome and input.get.schema == relaySchema(root)
        check schemaAnswer(root) == relaySchema(root)
        check selectedFor(root).isOk
      check selectedFor(relayA1Root).get.boundary.knowsEvent(ClearedDecl)
      check not selectedFor(relayA2Root).get.boundary.knowsEvent(ClearedDecl)
      # Published under B, which declares both events.
      let data = encodeCbor(cborMap((cbor("channel"), cbor(1'u64))))
      check publishedBy(ClearedDecl, data).isOk
      check publishedBy(ChangedDecl, data).isOk

    test "[RUN-1093] [RUN-0794] [RUN-0181] [RUN-1118] [RUN-1122] S-18 a stopping consumer's calls through its routes are refused from stop step 1, NOT_READY, hosted as direct; a malformed one, called or prepared, INVALID_PARAMS first (l.1828, l.1832)":
      var codes: seq[Opt[ErrorCode]]
      var malformed: seq[(Opt[ErrorCode], Opt[ErrorCode])]
      for hostedConsumer in [true, false]:
        let cfg = hosted()
        var c = cfg.serving(extra = "block-destroy\n")
        let e = fixtureEngine(cfg)
        discard e.started(meter(), "m")
        discard e.started(consumerRecord(hostedConsumer), "c")
        let route = c.establishVia("k")
        check c.materializeVia(0, route) == Opt.some(ecOk)
        check readingOf(c.readVia(0, 4)).isSome
        var t: Thread[(Engine, string)]
        check e.stopping("c", t)
        # `_MODULE_destroy` waits for `go`; the command thread still serves.
        codes.add(codeIn(c.readVia(0, 4)))
        malformed.add(c.malformedVia(0, 1))
        check codeIn(c.run("release 0")) == Opt.some(ecOk)
        writeFile(c.dir / "go", "")
        joinThread(t)
        check stopReply.load == ord(msUnloaded)
        e.finish()
        check noHostLeft()
      check codes == @[Opt.some(ecNotReady), Opt.some(ecNotReady)]
      let invalid = (Opt.some(ecInvalidParams), Opt.some(ecInvalidParams))
      check malformed == @[invalid, invalid]

    test "[IMPL-DECISION G339] C-14 a consumer written with the typed helpers, hosted and direct_dynamic: kit/routes opens its route at initialization, the typed subscribe hears the meter's event, the typed invoke reads through the route, and its RouteSet closes at destroy; a failed initialization closes the set before it returns":
      for (listenerHosted, providerHosted) in [
        (true, false), (true, true), (false, true)
      ]:
        let cfg = hosted()
        discard cfg.stateOf()
        let dir = cfg.stateOf("l")
        writeFile(
          dir / "listen.cmd", hexOf(meterRoot) & "\n" & hexOf(meterSchema) & "\n"
        )
        let e = fixtureEngine(cfg)
        discard e.started(
          if providerHosted:
            hostedMeter()
          else:
            meter(),
          "m",
        )
        check e.started(listenerRecord(listenerHosted), "l").state == msReady
        let c = Consumer(dir: dir)
        check c.noted("opened", "0 ")
        check c.noted("opened", "sub 0")
        # Channel 21 publishes `meter.changed_event` (210) and answers with
        # its caller: the listener's own instance.
        check c.noted("read", "0 l")
        check c.noted("heard", "210 ")
        e.finish()
        check c.linesOf("closed") == @["0"]
        check noHostLeft()
      let cfg = hosted()
      discard cfg.stateOf()
      let dir = cfg.stateOf("l")
      writeFile(
        dir / "listen.cmd", hexOf(meterRoot) & "\n" & hexOf(meterSchema) & "\nfail\n"
      )
      let e = fixtureEngine(cfg)
      discard e.started(meter(), "m")
      let made = e.create(listenerRecord(), "l").tryGet
      let st = e.start(made.instance)
      check st.isErr or st.get.state != msReady
      let c = Consumer(dir: dir)
      check c.noted("opened", "sub 0")
      check c.linesOf("closed") == @["0"]
      e.finish()
      check noHostLeft()

  # M-1 to M-3: a module built with the other memory manager ---------------------------

  # [DECISIONS G342; TIER5-PLAN A7] The meter, the deferred adapter and the probe
  # built with `otherMm` (refc beside this orc build, orc beside a refc one):
  # two Nim runtimes with different memory managers in one process, the
  # Runtime's or a Module Host's and the module's. The handlers store nothing
  # in the instance from the calling thread, so the kit's refc limit (I71)
  # holds; the confined mode, which lifts it, comes with step N-1's sub-part 3.
  let
    # [DECISIONS G341] Linked with the kit's export list, as a port builds them.
    mixedMeterLib =
      buildKitLibrary("meter_impl.nim", "hrmeterx", otherMm, exports = "meter_module")
    mixedDeferredLib = buildKitLibrary(
      "deferred_adapter.nim", "hrdeferredx", otherMm, exports = "meter_module"
    )
    mixedProbeLib = buildKitLibrary("probe_impl.nim", "probex", otherMm)
    mixedMeterDigest = digestOf(mixedMeterLib)
    mixedDeferredDigest = digestOf(mixedDeferredLib)
    mixedProbeDigest = digestOf(mixedProbeLib)

  proc directMixedMeter(state = "m"): ModuleRecord =
    ModuleRecord(
      module: MeterModule,
      strategy: stDirectDynamic,
      artifact: ArtifactRecord(
        id: "meterx",
        localPath: mixedMeterLib,
        hash: mixedMeterDigest,
        hashSuite: HashSuiteId,
      ),
      primaryContract: Opt.some(meterRoot),
      stateAssignment: Opt.some(state),
    )

  proc hostedMixedProbe(): ModuleRecord =
    ModuleRecord(
      module: "probe_module",
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: "probex",
        localPath: mixedProbeLib,
        hash: mixedProbeDigest,
        hashSuite: HashSuiteId,
      ),
      stateAssignment: Opt.some("p"),
    )

  type Reader = object ## One thread's handle and what its reads got.
    handle: LogosRouteHandle
    ok: Atomic[int]

  const
    ReaderThreads = 8
    ReadsPerThread = 50
    # [DECISIONS G342] A refc library is built without the sanitizer
    # (`kitbuild`); MemorySanitizer takes what uninstrumented code writes for
    # uninitialized (DECISIONS I77), so its run skips these cases.
    mixedUninstrumented = defined(msan) and otherMm == "refc"

  template instrumentedOnly() =
    if mixedUninstrumented:
      skip()
      break

  proc reads(r: ptr Reader) {.thread.} =
    ## Reads every channel from 30 on through the thread's own handle (one
    ## handle per thread: INTERFACE l.1980).
    for i in 0 ..< ReadsPerThread:
      let c = uint32(30 + i)
      let got = r.handle.read(c)
      if got.isOk and got.get.reading.value == uint64(c) * 10:
        r.ok += 1
    releasePerThread()

  suite "run.mixed: a module built with the other memory manager (DECISIONS G342; TIER5-PLAN A7)":
    setup:
      for h in heard.mitems:
        h.count.store(0)
        h.last.store(0)
    teardown:
      leftover()
      check noHostLeft()

    test "M-1 hosted: calls on two sessions at once, a held call, the caller, events from a handler and from the module's own thread, a deferred provider, and a restart":
      instrumentedOnly()
      let cfg = hosted()
      let dir = cfg.stateOf()
      discard cfg.stateOf("d")
      let e = fixtureEngine(cfg)
      discard
        e.started(hostedMeter(lib = mixedMeterLib, digest = mixedMeterDigest), "hm")
      let (c1, rc1) = e.startClient("c1")
      let (_, rc2) = e.startClient("c2")
      let o = newOwner(roomy())
      defer:
        o.stop()
      let a = o.session(rc1.establish("k").recordOf.invocationOf.get)
      let b = o.session(rc2.establish("k").recordOf.invocationOf.get)
      check o.outcome(a, o.send(a, 18)).reading.label == c1.instance
      let slow = o.send(a, 22)
      check dir.heldAt(1)
      check o.outcome(b, o.send(b, 6)).reading.reading.value == 60
      dir.open()
      check o.outcome(a, slow).codeOf == Opt.some(ecOk)
      # Events: from a handler (15), and from a thread the module's runtime
      # made, through the host's publish callback (25).
      var k = rc1.handle(rc1.establish("ke").recordOf.route)
      var sub: LogosSubscriptionId
      check k.hear(0, sub) == ecOk
      check k.read(15).isOk
      check heardAt(0, 1)
      check heard[0].last.load == 150
      let r25 = k.read(25)
      check r25.isOk and r25.get.reading.value == 250
      check heardAt(0, 2)
      check heard[0].last.load == 250
      k.release()
      # A deferred provider built the same way.
      let d = e.started(
        hostedMeter("d", mixedDeferredLib, mixedDeferredDigest, "deferredx"), "hd"
      )
      let cd = o.session(
        rc1.establish("kd", provider = Opt.some(providerAddress(d.providerId))).recordOf.invocationOf.get
      )
      check o.outcome(cd, o.send(cd, 7)).reading.reading.value == 70
      check o.outcome(cd, o.send(cd, 13)).codeOf == Opt.some(ecModule)
      # A restart: a new host process loads the library again.
      check e.stop("hm").tryGet.state == msUnloaded
      check e.start("hm").tryGet.state == msReady
      let a2 = o.session(rc1.establish("k2").recordOf.invocationOf.get)
      check o.outcome(a2, o.send(a2, 9)).reading.reading.value == 90
      e.finish()

    test "M-2 direct_dynamic in this process: reads from 8 threads on their own handles, events from a handler and from the module's own thread, scoped events, and a second instance after the first is stopped":
      instrumentedOnly()
      let cfg = hosted()
      discard cfg.stateOf()
      let e = fixtureEngine(cfg)
      discard e.started(directMixedMeter(), "dm")
      let (_, rc) = e.startClient("c")
      let route = rc.establish("k").recordOf.route
      var readers: array[ReaderThreads, Reader]
      var threads: array[ReaderThreads, Thread[ptr Reader]]
      for i in 0 ..< ReaderThreads:
        readers[i].handle = rc.handle(route)
      for i in 0 ..< ReaderThreads:
        createThread(threads[i], reads, addr readers[i])
      joinThreads(threads)
      for i in 0 ..< ReaderThreads:
        check readers[i].ok.load == ReadsPerThread
        readers[i].handle.release()
      var k = rc.handle(route)
      var sub: LogosSubscriptionId
      check k.hear(0, sub) == ecOk
      check k.read(15).isOk
      check heard[0].last.load == 150 # direct delivery runs before publish returns
      check k.read(25).isOk
      check heard[0].count.load == 2
      check heard[0].last.load == 250
      check k.read(17).isOk # in the invocation's scope
      check heard[0].count.load == 3
      check heard[0].last.load == 170
      k.release()
      check e.stop("dm").tryGet.state == msUnloaded
      # The library stays loaded (`runtime/artifact.nim`); a new instance runs.
      discard e.started(directMixedMeter("m2"), "dm2")
      var k2 = rc.handle(rc.establish("k2").recordOf.route)
      let again = k2.read(20)
      check again.isOk and again.get.label == "m2"
      k2.release()
      e.finish()

    test "M-3 a hosted consumer built with the other memory manager calls, subscribes and releases, to a hosted provider built the same way":
      instrumentedOnly()
      let cfg = hosted()
      discard cfg.stateOf()
      var c = cfg.serving(state = "p")
      let e = fixtureEngine(cfg)
      discard
        e.started(hostedMeter(lib = mixedMeterLib, digest = mixedMeterDigest), "m")
      check e.started(hostedMixedProbe(), "c").state == msReady
      let route = c.establishVia("k")
      check c.materializeVia(0, route) == Opt.some(ecOk)
      let r = readingOf(c.readVia(0, 4))
      check r.isSome and r.get.reading.value == 40
      let sub = c.run("subscribe 0 meter.changed_event s1")
      check codeIn(sub) == Opt.some(ecOk)
      check readingOf(c.readVia(0, 25)).isSome
      check c.noted("deliveries", "s1 meter.changed_event ")
      check codeIn(c.run("unsubscribe 0 " & valueIn(sub))) == Opt.some(ecOk)
      check codeIn(c.run("release 0")) == Opt.some(ecOk)
      e.finish()
