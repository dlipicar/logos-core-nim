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
## [I90; plan §2.7] Over local transport the same `SubState` stands behind a
## subscription made through a transported handle, but its Events arrive on
## the wire: the Runtime thread queues them, and an event worker drains them
## (`linkDrain`) through the same gate. A publication reaches each transported
## subscriber connection as one Event (`cmdPublishConn`) once the Runtime
## thread admits it, and an invocation-scoped one on a served invocation goes
## to its session with its verdict (E2).
##
## [SPEC INTERFACE l.1402-1408; DECISIONS G176] The gate. One thread at a
## time may be inside a subscription's handler or admitting one; the same
## thread may re-enter it through nested direct publication (l.1404). A
## publication that finds the gate held by another thread does not wait: it
## queues a copy of the delivery (`Queued`: the name, the data and the
## publication's identifiers, never its call ticket or anything freed with
## its call or attempt) and moves on. The thread holding the gate runs the
## queued deliveries in publication order before it lets go, each admitted
## afresh as it begins (G175). [P3 §10.1] A nested publication on that thread
## while deliveries published before it wait there takes its place in the
## queue, and runs the queue from the head, inside its publish, until its own
## delivery has begun: order holds (l.1402), and its handler returns before
## its publish does (l.1918-1920, l.2153). Up to `eventQueue` deliveries or
## `eventQueueBytes` of copied data wait per subscription (the first is
## always taken); one more ends the subscription with MODULE_ERROR
## (l.1469-1470, l.1479): the publisher that finds the bound deactivates it
## there, under the gate's lock, so nothing published after the refused
## delivery runs (l.1472), and the Runtime thread ends and reports it
## (`rqQueueBound`). Deactivation discards the queue.
## `unsubscribe` and handle release deactivate on the Runtime thread and then
## wait until no other thread holds the gate, so no handler can begin after
## they return; a gate held by the calling thread further down its stack is
## not waited for (the N1 reading of l.1454-1458).

{.push raises: [], gcsafe.}

import std/[atomics, locks, tables]
import results
import logos_sdk/abi/types
import logos_sdk/hash/hashinput
import logos_sdk/iface/[outcome, payload]
import ../transport/boundary
from ../transport/io/api import IoCommand, IoCommandKind, SubmitResult, TooLargeAction
import ./[callside, plumbing]
from ./tport import submitWait

type
  Outcome = object
    ## [P3 §10.1] A nested publication's own delivery, on its publisher's
    ## stack: whoever runs it from the queue is that same thread, in a frame
    ## above the publisher's, so the frame is live when it is written.
    begun: bool
    admitted: bool
    error: Opt[EngineError] ## a scoped delivery that stopped its publication

  Queued = object
    ## [SPEC INTERFACE l.1405-1406; P3 F1] One delivery waiting for the
    ## thread that holds the gate, on the shared heap: copied values and
    ## identifiers only, so it outlives its publication, call and attempt.
    next: ptr Queued
    number: uint64 ## [P3 §10.1] its place: entries join and begin in order
    outcome: ptr Outcome
      ## a nested publication's own delivery: its result for the publisher's
      ## frame; nil for one another thread published. Deactivation frees an
      ## entry without reading this.
    scoped: bool
    origin: FixedText ## the publishing instance
    attempt: FixedText ## an ordinary publication's attempt token
    call: uint64
      ## a scoped one's call, by its ticket's number: the Runtime thread
      ## resolves it at admission, and a call that left is a closed
      ## destination
    name: FixedText
    len: int
    data: UncheckedArray[byte]

  SubState* = object
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
    ended*: bool
      ## [DECISIONS G175, G225] Runtime thread: the Runtime ended it while its
      ## route stayed ready (`engine.endDirect`); `unsubscribe` answers
      ## LOGOS_OK once
    owner: int ## the thread holding the gate; 0: none
    depth: int ## the owner's nested holds
    head, tail: ptr Queued ## [G176] deliveries waiting for the owner, in order
    queued, queuedBytes: int ## their number and copied data
    maxQueued, maxQueuedBytes: int ## the bound, set at activation
    joined, begun: uint64
      ## [P3 §10.1] the last number given to an entry, and that of the last
      ## entry taken from the head
    bound: bool
      ## [P3 §10.2, §12.1] a publisher found the queue at its bound and
      ## deactivated the subscription; the Runtime thread ends it
      ## (`engine.endAtBound`)

  Entry = enum
    enEntered ## this thread holds the gate: deliver, then `leaveGate`
    enBusy ## another thread holds it, or deliveries wait: queue a copy
    enQueued ## the copy waits in the queue, which owns it now
    enNested
      ## this thread holds the gate and deliveries wait: the copy joined the
      ## queue, and this thread runs it up to the copy (`runNested`)
    enBound ## the queue was at its bound: the subscription is inactive now
    enInactive ## the subscription is inactive

proc subOf*(p: pointer): ptr SubState =
  cast[ptr SubState](p)

when defined(lcnTestHooks):
  proc linkKeyForTests*(p: pointer): pointer =
    ## [DECISIONS G466] Test hook: the handler `linkDrain` runs.
    let s = subOf(p)
    withLock s.lock:
      result = cast[pointer](s.handler)

proc newQueued(
    scoped: bool,
    origin, attempt: string,
    call: uint64,
    name: string,
    data: openArray[byte],
): ptr Queued =
  result = cast[ptr Queued](allocShared0(sizeof(Queued) + data.len))
  result.scoped = scoped
  result.origin = fixed(origin)
  result.attempt = fixed(attempt)
  result.call = call
  result.name = fixed(name)
  result.len = data.len
  if data.len > 0:
    copyMem(addr result.data[0], unsafeAddr data[0], data.len)

proc freeQueued(q: ptr Queued) =
  ## [DECISIONS G276] Events are not sensitive: no wipe.
  var q = q
  while q != nil:
    let next = q.next
    deallocShared(q)
    q = next

proc retain*(s: ptr SubState) =
  discard s.refs.fetchAdd(1)

proc drop*(s: ptr SubState) =
  if s.refs.fetchSub(1) == 1:
    freeQueued(s.head)
    drop(s.blob)
    deinitCond(s.cond)
    deinitLock(s.lock)
    freeShared(s)

# The Runtime thread's side -----------------------------------------------------------

proc activate*(
    s: ptr SubState, id: LogosSubscriptionId, maxQueued = 0, maxQueuedBytes = 0
) =
  ## [SPEC INTERFACE l.1427-1429] The id is set (and written for the caller)
  ## before the subscription becomes active. A direct subscription gets its
  ## queue bound (G176); a transported one never queues.
  withLock s.lock:
    s.id = id
    s.maxQueued = maxQueued
    s.maxQueuedBytes = maxQueuedBytes
    s.active = true

proc deactivate*(s: ptr SubState) =
  ## No handler invocation is admitted after this, and the deliveries still
  ## queued go (INTERFACE l.1408).
  var gone: ptr Queued
  withLock s.lock:
    s.active = false
    gone = s.head
    s.head = nil
    s.tail = nil
    s.queued = 0
    s.queuedBytes = 0
    broadcast(s.cond)
  freeQueued(gone)

proc isActive*(s: ptr SubState): bool =
  withLock s.lock:
    result = s.active

proc atBound*(s: ptr SubState): bool =
  ## [P3 §10.2, §12.1] Deactivated by a publisher at the queue's bound: the
  ## end the Runtime thread still owes it.
  withLock s.lock:
    result = s.bound

func eventName*(s: ptr SubState): string =
  $s.event

func routeId*(s: ptr SubState): string =
  $s.route

# The gate ------------------------------------------------------------------------------

proc enterGate(
    s: ptr SubState,
    copy: ptr Queued = nil,
    outcome: ptr Outcome = nil,
    number: ptr uint64 = nil,
): Entry =
  ## [SPEC INTERFACE l.1402-1406] A publication's delivery: the gate when it
  ## is free, or held by this thread with nothing queued (nested
  ## publication); otherwise `copy`, when given, joins the queue with the
  ## next number, written to `number`, unless the queue is at its bound. On
  ## the gate's own thread it carries `outcome` (`enNested`). The first queued
  ## delivery is always taken. [P3 §10.2] At the bound the subscription is
  ## deactivated here, so nothing published after the refused delivery runs.
  let me = getThreadId()
  var gone: ptr Queued
  withLock s.lock:
    if not s.active:
      return enInactive
    if s.owner == 0 or (s.owner == me and s.head == nil):
      s.owner = me
      inc s.depth
      return enEntered
    if copy == nil:
      return enBusy
    if s.queued > 0 and
        (s.queued >= s.maxQueued or s.queuedBytes + copy.len > s.maxQueuedBytes):
      s.active = false
      s.bound = true
      gone = s.head
      s.head = nil
      s.tail = nil
      s.queued = 0
      s.queuedBytes = 0
      broadcast(s.cond)
      result = enBound
    else:
      inc s.joined
      copy.number = s.joined
      number[] = s.joined
      if s.owner == me:
        copy.outcome = outcome
        result = enNested
      else:
        result = enQueued
      if s.tail == nil:
        s.head = copy
      else:
        s.tail.next = copy
      s.tail = copy
      inc s.queued
      s.queuedBytes += copy.len
  freeQueued(gone)

proc waitGate(s: ptr SubState): bool =
  ## [P3 revision 3] The transported drain's entry: it never queues. Only
  ## its own drain delivers to a transported subscription, so this does not
  ## wait in practice; false once the subscription is inactive.
  let me = getThreadId()
  withLock s.lock:
    while s.active and s.owner != 0 and s.owner != me:
      wait(s.cond, s.lock)
    if not s.active:
      return false
    s.owner = me
    inc s.depth
  true

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

proc runQueued(s: ptr SubState, q: ptr Queued) =
  ## [SPEC INTERFACE l.1406-1407; G175; P3 F1] One queued delivery on the
  ## gate's owner: admitted as it begins, as if published now by its
  ## publisher (an ordinary one needs that publisher's same attempt, ready; a
  ## scoped one its call still open), then its handler. A nested
  ## publication's own delivery reports to its frame (`Outcome`).
  let name = $q.name
  let r = s.engine.call(
    Request(
      kind: rqDeliver,
      scoped: q.scoped,
      origin: moduleOrigin($q.origin),
      attempt: $q.attempt,
      handle: s,
      bare: name,
      callId: q.call,
    )
  )
  if q.outcome != nil:
    q.outcome.begun = true
    q.outcome.admitted = r.admitted
    q.outcome.error = r.error
  if r.admitted:
    s.run(name, toOpenArray(cast[ptr UncheckedArray[byte]](addr q.data), 0, q.len - 1))

proc takeHead(s: ptr SubState): ptr Queued =
  ## Under the gate's lock, on its owner: the next delivery, which begins now.
  result = s.head
  s.head = result.next
  if s.head == nil:
    s.tail = nil
  result.next = nil
  dec s.queued
  s.queuedBytes -= result.len
  s.begun = result.number

proc runNested(s: ptr SubState, number: uint64) =
  ## [SPEC INTERFACE l.1402-1407, l.1918-1920, l.2153; P3 §10.1] A nested
  ## publication whose delivery joined the queue as `number`: its thread
  ## holds the gate, so it runs the queue from the head, in order, until that
  ## delivery has begun (here, or in a deeper nested publication that ran it)
  ## or the subscription is inactive. What joined after it waits for the
  ## outermost hold (`leaveGate`).
  while true:
    var q: ptr Queued
    withLock s.lock:
      if not s.active or s.begun >= number or s.head == nil:
        return
      q = s.takeHead()
    s.runQueued(q)
    freeQueued(q)

proc leaveGate(s: ptr SubState) =
  ## [SPEC INTERFACE l.1406-1407] The outermost hold runs the queued
  ## deliveries in publication order before the gate opens; deactivation
  ## discards those not begun.
  while true:
    var q: ptr Queued
    withLock s.lock:
      if s.depth > 1 or not s.active or s.head == nil:
        dec s.depth
        if s.depth == 0:
          s.owner = 0
          broadcast(s.cond)
        return
      q = s.takeHead()
    s.runQueued(q)
    freeQueued(q)

proc deliverOrQueue(
    s: ptr SubState,
    scoped: bool,
    origin, attempt: string,
    call: uint64,
    name: string,
    data: openArray[byte],
    outcome: var Outcome,
): Entry =
  ## [SPEC INTERFACE l.1402-1406] Takes the gate, or queues a copy of the
  ## delivery; at the bound the Runtime thread ends the subscription
  ## (`rqQueueBound`, MODULE_ERROR) and the copy goes. [P3 §10.1] A nested
  ## publication behind queued deliveries runs them and its own here, its
  ## own's result in `outcome` (`enNested`).
  result = s.enterGate()
  if result == enBusy:
    let copy = newQueued(scoped, origin, attempt, call, name, data)
    var number: uint64
    result = s.enterGate(copy, addr outcome, addr number)
    if result notin {enQueued, enNested}:
      freeQueued(copy)
    if result == enNested:
      s.runNested(number)
  if result == enBound:
    when defined(lcnTestHooks):
      waitAtQueueBoundHold()
    discard s.engine.call(Request(kind: rqQueueBound, handle: s))

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

proc linkSubscribe*(
    h: ptr HandleState,
    eventName: cstring,
    handler: LogosEventHandler,
    userData: pointer,
    outId: ptr LogosSubscriptionId,
): LogosResult =
  ## [SPEC INTERFACE §2.5 l.1417-1432; RUNTIME l.1018-1024; plan §2.7] A
  ## subscription through a transported handle: LOGOS_OK only after the
  ## provider's successful SubscriptionResult (RUN-0192), with `*outId`
  ## written and the subscription active before this returns [Rev R6, R7].
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
      kind: rqLinkSubscribe,
      origin: moduleOrigin($h.consumer),
      attempt: $h.attempt,
      route: $h.route,
      conn: h.conn,
      bare: name,
      handle: s,
      generation: h.generation,
      outId: outId,
    )
  )
  drop(s) # the Runtime thread holds its own reference while it lasts
  if reply.error.isSome:
    return status(reply.error.get)
  LogosResult()

proc linkUnsubscribe*(h: ptr HandleState, id: LogosSubscriptionId): LogosResult =
  ## [SPEC INTERFACE §2.5 l.1446-1459; plan §2.7] LOGOS_OK once the provider
  ## confirmed it, the subscription is inactive and no handler of it runs on
  ## another thread.
  let reply = h.engine.call(
    Request(
      kind: rqLinkUnsubscribe,
      origin: moduleOrigin($h.consumer),
      attempt: $h.attempt,
      route: $h.route,
      conn: h.conn,
      generation: h.generation,
      subId: id,
    )
  )
  if reply.error.isSome:
    return status(reply.error.get)
  quiesce(reply.subs)
  LogosResult()

proc linkDrain*(e: Engine, p: pointer) =
  ## [G178; plan §2.7] Event worker: one drain of a transported subscription.
  ## Each Event the Runtime thread admits runs its handler here, in order,
  ## behind the subscription's gate; its credit goes back with the next ask,
  ## once the handler returned (TRANSPORT l.721-725), and the handler's return
  ## is reported before the gate opens, so release and destroy, which wait for
  ## it, never overtake it.
  let s = subOf(p)
  var credit = 0
  while true:
    let gated = s.waitGate()
    let r = e.call(Request(kind: rqLinkNext, handle: p, gated: gated, credit: credit))
    credit = 0
    if r.admitted:
      s.run(r.name, r.bytes)
      credit = r.credit
      e.post(Msg(kind: mkRcHandled, target: p))
    if gated:
      s.leaveGate()
    if r.drained or r.error.isSome:
      break
  drop(s)

# Publication -----------------------------------------------------------------------------

proc checkPublication(
    b: ptr SchemaBlob, name: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [SPEC RUNTIME l.1221-1227, l.1233-1235] As `callcheck.checkEvent`, under
  ## the subscriber route's selected contract.
  let sel = selectedOf(b).valueOr:
    return err(failure(ecModule, "the selected contract cannot be loaded"))
  sel.checkEvent(name, data)

proc describe(f: InvocationFailure): string =
  $f.code & (if f.message.isSome: ": " & f.message.get else: "")

proc publishOp*(
    userData: pointer,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
): CErrorCode {.cdecl.} =
  ## [SPEC RUNTIME §7.3, §7.4; INTERFACE §2.8, §5.2] The publish callback every
  ## execution attempt gets. Every admitted handler returns before it does. A
  ## failure for one subscriber route is recorded as a diagnostic and drops
  ## the event for that route only (RUNTIME l.1148-1149).
  ## [SPEC INTERFACE l.3351; DECISIONS I106] The result: LOGOS_OK when the
  ## event is declared by the publishing module's contracts and the data is
  ## one value of its data type within the §5.3 limits (`publishedBy`), and
  ## INVALID_PARAMS otherwise (a null user data, a malformed name, no payload),
  ## decided before the notice path and any fan-out. It reports no delivery.
  bindingEnter()
  let a = cast[ptr AttemptServices](userData)
  if a == nil:
    # [SPEC INTERFACE §5.2 l.3351] a call without the `publish_user_data`
    # this Runtime gave is the caller's error
    return CErrorCode(ord(ecInvalidParams))
  let e = a.engine
  let name = checkEventName(eventName).valueOr:
    e.diagnose("a publication from " & $a.instance & " was refused: " & describe(error))
    return CErrorCode(ord(ecInvalidParams))
  var bytes: seq[byte]
  if cborData != nil:
    bytes = view(cborData, cborDataLen)
  let declared =
    if bytes.len == 0:
      Result[void, InvocationFailure].err(failure(ecInvalidParams, "no payload"))
    else:
      a.publishedBy(name, bytes)
  if name in [GrantChangedName, PolicyChangedName]:
    # [SPEC CA §8; RUNTIME l.1660-1667; I85] Under the Capability Authority
    # policy the authority's notices go to the Runtime thread on the
    # protected path, in order with every admission, and to no subscriber; a
    # malformed or missing one is notification-path loss there, reported
    # whatever this callback answers (I106). Under internal policy they are
    # ordinary publications.
    let consumed = e.call(
      Request(
        kind: rqAuthorityNotice,
        origin: moduleOrigin($a.instance),
        attempt: $a.attempt,
        bare: name,
        payload: bytes,
      )
    )
    if consumed.admitted and declared.isOk:
      return CErrorCode(ord(ecOk))
  if declared.isErr:
    e.diagnose(
      "a publication of " & name & " from " & $a.instance & " was refused: " &
        describe(declared.error)
    )
    return CErrorCode(ord(ecInvalidParams))
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
    var nested: Outcome # an ordinary publication reports no delivery
    if checked.getOrDefault(root, false) and
        s.deliverOrQueue(false, $a.instance, $a.attempt, 0, name, bytes, nested) ==
        enEntered:
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
  # [plan §2.7; E1] Then each transported subscriber connection: one Event,
  # admitted per route by the Runtime thread (G175), committed by the I/O
  # thread. The publication waits for the shared output budget with no finite
  # bound (D3 (a), G261); an Event over the subscriber's frame maximum closes
  # that connection (G165 (a)). [IMPL] Direct subscribers come first.
  var stopped = false
  for t in reply.targets:
    let blob = cast[ptr SchemaBlob](t.blob)
    let root = blob.root
    if root notin checked:
      let c = checkPublication(blob, name, bytes)
      checked[root] = c.isOk
      if c.isErr:
        e.diagnose(
          "a publication of " & name & " from " & $a.instance &
            " was not delivered on route " & t.route & ": " & describe(c.error)
        )
    if not stopped and checked.getOrDefault(root, false):
      let r = e.call(
        Request(
          kind: rqDeliverConn,
          origin: moduleOrigin($a.instance),
          attempt: $a.attempt,
          conn: t.conn,
          route: t.route,
          bare: name,
        )
      )
      if r.admitted:
        let sent = e.tport.submitWait(
          IoCommand(
            conn: t.conn,
            kind: IoCommandKind.cmdPublishConn,
            event: name,
            data: bytes,
            tooLarge: tlClose,
          )
        )
        stopped = sent == SubmitResult.sbStopped
    drop(blob)
  CErrorCode(ord(ecOk))

# A hosted publisher (part 4b-3.2; plan §2.7) ------------------------------------------
#
# The payload stays in the publisher's Module Host, which checks it under each
# subscriber session's selected contract and writes the Events with its own
# loop. Here the Runtime names the sessions and admits each delivery as for a
# direct publisher; nothing it decides reads the payload.

type HostedTarget* = object
  conn*: uint64 ## the Runtime's number for the session
  root*: Digest ## its selected contract

proc hostedCandidates(a: ptr AttemptServices, name: string): Reply =
  let e = a.engine
  if name in [GrantChangedName, PolicyChangedName]:
    # [SPEC CA §8; RUNTIME l.1660-1667] As `publishOp`: under the Capability
    # Authority policy a notice is consumed on the protected path. A hosted
    # module is never the bound authority (`host_config`: the authority is
    # `direct_static`), so its notice is ignored there and needs no payload.
    let consumed = e.call(
      Request(
        kind: rqAuthorityNotice,
        origin: moduleOrigin($a.instance),
        attempt: $a.attempt,
        bare: name,
      )
    )
    if consumed.admitted:
      return Reply()
  result = e.call(
    Request(
      kind: rqCandidates,
      origin: moduleOrigin($a.instance),
      attempt: $a.attempt,
      bare: name,
    )
  )
  for p in result.subs:
    drop(subOf(p)) # [G272] none: a hosted provider's routes are transported
  result.subs.setLen(0)

proc hostedTargets*(a: ptr AttemptServices, name: string): seq[HostedTarget] =
  ## [SPEC RUNTIME §7.3, l.1221-1224] The subscriber sessions an ordinary
  ## publication of `name` by a hosted publisher may reach, with the contract
  ## its payload is checked under for each.
  let reply = hostedCandidates(a, name)
  for t in reply.targets:
    let blob = cast[ptr SchemaBlob](t.blob)
    result.add(HostedTarget(conn: t.conn, root: blob.root))
    drop(blob)

proc hostedDeliver*(
    a: ptr AttemptServices,
    name: string,
    conns: openArray[uint64],
    dropped: openArray[(uint64, ErrorCode)],
): seq[uint64] =
  ## [SPEC RUNTIME l.1225-1231; G175] The rest of a hosted publisher's
  ## ordinary publication, once its host checked the payload: a session whose
  ## contract did not take it is a diagnostic; each other session still a
  ## candidate is admitted afresh, in order. The admitted sessions.
  let e = a.engine
  let reply = hostedCandidates(a, name)
  for t in reply.targets:
    drop(cast[ptr SchemaBlob](t.blob))
    for (conn, code) in dropped:
      if conn == t.conn:
        e.diagnose(
          "a publication of " & name & " from " & $a.instance &
            " was not delivered on route " & t.route & ": " & $code
        )
    if t.conn in conns:
      let r = e.call(
        Request(
          kind: rqDeliverConn,
          origin: moduleOrigin($a.instance),
          attempt: $a.attempt,
          conn: t.conn,
          route: t.route,
          bare: name,
        )
      )
      if r.admitted:
        result.add(t.conn)

proc scopedCheck*(
    inv: ptr InvocationState, name: string
): Result[bool, InvocationFailure] =
  ## [SPEC RUNTIME §7.3.1; INTERFACE l.2193-2196] A served invocation's
  ## scoped publication, before its payload is checked: the scope and an
  ## authority end (NOT_AUTHORISED); whether the destination is open.
  let first = inv.engine.call(
    Request(
      kind: rqScopedConn,
      origin: moduleOrigin($inv.provider),
      route: $inv.route,
      conn: inv.conn,
      bare: name,
      ticket: inv.ticket,
    )
  )
  if first.error.isSome:
    return err(failureOf(first.error.get))
  ok(first.ready)

proc scopedAdmit*(
    inv: ptr InvocationState, name: string
): Result[Opt[uint64], InvocationFailure] =
  ## [G175; E2] Once the payload is checked: the delivery decisions. The tag
  ## its verdict is awaited by; none when the subscriber's own decisions
  ## skipped it.
  let d = inv.engine.call(
    Request(
      kind: rqDeliverConn,
      scoped: true,
      origin: moduleOrigin($inv.provider),
      route: $inv.route,
      conn: inv.conn,
      bare: name,
      ticket: inv.ticket,
      generation: inv.generation,
    )
  )
  if d.error.isSome:
    return err(failureOf(d.error.get))
  if not d.admitted:
    return ok(Opt.none(uint64))
  ok(Opt.some(d.pubTag))

proc scopedVerdict*(
    inv: ptr InvocationState, tag: uint64, abandon: bool
): Result[void, InvocationFailure] =
  ## [E2] The session's verdict on the Event, once the loop took it; `abandon`
  ## when the loop did not.
  let w =
    inv.engine.call(Request(kind: rqPublishVerdict, pubTag: tag, abandon: abandon))
  if w.error.isSome:
    return err(failureOf(w.error.get))
  ok()

proc scopedOverSession(
    inv: ptr InvocationState, sel: Selected, name: string, bytes: seq[byte]
): LogosResult =
  ## [SPEC RUNTIME §7.3.1; INTERFACE l.2187-2199; plan §2.7, E2] A served
  ## invocation's scoped publication goes to its session, checked in a direct
  ## one's order: the scope and an authority end (NOT_AUTHORISED), the
  ## payload (INVALID_PARAMS), a closed destination (NOT_READY), then the
  ## per-delivery decisions; the session commits one Event per subscription
  ## to it on that connection, or reports why it did not, and that verdict is
  ## the result. A Module Host runs the same steps (`host/endpoint.nim`).
  let ready = inv.scopedCheck(name).valueOr:
    return status(error)
  let v = sel.validator.checkEvent(name, bytes)
  if v.isErr:
    return status(toFailure(v.error))
  let c = sel.boundary.commitEvent(name, v.get)
  if c.isErr:
    return status(c.error.failure)
  if not ready:
    return status(ecNotReady, "the invocation's destination is closed")
  let tag = inv.scopedAdmit(name).valueOr:
    return status(error)
  if tag.isNone:
    return LogosResult() # the subscriber's own decisions skipped it
  let sent = inv.engine.tport.submitWait(
    IoCommand(
      conn: inv.conn,
      kind: IoCommandKind.cmdPublishScoped,
      pubRequest: inv.requestId,
      pubTag: tag.get,
      event: name,
      data: bytes,
      tooLarge: tlReport,
    )
  )
  inv.scopedVerdict(tag.get, sent != SubmitResult.sbOk).isOkOr:
    return status(error)
  LogosResult()

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
  ## NOT_READY. Each handler this publication admitted returns before this
  ## does; a denied publish-event decision, a revocation or a closing
  ## destination stops the fan-out after the active handler, and a subscriber
  ## the decisions or its scope exclude is skipped. [G176; P3 F1] A delivery
  ## queued behind another thread's handler is admitted when it begins, and
  ## not delivered if the call's destination closed by then (INTERFACE
  ## l.2153: those this publication ran). [P3 §10.1] One behind deliveries
  ## queued for this thread's own handler runs here, before this returns, so
  ## its call is open when it is admitted.
  let name = checkEventName(eventName).valueOr:
    return status(error)
  if cborData == nil or cborDataLen == 0:
    return status(ecInvalidParams, "an event payload is one CBOR map")
  let sel = selectedOf(inv.blob).valueOr:
    return status(ecModule, "the selected contract cannot be loaded")
  if not sel.boundary.knowsEvent(name):
    return status(ecNotAuthorised, name & " is not an event of the selected contract")
  if inv.conn != 0:
    return scopedOverSession(inv, sel, name, view(cborData, cborDataLen))
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
  let call = (if inv.ticket == nil: 0'u64 else: inv.ticket.id)
  for p in reply.subs:
    let s = subOf(p)
    if failed.isNone:
      var nested: Outcome
      case s.deliverOrQueue(true, $inv.provider, "", call, name, bytes, nested)
      of enEntered:
        let r = e.call(
          Request(
            kind: rqDeliver,
            scoped: true,
            origin: moduleOrigin($inv.provider),
            handle: s,
            bare: name,
            callId: call,
          )
        )
        if r.admitted:
          s.run(name, bytes)
        s.leaveGate()
        if r.error.isSome:
          failed = Opt.some(failureOf(r.error.get))
      of enNested:
        # [P3 §10.1] Run from the queue on this thread, inside this publish:
        # its admission stops the fan-out as above (l.2157, l.2160).
        if not nested.begun:
          skipped = true
        elif nested.error.isSome:
          failed = Opt.some(failureOf(nested.error.get))
      of enInactive:
        skipped = true
      of enBusy, enQueued, enBound:
        discard
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
    for p in again.subs:
      drop(subOf(p))
    if again.error.isSome:
      failed = Opt.some(failureOf(again.error.get))
    elif not again.ready:
      failed = Opt.some(failure(ecNotReady, "the invocation's destination is closed"))
  if failed.isSome:
    return status(failed.get)
  LogosResult()
