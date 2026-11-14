## DECISIONS I90 (step 4b-2): transported local routes. A routing rule selects
## `local-transport` for the meter provider (G254); the Runtime serves it at an
## endpoint of its own (G257), and the ticket in a route's invocation
## descriptor opens one session there (RUNTIME §4.1, §7.5, §9.3; TRANSPORT
## §3.1, §8.1, §8.1.1, §8.2).
##
## Part 4b-2a, the provider side: the caller is a test-owned transport loop
## (`support/trnowner.nim`), which connects with the descriptor's path and
## ticket as a consumer's binding will in 4b-2b. Every wait that only bounds a
## test is scaled by `Slow`.

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
when defined(posix):
  import std/posix
import unittest2
import ../src/logos_core/runtime/[engine, routing]
import ../src/logos_core/transport/io/sock
import ../src/logos_core/abi/types
import ../src/logos_core/base/clock
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, surface]
import ../src/logos_core/iface/common_types
import ./support/[fakeca, kitbuild, kitruntime, shortdir]
import ./kit/meter_impl
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

proc transported(policy = allowAll(), clock = systemClock(), dir = ""): EngineConfig =
  ## `config`, with the meter provider routed over local transport.
  result = config(policy)
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

  ltTest "[I90] [IMPL] until step 4b-2b, materializing a transported route is refused MODULE_ERROR":
    let e = fixtureEngine(transported())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.establish("k").recordOf.route
    let (code, _) = rc.materialize(route)
    check code == ecModule
    e.finish()

removeDir(shortBase)
