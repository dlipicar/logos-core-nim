## The typed consumer helpers over a direct route (`logos_sdk/codegen/
## consumert`, the handle helpers of a generated `<stem>_calls.nim`; DECISIONS
## G339): a wrapped route handle, typed event subscriptions with their end
## reports (INTERFACE §2.5, ABI 3), the handler rule by thread (l.1424,
## l.1939, l.1485) and typed asynchronous calls (§2.9.1).
##
## The provider is the deferred meter (`kit/deferred_adapter`), which keeps its
## publish callback, so a test publishes `meter.changed_event` as the meter
## from any thread, and which can hold an asynchronous call for the test.
## Handlers and completions are `{.nimcall.}` procedures that record into
## atomics: they run on whichever thread delivers.
##
## The second suite covers `logos_sdk/kit/routes`: a `RouteSet` over the
## client's Runtime Control binding, `openRoute`, `closeRoute`, typed Runtime
## Control subscriptions and `close`.

import std/[atomics, monotimes, os, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
import ../src/logos_core/runtime/[callside, native, realizer]
import logos_sdk/hash/hashinput
import logos_sdk/abi/types
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/iface/[accept, outcome, surface]
import logos_sdk/codegen/common_types
import logos_sdk/testing/[kitbuild, kitruntime]
import ./kit/deferred_adapter, logos_sdk/testing/fixtures/meter_impl
import logos_sdk/testing/generated/meter_module_calls
import logos_sdk/kit/routes

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "consumert" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

const Changed = "meter.changed_event"

let dmeterStatic = checkStaticRegistration("dmeter", deferredMeterSymbols()).tryGet

proc dmeter(): ModuleRecord =
  ModuleRecord(
    module: "meter_module",
    strategy: stDirectStatic,
    binding: "dmeter",
    primaryContract: Opt.some(meterRoot),
  )

proc valuePayload(n: int): seq[byte] =
  ## `{"value": n}` for n < 24, in deterministic CBOR.
  @[0xA1'u8, 0x65, byte('v'), byte('a'), byte('l'), byte('u'), byte('e'), byte(n)]

proc publishedOk(n: int): bool =
  publishRaw(cstring(Changed), valuePayload(n)) == CErrorCode(ord(ecOk))

type Pub = object
  value: int
  code: Atomic[int]

proc publishes(p: ptr Pub) {.thread.} =
  p.code.store(int(publishRaw(cstring(Changed), valuePayload(p.value))))

# What the handlers see -------------------------------------------------------------

const NoCode = -1

type Got = object
  count: Atomic[int] ## typed deliveries that returned
  started: Atomic[int]
  last: Atomic[int]
  thread: Atomic[int]
  hold: Atomic[bool] ## the handler waits while it is true
  probe: Atomic[bool] ## the handler tries operations on its own handle
  selfUnsub: Atomic[bool] ## …and unsubscribes itself
  invokeInside, releaseInside, unsubInside, unsubOther: Atomic[int]
  ends: Atomic[int]
  endReason: Atomic[int]
  endId: Atomic[uint64]
  probeEnd: Atomic[bool] ## the end report tries an operation on its handle
  invokeInEnd: Atomic[int]
  invalid: Atomic[int] ## deliveries that did not decode

proc reset(g: var Got) =
  for a in [
    addr g.count,
    addr g.started,
    addr g.last,
    addr g.thread,
    addr g.ends,
    addr g.endReason,
    addr g.invalid,
  ]:
    a[].store(0)
  for a in [
    addr g.invokeInside,
    addr g.releaseInside,
    addr g.unsubInside,
    addr g.unsubOther,
    addr g.invokeInEnd,
  ]:
    a[].store(NoCode)
  g.hold.store(false)
  g.probeEnd.store(false)
  g.probe.store(false)
  g.selfUnsub.store(false)
  g.endId.store(0)

var
  got: Got
  other: Got
  theRoute: RouteHandle ## the handle the probing handler operates on
  mySub, otherSub: Subscription

func codeOf[T](r: Result[T, InvocationFailure]): int =
  if r.isOk:
    0
  else:
    ord(r.error.code)

proc onChanged(ev: MeterChangedEvent, user: pointer) {.nimcall, gcsafe, raises: [].} =
  let g = cast[ptr Got](user)
  discard g.started.fetchAdd(1)
  while g.hold.load:
    sleep(1)
  g.last.store(int(ev.value))
  g.thread.store(getThreadId())
  if g.probe.load:
    {.cast(gcsafe).}:
      g.invokeInside.store(codeOf(theRoute.invoke(MeterReadRequest(channel: 1))))
      g.releaseInside.store(codeOf(theRoute.release()))
      g.unsubOther.store(codeOf(otherSub.unsubscribe()))
      if g.selfUnsub.load:
        g.unsubInside.store(codeOf(mySub.unsubscribe()))
  discard g.count.fetchAdd(1)

proc onSubEnd(
    sub: Subscription, reason: ErrorCode, user: pointer
) {.nimcall, gcsafe, raises: [].} =
  let g = cast[ptr Got](user)
  g.endReason.store(ord(reason))
  g.endId.store(sub.id)
  if g.probeEnd.load:
    {.cast(gcsafe).}:
      g.invokeInEnd.store(codeOf(theRoute.invoke(MeterReadRequest(channel: 1))))
  discard g.ends.fetchAdd(1)

proc onBad(
    sub: Subscription, reason: string, user: pointer
) {.nimcall, gcsafe, raises: [].} =
  let g = cast[ptr Got](user)
  if reason.len > 0:
    discard g.invalid.fetchAdd(1)

type RouteEnds = object
  count: Atomic[int]
  code: Atomic[int]

var routeEnds: RouteEnds

proc onRouteEnd(code: ErrorCode, user: pointer) {.nimcall, gcsafe, raises: [].} =
  let r = cast[ptr RouteEnds](user)
  r.code.store(ord(code))
  discard r.count.fetchAdd(1)

proc rawRouteEnd(reason: CErrorCode, userData: pointer) {.cdecl, gcsafe, raises: [].} =
  discard

# What completions see --------------------------------------------------------------

type Done = object
  count: Atomic[int]
  code: Atomic[int]
  value: Atomic[int]
  releaseOwn: Atomic[int] ## `release` from the call's own completion
  thread: Atomic[int]

var
  done: Done
  ownCall: PreparedCall

proc reset(d: var Done) =
  d.count.store(0)
  d.code.store(NoCode)
  d.value.store(0)
  d.releaseOwn.store(NoCode)
  d.thread.store(0)

proc onRead(
    outcome: Result[MeterReadResponse, InvocationFailure], user: pointer
) {.nimcall, gcsafe, raises: [].} =
  let d = cast[ptr Done](user)
  if outcome.isOk:
    d.code.store(0)
    d.value.store(int(outcome.get.reading.value))
  else:
    d.code.store(ord(outcome.error.code))
  d.thread.store(getThreadId())
  {.cast(gcsafe).}:
    d.releaseOwn.store(codeOf(ownCall.release()))
  discard d.count.fetchAdd(1)

# A chain of calls, each prepared from the previous one's completion ---------------

var
  chain: array[3, PreparedCall]
  chainAt, chainDone, chainPrep: Atomic[int]

proc onChain(
    outcome: Result[MeterReadResponse, InvocationFailure], user: pointer
) {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    let i = chainAt.fetchAdd(1)
    if outcome.isOk:
      discard chainDone.fetchAdd(1)
    if i + 1 < chain.len:
      let n = theRoute.prepareInvoke(MeterReadRequest(channel: 1), onChain)
      if n.isOk:
        chain[i + 1] = n.get
        n.get.submit()
      else:
        chainPrep.store(ord(n.error.code))

# A route handle that hands the test its subscription's handler ----------------------

var
  fakeHandler: LogosEventHandler
  fakeUser: pointer
  fakeState: int

proc fCall(
    route: ptr LogosRouteHandle,
    m: cstring,
    p: ptr UncheckedArray[uint8],
    l: csize_t,
    o: ptr ptr UncheckedArray[uint8],
    ol: ptr csize_t,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  LogosResult(code: CErrorCode(ord(ecModule)))

proc fReleaseResponse(
    route: ptr LogosRouteHandle, r: ptr UncheckedArray[uint8], l: csize_t
) {.cdecl, gcsafe, raises: [].} =
  discard

proc fSubscribe(
    route: ptr LogosRouteHandle,
    name: cstring,
    handler: LogosEventHandler,
    user: pointer,
    outId: ptr LogosSubscriptionId,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    fakeHandler = handler
    fakeUser = user
  outId[] = 1
  LogosResult()

proc fUnsubscribe(
    route: ptr LogosRouteHandle, id: LogosSubscriptionId
): LogosResult {.cdecl, gcsafe, raises: [].} =
  LogosResult()

proc fRelease(route: ptr LogosRouteHandle) {.cdecl, gcsafe, raises: [].} =
  discard

proc fPrepare(
    route: ptr LogosRouteHandle,
    m: cstring,
    p: ptr UncheckedArray[uint8],
    l: csize_t,
    options: ptr LogosAsyncOptions,
    callbacks: ptr LogosAsyncCallbacks,
    outCall: ptr LogosAsyncCall,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  LogosResult(code: CErrorCode(ord(ecModule)))

proc fObserveEnd(
    route: ptr LogosRouteHandle, handler: LogosRouteEndHandler, user: pointer
): LogosResult {.cdecl, gcsafe, raises: [].} =
  LogosResult()

proc fObserveSubEnd(
    route: ptr LogosRouteHandle, handler: LogosSubscriptionEndHandler, user: pointer
): LogosResult {.cdecl, gcsafe, raises: [].} =
  LogosResult()

var fakeVtable = LogosRouteVtable(
  abiVersion: RouteVtableAbiVersion,
  structSize: csize_t(sizeof(LogosRouteVtable)),
  call: fCall,
  releaseResponse: fReleaseResponse,
  subscribe: fSubscribe,
  unsubscribe: fUnsubscribe,
  release: fRelease,
  prepareCall: fPrepare,
  observeEnd: fObserveEnd,
  observeSubscriptionEnd: fObserveSubEnd,
)

proc start(
    cfg = config(extra = @[dmeterStatic])
): (Engine, ptr LogosRuntimeControlBinding) =
  let e = fixtureEngine(cfg)
  resetDeferred()
  discard e.started(dmeter())
  let (_, rc) = e.startClient()
  (e, rc)

suite "run.consumert: typed consumer helpers over a direct route (INTERFACE §2.5, §2.9.1; ABI 3) [IMPL-DECISION G339]":
  setup:
    got.reset()
    other.reset()
    done.reset()
    routeEnds.count.store(0)
    routeEnds.code.store(0)

  test "[IFC-0671] [IMPL-DECISION G339] a typed subscription decodes each delivery to the event's type; after unsubscribe nothing more arrives, and the handle releases":
    let (e, rc) = start()
    let route = wrapRoute(rc.handle(rc.routeId("k")), onRouteEnd, addr routeEnds).tryGet
    let sub =
      route.subscribe(MeterChangedEvent, onChanged, onSubEnd, nil, addr got).tryGet
    check sub.id != 0
    check publishedOk(5)
    check got.count.load == 1
    check got.last.load == 5
    check got.thread.load == getThreadId() # direct: on the publishing thread
    check sub.unsubscribe().isOk
    check publishedOk(6)
    check got.count.load == 1
    check route.release().isOk
    check routeEnds.count.load == 0
    e.finish()

  test "[IMPL-DECISION G339] the handler rule by thread (INTERFACE l.1424, l.1939, l.1485): inside a handler, operations on its own handle and its release are NOT_READY, so is unsubscribing another subscription; its own unsubscription succeeds and nothing more arrives":
    let (e, rc) = start()
    theRoute = wrapRoute(rc.handle(rc.routeId("k"))).tryGet
    otherSub =
      theRoute.subscribe(MeterChangedEvent, onChanged, nil, nil, addr other).tryGet
    mySub = theRoute.subscribe(MeterChangedEvent, onChanged, nil, nil, addr got).tryGet
    got.probe.store(true)
    got.selfUnsub.store(true)
    check publishedOk(3)
    check got.count.load == 1
    check got.invokeInside.load == ord(ecNotReady)
    check got.releaseInside.load == ord(ecNotReady)
    check got.unsubOther.load == ord(ecNotReady)
    check got.unsubInside.load == 0
    check other.count.load == 1
    check publishedOk(4)
    check got.count.load == 1 # unsubscribed itself
    check other.count.load == 2
    check otherSub.unsubscribe().isOk
    check theRoute.release().isOk
    e.finish()

  test "[IMPL-DECISION G339] an operation from another thread is not refused while a handler runs: it is serialized on the handle and succeeds (INTERFACE l.1935)":
    let (e, rc) = start()
    theRoute = wrapRoute(rc.handle(rc.routeId("k"))).tryGet
    let sub =
      theRoute.subscribe(MeterChangedEvent, onChanged, nil, nil, addr got).tryGet
    got.hold.store(true)
    var p = Pub(value: 7)
    var t: Thread[ptr Pub]
    createThread(t, publishes, addr p)
    check waitUntil(
      proc(): bool =
        got.started.load == 1
    )
    let r = theRoute.invoke(MeterReadRequest(channel: 2))
    check r.isOk
    check r.get.reading.value == 20
    got.hold.store(false)
    joinThread(t)
    check got.count.load == 1
    check sub.unsubscribe().isOk
    check theRoute.release().isOk
    e.finish()

  test "[IFC-0963] [IFC-0964] [IMPL-DECISION G339] a subscription the binding ends at its queue bound reaches its onEnd with MODULE_ERROR; a later unsubscribe is OK (INTERFACE l.1472-1482)":
    directOnly()
    var cfg = config(extra = @[dmeterStatic])
    cfg.limits.eventQueue = 2
    let (e, rc) = start(cfg)
    let route = wrapRoute(rc.handle(rc.routeId("k"))).tryGet
    let sub =
      route.subscribe(MeterChangedEvent, onChanged, onSubEnd, nil, addr got).tryGet
    got.hold.store(true)
    var first = Pub(value: 1)
    var t: Thread[ptr Pub]
    createThread(t, publishes, addr first)
    check waitUntil(
      proc(): bool =
        got.started.load == 1
    )
    check publishedOk(2)
    check publishedOk(3)
    check publishedOk(4)
    check waitUntil(
      proc(): bool =
        got.ends.load == 1
    )
    check got.endReason.load == ord(ecModule)
    check got.endId.load == sub.id
    got.hold.store(false)
    joinThread(t)
    check sub.unsubscribe().isOk
    check route.release().isOk
    e.finish()

  test "[IMPL-DECISION G339] a route closed by close_route reaches onRouteEnd with NOT_READY once, and the handle reports it (INTERFACE l.1442-1470)":
    let (e, rc) = start()
    let id = rc.routeId("k")
    let route = wrapRoute(rc.handle(id), onRouteEnd, addr routeEnds).tryGet
    check route.ended.isNone
    check rc.close(id).code == ecOk
    check waitUntil(
      proc(): bool =
        routeEnds.count.load == 1
    )
    check routeEnds.code.load == ord(ecNotReady)
    check route.ended == Opt.some(ecNotReady)
    check route.release().isOk
    check routeEnds.count.load == 1
    e.finish()

  test "[IMPL-DECISION G339] wrapping a handle whose route has already ended fails with the termination code and releases it (INTERFACE l.1459)":
    let (e, rc) = start()
    let id = rc.routeId("k")
    let h = rc.handle(id)
    check rc.close(id).code == ecOk
    let w = wrapRoute(h, onRouteEnd, addr routeEnds)
    check w.isErr
    check w.error.code == ecNotReady
    check routeEnds.count.load == 0
    e.finish()

  test "[IMPL-DECISION G339] wrapping a handle that already has a raw observe_end registration fails INVALID_PARAMS and releases it (INTERFACE l.1451)":
    let (e, rc) = start()
    var h = rc.handle(rc.routeId("k"))
    check toResult(h.vtable.observeEnd(addr h, rawRouteEnd, nil)).code == ecOk
    let w = wrapRoute(h)
    check w.isErr
    check w.error.code == ecInvalidParams
    e.finish()

  test "[IMPL-DECISION G339] prepareInvoke: a typed completion, inline in submit; release from the call's own completion is NOT_READY, and afterwards it releases (INTERFACE §2.9.1, l.2011, l.2043)":
    let (e, rc) = start()
    let route = wrapRoute(rc.handle(rc.routeId("k"))).tryGet
    mode.store(ord(dmInline))
    ownCall =
      route.prepareInvoke(MeterReadRequest(channel: 3), onRead, addr done).tryGet
    ownCall.submit()
    check waitUntil(
      proc(): bool =
        done.count.load == 1
    )
    check done.code.load == 0
    check done.value.load == 30
    check done.releaseOwn.load == ord(ecNotReady)
    check ownCall.release().isOk
    check route.release().isOk
    e.finish()

  test "[IMPL-DECISION G339] prepareInvoke with a deadline: a held call completes TIMEOUT (INTERFACE l.2025)":
    let (e, rc) = start()
    let route = wrapRoute(rc.handle(rc.routeId("k"))).tryGet
    mode.store(ord(dmHold))
    ownCall = route.prepareInvoke(
      MeterReadRequest(channel: 4), onRead, addr done, timeoutMs = 50
    ).tryGet
    ownCall.submit()
    check waitUntil(
      proc(): bool =
        done.count.load == 1
    )
    check done.code.load == ord(ecTimeout)
    let (m, inv) = takeHeld()
    if inv != nil:
      settle(m, inv)
    check ownCall.release().isOk
    check route.release().isOk
    mode.store(ord(dmInline))
    e.finish()

  test "[IMPL-DECISION G339] a handler that runs nested in its own handle's call (a direct provider publishing during it, INTERFACE l.1405) is refused operations on that handle with NOT_READY instead of deadlocking":
    let (e, rc) = start()
    theRoute = wrapRoute(rc.handle(rc.routeId("k"))).tryGet
    otherSub = Subscription()
    mySub = theRoute.subscribe(MeterChangedEvent, onChanged, nil, nil, addr got).tryGet
    got.probe.store(true)
    let r = theRoute.invoke(MeterReadRequest(channel: 15))
    check r.isOk
    check r.get.label == "published"
    check got.count.load == 1
    check got.last.load == 150
    check got.thread.load == getThreadId()
    check got.invokeInside.load == ord(ecNotReady)
    check got.releaseInside.load == ord(ecNotReady)
    got.probe.store(false)
    check mySub.unsubscribe().isOk
    check theRoute.release().isOk
    e.finish()

  test "[IMPL-DECISION G339] an end report while an operation holds its handle's lock is not blocked by it, and an operation on the handle from inside the report is NOT_READY (INTERFACE l.1467-1468)":
    directOnly()
    var cfg = config(extra = @[dmeterStatic])
    cfg.limits.eventQueue = 2
    let (e, rc) = start(cfg)
    theRoute = wrapRoute(rc.handle(rc.routeId("k"))).tryGet
    let sub =
      theRoute.subscribe(MeterChangedEvent, onChanged, onSubEnd, nil, addr got).tryGet
    got.hold.store(true)
    got.probeEnd.store(true)
    var first = Pub(value: 1)
    var t: Thread[ptr Pub]
    createThread(t, publishes, addr first)
    check waitUntil(
      proc(): bool =
        got.started.load == 1
    )
    check theRoute.beginOperation().isOk # an operation in progress on the handle
    check publishedOk(2)
    check publishedOk(3)
    check publishedOk(4)
    check waitUntil(
      proc(): bool =
        got.ends.load == 1
    )
    check got.endReason.load == ord(ecModule)
    check got.invokeInEnd.load == ord(ecNotReady)
    theRoute.endOperation()
    got.hold.store(false)
    joinThread(t)
    check sub.unsubscribe().isOk
    check theRoute.release().isOk
    e.finish()

  test "[IMPL-DECISION G339] a handle released while its prepared call is held: the call keeps its own lifetime, completes and releases (INTERFACE l.1487, §2.9.1)":
    let (e, rc) = start()
    let route = wrapRoute(rc.handle(rc.routeId("k"))).tryGet
    mode.store(ord(dmHold))
    ownCall =
      route.prepareInvoke(MeterReadRequest(channel: 5), onRead, addr done).tryGet
    ownCall.submit()
    check waitUntil(
      proc(): bool =
        heldCount() == 1
    )
    check route.release().isOk
    let (m, inv) = takeHeld()
    check inv != nil
    if inv != nil:
      settle(m, inv)
    check waitUntil(
      proc(): bool =
        done.count.load == 1
    )
    check done.code.load == 0
    check done.value.load == 50
    check ownCall.release().isOk
    mode.store(ord(dmInline))
    e.finish()

  test "[IMPL-DECISION G339] a completion that runs inline in submit prepares and submits the next call through the same handle (INTERFACE l.2011, l.2001-2004)":
    let (e, rc) = start()
    theRoute = wrapRoute(rc.handle(rc.routeId("k"))).tryGet
    mode.store(ord(dmInline))
    chainAt.store(0)
    chainDone.store(0)
    chainPrep.store(NoCode)
    chain[0] = theRoute.prepareInvoke(MeterReadRequest(channel: 1), onChain).tryGet
    chain[0].submit()
    check waitUntil(
      proc(): bool =
        chainDone.load == chain.len
    )
    check chainPrep.load == NoCode
    for c in chain:
      check c.release().isOk
    check theRoute.release().isOk
    e.finish()

  test "[IMPL-DECISION G339] a delivery that does not decode as the event's type goes to onInvalid, never to onEvent (a binding that breaks INTERFACE l.1412)":
    let route =
      wrapRoute(LogosRouteHandle(vtable: addr fakeVtable, state: addr fakeState)).tryGet
    let sub = route.subscribe(MeterChangedEvent, onChanged, nil, onBad, addr got).tryGet
    check fakeHandler != nil
    let bad = @[
      0xA1'u8,
      0x65,
      byte('v'),
      byte('a'),
      byte('l'),
      byte('u'),
      byte('e'),
      0x61,
      byte('x'),
    ]
    fakeHandler(
      cstring(Changed),
      cast[ptr UncheckedArray[uint8]](unsafeAddr bad[0]),
      csize_t(bad.len),
      fakeUser,
    )
    check got.invalid.load == 1
    check got.count.load == 0
    let good = valuePayload(9)
    fakeHandler(
      cstring(Changed),
      cast[ptr UncheckedArray[uint8]](unsafeAddr good[0]),
      csize_t(good.len),
      fakeUser,
    )
    check got.count.load == 1
    check got.last.load == 9
    check got.invalid.load == 1
    check sub.unsubscribe().isOk
    check route.release().isOk

# Routes and Runtime Control subscriptions (`kit/routes`) -----------------------------

const ExecState = "logos.runtime_control.execution_state_changed_event"

type RcGot = object
  count: Atomic[int]
  started: Atomic[int]
  hold: Atomic[bool]
  ends: Atomic[int]
  endReason: Atomic[int]
  openInEnd, unsubInEnd: Atomic[int]

proc reset(g: var RcGot) =
  for a in [addr g.count, addr g.started, addr g.ends, addr g.endReason]:
    a[].store(0)
  g.openInEnd.store(NoCode)
  g.unsubInEnd.store(NoCode)
  g.hold.store(false)

var
  rcGot: RcGot
  theSet: RouteSet
  rcSub: Subscription

proc onExec(
    ev: LogosNSRuntimeControlExecutionStateChangedEvent, user: pointer
) {.nimcall, gcsafe, raises: [].} =
  let g = cast[ptr RcGot](user)
  discard g.started.fetchAdd(1)
  while g.hold.load:
    sleep(1)
  discard g.count.fetchAdd(1)

proc onRcEnd(
    sub: Subscription, reason: ErrorCode, user: pointer
) {.nimcall, gcsafe, raises: [].} =
  let g = cast[ptr RcGot](user)
  g.endReason.store(ord(reason))
  {.cast(gcsafe).}:
    g.openInEnd.store(codeOf(theSet.openRoute(meterRoot, meterSchema)))
    g.unsubInEnd.store(codeOf(rcSub.unsubscribe()))
  discard g.ends.fetchAdd(1)

suite "run.consumert: routes and Runtime Control subscriptions of a module instance (RUNTIME §9.3; INTERFACE l.3868) [IMPL-DECISION G339]":
  setup:
    got.reset()
    done.reset()
    rcGot.reset()
    routeEnds.count.store(0)
    routeEnds.code.store(0)

  test "[IMPL-DECISION G339] openRoute establishes, materializes and wraps a ready route the set holds, without its invocation; closeRoute ends it with onRouteEnd NOT_READY, and close releases it":
    let (e, rc) = start()
    let set = newRouteSet(rc).tryGet
    let opened = set.openRoute(
      meterRoot, meterSchema, onRouteEnd = onRouteEnd, user = addr routeEnds
    ).tryGet
    check not opened.partial
    check opened.routes.len == 1
    let o = opened.routes[0]
    check o.record.invocation.isNone
    check o.record.state.kind == LogosNSRuntimeControlRouteStateKind.Ready
    let h = o.handle.tryGet
    let r = h.invoke(MeterReadRequest(channel: 2))
    check r.isOk
    check r.get.reading.value == 20
    check set.closeRoute(o.record.route).isOk
    check waitUntil(
      proc(): bool =
        routeEnds.count.load == 1
    )
    check routeEnds.code.load == ord(ecNotReady)
    check set.close().isOk
    e.finish()

  test "[IMPL-DECISION G339] openRoute with the same request_key replays the same route; a fresh key establishes another (RUNTIME l.3072-3080)":
    let (e, rc) = start()
    let set = newRouteSet(rc).tryGet
    let a =
      set.openRoute(meterRoot, meterSchema, requestKey = "consumert-replay").tryGet
    let b =
      set.openRoute(meterRoot, meterSchema, requestKey = "consumert-replay").tryGet
    check a.routes.len == 1
    check b.routes.len == 1
    check a.routes[0].record.route == b.routes[0].record.route
    check a.routes[0].handle.isOk
    let c = set.openRoute(meterRoot, meterSchema).tryGet
    check c.routes[0].record.route != a.routes[0].record.route
    check c.routes[0].handle.isOk
    check set.close().isOk
    e.finish()

  test "[IMPL-DECISION G339] close releases what the set still holds: a held prepared call (its completion CANCELLED), the route handle and a Runtime Control subscription (INTERFACE l.1959-1960)":
    let (e, rc) = start()
    let set = newRouteSet(rc).tryGet
    let h = set.openRoute(meterRoot, meterSchema).tryGet.routes[0].handle.tryGet
    mode.store(ord(dmHold))
    ownCall = h.prepareInvoke(MeterReadRequest(channel: 6), onRead, addr done).tryGet
    set.adopt(ownCall)
    ownCall.submit()
    check waitUntil(
      proc(): bool =
        heldCount() == 1
    )
    rcSub = set.subscribe(
      ExecState,
      LogosNSRuntimeControlExecutionStateChangedEvent,
      onExec,
      nil,
      nil,
      addr rcGot,
    ).tryGet
    check set.close().isOk
    check done.count.load == 1
    check done.code.load == ord(ecCancelled)
    let (m, inv) = takeHeld()
    if inv != nil:
      settle(m, inv)
    mode.store(ord(dmInline))
    e.finish()

  test "[IMPL-DECISION G339] a typed Runtime Control subscription: past the binding's queue bound it ends with MODULE_ERROR, and inside that end report the set refuses Runtime Control operations with NOT_READY (INTERFACE l.3868, l.1478-1480)":
    var cfg = config(extra = @[dmeterStatic])
    cfg.limits.rcQueue = 4
    let (e, rc) = start(cfg)
    theSet = newRouteSet(rc).tryGet
    rcSub = theSet.subscribe(
      ExecState,
      LogosNSRuntimeControlExecutionStateChangedEvent,
      onExec,
      onRcEnd,
      nil,
      addr rcGot,
    ).tryGet
    rcGot.hold.store(true)
    discard e.create(slow(), "s").tryGet
    check e.start("s").tryGet.state == msReady
    check waitUntil(
      proc(): bool =
        rcGot.started.load == 1
    )
    check e.stop("s").tryGet.state == msUnloaded
    for i in 1 ..< 4:
      check e.start("s").tryGet.state == msReady
      check e.stop("s").tryGet.state == msUnloaded
    check waitUntil(
      proc(): bool =
        rcGot.ends.load == 1
    )
    check rcGot.endReason.load == ord(ecModule)
    check rcGot.openInEnd.load == ord(ecNotReady)
    check rcGot.unsubInEnd.load == ord(ecNotReady)
    rcGot.hold.store(false)
    check waitUntil(
      proc(): bool =
        rcGot.count.load == 1
    )
    check rcSub.unsubscribe().isOk
    check theSet.close().isOk
    e.finish()

  test "[IMPL-DECISION G339] close after a failed initialization keeps the binding's end registration, so a later set's first subscription through that binding is INVALID_PARAMS (INTERFACE l.1477, l.1954)":
    let (e, rc) = start()
    let a = newRouteSet(rc).tryGet
    rcSub = a.subscribe(
      ExecState,
      LogosNSRuntimeControlExecutionStateChangedEvent,
      onExec,
      nil,
      nil,
      addr rcGot,
    ).tryGet
    check a.close(initFailed = true).isOk
    let b = newRouteSet(rc).tryGet
    let s = b.subscribe(
      ExecState,
      LogosNSRuntimeControlExecutionStateChangedEvent,
      onExec,
      nil,
      nil,
      addr rcGot,
    )
    check s.isErr
    if s.isErr:
      check s.error.code == ecInvalidParams
    check b.close().isOk
    e.finish()
