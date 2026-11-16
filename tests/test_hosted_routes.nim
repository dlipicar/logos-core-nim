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
  import ../src/logos_core/runtime/[engine, hostsup]
  import ../src/logos_core/abi/types
  import ../src/logos_core/base/clock
  from ../src/logos_core/base/wipe import ChannelsMove, MarkedUnsupported
  import ../src/logos_core/cbor
  import ../src/logos_core/commitment
  import ../src/logos_core/crypto/blake3
  import ../src/logos_core/iface/[accept, cmap, outcome, provider, surface]
  import ../src/logos_core/iface/common_types
  import ../src/logos_core/loader/contract
  import ../src/logos_core/pins
  import ../src/logos_core/authority/scopes except
    LogosNSRuntimeModuleInstanceAddress, LogosNSRuntimeModuleInstanceId,
    LogosNSRuntimeModuleName, LogosNSRuntimeModuleProviderAddress,
    LogosNSRuntimeModuleProviderId, LogosNSRuntimeModuleStateAssignmentId,
    LogosNSRuntimeRouteId, LogosNSRuntimeRuntimeInstanceId
  import ./support/[fakeca, kitbuild, kitruntime, modulehostbuild, shortdir]
  import ./kit/[bulk_impl, meter_impl]
  import
    ./generated/
      [bulk_module_calls, bulk_module_types, meter_module_calls, meter_module_types]
  import ./support/trnowner except Provider, now, binding, issue, live, release, gate

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
    SanitizerEnv =
      ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
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
    ## host runs and serves, and the Runtime has not adopted it.
    check e.setLoaderFaultsForTests(LoaderFaults(stall: {lmRealize})).isOk
    startReply.store(-2)
    createThread(t, startOn, (e, instance))
    waitUntil(
      proc(): bool =
        e.stalledLoaderCallsForTests() == 1
    )

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
      check e.stalledStart("hm", t)
      # The host serves already (it answered `initialized` only then), and the
      # Runtime has not adopted it.
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
      check e.stalledStart("hm", t)
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
      check e.stalledStart("hm", t)
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

    test "[IMPL-DECISION G172] [RUN-0815] [IMPL-DECISION G274] P-9 a hosted provider's failure passes through; an invalid status or a response outside the schema is MODULE_ERROR, as direct":
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
      for channel in [13'u32, 14, 16]:
        checkpoint("channel " & $channel)
        let viaHost = hh.read(channel)
        let direct = hd.read(channel)
        check viaHost.isErr and direct.isErr
        if viaHost.isErr and direct.isErr:
          check viaHost.error.code == direct.error.code
          check viaHost.error.code == ecModule
          check viaHost.error.message == direct.error.message
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

    test "[TRN-0317] [IMPL-DECISION G174] [IMPL-DECISION G260] P-11 revocation answers a hosted provider's in-flight Request NOT_AUTHORISED, then ends the session NOT_AUTHORISED; close_route drains without a ProtocolError":
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
        check o.outcome(conn, tag).codeOf == Opt.some(ecNotAuthorised)
        let closed = o.closedOf(conn)
        check closed.isSome
        if closed.isSome:
          check closed.get.cause == ccPeerError
          check closed.get.code == ecNotAuthorised
        dir.open()
        o.settle(50 * Slow)
        check o.responses(conn, tag) == 1
      removeFile(dir / "open")
      removeFile(dir / "held")
      block closing:
        # Channel 23: the provider goes on after its invocation is marked
        # cancelled, as G174 marks the route's admitted calls at its end.
        let rec = rc.establish("k2").recordOf
        let conn = o.session(rec.invocationOf.get)
        let tag = o.send(conn, 23)
        check dir.heldAt(1)
        check rc.close(rec.route).code == ecOk
        check o.outcome(conn, o.send(conn, 4)).codeOf == Opt.some(ecNotReady)
        check o.closedOf(conn, 50 * Slow).isNone # still draining
        dir.open()
        let late = o.outcome(conn, tag)
        check late.codeOf == Opt.some(ecOk)
        if late.codeOf == Opt.some(ecOk):
          check late.reading.reading.value == 1 # it saw `is_cancelled`
        let closed = o.closedOf(conn)
        check closed.isSome
        if closed.isSome:
          check closed.get.cause == ccPeerClosed
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

  proc readingOf(line: string): Opt[MeterReadResponse] =
    if codeIn(line) != Opt.some(ecOk):
      return Opt.none(MeterReadResponse)
    let r = MeterReadResponse.decode(unhexOf(valueIn(line)))
    if r.isErr:
      Opt.none(MeterReadResponse)
    else:
      Opt.some(r.get)

  proc routeOf(e: Engine, route: string): Opt[LogosNSRuntimeControlRouteRecord] =
    for rec in e.routes():
      if rec.route == route:
        return Opt.some(rec)
    Opt.none(LogosNSRuntimeControlRouteRecord)

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

    test "[RUN-0805] [RUN-0256] [RUN-0837] [RUN-0838] C-5 a hosted provider's host killed during a hosted consumer's call: the call is TRANSPORT_ERROR, the end is reported once and never changes, and the failed route answers NOT_READY":
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

    test "[IFC-0729] [RUN-0181] [IMPL-DECISION G267] C-8 prepared calls from a hosted consumer to a hosted provider: a response, a timeout that cancels the provider's call, an expiry at submission, a cancellation before it, and the connection kept until the last completes":
      let cfg = hosted()
      let mdir = cfg.stateOf()
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      discard e.started(hostedMeter(), "hm")
      discard e.started(consumerRecord(), "c")
      let route = c.establishVia("k")
      check c.materializeVia(0, route) == Opt.some(ecOk)
      proc prepareLine(call: int, channel: uint32, timeout: string): string =
        "prepare 0 " & $call & " read " &
          hexOf(encode(MeterReadRequest(channel: channel)).tryGet) & " " & timeout

      proc doneOf(c: Consumer, call: int): string =
        for line in c.linesOf("done"):
          if line.startsWith($call & " "):
            return line.split(' ', 1)[1]
        "none"

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
      # 10 s on a CI runner (2026-11-15).
      let holdTimeout = max(10_000'i64, 5 * roundTrip)
      let bound = int(holdTimeout div 1000) + 10 * Slow
      check codeIn(c.run(prepareLine(2, 22, $holdTimeout))) == Opt.some(ecOk)
      # Channel 22 holds the call in the provider until it is cancelled: the
      # timeout ends it, and the Cancel goes to the provider.
      check codeIn(c.run("submit 2")) == Opt.some(ecOk)
      check mdir.heldAt(1, bound)
      check c.doneOf(2) == "none" # held before the timeout passed
      check c.noted("done", "2 ", seconds = bound)
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

    test "[RUN-0111] [RUN-0794] [RUN-0181] S-18 a stopping consumer's calls through its routes are refused from stop step 1, NOT_READY, hosted as direct":
      var codes: seq[Opt[ErrorCode]]
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
        check codeIn(c.run("release 0")) == Opt.some(ecOk)
        writeFile(c.dir / "go", "")
        joinThread(t)
        check stopReply.load == ord(msUnloaded)
        e.finish()
        check noHostLeft()
      check codes == @[Opt.some(ecNotReady), Opt.some(ecNotReady)]
