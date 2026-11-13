## DECISIONS I90 (step 4b-2): transported local routes. A routing rule selects
## `local-transport` for the meter provider (G254); the Runtime serves it at an
## endpoint of its own (G257), and the ticket in a route's invocation
## descriptor opens one session there (RUNTIME §4.1, §7.5, §9.3; TRANSPORT
## §3.1, §8.1, §8.1.1, §8.2).
##
## Part 4b-2a, the provider side: the caller is a test-owned transport loop
## (`support/trnowner.nim`), which connects with the descriptor's path and
## ticket as a consumer's binding does. Part 4b-2b, the caller side: the
## consumer materializes the route and calls through its handle, whose link
## the Runtime connects (G258, G259, G260). Every wait that only bounds a test
## is scaled by `Slow`.

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
when defined(posix):
  import std/posix
import unittest2
import ../src/logos_core/runtime/[engine, routing]
from ../src/logos_core/runtime/transported import connectOutcome, closedCode
import ../src/logos_core/transport/io/sock
import ../src/logos_core/abi/types
import ../src/logos_core/base/clock
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, surface]
import ../src/logos_core/iface/common_types
import ./support/[fakeca, kitbuild, kitruntime, shortdir]
import ./kit/[deferred_adapter, meter_impl]
import ./generated/[meter_module_calls, meter_module_types]
import ./support/trnowner except Provider, now, binding, issue, live, release, gate

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "transported" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

# The endpoints go under a short private base (plan §4.3): `<base>/e<n>/<8
# hex>/logos_meter_module.sock`.
let shortBase = makeShortBase("lcntr", "/e999/12345678/logos_meter_module.sock")

const
  MeterModule = "meter_module"
  Wait = 5000 * Slow ## ms: bounds a wait for an event

proc transported(
    policy = allowAll(),
    clock = systemClock(),
    dir = "",
    extra: seq[StaticRegistration] = @[],
): EngineConfig =
  ## `config`, with the meter provider routed over local transport.
  result = config(policy, extra)
  result.routing = @[RoutingRule(callee: MeterModule, mode: rmLocalTransport)]
  result.endpointDir =
    if dir.len > 0:
      dir
    else:
      shortBase / ("e" & $engines)
  result.transport = Opt.some(fastConfig())
  result.clock = clock

let caClock = newTestClock()
useClock(caClock) # the fake authority's `issued_at` and `valid_until`

proc underAuthority(): Engine =
  ## A transported engine on `caClock` with the fake Capability Authority
  ## bound; meter and client not started.
  resetFake()
  var cfg = transported(clock = caClock)
  cfg.statics.add(fakeCaRegistration())
  cfg.authority = Opt.some(
    AuthorityPolicy(instance: "ca", evaluationDeadline: initDuration(seconds = 60))
  )
  result = fixtureEngine(cfg)
  discard result.create(fakeCaRecord(), "ca").tryGet
  doAssert result.start("ca").tryGet.state == msReady
  doAssert result.authorityBound()[0]

proc meterInput(): ContractInput =
  ContractInput(root: meterRoot, schema: meterSchema, system: false)

# Descriptors ----------------------------------------------------------------------------

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

func holds(hay: openArray[byte], t: RouteTicket): bool =
  ## Whether the ticket's bytes appear anywhere in `hay`.
  if hay.len < t.len:
    return false
  for i in 0 .. hay.len - t.len:
    if equalMem(unsafeAddr hay[i], unsafeAddr t[0], t.len):
      return true
  false

func holds(hay: string, t: RouteTicket): bool =
  holds(hay.toOpenArrayByte(0, hay.high), t)

proc isState(
    rec: LogosNSRuntimeControlRouteRecord, k: LogosNSRuntimeControlRouteStateKind
): bool =
  rec.state.kind == k

template ltTest(name: string, body: untyped) =
  ## [I90] Transported routes are POSIX-only (`logos.local.unix-stream`, §8.2.1;
  ## the host configuration refuses the rule on Windows): elsewhere the case
  ## compiles and skips.
  test name:
    when unixStream:
      body
    else:
      skip()

when defined(posix):
  proc modeOf(path: string): int =
    var s: Stat
    if lstat(cstring(path), s) != 0:
      return -1
    int(s.st_mode) and 0o7777

  proc isSocket(path: string): bool =
    var s: Stat
    lstat(cstring(path), s) == 0 and S_ISSOCK(s.st_mode)

# The caller -------------------------------------------------------------------------------

var nextConn, nextTag: uint64

proc seen(o: Owner, pred: proc(ev: IoEvent): bool, timeoutMs = Wait): Opt[IoEvent] =
  ## The first event in the whole log that matches, waiting for it; unlike
  ## `expect`, an event that came earlier than another awaited one is found.
  let until = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    for ev in o.log:
      if pred(ev):
        return Opt.some(ev)
    if getMonoTime() >= until:
      return Opt.none(IoEvent)
    discard o.pump(10)

proc open(o: Owner, inv: Invocation, selected = meterInput()): (ConnId, IoEvent) =
  ## Connects with the descriptor; the connection's outcome.
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
  ## The code a connection with `inv` fails with, or OK.
  let (_, ev) = o.open(inv, selected)
  if ev.kind == evConnectFailed: ev.failCode else: ecOk

proc session(o: Owner, inv: Invocation): ConnId =
  let (conn, ev) = o.open(inv)
  check ev.kind == evConnected
  conn

proc send(o: Owner, conn: ConnId, channel: uint64): uint64 =
  ## A `read` on `channel`; its tag.
  inc nextTag
  o.call(conn, nextTag, "read", cborMap((cbor("channel"), cbor(channel))))
  nextTag

proc outcome(o: Owner, conn: ConnId, tag: uint64, timeoutMs = Wait): Opt[CallOutcome] =
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

proc heldAt(n: int): bool =
  waitUntil(
    proc(): bool =
      held.load == n
  )

# Tests ----------------------------------------------------------------------------------

suite "run.transported: tickets and the Runtime-served endpoint (I90 part 4b-2a)":
  teardown:
    leftover()

  ltTest "[RUN-0541] [RUN-0623] [IMPL-DECISION G254] [IMPL-DECISION G257] a local-transport route's answer carries the invocation descriptor; the endpoint is private; renewal issues a fresh ticket":
    let e = fixtureEngine(transported())
    let dir = shortBase / ("e" & $engines)
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let r = rc.establish("k")
    check r.code == ecOk
    let rec = r.recordOf
    check rec.isState(LogosNSRuntimeControlRouteStateKind.Ready)
    check rec.invocation.isSome
    let d = rec.invocation.get
    check d.kind == LogosNSRuntimeControlInvocationDescriptorKind.Case0
    check d.arm_0.kind == "local-transport"
    check d.arm_0.profile == "logos.local.unix-stream"
    check d.arm_0.ticket.len == 32
    let inv = rec.invocationOf.get
    check inv.path.startsWith(dir & "/")
    check inv.path.endsWith("/logos_meter_module.sock")
    check inv.path.isSocket
    check inv.path.modeOf == 0o600
    check inv.path.parentDir.modeOf == 0o700
    check dir.modeOf == 0o700
    let n = rc.renew("k2", rec.route)
    check n.code == ecOk
    let again = n.renewed.invocationOf
    check again.isSome
    check again.get.path == inv.path
    check again.get.ticket != inv.ticket
    e.finish()

  ltTest "[RUN-0541] [IMPL-DECISION G254] a direct route, or one no rule selects, has no invocation descriptor":
    block:
      let e = fixtureEngine(config())
      discard e.started(meter())
      let (_, rc) = e.startClient()
      let r = rc.establish("k")
      check r.code == ecOk
      check r.recordOf.invocation.isNone
      e.finish()
    block:
      var cfg = transported()
      cfg.routing = @[RoutingRule(callee: "other_module", mode: rmLocalTransport)]
      let e = fixtureEngine(cfg)
      discard e.started(meter())
      let (_, rc) = e.startClient()
      let r = rc.establish("k")
      check r.code == ecOk
      check r.recordOf.invocation.isNone
      e.finish()

  ltTest "[RUN-0543] [RUN-0544] [TRN-0195] [CAP-0257] [IMPL-DECISION G255] no list, record, retained answer, diagnostic or stored file holds a ticket; a replay answers without the invocation":
    var cfg = transported()
    let root = cfg.workDir
    cfg.storeDir = Opt.some(root / "store") # the persistent Runtime state (I82)
    let e = openEngine(cfg).tryGet
    live = e
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let first = rc.establish("k")
    check first.code == ecOk
    let rec = first.recordOf
    let t1 = rec.invocationOf.get.ticket
    # A replay of the same request key: the retained record, ready, without
    # `invocation`, whose bytes hold no ticket (NA-04 interim).
    let replay = rc.establish("k")
    check replay.code == ecOk
    check replay.recordOf.route == rec.route
    check replay.recordOf.isState(LogosNSRuntimeControlRouteStateKind.Ready)
    check replay.recordOf.invocation.isNone
    check not replay.response.holds(t1)
    let n = rc.renew("r", rec.route)
    check n.code == ecOk
    let t2 = n.renewed.invocationOf.get.ticket
    let renewReplay = rc.renew("r", rec.route)
    check renewReplay.code == ecOk
    check renewReplay.renewed.invocation.isNone
    check not renewReplay.response.holds(t2)
    # list_routes and the Runtime's own view.
    let listed =
      rcCall(rc, "list_routes", encode(LogosNSRuntimeControlListRoutesRequest()).tryGet)
    check listed.code == ecOk
    check not listed.response.holds(t1)
    check not listed.response.holds(t2)
    for x in e.routes():
      check x.invocation.isNone
    for msg in e.diagnostics():
      check not msg.holds(t1)
      check not msg.holds(t2)
    e.finish()
    # Every file the engine wrote, the store included, once it is closed.
    var scanned = 0
    for path in walkDirRec(root):
      if path.isSocket:
        continue
      let bytes =
        try:
          readFile(path)
        except IOError:
          ""
      check not bytes.holds(t1)
      check not bytes.holds(t2)
      inc scanned
    check scanned > 0

  ltTest "[RUN-0226] [RUN-0220] [RUN-0229] [RUN-0230] a session runs the consumer's calls: the caller is the ticket's consumer, calls answer out of order, logos.schema is served":
    let e = fixtureEngine(transported())
    discard e.started(meter())
    let (client, rc) = e.startClient()
    let inv = rc.establish("k").recordOf.invocationOf.get
    let o = newOwner()
    defer:
      gate.store(false)
      o.stop()
    let conn = o.session(inv)
    # The provider reads its caller: the route's consumer, never one the
    # connection names.
    let who = o.outcome(conn, o.send(conn, 18)).reading
    check who.label == client.instance
    check who.reading.label == Opt.some(e.runtimeInstanceId)
    check who.reading.value == 0
    # A held call does not hold the session: a later one answers first.
    gate.store(true)
    let before = held.load
    let slowTag = o.send(conn, 19)
    check heldAt(before + 1)
    let fast = o.outcome(conn, o.send(conn, 5))
    check fast.reading.reading.value == 50
    check o.responses(conn, slowTag) == 0
    gate.store(false)
    check o.outcome(conn, slowTag).codeOf == Opt.some(ecOk)
    # Introspection over the session (E3): the provider's schema response.
    inc nextTag
    o.call(conn, nextTag, "schema", cborMap())
    let s = o.outcome(conn, nextTag)
    check s.codeOf == Opt.some(ecOk)
    check s.get.result == meterSchema
    e.finish()

  ltTest "[CAP-0254] [CAP-0252] [TRN-0153] a ticket opens one session; a random token, a used ticket or an expired one is NOT_AUTHORISED; a wrong schema is VERSION_MISMATCH and consumes nothing":
    var clock = newTestClock()
    defer:
      clock.freeClock()
    let e = fixtureEngine(transported(clock = clock))
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let rec = rc.establish("k").recordOf
    let inv = rec.invocationOf.get
    let o = newOwner()
    defer:
      o.stop()
    var forged = inv
    for i in 0 ..< forged.ticket.len:
      forged.ticket[i] = byte(i)
    check o.refusal(forged) == ecNotAuthorised
    # Another contract in the Hello: VERSION_MISMATCH before redemption.
    check o.refusal(inv, storageInput()) == ecVersionMismatch
    discard o.session(inv)
    check o.refusal(inv) == ecNotAuthorised
    # A fresh ticket from renewal expires 60 s after its issue.
    let fresh = rc.renew("r", rec.route).renewed.invocationOf.get
    clock.advance(61_000)
    check o.refusal(fresh) == ecNotAuthorised
    e.finish()

  ltTest "[TRN-0153] [RUN-0623] [LDR-0021] [IMPL-DECISION G257] an unused ticket dies with its route; the Runtime-served endpoint of a direct provider goes with its realization and a restart serves a new one":
    let e = fixtureEngine(transported())
    let meterView = e.started(meter())
    let (_, rc) = e.startClient()
    let o = newOwner()
    defer:
      o.stop()
    let closing = rc.establish("k1").recordOf
    let stopping = rc.establish("k2").recordOf
    let a = closing.invocationOf.get
    let b = stopping.invocationOf.get
    check rc.close(closing.route).code == ecOk
    check o.refusal(a) == ecNotAuthorised
    check e.stop(meterView.instance).tryGet.state == msUnloaded
    check o.refusal(b) != ecOk
    # The endpoint went with the realization; a restart serves a new path.
    check not b.path.fileExists
    check not b.path.isSocket
    check not b.path.parentDir.dirExists
    check e.start(meterView.instance).tryGet.state == msReady
    let c = rc.establish("k3").recordOf.invocationOf.get
    check c.path != b.path
    check c.path.isSocket
    discard o.session(c)
    e.finish()

  ltTest "[RUN-0230] Cancel on a session: the call ends CANCELLED and its late result is not sent":
    let e = fixtureEngine(transported())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let inv = rc.establish("k").recordOf.invocationOf.get
    let o = newOwner()
    defer:
      gate.store(false)
      o.stop()
    let conn = o.session(inv)
    gate.store(true)
    let before = held.load
    let tag = o.send(conn, 19)
    check heldAt(before + 1)
    o.cancel(conn, tag)
    check o.outcome(conn, tag).codeOf == Opt.some(ecCancelled)
    gate.store(false)
    check heldAt(before)
    o.settle(50 * Slow)
    check o.responses(conn, tag) == 1
    # The session goes on.
    check o.outcome(conn, o.send(conn, 4)).codeOf == Opt.some(ecOk)
    e.finish()

  ltTest "[TRN-0317] [IMPL-DECISION G174] [IMPL-DECISION G260] revoked: an in-flight Request is answered NOT_AUTHORISED, then the session ends NOT_AUTHORISED; the late result is not sent":
    let e = fixtureEngine(
      transported(denying(deny(action = Opt.some(aaRoute), operation = "renew_route")))
    )
    let meterView = e.started(meter())
    let (_, rc) = e.startClient()
    let rec = rc.establish("k").recordOf
    let o = newOwner()
    defer:
      gate.store(false)
      o.stop()
    let conn = o.session(rec.invocationOf.get)
    gate.store(true)
    let before = held.load
    let tag = o.send(conn, 19)
    check heldAt(before + 1)
    check rc.renew("r", rec.route).code == ecNotAuthorised
    check o.outcome(conn, tag).codeOf == Opt.some(ecNotAuthorised)
    let closed = o.closedOf(conn)
    check closed.isSome
    if closed.isSome:
      check closed.get.cause == ccPeerError
      check closed.get.code == ecNotAuthorised
    gate.store(false)
    check heldAt(before)
    o.settle(50 * Slow)
    check o.responses(conn, tag) == 1
    # The provider is destroyed only after the call returned (G174).
    check e.stop(meterView.instance).tryGet.state == msUnloaded
    e.finish()

  ltTest "[IMPL-DECISION G174] [IMPL-DECISION G260] close_route drains: the in-flight Request gets its result, a new one is NOT_READY, then the session closes with no ProtocolError":
    let e = fixtureEngine(transported())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let rec = rc.establish("k").recordOf
    let o = newOwner()
    defer:
      gate.store(false)
      o.stop()
    let conn = o.session(rec.invocationOf.get)
    gate.store(true)
    let before = held.load
    let tag = o.send(conn, 19)
    check heldAt(before + 1)
    check rc.close(rec.route).code == ecOk
    check o.outcome(conn, o.send(conn, 4)).codeOf == Opt.some(ecNotReady)
    check o.closedOf(conn, 50 * Slow).isNone # still draining
    gate.store(false)
    check o.outcome(conn, tag).codeOf == Opt.some(ecOk)
    let closed = o.closedOf(conn)
    check closed.isSome
    if closed.isSome:
      check closed.get.cause == ccPeerClosed
    e.finish()

  ltTest "[IMPL-DECISION G174] [IMPL-DECISION G260] a provider stop drains to the stop deadline, then closes; the provider is destroyed only after its call returns":
    var cfg = transported()
    cfg.stopDeadline = PassingStop
    let e = fixtureEngine(cfg)
    let meterView = e.started(meter())
    let (_, rc) = e.startClient()
    let o = newOwner()
    defer:
      gate.store(false)
      o.stop()
    let conn = o.session(rc.establish("k").recordOf.invocationOf.get)
    gate.store(true)
    let before = held.load
    let gone = destroyed.load
    let tag = o.send(conn, 19)
    check heldAt(before + 1)
    var t: Thread[(Engine, string)]
    check e.stopping(meterView.instance, t)
    # The stop deadline (`PassingStop`) passes with the call held: the session
    # closes, so the caller's call fails TRANSPORT_ERROR (TRANSPORT l.543).
    check o.outcome(conn, tag, 3 * Wait).codeOf == Opt.some(ecTransport)
    check o.closedOf(conn).isSome
    check destroyed.load == gone
    gate.store(false)
    joinThread(t)
    # The stop failed `cleanup-timeout`; the release follows the call's return.
    check stopReply.load == ord(msError)
    check waitUntil(
      proc(): bool =
        destroyed.load == gone + 1
    )
    e.finish()

  ltTest "[TRN-0317] [CAP-0254] [IMPL-DECISION G174] under the Capability Authority a session ends with the decision its ticket carried, also after renewal moved the route's end; its in-flight Request is answered NOT_AUTHORISED first":
    let e = underAuthority()
    setScript(
      allow("establish-route", validMs = 1000), allow("renew-route", validMs = 10_000)
    )
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let rec = rc.establish("k").recordOf
    let o = newOwner()
    defer:
      gate.store(false)
      o.stop()
    let conn = o.session(rec.invocationOf.get)
    let fresh = rc.renew("r", rec.route).renewed.invocationOf.get
    gate.store(true)
    let before = held.load
    let tag = o.send(conn, 19)
    check heldAt(before + 1)
    caClock.advance(1500)
    # Each look is a request, after which the Runtime thread checks its
    # deadlines on the test clock.
    check waitUntil(
      proc(): bool =
        discard e.routes()
        o.pump(1) or o.responses(conn, tag) > 0
    )
    check o.outcome(conn, tag).codeOf == Opt.some(ecNotAuthorised)
    let closed = o.closedOf(conn)
    check closed.isSome
    if closed.isSome:
      check closed.get.cause == ccPeerError
      check closed.get.code == ecNotAuthorised
    # The route itself runs to its renewed end: a later session works.
    let now = e.routes().filterIt(it.route == rec.route)
    check now.len == 1 and now[0].isState(LogosNSRuntimeControlRouteStateKind.Ready)
    let later = o.session(fresh)
    gate.store(false)
    check heldAt(before)
    o.settle(50 * Slow)
    check o.responses(conn, tag) == 1
    check o.outcome(later, o.send(later, 3)).codeOf == Opt.some(ecOk)
    # Past the renewed end the route expires and its session terminates.
    caClock.advance(10_000)
    check waitUntil(
      proc(): bool =
        discard e.routes()
        discard o.pump(1)
        o.closedOf(later, 0).isSome
    )
    e.finish()

  ltTest "[RUN-0623] [IMPL-DECISION G257] an endpoint that cannot be created fails the establishment MODULE_ERROR and makes no route":
    # 120 bytes of directory: no socket path under it fits `sun_path`.
    let long = shortBase / repeat('d', 120)
    let e = fixtureEngine(transported(dir = long))
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let r = rc.establish("k")
    check r.code == ecModule
    check e.routes().len == 0
    check e.diagnostics().anyIt("endpoint" in it)
    e.finish()

# Part 4b-2b: the caller side -------------------------------------------------------------

let dmeterStatic = checkStaticRegistration("dmeter", deferredMeterSymbols()).tryGet

proc dmeter(): ModuleRecord =
  ModuleRecord(
    module: MeterModule,
    strategy: stDirectStatic,
    binding: "dmeter",
    primaryContract: Opt.some(meterRoot),
  )

proc readReq(channel: int): seq[byte] =
  encodeCbor(cborMap((cbor("channel"), cbor(uint64(channel)))))

type Done = object
  count: Atomic[int]
  code: Atomic[int]
  len: Atomic[int]
  bytes: array[256, byte]

var done: array[2, Done]

proc onDone(
    userData: pointer,
    r: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr Done](userData)
  let n = min(int(len), d.bytes.len)
  for i in 0 ..< n:
    d.bytes[i] = response[i]
  d.len.store(n)
  if not owner.release.isNil:
    owner.release(owner.state)
  d.code.store(int(r.code))
  d.count += 1

proc reset(d: var Done) =
  d.count.store(0)
  d.code.store(-1)
  d.len.store(0)

proc codeOf(d: var Done): ErrorCode =
  errorCode(int64(d.code.load)).get

proc responseOf(d: var Done): seq[byte] =
  d.bytes[0 ..< d.len.load]

proc finished(d: var Done): bool =
  let p = addr d
  waitUntil(
    proc(): bool =
      p.count.load >= 1
  )

proc prepared(
    h: var LogosRouteHandle, params: seq[byte], d: ptr Done, timeoutMs = -1
): (ErrorCode, LogosAsyncCall) =
  var o = LogosAsyncOptions(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncOptions)),
    hasTimeout: timeoutMs >= 0,
    timeoutMs: uint64(max(timeoutMs, 0)),
  )
  var cb = LogosAsyncCallbacks(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncCallbacks)),
    complete: onDone,
    userData: d,
  )
  var c = LogosAsyncCall()
  let r = h.vtable.prepareCall(
    addr h,
    "read",
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr o,
    addr cb,
    addr c,
  )
  (toResult(r).code, c)

proc submitted(
    h: var LogosRouteHandle, params: seq[byte], d: ptr Done, timeoutMs = -1
): LogosAsyncCall =
  let (code, c) = h.prepared(params, d, timeoutMs)
  check code == ecOk
  result = c
  result.vtable.submit(addr result)

proc ended(seen: ptr EndSeen, n = 1): bool =
  waitUntil(
    proc(): bool =
      seen.count.load >= n
  )

proc routeState(e: Engine): LogosNSRuntimeControlRouteStateKind =
  e.routes()[0].state.kind

template denyRenew(): untyped =
  ## Internal policy that revokes a route on its renewal (G170).
  denying(deny(action = Opt.some(aaRoute), operation = "renew_route"))

type Script = seq[(ErrorCode, string, seq[byte], seq[byte])]

proc script(cfg: EngineConfig): Script =
  ## One sequence of calls through a materialized handle: its codes,
  ## messages, details and responses.
  let e = fixtureEngine(cfg)
  discard e.started(meter())
  let (_, rc) = e.startClient()
  var h = rc.handle(rc.routeId("k"))
  for (name, params) in [
    ("read", readReq(4)),
    ("schema", @[0xA0'u8]),
    ("schema", @[0xA1'u8, 0x61, 0x78, 0x01]),
    ("read", encodeCbor(cborMap(@[(cbor("channel"), cbor("x"))]))),
    ("nope", @[0xA0'u8]),
    ("read", readReq(13)),
    ("read", readReq(14)),
    ("read", readReq(16)),
  ]:
    let r = h.raw(name, params)
    result.add((r.code, r.message, r.detail, r.response))
  done[0].reset()
  var c = h.submitted(readReq(5), addr done[0])
  check done[0].finished
  result.add((done[0].codeOf, "", @[], done[0].responseOf))
  c.vtable.release(addr c)
  h.release()
  e.finish()

suite "run.transported: the caller-side handle (I90 part 4b-2b)":
  setup:
    for d in done.mitems:
      d.reset()
    resetDeferred()
  teardown:
    gate.store(false)
    leftover()

  ltTest "[RUN-0007] [RUN-0008] [RUN-0014] [IFC-0007] [IFC-0008] [IFC-0009] [IFC-0011] [IFC-0012] [IFC-0013] [IFC-0014] [IFC-0015] [IFC-0480] one scripted sequence gives the same codes, messages, details and payloads direct and over local transport":
    let direct = script(config())
    let wire = script(transported())
    check direct.len == wire.len
    for i in 0 ..< min(direct.len, wire.len):
      checkpoint("step " & $i)
      check wire[i] == direct[i]

  ltTest "[RUN-0800] [RUN-0802] [TRN-0187] materialize returns once the provider holds the session":
    let e = fixtureEngine(transported())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.establish("k").recordOf.route
    var h = rc.handle(route)
    var seen: EndSeen
    check h.observe(addr seen) == ecOk
    # The session is there at once: closing the provider's side ends the link.
    check e.closeSessionsForTests(route).isOk
    check ended(addr seen)
    check seen.code.load == ord(ecTransport)
    h.release()
    e.finish()

  ltTest "[RUN-0801] [RUN-0806] [IMPL-DECISION G164] [IMPL-DECISION G177] [IMPL-DECISION G258] [IMPL-DECISION G255] a ticket opens one handle: another materialization is NOT_AUTHORISED and connects nothing until renew_route; a replayed answer carries no ticket":
    let e = fixtureEngine(transported())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.establish("k").recordOf.route
    var (c1, h1) = rc.materialize(route)
    check c1 == ecOk
    var (c2, _) = rc.materialize(route)
    check c2 == ecNotAuthorised
    check rc.renew("r1", route).code == ecOk
    var (c3, h2) = rc.materialize(route)
    check c3 == ecOk
    # Two connections: each handle works without the other.
    check h1.read(4).isOk and h2.read(4).isOk
    h1.release()
    check h2.read(5).isOk
    # A replay of the establishment answers without the invocation (G255).
    let again = rc.establish("k")
    check again.code == ecOk and again.recordOf.invocation.isNone
    check rc.materialize(route)[0] == ecNotAuthorised
    check rc.renew("r2", route).code == ecOk
    var (c4, h3) = rc.materialize(route)
    check c4 == ecOk
    check h3.read(4).isOk
    h2.release()
    h3.release()
    e.finish()

  ltTest "[RUN-0803] [RUN-0806] [IFC-0948] a Hello the provider rejects fails the materialization with its code; the ticket is not replayed and the route is not renewed":
    let e = fixtureEngine(transported())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.establish("k").recordOf.route
    check e.spoilNextTicketForTests().isOk
    check rc.materialize(route)[0] == ecNotAuthorised
    # The route's material went with that attempt: nothing is retried.
    check rc.materialize(route)[0] == ecNotAuthorised
    check e.routeState == LogosNSRuntimeControlRouteStateKind.Ready
    check rc.renew("r", route).code == ecOk
    var (code, h) = rc.materialize(route)
    check code == ecOk
    check h.read(4).isOk
    h.release()
    e.finish()

  ltTest "[RUN-0805] [RUN-0806] [IFC-0948] a connection lost during establishment is TRANSPORT_ERROR; the route stays ready and is not renewed":
    let e = fixtureEngine(transported())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.establish("k").recordOf.route
    check e.failNextConnectForTests(cfConnect).isOk
    check rc.materialize(route)[0] == ecTransport
    check e.routeState == LogosNSRuntimeControlRouteStateKind.Ready
    check rc.materialize(route)[0] == ecNotAuthorised
    check rc.renew("r", route).code == ecOk
    var (code, h) = rc.materialize(route)
    check code == ecOk
    check h.read(4).isOk
    h.release()
    e.finish()

  ltTest "[RUN-0806] [IFC-0948] an expired ticket gives NOT_AUTHORISED and leaves nothing to replay; renew_route gives a working handle":
    var clock = newTestClock()
    defer:
      clock.freeClock()
    let e = fixtureEngine(transported(clock = clock))
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.establish("k").recordOf.route
    clock.advance(61_000)
    check rc.materialize(route)[0] == ecNotAuthorised
    check rc.materialize(route)[0] == ecNotAuthorised
    check rc.renew("r", route).code == ecOk
    var (code, h) = rc.materialize(route)
    check code == ecOk
    check h.read(4).isOk
    h.release()
    e.finish()

  test "[RUN-0804] [RUN-0805] [IFC-0948] [IMPL-DECISION G259] a failed connection's cause decides the materialization's code; a peer mismatch fails the route":
    check connectOutcome(cfHello, ecNotAuthorised) == (ecNotAuthorised, false)
    check connectOutcome(cfHello, ecVersionMismatch) == (ecVersionMismatch, false)
    check connectOutcome(cfHello, ecModule) == (ecModule, false)
    check connectOutcome(cfHello, ecTransport) == (ecTransport, false)
    check connectOutcome(cfConnect, ecTransport) == (ecTransport, false)
    check connectOutcome(cfPeerMismatch, ecTransport) == (ecTransport, true)
    check connectOutcome(cfCapacity, ecModule) == (ecModule, false)
    check connectOutcome(cfContract, ecModule) == (ecModule, false)
    check connectOutcome(cfUnsupported, ecTransport) == (ecModule, false)
    check connectOutcome(cfShutdown, ecTransport) == (ecNotReady, false)
    check closedCode(ccPeerError, ecNotAuthorised) == ecNotAuthorised
    for cause in [ccPeerClosed, ccPeerError, ccProtocol, ccNotWritable, ccOverflow]:
      check closedCode(cause, ecTransport) == ecTransport
    check closedCode(ccPeerClosed, ecOk) == ecTransport

  ltTest "[TRN-0191] [IMPL-DECISION G259] a peer that is not the expected identity: materialize is TRANSPORT_ERROR, the route fails with transport-error and its tickets are revoked":
    let e = fixtureEngine(transported())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.establish("k").recordOf.route
    check e.failNextConnectForTests(cfPeerMismatch).isOk
    check rc.materialize(route)[0] == ecTransport
    let rec = e.routes()[0]
    check rec.state.kind == LogosNSRuntimeControlRouteStateKind.Failed
    check rec.failure.isSome and rec.failure.get.code == "transport-error"
    check e.diagnostics().anyIt("peer identity mismatch" in it)
    check rc.renew("r", route).code == ecNotReady
    check rc.materialize(route)[0] == ecNotReady
    e.finish()

  ltTest "[TRN-0278] [IMPL-DECISION G260] the handle learns its route's end: close_route NOT_READY, revocation NOT_AUTHORISED, a provider stop NOT_READY":
    block closed:
      let e = fixtureEngine(transported())
      discard e.started(meter())
      let (_, rc) = e.startClient()
      let route = rc.establish("k").recordOf.route
      var h = rc.handle(route)
      var seen: EndSeen
      check h.observe(addr seen) == ecOk
      check rc.close(route).code == ecOk
      check ended(addr seen)
      check seen.code.load == ord(ecNotReady)
      check h.read(4).error.code == ecNotReady
      h.release()
      e.finish()
    block revoked:
      let e = fixtureEngine(transported(denyRenew()))
      discard e.started(meter())
      let (_, rc) = e.startClient()
      let route = rc.establish("k").recordOf.route
      var h = rc.handle(route)
      var seen: EndSeen
      check h.observe(addr seen) == ecOk
      check rc.renew("r", route).code == ecNotAuthorised
      check ended(addr seen)
      check seen.code.load == ord(ecNotAuthorised)
      check h.read(4).error.code == ecNotAuthorised
      h.release()
      e.finish()
    block stopped:
      let e = fixtureEngine(transported())
      let m = e.started(meter())
      let (_, rc) = e.startClient()
      var h = rc.handle(rc.establish("k").recordOf.route)
      var seen: EndSeen
      check h.observe(addr seen) == ecOk
      check e.stop(m.instance).tryGet.state == msUnloaded
      check ended(addr seen)
      check seen.code.load == ord(ecNotReady)
      check h.read(4).error.code == ecNotReady
      h.release()
      e.finish()

  ltTest "[IMPL-DECISION G174] [IMPL-DECISION G260] calls in flight at the route's end: revoked, NOT_AUTHORISED; closed, their results":
    block revoked:
      let e = fixtureEngine(transported(denyRenew()))
      discard e.started(meter())
      let (_, rc) = e.startClient()
      let route = rc.establish("k").recordOf.route
      var h = rc.handle(route)
      gate.store(true)
      let before = held.load
      bgDone.store(false)
      var t: Thread[ptr LogosRouteHandle]
      createThread(t, background, addr h) # channel 19, synchronous
      var c = h.submitted(readReq(19), addr done[0])
      check heldAt(before + 2)
      check rc.renew("r", route).code == ecNotAuthorised
      check done[0].finished
      check done[0].codeOf == ecNotAuthorised
      joinThread(t)
      check bgCode.load == ord(ecNotAuthorised)
      gate.store(false)
      check heldAt(before)
      c.vtable.release(addr c)
      h.release()
      e.finish()
    block closed:
      done[0].reset()
      let e = fixtureEngine(transported())
      discard e.started(meter())
      let (_, rc) = e.startClient()
      let route = rc.establish("k").recordOf.route
      var h = rc.handle(route)
      gate.store(true)
      let before = held.load
      bgDone.store(false)
      var t: Thread[ptr LogosRouteHandle]
      createThread(t, background, addr h)
      var c = h.submitted(readReq(19), addr done[0])
      check heldAt(before + 2)
      check rc.close(route).code == ecOk
      check h.read(4).error.code == ecNotReady
      gate.store(false)
      joinThread(t)
      check bgCode.load == 0
      check done[0].finished
      check done[0].codeOf == ecOk
      c.vtable.release(addr c)
      h.release()
      e.finish()

  ltTest "[TRN-0278] [IMPL-DECISION G256] a lost connection is TRANSPORT_ERROR and leaves the route ready; the route's later end still decides new calls; renew_route gives a working handle":
    block revoked:
      let e = fixtureEngine(transported(denyRenew()))
      discard e.started(meter())
      let (_, rc) = e.startClient()
      let route = rc.establish("k").recordOf.route
      var h = rc.handle(route)
      var seen: EndSeen
      check h.observe(addr seen) == ecOk
      check e.closeSessionsForTests(route).isOk
      check ended(addr seen)
      check seen.code.load == ord(ecTransport)
      check h.read(4).error.code == ecTransport
      check e.routeState == LogosNSRuntimeControlRouteStateKind.Ready
      check rc.renew("r", route).code == ecNotAuthorised # revoked
      check h.read(4).error.code == ecNotAuthorised
      var again: EndSeen
      check h.observe(addr again) == ecTransport # the first cause
      check seen.count.load == 1
      h.release()
      e.finish()
    block closed:
      let e = fixtureEngine(transported())
      discard e.started(meter())
      let (_, rc) = e.startClient()
      let route = rc.establish("k").recordOf.route
      var h = rc.handle(route)
      check e.closeSessionsForTests(route).isOk
      check waitUntil(
        proc(): bool =
          h.read(4).isErr
      )
      check h.read(4).error.code == ecTransport
      check rc.renew("r", route).code == ecOk
      var (code, fresh) = rc.materialize(route)
      check code == ecOk
      check fresh.read(4).isOk
      check rc.close(route).code == ecOk
      check h.read(4).error.code == ecNotReady
      check fresh.read(4).error.code == ecNotReady
      h.release()
      fresh.release()
      e.finish()

  ltTest "[IFC-0729] an asynchronous call cancelled or timed out sends Cancel: the provider's request_cancel runs and the late Response is discarded":
    let e = fixtureEngine(transported(extra = @[dmeterStatic]))
    discard e.started(dmeter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.establish("k").recordOf.route)
    mode.store(ord(dmHold))
    var c = h.submitted(readReq(5), addr done[0])
    let (module, inv) = takeHeld()
    check inv != nil
    c.vtable.cancel(addr c)
    check done[0].finished
    check done[0].codeOf == ecCancelled
    check waitUntil(
      proc(): bool =
        hooks.load == 1
    )
    settle(module, inv)
    var t = h.submitted(readReq(5), addr done[1], timeoutMs = 50)
    let (module2, inv2) = takeHeld()
    check done[1].finished
    check done[1].codeOf == ecTimeout
    check waitUntil(
      proc(): bool =
        hooks.load == 2
    )
    settle(module2, inv2)
    sleep(50)
    check done[0].count.load == 1 and done[1].count.load == 1
    c.vtable.release(addr c)
    t.vtable.release(addr t)
    h.release()
    e.finish()

  ltTest "[IFC-0720] [IMPL-DECISION G256] a call prepared on a handle whose connection ended completes with the handle's code without dispatch":
    let e = fixtureEngine(transported())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.establish("k").recordOf.route
    var h = rc.handle(route)
    var (code, c) = h.prepared(readReq(19), addr done[0])
    check code == ecOk
    var seen: EndSeen
    check h.observe(addr seen) == ecOk
    check e.closeSessionsForTests(route).isOk
    check ended(addr seen)
    gate.store(true)
    let before = held.load
    c.vtable.submit(addr c)
    check done[0].finished
    check done[0].codeOf == ecTransport
    check held.load == before
    c.vtable.release(addr c)
    h.release()
    e.finish()

  ltTest "[TRN-0278] [IFC-0516] release closes the connection and emits no terminal callback; an asynchronous call in flight keeps it until its Response":
    let e = fixtureEngine(transported())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.establish("k").recordOf.route
    var h = rc.handle(route)
    var seen: EndSeen
    check h.observe(addr seen) == ecOk
    gate.store(true)
    let before = held.load
    var c = h.submitted(readReq(19), addr done[0])
    check heldAt(before + 1)
    h.release()
    gate.store(false)
    check done[0].finished
    check done[0].codeOf == ecOk
    let r = MeterReadResponse.decode(done[0].responseOf).tryGet
    check r.reading.value == 0 # not cancelled
    c.vtable.release(addr c)
    check rc.close(route).code == ecOk
    sleep(50)
    check seen.count.load == 0
    e.finish()

removeDir(shortBase)
