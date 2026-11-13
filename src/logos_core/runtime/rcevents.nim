## Step 7b (DECISIONS I86): Runtime Control subscriptions (INTERFACE §2.5,
## applied to the Runtime Control contract by l.3837; RUNTIME §9.3
## l.3415-3428, l.3496-3511, l.3732-3735).
##
## [IMPL-DECISION G178 (TF-22)] An event no module publishes has no publishing
## thread to run its handlers on, so RUNTIME l.1182 (no Runtime
## event-delivery thread) is knowingly not applied to these events. The
## Runtime thread fans each committed change out after it is exposed (so after
## its write) and judges each entry against the subscriber's authority; the
## entries a subscriber may observe join that subscription's queue (in
## `engine.nim`). Event workers, a pool of their own, deliver them: one drain
## of one subscription at a time, in committed order, each entry admitted by
## the Runtime thread just before its handler runs (`rqRcDeliver`). A handler
## never runs on the Runtime thread or inside the operation that committed the
## change, so it may call Runtime Control.
##
## A subscription (`RcSub`) lives on the shared heap and holds only its
## handler, its activation and its gate; its queue and authority state stay on
## the Runtime thread. The gate is `events.nim`'s: one thread at a time admits
## or runs the subscription's handler, `unsubscribe` deactivates on the Runtime
## thread and then waits until no other thread holds the gate (IFC-0186,
## IFC-0187), and a handler unsubscribing its own subscription does not wait
## for its own frame.

{.push raises: [], gcsafe.}

import std/[atomics, locks, strutils]
import results
import ../abi/types
import ../base/perthread
import ../iface/outcome
import ./[callside, plumbing]

const
  RcPrefix = "logos.runtime_control."
  RcSuffix = "_event"

type
  RcEvent* = enum
    ## [SPEC RUNTIME §9.3] The Runtime Control events, by bare name.
    reModuleState = "module_state_changed"
    reExecutionState = "execution_state_changed"
    reRouteState = "route_state_changed"
    reInventory = "inventory_changed"
    rePermissionSettings = "permission_settings_changed"
    reConfigurationState = "configuration_state_changed"

  RcSub* = object ## One Runtime Control subscription made through one binding.
    refs: Atomic[int]
    engine: Engine
    id*: LogosSubscriptionId ## written by the Runtime thread before activation
    handler: LogosEventHandler
    userData: pointer
    lock: Lock
    cond: Cond
    active: bool
    owner: int ## the thread holding the gate; 0: none

func qualified*(e: RcEvent): string =
  ## [SPEC RUNTIME l.1217] The exact schema event identifier.
  RcPrefix & $e & RcSuffix

func rcEventOf*(name: string): Opt[RcEvent] =
  ## The Runtime Control event a fully qualified name identifies.
  if name.startsWith(RcPrefix) and name.endsWith(RcSuffix):
    let bare = name[RcPrefix.len ..< name.len - RcSuffix.len]
    for e in RcEvent:
      if $e == bare:
        return Opt.some(e)
  Opt.none(RcEvent)

proc rcSubOf*(p: pointer): ptr RcSub =
  cast[ptr RcSub](p)

proc retain*(s: ptr RcSub) =
  discard s.refs.fetchAdd(1)

proc drop*(s: ptr RcSub) =
  if s.refs.fetchSub(1) == 1:
    deinitCond(s.cond)
    deinitLock(s.lock)
    freeShared(s)

# The Runtime thread's side -----------------------------------------------------------

proc activate*(s: ptr RcSub, id: LogosSubscriptionId) =
  ## [SPEC INTERFACE l.1427-1429] The id is set (and written for the caller)
  ## before the subscription becomes active.
  withLock s.lock:
    s.id = id
    s.active = true

proc deactivate*(s: ptr RcSub) =
  ## No handler invocation is admitted after this; a worker no longer takes
  ## the gate.
  withLock s.lock:
    s.active = false
    broadcast(s.cond)

# The gate ------------------------------------------------------------------------------

proc enterGate(s: ptr RcSub): bool =
  ## Takes the gate for one admission and handler invocation; false once the
  ## subscription is inactive. Only `unsubscribe`'s wait shares it with the
  ## draining worker, and it never holds it, so the wait here is short.
  let me = getThreadId()
  withLock s.lock:
    while s.active and s.owner != 0 and s.owner != me:
      wait(s.cond, s.lock)
    if not s.active:
      return false
    s.owner = me
  true

proc leaveGate(s: ptr RcSub) =
  withLock s.lock:
    s.owner = 0
    broadcast(s.cond)

proc quiesce*(s: ptr RcSub) =
  ## [SPEC INTERFACE l.1446-1449] Waits until no other thread is inside (or
  ## admitting) the subscription's handler. Once it is inactive, none can
  ## begin.
  let me = getThreadId()
  withLock s.lock:
    while s.owner != 0 and s.owner != me:
      wait(s.cond, s.lock)

proc run(s: ptr RcSub, name: string, data: openArray[byte]) =
  ## [SPEC INTERFACE l.1441-1444, l.2170] The event name and payload are
  ## borrowed for the invocation; the handler sees no provider entry.
  barrier:
    s.handler(
      cstring(name),
      cast[ptr UncheckedArray[uint8]](unsafeAddr data[0]),
      csize_t(data.len),
      s.userData,
    )

# The binding's operations --------------------------------------------------------------

proc rcSubscribe*(
    e: Engine,
    instance, attempt: string,
    eventName: cstring,
    handler: LogosEventHandler,
    userData: pointer,
    outId: ptr LogosSubscriptionId,
): LogosResult =
  ## [SPEC INTERFACE §2.5 l.1417-1432, l.3837] Null arguments and a malformed
  ## name are INVALID_PARAMS before anything else, with `*outId` as it was;
  ## the rest is decided on the Runtime thread, which writes `*outId` before
  ## the subscription becomes active. No handler runs on this thread.
  if eventName == nil or handler.isNil or outId == nil:
    return status(ecInvalidParams, "a null event name, handler or subscription output")
  let name = checkEventName(eventName).valueOr:
    return status(error)
  let s = createShared(RcSub)
  s.engine = e
  s.handler = handler
  s.userData = userData
  initLock(s.lock)
  initCond(s.cond)
  s.refs.store(1)
  let reply = e.call(
    Request(
      kind: rqRcSubscribe,
      origin: moduleOrigin(instance),
      attempt: attempt,
      bare: name,
      handle: s,
      outId: outId,
    )
  )
  drop(s) # the Runtime thread holds its own reference once it is active
  if reply.error.isSome:
    return status(reply.error.get)
  LogosResult()

proc rcUnsubscribe*(
    e: Engine, instance, attempt: string, id: LogosSubscriptionId
): LogosResult =
  ## [SPEC INTERFACE §2.5 l.1446-1459, l.2004; RUNTIME l.622] LOGOS_OK once
  ## the subscription is inactive and no handler of it runs on another
  ## thread; a subscription the Runtime already ended is LOGOS_OK too
  ## [G178, G225]. An unknown id is INVALID_PARAMS and changes nothing.
  let reply = e.call(
    Request(
      kind: rqRcUnsubscribe, origin: moduleOrigin(instance), attempt: attempt, subId: id
    )
  )
  if reply.error.isSome:
    return status(reply.error.get)
  for p in reply.subs:
    quiesce(rcSubOf(p))
    drop(rcSubOf(p))
  LogosResult()

# Event workers ---------------------------------------------------------------------------

proc drain(e: Engine, s: ptr RcSub) =
  ## [G178] One drain of one subscription: each entry the Runtime thread
  ## admits runs its handler here, in order, until the Runtime thread ends
  ## the drain. The handler's return is reported before the gate opens, so
  ## release and destroy, which wait for it, never overtake it.
  while true:
    let gated = s.enterGate()
    let r = e.call(Request(kind: rqRcDeliver, handle: s, gated: gated))
    if r.admitted:
      s.run(r.name, r.bytes)
      e.post(Msg(kind: mkRcHandled, target: s))
    if gated:
      s.leaveGate()
    if r.drained or r.error.isSome:
      break
  drop(s)

proc rcWorkerLoop(e: Engine) =
  while true:
    var job: RcJob
    try:
      job = e.rcJobs.recv()
    except Exception:
      return
    case job.kind
    of rjQuit:
      return
    of rjDrain:
      drain(e, rcSubOf(job.sub))

proc rcWorkerMain*(e: Engine) {.thread.} =
  ## A Runtime-owned thread: `wait_for_shutdown` from a handler is NOT_READY,
  ## as from any module code the Runtime runs.
  markRuntimeThread()
  rcWorkerLoop(e)
  releasePerThread() # after the loop's locals are gone
