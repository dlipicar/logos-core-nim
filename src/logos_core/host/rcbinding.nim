## The Module Host's Runtime Control binding, publish callback and invocation
## access (Tier 4b step 4b-3; DECISIONS G267, G271; plan §2.6) [IMPL]: what
## the host passes in `_MODULE_init`'s input. Every operation that depends on
## the Runtime is one lane-1 round trip; the Runtime runs it through the
## attempt's own direct binding (`runtime/hostsup.nim`), so values, errors,
## authority and transitions are the direct ones (RUNTIME RUN-0180).
##
## What cannot cross the carrier, null pointers and malformed structs, is
## checked here with the direct binding's own checks and messages before
## anything is sent, so a module sees the same statuses in either placement.
##
## - **Subscriptions** (G178, G225). The handler runs on a host event worker
##   (at most four), one delivery at a time per subscription as the Runtime
##   forwards them, and `rc_delivered` reports its return. The subscription id
##   is written before any handler of it runs (INTERFACE l.1427-1429): a
##   delivery that overtakes the subscribe reply waits for it. An unsubscribe
##   from a handler names the delivery in progress, which the Runtime runs it
##   beside, so it does not wait for its own frame.
## - **Prepared calls** (INTERFACE §2.9.1). Submit and cancel are sent in
##   order; the completion runs on a host completion worker with a response
##   owner of its own; release waits for a completion already received,
##   except from inside it (l.2085).
## - **Publications** (RUNTIME §7.3; plan §2.7, part 4b-3.2). The payload
##   stays here: the Runtime names the subscriber sessions (`rc_publish`),
##   the payload is checked under each one's selected contract, the Runtime
##   admits each delivery (`rc_deliver`) and this host's loop writes the
##   Events (`endpoint.publishConn`).

{.push raises: [], gcsafe.}

import std/[atomics, locks, tables]
import results
import ../abi/[checks, cstatus, types]
import ../base/perthread
import ../hash/hashinput
import ../runtime/[entryframe, hostio]
import ../transport/io/api except decodeMessage
import ./[consumer, endpoint, selected, state]

# Statuses ------------------------------------------------------------------------------

func codeOf(c: uint8): ErrorCode =
  if c > 0 and c <= uint8(high(ErrorCode)):
    ErrorCode(c)
  else:
    ecModule

proc statusOf(a: Answer): LogosResult =
  if a.failed:
    status(failureOf(a))
  else:
    LogosResult()

func bytesOf(p: ptr UncheckedArray[uint8], n: csize_t): seq[byte] =
  if p == nil:
    return @[]
  result = newSeq[byte](int(n))
  for i in 0 ..< int(n):
    result[i] = p[i]

func bytesOf(s: cstring): seq[byte] =
  let t = $s
  result = newSeq[byte](t.len)
  for i, c in t:
    result[i] = byte(c)

# Worker pools ----------------------------------------------------------------------------

const
  MaxEventWorkers = 4 ## [G178] handlers of one subscriber at once
  MaxCompletionWorkers = 64 ## [IMPL] as the Runtime's call workers

type Pool = object
  ch: Channel[seq[byte]]
  lock: Lock
  done: Cond ## signalled when `pending` reaches 0
  idle, count, max: int
  pending: int ## frames posted whose callback has not returned
  threads: array[MaxCompletionWorkers, Thread[ptr Pool]]
  run: proc(f: seq[byte]) {.nimcall, gcsafe, raises: [].}

var events, completions: ptr Pool

proc poolLoop(p: ptr Pool) =
  markHostThread()
  while true:
    var f: seq[byte]
    try:
      f = p.ch.recv()
    except Exception:
      return
    if f.len == 0:
      return
    withLock p.lock:
      dec p.idle
    p.run(f)
    withLock p.lock:
      inc p.idle
      dec p.pending
      if p.pending == 0:
        broadcast(p.done)

proc poolMain(p: ptr Pool) {.thread.} =
  poolLoop(p)
  releasePerThread()

proc newPool(
    max: int, run: proc(f: seq[byte]) {.nimcall, gcsafe, raises: [].}
): ptr Pool =
  result = createShared(Pool)
  result.ch.open()
  initLock(result.lock)
  initCond(result.done)
  result.max = max
  result.run = run

proc post(p: ptr Pool, f: seq[byte]) =
  ## Main thread: one callback frame; the pool grows while every worker is busy.
  var grow = false
  withLock p.lock:
    inc p.pending
    if p.idle == 0 and p.count < p.max:
      grow = true
      inc p.count
      inc p.idle
  if grow:
    try:
      createThread(p.threads[p.count - 1], poolMain, p)
    except Exception:
      carrierLost("a callback worker cannot start")
  try:
    p.ch.send(f)
  except Exception:
    carrierLost("a callback queue failed")

proc awaitIdle(p: ptr Pool) =
  withLock p.lock:
    while p.pending > 0:
      wait(p.done, p.lock)

proc stopPool(p: ptr Pool) =
  var n: int
  withLock p.lock:
    n = p.count
  for _ in 0 ..< n:
    try:
      p.ch.send(@[])
    except Exception:
      discard
  for i in 0 ..< n:
    try:
      joinThread(p.threads[i])
    except Exception:
      discard

# Subscriptions ---------------------------------------------------------------------------

type LocalSub = object
  local: uint64
  handler: LogosEventHandler
  userData: pointer
  outId: ptr LogosSubscriptionId
  ready: bool ## `*outId` is written
  failed: bool ## the subscribe failed: no delivery can come
  id: uint64
  next: ptr LocalSub

var
  subLock: Lock
  subCond: Cond
  subs: ptr LocalSub
  nextLocal: Atomic[uint64]
  currentDelivery {.threadvar.}: uint64

proc findLocal(local: uint64): ptr LocalSub =
  ## Under `subLock`.
  var p = subs
  while p != nil:
    if p.local == local:
      return p
    p = p.next
  nil

proc unlink(s: ptr LocalSub) =
  ## Under `subLock`.
  var p = addr subs
  while p[] != nil:
    if p[] == s:
      p[] = s.next
      return
    p = addr p[].next

proc runDelivery(f: seq[byte]) =
  ## An event worker: one entry, then `rc_delivered`.
  let m = decodeMessage(f).valueOr:
    carrierLost("a delivery does not decode")
  let d = m.arm_lcn_Carrier_rc_delivery
  var s: ptr LocalSub
  withLock subLock:
    s = findLocal(d.local)
    while s != nil and not s.ready and not s.failed:
      wait(subCond, subLock)
  if s != nil and s.ready:
    currentDelivery = d.local
    s.handler(
      cstring(d.name),
      (
        if d.data.len == 0: nil
        else: cast[ptr UncheckedArray[uint8]](unsafeAddr d.data[0])
      ),
      csize_t(d.data.len),
      s.userData,
    )
    currentDelivery = 0
  send(toMessage(LcnCarrierRcDelivered(local: d.local, seq: d.seq)))

# Prepared calls --------------------------------------------------------------------------

type
  CallPhase = enum
    hcOpen
    hcCompleting
    hcDone

  HostCall = object
    local: uint64
    complete: LogosAsyncCompleteFn
    userData: pointer
    phase: CallPhase
    received: bool ## its completion came
    completer: int
    next: ptr HostCall

  Owned = object ## A completion's response and diagnostics, released by its owner.
    response: ptr UncheckedArray[uint8]
    message: cstring
    detail: ptr UncheckedArray[uint8]

var
  callLock: Lock
  callCond: Cond
  calls: ptr HostCall
  nextCall: Atomic[uint64]

proc findCall(local: uint64): ptr HostCall =
  ## Under `callLock`.
  var p = calls
  while p != nil:
    if p.local == local:
      return p
    p = p.next
  nil

proc copyOut(b: openArray[byte]): ptr UncheckedArray[uint8] =
  result = cast[ptr UncheckedArray[uint8]](cMalloc(csize_t(max(b.len, 1))))
  for i, x in b:
    result[i] = x

proc ownedRelease(state: pointer) {.cdecl.} =
  let o = cast[ptr Owned](state)
  if o == nil:
    return
  cFree(o.response)
  cFree(o.message)
  cFree(o.detail)
  cFree(o)

proc runCompletion(f: seq[byte]) =
  ## A completion worker: the call's one completion callback.
  let m = decodeMessage(f).valueOr:
    carrierLost("a completion does not decode")
  let d = m.arm_lcn_Carrier_async_done
  var c: ptr HostCall
  withLock callLock:
    c = findCall(d.call)
    if c != nil:
      c.phase = hcCompleting
      c.completer = getThreadId()
  if c == nil:
    return
  let o = cast[ptr Owned](cMalloc(csize_t(sizeof(Owned))))
  o[] = Owned()
  var res = LogosResult()
  var response: ptr UncheckedArray[uint8] = nil
  var len: csize_t = 0
  if d.failure.isNone:
    let v = d.value.get(@[])
    o.response = copyOut(v)
    response = o.response
    len = csize_t(v.len)
  else:
    let fl = d.failure.get
    res.code = CErrorCode(ord(codeOf(fl.code)))
    if fl.message.isSome:
      let t = clip(fl.message.get)
      o.message = cast[cstring](cMalloc(csize_t(t.len + 1)))
      for i, ch in t:
        o.message[i] = ch
      o.message[t.len] = '\0'
      res.message = o.message
    if fl.detail.isSome and codeOf(fl.code) == ecInvalidParams:
      o.detail = copyOut(fl.detail.get)
      res.detail = o.detail
      res.detailLen = csize_t(fl.detail.get.len)
  c.complete(
    c.userData, res, response, len, LogosResponseOwner(state: o, release: ownedRelease)
  )
  withLock callLock:
    c.phase = hcDone
    c.completer = 0
    broadcast(callCond)

proc callOf(call: ptr LogosAsyncCall): ptr HostCall =
  if call == nil:
    nil
  else:
    cast[ptr HostCall](call.state)

proc submitOp(call: ptr LogosAsyncCall) {.cdecl.} =
  bindingEnter()
  let c = callOf(call)
  if c != nil:
    send(toMessage(LcnCarrierRcAsyncSubmit(call: c.local)))

proc cancelOp(call: ptr LogosAsyncCall) {.cdecl.} =
  bindingEnter()
  let c = callOf(call)
  if c != nil:
    send(toMessage(LcnCarrierRcAsyncCancel(call: c.local)))

proc releaseOp(call: ptr LogosAsyncCall) {.cdecl.} =
  ## [SPEC INTERFACE l.2079-2087] The Runtime cancels or discards the call and
  ## waits for its completion; a completion already received here is waited
  ## for too, except from inside it.
  bindingEnter()
  let c = callOf(call)
  if c == nil:
    return
  let id = nextId()
  discard request(toMessage(LcnCarrierRcAsyncRelease(id: id, call: c.local)), id)
  let me = getThreadId()
  withLock callLock:
    while c.phase == hcCompleting and c.completer != me:
      wait(callCond, callLock)
    var p = addr calls
    while p[] != nil:
      if p[] == c:
        p[] = c.next
        break
      p = addr p[].next
  freeShared(c)

var asyncVtable = LogosAsyncCallVtable(
  abiVersion: AsyncCallAbiVersion,
  structSize: csize_t(sizeof(LogosAsyncCallVtable)),
  submit: submitOp,
  cancel: cancelOp,
  release: releaseOp,
)

# The Runtime Control vtable --------------------------------------------------------------

proc rcCallOp(
    binding: ptr LogosRuntimeControlBinding,
    `method`: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outBuf: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §5.2; RUNTIME §9] As `bindings.rcCallOp`.
  bindingEnter()
  if outBuf == nil or outLen == nil:
    return status(ecInvalidParams, "null response outputs")
  outBuf[] = nil
  outLen[] = 0
  if `method` == nil or (params == nil and paramsLen != 0):
    return status(ecInvalidParams, "null method or request")
  let id = nextId()
  let a = request(
    toMessage(
      LcnCarrierRcCall(
        id: id,
        `method`: bytesOf(`method`),
        params: bytesOf(params, paramsLen),
        runtime_thread: onHostThread(),
      )
    ),
    id,
  )
  if a.failed:
    return statusOf(a)
  # [RUN-0174; plan §2.8] A route's invocation material stays in the host.
  retainFrom($`method`, a.value)
  give(a.value, outBuf, outLen)

proc rcReleaseResponseOp(
    binding: ptr LogosRuntimeControlBinding,
    response: ptr UncheckedArray[uint8],
    responseLen: csize_t,
) {.cdecl.} =
  cFree(response)

proc rcSubscribeOp(
    binding: ptr LogosRuntimeControlBinding,
    eventName: cstring,
    handler: LogosEventHandler,
    userData: pointer,
    outId: ptr LogosSubscriptionId,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE l.3837; G178] As `rcevents.rcSubscribe`.
  bindingEnter()
  if eventName == nil or handler.isNil or outId == nil:
    return status(ecInvalidParams, "a null event name, handler or subscription output")
  let s = createShared(LocalSub)
  s.local = nextLocal.fetchAdd(1) + 1
  s.handler = handler
  s.userData = userData
  s.outId = outId
  withLock subLock:
    s.next = subs
    subs = s
  let id = nextId()
  let a = request(
    toMessage(LcnCarrierRcSubscribe(id: id, event: bytesOf(eventName), local: s.local)),
    id,
  )
  withLock subLock:
    if a.failed:
      s.failed = true
      unlink(s)
    else:
      s.id = a.sub
      outId[] = LogosSubscriptionId(a.sub)
      s.ready = true
    broadcast(subCond)
  if a.failed:
    # [IMPL] A delivery cannot be waiting: none comes for a failed subscribe.
    freeShared(s)
    return statusOf(a)
  LogosResult()

proc rcUnsubscribeOp(
    binding: ptr LogosRuntimeControlBinding, id: LogosSubscriptionId
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE l.3837; G178] As `rcevents.rcUnsubscribe`.
  bindingEnter()
  let rid = nextId()
  var u = LcnCarrierRcUnsubscribe(id: rid, sub: uint64(id))
  if currentDelivery != 0:
    u.in_handler = Opt.some(currentDelivery)
  let a = request(toMessage(u), rid)
  if a.failed:
    return statusOf(a)
  # No handler of it runs or begins now; its record goes (a handler of it on
  # this thread keeps its own copy of what it needs).
  var gone: ptr LocalSub
  withLock subLock:
    var p = subs
    while p != nil:
      if p.ready and p.id == uint64(id):
        gone = p
        unlink(p)
        break
      p = p.next
  if gone != nil and gone.local != currentDelivery:
    freeShared(gone)
  LogosResult()

proc rcMaterializeOp(
    binding: ptr LogosRuntimeControlBinding,
    routeId: cstring,
    expectedRoot: ptr ContractRoot,
    schema: ptr UncheckedArray[uint8],
    schemaLen: csize_t,
    outRoute: ptr LogosRouteHandle,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §5.2 l.3880-3911] A hosted consumer's handle
  ## (`consumer.nim`, part 4b-3.3).
  bindingEnter()
  consumer.materialize(routeId, expectedRoot, schema, schemaLen, outRoute)

proc rcConnectRemoteOp(
    binding: ptr LogosRuntimeControlBinding,
    endpoint: ptr UncheckedArray[uint8],
    endpointLen: csize_t,
    expectedRoot: ptr ContractRoot,
    outBinding: ptr LogosRuntimeControlBinding,
): LogosResult {.cdecl.} =
  ## As `bindings.rcConnectRemoteOp`: the input checks here, the rest by the
  ## Runtime.
  bindingEnter()
  if outBinding != nil:
    outBinding.vtable = nil
    outBinding.state = nil
  checkConnectRemoteInput(endpoint, endpointLen, expectedRoot).isOkOr:
    return status(error)
  var root = newSeq[byte](32)
  for i in 0 ..< 32:
    root[i] = expectedRoot[][i]
  let id = nextId()
  let a = request(
    toMessage(
      LcnCarrierRcConnectRemote(
        id: id, endpoint: bytesOf(endpoint, endpointLen), expected_root: root
      )
    ),
    id,
  )
  statusOf(a)

proc rcReleaseOp(binding: ptr LogosRuntimeControlBinding) {.cdecl.} =
  ## [SPEC INTERFACE §5.2 l.3864] Borrowed; a release is ignored, as direct.
  discard

proc rcPrepareCallOp(
    binding: ptr LogosRuntimeControlBinding,
    `method`: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    options: ptr LogosAsyncOptions,
    callbacks: ptr LogosAsyncCallbacks,
    outCall: ptr LogosAsyncCall,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.9.1; RUNTIME §7.5] The checks `asynccall.prepare`
  ## makes first, then the Runtime prepares the call.
  bindingEnter()
  if outCall == nil:
    return status(ecInvalidParams, "a null call output")
  if `method` == nil:
    return status(ecInvalidParams, "a null method")
  if params == nil and paramsLen != 0:
    return status(ecInvalidParams, "a null request")
  checkAsyncOptions(options).isOkOr:
    return status(error)
  checkAsyncCallbacks(callbacks).isOkOr:
    return status(error)
  let c = createShared(HostCall)
  c.local = nextCall.fetchAdd(1) + 1
  c.complete = callbacks.complete
  c.userData = callbacks.userData
  withLock callLock:
    c.next = calls
    calls = c
  let id = nextId()
  var p = LcnCarrierRcPrepare(
    id: id,
    call: c.local,
    `method`: bytesOf(`method`),
    params: bytesOf(params, paramsLen),
  )
  if options.hasTimeout:
    p.timeout_ms = Opt.some(options.timeoutMs)
  let a = request(toMessage(p), id)
  if a.failed:
    withLock callLock:
      var q = addr calls
      while q[] != nil:
        if q[] == c:
          q[] = c.next
          break
        q = addr q[].next
    freeShared(c)
    return statusOf(a)
  outCall.vtable = addr asyncVtable
  outCall.state = c
  LogosResult()

var rcVtable = LogosRuntimeControlVtable(
  abiVersion: RuntimeControlVtableAbiVersion,
  structSize: csize_t(sizeof(LogosRuntimeControlVtable)),
  call: rcCallOp,
  releaseResponse: rcReleaseResponseOp,
  subscribe: rcSubscribeOp,
  unsubscribe: rcUnsubscribeOp,
  materializeRoute: rcMaterializeOp,
  connectRemote: rcConnectRemoteOp,
  release: rcReleaseOp,
  prepareCall: rcPrepareCallOp,
)

# Publish and invocation access -------------------------------------------------------------

proc publishOp(
    userData: pointer,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
) {.cdecl.} =
  ## [SPEC RUNTIME §7.3, l.1221-1231] An ordinary publication: delivered to
  ## each subscriber session whose selected contract takes the payload and
  ## whose delivery the Runtime admits; one that cannot be delivered is the
  ## Runtime's diagnostic. Returns once every admitted Event is taken by the
  ## loop (no result).
  bindingEnter()
  let id = nextId()
  let a = request(
    toMessage(
      LcnCarrierRcPublish(
        id: id, event: (if eventName == nil: @[] else: bytesOf(eventName))
      )
    ),
    id,
  )
  if a.failed or a.targets.len == 0:
    return
  let name = $eventName # the Runtime checked it
  let data = bytesOf(cborData, cborDataLen)
  var checked: Table[Digest, ErrorCode]
  var conns: seq[uint64]
  var dropped: seq[LcnCarrierDropped]
  for (conn, contract) in a.targets:
    let root = digestOf(contract).valueOr:
      carrierLost("a publication target whose contract is not a digest")
    if root notin checked:
      checked[root] =
        if data.len == 0:
          ecInvalidParams
        else:
          let sel = selectedFor(root)
          if sel.isErr:
            ecModule
          else:
            let c = sel.get.checkEvent(name, data)
            if c.isErr: c.error.code else: ecOk
    let code = checked.getOrDefault(root, ecModule)
    if code == ecOk:
      conns.add(conn)
    else:
      dropped.add(LcnCarrierDropped(conn: conn, code: uint8(ord(code))))
  let id2 = nextId()
  let b = request(
    toMessage(LcnCarrierRcDeliver(id: id2, event: name, conns: conns, dropped: dropped)),
    id2,
  )
  if b.failed:
    return
  for conn in b.admitted:
    if publishConn(conn, name, data) == sbStopped:
      return

var
  bindingState: int ## [SPEC INTERFACE §5.2] non-null; the host has one instance
  binding = LogosRuntimeControlBinding(vtable: addr rcVtable, state: addr bindingState)
  accessState: int

proc hostServices*(): (
  ptr LogosRuntimeControlBinding, LogosPublishFn, pointer, LogosInvocationAccess
) =
  ## The instance's Runtime Control binding, publish callback (with its user
  ## data) and invocation access.
  (
    addr binding,
    publishOp,
    nil,
    # [SPEC INTERFACE §2.9.3] The context of the provider entry running on
    # the calling thread (`endpoint.nim` makes it current), as direct.
    LogosInvocationAccess(state: addr accessState, current: entryframe.currentOp),
  )

# Startup and frames from the main thread -------------------------------------------------

proc initBinding*() =
  initLock(subLock)
  initCond(subCond)
  initLock(callLock)
  initCond(callCond)
  events = newPool(MaxEventWorkers, runDelivery)
  completions = newPool(MaxCompletionWorkers, runCompletion)

proc delivered*(f: seq[byte]) =
  ## Main thread: an `rc_event`.
  events.post(f)

proc completed*(f: seq[byte]) =
  ## Main thread: an `async_done`.
  completions.post(f)

proc awaitCallbacks*() =
  ## Lifecycle thread, at the release, before `_MODULE_destroy` (DECISIONS
  ## G267; INTERFACE l.1465, l.1503, l.1999): every event handler and
  ## completion the Runtime handed over has returned, as the Runtime waits
  ## for a direct module's (`engine.releaseRealization`). The main thread keeps
  ## serving their Runtime Control calls meanwhile; a callback that never
  ## returns leaves the release to the stop deadline, which ends the host.
  events.awaitIdle()
  completions.awaitIdle()
  awaitConsumer()

proc stopBinding*() =
  ## At a graceful exit: the workers are joined.
  events.stopPool()
  completions.stopPool()
