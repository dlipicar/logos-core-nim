## INTERFACE §2.5, §2.8, §2.9.3; RUNTIME §4.4, §7.3, §7.3.1, §7.4: module
## events on direct routes.
##
## A subscription (`SubState`) lives on the shared heap. The Runtime thread
## owns its activation and keeps it on its route (`Route.subs`); the threads
## that publish hold a reference while they deliver to it.
##
## Delivery is synchronous on the publishing thread (INTERFACE l.1961-1967,
## RUNTIME l.1179-1182): there is no Runtime event-delivery thread. For each
## publication the Runtime thread names the candidate subscriptions; the
## publishing thread validates the payload and computes its commitment once per
## selected contract (RUNTIME l.1221-1227); then, for each subscription in
## creation order [IMPL], it takes that subscription's delivery gate, asks the
## Runtime thread to admit this one handler invocation (the subscription is
## active, the route ready, the consumer live, both access scopes and both
## event decisions allow it [G175]), and runs the handler behind a barrier that
## hides any provider entry below it (INTERFACE l.2170).
##
## [IMPL] The gate. One thread at a time may be inside a subscription's handler
## or admitting one; the same thread may re-enter it through nested direct
## publication (INTERFACE l.1434-1439). `unsubscribe` and handle release
## deactivate on the Runtime thread and then wait until no other thread holds
## the gate, so no handler can begin after they return; a gate held by the
## calling thread further down its stack is not waited for (the N1 reading of
## l.1454-1458). A thread waiting for a gate stops waiting once the
## subscription is deactivated, and records a diagnostic when the wait is long:
## two threads that each publish to the other's subscription from inside a
## handler wait for each other until one subscription ends [G176].

{.push raises: [], gcsafe.}

import std/[atomics, locks, monotimes, tables, times]
import results
import ../abi/types
import ../hash/hashinput
import ../iface/[outcome, payload]
import ../transport/boundary
import ./[bell, callside, plumbing]

const
  GateSlice = 200 ## milliseconds between checks of a long gate wait
  LongGateWait = initDuration(seconds = 2) ## [G176] a wait worth a diagnostic

type SubState* = object
  ## One subscription made through one route handle (INTERFACE §2.5).
  refs: Atomic[int]
  engine: Engine
  id*: LogosSubscriptionId ## written by the Runtime thread before activation
  route*: FixedText
  generation*: uint64 ## the handle's path generation [G177]
  event*: FixedText
  blob*: ptr SchemaBlob ## the selected contract, retained
  handler: LogosEventHandler
  userData: pointer
  lock: Lock
  cond: Cond
  active: bool
  owner: int ## the thread holding the gate; 0: none
  depth: int ## the owner's nested holds

proc subOf*(p: pointer): ptr SubState =
  cast[ptr SubState](p)

proc retain*(s: ptr SubState) =
  discard s.refs.fetchAdd(1)

proc drop*(s: ptr SubState) =
  if s.refs.fetchSub(1) == 1:
    drop(s.blob)
    deinitCond(s.cond)
    deinitLock(s.lock)
    freeShared(s)

# The Runtime thread's side -----------------------------------------------------------

proc activate*(s: ptr SubState, id: LogosSubscriptionId) =
  ## [SPEC INTERFACE l.1427-1429] The id is set (and written for the caller)
  ## before the subscription becomes active.
  withLock s.lock:
    s.id = id
    s.active = true

proc deactivate*(s: ptr SubState) =
  ## No handler invocation is admitted after this; gate waiters stop waiting.
  withLock s.lock:
    s.active = false
    broadcast(s.cond)

proc isActive*(s: ptr SubState): bool =
  withLock s.lock:
    result = s.active

func eventName*(s: ptr SubState): string =
  $s.event

func routeId*(s: ptr SubState): string =
  $s.route

# The gate ------------------------------------------------------------------------------

proc enterGate(s: ptr SubState): bool =
  ## Takes the gate for one handler invocation; false once the subscription is
  ## inactive.
  let me = getThreadId()
  var reported = false
  let since = getMonoTime()
  withLock s.lock:
    while s.active and s.owner != 0 and s.owner != me:
      timedWait(s.cond, s.lock, GateSlice)
      if not reported and s.active and s.owner != 0 and s.owner != me and
          getMonoTime() - since >= LongGateWait:
        reported = true
        s.engine.diagnose(
          "a publication has waited over 2 s for subscription " & $s.id & " on route " &
            $s.route & " (G176)"
        )
    if not s.active:
      return false
    s.owner = me
    inc s.depth
  true

proc leaveGate(s: ptr SubState) =
  withLock s.lock:
    dec s.depth
    if s.depth == 0:
      s.owner = 0
      broadcast(s.cond)

proc quiesce*(s: ptr SubState) =
  ## [SPEC INTERFACE l.1446-1449, l.1465] Waits until no other thread is inside
  ## (or admitting) the subscription's handler. Once it is inactive, none can
  ## begin.
  let me = getThreadId()
  withLock s.lock:
    while s.owner != 0 and s.owner != me:
      wait(s.cond, s.lock)

proc quiesce*(subs: seq[pointer]) =
  ## Each subscription, then the reference the Runtime thread gave with it.
  for p in subs:
    quiesce(subOf(p))
    drop(subOf(p))

proc run(s: ptr SubState, name: string, data: openArray[byte]) =
  ## [SPEC INTERFACE l.1441-1444, l.2170] The event name and payload are
  ## borrowed for the invocation; the handler sees no provider entry.
  barrier:
    s.handler(
      cstring(name),
      cast[ptr UncheckedArray[uint8]](unsafeAddr data[0]),
      csize_t(data.len),
      s.userData,
    )

# Subscribing ---------------------------------------------------------------------------

proc subscribe*(
    h: ptr HandleState,
    eventName: cstring,
    handler: LogosEventHandler,
    userData: pointer,
    outId: ptr LogosSubscriptionId,
): LogosResult =
  ## [SPEC INTERFACE §2.5 l.1417-1432; RUNTIME §4.4 l.1018-1021] Activation is
  ## decided on the Runtime thread; no handler runs on this thread before it
  ## returns, and a failure leaves `*outId` as it was.
  if handler.isNil or outId == nil:
    return status(ecInvalidParams, "a null handler or subscription output")
  let name = checkEventName(eventName).valueOr:
    return status(error)
  let s = createShared(SubState)
  s.engine = h.engine
  s.route = h.route
  s.generation = h.generation
  s.event = fixed(name)
  s.blob = retain(h.blob)
  s.handler = handler
  s.userData = userData
  initLock(s.lock)
  initCond(s.cond)
  s.refs.store(1)
  let reply = h.engine.call(
    Request(
      kind: rqSubscribe,
      origin: moduleOrigin($h.consumer),
      attempt: $h.attempt,
      route: $h.route,
      bare: name,
      handle: s,
      generation: h.generation,
      outId: outId,
    )
  )
  drop(s) # the Runtime thread holds its own reference once it is active
  if reply.error.isSome:
    return status(reply.error.get)
  LogosResult()

proc unsubscribe*(h: ptr HandleState, id: LogosSubscriptionId): LogosResult =
  ## [SPEC INTERFACE §2.5 l.1446-1459] LOGOS_OK once the subscription is
  ## inactive and no handler of it runs on another thread.
  let reply = h.engine.call(
    Request(
      kind: rqUnsubscribe,
      origin: moduleOrigin($h.consumer),
      attempt: $h.attempt,
      route: $h.route,
      generation: h.generation,
      subId: id,
    )
  )
  if reply.error.isSome:
    return status(reply.error.get)
  quiesce(reply.subs)
  LogosResult()

# Publication -----------------------------------------------------------------------------

proc checkPublication(
    b: ptr SchemaBlob, name: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [SPEC RUNTIME l.1221-1227, l.1233-1235] The name resolves under the
  ## selected contract; the payload is one value of its event-data type; its
  ## commitment is computed before delivery.
  let sel = selectedOf(b).valueOr:
    return err(failure(ecModule, "the selected contract cannot be loaded"))
  if not sel.boundary.knowsEvent(name):
    return
      err(failure(ecNotAuthorised, name & " is not an event of the selected contract"))
  let v = sel.validator.checkEvent(name, data).valueOr:
    return err(toFailure(error))
  discard sel.boundary.commitEvent(name, v).valueOr:
    return err(error.failure)
  ok()

proc describe(f: InvocationFailure): string =
  $f.code & (if f.message.isSome: ": " & f.message.get else: "")

proc publishOp*(
    userData: pointer,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
) {.cdecl.} =
  ## [SPEC RUNTIME §7.3, §7.4; INTERFACE §2.8] The publish callback every
  ## execution attempt gets. Every admitted handler returns before it does; a
  ## publication that cannot be delivered is recorded as a diagnostic and
  ## dropped, since the callback has no result (RUNTIME l.1227).
  bindingEnter()
  let a = cast[ptr AttemptServices](userData)
  if a == nil:
    return
  let e = a.engine
  let name = checkEventName(eventName).valueOr:
    e.diagnose("a publication from " & $a.instance & " was dropped: " & describe(error))
    return
  if name in [GrantChangedName, PolicyChangedName]:
    # [SPEC CA §8; RUNTIME l.1660-1667; I85] Under the Capability Authority
    # policy the authority's notices go to the Runtime thread on the
    # protected path, in order with every admission, and to no subscriber; a
    # dropped one (no payload) is notification-path loss there. Under
    # internal policy they are ordinary publications.
    var payload: seq[byte]
    if cborData != nil:
      payload = view(cborData, cborDataLen)
    let consumed = e.call(
      Request(
        kind: rqAuthorityNotice,
        origin: moduleOrigin($a.instance),
        attempt: $a.attempt,
        bare: name,
        payload: payload,
      )
    )
    if consumed.admitted:
      return
  if cborData == nil or cborDataLen == 0:
    e.diagnose(
      "a publication of " & name & " from " & $a.instance & " was dropped: no payload"
    )
    return
  let bytes = view(cborData, cborDataLen)
  let reply = e.call(
    Request(
      kind: rqCandidates,
      origin: moduleOrigin($a.instance),
      attempt: $a.attempt,
      bare: name,
    )
  )
  var checked: Table[Digest, bool]
  for p in reply.subs:
    let s = subOf(p)
    let root = s.blob.root
    if root notin checked:
      let c = checkPublication(s.blob, name, bytes)
      checked[root] = c.isOk
      if c.isErr:
        e.diagnose(
          "a publication of " & name & " from " & $a.instance &
            " was not delivered on route " & $s.route & ": " & describe(c.error)
        )
    if checked.getOrDefault(root, false) and s.enterGate():
      let r = e.call(
        Request(
          kind: rqDeliver,
          origin: moduleOrigin($a.instance),
          attempt: $a.attempt,
          handle: s,
          bare: name,
        )
      )
      if r.admitted:
        s.run(name, bytes)
      s.leaveGate()
    drop(s)

proc scopedPublish*(
    inv: ptr InvocationState,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
): LogosResult =
  ## [SPEC INTERFACE §2.9.3 l.2187-2199; RUNTIME §7.3.1] Publication into the
  ## invocation's own destination: the subscriptions on its route and path
  ## generation. Checked in this order [I78]: a malformed name or payload is
  ## INVALID_PARAMS; an event outside the selected contract or the route's
  ## `publish_events`, or a revoked route, NOT_AUTHORISED; a payload that is not
  ## a value of the event's type INVALID_PARAMS; a closed destination
  ## NOT_READY. Each admitted handler returns before this does; a denied
  ## publish-event decision, a revocation or a closing destination stops the
  ## fan-out after the active handler, and a subscriber the decisions or its
  ## scope exclude is skipped.
  let name = checkEventName(eventName).valueOr:
    return status(error)
  if cborData == nil or cborDataLen == 0:
    return status(ecInvalidParams, "an event payload is one CBOR map")
  let sel = selectedOf(inv.blob).valueOr:
    return status(ecModule, "the selected contract cannot be loaded")
  if not sel.boundary.knowsEvent(name):
    return status(ecNotAuthorised, name & " is not an event of the selected contract")
  let e = inv.engine
  let reply = e.call(
    Request(
      kind: rqScoped,
      origin: moduleOrigin($inv.provider),
      route: $inv.route,
      bare: name,
      generation: inv.generation,
      ticket: inv.ticket,
    )
  )
  var failed = Opt.none(InvocationFailure)
  if reply.error.isSome:
    failed = Opt.some(failureOf(reply.error.get))
  let bytes = view(cborData, cborDataLen)
  if failed.isNone:
    let v = sel.validator.checkEvent(name, bytes)
    if v.isErr:
      failed = Opt.some(toFailure(v.error))
    else:
      let c = sel.boundary.commitEvent(name, v.get)
      if c.isErr:
        failed = Opt.some(c.error.failure)
  if failed.isNone and not reply.ready:
    failed = Opt.some(failure(ecNotReady, "the invocation's destination is closed"))
  var skipped = false
  for p in reply.subs:
    let s = subOf(p)
    if failed.isNone:
      if s.enterGate():
        let r = e.call(
          Request(
            kind: rqDeliver,
            scoped: true,
            origin: moduleOrigin($inv.provider),
            route: $inv.route,
            handle: s,
            bare: name,
            ticket: inv.ticket,
            generation: inv.generation,
          )
        )
        if r.admitted:
          s.run(name, bytes)
        s.leaveGate()
        if r.error.isSome:
          failed = Opt.some(failureOf(r.error.get))
      else:
        skipped = true
    drop(s)
  if failed.isNone and skipped:
    # A subscription went inactive during the fan-out: if its destination
    # closed with it (RUNTIME l.1275-1283), the publication reports that.
    let again = e.call(
      Request(
        kind: rqScoped,
        origin: moduleOrigin($inv.provider),
        route: $inv.route,
        bare: name,
        generation: inv.generation,
        ticket: inv.ticket,
      )
    )
    quiesce(again.subs)
    if again.error.isSome:
      failed = Opt.some(failureOf(again.error.get))
    elif not again.ready:
      failed = Opt.some(failure(ecNotReady, "the invocation's destination is closed"))
  if failed.isSome:
    return status(failed.get)
  LogosResult()
