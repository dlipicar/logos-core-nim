## Module events on direct routes (`runtime/events.nim`, `runtime/engine.nim`):
## route subscriptions (INTERFACE §2.5; RUNTIME §4.4), direct publication
## (RUNTIME §7.3, §7.4; INTERFACE §2.8) and invocation-scoped publication
## (RUNTIME §7.3.1; INTERFACE §2.9.3).
##
## The provider is the meter kit module: channel 15 publishes
## `meter.changed_event` with its publish callback, channel 17 in the
## invocation's scope. The deferred variant (`kit/deferred_adapter`) also keeps
## its publish callback, so a test can publish as the meter with any payload.
## Handlers record into `Seen` slots, which are atomics: they run on whichever
## thread publishes.

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, surface]
import ../src/logos_core/iface/common_types
import ./support/[kitbuild, kitruntime]
import ./kit/[deferred_adapter, meter_impl]
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "events" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

const
  Changed = "meter.changed_event"
  MaxPayload = 64

let dmeterStatic = checkStaticRegistration("dmeter", deferredMeterSymbols()).tryGet

proc dmeter(): ModuleRecord =
  ModuleRecord(
    module: "meter_module",
    strategy: stDirectStatic,
    binding: "dmeter",
    primaryContract: Opt.some(meterRoot),
  )

# Handlers -----------------------------------------------------------------------------

type Seen = object
  count: Atomic[int] ## handler invocations that returned
  inside: Atomic[int]
  overlaps: Atomic[int] ## invocations begun while another was active
  thread: Atomic[int]
  sawContext: Atomic[int] ## invocations that found an invocation context current
  hold: Atomic[bool] ## the handler waits while it is true
  payloadLen: Atomic[int]
  payload: array[MaxPayload, byte]
  # Re-entry, each at most once: unsubscribe itself, close a route, call or
  # publish again.
  selfRoute: ptr LogosRouteHandle
  selfId: LogosSubscriptionId
  selfCode: Atomic[int]
  closeRc: ptr LogosRuntimeControlBinding
  closeRoute: array[64, char]
  callRoute: ptr LogosRouteHandle
  callChannel: uint32
  callCode: Atomic[int]
  armed: Atomic[bool]

var seen: array[4, Seen]

proc clear(s: var Seen) =
  s.count.store(0)
  s.inside.store(0)
  s.overlaps.store(0)
  s.thread.store(0)
  s.sawContext.store(0)
  s.hold.store(false)
  s.payloadLen.store(0)
  s.selfRoute = nil
  s.selfCode.store(-1)
  s.closeRc = nil
  s.callRoute = nil
  s.callCode.store(-1)
  s.armed.store(true)

proc clearAll() =
  for s in seen.mitems:
    s.clear()

proc onEvent(
    name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let s = cast[ptr Seen](userData)
  if s.inside.fetchAdd(1) > 0 and s.thread.load != getThreadId():
    s.overlaps += 1
  s.thread.store(getThreadId())
  let n = min(int(len), MaxPayload)
  for i in 0 ..< n:
    s.payload[i] = data[i]
  s.payloadLen.store(n)
  if clientContext() != nil:
    s.sawContext += 1
  while s.hold.load:
    sleep(1)
  var first = true
  if s.armed.compareExchange(first, false):
    if s.selfRoute != nil:
      let r = s.selfRoute.vtable.unsubscribe(s.selfRoute, s.selfId)
      s.selfCode.store(int(r.code))
    {.cast(gcsafe).}:
      try:
        if s.closeRc != nil:
          discard s.closeRc.close($cast[cstring](addr s.closeRoute[0]))
        if s.callRoute != nil:
          let r = invoke(s.callRoute, MeterReadRequest(channel: s.callChannel))
          s.callCode.store(
            if r.isOk:
              0
            else:
              ord(r.error.code)
          )
      except CatchableError:
        discard
  s.inside -= 1
  s.count += 1

proc payloadOf(s: var Seen): seq[byte] =
  s.payload[0 ..< s.payloadLen.load]

proc subscribe(
    h: var LogosRouteHandle,
    s: ptr Seen,
    id: var LogosSubscriptionId,
    name = Changed,
    handler: LogosEventHandler = onEvent,
): ErrorCode =
  toResult(h.vtable.subscribe(addr h, cstring(name), handler, s, addr id)).code

proc unsubscribe(h: var LogosRouteHandle, id: LogosSubscriptionId): ErrorCode =
  toResult(h.vtable.unsubscribe(addr h, id)).code

proc closeFrom(s: var Seen, rc: ptr LogosRuntimeControlBinding, route: string) =
  s.closeRc = rc
  for i, c in route:
    s.closeRoute[i] = c
  s.closeRoute[route.len] = '\0'

proc published(e: Engine, fragment: string): bool =
  e.diagnostics().anyIt(fragment in it)

# Threads ------------------------------------------------------------------------------

type Job = object
  route: ptr LogosRouteHandle
  channel: uint32
  times: int
  id: LogosSubscriptionId
  code: Atomic[int]
  done: Atomic[bool]

proc reads(j: ptr Job) {.thread.} =
  var code = 0
  for _ in 0 ..< j.times:
    let r = invoke(j.route, MeterReadRequest(channel: j.channel))
    if r.isErr:
      code = ord(r.error.code)
  j.code.store(code)
  j.done.store(true)

proc unsubscribes(j: ptr Job) {.thread.} =
  j.code.store(int(j.route.vtable.unsubscribe(j.route, j.id).code))
  j.done.store(true)

proc releases(j: ptr Job) {.thread.} =
  j.route.vtable.release(j.route)
  j.done.store(true)

proc stillRunning(j: var Job, ms = 100): bool =
  sleep(ms)
  not j.done.load

# Tests --------------------------------------------------------------------------------

suite "run.events: route subscriptions (INTERFACE §2.5; RUNTIME §4.4)":
  setup:
    clearAll()

  test "[IFC-0174] [IFC-0175] [RUN-0191] [RUN-0549] subscribe resolves the event under the selected contract and the route's subscribe scope":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var all = rc.handle(rc.routeId("all"))
    let none =
      rc.establish("none", scope = access(subscribe = Opt.some(newSeq[seq[byte]]())))
    var narrow = rc.handle(none.routesOf.routes[0].route)
    let listed =
      rc.establish("listed", scope = access(subscribe = Opt.some(@[declRoot(Changed)])))
    var wide = rc.handle(listed.routesOf.routes[0].route)
    var id: LogosSubscriptionId
    check all.subscribe(addr seen[0], id, "meter.unknown_event") == ecNotAuthorised
    check all.subscribe(addr seen[0], id, "meter.reading") == ecNotAuthorised
    check narrow.subscribe(addr seen[0], id) == ecNotAuthorised
    check wide.subscribe(addr seen[0], id) == ecOk
    check all.subscribe(addr seen[1], id) == ecOk
    # Malformed input never reaches the Runtime thread.
    check all.subscribe(addr seen[1], id, "") == ecInvalidParams
    check all.subscribe(addr seen[1], id, handler = nil) == ecInvalidParams
    check toResult(all.vtable.subscribe(addr all, cstring(Changed), onEvent, nil, nil)).code ==
      ecInvalidParams
    all.release()
    narrow.release()
    wide.release()
    e.finish()

  test "[IFC-0176] [IFC-0180] [IFC-0179] [IFC-0178] the id is written on success only, and subscribe runs no handler on its thread":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    var id = LogosSubscriptionId(77)
    check h.subscribe(addr seen[0], id, "meter.unknown_event") == ecNotAuthorised
    check id == 77
    check h.subscribe(addr seen[0], id) == ecOk
    check id != 77
    var second = LogosSubscriptionId(0)
    check h.subscribe(addr seen[1], second) == ecOk
    check second != id # scoped to the route: distinct
    check seen[0].count.load == 0 and seen[1].count.load == 0
    check h.read(15).isOk
    check seen[0].count.load == 1 and seen[1].count.load == 1
    h.release()
    e.finish()

  test "[IFC-0186] [IFC-0187] [IFC-0652] [IFC-0653] [IFC-0654] unsubscribe waits for a handler on another thread, returns at once from its own handler, and a failure changes nothing":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var other = rc.handle(route) # same route, another path generation
    var publisher = rc.handle(route)
    var a, b: LogosSubscriptionId
    check h.subscribe(addr seen[0], a) == ecOk
    check h.subscribe(addr seen[1], b) == ecOk
    # An id this handle never issued, or one issued through another handle
    # [X3 reading]: INVALID_PARAMS, and delivery goes on.
    check h.unsubscribe(a + b + 100) == ecInvalidParams
    check other.unsubscribe(a) == ecInvalidParams
    check h.read(15).isOk
    check seen[0].count.load == 1
    # A handler held on another thread: unsubscribe waits for it.
    seen[0].hold.store(true)
    var pub = Job(route: addr publisher, channel: 15, times: 1)
    var t1: Thread[ptr Job]
    createThread(t1, reads, addr pub)
    check waitUntil(
      proc(): bool =
        seen[0].inside.load == 1
    )
    var unsub = Job(route: addr h, id: a)
    var t2: Thread[ptr Job]
    createThread(t2, unsubscribes, addr unsub)
    check unsub.stillRunning()
    seen[0].hold.store(false)
    joinThread(t2)
    joinThread(t1)
    check unsub.code.load == ord(ecOk)
    check pub.code.load == 0
    check seen[0].count.load == 2
    check h.read(15).isOk
    check seen[0].count.load == 2 # inactive
    check h.unsubscribe(a) == ecInvalidParams # already inactive
    # From its own handler, through the same handle: deactivated at once.
    seen[1].selfRoute = addr h
    seen[1].selfId = b
    seen[1].armed.store(true)
    let before = seen[1].count.load
    check h.read(15).isOk
    check seen[1].selfCode.load == ord(ecOk)
    check seen[1].count.load == before + 1
    check h.read(15).isOk
    check seen[1].count.load == before + 1
    publisher.release()
    other.release()
    h.release()
    e.finish()

  test "[IFC-0188] [IFC-0189] [RUN-0193] [IFC-0669] a route that ends deactivates its subscriptions; handle release waits for an active handler":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let first = rc.routeId("k1")
    let second = rc.routeId("k2")
    var h1 = rc.handle(first)
    var h2 = rc.handle(second)
    var driver = rc.handle(second)
    var a, b: LogosSubscriptionId
    check h1.subscribe(addr seen[0], a) == ecOk
    check h2.subscribe(addr seen[1], b) == ecOk
    check rc.close(first).code == ecOk
    check driver.read(15).isOk
    check seen[0].count.load == 0
    check seen[1].count.load == 1
    # Release waits for a handler running on another thread.
    seen[1].hold.store(true)
    var pub = Job(route: addr driver, channel: 15, times: 1)
    var t1: Thread[ptr Job]
    createThread(t1, reads, addr pub)
    check waitUntil(
      proc(): bool =
        seen[1].inside.load == 1
    )
    var rel = Job(route: addr h2)
    var t2: Thread[ptr Job]
    createThread(t2, releases, addr rel)
    check rel.stillRunning()
    seen[1].hold.store(false)
    joinThread(t2)
    joinThread(t1)
    check seen[1].count.load == 2
    check driver.read(15).isOk
    check seen[1].count.load == 2 # released with its handle
    driver.release()
    h1.release()
    e.finish()

  test "[RUN-0256] [RUN-0836] [RUN-0837] subscribe and unsubscribe through a revoked route are NOT_AUTHORISED, through a closed one NOT_READY":
    let e = fixtureEngine(
      config(denying(deny(action = Opt.some(aaRoute), operation = "renew_route")))
    )
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let revoked = rc.routeId("k1")
    let closed = rc.routeId("k2")
    var hr = rc.handle(revoked)
    var hc = rc.handle(closed)
    var a, b: LogosSubscriptionId
    check hr.subscribe(addr seen[0], a) == ecOk
    check hc.subscribe(addr seen[1], b) == ecOk
    check rc.renew("r", revoked).code == ecNotAuthorised
    check rc.close(closed).code == ecOk
    var id = LogosSubscriptionId(5)
    check hr.subscribe(addr seen[2], id) == ecNotAuthorised
    check hc.subscribe(addr seen[2], id) == ecNotReady
    check id == 5
    # The route's own code first, even for an id that exists.
    check hr.unsubscribe(a) == ecNotAuthorised
    check hc.unsubscribe(b) == ecNotReady
    check hc.unsubscribe(b + 100) == ecNotReady
    hr.release()
    hc.release()
    e.finish()

suite "run.events: publication (RUNTIME §7.3, §7.4; INTERFACE §2.8)":
  setup:
    clearAll()

  test "[RUN-0249] [IFC-0210] every initialization gets the engine's non-null publish callback":
    let e = fixtureEngine(config(extra = @[dmeterStatic]))
    resetDeferred()
    let before = clientPublishes.load
    discard e.started(dmeter())
    discard e.startClient()
    discard e.startClient()
    check publishes.load == 1
    check clientPublishes.load == before + 2
    e.finish()

  test "[IFC-0279] [IFC-0280] [RUN-0233] [IFC-0775] the handler runs on the publishing thread before publish returns, with no invocation context":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    var id: LogosSubscriptionId
    check h.subscribe(addr seen[0], id) == ecOk
    let r = h.read(15)
    check r.isOk
    check seen[0].count.load == 1
    check seen[0].thread.load == getThreadId()
    # The meter published from inside its provider entry on this thread; the
    # handler does not inherit it.
    check seen[0].sawContext.load == 0
    check seen[0].payloadOf == encodeCbor(parseDiag("{\"value\": 150}").get)
    h.release()
    e.finish()

  test "[RUN-0244] [RUN-0245] [IFC-0184] a publication that cannot be validated is dropped with a diagnostic; a valid one arrives byte for byte":
    let e = fixtureEngine(config(extra = @[dmeterStatic]))
    resetDeferred()
    discard e.started(dmeter())
    let (_, rc) = e.startClient()
    var h = rc.handle(rc.routeId("k"))
    var id: LogosSubscriptionId
    check h.subscribe(addr seen[0], id) == ecOk
    let valid = encodeCbor(parseDiag("{\"value\": 7}").get)
    publishRaw(cstring(Changed), valid)
    check seen[0].count.load == 1
    check seen[0].payloadOf == valid
    publishRaw(cstring(Changed), encodeCbor(parseDiag("{\"value\": \"seven\"}").get))
    publishRaw(cstring(Changed), encodeCbor(parseDiag("[7]").get))
    publishRaw(cstring(Changed), [0xA1'u8, 0x65]) # truncated
    publishRaw(cstring(Changed), [])
    publishRaw(cstring(""), valid)
    publishRaw(nil, valid)
    check seen[0].count.load == 1
    check e.published("no payload")
    check e.published("was not delivered on route")
    check e.published("was dropped")
    h.release()
    e.finish()

  test "[RUN-0819] [CAP-0288] [CAP-0289] [IMPL-DECISION G175] delivery is authorized for each subscriber route: publish-event and subscribe-event, and both event lists":
    let e = fixtureEngine(config(extra = @[dmeterStatic]))
    resetDeferred()
    let m = e.started(dmeter())
    let (c1, rc1) = e.startClient()
    let (c2, rc2) = e.startClient()
    var h1 = rc1.handle(rc1.routeId("k"))
    var h2 = rc2.handle(rc2.routeId("k"))
    # Subscribing is allowed, publishing on the route is not.
    let quiet =
      rc1.establish("q", scope = access(publish = Opt.some(newSeq[seq[byte]]())))
    var h3 = rc1.handle(quiet.routesOf.routes[0].route)
    var a, b, c: LogosSubscriptionId
    check h1.subscribe(addr seen[0], a) == ecOk
    check h2.subscribe(addr seen[1], b) == ecOk
    check h3.subscribe(addr seen[2], c) == ecOk
    publishRaw(cstring(Changed), encodeCbor(parseDiag("{\"value\": 1}").get))
    check seen[0].count.load == 1
    check seen[1].count.load == 1
    check seen[2].count.load == 0
    # Both decisions were asked for each delivery, with the publisher as the
    # consumer of publish-event and the subscriber's route.
    let asked = e.answers()
    check asked.anyIt(
      it.request.action == aaPublishEvent and it.request.consumer == m.instance and
        it.request.target == c2.instance and it.request.operation == Changed
    )
    check asked.anyIt(
      it.request.action == aaSubscribeEvent and it.request.consumer == c1.instance and
        it.request.operation == Changed and it.request.route.len > 0
    )
    h1.release()
    h2.release()
    h3.release()
    e.finish()
    # A denied publish-event skips that subscriber only.
    clearAll()
    let e3 = fixtureEngine(
      config(
        denying(deny(action = Opt.some(aaPublishEvent), target = "second")),
        extra = @[dmeterStatic],
      )
    )
    discard e3.started(dmeter())
    let (_, re1) = e3.startClient("first")
    let (_, re2) = e3.startClient("second")
    var k1 = re1.handle(re1.routeId("k"))
    var k2 = re2.handle(re2.routeId("k"))
    check k1.subscribe(addr seen[0], a) == ecOk
    check k2.subscribe(addr seen[1], b) == ecOk
    publishRaw(cstring(Changed), encodeCbor(parseDiag("{\"value\": 2}").get))
    check seen[0].count.load == 1
    check seen[1].count.load == 0
    k1.release()
    k2.release()
    e3.finish()
    # A denied subscribe-event refuses the subscription itself.
    let e4 = fixtureEngine(
      config(
        denying(deny(action = Opt.some(aaSubscribeEvent), consumer = "second")),
        extra = @[dmeterStatic],
      )
    )
    discard e4.started(dmeter())
    let (_, rf1) = e4.startClient("first")
    let (_, rf2) = e4.startClient("second")
    var f1 = rf1.handle(rf1.routeId("k"))
    var f2 = rf2.handle(rf2.routeId("k"))
    check f1.subscribe(addr seen[2], c) == ecOk
    check f2.subscribe(addr seen[3], c) == ecNotAuthorised
    f1.release()
    f2.release()
    e4.finish()

  test "[IFC-0181] [IFC-0182] [IFC-0183] one subscription's handler never overlaps across publishing threads; distinct subscriptions all receive":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var a, b: LogosSubscriptionId
    check h.subscribe(addr seen[0], a) == ecOk
    check h.subscribe(addr seen[1], b) == ecOk
    const Threads = 4
    const Times = 25
    var handles: array[Threads, LogosRouteHandle]
    var jobs: array[Threads, Job]
    var threads: array[Threads, Thread[ptr Job]]
    for i in 0 ..< Threads:
      handles[i] = rc.handle(route)
      jobs[i] = Job(route: addr handles[i], channel: 15, times: Times)
    for i in 0 ..< Threads:
      createThread(threads[i], reads, addr jobs[i])
    joinThreads(threads)
    for i in 0 ..< Threads:
      check jobs[i].code.load == 0
      handles[i].release()
    check seen[0].count.load == Threads * Times
    check seen[1].count.load == Threads * Times
    check seen[0].overlaps.load == 0
    check seen[1].overlaps.load == 0
    h.release()
    e.finish()

  test "[IFC-0281] [IFC-0181] a handler may call the publishing provider again and publish again on the same thread":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var again = rc.handle(route)
    var a, b: LogosSubscriptionId
    check h.subscribe(addr seen[0], a) == ecOk
    check h.subscribe(addr seen[1], b) == ecOk
    seen[0].callRoute = addr again
    seen[0].callChannel = 5
    seen[1].callRoute = addr again
    seen[1].callChannel = 15 # a nested publication re-enters both subscriptions
    check h.read(15).isOk
    check seen[0].callCode.load == 0
    check seen[1].callCode.load == 0
    check seen[0].count.load == 2
    check seen[1].count.load == 2
    again.release()
    h.release()
    e.finish()

suite "run.events: invocation-scoped publication (RUNTIME §7.3.1; INTERFACE §2.9.3)":
  setup:
    clearAll()

  test "[RUN-0821] [RUN-0825] [RUN-0826] [IFC-0782] only subscriptions on the calling handle receive a scoped event, each before publish returns":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k1")
    var h = rc.handle(route)
    var sibling = rc.handle(route)
    var elsewhere = rc.handle(rc.routeId("k2"))
    # No subscriber at all: still OK.
    let quiet = h.read(17)
    check quiet.isOk
    var a, b, c, d: LogosSubscriptionId
    check h.subscribe(addr seen[0], a) == ecOk
    check h.subscribe(addr seen[3], d) == ecOk
    check sibling.subscribe(addr seen[1], b) == ecOk
    check elsewhere.subscribe(addr seen[2], c) == ecOk
    check h.read(17).isOk
    check seen[0].count.load == 1
    check seen[3].count.load == 1
    check seen[1].count.load == 0
    check seen[2].count.load == 0
    check seen[0].payloadOf == encodeCbor(parseDiag("{\"value\": 170}").get)
    check seen[0].sawContext.load == 0
    h.release()
    sibling.release()
    elsewhere.release()
    e.finish()

  test "[RUN-0824] [RUN-0549] [IMPL-DECISION G175] an event outside the route's publish_events is NOT_AUTHORISED and reaches no one":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let r = rc.establish("k", scope = access(publish = Opt.some(newSeq[seq[byte]]())))
    var h = rc.handle(r.routesOf.routes[0].route)
    var a: LogosSubscriptionId
    check h.subscribe(addr seen[0], a) == ecOk
    # The meter returns the publish failure as its own.
    check h.read(17).error.code == ecNotAuthorised
    check seen[0].count.load == 0
    h.release()
    e.finish()

  test "[RUN-0831] [RUN-0830] a handler that closes the destination stops later admissions, and publish reports NOT_READY":
    let e = fixtureEngine(config())
    discard e.started(meter())
    let (_, rc) = e.startClient()
    let route = rc.routeId("k")
    var h = rc.handle(route)
    var a, b: LogosSubscriptionId
    check h.subscribe(addr seen[0], a) == ecOk
    check h.subscribe(addr seen[1], b) == ecOk
    seen[0].closeFrom(rc, route)
    # [G174] The call itself completes; the meter returns publish's NOT_READY.
    check h.read(17).error.code == ecNotReady
    check seen[0].count.load == 1
    check seen[1].count.load == 0
    h.release()
    e.finish()
