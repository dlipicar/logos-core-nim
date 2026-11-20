## A hosted provider's endpoint, in the Module Host (Tier 4b step 4b-3, part
## 4b-3.2; plan §2.7 [Rev R14, R16, R19]; DECISIONS G267, G273, G274) [IMPL].
##
## Payloads go between the consumer's process and this one directly; the
## Runtime stays on the control path (the owner's direct layout, 2026-11-14).
##
## - **The loop.** The host serves the listener the Runtime made and handed
##   over as fd 4 (RUN-0200, TRN-0184) with the transport loop the Runtime
##   runs for a direct provider, from the module's own primary contract. It
##   binds nothing (LDR-0146). `initialized` is sent only once the loop
##   listens; a listener that cannot be served ends the initialization
##   (TRN-0186). The loop frames each Request and resolves it under the
##   session's contract and access (METHOD_NOT_FOUND, NOT_AUTHORISED).
## - **The Runtime decides.** The loop's session events go to the Runtime on
##   lane 2 without any payload: it judges each Hello, admits each call
##   (`admit_verdict`), subscription and delivery, and keeps the sessions.
##   Its orders and verdicts reach the loop in the order given, through one
##   ordering thread that waits while the loop's output budget is full.
## - **Calls.** A Request's params stay here (`HostInv`). A refused one is
##   answered here, its params checked first when the refusal is NOT_READY
##   (RUNTIME l.1828, l.1832). An admitted one runs on a dispatch worker: its params are checked
##   under the session's selected contract (`selected.nim`, with the
##   Runtime's own `callcheck`), the provider runs with an invocation context
##   made from the verdict (its caller is the consumer the Runtime names), its
##   status is checked as on the direct path (INTERFACE l.3306-3311) and its response against
##   the schema, and the loop commits the Response. `logos.schema` is answered
##   by the loop from the selected contract once its request checks.
## - **Commit (K38 interim, G273).** Each Request has one Response: the
##   first of the host's own and the Runtime's (`io_respond`) to reach the
##   loop; a Cancel the loop committed, a closed session, or an order that
##   terminates the session (`io_terminate`, P5 Q3 (a)) ends it too, and a
##   CANCELLED the Runtime's cancel caused is not committed (P5 d4).
##   `call_ended` reports whether the host's success was committed, with the
##   request and response commitments only where the admission asks to retain
##   them (G274; IFC-0581). A deferred call (INTERFACE §2.9.2) reports once
##   its execution is released. The Runtime then releases the Request's slot,
##   as for an endpoint it serves.
## - **Scoped events.** `publish` on the invocation context asks the Runtime
##   about the destination (`scoped_check`), checks the payload here, asks for
##   the delivery (`scoped_admit`), has the loop write the Event and waits for
##   the verdict (`scoped_done`), so the Event is committed before the
##   Response, which waits for every publication still pending (R19).
## - **Release [R13].** No new connection is accepted, every admitted call
##   ends, the loop stops (closing its sessions), and only then is the
##   context destroyed.

{.push raises: [], gcsafe.}

import std/[atomics, locks, os]
import results
import logos_sdk/cbor
import logos_sdk/abi/[checks, cstatus, types]
import logos_sdk/base/[perthread, wipe]
import logos_sdk/hash/hashinput
import logos_sdk/iface/[accept, outcome, surface]
import ../transport/io/api except decodeMessage
import ../transport/io/[loop, sock]
import ../runtime/[carrier, entryframe, hostio, native, servedroots]
import ./[selected, state]

const
  MaxDispatchWorkers = 64 ## [IMPL] as the Runtime's call workers
  BusyStepMs = 1 ## [IMPL] between offers of a command the loop has no room for

type
  ServeState = enum
    ssNone
    ssWaiting
    ssListening
    ssFailed

  HostInv = object
    ## One dispatched Request, from the loop's report until it ends: its
    ## params and, once admitted, its invocation context and, for a deferred
    ## provider, its invocation, kept until execution is released.
    inv: LogosProviderInvocation ## first: the provider's pointer is this object's
    context: LogosInvocationContext
    conn, request: uint64 ## the loop's numbers
    introspection: bool
    methodName: cstring
    params: ptr UncheckedArray[uint8]
    paramsLen: int
    # Under `sv.lock`:
    admitted: bool
    answered: bool ## a Response is committed, or none can be any more
    committedOk: bool ## the host's own success was committed
    # Set before the call runs:
    call: uint64 ## the Runtime's number
    root: Digest ## the session's selected contract
    retainRequest, retainResponse: bool
    consumer: FixedText
    requestRoot, responseRoot: Opt[PayloadCommitment]
    cancelled: Atomic[bool]
    deferred: bool
    lock: Lock
    entries: int
      ## deferred: `submit`, a completion, a context operation or `request_cancel`
    publishing: int ## scoped publications not yet answered
    completed, released, submitReturned, cancelKnown, cancelNotified: bool
    next: ptr HostInv

  Job = object
    inv: int ## a `ptr HostInv`; 0 ends the worker
    hook: bool ## run its `request_cancel`

  Pool = object
    ch: Channel[Job]
    lock: Lock
    idle, count: int
    threads: array[MaxDispatchWorkers, Thread[ptr Pool]]

  Served = object
    loop: Loop
    lock: Lock
    cond: Cond
    serve: ServeState
    serveError: array[512, char]
    serveErrorLen: int
    stopped: bool ## `evStopped` came
    runtimeId: FixedText
    module: ptr LogosModuleContext
    dispatch: ModuleDispatchFn
    free: ModuleFreeFn
    asyncApi: ptr LogosAsyncProviderApi
    access: pointer ## the instance's invocation-access state
    calls: ptr HostInv ## under `lock`
    running: int ## admitted calls not yet ended, under `lock`
    orders: Channel[seq[byte]] ## lane-2 orders for the ordering thread
    submitter: Thread[void]
    pool: Pool

var sv: ptr Served

# Requests ------------------------------------------------------------------------------

proc copyOut(b: openArray[byte]): ptr UncheckedArray[uint8] =
  if b.len == 0:
    return nil
  result = cast[ptr UncheckedArray[uint8]](allocShared(b.len))
  copyMem(result, unsafeAddr b[0], b.len)

proc shared(s: string): cstring =
  result = cast[cstring](allocShared0(s.len + 1))
  if s.len > 0:
    copyMem(result, unsafeAddr s[0], s.len)

proc paramsOf(d: ptr HostInv): seq[byte] =
  ## A copy of the params, which the caller wipes [DECISIONS G276].
  if d.params == nil:
    return
  result = newSeq[byte](d.paramsLen)
  copyMem(addr result[0], d.params, d.paramsLen)

proc findLocked(conn, request: uint64): ptr HostInv =
  var p = sv.calls
  while p != nil:
    if p.conn == conn and p.request == request:
      return p
    p = p.next
  nil

proc unlinkLocked(d: ptr HostInv) =
  var p = addr sv.calls
  while p[] != nil:
    if p[] == d:
      p[] = d.next
      return
    p = addr p[].next

proc freeInv(d: ptr HostInv) =
  if d.methodName != nil:
    deallocShared(d.methodName)
  freeWiped(d.params, d.paramsLen) # [DECISIONS G276]
  deinitLock(d.lock)
  # [DECISIONS G276] Its commitments: a marked side's value root is the
  # payload's own (TRANSPORT §4.1); plain digests, zeroed in place.
  secureZero(addr d.requestRoot, sizeof(d.requestRoot))
  secureZero(addr d.responseRoot, sizeof(d.responseRoot))
  freeShared(d)

proc newInv(ev: IoEvent) =
  ## I/O thread: a Request the loop dispatched, kept until it ends.
  let d = createShared(HostInv)
  initLock(d.lock)
  d.conn = ev.conn
  d.request = ev.requestId
  d.introspection = ev.introspection
  d.methodName = shared(ev.methodName)
  d.params = copyOut(ev.params)
  d.paramsLen = ev.params.len
  d.deferred = sv.asyncApi != nil
  withLock sv.lock:
    d.next = sv.calls
    sv.calls = d

proc endedBySession(conn: uint64, request: Opt[uint64]) =
  ## I/O thread: the loop committed CANCELLED to `request` (a Cancel), or the
  ## session closed (none): nothing more is committed for them. Those never
  ## admitted are dropped; the Runtime's verdict on one finds nothing.
  var gone: seq[ptr HostInv]
  withLock sv.lock:
    var p = sv.calls
    while p != nil:
      let next = p.next
      if p.conn == conn and (request.isNone or p.request == request.get):
        p.answered = true
        if not p.admitted:
          unlinkLocked(p)
          gone.add(p)
      p = next
  for d in gone:
    freeInv(d)

# Committing ----------------------------------------------------------------------------

proc commit(d: ptr HostInv, cmd: var IoCommand, success: bool) =
  ## [K38 interim] The Request's Response, unless one is committed already.
  ## A full output budget is waited for, holding nothing.
  while true:
    var busy = false
    withLock sv.lock:
      if d.answered:
        return
      let r = sv.loop.trySubmit(cmd)
      if r == sbBusy:
        busy = true
      else:
        d.answered = true
        d.committedOk = success and r == sbOk
    if not busy:
      return
    sleep(BusyStepMs)

proc respond(
    d: ptr HostInv, r: var Result[seq[byte], InvocationFailure], workEnded: bool
) =
  ## [DECISIONS G276] The outcome moves into the command; what the loop did not
  ## take, and `r`, are wiped.
  let ok = r.isOk
  if not ok and r.error.code == ecCancelled and d.cancelled.load:
    # [SPEC RUNTIME l.1271; INTERFACE l.2024; P5 d4] The Runtime's cancel of a
    # call whose Request is still open is its route's or consumer's end (the
    # loop commits a consumer's Cancel itself): a CANCELLED that end caused
    # is not the caller's, so nothing is committed and the session's end
    # fails the Request TRANSPORT_ERROR at its consumer.
    withLock sv.lock:
      d.answered = true
    wipe(r)
    return
  var cmd = IoCommand(
    conn: d.conn,
    kind: IoCommandKind.cmdRespond,
    requestId: d.request,
    outcome:
      if ok:
        CallOutcome(ok: true, result: move r.get)
      else:
        CallOutcome(ok: false, failure: r.error),
    workEnded: workEnded,
  )
  d.commit(cmd, ok)
  wipe(cmd)
  wipe(r)

proc fail(d: ptr HostInv, f: InvocationFailure) =
  var r = Result[seq[byte], InvocationFailure].err(f)
  d.respond(r, workEnded = true)

proc ended(d: ptr HostInv) =
  ## An admitted call's last step: the Runtime learns what was committed and
  ## the release stops waiting for it.
  var m = LcnCarrierCallEnded(call: d.call)
  withLock sv.lock:
    m.succeeded = d.committedOk
    unlinkLocked(d)
  if d.retainRequest and d.requestRoot.isSome:
    m.request = Opt.some(toCarrier(d.requestRoot.get))
  if d.retainResponse and d.responseRoot.isSome:
    m.response = Opt.some(toCarrier(d.responseRoot.get))
  send(toMessage(m))
  freeInv(d)
  withLock sv.lock:
    dec sv.running
    broadcast(sv.cond)

# The invocation context -------------------------------------------------------------------

proc enter(d: ptr HostInv): bool =
  ## [SPEC INTERFACE l.2137-2141, l.2177] A context operation of a deferred
  ## invocation is admitted until execution is released.
  if not d.deferred:
    return true
  withLock d.lock:
    if d.released:
      return false
    inc d.entries
  true

proc leave(d: ptr HostInv)

proc callerOp(
    invocation: ptr LogosInvocationContext, outCaller: ptr LogosCallerView
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.9.3; RUNTIME l.869-873] The route's consumer, as the
  ## Runtime named it in its verdict.
  bindingEnter()
  if invocation == nil or outCaller == nil:
    return status(ecInvalidParams, "null caller output")
  let d = cast[ptr HostInv](invocation.state)
  if not d.enter():
    return status(ecModule, "the invocation was released")
  outCaller[] = LogosCallerView(
    kind: CallerModule,
    runtimeInstanceId: sv.runtimeId.utf8View,
    moduleInstanceId: d.consumer.utf8View,
  )
  if d.deferred:
    d.leave()
  LogosResult()

proc isCancelledOp(invocation: ptr LogosInvocationContext): bool {.cdecl.} =
  ## [SPEC INTERFACE l.2101-2102] Sticky, from `call_cancel`.
  bindingEnter()
  if invocation == nil:
    return false
  let d = cast[ptr HostInv](invocation.state)
  if not d.enter():
    return true
  result = d.cancelled.load
  if d.deferred:
    d.leave()

proc submitWaiting(cmd: var IoCommand): SubmitResult =
  ## [SPEC TRANSPORT §5.2 l.806-807; D3 (a)] Waits while the output budget is
  ## full, with no finite bound; ends once the loop is stopping.
  while true:
    result = sv.loop.trySubmit(cmd)
    if result != sbBusy:
      return
    sleep(BusyStepMs)

proc scopedPublish(
    d: ptr HostInv, eventName: cstring, data: openArray[byte]
): LogosResult =
  ## [SPEC INTERFACE l.2187-2199; RUNTIME §7.3.1] In a direct invocation's
  ## order (`events.scopedOverSession`): a malformed name or payload is
  ## INVALID_PARAMS; an event outside the selected contract, the route's
  ## scope or a revoked route NOT_AUTHORISED; a payload that is not a value of
  ## the event's type INVALID_PARAMS; a closed destination NOT_READY; then the
  ## session's verdict on the Event.
  let name = checkEventName(eventName).valueOr:
    return status(error)
  if data.len == 0:
    return status(ecInvalidParams, "an event payload is one CBOR map")
  let sel = selectedFor(d.root).valueOr:
    return status(ecModule, "the selected contract cannot be loaded")
  if not sel.boundary.knowsEvent(name):
    return status(ecNotAuthorised, name & " is not an event of the selected contract")
  var event = newSeq[byte](name.len)
  for i, c in name:
    event[i] = byte(c)
  let id = nextId()
  let first =
    request(toMessage(LcnCarrierScopedCheck(id: id, call: d.call, event: event)), id)
  if first.failed:
    return status(failureOf(first))
  let checked = sel.checkEvent(name, data)
  if checked.isErr:
    return status(checked.error)
  if not first.ready:
    return status(ecNotReady, "the invocation's destination is closed")
  let id2 = nextId()
  let admitted =
    request(toMessage(LcnCarrierScopedAdmit(id: id2, call: d.call, event: name)), id2)
  if admitted.failed:
    return status(failureOf(admitted))
  if not admitted.hasTag:
    return LogosResult() # the subscriber's own decisions skipped it
  var cmd = IoCommand(
    conn: d.conn,
    kind: IoCommandKind.cmdPublishScoped,
    pubRequest: d.request,
    pubTag: admitted.tag,
    event: name,
    data: @data,
    tooLarge: tlReport,
  )
  let sent = submitWaiting(cmd)
  let id3 = nextId()
  let verdict = request(
    toMessage(
      LcnCarrierScopedDone(
        id: id3, call: d.call, tag: admitted.tag, abandon: sent != sbOk
      )
    ),
    id3,
  )
  if verdict.failed:
    return status(failureOf(verdict))
  LogosResult()

proc publishOp(
    invocation: ptr LogosInvocationContext,
    eventName: cstring,
    data: ptr UncheckedArray[uint8],
    dataLen: csize_t,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE l.2187-2199] The invocation's scoped publication; its
  ## call's Response waits for it (R19).
  bindingEnter()
  if invocation == nil:
    return status(ecInvalidParams, "a null invocation context")
  if data == nil and dataLen > 0:
    return status(ecInvalidParams, "null event data with a length")
  let d = cast[ptr HostInv](invocation.state)
  if not d.enter():
    return status(ecNotReady, "the invocation was released")
  withLock d.lock:
    inc d.publishing
  let bytes = (if data == nil: newSeq[byte]() else: view(data, dataLen))
  result = d.scopedPublish(eventName, bytes)
  withLock d.lock:
    dec d.publishing
  if d.deferred:
    d.leave()

var contextVtable = LogosInvocationContextVtable(
  abiVersion: InvocationContextAbiVersion,
  structSize: csize_t(sizeof(LogosInvocationContextVtable)),
  caller: callerOp,
  isCancelled: isCancelledOp,
  publish: publishOp,
)

# Calls ---------------------------------------------------------------------------------------

proc finished(d: ptr HostInv, outcome: sink Result[seq[byte], InvocationFailure]) =
  ## [SPEC RUNTIME §4.1 l.838-840; R19] The provider's result, checked against
  ## the schema, committed once its scoped publications are answered.
  var r = outcome
  if r.isOk:
    var trail: CallTrail
    let sel = selectedFor(d.root)
    let checked =
      if sel.isErr:
        Result[void, InvocationFailure].err(
          failure(ecModule, "the selected contract cannot be loaded")
        )
      else:
        sel.get.checkResponse($d.methodName, r.get, trail)
    if checked.isErr:
      wipe(r) # [DECISIONS G276]
      r = Result[seq[byte], InvocationFailure].err(checked.error)
    d.responseRoot = trail.response
  while true:
    var pending: int
    withLock d.lock:
      pending = d.publishing
    if pending == 0:
      break
    sleep(BusyStepMs)
  d.respond(r, workEnded = not d.deferred)

proc leave(d: ptr HostInv) =
  ## A deferred invocation's entry returned; the last one after its release
  ## ends it.
  var last = false
  withLock d.lock:
    dec d.entries
    last = d.entries == 0 and d.released
  if last:
    d.ended()

proc runSync(d: ptr HostInv) =
  ## [SPEC INTERFACE l.2013-2017] `_MODULE_dispatch` with the context current;
  ## the status checked as on the direct path (l.3306-3311, in this process),
  ## the buffer copied and freed at once.
  var buf: ptr UncheckedArray[uint8] = nil
  var len: csize_t = 0
  var f = Frame(context: addr d.context, access: sv.access)
  push(f)
  let r = sv.dispatch(
    sv.module, d.methodName, d.params, csize_t(d.paramsLen), addr buf, addr len
  )
  pop(f)
  # [DECISIONS G276] The provider's text and bytes are copied once, then the
  # copies are wiped where they end (`respond`); its buffer is its own to wipe.
  var outcome = block:
    var checked =
      checkOutcome(r, bufferShape(buf, len)).providerChecked(d.cancelled.load)
    if checked.isErr:
      if transfersBuffer(r, buf):
        sv.free(sv.module, buf)
      Result[seq[byte], InvocationFailure].err(takeFailure(checked))
    else:
      var bytes: seq[byte]
      if len <= csize_t(high(int)):
        bytes = view(buf, len)
      sv.free(sv.module, buf)
      if bytes.len == 0:
        Result[seq[byte], InvocationFailure].err(
          failure(ecModule, "the provider's response is too long")
        )
      else:
        Result[seq[byte], InvocationFailure].ok(move bytes)
  d.finished(move outcome)
  d.ended()

proc releaseOwner(o: LogosResponseOwner) =
  if not o.release.isNil:
    o.release(o.state)

proc completeOp(
    inv: ptr LogosProviderInvocation,
    res: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.cdecl.} =
  ## [SPEC INTERFACE §2.9.2, l.2126-2135] The provider's one completion, from
  ## any thread.
  bindingEnter()
  if inv == nil:
    return
  let d = cast[ptr HostInv](inv)
  var first = false
  withLock d.lock:
    if not d.completed and not d.released:
      d.completed = true
      first = true
      inc d.entries
  if not first:
    releaseOwner(owner)
    return
  # [SPEC INTERFACE l.3306-3311] the invocation's own cancellation flag
  var checked = checkOutcome(res, completionShape(response, len, owner)).providerChecked(
      d.cancelled.load
    )
  var outcome =
    if checked.isErr:
      if ownerValid(owner):
        releaseOwner(owner)
      Result[seq[byte], InvocationFailure].err(takeFailure(checked))
    else:
      var bytes: seq[byte]
      if len <= csize_t(high(int)):
        bytes = view(response, len)
      releaseOwner(owner)
      if bytes.len == 0:
        Result[seq[byte], InvocationFailure].err(
          failure(ecModule, "the provider's response is too long")
        )
      else:
        Result[seq[byte], InvocationFailure].ok(move bytes)
  d.finished(move outcome)
  d.leave()

proc executionReleaseOp(inv: ptr LogosProviderInvocation) {.cdecl.} =
  ## [SPEC INTERFACE l.2137-2141] The provider is done with the invocation; a
  ## release before its completion fails the call.
  bindingEnter()
  if inv == nil:
    return
  let d = cast[ptr HostInv](inv)
  var early, last = false
  withLock d.lock:
    if d.released:
      return
    d.released = true
    early = not d.completed
    d.completed = true
    last = d.entries == 0
  if early:
    d.fail(
      failure(ecModule, "the provider released the invocation without completing it")
    )
  if last:
    d.ended()

proc hookDueLocked(d: ptr HostInv): bool =
  ## [SPEC INTERFACE l.2143-2150] One `request_cancel` once cancellation is
  ## known and `submit` returned, unless execution was released.
  if d.cancelKnown and d.submitReturned and not d.cancelNotified and not d.released and
      not sv.asyncApi.requestCancel.isNil:
    d.cancelNotified = true
    inc d.entries
    return true
  false

proc runCancelHook(d: ptr HostInv) =
  var f = Frame(context: addr d.context, access: sv.access)
  push(f)
  sv.asyncApi.requestCancel(sv.module, addr d.inv)
  pop(f)
  d.leave()

proc runDeferred(d: ptr HostInv) =
  ## [SPEC INTERFACE §2.9.2] `submit` with the context current (l.2166-2167).
  d.inv = LogosProviderInvocation(
    abiVersion: AsyncProviderAbiVersion,
    structSize: csize_t(sizeof(LogosProviderInvocation)),
    `method`: d.methodName,
    paramsCbor: d.params,
    paramsCborLen: csize_t(d.paramsLen),
    context: addr d.context,
    complete: completeOp,
    executionRelease: executionReleaseOp,
  )
  withLock d.lock:
    d.entries = 1 # `submit`
  var f = Frame(context: addr d.context, access: sv.access)
  push(f)
  sv.asyncApi.submit(sv.module, addr d.inv)
  pop(f)
  var hook = false
  withLock d.lock:
    d.submitReturned = true
    hook = d.hookDueLocked()
  if hook:
    d.runCancelHook()
  d.leave()

proc runAdmitted(d: ptr HostInv) =
  ## A dispatch worker: [plan §2.7 step 2; RUN-0815] the params checked under
  ## the session's selected contract, then the provider run, or `logos.schema`
  ## answered.
  var trail: CallTrail
  let sel = selectedFor(d.root)
  if sel.isErr:
    d.fail(failure(ecModule, "the selected contract cannot be loaded"))
    d.ended()
    return
  if d.introspection:
    # [SPEC INTERFACE §5.1; TRANSPORT §8.1; E3] The loop answers from the
    # selected contract; the record commits that answer.
    var params = d.paramsOf
    let r = introspect(sel.get, $d.methodName, params, schemaAnswer(d.root), trail)
    wipe(params)
    d.requestRoot = trail.request
    d.responseRoot = trail.response
    if r.isOk:
      var cmd = IoCommand(
        conn: d.conn, kind: IoCommandKind.cmdIntrospect, introspectId: d.request
      )
      d.commit(cmd, success = true)
    else:
      d.fail(r.error)
    d.ended()
    return
  var params = d.paramsOf
  let checked = checkRequest(sel.get, $d.methodName, params, trail)
  wipe(params)
  d.requestRoot = trail.request
  if checked.isErr:
    d.fail(checked.error)
    d.ended()
    return
  if sel.get.marked($d.methodName).request:
    wipe(checked.get) # [DECISIONS G276] validated; the provider reads the bytes
  d.context = LogosInvocationContext(vtable: addr contextVtable, state: d)
  if d.deferred:
    d.runDeferred()
  else:
    d.runSync()

proc poolLoop(p: ptr Pool) =
  markHostThread()
  while true:
    var j: Job
    try:
      j = p.ch.recv()
    except Exception:
      return
    if j.inv == 0:
      return
    withLock p.lock:
      dec p.idle
    let d = cast[ptr HostInv](j.inv)
    if j.hook:
      d.runCancelHook() # its entry was claimed when it was queued
    else:
      d.runAdmitted()
    withLock p.lock:
      inc p.idle

proc poolMain(p: ptr Pool) {.thread.} =
  poolLoop(p)
  releasePerThread()

proc post(j: Job) =
  ## Work for a dispatch worker; the pool grows while every worker is busy.
  let p = addr sv.pool
  var grow = false
  withLock p.lock:
    if p.idle == 0 and p.count < MaxDispatchWorkers:
      grow = true
      inc p.count
      inc p.idle
  if grow:
    try:
      createThread(p.threads[p.count - 1], poolMain, p)
    except Exception:
      carrierLost("a dispatch worker cannot start")
  try:
    p.ch.send(j)
  except Exception:
    carrierLost("the dispatch queue failed")

# The Runtime's verdicts and orders ------------------------------------------------------

proc verdict(v: LcnCarrierAdmitVerdict) =
  ## Ordering thread: [plan §2.7 steps 2-4] the Runtime's decision on one
  ## dispatched Request.
  let root = digestOf(v.contract).valueOr:
    carrierLost("a verdict whose contract is not a digest")
  if v.failure.isNone and (v.call.isNone or v.consumer.isNone):
    carrierLost("an admission with no call or consumer")
  var d: ptr HostInv
  var answered = false
  withLock sv.lock:
    d = findLocked(v.conn, v.request)
    if d != nil and d.admitted:
      carrierLost("a second verdict on one Request")
    if d != nil:
      if v.failure.isSome:
        unlinkLocked(d)
        answered = d.answered
      else:
        d.admitted = true
        inc sv.running
  if v.failure.isSome:
    if d == nil:
      return # its session ended, or the Runtime answered it
    if not answered:
      # [SPEC RUNTIME l.1828, l.1832] A NOT_READY refusal is reported only once
      # the params validate.
      var params = d.paramsOf
      let f = notReadyAfter(
        selectedFor(root), $d.methodName, params, toInvocation(v.failure.get)
      )
      wipe(params)
      d.fail(f)
    freeInv(d)
    return
  if d == nil:
    # Answered or ended before the verdict: nothing runs.
    send(toMessage(LcnCarrierCallEnded(call: v.call.get, succeeded: false)))
    return
  d.call = v.call.get
  d.root = root
  d.consumer = fixed(v.consumer.get)
  d.retainRequest = v.retain_request
  d.retainResponse = v.retain_response
  post(Job(inv: cast[int](d)))

proc cancelCall(call: uint64) =
  ## Ordering thread: `call_cancel`. The flag is set here; a deferred call's
  ## `request_cancel` runs on a worker. One for a call no longer running is
  ## late and ignored.
  var hook: ptr HostInv
  withLock sv.lock:
    var p = sv.calls
    while p != nil:
      if p.admitted and p.call == call:
        p.cancelled.store(true)
        if p.deferred:
          withLock p.lock:
            p.cancelKnown = true
            if p.hookDueLocked():
              hook = p
        break
      p = p.next
  if hook != nil:
    post(Job(inv: cast[int](hook), hook: true))

proc endedByTerminate(conn: uint64) =
  ## Ordering thread: [SPEC RUNTIME l.1212, l.1271; TRANSPORT l.979; P5 Q3 (a)]
  ## the session's termination is ordered, after which no Response reaches its
  ## consumer, who fails each admitted Request TRANSPORT_ERROR at the close;
  ## the Runtime answers none of them. Each admitted call on it is ended
  ## here, so a provider that returns later commits nothing and its call is
  ## not recorded as a success.
  withLock sv.lock:
    var p = sv.calls
    while p != nil:
      if p.conn == conn and p.admitted:
        p.answered = true
      p = p.next

proc runtimeAnswer(cmd: var IoCommand) =
  ## Ordering thread: [K38 interim] the Runtime's failure for a Request, which
  ## takes effect unless a Response is committed already. One never admitted
  ## ends here.
  var gone: ptr HostInv
  while true:
    var busy = false
    withLock sv.lock:
      let d = findLocked(cmd.conn, cmd.requestId)
      if d != nil and d.answered:
        return
      let r = sv.loop.trySubmit(cmd)
      if r == sbBusy:
        busy = true
      elif d != nil:
        d.answered = true
        if not d.admitted:
          unlinkLocked(d)
          gone = d
    if not busy:
      break
    sleep(BusyStepMs)
  if gone != nil:
    freeInv(gone)

proc submitLoop() =
  ## The Runtime's orders and verdicts, applied in the order they came.
  while true:
    var f: seq[byte]
    try:
      f = sv.orders.recv()
    except Exception:
      return
    if f.len == 0:
      return
    let m = carrier.decodeMessage(f).valueOr:
      carrierLost("a lane-2 frame does not decode")
    case m.kind
    of LcnCarrierMessageKind.lcn_Carrier_admit_verdict:
      verdict(m.arm_lcn_Carrier_admit_verdict)
      continue
    of LcnCarrierMessageKind.lcn_Carrier_call_cancel:
      cancelCall(m.arm_lcn_Carrier_call_cancel.call)
      continue
    else:
      discard
    let c = toCommand(m).valueOr:
      carrierLost("a lane-2 order is malformed: " & error)
    if c.isNone:
      carrierLost("an unexpected lane-2 message: " & $m.kind)
    var cmd = c.get
    if cmd.kind == IoCommandKind.cmdRespond:
      runtimeAnswer(cmd)
      continue
    if cmd.kind == IoCommandKind.cmdTerminate and cmd.termPhase != tpBegin:
      endedByTerminate(cmd.conn)
    if cmd.kind == IoCommandKind.cmdAdmit and cmd.verdict.kind == avEstablished:
      # [G394; synthesis §3] A session on an earlier contract takes its input
      # to the loop, which accepts the set at the first and keeps it
      # (`callee.boundaryFor`); the Runtime's verdict never carries one to a
      # host.
      cmd.verdict.earlier = earlierInputOf(cmd.verdict.binding.contract)
    while true:
      let r = sv.loop.trySubmit(cmd)
      if r != sbBusy:
        break # `sbStopped`: the loop is ending, and its sessions with it
      sleep(BusyStepMs)

proc submitMain() {.thread.} =
  submitLoop()
  releasePerThread()

proc order*(f: seq[byte]) =
  ## Main thread: one lane-2 order or verdict.
  if sv == nil or sv.loop == nil:
    carrierLost("a lane-2 order for a host that serves nothing")
  try:
    sv.orders.send(f)
  except Exception:
    carrierLost("the order queue failed")

# The loop's events -------------------------------------------------------------------------

proc loopEvent(ev: sink IoEvent, ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  ## I/O thread: the serve outcome is the host's; a dispatched Request's
  ## params stay here; every other event of the callee side goes to the
  ## Runtime as it came, with no payload.
  var ev = ev
  defer:
    wipe(ev) # [DECISIONS G276] the params are copied into the record
  case ev.kind
  of IoEventKind.evListening:
    withLock sv.lock:
      if sv.serve == ssWaiting:
        sv.serve = ssListening
      broadcast(sv.cond)
  of IoEventKind.evServeFailed:
    withLock sv.lock:
      sv.serve = ssFailed
      let n = min(ev.serveError.len, sv.serveError.len)
      for i in 0 ..< n:
        sv.serveError[i] = ev.serveError[i]
      sv.serveErrorLen = n
      broadcast(sv.cond)
  of IoEventKind.evStopped:
    withLock sv.lock:
      sv.stopped = true
      broadcast(sv.cond)
  else:
    if ev.kind == IoEventKind.evDispatch:
      newInv(ev)
    elif ev.kind == IoEventKind.evStop:
      endedBySession(ev.conn, Opt.some(ev.stopId))
    elif ev.kind == IoEventKind.evClosed:
      endedBySession(ev.conn, Opt.none(uint64))
    let m = hostio.toMessage(ev)
    if m.isSome:
      send(m.get)

# Ordinary publications (lane 1, `rcbinding.nim`) ------------------------------------------

proc publishConn*(conn: uint64, name: string, data: seq[byte]): SubmitResult =
  ## [plan §2.7; E1; D3 (a), G165 (a)] An ordinary Event to one subscriber
  ## session the Runtime admitted: waits for the output budget with no finite
  ## bound; an Event over the subscriber's frame maximum closes it.
  if sv == nil or sv.loop == nil:
    return sbStopped
  var cmd = IoCommand(
    conn: conn,
    kind: IoCommandKind.cmdPublishConn,
    event: name,
    data: data,
    tooLarge: tlClose,
  )
  submitWaiting(cmd)

# Serving ---------------------------------------------------------------------------------------

proc serveEndpoint*(
    b: ref NativeBinding,
    context: ptr LogosModuleContext,
    access: pointer,
    module, path, runtimeId: string,
    transport: openArray[uint64],
    listener: cint,
    depth: int,
): Result[void, string] =
  ## Lifecycle thread, after a successful `_MODULE_init`: the loop serves
  ## `listener` from the module's primary contract; returns once it listens.
  ## [TRN-0186] A listener that did not arrive is refused here.
  var typ, domain, listening: cint
  if sockInfo(listener, addr typ, addr domain, addr listening) != 0 or typ != SockStream or
      domain != AfUnix or listening == 0:
    return err("the listener is not a listening local stream socket")
  let config = ?transportOf(transport)
  if runtimeId.len == 0 or runtimeId.len > TextCapacity:
    return err("the Runtime id is not valid")
  # [synthesis Q4; G394] The roots and the primary input the Runtime's own
  # endpoint takes (`servedroots`): an earlier contract is served, and its
  # input goes to the loop with each session that selects it (`submitLoop`).
  let served = ?servedContracts(b.contracts)
  # [DECISIONS I106] The contracts are kept already, before `_MODULE_init`
  # (`selected.keepProvider`).
  sv = createShared(Served)
  initLock(sv.lock)
  initCond(sv.cond)
  initLock(sv.pool.lock)
  sv.pool.ch.open()
  sv.orders.open()
  sv.runtimeId = fixed(runtimeId)
  sv.module = context
  sv.dispatch = b.dispatch
  sv.free = b.free
  sv.asyncApi = b.asyncApi
  sv.access = access
  sv.serve = ssWaiting
  sv.loop = ?startTransport(config, loopEvent, nil)
  var cmd = IoCommand(
    kind: IoCommandKind.cmdServe,
    endpoint: HostEndpoint,
    listener: listener,
    served: CalleeEndpoint(endpoint: path, provider: module, contracts: served.roots),
    contract: served.primary,
  )
  if sv.loop.trySubmit(cmd) != sbOk:
    return err("the transport loop did not take the listener")
  var failed = ""
  withLock sv.lock:
    while sv.serve == ssWaiting:
      wait(sv.cond, sv.lock)
    if sv.serve == ssFailed:
      failed = newString(sv.serveErrorLen)
      for i in 0 ..< sv.serveErrorLen:
        failed[i] = sv.serveError[i]
  if failed.len > 0 or sv.serve != ssListening:
    sv.loop.stopTransport()
    sv.loop = nil
    return err("the listener cannot be served: " & failed)
  try:
    createThread(sv.submitter, submitMain)
  except Exception:
    return err("the order thread cannot start")
  ok()

proc stopServing*() =
  ## Lifecycle thread, at the release [R13]: no new connection, every
  ## admitted call ends, then the loop stops and its sessions close.
  if sv == nil or sv.loop == nil:
    return
  var cmd = IoCommand(kind: IoCommandKind.cmdStopServing, stopEndpoint: HostEndpoint)
  discard sv.loop.trySubmit(cmd)
  withLock sv.lock:
    while sv.running > 0:
      wait(sv.cond, sv.lock)
  try:
    sv.orders.send(@[])
    joinThread(sv.submitter)
  except Exception:
    discard
  sv.loop.stopTransport()
  # [DECISIONS G276] Requests never admitted: their params go before the exit.
  var gone: seq[ptr HostInv]
  withLock sv.lock:
    var p = sv.calls
    while p != nil:
      gone.add(p)
      p = p.next
    sv.calls = nil
  for d in gone:
    freeInv(d)
