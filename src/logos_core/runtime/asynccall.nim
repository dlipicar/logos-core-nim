## INTERFACE §2.9, §2.9.1, §2.9.2, §2.9.3, §5.2; RUNTIME §4.1, §6.4, §7.3.1:
## asynchronous calls through Runtime Control and route bindings, and deferred
## provider completion.
##
## A prepared call (`AsyncCall`) lives on the shared heap with copies of what
## it needs (RUNTIME l.880-884): its consumer and attempt, its route and path
## generation, the selected contract, the method and request. The consumer
## holds one reference until `release` returns; the Runtime thread holds one
## from submission until nothing of the call runs any more.
##
## [IMPL] Execution. `submit` only posts: the Runtime thread registers the
## call and its deadline and hands it to a call worker (INTERFACE l.2016-2017),
## which admits it as a synchronous call is admitted (`invoke.nim`) and then
## either runs `_MODULE_dispatch` or, when the provider exports a valid
## deferred surface, builds one provider invocation (`Deferred`) and calls its
## `submit` with that invocation's context current (l.2166-2167).
##
## [IMPL] Terminal decisions. Under the call's lock the first terminal decision
## wins (l.2065-2071): a result (from a call worker or a deferred `complete`),
## a local rejection, `cancel`, `release`, the timeout (the Runtime thread),
## or the end of its route or consumer [G174]. Each completion callback runs on
## a lifecycle worker, never inline in `submit` or in a provider's `complete`;
## it is suppressed once the consumer's realization has ended. Its response
## owner frees a Runtime copy, so it outlives the call and the handle
## (l.2089-2097).
##
## [IMPL] A deferred invocation counts its admitted entries (`submit`, the
## `request_cancel` hook, context operations) under one entry guard
## (`callside.enterGuard`); once `execution_release` came and the last entry
## returned, the Runtime thread is told it is idle, and only then does it leave
## its provider's in-flight count, which `_MODULE_destroy` waits for
## (l.2155-2158). A cancellation, a timeout or the end of the route or consumer
## marks it cancelled and arranges one `request_cancel` after `submit`
## returned, unless execution was already released (l.2143-2153).
##
## [IMPL; DECISIONS I90, plan §2.5] A served invocation of a transported route
## is an `AsyncCall` with a session origin: the Runtime thread makes it at
## `evDispatch`, holds its one reference, and a call worker admits and runs it
## as above. Its outcome is a Response on the session, never a callback. The
## G174 discipline, adapted (owner batch B 7): under the ticket's lock, an end
## code NOT_AUTHORISED means the Runtime answers the Request; otherwise the
## worker submits the Response while still holding the lock, and on a full
## output budget releases it, waits 1 ms and tries again. Every other end is
## answered by the Runtime thread (`unsentFailure`), unless the session
## already committed it (`markSent`: a Cancel, a closed session).

{.push raises: [], gcsafe.}

import std/[atomics, locks, monotimes, times]
from std/os import sleep
import results
import ../abi/[checks, types]
import ../iface/[outcome, payload]
import ./[callside, invoke, plumbing]
from ../transport/io/api import IoCommand, IoCommandKind, CallOutcome, SubmitResult
from ./tport import trySubmit

type
  CallPhase* = enum
    cpPrepared
    cpSubmitted
    cpTerminal ## decided; the completion callback has not begun
    cpCompleting ## the completion callback is running
    cpDone ## the callback returned or was suppressed, or the call was discarded

  CallEnd* = enum
    okResult ## the call's own result or failure
    okCancelled ## `cancel` or `release`
    okTimeout
    okEnded ## its route or its consumer's realization ended [G174]

  Owned = object ## What one completion's response owner frees (INTERFACE l.2091-2093).
    message: cstring
    detail: ptr UncheckedArray[uint8]
    detailLen: int
    response: ptr UncheckedArray[uint8]
    responseLen: int

  AsyncCall* = object
    engine: Engine
    refs: Atomic[int]
    lock: Lock
    cond: Cond
    rc*: bool ## a Runtime Control call; otherwise a route call
    consumer*, attempt*, route*: FixedText
    generation*: uint64
    blob: ptr SchemaBlob ## route calls: the selected contract, retained
    methodName: cstring
    params: ptr UncheckedArray[byte]
    paramsLen: int
    hasTimeout*: bool
    timeoutMs*: uint64
    submittedAt*: MonoTime
    complete: LogosAsyncCompleteFn
    userData: pointer
    phase: CallPhase
    cancelledEarly: bool ## cancelled before submission
    started: bool ## a call worker began it (under `lock`) [I88]
    code: ErrorCode
    kind: CallEnd
    owned: ptr Owned ## the outcome until the callback takes it
    completer: int ## the thread running the completion callback
    session*: bool ## [I90] a served invocation: its outcome is a Response on `conn`
    conn*: uint64
    requestId*: uint64
    sent: bool ## session: its Response was submitted, or none is due (under `lock`)
    link*: uint64
      ## [I90] a route call through a transported handle: the link the Runtime
      ## thread sends it on (`transported.nim`); 0: direct

  Deferred = object
    ## One provider invocation of the deferred surface (INTERFACE §2.9.2).
    inv: LogosProviderInvocation ## first: the provider passes its address back
    state: InvocationState
    call: ptr AsyncCall
    api: ptr LogosAsyncProviderApi
    module: ptr LogosModuleContext
    methodName: cstring
    params: ptr UncheckedArray[byte]
    paramsLen: int
    completed: bool ## under `state.glock`
    submitReturned: bool
    cancelKnown: bool
    cancelNotified: bool
    audit: ptr SharedCapture
      ## [I85] the call's capture and request commitment, taken by its one
      ## completion (or early release), which records the call

proc copyText(s: string): cstring =
  let p = cast[ptr UncheckedArray[char]](allocShared(s.len + 1))
  for i, c in s:
    p[i] = c
  p[s.len] = '\0'
  cast[cstring](p)

proc copyBytes(p: ptr UncheckedArray[uint8], n: int): ptr UncheckedArray[byte] =
  result = cast[ptr UncheckedArray[byte]](allocShared(max(n, 1)))
  for i in 0 ..< n:
    result[i] = p[i]

func failed(f: InvocationFailure): Result[seq[byte], InvocationFailure] =
  Result[seq[byte], InvocationFailure].err(f)

func bytesOf(p: ptr UncheckedArray[byte], n: int): seq[byte] =
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = p[i]

# Outcomes ------------------------------------------------------------------------------

proc ownedRelease(state: pointer) {.cdecl.} =
  ## The response owner's release: any thread, once.
  bindingEnter()
  let o = cast[ptr Owned](state)
  if o == nil:
    return
  if o.message != nil:
    deallocShared(o.message)
  if o.detail != nil:
    deallocShared(o.detail)
  if o.response != nil:
    deallocShared(o.response)
  freeShared(o)

proc ownedOf(r: Result[seq[byte], InvocationFailure]): (ErrorCode, ptr Owned) =
  ## A Runtime copy of an outcome: a success's response, or a failure's
  ## message and (INVALID_PARAMS only) detail.
  let o = createShared(Owned)
  if r.isOk:
    let b = r.get
    if b.len > 0: # empty: a session's introspection, answered by the I/O thread
      o.response = copyBytes(cast[ptr UncheckedArray[uint8]](unsafeAddr b[0]), b.len)
      o.responseLen = b.len
    return (ecOk, o)
  let f = r.error
  if f.message.isSome:
    o.message = copyText(clip(f.message.get))
  if f.code == ecInvalidParams and f.detail.isSome and f.detail.get.len > 0 and
      f.detail.get.len <= MaxDetailBytes:
    let d = f.detail.get
    o.detail = copyBytes(cast[ptr UncheckedArray[uint8]](unsafeAddr d[0]), d.len)
    o.detailLen = d.len
  (f.code, o)

proc decideLocked(
    c: ptr AsyncCall, r: Result[seq[byte], InvocationFailure], kind: CallEnd
) =
  let (code, o) = ownedOf(r)
  c.code = code
  c.owned = o
  c.kind = kind
  c.phase = cpTerminal

proc decide*(
    c: ptr AsyncCall, r: Result[seq[byte], InvocationFailure], kind: CallEnd
): bool =
  ## [SPEC INTERFACE l.2065-2071] The first terminal decision wins; true when
  ## this one did. The caller then lets the Runtime thread schedule the
  ## completion (`aeTerminal`), unless it is the Runtime thread.
  withLock c.lock:
    if c.phase == cpSubmitted:
      c.decideLocked(r, kind)
      return true
  false

proc decide*(c: ptr AsyncCall, f: InvocationFailure, kind: CallEnd): bool =
  c.decide(failed(f), kind)

proc refuseQueued*(c: ptr AsyncCall, f: InvocationFailure): bool =
  ## [IMPL; I88, deviation 5] A submitted call no call worker has begun is
  ## decided with `f`, as its own outcome; true when it was. The worker that
  ## later takes it finds it terminal.
  withLock c.lock:
    if c.phase == cpSubmitted and not c.started:
      c.decideLocked(failed(f), okResult)
      return true
  false

func outcomeOf(r: Result[seq[byte], InvocationFailure]): CallOutcome =
  if r.isOk:
    CallOutcome(ok: true, result: r.get)
  else:
    CallOutcome(ok: false, failure: r.error)

proc sessionCommit(
    c: ptr AsyncCall,
    t: ptr CallTicket,
    r: Result[seq[byte], InvocationFailure],
    workEnded: bool,
): bool =
  ## [I90; plan §2.5; owner batch B 7] A served invocation's own outcome: the
  ## Response is submitted under the ticket's lock (when admitted) and the
  ## call's lock, and the decision made with it, so it is ordered with the
  ## route's revocation through the loop (RUNTIME l.1292-1296). A full output
  ## budget releases both locks before waiting (l.1298). True when `r` is the
  ## call's outcome and a success.
  let ok = r.isOk
  var cmd = IoCommand(
    conn: c.conn,
    kind: IoCommandKind.cmdRespond,
    requestId: c.requestId,
    outcome: outcomeOf(r),
    workEnded: workEnded,
  )
  while true:
    var state = 0
      # 0: lost; 1: decided and sent; 2: busy; 3: decided, the Runtime answers
    if t != nil:
      acquire(t.lock)
    if t != nil and t.endCode == ord(ecNotAuthorised):
      if c.decide(failed(revokedResult()), okEnded):
        state = 3
    else:
      acquire(c.lock)
      if c.phase == cpSubmitted:
        if c.engine.tport.trySubmit(cmd) == SubmitResult.sbBusy:
          state = 2
        else:
          c.decideLocked(r, okResult)
          c.sent = true
          state = 1
      release(c.lock)
    if t != nil:
      release(t.lock)
    case state
    of 2:
      sleep(1) # [IMPL] 1 ms, holding nothing
    of 1, 3:
      c.engine.post(Msg(kind: mkAsync, event: aeTerminal, target: c))
      return state == 1 and ok
    else:
      return false

proc offer(
    c: ptr AsyncCall, r: Result[seq[byte], InvocationFailure]
): bool {.discardable.} =
  ## A decision off the Runtime thread; true when `r` is the call's outcome
  ## and a success.
  let ok = r.isOk
  if c.session:
    return c.sessionCommit(nil, r, workEnded = true)
  if c.decide(r, okResult):
    c.engine.post(Msg(kind: mkAsync, event: aeTerminal, target: c))
    return ok
  false

proc offerCommitted(
    c: ptr AsyncCall,
    t: ptr CallTicket,
    r: Result[seq[byte], InvocationFailure],
    workEnded = false,
): bool {.discardable.} =
  ## [G174] A provider's result, decided under the ticket's lock so the commit
  ## is ordered with the route's revocation (RUNTIME l.1292-1293); true when
  ## it is the call's outcome and a success. `workEnded`: a served
  ## invocation's provider work ended with it (the synchronous path).
  if c.session:
    return c.sessionCommit(t, r, workEnded)
  let ok = r.isOk
  var won = false
  withLock t.lock:
    if t.endCode == ord(ecNotAuthorised):
      won = c.decide(failed(revokedResult()), okEnded)
      result = false
    else:
      won = c.decide(r, okResult)
      result = won and ok
  if won:
    c.engine.post(Msg(kind: mkAsync, event: aeTerminal, target: c))

# What the Runtime thread reads ----------------------------------------------------------

proc asyncOf*(p: pointer): ptr AsyncCall =
  cast[ptr AsyncCall](p)

proc retainCall*(c: ptr AsyncCall) =
  ## [I90] Another holder: a transported call's link, until its Response.
  discard c.refs.fetchAdd(1)

proc methodOf*(c: ptr AsyncCall): string =
  $c.methodName

proc paramsOf*(c: ptr AsyncCall): seq[byte] =
  bytesOf(c.params, c.paramsLen)

proc blobOf*(c: ptr AsyncCall): ptr SchemaBlob =
  c.blob

proc isTerminal*(c: ptr AsyncCall): bool =
  withLock c.lock:
    result = c.phase >= cpTerminal

proc callEnd*(c: ptr AsyncCall): CallEnd =
  withLock c.lock:
    result = c.kind

proc deadline*(c: ptr AsyncCall): Opt[MonoTime] =
  ## [SPEC INTERFACE l.2059-2063] Measured from submission, monotonic.
  if not c.hasTimeout:
    return Opt.none(MonoTime)
  let ms = int64(min(c.timeoutMs, uint64(high(int64) div 2_000_000)))
  Opt.some(c.submittedAt + initDuration(milliseconds = ms))

proc markSent*(c: ptr AsyncCall) =
  ## [I90] Session: no Response is due from here on (the session committed
  ## CANCELLED, closed, or was answered by a termination).
  withLock c.lock:
    c.sent = true

proc unsentFailure*(c: ptr AsyncCall): Opt[CallOutcome] =
  ## [I90] Runtime thread, at a session call's terminal decision: the failure
  ## the Runtime answers its Request with, when nothing was sent for it.
  withLock c.lock:
    if c.sent or c.phase < cpTerminal or c.code == ecOk:
      return Opt.none(CallOutcome)
    c.sent = true
    var f = InvocationFailure(code: c.code)
    if c.owned != nil and c.owned.message != nil:
      f.message = Opt.some($c.owned.message)
    return Opt.some(CallOutcome(ok: false, failure: f))

proc introspectSession(c: ptr AsyncCall): bool =
  ## [E3; I90] An authorized `logos.schema` on a session: the I/O thread
  ## answers it from the selected contract (`cmdIntrospect`).
  var cmd = IoCommand(
    conn: c.conn, kind: IoCommandKind.cmdIntrospect, introspectId: c.requestId
  )
  var won = false
  withLock c.lock:
    if c.phase == cpSubmitted:
      discard c.engine.tport.trySubmit(cmd) # uncharged: never busy
      c.decideLocked(Result[seq[byte], InvocationFailure].ok(@[]), okResult)
      c.sent = true
      won = true
  if won:
    c.engine.post(Msg(kind: mkAsync, event: aeTerminal, target: c))
  won

proc suppress*(c: ptr AsyncCall) =
  ## [IMPL] The consumer's realization ended: a completion callback that has
  ## not begun never will.
  withLock c.lock:
    if c.phase == cpTerminal:
      c.phase = cpDone
      if c.owned != nil:
        ownedRelease(c.owned)
        c.owned = nil
      broadcast(c.cond)

proc freeCall(c: ptr AsyncCall) =
  if c.owned != nil:
    ownedRelease(c.owned)
  drop(c.blob)
  deallocShared(c.methodName)
  deallocShared(c.params)
  deinitCond(c.cond)
  deinitLock(c.lock)
  discard c.engine.outstanding.fetchSub(1)
  freeShared(c)

proc dropCall*(c: ptr AsyncCall) =
  if c.refs.fetchSub(1) == 1:
    freeCall(c)

# The completion callback ----------------------------------------------------------------

proc runComplete*(p: pointer) =
  ## Lifecycle worker: the call's one completion callback, unless it was
  ## suppressed. The callback takes the response owner.
  let c = asyncOf(p)
  var run = false
  var o: ptr Owned
  var code: ErrorCode
  withLock c.lock:
    if c.phase == cpTerminal:
      c.phase = cpCompleting
      c.completer = getThreadId()
      o = c.owned
      c.owned = nil
      code = c.code
      run = true
  if not run:
    return
  var res = LogosResult(code: CErrorCode(ord(code)))
  var response: ptr UncheckedArray[uint8] = nil
  var len: csize_t = 0
  if code == ecOk:
    response = o.response
    len = csize_t(o.responseLen)
  else:
    res.message = o.message
    if o.detail != nil:
      res.detail = o.detail
      res.detailLen = csize_t(o.detailLen)
  c.complete(
    c.userData, res, response, len, LogosResponseOwner(state: o, release: ownedRelease)
  )
  withLock c.lock:
    c.phase = cpDone
    c.completer = 0
    broadcast(c.cond)

# Deferred provider invocations ----------------------------------------------------------

proc releaseOwner(o: LogosResponseOwner) =
  ## [SPEC INTERFACE l.2128] `complete` consumes the owner on every path.
  if not o.release.isNil:
    o.release(o.state)

proc hookDueLocked(d: ptr Deferred): bool =
  ## [SPEC INTERFACE l.2143-2150] One `request_cancel` once cancellation is
  ## known and `submit` returned, unless execution was released; its entry
  ## guard is claimed here.
  if d.cancelKnown and d.submitReturned and not d.cancelNotified and not d.state.released and
      not d.api.requestCancel.isNil:
    d.cancelNotified = true
    inc d.state.entries
    return true
  false

proc completionOf(
    d: ptr Deferred,
    res: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
    trail: var CallTrail,
): Result[seq[byte], InvocationFailure] =
  ## [SPEC INTERFACE l.2126-2135] The provider's completion as the ordinary
  ## boundary checks a result, copied before its owner is released.
  let shape = completionShape(response, len, owner)
  let checked = checkOutcome(res, shape)
  if checked.isErr:
    if ownerValid(owner):
      releaseOwner(owner)
    return err(failureOf(checked.error))
  var bytes: seq[byte]
  if len <= csize_t(high(int)):
    bytes = view(response, len)
  releaseOwner(owner)
  if bytes.len == 0:
    return err(failure(ecModule, "the provider's response is too long"))
  let sel = selectedOf(d.state.blob).valueOr:
    return err(failure(ecModule, "the selected contract cannot be loaded"))
  ?checkResponse(sel, $d.methodName, bytes, trail)
  ok(bytes)

proc recordDeferred(
    s: ptr InvocationState, audit: ptr SharedCapture, trail: CallTrail
) =
  ## [SPEC CA l.1172-1174; I85] The deferred call's record after its outcome.
  if audit == nil:
    return
  var (capture, t) = unshare(audit)
  t.response = trail.response
  t.succeeded = trail.succeeded
  s.engine.record(capture, t)

proc completeOp(
    inv: ptr LogosProviderInvocation,
    result: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.cdecl.} =
  ## [SPEC INTERFACE §2.9.2] The provider's one completion, from any thread.
  bindingEnter()
  if inv == nil:
    return
  let d = cast[ptr Deferred](inv)
  let s = addr d.state
  if not s.enterGuard():
    releaseOwner(owner)
    return
  var first = false
  var audit: ptr SharedCapture = nil
  withLock s.glock:
    if not d.completed:
      d.completed = true
      first = true
      swap(audit, d.audit)
  if first:
    var trail: CallTrail
    trail.succeeded = d.call.offerCommitted(
      s.ticket, d.completionOf(result, response, len, owner, trail)
    )
    recordDeferred(s, audit, trail)
  else:
    releaseOwner(owner)
    s.engine.diagnose(
      "a second completion of " & $d.methodName & " from " & $s.provider & " was ignored"
    )
  s.leaveGuard()

proc executionReleaseOp(inv: ptr LogosProviderInvocation) {.cdecl.} =
  ## [SPEC INTERFACE l.2137-2141] Closes admission through the invocation; it
  ## never waits for admitted entries, which keep the state until they return.
  bindingEnter()
  if inv == nil:
    return
  let d = cast[ptr Deferred](inv)
  let s = addr d.state
  var again, early = false
  var audit: ptr SharedCapture = nil
  withLock s.glock:
    if s.released or s.finished:
      again = true
    else:
      s.released = true
      early = not d.completed
      if early:
        swap(audit, d.audit)
      d.completed = true
      inc s.entries # this entry, until the outcome below is decided
  if again:
    return
  if early:
    s.engine.diagnose(
      "the provider " & $s.provider & " released " & $d.methodName &
        " without completing it"
    )
    d.call.offerCommitted(
      s.ticket,
      failed(
        failure(ecModule, "the provider released the invocation without completing it")
      ),
    )
    recordDeferred(s, audit, CallTrail())
  s.leaveGuard()

proc submitDeferred(
    c: ptr AsyncCall,
    adm: Admission,
    bare: string,
    params: seq[byte],
    audit: ptr SharedCapture,
) =
  ## Call worker: one provider invocation through the deferred surface.
  let d = createShared(Deferred)
  d.call = c
  d.audit = audit
  d.api = adm.asyncApi
  d.module = adm.context
  d.methodName = copyText(bare)
  d.params =
    copyBytes(cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]), params.len)
  d.paramsLen = params.len
  d.state = invocationFor(
    adm,
    c.consumer,
    c.route,
    c.generation,
    retain(c.blob),
    c.engine,
    (if c.session: c.conn else: 0'u64),
    (if c.session: c.requestId else: 0'u64),
  )
  d.state.guarded = true
  d.state.owner = d
  d.state.entries = 1 # `submit`
  initLock(d.state.glock)
  initContext(d.state)
  d.inv = LogosProviderInvocation(
    abiVersion: AsyncProviderAbiVersion,
    structSize: csize_t(sizeof(LogosProviderInvocation)),
    `method`: d.methodName,
    paramsCbor: cast[ptr UncheckedArray[uint8]](d.params),
    paramsCborLen: csize_t(d.paramsLen),
    context: addr d.state.context,
    complete: completeOp,
    executionRelease: executionReleaseOp,
  )
  c.engine.post(Msg(kind: mkAsync, event: aeDeferred, target: c, extra: d))
  # [SPEC INTERFACE l.2166-2167] `current` returns its context during `submit`.
  var f = Frame(context: addr d.state.context, access: adm.access)
  push(f)
  d.api.submit(d.module, addr d.inv)
  pop(f)
  var hook = false
  withLock d.state.glock:
    d.submitReturned = true
    hook = d.hookDueLocked()
  if hook:
    c.engine.post(Msg(kind: mkAsync, event: aeHook, target: c, extra: d))
  leaveGuard(addr d.state)

proc cancelKnown*(p: pointer): bool =
  ## Runtime thread: the deferred invocation is cancelled; true when its
  ## `request_cancel` is due now (its entry guard is claimed).
  let d = cast[ptr Deferred](p)
  withLock d.state.glock:
    if d.state.finished:
      return false
    d.cancelKnown = true
    result = d.hookDueLocked()

proc runRequestCancel*(p: pointer) =
  ## Lifecycle worker: the hook, outside every lock, with the invocation's
  ## context current (INTERFACE l.2151-2152, l.2166-2167).
  let d = cast[ptr Deferred](p)
  var f = Frame(context: addr d.state.context, access: d.state.access)
  push(f)
  d.api.requestCancel(d.module, addr d.inv)
  pop(f)
  leaveGuard(addr d.state)

proc finishDeferred*(p: pointer): (string, string, ptr CallTicket) =
  ## Runtime thread, once the invocation is idle: frees it and returns its
  ## provider, route and ticket, which leave the in-flight count.
  let d = cast[ptr Deferred](p)
  result = ($d.state.provider, $d.state.route, d.state.ticket)
  if d.audit != nil:
    # [IMPL] Never reached: its completion or release took it.
    recordDeferred(addr d.state, d.audit, CallTrail())
    d.audit = nil
  drop(d.state.blob)
  deallocShared(d.methodName)
  deallocShared(d.params)
  deinitLock(d.state.glock)
  freeShared(d)

# The call worker ----------------------------------------------------------------------------

proc runRoute(c: ptr AsyncCall, bare: string, params: seq[byte]) =
  let e = c.engine
  let reply = e.call(
    Request(
      kind: rqAdmit,
      origin: moduleOrigin($c.consumer),
      attempt: $c.attempt,
      route: $c.route,
      bare: bare,
      call: c,
    )
  )
  if reply.error.isSome:
    c.offer(failed(notReadyAfter(c.blob, bare, params, reply.error.get)))
    return
  let adm = reply.admission
  var trail: CallTrail
  if adm.introspection:
    let r = introspect(c.blob, bare, params, adm.schema, trail)
    if c.session and r.isOk:
      # [E3] The record commits what the boundary answers with.
      trail.succeeded = c.introspectSession()
    else:
      trail.succeeded = c.offer(r)
    e.record(adm.capture, trail)
    return
  if c.isTerminal:
    # Decided while it was admitted: nothing is dispatched.
    e.record(adm.capture, trail)
    leave(e, adm)
    return
  if adm.asyncApi == nil:
    # [SPEC INTERFACE l.2013-2017] Over the synchronous provider ABI.
    trail.succeeded = c.offerCommitted(
      adm.ticket,
      callProvider(
        adm,
        e,
        c.consumer,
        c.route,
        c.generation,
        c.blob,
        bare,
        params,
        trail,
        (if c.session: c.conn else: 0'u64),
        (if c.session: c.requestId else: 0'u64),
      ),
      workEnded = true,
    )
    e.record(adm.capture, trail)
    leave(e, adm)
  else:
    # [SPEC RUNTIME §4.1 l.833-841; RUN-0332] The request is validated and
    # committed before `submit`, as on the synchronous path; then the same
    # check as `callProvider` [S8b-1 interim].
    let refused = block:
      let sel = selectedOf(c.blob)
      if sel.isErr:
        Result[void, InvocationFailure].err(
          failure(ecModule, "the selected contract cannot be loaded")
        )
      else:
        let v = checkRequest(sel.get, bare, params, trail)
        if v.isErr:
          Result[void, InvocationFailure].err(v.error)
        else:
          authorityRefusal(adm, e, $c.consumer, $c.route, bare, v.get)
    if refused.isErr:
      c.offerCommitted(
        adm.ticket,
        Result[seq[byte], InvocationFailure].err(refused.error),
        workEnded = true,
      )
      e.record(adm.capture, trail)
      leave(e, adm)
      return
    c.submitDeferred(adm, bare, params, share(adm.capture, trail))

proc runCall*(p: pointer) =
  ## Call worker: one submitted call, unless it is already terminal. The
  ## engine posts `mkCallJobDone` after this returns.
  let c = asyncOf(p)
  var begun = false
  withLock c.lock:
    if c.phase == cpSubmitted:
      c.started = true
      begun = true
  if not begun:
    return
  let bare = $c.methodName
  let params = bytesOf(c.params, c.paramsLen)
  if c.rc:
    c.offer(rcInvoke(c.engine, $c.consumer, $c.attempt, bare, params))
  else:
    c.runRoute(bare, params)

# The async call vtable -------------------------------------------------------------------

proc callOf(call: ptr LogosAsyncCall): ptr AsyncCall =
  if call == nil:
    return nil
  cast[ptr AsyncCall](call.state)

proc submitOp(call: ptr LogosAsyncCall) {.cdecl.} =
  ## [SPEC INTERFACE l.2050-2063] Once; no result channel. The Runtime thread
  ## takes a reference before anything else can run the call.
  bindingEnter()
  let c = callOf(call)
  if c == nil:
    return
  var submitted = false
  withLock c.lock:
    if c.phase == cpPrepared:
      submitted = true
      c.phase = cpSubmitted
      c.submittedAt = getMonoTime()
      if c.cancelledEarly:
        c.decideLocked(
          failed(failure(ecCancelled, "the call was cancelled")), okCancelled
        )
      elif c.hasTimeout and c.timeoutMs == 0:
        # [SPEC INTERFACE l.2061] Expires at once, without dispatch.
        c.decideLocked(failed(failure(ecTimeout, "the call timed out")), okTimeout)
  if not submitted:
    c.engine.diagnose("a second submit of an asynchronous call was ignored")
    return
  discard c.refs.fetchAdd(1)
  c.engine.post(Msg(kind: mkAsync, event: aeSubmit, target: c))

proc cancelOp(call: ptr LogosAsyncCall) {.cdecl.} =
  ## [SPEC INTERFACE l.2065-2071] CANCELLED unless a terminal outcome exists;
  ## before submission it is recorded.
  bindingEnter()
  let c = callOf(call)
  if c == nil:
    return
  var won = false
  withLock c.lock:
    case c.phase
    of cpPrepared:
      c.cancelledEarly = true
    of cpSubmitted:
      c.decideLocked(
        failed(failure(ecCancelled, "the call was cancelled")), okCancelled
      )
      won = true
    else:
      discard
  if won:
    c.engine.post(Msg(kind: mkAsync, event: aeTerminal, target: c))

proc releaseOp(call: ptr LogosAsyncCall) {.cdecl.} =
  ## [SPEC INTERFACE l.2079-2087] An unsubmitted call is discarded; a submitted
  ## one is cancelled if it has no terminal outcome, and its completion
  ## callback is waited for, never the provider.
  bindingEnter()
  let c = callOf(call)
  if c == nil:
    return
  let me = getThreadId()
  var won = false
  var unsent = false
  withLock c.lock:
    case c.phase
    of cpPrepared:
      c.phase = cpDone
      unsent = true
    of cpSubmitted:
      c.decideLocked(failed(failure(ecCancelled, "the call was released")), okCancelled)
      won = true
    else:
      discard
  if unsent and c.link != 0:
    c.engine.post(Msg(kind: mkAsync, event: aeLinkDrop, extra: cast[pointer](c.link)))
  if won:
    c.engine.post(Msg(kind: mkAsync, event: aeTerminal, target: c))
  withLock c.lock:
    # [IMPL] Never from the call's own callback (l.2085); if it is, that
    # callback is not waited for.
    while c.phase in {cpTerminal, cpCompleting} and c.completer != me:
      wait(c.cond, c.lock)
  dropCall(c)

var asyncVtable = LogosAsyncCallVtable(
  abiVersion: AsyncCallAbiVersion,
  structSize: csize_t(sizeof(LogosAsyncCallVtable)),
  submit: submitOp,
  cancel: cancelOp,
  release: releaseOp,
)

proc prepare*(
    e: Engine,
    rc: bool,
    consumer, attempt, route: FixedText,
    generation: uint64,
    blob: ptr SchemaBlob,
    methodName: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    options: ptr LogosAsyncOptions,
    callbacks: ptr LogosAsyncCallbacks,
    outCall: ptr LogosAsyncCall,
    link = 0'u64,
): LogosResult =
  ## [SPEC INTERFACE §2.9.1 l.2035-2048, §5.2 l.3901-3911] Copies what the call
  ## keeps; runs no provider code and no callback; reserves no authority. The
  ## route, admission and authority checks run at submission. A failure leaves
  ## the outputs null.
  if outCall == nil:
    return status(ecInvalidParams, "a null call output")
  if methodName == nil:
    return status(ecInvalidParams, "a null method")
  if rc:
    if params == nil and paramsLen != 0:
      return status(ecInvalidParams, "a null request")
  elif params == nil or paramsLen == 0:
    return status(ecInvalidParams, "a null or empty request")
  checkAsyncOptions(options).isOkOr:
    return status(error)
  checkAsyncCallbacks(callbacks).isOkOr:
    return status(error)
  if e.outstanding.fetchAdd(1) >= MaxAsyncCalls:
    discard e.outstanding.fetchSub(1)
    return status(ecModule, "no capacity for another asynchronous call")
  let c = createShared(AsyncCall)
  c.engine = e
  c.rc = rc
  c.consumer = consumer
  c.attempt = attempt
  c.route = route
  c.generation = generation
  c.blob = (if blob == nil: nil else: retain(blob))
  c.methodName = copyText($methodName)
  c.params = copyBytes(params, int(paramsLen))
  c.paramsLen = int(paramsLen)
  c.hasTimeout = options.hasTimeout
  c.timeoutMs = options.timeoutMs
  c.complete = callbacks.complete
  c.userData = callbacks.userData
  c.link = link
  initLock(c.lock)
  initCond(c.cond)
  c.refs.store(1)
  outCall.vtable = addr asyncVtable
  outCall.state = c
  if link != 0:
    # [Rev R5] Posted before anything the consumer does next with the handle.
    e.post(Msg(kind: mkAsync, event: aeLinkHold, extra: cast[pointer](link)))
  LogosResult()

proc newSessionCall*(
    e: Engine,
    consumer, attempt, route: FixedText,
    generation: uint64,
    blob: ptr SchemaBlob,
    methodName: string,
    params: openArray[byte],
    conn, requestId: uint64,
): ptr AsyncCall =
  ## [I90; plan §2.5] A served invocation of Request `requestId` on session
  ## `conn`, submitted at once; the Runtime thread holds its one reference.
  ## `attempt` is the consumer attempt that established the route, which
  ## admission checks; `blob` (retained by the call) is the provider's
  ## construction input for the selected contract.
  discard e.outstanding.fetchAdd(1)
  let c = createShared(AsyncCall)
  c.engine = e
  c.session = true
  c.conn = conn
  c.requestId = requestId
  c.consumer = consumer
  c.attempt = attempt
  c.route = route
  c.generation = generation
  c.blob = blob
  c.methodName = copyText(methodName)
  c.params = cast[ptr UncheckedArray[byte]](allocShared(max(params.len, 1)))
  for i, b in params:
    c.params[i] = b
  c.paramsLen = params.len
  c.phase = cpSubmitted
  c.submittedAt = getMonoTime()
  initLock(c.lock)
  initCond(c.cond)
  c.refs.store(1)
  c
