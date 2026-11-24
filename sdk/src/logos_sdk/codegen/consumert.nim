## Runtime support for lcn-gen's typed consumer helpers [IMPL] (DECISIONS
## G339; INTERFACE §2.5, §2.8, §2.9.1, §5.2).
##
## A generated `<stem>_calls.nim` imports this module beside `invokert`. It
## wraps a materialized route handle (`wrapRoute`) and gives the typed
## operations of the provider's contract over it:
##
## - `subscribe(route, <Event>, onEvent, …)`, generated per event (App A.4,
##   l.1489), decodes each delivery with the event's checked decoder; a
##   delivery that does not decode goes to `onInvalid`.
## - `prepareInvoke(route, <Request>, onDone, …)`, generated per method, is an
##   asynchronous call (`prepare_call`, §2.9.1) whose completion is decoded to
##   the method's response type; `submit`, `cancel` and `release` act on it.
## - `invoke(route, <Request>)`, generated per method, is the synchronous call
##   of `invokert` under this module's operation rules.
##
## **End reports (ABI 3).** Wrapping registers `observe_end` and
## `observe_subscription_end` once each, before any subscription exists
## (l.1446-1451, l.1477, l.1481). A route end goes to `onRouteEnd`; it ends
## the route's subscriptions without their `onEnd` (l.1474). A subscription the
## binding ended goes to that subscription's `onEnd` with NOT_AUTHORISED or
## MODULE_ERROR (l.1479), and a later `unsubscribe` is OK (l.1482). A
## registration on a handle that has already ended returns the termination code
## (l.1459): the wrap then fails with that code and releases the handle.
##
## **The handler rule, by thread** (l.1424, l.1939, l.1485). While a handler or
## end callback of a handle runs on a thread, an operation on that handle from
## the same thread is refused with NOT_READY, except the running handler's own
## unsubscription; `release` from it is refused too. The check comes before the
## handle's operation lock, so a handler nested inside its own handle's `call`
## (l.1405) is refused rather than deadlocked. Operations from other threads
## wait on the lock, as the caller's serialization requires (l.1935), and
## `release` from another thread waits for running handlers (l.1434). A
## self-unsubscription takes no operation lock (l.1937-1938). The lock covers
## handle operations only: a prepared call lives apart from its handle
## (l.2001-2004), so its `submit`, `cancel` and `release` take no lock, and a
## completion that runs inline in `submit` (l.2011) may prepare the next call.
##
## **State.** Everything a binding thread reads lives in shared, C-allocated
## memory: the handle, each subscription and each prepared call, with plain
## procedure pointers (`{.nimcall.}`), never closures. A subscription's state is
## linked before the binding's `subscribe` is called, with the out-parameter
## pointing into it, since a delivery or an end can arrive before `subscribe`
## returns (l.1395, l.1398). It is freed when an external unsubscription returns
## OK (l.1436-1437), after a self-unsubscription once its last running frame
## returns, or at release. The two registrations' state lives until release
## returns (IFC-0668, IFC-0967). A completion has its own storage in the call,
## reserved when the call is prepared (l.2010).
##
## **Diagnostics.** A binding's failure message and detail are copied on the
## thread that received them (`checkOutcome`), before anything else uses them
## (IFC-0260, l.1792-1794). A completion's response owner is cleared after the
## decode, on every path (IFC-0736, l.2052).
##
## **Marked responses** (DECISIONS G276). The generated `prepareInvoke` of a
## method whose response `_sensitive` marks passes `marked`: the decoded
## response is erased (`wipeTyped`) once `onDone` returns, so `onDone` copies
## what it keeps. A failure's text is erased then too, for every method: a
## provider's may echo a marked request. `_sensitive` marks method payloads
## only (§1.2.1), so an event is never erased.
##
## **Runtime Control subscriptions.** `BindingEvents` gives the same typed
## subscriptions over a module's Runtime Control binding (l.3868), one per
## binding. Its first subscription registers the binding's
## `observe_subscription_end` once, under a lock (l.1476-1477); a registration
## made raw before makes that subscription fail INVALID_PARAMS. Operations
## through the binding may run concurrently (l.1911), so these take no
## operation lock; inside the binding's end callback they are refused NOT_READY
## (l.1480), and `insideBindingEnd` tells other code the same.
##
## Handlers and completions run on whatever thread the binding uses, and may run
## on a different thread from one delivery to the next; a delivery may be one the
## binding queued (l.1406-1408). Each callback registers its thread with this
## library's Nim runtime first (`{.lcnCallback.}`, DECISIONS G464), as an exported entry
## does. Under refc they must not keep GC'd values (DECISIONS I71).
##
## **A confined kit's handles** (DECISIONS G335, G339; P1, P2). A handle
## wrapped with a confined kit's `Dispatcher` (`ModuleServices.dispatcher`)
## runs every handler, end report and completion on the kit's module thread.
## The binding's callback copies what it got into C memory (a completion's
## status with its message and detail, and its response, whose owner it then
## clears) and posts it; the module thread decodes and runs it, in arrival
## order, never inline, even when the delivering thread is the module thread
## itself (l.1405). Events wait in a bound shared by the kit's subscriptions
## (1024 [IMPL], `confinedrt.setDeliveryBound`). **A delivery that finds the
## bound reached ends its subscription**: the callback unsubscribes from inside
## its own delivery, which never waits (l.1424-1426), drops and erases the
## event, and the module thread reports `onEnd(MODULE_ERROR)` after the events
## already queued, as a binding does at its own bound (l.1473, l.1479); a later
## `unsubscribe` is OK. End reports and completions use storage reserved in
## the subscription, handle or call, so they never meet the bound. On the
## module thread an unsubscription, even from the subscription's own handler,
## and a release are external to the binding, whose callbacks run elsewhere
## (l.1416-1419, l.1434): the subscription or handle is marked closing first,
## so a delivery still arriving is dropped, and what is queued for it is
## dropped when its turn comes; its state goes with the last of them. A
## prepared call released before its queued completion ran never completes.
## Use these on the module thread only.
##
## This module imports neither the Runtime Control types nor chronos
## (`tools/lint/layers.toml`, `kit_facade`).

{.push raises: [], gcsafe.}

import std/[atomics, locks]
import results
import ../abi/[checks, types]
import ../iface/outcome
import ../base/[testhooks, wipe]
import ./[handover, kitrt]

testHooksMarker("consumert")
from ./nimrt import wipeTyped

export results, types, outcome, kitrt, handover

type
  RouteEndProc* = proc(code: ErrorCode, user: pointer) {.nimcall, gcsafe, raises: [].}
    ## A route's end (l.1442-1470): NOT_AUTHORISED, NOT_READY or TRANSPORT_ERROR.

  SubscriptionEndProc* = proc(sub: Subscription, reason: ErrorCode, user: pointer) {.
    nimcall, gcsafe, raises: []
  .}
    ## A subscription the binding ended (l.1472-1483): NOT_AUTHORISED or
    ## MODULE_ERROR.

  InvalidEventProc* = proc(sub: Subscription, reason: string, user: pointer) {.
    nimcall, gcsafe, raises: []
  .} ## A delivery that does not decode as the event's type.

  EventProc*[E] = proc(event: E, user: pointer) {.nimcall, gcsafe, raises: [].}
    ## A decoded event.

  CallDone*[R] = proc(outcome: Result[R, InvocationFailure], user: pointer) {.
    nimcall, gcsafe, raises: []
  .} ## The one completion of a prepared call (l.2010).

  DeliverProc = proc(sub: ptr SubObj, data: ptr UncheckedArray[uint8], len: csize_t) {.
    nimcall, gcsafe, raises: []
  .}

  CompleteProc = proc(
    c: ptr CallObj,
    st: Result[void, InvocationFailure],
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
  ) {.nimcall, gcsafe, raises: [].}

  HandleObj = object
    route: LogosRouteHandle
    opLock: Lock ## handle operations (l.1935)
    stateLock: Lock ## the subscription list; never held across a binding call
    subs: ptr SubObj
    onRouteEnd: RouteEndProc
    user: pointer
    endCode: Atomic[int32] ## 0 while the route is live
    # A confined kit's handle (G339): its callbacks are tasks for the module thread.
    dispatch: Dispatcher
    closing: bool ## under `stateLock`: release has begun
    pending: int ## under `stateLock`: tasks queued for the handle and its subscriptions
    released: bool
      ## under `stateLock`: released while tasks were queued; the last frees it
    endTask: TaskNode ## the route-end report, reserved
    endQueued: Atomic[bool]

  RouteHandle* = ptr HandleObj ## A wrapped route handle; `release` it once.

  BindingObj = object
    rc: ptr LogosRuntimeControlBinding
    regLock: Lock ## the end registration, made once; held across that call
    registered: bool
    stateLock: Lock ## the subscription list; never held across a binding call
    subs: ptr SubObj
    nextKept: ptr BindingObj ## in `kept`, once closed with its registration kept
    dispatch: Dispatcher ## as a handle's
    closing: bool ## under `stateLock`
    pending: int ## under `stateLock`
    released: bool ## under `stateLock`

  BindingEvents* = ptr BindingObj
    ## The typed subscriptions of one Runtime Control binding; `close` it once.

  OwnerKind = enum
    okRoute
    okBinding

  SubObj = object
    kind: OwnerKind
    handle: RouteHandle ## `okRoute`
    binding: BindingEvents ## `okBinding`
    next, prev: ptr SubObj
    linked: bool ## in the owner's list
    id: LogosSubscriptionId
    event: cstring ## shared copy
    deliver: DeliverProc
    onEvent: pointer
    onEnd: SubscriptionEndProc
    onInvalid: InvalidEventProc
    user: pointer
    frames: int
      ## handler and end frames running, and tasks queued for it; under the
      ## owner's state lock
    dead: bool ## unsubscribed; under the owner's state lock
    closing: bool ## under the owner's state lock: an unsubscription has begun
    helperEnded: bool
      ## under the owner's state lock: ended at a full delivery queue (P1),
      ## already unsubscribed from the binding
    endTask: TaskNode ## its end report, reserved
    endReason: CErrorCode
    endQueued: Atomic[bool]

  EventTask = object ## One delivery copied for the module thread.
    task: TaskNode
    sub: ptr SubObj
    len: int ## the payload's bytes follow

  Subscription* = object ## One subscription of a route handle or binding.
    p: ptr SubObj

  CallObj = object
    call: LogosAsyncCall
    complete: CompleteProc
    onDone: pointer
    user: pointer
    marked: bool ## the response `_sensitive` marks (G276)
    dispatch: Dispatcher ## its handle's
    doneTask: TaskNode ## the completion, reserved
    status: StatusCopy
    data: ptr UncheckedArray[uint8] ## the response's copy
    len: int
    queued: Atomic[bool] ## the completion's task waits on the module thread
    released: bool ## module thread: released before that task ran

  PreparedCall* = object ## A prepared asynchronous call; `release` it once.
    p: ptr CallObj

const MaxNesting = 32
  ## Distinct handles whose callbacks can be active on one thread at once.

var
  activeHandles {.threadvar.}: array[MaxNesting, tuple[h: RouteHandle, n: int]]
  currentSub {.threadvar.}: ptr SubObj
  currentCall {.threadvar.}: ptr CallObj
  bindingEndOf {.threadvar.}: ptr LogosRuntimeControlBinding
    ## The binding whose subscription-end callback runs on this thread.
  keptLock: Lock
  kept: ptr BindingObj
    ## Registrations kept past a failed initialization, still reachable.

initLock(keptLock)

# The handler rule's per-thread record ---------------------------------------------

proc enterCallback(h: RouteHandle) =
  for e in activeHandles.mitems:
    if e.h == h:
      inc e.n
      return
  for e in activeHandles.mitems:
    if e.h.isNil:
      e = (h, 1)
      return
  doAssert false, "more than " & $MaxNesting & " route handles active on one thread"

proc leaveCallback(h: RouteHandle) =
  for e in activeHandles.mitems:
    if e.h == h:
      dec e.n
      if e.n == 0:
        e.h = nil
      return

proc insideCallback(h: RouteHandle): bool =
  for e in activeHandles:
    if e.h == h:
      return true
  false

proc insideBindingEnd*(rc: ptr LogosRuntimeControlBinding): bool =
  ## Whether the subscription-end callback of `rc` runs on this thread, where no
  ## operation through `rc` may be made (l.1480).
  rc != nil and bindingEndOf == rc

# Helpers ---------------------------------------------------------------------------

func toFailure(f: AbiFailure, what: string): InvocationFailure =
  if f.message.isSome or f.detail.isSome or f.reason.len == 0:
    InvocationFailure(code: f.code, message: f.message, detail: f.detail)
  else:
    failure(f.code, what & ": " & f.reason)

func codeOf(c: CErrorCode): ErrorCode =
  errorCode(int64(c)).get(ecModule)

proc sharedCString(s: string): cstring =
  let p = cast[ptr UncheckedArray[char]](allocShared0(s.len + 1))
  for i, ch in s:
    p[i] = ch
  cast[cstring](p)

func refused(what: string): InvocationFailure =
  failure(
    ecNotReady,
    what &
      " from a handler or end callback of the same route handle (INTERFACE l.1939, l.1485)",
  )

func refusedInEnd(): InvocationFailure =
  failure(
    ecNotReady,
    "an operation through the Runtime Control binding from its subscription-end callback (INTERFACE l.1480)",
  )

proc beginOperation*(h: RouteHandle): Result[void, InvocationFailure] =
  ## Admits one handle operation: refused on a thread where a handler or end
  ## callback of `h` runs, otherwise serialized with the handle's other
  ## operations. Pair with `endOperation`.
  if h.isNil:
    return err(failure(ecInvalidParams, "a null route handle"))
  if insideCallback(h):
    return err(refused("a route-handle operation"))
  acquire(h.opLock)
  ok()

proc endOperation*(h: RouteHandle) =
  release(h.opLock)

proc raw*(h: RouteHandle): ptr LogosRouteHandle =
  ## The binding's handle. An operation through it bypasses this module's
  ## rules; the caller then keeps them itself.
  addr h.route

func dispatcher*(h: RouteHandle): Dispatcher =
  ## Where the handle's callbacks run (DECISIONS G339).
  h.dispatch

proc ended*(h: RouteHandle): Opt[ErrorCode] =
  ## The route's termination code once its end has been reported.
  let c = h.endCode.load
  if c == 0:
    Opt.none(ErrorCode)
  else:
    Opt.some(codeOf(CErrorCode(c)))

# Subscription bookkeeping -----------------------------------------------------------
#
# A subscription's state is freed exactly once, by whichever comes last of its
# unsubscription and its last running frame. Frames and the `dead` mark are
# counted under the owner's state lock, so an end callback that runs while an
# external unsubscription returns (l.1416-1419 waits for handlers only) still
# holds valid state.

proc stateLock(s: ptr SubObj): ptr Lock =
  case s.kind
  of okRoute:
    addr s.handle.stateLock
  of okBinding:
    addr s.binding.stateLock

proc head(s: ptr SubObj): ptr ptr SubObj =
  case s.kind
  of okRoute:
    addr s.handle.subs
  of okBinding:
    addr s.binding.subs

proc link(s: ptr SubObj) =
  let l = s.stateLock
  acquire(l[])
  let hd = s.head
  s.next = hd[]
  s.prev = nil
  if hd[] != nil:
    hd[].prev = s
  hd[] = s
  s.linked = true
  release(l[])

proc unlinkLocked(s: ptr SubObj) =
  if not s.linked:
    return
  if s.prev != nil:
    s.prev.next = s.next
  else:
    s.head[] = s.next
  if s.next != nil:
    s.next.prev = s.prev
  s.linked = false

proc freeSub(s: ptr SubObj) =
  if s.event != nil:
    deallocShared(cast[pointer](s.event))
  deallocShared(s)

proc enterFrame(s: ptr SubObj): bool =
  ## Counts a running frame of a live subscription.
  let l = s.stateLock
  acquire(l[])
  result = not s.dead
  if result:
    inc s.frames
  release(l[])

proc leaveFrame(s: ptr SubObj) =
  let l = s.stateLock
  acquire(l[])
  dec s.frames
  let gone = s.frames == 0 and s.dead
  if gone:
    unlinkLocked(s)
  release(l[])
  if gone:
    freeSub(s)

proc markDead(s: ptr SubObj) =
  ## A self-unsubscription: the running frame frees the state.
  let l = s.stateLock
  acquire(l[])
  s.dead = true
  release(l[])

proc dropSub(s: ptr SubObj) =
  ## An external unsubscription returned OK, or a subscription never became
  ## active: frees the state unless an end frame still runs.
  let l = s.stateLock
  acquire(l[])
  unlinkLocked(s)
  s.dead = true
  let gone = s.frames == 0
  release(l[])
  if gone:
    freeSub(s)

proc findLive(lock: ptr Lock, first: ptr SubObj, id: LogosSubscriptionId): ptr SubObj =
  ## The live subscription with `id`, its frame counted; nil if none.
  acquire(lock[])
  var s = first
  while s != nil:
    if s.id == id and not s.dead:
      inc s.frames
      break
    s = s.next
  release(lock[])
  s

proc freeAll(first: ptr SubObj) =
  var s = first
  while s != nil:
    let next = s.next
    freeSub(s)
    s = next

proc freeHandle(h: RouteHandle) =
  acquire(h.stateLock)
  let first = h.subs
  h.subs = nil
  release(h.stateLock)
  freeAll(first)
  deinitLock(h.opLock)
  deinitLock(h.stateLock)
  deallocShared(h)

proc freeBinding(b: BindingEvents) =
  acquire(b.stateLock)
  let first = b.subs
  b.subs = nil
  release(b.stateLock)
  freeAll(first)
  deinitLock(b.regLock)
  deinitLock(b.stateLock)
  deallocShared(b)

# A confined kit's tasks ----------------------------------------------------------------
#
# [DECISIONS G339, P1] Each task queued for the module thread holds a frame of its
# subscription and counts in its owner's `pending`. A subscription's state goes with
# the last of its unsubscription and its frames; a released owner's with its last
# task. All of it is counted under the owner's state lock.

proc dispatcherOf(s: ptr SubObj): Dispatcher =
  case s.kind
  of okRoute: s.handle.dispatch
  of okBinding: s.binding.dispatch

proc pendingOf(s: ptr SubObj): ptr int =
  case s.kind
  of okRoute:
    addr s.handle.pending
  of okBinding:
    addr s.binding.pending

proc ownerClosing(s: ptr SubObj): bool =
  ## Under the owner's state lock.
  case s.kind
  of okRoute: s.handle.closing
  of okBinding: s.binding.closing

proc ownerReleased(s: ptr SubObj): bool =
  ## Under the owner's state lock.
  case s.kind
  of okRoute: s.handle.released
  of okBinding: s.binding.released

proc live(s: ptr SubObj): bool =
  ## Whether a queued task of `s` still runs its handler.
  let l = s.stateLock
  acquire(l[])
  result = not s.dead and not s.closing and not s.ownerClosing
  release(l[])

proc finishTask(s: ptr SubObj) =
  ## A task of `s` ran or was dropped: its frame and its owner's count go.
  let (kind, h, b) = (s.kind, s.handle, s.binding)
  let l = s.stateLock
  acquire(l[])
  dec s.frames
  let pending = s.pendingOf
  dec pending[]
  let ownerGone = s.ownerReleased and pending[] == 0
  var subGone = false
  if s.frames == 0 and s.dead:
    unlinkLocked(s)
    subGone = true
  release(l[])
  if subGone:
    freeSub(s)
  if ownerGone:
    case kind
    of okRoute:
      freeHandle(h)
    of okBinding:
      freeBinding(b)

proc dataOf(e: ptr EventTask): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](e) + uint(sizeof(EventTask)))

proc runEvent(t: ptr TaskNode, drop: bool) {.nimcall, gcsafe, raises: [].} =
  ## On the module thread: one queued delivery, decoded and handled.
  let e = cast[ptr EventTask](t)
  let s = e.sub
  if not drop and s.live:
    let h = if s.kind == okRoute: s.handle else: nil
    if h != nil:
      enterCallback(h)
    let outer = currentSub
    currentSub = s
    s.deliver(s, (if e.len == 0: nil else: e.dataOf), csize_t(e.len))
    currentSub = outer
    if h != nil:
      leaveCallback(h)
  if e.len > 0:
    secureZero(e.dataOf, e.len)
  deallocShared(e)
  finishTask(s)

proc runEnd(t: ptr TaskNode, drop: bool) {.nimcall, gcsafe, raises: [].} =
  ## On the module thread: a subscription's end report, after its queued events.
  let s = cast[ptr SubObj](cast[uint](t) - uint(offsetOf(SubObj, endTask)))
  if not drop and s.onEnd != nil and s.live:
    let h = if s.kind == okRoute: s.handle else: nil
    if h != nil:
      enterCallback(h)
    s.onEnd(Subscription(p: s), codeOf(s.endReason), s.user)
    if h != nil:
      leaveCallback(h)
  finishTask(s)

proc runRouteEnd(t: ptr TaskNode, drop: bool) {.nimcall, gcsafe, raises: [].} =
  ## On the module thread: the route's end report.
  let h = cast[RouteHandle](cast[uint](t) - uint(offsetOf(HandleObj, endTask)))
  acquire(h.stateLock)
  let open = not h.closing
  release(h.stateLock)
  if not drop and open and h.onRouteEnd != nil:
    enterCallback(h)
    h.onRouteEnd(codeOf(CErrorCode(h.endCode.load)), h.user)
    leaveCallback(h)
  acquire(h.stateLock)
  dec h.pending
  let gone = h.released and h.pending == 0
  release(h.stateLock)
  if gone:
    freeHandle(h)

proc runDone(t: ptr TaskNode, drop: bool) {.nimcall, gcsafe, raises: [].} =
  ## On the module thread: a prepared call's completion, unless the call was
  ## released first. The response's copy is erased after it.
  let c = cast[ptr CallObj](cast[uint](t) - uint(offsetOf(CallObj, doneTask)))
  var st = readCopy(c.status)
  if not drop and not c.released:
    let outer = currentCall
    currentCall = c
    c.complete(c, st, c.data, csize_t(c.len), LogosResponseOwner())
    currentCall = outer
  wipeError(st)
  if c.data != nil:
    secureZero(c.data, c.len)
    deallocShared(c.data)
    c.data = nil
    c.len = 0
  c.queued.store(false)
  if c.released:
    deallocShared(c)

proc queueEnd(s: ptr SubObj, d: Dispatcher, reason: CErrorCode): bool =
  ## Posts the subscription's one end report; a frame the caller holds goes
  ## with it. False when one was posted already.
  var expected = false
  if not s.endQueued.compareExchange(expected, true):
    return false
  let l = s.stateLock
  acquire(l[])
  inc s.pendingOf[]
  release(l[])
  s.endReason = reason
  s.endTask.run = runEnd
  s.endTask.counted = false
  s.endTask.duringDestroy = false # G437: an end report, dropped once destroy begins
  discard d.post(d.context, addr s.endTask)
  true

proc endAtBound(s: ptr SubObj, d: Dispatcher) =
  ## [DECISIONS G339, P1] A delivery found the bound reached: from inside that
  ## delivery the subscription unsubscribes, which never waits (INTERFACE
  ## l.1424-1426), and its end report follows the events already queued.
  let l = s.stateLock
  acquire(l[])
  let first = not s.helperEnded and not s.dead and not s.closing
  if first:
    s.helperEnded = true
    inc s.frames # for the end report
  release(l[])
  if not first:
    return
  case s.kind
  of okRoute:
    discard s.handle.route.vtable.unsubscribe(addr s.handle.route, s.id)
  of okBinding:
    discard s.binding.rc.vtable.unsubscribe(s.binding.rc, s.id)
  if not queueEnd(s, d, CErrorCode(ord(ecModule))):
    leaveFrame(s)

proc queueEvent(
    s: ptr SubObj, d: Dispatcher, data: ptr UncheckedArray[uint8], len: csize_t
) =
  ## [DECISIONS G339] A delivery to a confined kit's subscription: copied and
  ## posted to the module thread, or, at the bound, the subscription's end.
  let l = s.stateLock
  acquire(l[])
  let admitted =
    not s.dead and not s.closing and not s.helperEnded and not s.ownerClosing
  if admitted:
    inc s.frames
    inc s.pendingOf[]
  release(l[])
  if not admitted:
    return
  let n =
    if data.isNil:
      0
    else:
      int(len)
  let e = cast[ptr EventTask](allocShared0(sizeof(EventTask) + n))
  e.task.run = runEvent
  e.task.counted = true
  e.task.duringDestroy = false # G437: an event, dropped once destroy begins
  e.sub = s
  e.len = n
  if n > 0:
    copyMem(e.dataOf, data, n)
  if d.post(d.context, addr e.task):
    return
  if n > 0:
    secureZero(e.dataOf, n)
  deallocShared(e)
  endAtBound(s, d)
  finishTask(s)

# Callbacks the binding runs ----------------------------------------------------------

proc onEventCb(
    eventName: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
) {.lcnCallback.} =
  let s = cast[ptr SubObj](userData)
  let d = s.dispatcherOf
  if d.confined:
    queueEvent(s, d, data, len)
    return
  if not enterFrame(s):
    return
  let h = if s.kind == okRoute: s.handle else: nil
  if h != nil:
    enterCallback(h)
  let outer = currentSub
  currentSub = s
  s.deliver(s, data, len)
  currentSub = outer
  if h != nil:
    leaveCallback(h)
  leaveFrame(s)

proc onRouteEndCb(reason: CErrorCode, userData: pointer) {.lcnCallback.} =
  let h = cast[RouteHandle](userData)
  var expected = 0'i32
  discard h.endCode.compareExchange(expected, int32(reason))
  if h.onRouteEnd != nil and h.dispatch.confined:
    var first = false
    if h.endQueued.compareExchange(first, true):
      acquire(h.stateLock)
      let open = not h.closing
      if open:
        inc h.pending
      release(h.stateLock)
      if open:
        h.endTask.run = runRouteEnd
        h.endTask.counted = false
        h.endTask.duringDestroy = false # G437: dropped once destroy begins
        discard h.dispatch.post(h.dispatch.context, addr h.endTask)
  elif h.onRouteEnd != nil:
    enterCallback(h)
    h.onRouteEnd(codeOf(reason), h.user)
    leaveCallback(h)

proc onSubscriptionEndCb(
    id: LogosSubscriptionId, reason: CErrorCode, userData: pointer
) {.lcnCallback.} =
  let h = cast[RouteHandle](userData)
  let s = findLive(addr h.stateLock, h.subs, id)
  if s.isNil:
    return
  if h.dispatch.confined:
    if not queueEnd(s, h.dispatch, reason):
      leaveFrame(s)
    return
  if s.onEnd != nil:
    enterCallback(h)
    s.onEnd(Subscription(p: s), codeOf(reason), s.user)
    leaveCallback(h)
  leaveFrame(s)

proc onBindingEndCb(
    id: LogosSubscriptionId, reason: CErrorCode, userData: pointer
) {.lcnCallback.} =
  let b = cast[BindingEvents](userData)
  let s = findLive(addr b.stateLock, b.subs, id)
  if s.isNil:
    return
  if b.dispatch.confined:
    # [DECISIONS G339] Runs later on the module thread, outside this callback,
    # where Runtime Control operations are allowed again (l.1480).
    if not queueEnd(s, b.dispatch, reason):
      leaveFrame(s)
    return
  if s.onEnd != nil:
    let outer = bindingEndOf
    bindingEndOf = b.rc
    s.onEnd(Subscription(p: s), codeOf(reason), s.user)
    bindingEndOf = outer
  leaveFrame(s)

# Wrapping and release ----------------------------------------------------------------

proc release*(h: RouteHandle): Result[void, InvocationFailure]

proc wrapRoute*(
    route: LogosRouteHandle,
    onRouteEnd: RouteEndProc = nil,
    user: pointer = nil,
    dispatcher = Dispatcher(),
): Result[RouteHandle, InvocationFailure] =
  ## Takes ownership of a materialized route handle and registers its two end
  ## reports. On failure the handle is released (when it can be) and the
  ## result says why: the route's termination code when it has already ended
  ## (l.1459), INVALID_PARAMS when a registration already exists, MODULE_ERROR
  ## when the binding has no capacity for one (l.1451). With a confined kit's
  ## `dispatcher` (`ModuleServices.dispatcher`), its callbacks run on the
  ## kit's module thread (G339).
  var probe = route
  checkRoute(addr probe).isOkOr:
    return err(toFailure(error, "route handle"))
  let h = cast[RouteHandle](allocShared0(sizeof(HandleObj)))
  h.route = route
  initLock(h.opLock)
  initLock(h.stateLock)
  h.onRouteEnd = onRouteEnd
  h.user = user
  h.dispatch = dispatcher
  proc fail(h: RouteHandle, r: LogosResult, what: string): InvocationFailure =
    let f = readStatus(r)
    result =
      if f.isErr:
        toFailure(f.error, what)
      else:
        moduleError(what & " gave no reason")
    h.route.vtable.release(addr h.route)
    deinitLock(h.opLock)
    deinitLock(h.stateLock)
    deallocShared(h)

  let r1 = h.route.vtable.observeEnd(addr h.route, onRouteEndCb, h)
  if r1.code != 0:
    return err(fail(h, r1, "observe_end"))
  let r2 = h.route.vtable.observeSubscriptionEnd(addr h.route, onSubscriptionEndCb, h)
  if r2.code != 0:
    # [DECISIONS I142] `observe_end` is installed: a route that ended meanwhile
    # has its end report running, or queued on `h` for the module thread (G339).
    # So `h` goes through `release`, never `fail`: it suppresses the report and
    # waits for a running one, and the last queued task frees `h`. That task
    # sees `closing`, so the caller's `onRouteEnd` runs for none of this
    # handle, which the caller never received.
    let st = readStatus(r2)
    let f =
      if st.isErr:
        toFailure(st.error, "observe_subscription_end")
      else:
        moduleError("observe_subscription_end gave no reason")
    discard release(h)
    return err(f)
  ok(h)

when defined(lcnTestHooks):
  proc pendingTasks*(h: RouteHandle): int =
    ## [DECISIONS G440] Test hook: the tasks queued for `h` and its
    ## subscriptions that have neither run nor been dropped.
    acquire(h.stateLock)
    result = h.pending
    release(h.stateLock)

proc release*(h: RouteHandle): Result[void, InvocationFailure] =
  ## Releases the handle: waits for operations on other threads, then for
  ## running handlers and end callbacks (l.1434, l.1484), then frees every
  ## subscription's state. Refused from a handler or end callback of `h`
  ## (l.1485). `h` is not used again.
  if h.isNil:
    return ok()
  if insideCallback(h):
    return err(refused("route-handle release"))
  acquire(h.opLock)
  acquire(h.stateLock)
  h.closing = true
  release(h.stateLock)
  h.route.vtable.release(addr h.route)
  release(h.opLock)
  acquire(h.stateLock)
  let later = h.pending > 0
  if later:
    # [DECISIONS G339] Tasks are still queued for it: the last one frees it.
    h.released = true
  release(h.stateLock)
  if not later:
    freeHandle(h)
  ok()

# The Runtime Control binding's subscriptions ------------------------------------------

proc newBindingEvents*(
    rc: ptr LogosRuntimeControlBinding, dispatcher = Dispatcher()
): BindingEvents =
  ## Typed subscriptions through `rc`, which the caller has checked; one per
  ## binding. With a confined kit's `dispatcher`, their handlers and end
  ## reports run on its module thread (G339).
  result = cast[BindingEvents](allocShared0(sizeof(BindingObj)))
  result.rc = rc
  result.dispatch = dispatcher
  initLock(result.regLock)
  initLock(result.stateLock)

proc register(b: BindingEvents): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE l.1476-1477] The binding's end report, once, before the
  ## first subscription.
  acquire(b.regLock)
  defer:
    release(b.regLock)
  if b.registered:
    return ok()
  let st = readStatus(b.rc.vtable.observeSubscriptionEnd(b.rc, onBindingEndCb, b))
  if st.isErr:
    return err(toFailure(st.error, "observe_subscription_end"))
  b.registered = true
  ok()

proc close*(
    b: BindingEvents, keepRegistration = false
): Result[void, InvocationFailure] =
  ## Unsubscribes every subscription still made through `b` (each waits for its
  ## running handlers) and frees `b`. With `keepRegistration`, as after a failed
  ## `_MODULE_init`, the end registration's state is kept, since the Runtime
  ## suppresses the binding's end callbacks only before `_MODULE_destroy`
  ## (l.1954); it then holds no subscription. The first failure is returned;
  ## the rest are still unsubscribed.
  if b.isNil:
    return ok()
  if insideBindingEnd(b.rc):
    return err(refusedInEnd())
  var first = Result[void, InvocationFailure].ok()
  acquire(b.stateLock)
  b.closing = true
  release(b.stateLock)
  while true:
    acquire(b.stateLock)
    var s = b.subs
    while s != nil and s.dead:
      s = s.next
    if s != nil:
      s.closing = true
    let ended = s != nil and s.helperEnded
    release(b.stateLock)
    if s.isNil:
      break
    if not ended:
      let st = readStatus(b.rc.vtable.unsubscribe(b.rc, s.id))
      if st.isErr and first.isOk:
        first = err(toFailure(st.error, "unsubscribe"))
    dropSub(s)
  if keepRegistration and b.registered:
    acquire(keptLock)
    b.nextKept = kept
    kept = b
    release(keptLock)
    return first
  acquire(b.stateLock)
  let later = b.pending > 0
  if later:
    b.released = true # the last queued task frees it (G339)
  release(b.stateLock)
  if not later:
    freeBinding(b)
  first

# Subscriptions -------------------------------------------------------------------------

proc newSub(
    event: string,
    deliver: DeliverProc,
    onEvent: pointer,
    onEnd: SubscriptionEndProc,
    onInvalid: InvalidEventProc,
    user: pointer,
): ptr SubObj =
  result = cast[ptr SubObj](allocShared0(sizeof(SubObj)))
  result.event = sharedCString(event)
  result.deliver = deliver
  result.onEvent = onEvent
  result.onEnd = onEnd
  result.onInvalid = onInvalid
  result.user = user

proc subscribeWith(
    h: RouteHandle,
    event: string,
    deliver: DeliverProc,
    onEvent: pointer,
    onEnd: SubscriptionEndProc,
    onInvalid: InvalidEventProc,
    user: pointer,
): Result[Subscription, InvocationFailure] =
  ?h.beginOperation()
  defer:
    h.endOperation()
  let s = newSub(event, deliver, onEvent, onEnd, onInvalid, user)
  s.kind = okRoute
  s.handle = h
  link(s)
  let r = h.route.vtable.subscribe(addr h.route, s.event, onEventCb, s, addr s.id)
  let st = readStatus(r)
  if st.isErr:
    dropSub(s)
    return err(toFailure(st.error, "subscribe"))
  ok(Subscription(p: s))

proc subscribeWith(
    b: BindingEvents,
    event: string,
    deliver: DeliverProc,
    onEvent: pointer,
    onEnd: SubscriptionEndProc,
    onInvalid: InvalidEventProc,
    user: pointer,
): Result[Subscription, InvocationFailure] =
  if b.isNil:
    return err(failure(ecInvalidParams, "null binding events"))
  if insideBindingEnd(b.rc):
    return err(refusedInEnd())
  ?b.register()
  let s = newSub(event, deliver, onEvent, onEnd, onInvalid, user)
  s.kind = okBinding
  s.binding = b
  link(s)
  let r = b.rc.vtable.subscribe(b.rc, s.event, onEventCb, s, addr s.id)
  let st = readStatus(r)
  if st.isErr:
    dropSub(s)
    return err(toFailure(st.error, "subscribe"))
  ok(Subscription(p: s))

proc deliverTyped[E](
    s: ptr SubObj, data: ptr UncheckedArray[uint8], len: csize_t
) {.nimcall, gcsafe, raises: [].} =
  mixin decode
  let r =
    if len == 0 or data.isNil:
      E.decode(newSeq[byte]())
    else:
      E.decode(data.toOpenArray(0, int(len) - 1))
  # `valueOr`, not `.error`: results' `error` accessor needs a side-effect-free
  # `$` of the value type, which generated types do not have.
  let v = r.valueOr:
    if s.onInvalid != nil:
      s.onInvalid(Subscription(p: s), error, s.user)
    return
  cast[EventProc[E]](s.onEvent)(v, s.user)

proc subscribeTyped*[E](
    h: RouteHandle,
    event: string,
    T: typedesc[E],
    onEvent: EventProc[E],
    onEnd: SubscriptionEndProc = nil,
    onInvalid: InvalidEventProc = nil,
    user: pointer = nil,
): Result[Subscription, InvocationFailure] =
  ## The generated `subscribe` of one event: `event` is its schema event
  ## identifier, `E` its type. Each delivery is decoded with `E.decode`.
  if onEvent.isNil:
    return err(failure(ecInvalidParams, "a null event handler"))
  subscribeWith(
    h, event, deliverTyped[E], cast[pointer](onEvent), onEnd, onInvalid, user
  )

proc subscribeTyped*[E](
    b: BindingEvents,
    event: string,
    T: typedesc[E],
    onEvent: EventProc[E],
    onEnd: SubscriptionEndProc = nil,
    onInvalid: InvalidEventProc = nil,
    user: pointer = nil,
): Result[Subscription, InvocationFailure] =
  ## A Runtime Control event (l.3868): `event` is its schema event identifier,
  ## `E` its type. The binding's end report is registered first, once.
  if onEvent.isNil:
    return err(failure(ecInvalidParams, "a null event handler"))
  subscribeWith(
    b, event, deliverTyped[E], cast[pointer](onEvent), onEnd, onInvalid, user
  )

proc unsubscribeConfined(s: ptr SubObj): Result[void, InvocationFailure] =
  ## [DECISIONS G339] On a confined kit's module thread: external to the
  ## binding even from the subscription's own handler, whose frame is not on
  ## the binding's thread (INTERFACE l.1416-1419). Marked closing first, so a
  ## delivery still arriving is dropped; a subscription ended at the bound is
  ## already unsubscribed from the binding, and its unsubscription is OK.
  let own = currentSub == s
  var h: RouteHandle = nil
  if s.kind == okRoute:
    h = s.handle
    if insideCallback(h) and not own:
      return err(refused("unsubscribing another subscription"))
    if not own:
      ?h.beginOperation()
  let l = s.stateLock
  acquire(l[])
  s.closing = true
  let ended = s.helperEnded
  release(l[])
  var st = Result[void, AbiFailure].ok()
  if not ended:
    st =
      case s.kind
      of okRoute:
        readStatus(h.route.vtable.unsubscribe(addr h.route, s.id))
      of okBinding:
        readStatus(s.binding.rc.vtable.unsubscribe(s.binding.rc, s.id))
  if h != nil and not own:
    h.endOperation()
  if st.isErr:
    acquire(l[])
    s.closing = false
    release(l[])
    return err(toFailure(st.error, "unsubscribe"))
  dropSub(s)
  ok()

proc unsubscribe*(sub: Subscription): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE l.1416-1437] From the subscription's own handler, a
  ## self-unsubscription: deactivates without waiting, and the state goes when
  ## the handler returns. From anywhere else, an external one: waits for running
  ## handlers, then frees the state. A subscription the binding ended
  ## unsubscribes with OK (l.1482).
  let s = sub.p
  if s.isNil:
    return err(failure(ecInvalidParams, "a null subscription"))
  if s.dispatcherOf.confined:
    return unsubscribeConfined(s)
  case s.kind
  of okRoute:
    let h = s.handle
    if insideCallback(h):
      if currentSub != s:
        return err(refused("unsubscribing another subscription"))
      let st = readStatus(h.route.vtable.unsubscribe(addr h.route, s.id))
      if st.isErr:
        return err(toFailure(st.error, "unsubscribe"))
      markDead(s)
      return ok()
    ?h.beginOperation()
    let st = readStatus(h.route.vtable.unsubscribe(addr h.route, s.id))
    h.endOperation()
    if st.isErr:
      return err(toFailure(st.error, "unsubscribe"))
    dropSub(s)
    ok()
  of okBinding:
    let b = s.binding
    if insideBindingEnd(b.rc):
      return err(refusedInEnd())
    let own = currentSub == s
    let st = readStatus(b.rc.vtable.unsubscribe(b.rc, s.id))
    if st.isErr:
      return err(toFailure(st.error, "unsubscribe"))
    if own:
      markDead(s)
    else:
      dropSub(s)
    ok()

func id*(sub: Subscription): LogosSubscriptionId =
  if sub.p.isNil: 0'u64 else: sub.p.id

# Prepared calls ------------------------------------------------------------------------

proc checkCompletion(
    status: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
): Result[void, InvocationFailure] =
  ## A completion's status and response shape, read on the thread that got
  ## them (IFC-0260).
  var st = checkOutcome(status, completionShape(response, len, owner))
  if st.isErr:
    result = err(toFailure(st.unsafeError, "completion"))
    # [DECISIONS G276] A provider's failure text goes to the receiver only: the
    # copy it was checked in is zeroed (it may hold a marked request).
    wipe(st.eResultPrivate)
    return
  ok()

proc onCompleteCb(
    userData: pointer,
    status: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.lcnCallback.} =
  let c = cast[ptr CallObj](userData)
  if c.dispatch.confined:
    # [DECISIONS G339] Copied here, the owner cleared here (l.2052), decoded
    # and handled on the module thread.
    var st = checkCompletion(status, response, len, owner)
    if st.isErr:
      copyFailure(c.status, st.unsafeError)
      wipeError(st)
    else:
      c.status.clear()
      if response != nil and len > 0:
        c.data = cast[ptr UncheckedArray[uint8]](allocShared0(int(len)))
        copyMem(c.data, response, int(len))
        c.len = int(len)
    if ownerValid(owner) and owner.release != nil:
      owner.release(owner.state)
    c.queued.store(true)
    c.doneTask.run = runDone
    c.doneTask.counted = false
    c.doneTask.duringDestroy = true
      # G437: a completion of what the module started, which `destroyModule` may
      # await (`invokeAsync` included)
    discard c.dispatch.post(c.dispatch.context, addr c.doneTask)
    return
  var st = checkCompletion(status, response, len, owner)
  let outer = currentCall
  currentCall = c
  c.complete(c, st, response, len, owner)
  currentCall = outer
  wipeError(st)

proc completeTyped[R](
    c: ptr CallObj,
    st: Result[void, InvocationFailure],
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.nimcall, gcsafe, raises: [].} =
  mixin decode
  type Outcome = Result[R, InvocationFailure]
  var outcome: Outcome
  # `st` is the caller's, which zeroes it once this returns (DECISIONS G276).
  if st.isErr:
    outcome = Outcome.err(st.unsafeError)
  else:
    var d =
      if response.isNil or len == 0:
        R.decode(newSeq[byte]())
      else:
        R.decode(response.toOpenArray(0, int(len) - 1))
    if d.isOk:
      outcome = Outcome.ok(d.get)
      if c.marked:
        wipeTyped(d.get)
    else:
      # `unsafeError`, not `.error` (its defect path needs a side-effect-free
      # `$` of the value type, which generated types lack) nor `isOkOr` (it
      # copies the whole result, a marked value included).
      outcome = Outcome.err(
        moduleError("the completion's response does not decode: " & d.unsafeError)
      )
  # [SPEC INTERFACE l.2052; IFC-0736] The owner is cleared after the decode,
  # whatever the outcome.
  if ownerValid(owner) and owner.release != nil:
    owner.release(owner.state)
  cast[CallDone[R]](c.onDone)(outcome, c.user)
  # [DECISIONS G276] A marked response is erased once its receiver returns,
  # and so is a failure's text, which may hold a marked request or response.
  if c.marked and outcome.isOk:
    wipeTyped(outcome.get)
  wipeError(outcome)

proc newCall(
    complete: CompleteProc,
    onDone: pointer,
    user: pointer,
    marked: bool,
    dispatch: Dispatcher,
): ptr CallObj =
  result = cast[ptr CallObj](allocShared0(sizeof(CallObj)))
  result.complete = complete
  result.onDone = onDone
  result.user = user
  result.marked = marked
  result.dispatch = dispatch
  result.status.clear()

proc prepared(c: ptr CallObj, r: LogosResult): Result[PreparedCall, InvocationFailure] =
  ## The `prepare_call` result of a route or a binding: the call, or none.
  let shaped = checkOutcome(r, handleShape(c.call.vtable, c.call.state))
  if shaped.isErr:
    if r.code == 0 and c.call.vtable != nil and c.call.state != nil and
        checkAsyncCall(addr c.call).isOk:
      c.call.vtable.release(addr c.call)
    deallocShared(c)
    return err(toFailure(shaped.error, "prepare_call"))
  checkAsyncCall(addr c.call).isOkOr:
    deallocShared(c)
    return err(toFailure(error, "prepare_call"))
  ok(PreparedCall(p: c))

proc callOptions(timeoutMs: uint64): LogosAsyncOptions =
  # [SPEC INTERFACE l.1992] Options and callbacks are always passed.
  LogosAsyncOptions(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncOptions)),
    hasTimeout: timeoutMs > 0,
    timeoutMs: timeoutMs,
  )

proc callCallbacks(c: ptr CallObj): LogosAsyncCallbacks =
  LogosAsyncCallbacks(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncCallbacks)),
    complete: onCompleteCb,
    userData: c,
  )

func paramsOf(params: openArray[byte]): ptr UncheckedArray[uint8] =
  if params.len == 0:
    nil
  else:
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0])

proc prepareWith(
    h: RouteHandle,
    bare: string,
    params: openArray[byte],
    complete: CompleteProc,
    onDone: pointer,
    user: pointer,
    timeoutMs: uint64,
    marked: bool,
): Result[PreparedCall, InvocationFailure] =
  ?h.beginOperation()
  defer:
    h.endOperation()
  let c = newCall(complete, onDone, user, marked, h.dispatch)
  var options = callOptions(timeoutMs)
  var callbacks = callCallbacks(c)
  let r = h.route.vtable.prepareCall(
    addr h.route,
    cstring(bare),
    paramsOf(params),
    csize_t(params.len),
    addr options,
    addr callbacks,
    addr c.call,
  )
  prepared(c, r)

proc prepareWith(
    b: BindingEvents,
    bare: string,
    params: openArray[byte],
    complete: CompleteProc,
    onDone: pointer,
    user: pointer,
    timeoutMs: uint64,
    marked: bool,
): Result[PreparedCall, InvocationFailure] =
  if b.isNil:
    return err(failure(ecInvalidParams, "null binding events"))
  if insideBindingEnd(b.rc):
    return err(refusedInEnd())
  let c = newCall(complete, onDone, user, marked, b.dispatch)
  var options = callOptions(timeoutMs)
  var callbacks = callCallbacks(c)
  let r = b.rc.vtable.prepareCall(
    b.rc,
    cstring(bare),
    paramsOf(params),
    csize_t(params.len),
    addr options,
    addr callbacks,
    addr c.call,
  )
  prepared(c, r)

proc prepareTyped*[R](
    h: RouteHandle,
    bare: string,
    params: openArray[byte],
    T: typedesc[R],
    onDone: CallDone[R],
    user: pointer = nil,
    timeoutMs: uint64 = 0,
    marked = false,
): Result[PreparedCall, InvocationFailure] =
  ## The generated `prepareInvoke` of one method: `bare` is its wire name and
  ## `params` its request bytes. The completion is decoded with `R.decode`; a
  ## nonzero `timeoutMs` is the call's deadline (TIMEOUT, l.2020, l.2024). A
  ## TRANSPORT_ERROR completion does not prove that the provider did not run
  ## the call (l.2026). With `marked`, the decoded response is erased once
  ## `onDone` returns (G276).
  if onDone.isNil:
    return err(failure(ecInvalidParams, "a null completion handler"))
  prepareWith(
    h, bare, params, completeTyped[R], cast[pointer](onDone), user, timeoutMs, marked
  )

proc prepareRc*[R](
    b: BindingEvents,
    bare: string,
    params: openArray[byte],
    T: typedesc[R],
    onDone: CallDone[R],
    user: pointer = nil,
    timeoutMs: uint64 = 0,
    marked = false,
): Result[PreparedCall, InvocationFailure] =
  ## [DECISIONS G339, G464] A Runtime Control method's asynchronous call through
  ## the module's binding (INTERFACE l.1969), as `prepareTyped` is a
  ## route's: `bare` is the method's name, `params` its request bytes, and the
  ## completion, decoded with `R.decode`, goes to `onDone`, on the kit's module
  ## thread when `b` has a confined kit's dispatcher. No completion procedure of
  ## the module's own is handed to the binding. Refused NOT_READY inside the
  ## binding's end callback (l.1480). `submit`, `cancel` and `release` it as a
  ## route's.
  if onDone.isNil:
    return err(failure(ecInvalidParams, "a null completion handler"))
  prepareWith(
    b, bare, params, completeTyped[R], cast[pointer](onDone), user, timeoutMs, marked
  )

func isNil*(c: PreparedCall): bool =
  c.p.isNil

func `==`*(a, b: PreparedCall): bool =
  a.p == b.p

proc submit*(c: PreparedCall) =
  ## [SPEC INTERFACE §2.9.1] Starts the call. Its one completion may run
  ## before `submit` returns (l.2011).
  if c.p != nil:
    c.p.call.vtable.submit(addr c.p.call)

proc cancel*(c: PreparedCall) =
  ## [SPEC INTERFACE §2.9.1] Asks for the call's cancellation.
  if c.p != nil:
    c.p.call.vtable.cancel(addr c.p.call)

proc release*(c: PreparedCall): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE l.2041-2043] Ends the call: cancels it if it has no
  ## outcome and waits for a running completion. Refused from the call's own
  ## completion.
  if c.p.isNil:
    return ok()
  if currentCall == c.p:
    return err(
      failure(
        ecNotReady,
        "a prepared call released from its own completion (INTERFACE l.2043)",
      )
    )
  c.p.call.vtable.release(addr c.p.call)
  if c.p.dispatch.confined and c.p.queued.load:
    # [DECISIONS G339] Its completion waits on the module thread: it is
    # dropped there, and the call freed with it.
    c.p.released = true
    return ok()
  deallocShared(c.p)
  ok()

{.pop.}
