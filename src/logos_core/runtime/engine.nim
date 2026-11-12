## RUNTIME §3, §8, §9.1, §9.3, §10: the module-instance registry and its
## lifecycle, for direct realization.
##
## [IMPL] Threads. One Runtime thread owns every record, the realizer and the
## authorizer, and applies every mutation, so the mutations on one target have
## one total order (§9.1): the order the Runtime thread takes them in. Callers
## on any thread send requests through a channel and wait for the reply, which
## the Runtime thread sends once the operation has reached its result.
##
## Module code never runs on the Runtime thread: binding (the platform loader,
## `_MODULE_name()`, `_MODULE_call_surface()`), `_MODULE_init()` and
## `_MODULE_destroy()` run on a pool of worker threads, because a module may
## call Runtime Control from them and the Runtime thread must stay free to
## answer it. A worker that never returns holds only its own thread.
##
## Messages carry values only (no `ref`), so they move between threads under
## ORC and are deep-copied under refc. The bell wakes the Runtime thread for a
## message or for its next deadline.
##
## [IMPL] Deadlines [G61, revised by A18]. A startup deadline (120 s by
## default) for every realization: it starts when the execution attempt is
## accepted and covers binding, `_MODULE_init()` and the readiness checks. On
## expiry the instance enters `error` with `startup-timeout`, and the attempt
## can no longer make it ready (§3.4 l.664-668). Module code still running is
## never interrupted, destroyed or unloaded: a valid context it returns later
## is destroyed through the realizer, and until then cleanup is unresolved, so
## `start` is NOT_READY (l.585-587). An explicit stop has a stop deadline
## (10 s) from the moment the instance enters `stopping`, and shutdown a
## shutdown grace (10 s); past either, the cleanup failure is recorded: the
## instance enters `error` with `cleanup-timeout` (§10.2 l.3835-3838,
## l.3873-3874). A direct realization is never force-released (l.3838): its
## cleanup goes on and `start` is NOT_READY until it ends (§3.4 l.613). Its
## end does not by itself leave `error` (l.611), and the classification stays
## (§9.3 l.3757); a later stop then makes the instance `unloaded` at once.
##
## [IMPL] Runtime Control and direct routes (step 3). Each execution attempt
## gets its own Runtime Control binding and invocation access
## (`bindings.nim`); every operation through them that depends on Runtime-owned
## state is one request to the Runtime thread, ordered with every lifecycle
## change. A route call is admitted there (route, scope, per-call decision) and
## joins its provider's in-flight count; the provider code then runs on the
## caller's thread. A provider that leaves `ready` fails its routes at once,
## and its `_MODULE_destroy` waits until its in-flight count is zero. A
## consumer's routes close when it is stopped and fail when it fails (§3.4
## l.624-626).
##
## [IMPL] Route retention (§9.3 l.3180, l.3249: a deployment concern). An
## ended route keeps its record while anything can still reach it by its id:
## an unreleased handle of a live consumer attempt (§7.5 l.1346), an admitted
## call, or a submitted asynchronous call. After that it is droppable, and
## each consumer keeps its newest `endedRoutes` droppable records (4096 by
## default), dropping the oldest first. A dropped id is unknown: renew, close
## and materialize get NOT_AUTHORISED, as for an id that never existed
## (l.3157-3159, l.3188); a `request_key` replay still returns its retained
## result (l.3175-3176).
##
## [G171 interim (TF-18)] The order of checks for a Runtime Control request:
## the caller's association (NOT_AUTHORISED), the method's own authority where
## it names no target from the payload, the payload (INVALID_PARAMS), the
## target's authority, then readiness, including whether the caller's binding
## is still current (`originReady`), and last the contract root.
##
## [IMPL] Events and asynchronous calls (step 4). Subscriptions are activated,
## deactivated and admitted here, one handler invocation at a time; the
## handlers run on the publishing thread (`events.nim`). An asynchronous call
## is registered here at submission, with its deadline, and runs on a pool of
## call workers apart from the lifecycle workers (`asynccall.nim`); its
## completion callback, and a deferred provider's `request_cancel`, run on a
## lifecycle worker. A route that ends deactivates its subscriptions and marks
## the invocations admitted through it cancelled; what becomes of their
## results is G174's policy. A realization that ends suppresses the completion
## callbacks of its calls that have not begun.
##
## [IMPL] The host (step 5, `host.nim`). `bootstrap` creates the configured
## instances and answers once the orchestration instance is `ready` or its
## start failed (`checkBootstrap`, G190). Shutdown can be accepted without
## waiting and waited for without initiating it; every waiter gets the one
## result (G60). `tryClose` refuses while module code runs on a worker and
## leaves the Runtime thread running, so it can be tried again.
##
## Not yet built: the other Runtime Control methods, Runtime Control
## subscriptions (G178), remote Runtimes, `recover_module` and
## `retire_module`, and persistence of execution state and routes.

{.push raises: [].}

import
  std/[
    atomics, deques, locks, monotimes, sets, strutils, sysrand, tables, times,
    typedthreads,
  ]
from std/os import sleep
import results
import ../abi/types
import ../base/perthread
import ../cbor/utf8
import ../commitment
import ../iface/[accept, outcome]
import ./[asynccall, bell, bindings, callside, events, invoke, plumbing]

export plumbing

type
  # Runtime-thread state ---------------------------------------------------------
  AttemptPhase = enum
    apBind
    apInit
    apCleanup ## the context made by the attempt is being destroyed
    apDone

  Attempt = ref object
    id: int
    token: string
    inst: Inst
    deadline: MonoTime
    phase: AttemptPhase
    request: RealizeRequest
    handoff: InitHandoff
    cancelled: bool ## an explicit stop or shutdown was ordered after it
    expired: bool ## the startup deadline passed
    failed: bool ## the attempt failed or a failure was reported
    waiters: seq[Waiter]
    services: ptr AttemptServices
      ## its Runtime Control binding and invocation access, until the
      ## realization it made takes them over or its outcome is final

  Waiter = object
    reply: ReplyChannel
    origin: string ## the module instance waiting, empty for the host

  StopWaiter = object
    reply: ReplyChannel
    origin: string

  Inst = ref object
    id: string
    record: ModuleRecord
    state: ModuleState
    failure: Opt[Failure]
    revision: uint64
    intent: Intent
    intentRevision: uint64
    intentOrigin: Origin
    attempt: Attempt ## the attempt in progress or being cleaned, if any
    realization: Realization ## the live realization, if any
    teardown: int ## the destroy job for `realization`, if any
    tokens: HashSet[string] ## every attempt token issued for the instance
    current: string ## the token of the realization that is current
    provider: bool
    keepIntent: bool ## the stop in progress is a shutdown stop
    stopWaiters: seq[StopWaiter]
    stopDeadline: Opt[MonoTime]
      ## [G61] while `stopping` after an explicit stop: when its cleanup failure
      ## is recorded
    providerId: string ## its provider record, when its record expects a contract
    services: ptr AttemptServices ## those of `realization`
    inflight: int
      ## route calls admitted into `realization` and not yet left, deferred
      ## invocations included until they are idle (INTERFACE l.2155-2158)
    releasePending: bool ## `realization` is released once `inflight` is zero
    orchestration: bool ## [G53] the instance the bootstrap input names

  AsyncRec = ref object
    ## One submitted asynchronous call, from submission until nothing of it
    ## runs any more; it holds one reference to the call.
    call: pointer
    rc: bool
    consumer: string
    attempt: string
    route: string
    deadline: Opt[MonoTime]
    ticket: ptr CallTicket ## once admitted into a provider
    provider: string ## the provider instance it was admitted into
    deferred: pointer ## the deferred invocation, until it is idle
    cancelled: bool ## its invocation was marked cancelled
    terminal: bool ## the Runtime thread knows its terminal outcome
    executing: bool ## a call worker has it
    completing: bool ## its completion job is dispatched

  State = ref object
    shared: ptr Shared
    cfg: EngineConfig
    realizer: Realizer
    authorizer: Authorizer
    instances: OrderedTable[string, Inst]
    attempts: Table[int, Attempt] ## by job id (bind and init jobs)
    teardowns: Table[int, Inst] ## by job id (destroy jobs)
    nextJob: int
    busy: int ## jobs dispatched and not yet answered
    serial: uint64
    changes: seq[StateChange]
    prefix: string
    created: int
    shuttingDown: bool
    shutdownDeadline: MonoTime
    shutdownWaiters: seq[ReplyChannel]
    shutdownDone: bool
    shutdownResult: Opt[EngineError] ## [G60] set when shutdown completes
    bootstrapped: bool ## a bootstrap was requested
    bootstrapReply: ReplyChannel ## the bootstrap waiting for its outcome
    orchestrator: Inst ## the orchestration instance, once bootstrapped
    done: bool ## `close` asked the Runtime thread to leave
    runtimeId: string
    ctx: SchemaContext ## the pinned context, for the well-known methods
    routes: OrderedTable[string, Route]
      ## every route not yet compacted away, in creation order [IMPL]
    ended: Table[string, Deque[string]]
      ## per consumer: its droppable route records, oldest first
    dropped: int ## dropped records still in `routes`
    keys: RequestKeys
    routeCount: int
    providerCount: int
    asyncCalls: Table[pointer, AsyncRec] ## by call
    callBusy: int ## call jobs dispatched and not yet answered
    liveAttempts: HashSet[string]
      ## attempt tokens whose bindings are valid: from acceptance until the
      ## context they made is destroyed, or their outcome is final
    diagnostics: Deque[string]

proc workerLoop(s: ptr Shared) =
  while true:
    var job: Job
    try:
      job = s.jobs.recv()
    except Exception:
      return
    case job.kind
    of jkQuit:
      return
    of jkBind:
      s.post(Msg(kind: mkBound, job: job.id, bound: runBind(job.spec)))
    of jkInit:
      let (res, ctx) = initModule(job.init, job.input)
      s.post(Msg(kind: mkInitialized, job: job.id, res: res, context: ctx))
    of jkDestroy:
      job.destroy(job.context)
      s.post(Msg(kind: mkDestroyed, job: job.id))
    of jkObserveEnd:
      runEnd(job.handle)
      s.post(Msg(kind: mkJobDone, job: job.id))
    of jkComplete:
      runComplete(job.call)
      s.post(Msg(kind: mkCompleted, job: job.id, target: job.call))
    of jkRequestCancel:
      runRequestCancel(job.deferred)
      s.post(Msg(kind: mkJobDone, job: job.id))

proc workerMain(s: ptr Shared) {.thread.} =
  markRuntimeThread()
  workerLoop(s)
  releasePerThread() # after the loop's locals are gone

proc callWorkerLoop(s: ptr Shared) =
  while true:
    var job: CallJob
    try:
      job = s.calls.recv()
    except Exception:
      return
    case job.kind
    of cjQuit:
      return
    of cjRun:
      runCall(job.call)
      s.post(Msg(kind: mkCallJobDone, target: job.call))

proc callWorkerMain(s: ptr Shared) {.thread.} =
  markRuntimeThread()
  callWorkerLoop(s)
  releasePerThread()

proc dispatch(st: State, job: sink Job) =
  inc st.busy
  let s = st.shared
  if st.busy > s.spawned and s.spawned < MaxWorkers:
    try:
      createThread(s.workers[s.spawned], workerMain, s)
      inc s.spawned
    except ResourceExhaustedError:
      discard # the job waits for a busy worker
  try:
    s.jobs.send(job)
  except Exception:
    discard

proc nextJobId(st: State): int =
  inc st.nextJob
  st.nextJob

proc dispatchCall(st: State, call: pointer) =
  ## A call worker for one submitted call; spawned on demand.
  inc st.callBusy
  let s = st.shared
  if st.callBusy > s.callSpawned and s.callSpawned < MaxCallWorkers:
    try:
      createThread(s.callWorkers[s.callSpawned], callWorkerMain, s)
      inc s.callSpawned
    except ResourceExhaustedError:
      discard # the call waits for a busy call worker
  try:
    s.calls.send(CallJob(kind: cjRun, call: call))
  except Exception:
    discard

proc diagnose(st: State, text: string) =
  ## [SPEC RUNTIME l.1227] Kept for observation, the oldest dropped first.
  if st.diagnostics.len >= MaxDiagnostics:
    st.diagnostics.popFirst()
  st.diagnostics.addLast(text)

# Observation --------------------------------------------------------------------

func view(x: Inst): InstanceView =
  result = InstanceView(
    instance: x.id,
    module: x.record.module,
    state: x.state,
    failure: x.failure,
    execution: ExecutionState(revision: x.revision, intent: x.intent),
    stateAssignment: x.record.stateAssignment,
    primaryContract: x.record.primaryContract,
    implements: x.record.implements,
    provider: x.provider,
    providerId: x.providerId,
    attempt: x.current,
    orchestration: x.orchestration,
  )
  if x.intent == inRequested:
    result.execution.intentRevision = Opt.some(x.intentRevision)
    result.intentOrigin = x.intentOrigin

proc answer(r: ReplyChannel, reply: sink Reply) =
  if r != nil:
    try:
      r[].send(reply)
    except Exception:
      discard

proc answerView(r: ReplyChannel, x: Inst) =
  r.answer(Reply(view: x.view))

proc answerError(r: ReplyChannel, code: ErrorCode, message: string) =
  r.answer(Reply(error: Opt.some(engineError(code, message))))

# Asynchronous calls ---------------------------------------------------------------

proc newTicket(): ptr CallTicket =
  result = createShared(CallTicket)
  initLock(result.lock)

proc freeTicket(t: ptr CallTicket) =
  deinitLock(t.lock)
  freeShared(t)

proc cancelInvocation(st: State, a: AsyncRec) =
  ## [SPEC INTERFACE l.2101-2102, l.2143-2150] Sticky; a deferred invocation
  ## gets its `request_cancel` once that is due.
  if a.cancelled:
    return
  a.cancelled = true
  if a.ticket != nil:
    a.ticket.cancelled.store(true)
  if a.deferred != nil and cancelKnown(a.deferred):
    st.dispatch(Job(id: st.nextJobId(), kind: jkRequestCancel, deferred: a.deferred))

proc route(st: State, id: string): Route =
  ## The record of route `id`, or nil when it is unknown or dropped.
  result = st.routes.getOrDefault(id)
  if result != nil and result.dropped:
    result = nil

proc settle(st: State, r: Route) =
  ## [IMPL] An ended route that nothing reaches any more joins its consumer's
  ## droppable records; past `endedRoutes` of them, the oldest is dropped.
  if r == nil or r.droppable or not r.isTerminal or r.reachable:
    return
  r.droppable = true
  let q = addr st.ended.mgetOrPut(r.consumer, initDeque[string]())
  q[].addLast(r.id)
  while q[].len > max(st.cfg.endedRoutes, 0):
    let old = st.routes.getOrDefault(q[].popFirst())
    if old != nil and not old.dropped:
      old.dropped = true
      inc st.dropped

proc compactRoutes(st: State) =
  ## Dropped records leave the creation-ordered table in batches, once they
  ## are an eighth of it, so each drop costs amortized constant time.
  if st.dropped > 0 and st.dropped * 8 >= st.routes.len:
    var kept = initOrderedTable[string, Route]()
    for id, r in st.routes:
      if not r.dropped:
        kept[id] = r
    st.routes = move kept
    st.dropped = 0

proc maybeForget(st: State, a: AsyncRec) =
  ## The record goes, with its reference to the call, once nothing of the
  ## call runs any more.
  if a.terminal and not a.executing and not a.completing and a.deferred == nil:
    st.asyncCalls.del(a.call)
    dropCall(asyncOf(a.call))
    if not a.rc:
      let r = st.route(a.route)
      if r != nil:
        dec r.pending
        st.settle(r)

proc asyncTerminal(st: State, a: AsyncRec) =
  ## The call's terminal outcome is decided: its invocation-scoped destination
  ## closes (RUNTIME l.1281); a cancellation, a timeout or an end also cancels
  ## the invocation; the completion callback runs on a worker while the
  ## consumer's realization lasts, and is suppressed after it [IMPL].
  if a.terminal:
    return
  a.terminal = true
  a.deadline = Opt.none(MonoTime)
  let c = asyncOf(a.call)
  if a.ticket != nil:
    a.ticket.closed.store(true)
  if c.callEnd != okResult:
    st.cancelInvocation(a)
  if a.attempt in st.liveAttempts:
    a.completing = true
    st.dispatch(Job(id: st.nextJobId(), kind: jkComplete, call: a.call))
  else:
    c.suppress()
  st.maybeForget(a)

proc endCall(st: State, a: AsyncRec, f: InvocationFailure, kind: CallEnd) =
  ## A terminal decision the Runtime thread makes: a timeout, or the end of
  ## the call's route or of a realization [G174].
  if not a.terminal and asyncOf(a.call).decide(f, kind):
    st.asyncTerminal(a)

proc records(st: State): seq[AsyncRec] =
  for a in st.asyncCalls.values:
    result.add(a)

proc endServices(st: State, s: ptr AttemptServices, instance: string) =
  ## The realization an attempt made is gone, or the attempt made none: its
  ## bindings are invalid. Its calls are cancelled and their completions not
  ## yet begun suppressed; calls admitted into it as a provider and still
  ## without an outcome end NOT_READY, the bound of G174.
  if s == nil:
    return
  let token = attemptOf(s)
  st.liveAttempts.excl(token)
  # [SPEC INTERFACE l.2004-2006] None of the attempt's handles remains valid.
  for r in st.routes.values:
    if r.consumer == instance and r.pins.len > 0:
      var kept: seq[Pin]
      for p in r.pins:
        if p.attempt != token:
          kept.add(p)
      r.pins = kept
      st.settle(r)
  for a in st.records:
    if a.attempt == token:
      st.cancelInvocation(a)
      if a.terminal:
        asyncOf(a.call).suppress()
      else:
        st.endCall(a, failure(ecNotReady, "the consumer's realization ended"), okEnded)
    elif a.provider == instance and not a.terminal:
      st.endCall(a, failure(ecNotReady, "the provider's realization ended"), okEnded)

proc endRoute(st: State, r: Route, state: RouteState, failure: Opt[RouteFailureCode]) =
  ## [SPEC RUNTIME §7.5, §9.3 l.3226-3229; INTERFACE §2.5] The route takes no
  ## new calls, its subscriptions are deactivated, and each handle observing
  ## it gets its terminal callback once, on a worker. [G174] The invocations
  ## admitted through it are marked cancelled (INTERFACE l.2101-2102) and
  ## learn its end cause under their ticket's lock; a revoked route ends its
  ## asynchronous calls NOT_AUTHORISED at once, a closed or failed one lets
  ## them complete.
  if r.isTerminal:
    return
  r.terminate(state, failure)
  for t in r.calls:
    let ticket = cast[ptr CallTicket](t)
    withLock ticket.lock:
      ticket.endCode = ord(r.endCode)
    ticket.cancelled.store(true)
  for p in r.subs:
    deactivate(subOf(p))
  for a in st.records:
    if not a.rc and a.route == r.id:
      st.cancelInvocation(a)
      if r.state == rtRevoked:
        st.endCall(a, revokedResult(), okEnded)
  for h in r.handles:
    scheduleEnd(h, r.endCode)
    st.dispatch(Job(id: st.nextJobId(), kind: jkObserveEnd, handle: h))
  r.handles.setLen(0)
  st.settle(r)

proc routesFollow(st: State, x: Inst) =
  ## [SPEC RUNTIME §3.4 l.620-626, §9.3 l.3225] A provider that is no longer
  ## `ready` fails its routes; a consumer that is no longer live closes its
  ## routes after an authorized stop and fails them after a failure.
  for r in st.routes.values:
    if r.isTerminal:
      continue
    if r.providerInstance == x.id and x.state != msReady:
      st.endRoute(r, rtFailed, Opt.some(rfProviderUnavailable))
    elif r.consumer == x.id and x.state notin {msLoaded, msReady}:
      if x.state == msError:
        st.endRoute(r, rtFailed, Opt.some(rfConsumerUnavailable))
      else:
        st.endRoute(r, rtClosed, Opt.none(RouteFailureCode))

proc releaseCallers(st: State, x: Inst) =
  ## [IMPL] Runtime Control calls of `x` still waiting for another instance
  ## (`start_module`, `stop_module`) end with NOT_READY once its binding is
  ## invalidated (§3.4 l.629-631), so its threads can return.
  for y in st.instances.values:
    if y.attempt != nil:
      var kept: seq[Waiter]
      for w in y.attempt.waiters:
        if w.origin == x.id:
          w.reply.answerError(ecNotReady, "the Runtime Control binding is invalidated")
        else:
          kept.add(w)
      y.attempt.waiters = kept
    var kept: seq[StopWaiter]
    for w in y.stopWaiters:
      if w.origin == x.id:
        w.reply.answerError(ecNotReady, "the Runtime Control binding is invalidated")
      else:
        kept.add(w)
    y.stopWaiters = kept

proc commit(st: State, x: Inst) =
  ## Records one committed change: the execution revision advances (§9.3
  ## l.3504-3505) and the change joins the ordered log (§9.1 l.1851). The
  ## routes that depend on the instance follow it in the same step.
  inc x.revision
  inc st.serial
  if x.state != msStopping:
    x.stopDeadline = Opt.none(MonoTime)
  if st.changes.len >= MaxRetainedChanges:
    st.changes.delete(0)
  st.changes.add(StateChange(serial: st.serial, view: x.view))
  st.routesFollow(x)
  if x.state notin {msLoaded, msReady}:
    st.releaseCallers(x)

# Lifecycle ----------------------------------------------------------------------

proc releaseWaiters(st: State, x: Inst) =
  ## Stop requests wait for `unloaded`.
  if x.state in {msUnloaded, msError}:
    for w in x.stopWaiters:
      w.reply.answerView(x)
    x.stopWaiters.setLen(0)

proc finishAttempt(st: State, a: Attempt) =
  ## The attempt has nothing left to clean: its outcome is final.
  let x = a.inst
  a.phase = apDone
  st.endServices(a.services, x.id)
  freeAttemptServices(a.services)
  a.services = nil
  for w in a.waiters:
    w.reply.answerView(x)
  a.waiters.setLen(0)
  if x.attempt == a:
    x.attempt = nil
  if a.cancelled and x.state == msStopping:
    # [SPEC RUNTIME §3.4] A completed explicit stop: `unloaded`, failure
    # cleared. A stop whose deadline passed already left `error`, which the end
    # of its cleanup does not change (l.611).
    x.state = msUnloaded
    x.failure = Opt.none(Failure)
    x.current = ""
    st.commit(x)
  st.releaseWaiters(x)

proc failAttempt(st: State, a: Attempt, f: Failure) =
  ## [SPEC RUNTIME §3.4, §10.2] The attempt cannot make the instance ready.
  ## Unless a stop already owns the outcome, the instance enters `error` now.
  let x = a.inst
  if a.cancelled or a.expired or a.failed:
    return
  a.failed = true
  x.state = msError
  x.failure = Opt.some(f)
  x.provider = false
  st.commit(x)
  for w in a.waiters:
    w.reply.answerView(x)
  a.waiters.setLen(0)

proc destroyContext(st: State, a: Attempt, ctx: ptr LogosModuleContext) =
  ## A context the attempt made that must not become ready.
  a.phase = apCleanup
  let id = st.nextJobId()
  st.attempts[id] = a
  st.dispatch(
    Job(id: id, kind: jkDestroy, destroy: a.handoff.binding.destroy, context: ctx)
  )

proc releaseRealization(st: State, x: Inst) =
  ## [SPEC RUNTIME §10.2 step 4] Graceful release through the realizer: one
  ## `_MODULE_destroy` on a worker, then the record is gone.
  let r = x.realization
  if r.isNil or x.teardown != 0:
    return
  if x.inflight > 0:
    # [IMPL] Calls already inside the provider finish first (§3.4 l.623).
    x.releasePending = true
    return
  x.releasePending = false
  let t = st.realizer.beginRelease(r.id, x.id).valueOr:
    x.realization = nil
    return
  if t.isNone:
    st.realizer.finishRelease(x.id)
    x.realization = nil
    return
  let id = st.nextJobId()
  x.teardown = id
  st.teardowns[id] = x
  st.dispatch(
    Job(id: id, kind: jkDestroy, destroy: t.get.destroy, context: t.get.context)
  )

proc loaderFailure(e: LoaderError): Failure =
  ## [SPEC RUNTIME §9.3 l.3753-3754] `_MODULE_init()` failing is the more
  ## specific `initialization-failed`; any other Loader error is
  ## `loader-<code>`.
  if e.code == lecRealizationFailed and e.cause.isSome:
    Failure(kind: fkInitializationFailed, reason: e.message)
  else:
    Failure(kind: fkLoader, loader: e.code, reason: e.message)

proc checkContracts(x: Inst, r: Realization): Result[bool, string] =
  ## [SPEC RUNTIME §3.3, §3.6] The expected contracts against the validated
  ## call surface. Returns whether the instance exposes a provider view.
  let rec = x.record
  if rec.primaryContract.isNone and rec.implements.len == 0:
    # [SPEC RUNTIME §8 l.1423-1425] No declared contract: no provider record,
    # whatever the module exports.
    return ok(false)
  let b = r.binding
  if not b.provider:
    return err("the module exposes no call surface")
  if rec.primaryContract.isSome:
    if b.contracts.primary.isNone or
        b.contracts.primary.get.root != rec.primaryContract.get:
      return err("the primary contract differs from the expected one")
  for c in rec.implements:
    var found = false
    for i in b.contracts.interfaces:
      if i.root == c:
        found = true
    if not found:
      return err("an expected interface contract is not implemented")
  ok(true)

proc initialized(st: State, a: Attempt, res: LogosResult, ctx: ptr LogosModuleContext) =
  let x = a.inst
  var orphan: ptr LogosModuleContext
  let made = st.realizer.completeInit(a.handoff, res, ctx, orphan)
  if made.isErr:
    st.failAttempt(a, loaderFailure(made.error))
    if orphan != nil:
      st.destroyContext(a, orphan)
    else:
      st.finishAttempt(a)
    return
  let r = made.get
  x.realization = r
  if a.cancelled or a.expired or a.failed:
    # [SPEC RUNTIME §3.4 l.668] A valid context after expiry, a stop or a
    # reported failure is cleaned through the mechanism that made it.
    a.phase = apCleanup
    st.releaseRealization(x)
    return
  let provider = x.checkContracts(r).valueOr:
    st.failAttempt(a, Failure(kind: fkInitializationFailed, reason: error))
    a.phase = apCleanup
    st.releaseRealization(x)
    return
  # [SPEC RUNTIME §3.4] Every lifecycle and realization check succeeded.
  x.services = a.services
  a.services = nil
  x.provider = provider
  x.state = msReady
  st.commit(x)
  st.finishAttempt(a)

proc beginInit(st: State, a: Attempt, b: ref NativeBinding) =
  if a.cancelled or a.expired or a.failed:
    st.finishAttempt(a)
    return
  let h = st.realizer.prepareInit(a.request, b).valueOr:
    st.failAttempt(a, loaderFailure(error))
    st.finishAttempt(a)
    return
  a.handoff = h
  a.phase = apInit
  let id = st.nextJobId()
  st.attempts[id] = a
  st.dispatch(Job(id: id, kind: jkInit, init: b.init, input: addr h.input))

proc bound(st: State, a: Attempt, res: sink BindResult) =
  let b = st.realizer.storeBinding(res)
  if b.isErr:
    st.failAttempt(a, loaderFailure(b.error))
    st.finishAttempt(a)
    return
  st.beginInit(a, b.get)

proc prerequisitesReady(st: State, x: Inst): bool =
  for (pre, dep) in st.cfg.ordering:
    if dep == x.id:
      let p = st.instances.getOrDefault(pre)
      if p.isNil or p.state != msReady:
        return false
  true

proc authorize(st: State, q: AuthzRequest): Opt[EngineError] =
  ## [SPEC RUNTIME §9] An evaluation failure fails closed like a deny; the
  ## retained answer keeps them apart (l.1740-1744).
  let a = st.authorizer.decide(q)
  if a.outcome == azAllow:
    Opt.none(EngineError)
  else:
    Opt.some(engineError(ecNotAuthorised, "not authorised"))

proc lookup(st: State, q: Request, operation: string): Result[Inst, EngineError] =
  ## [SPEC RUNTIME §9.3 l.3661-3662] For a module consumer, an unknown target
  ## and a refused one are the same NOT_AUTHORISED; a module-name mismatch is
  ## INVALID_PARAMS only after authorization (l.3663-3664).
  let x = st.instances.getOrDefault(q.instance)
  if not q.origin.host:
    let denied = st.authorize(
      AuthzRequest(
        action: aaLifecycle,
        operation: operation,
        consumer: q.origin.instance,
        target: q.instance,
        module: (if x.isNil: "" else: x.record.module),
      )
    )
    if denied.isSome:
      return err(denied.get)
    if x.isNil:
      return err(engineError(ecNotAuthorised, "not authorised"))
  if x.isNil:
    return err(engineError(ecInvalidParams, "unknown module instance"))
  if q.module.len > 0 and q.module != x.record.module:
    return err(engineError(ecInvalidParams, "the module name does not match"))
  if q.expectedRevision.isSome and q.expectedRevision.get != x.revision:
    # [SPEC RUNTIME §9.1 l.1832-1833] compared atomically with acceptance
    return err(engineError(ecInvalidParams, "execution revision mismatch"))
  ok(x)

proc originReady(st: State, q: Request): Opt[EngineError] =
  ## [SPEC RUNTIME §3.4 l.629-631, §10.2; G171 interim (TF-18)] Checked after
  ## the request's authorization: a Runtime Control binding that is
  ## invalidated, or a Runtime that is shutting down, is NOT_READY. A request
  ## that comes through no binding (the host API) has only the second.
  if q.attempt.len > 0:
    let x = st.instances.getOrDefault(q.origin.instance)
    if x.isNil or q.attempt != x.current or x.state notin {msLoaded, msReady}:
      return
        Opt.some(engineError(ecNotReady, "the Runtime Control binding is invalidated"))
  if st.shuttingDown:
    return Opt.some(engineError(ecNotReady, "the Runtime is shutting down"))
  Opt.none(EngineError)

template requireReady(st: State, q: Request) =
  let notReady = st.originReady(q)
  if notReady.isSome:
    q.reply.answerError(notReady.get.code, notReady.get.message)
    return

proc start(st: State, q: Request) =
  ## [SPEC RUNTIME §9.1, §9.3 start_module; §3.6] Replies once the attempt
  ## is ready or failed, or once its deadline passed.
  let x = st.lookup(q, "start_module").valueOr:
    q.reply.answerError(error.code, error.message)
    return
  st.requireReady(q)
  case x.state
  of msLoaded, msReady:
    q.reply.answerView(x) # §9.1 l.1837: no new realization, intent unchanged
    return
  of msStopping:
    q.reply.answerError(ecNotReady, "the module instance is stopping")
    return
  of msError:
    if x.attempt != nil or x.teardown != 0 or x.realization != nil:
      # [SPEC RUNTIME §3.4 l.587-588] intent and origin unchanged
      q.reply.answerError(ecNotReady, "cleanup of the previous realization is pending")
      return
  of msUnloaded:
    discard
  # [SPEC RUNTIME §9.3 l.3644-3647] Acceptance establishes `requested` intent
  # with this origin, before execution authorization or startup.
  x.intent = inRequested
  x.intentOrigin = q.origin
  x.intentRevision = x.revision + 1
  st.commit(x)
  if not st.prerequisitesReady(x):
    # [SPEC RUNTIME §3.7, §10.1] A dependent waits for every prerequisite.
    q.reply.answerError(ecNotReady, "a lifecycle prerequisite is not ready")
    return
  # [SPEC RUNTIME §3.6 step 3] Execution authorization, for the retained
  # origin, before any artifact code runs.
  let ans = st.authorizer.decide(
    AuthzRequest(
      action: aaExecute,
      operation: "execute",
      consumer: (if x.intentOrigin.host: "" else: x.intentOrigin.instance),
      target: x.id,
      module: x.record.module,
    )
  )
  if ans.outcome != azAllow:
    # [G168 interim] NOT_AUTHORISED; the state stays, the failure records why
    # and intent stays `requested` with its origin.
    x.failure = Opt.some(
      Failure(
        kind: (
          if ans.outcome == azDeny: fkAuthorityDenied else: fkAuthorityEvaluationFailed
        )
      )
    )
    st.commit(x)
    q.reply.answerError(ecNotAuthorised, "execution is not authorised")
    return
  # The attempt is accepted: `loaded`, failure cleared (§9.3 l.3758-3759).
  let id = st.nextJobId()
  let a = Attempt(
    id: id,
    token: "a-" & st.prefix & "-" & $id,
    inst: x,
    deadline: getMonoTime() + st.cfg.startupDeadline,
    waiters: @[Waiter(reply: q.reply, origin: q.origin.instance)],
  )
  x.tokens.incl(a.token)
  x.current = a.token
  var services = InitServices()
  a.services = newAttemptServices(st.shared, x.id, a.token)
  services.fill(a.services)
  st.liveAttempts.incl(a.token)
  a.request = RealizeRequest(
    moduleInstance: x.id,
    descriptor: x.record.descriptor,
    state: x.record.stateAssignment,
    services: services,
  )
  x.attempt = a
  x.state = msLoaded
  x.failure = Opt.none(Failure)
  x.provider = false
  st.commit(x)
  let step = st.realizer.begin(a.request).valueOr:
    st.failAttempt(a, loaderFailure(error))
    st.finishAttempt(a)
    return
  case step.kind
  of skLive:
    st.failAttempt(a, Failure(kind: fkOther, reason: "a stale realization remains"))
    st.finishAttempt(a)
  of skBind:
    a.phase = apBind
    st.attempts[id] = a
    st.dispatch(Job(id: id, kind: jkBind, spec: step.spec))
  of skInit:
    st.beginInit(a, step.binding)

proc stopInstance(
    st: State, x: Inst, reply: ReplyChannel, keepIntent: bool, origin = ""
) =
  ## [SPEC RUNTIME §3.4, §9.1, §10.2] Moves `x` toward `unloaded`; replies
  ## once it is there, or once the stop deadline passes and the instance is
  ## `error` with `cleanup-timeout` [G61].
  if not keepIntent and x.intent != inStopped:
    # [SPEC RUNTIME §9.1 l.1839] An explicit stop cancels retained intent.
    x.intent = inStopped
    st.commit(x)
  case x.state
  of msUnloaded, msStopping:
    reply.answerView(x)
    return
  of msLoaded:
    # [SPEC RUNTIME §9.1 l.1840-1841] The incomplete start can no longer make
    # the instance ready; its outcome is cleaned, then `unloaded`.
    x.attempt.cancelled = true
    x.state = msStopping
    st.commit(x)
    for w in x.attempt.waiters:
      w.reply.answerView(x)
    x.attempt.waiters.setLen(0)
  of msReady:
    x.state = msStopping
    x.provider = false
    st.commit(x)
    st.releaseRealization(x)
  of msError:
    if x.attempt != nil:
      x.attempt.cancelled = true
      x.state = msStopping
      st.commit(x)
    elif x.teardown != 0 or x.realization != nil:
      x.state = msStopping
      st.commit(x)
    else:
      x.state = msUnloaded
      x.failure = Opt.none(Failure)
      x.current = ""
      st.commit(x)
      reply.answerView(x)
      return
  if x.state == msStopping and x.teardown == 0 and x.attempt.isNil and
      x.realization.isNil:
    x.state = msUnloaded
    x.failure = Opt.none(Failure)
    x.current = ""
    st.commit(x)
  if x.state == msUnloaded:
    reply.answerView(x)
    return
  if not keepIntent:
    # [G61, revised by A18] The drain deadline of an explicit stop starts
    # when the instance enters `stopping`; shutdown has its own grace.
    x.stopDeadline = Opt.some(getMonoTime() + st.cfg.stopDeadline)
  if reply != nil:
    x.stopWaiters.add(StopWaiter(reply: reply, origin: origin))

proc callsInto(st: State, consumer, provider: string): bool =
  ## Whether `consumer` has an admitted call in progress through a route to
  ## `provider`.
  for r in st.routes.values:
    if r.consumer == consumer and r.providerInstance == provider and r.calls.len > 0:
      return true
  false

proc stop(st: State, q: Request) =
  ## [SPEC RUNTIME §9.1, §9.3 stop_module]
  let x = st.lookup(q, "stop_module").valueOr:
    q.reply.answerError(error.code, error.message)
    return
  st.requireReady(q)
  if not q.origin.host and
      (q.origin.instance == x.id or st.callsInto(q.origin.instance, x.id)):
    # [G173 interim (TF-20)] A module that stops itself, or that has a call in
    # progress in the target, gets the state at once: waiting would hold that
    # call, and so the target's release (l.3687 permits `stopping`).
    st.stopInstance(x, nil, keepIntent = false)
    q.reply.answerView(x)
    return
  st.stopInstance(x, q.reply, keepIntent = false, q.origin.instance)

proc reportFailure(st: State, q: Request, success = Reply()) =
  ## [SPEC RUNTIME §9.3 report_failure] Authorized by the realization-bound
  ## association alone; the reply does not wait for cleanup.
  let x = st.instances.getOrDefault(q.instance)
  if x.isNil or q.attempt notin x.tokens:
    q.reply.answerError(ecNotAuthorised, "no realization-bound association")
    return
  if q.attempt != x.current or x.state notin {msLoaded, msReady}:
    q.reply.answerError(ecNotReady, "the realization is not current")
    return
  let f = Failure(kind: fkReportedByModule, reason: q.reason)
  if x.state == msLoaded:
    # [SPEC RUNTIME §9.3 l.3604] A report during initialization keeps that
    # realization from becoming ready.
    st.failAttempt(x.attempt, f)
  else:
    x.state = msError
    x.failure = Opt.some(f)
    x.provider = false
    st.commit(x)
    st.releaseRealization(x)
  q.reply.answer(success)

proc createInst(
    st: State, record: ModuleRecord, instance: string, origin: Origin
): Result[Inst, EngineError] =
  ## A local module-instance record: `unloaded`, intent `uninitialized`
  ## (§9.3 l.3623). The slice takes records from the host only (G55).
  if st.shuttingDown:
    return err(engineError(ecNotReady, "the Runtime is shutting down"))
  if not origin.host:
    return err(engineError(ecNotAuthorised, "not authorised"))
  checkRecord(record).isOkOr:
    return err(engineError(ecInvalidParams, error))
  var id = instance
  if id.len == 0:
    inc st.created
    id = "m-" & st.prefix & "-" & $st.created
  elif id.len > MaxInstanceIdBytes or not isValidUtf8(id):
    return
      err(engineError(ecInvalidParams, "an instance id must have 1 to 128 UTF-8 bytes"))
  if id in st.instances:
    return err(engineError(ecInvalidParams, "the instance id is already in use"))
  if record.stateAssignment.isSome:
    for y in st.instances.values:
      if y.record.stateAssignment == record.stateAssignment:
        # [SPEC RUNTIME §8 l.1468] no shared state assignment by default
        return err(engineError(ecInvalidParams, "the state assignment is in use"))
  let x = Inst(id: id, record: record, state: msUnloaded, intent: inUninitialized)
  if record.primaryContract.isSome or record.implements.len > 0:
    # [SPEC RUNTIME §9.3 l.2862-2871] Its provider record, kept across stop
    # and start [IMPL: one per instance].
    inc st.providerCount
    x.providerId = "p-" & st.prefix & "-" & $st.providerCount
  st.instances[id] = x
  st.commit(x)
  ok(x)

proc create(st: State, q: Request) =
  let x = st.createInst(q.record, q.instance, q.origin).valueOr:
    q.reply.answerError(error.code, error.message)
    return
  q.reply.answerView(x)

# Shutdown -----------------------------------------------------------------------

proc shutdownStep(st: State) =
  ## [SPEC RUNTIME §10.2 step 3] Releases dependents before prerequisites, in
  ## reverse creation order otherwise; execution intent is preserved.
  var progress = true
  while progress:
    progress = false
    var order: seq[Inst]
    for x in st.instances.values:
      order.insert(x, 0)
    for x in order:
      if x.state in {msUnloaded, msStopping}:
        continue
      if x.state == msError and x.attempt.isNil and x.teardown == 0 and
          x.realization.isNil:
        continue
      var dependentLive = false
      for (pre, dep) in st.cfg.ordering:
        if pre == x.id:
          let d = st.instances.getOrDefault(dep)
          if not d.isNil and d.state notin {msUnloaded, msError}:
            dependentLive = true
      if not dependentLive:
        st.stopInstance(x, nil, keepIntent = true)
        progress = true

proc shutdownComplete(st: State): bool =
  for x in st.instances.values:
    if x.state in {msLoaded, msReady, msStopping}:
      return false
  true

proc shutdownOutcome(st: State): Opt[EngineError] =
  ## [G60, made precise] Shutdown completed with every realization released,
  ## or with some cleanup unresolved or failed: an attempt or a release still
  ## outstanding, `cleanup-timeout` or `cleanup-failed`. The second is
  ## MODULE_ERROR, naming the instances.
  var unresolved: seq[string]
  for x in st.instances.values:
    let failed =
      x.failure.isSome and x.failure.get.kind in {fkCleanupTimeout, fkCleanupFailed}
    if failed or x.attempt != nil or x.teardown != 0 or x.realization != nil:
      unresolved.add(x.id)
  if unresolved.len == 0:
    Opt.none(EngineError)
  else:
    Opt.some(
      engineError(
        ecModule,
        "shutdown completed with cleanup unresolved or failed: " & unresolved.join(", "),
      )
    )

proc finishShutdown(st: State) =
  ## [IMPL] The Runtime thread keeps running after shutdown: it refuses new
  ## lifecycle requests and still cleans contexts that module code returns
  ## late, until `close`. Every waiter gets the one stored result (RUN-0760).
  st.shutdownResult = st.shutdownOutcome()
  st.shutdownDone = true
  for w in st.shutdownWaiters:
    w.answer(Reply(error: st.shutdownResult))
  st.shutdownWaiters.setLen(0)

proc beginShutdown(st: State) =
  ## [SPEC RUNTIME §10.2] Admission closes first; one sequence for every
  ## accepted request.
  if not st.shuttingDown:
    st.shuttingDown = true
    st.shutdownDeadline = getMonoTime() + st.cfg.shutdownGrace
  st.shutdownStep()
  if st.shutdownComplete():
    st.finishShutdown()

# Runtime Control ----------------------------------------------------------------

proc denied(st: State, q: AuthzRequest): bool =
  st.authorizer.decide(q).outcome != azAllow

proc answerEncoded(r: ReplyChannel, bytes: Result[seq[byte], string]) =
  if bytes.isErr:
    r.answerError(ecModule, "the response cannot be encoded")
  else:
    r.answer(Reply(bytes: bytes.get))

proc caller(st: State, q: Request): Result[Inst, EngineError] =
  ## [SPEC RUNTIME §9.3 l.2553-2560] The module consumer a binding
  ## authenticates; none is NOT_AUTHORISED. Whether the binding is still
  ## usable is checked after the method's authorization (`originReady`).
  let x = st.instances.getOrDefault(q.origin.instance)
  if x.isNil or q.attempt notin x.tokens:
    return err(engineError(ecNotAuthorised, "no authenticated module consumer"))
  ok(x)

proc rcPrecheck(st: State, q: Request) =
  ## [G171 interim (TF-18)] Before a Runtime Control request whose payload
  ## failed validation is answered INVALID_PARAMS: the caller's association,
  ## and the method's authority where it names no target from the payload.
  let x = st.caller(q).valueOr:
    q.reply.answerError(error.code, error.message)
    return
  if q.bare in [$rmEstablishRoute, $rmShutdownRuntime] and
      st.denied(
        AuthzRequest(action: aaRuntimeControl, operation: q.bare, consumer: x.id)
      ):
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  q.reply.answer(Reply())

proc selectLifecycle(
    st: State,
    x: Inst,
    operation, module: string,
    instance: Opt[string],
    provider: Opt[LogosNSRuntimeModuleProviderAddress],
    expected: Opt[uint64],
): Result[string, EngineError] =
  ## [SPEC RUNTIME §9.3 l.3656-3675] The local instance a Runtime Control
  ## `start_module` or `stop_module` request selects. No remote-module facade
  ## exists here, so a provider selector names a local implementation.
  if instance.isSome and provider.isSome:
    return err(engineError(ecInvalidParams, "both selectors are present"))
  if provider.isSome:
    if expected.isSome:
      return err(engineError(ecInvalidParams, "a facade has no execution revision"))
    let p = provider.get
    if p.runtime_instance_id.isSome and p.runtime_instance_id.get != st.runtimeId:
      return err(engineError(ecInvalidParams, "the provider names another Runtime"))
    var owner: Inst
    for y in st.instances.values:
      if y.providerId.len > 0 and y.providerId == p.provider:
        owner = y
    let refused = st.denied(
      AuthzRequest(
        action: aaLifecycle,
        operation: operation,
        consumer: x.id,
        target: p.provider,
        module: (if owner.isNil: "" else: owner.record.module),
      )
    )
    if refused or owner.isNil:
      return err(engineError(ecNotAuthorised, "not authorised"))
    return err(
      engineError(ecInvalidParams, "the provider selector names a local implementation")
    )
  if instance.isSome:
    return ok(instance.get)
  # [SPEC RUNTIME §9.3 l.3666-3670] Observation authority over the whole name
  # scope comes first, whatever the number of matches.
  if st.denied(
    AuthzRequest(
      action: aaObserve, operation: operation, consumer: x.id, module: module
    )
  ):
    return err(engineError(ecNotAuthorised, "not authorised"))
  var found: seq[string]
  for y in st.instances.values:
    if y.record.module == module:
      found.add(y.id)
  if found.len != 1:
    return err(
      engineError(
        ecInvalidParams, "the module name does not select exactly one instance"
      )
    )
  ok(found[0])

proc lifecycleCall(st: State, q: Request, x: Inst) =
  ## `start_module` and `stop_module` through the step 2 paths, with this
  ## module as origin; the reply's view becomes the response.
  var r = q
  # [IMPL] Field by field: Nim 2.2.14 builds a tuple's copy of an `Opt` by
  # resetting a temporary it never initialized (`=wasMoved` reads its
  # discriminator), which UBSan reports.
  let start = q.rc.m == rmStartModule
  let operation = if start: "start_module" else: "stop_module"
  let module = if start: q.rc.start.module else: q.rc.stop.module
  let instance = if start: q.rc.start.instance else: q.rc.stop.instance
  let provider = if start: q.rc.start.provider else: q.rc.stop.provider
  let expected =
    if start:
      q.rc.start.expected_execution_revision
    else:
      q.rc.stop.expected_execution_revision
  let target = st.selectLifecycle(x, operation, module, instance, provider, expected).valueOr:
    q.reply.answerError(error.code, error.message)
    return
  r.instance = target
  r.module = module
  r.expectedRevision = expected
  if start:
    st.start(r)
  else:
    st.stop(r)

func rcState(s: ModuleState): LogosNSRuntimeControlState =
  LogosNSRuntimeControlState(
    kind:
      case s
      of msUnloaded: LogosNSRuntimeControlStateKind.Unloaded
      of msLoaded: LogosNSRuntimeControlStateKind.Loaded
      of msReady: LogosNSRuntimeControlStateKind.Ready
      of msStopping: LogosNSRuntimeControlStateKind.Stopping
      of msError: LogosNSRuntimeControlStateKind.Error
  )

func rcExecution(v: InstanceView): LogosNSRuntimeControlExecutionState =
  LogosNSRuntimeControlExecutionState(
    revision: v.execution.revision,
    intent: LogosNSRuntimeControlExecutionStateIntentChoice(
      kind:
        case v.execution.intent
        of inUninitialized:
          LogosNSRuntimeControlExecutionStateIntentChoiceKind.Uninitialized
        of inRequested:
          LogosNSRuntimeControlExecutionStateIntentChoiceKind.Requested
        of inStopped:
          LogosNSRuntimeControlExecutionStateIntentChoiceKind.Stopped
    ),
    intent_revision: v.execution.intentRevision,
  )

func reasonText(s: string): string =
  ## `logos.runtime_control.reason`: at most 512 bytes, cut at a character
  ## boundary.
  if s.len <= 512:
    return s
  var n = 512
  while n > 0 and (uint8(s[n]) and 0xC0'u8) == 0x80'u8:
    dec n
  s[0 ..< n]

proc readiness(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §9.3 get_readiness, l.3656-3675, l.3494-3496] The
  ## selected local instance's lifecycle and execution state from one
  ## committed snapshot. Selection as for start and stop; the selected record
  ## needs observation authority (aaObserve; G161 interim for name-only
  ## selection).
  let req = q.rc.readiness
  let target = st.selectLifecycle(
    x, $rmGetReadiness, req.module, req.instance, req.provider, Opt.none(uint64)
  ).valueOr:
    q.reply.answerError(error.code, error.message)
    return
  let y = st.instances.getOrDefault(target)
  let refused = st.denied(
    AuthzRequest(
      action: aaObserve,
      operation: $rmGetReadiness,
      consumer: x.id,
      target: target,
      module: (if y.isNil: "" else: y.record.module),
    )
  )
  if refused or y.isNil:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if req.module != y.record.module:
    q.reply.answerError(ecInvalidParams, "the module name does not match")
    return
  st.requireReady(q)
  let v = y.view
  var response = LogosNSRuntimeControlGetReadinessResponse(
    module: v.module,
    instance: Opt.some(v.instance),
    execution: Opt.some(rcExecution(v)),
    state: rcState(v.state),
  )
  if v.failure.isSome:
    response.failure = Opt.some(v.failure.get.classification)
    if v.failure.get.reason.len > 0:
      response.reason = Opt.some(reasonText(v.failure.get.reason))
  q.reply.answerEncoded(encode(response))

proc newRouteId(st: State): string =
  ## [IMPL] Never reused by this engine; the random prefix keeps engines apart
  ## (§9.3 l.3172-3175).
  inc st.routeCount
  "route-" & st.prefix & "-" & $st.routeCount

func expects(y: Inst, root: Digest): bool =
  ## The instance's record expects `root` as its primary contract or as an
  ## implemented interface.
  (y.record.primaryContract.isSome and y.record.primaryContract.get == root) or
    root in y.record.implements

proc establish(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §4.2, §9.3 l.3086-3183] Local direct routes for consumer `x`.
  const op = "establish_route"
  let req = q.rc.establish
  # [SPEC RUNTIME l.1626, l.3138] The method itself; no provider access yet.
  if st.denied(AuthzRequest(action: aaRuntimeControl, operation: op, consumer: x.id)):
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  checkAccessOrder(req.access).isOkOr:
    q.reply.answerError(ecInvalidParams, error)
    return
  let all =
    req.cardinality.kind ==
    LogosNSRuntimeControlProviderRequirementCardinalityKind.All_runtime_visible
  if all and req.provider.isSome:
    q.reply.answerError(
      ecInvalidParams, "a provider selector requires single cardinality"
    )
    return
  let root = toDigest(req.contract.schema_root).valueOr:
    q.reply.answerError(ecInvalidParams, "the contract root is not 32 bytes")
    return
  let replayed = st.keys.replay(x.id, req.request_key, op, q.rc.request).valueOr:
    q.reply.answerError(ecInvalidParams, error)
    return
  if replayed.isSome:
    st.requireReady(q)
    q.reply.answer(Reply(bytes: replayed.get))
    return
  if req.provider.isSome and req.provider.get.runtime_instance_id.isSome and
      req.provider.get.runtime_instance_id.get != st.runtimeId:
    # [IMPL] No remote Runtime is reachable: an unknown target.
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if all and st.denied(AuthzRequest(action: aaDiscover, operation: op, consumer: x.id)):
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  # [SPEC RUNTIME §9.3 l.3088-3112] Candidates: the provider records whose
  # module record expects the contract, in creation order; readiness is
  # applied after the route decision.
  var candidates: seq[Inst]
  for y in st.instances.values:
    if y.providerId.len == 0 or not y.expects(root):
      continue
    if req.provider.isSome and y.providerId != req.provider.get.provider:
      continue
    candidates.add(y)
  if not all and candidates.len > 1:
    # [IMPL] `single` selects first and then authorizes only the selected
    # provider (l.3093-3094): the first ready candidate, else the first.
    var pick = candidates[0]
    for y in candidates:
      if y.state == msReady:
        pick = y
        break
    candidates = @[pick]
  var
    allowed: seq[(Inst, string, AuthzAnswer)]
    omitted = false
    made: seq[Route]
  for y in candidates:
    # [SPEC RUNTIME l.3155] The identifier is allocated before evaluation.
    let id = st.newRouteId()
    let ans = st.authorizer.decide(
      AuthzRequest(
        action: aaRoute,
        operation: op,
        consumer: x.id,
        target: y.providerId,
        route: id,
        module: y.record.module,
      )
    )
    if ans.outcome != azAllow:
      omitted = true
    else:
      allowed.add((y, id, ans))
  if allowed.len == 0:
    # [SPEC RUNTIME l.3157-3159; G169 interim (TF-16)] Nothing the caller may
    # route to: NOT_AUTHORISED, unless a `discover` allow covers the contract
    # and no provider offers it, which the caller may learn.
    let discoverable =
      candidates.len == 0 and (
        all or
        not st.denied(AuthzRequest(action: aaDiscover, operation: op, consumer: x.id))
      )
    if not discoverable:
      q.reply.answerError(ecNotAuthorised, "not authorised")
      return
  st.requireReady(q)
  for (y, id, ans) in allowed:
    let sel =
      if y.state == msReady and y.provider and not y.realization.isNil:
        selectContract(y.realization.binding.contracts, root, st.ctx)
      else:
        Opt.none(SelectedContract)
    if sel.isNone:
      omitted = true
      continue
    checkAccessRoots(req.access, sel.get).isOkOr:
      q.reply.answerError(ecInvalidParams, error)
      return
    made.add(
      Route(
        id: id,
        consumer: x.id,
        provider: y.providerId,
        providerInstance: y.id,
        selected: sel.get,
        access: req.access,
        state: rtReady,
        decisionId: ans.decisionId,
      )
    )
  if made.len == 0:
    # [G169 interim (TF-16)] The caller holds a route allow for a provider, or
    # a `discover` allow and no provider offers the contract.
    q.reply.answerError(ecNotReady, "no selected provider is ready")
    return
  var response = LogosNSRuntimeControlEstablishRouteResponse(partial: all and omitted)
  for r in made:
    st.routes[r.id] = r
    response.routes.add(r.record(st.runtimeId))
  let bytes = encode(response).valueOr:
    q.reply.answerError(ecModule, "the response cannot be encoded")
    return
  st.keys.retain(x.id, req.request_key, op, q.rc.request, bytes)
  q.reply.answer(Reply(bytes: bytes))

proc renew(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §9.3 l.3183-3190, l.3471-3484] A new authority check for
  ## an existing ready route. An allow replaces the decision; a deny makes the
  ## route unusable [G170 interim (TF-17)].
  const op = "renew_route"
  let req = q.rc.renew
  if st.denied(
    AuthzRequest(
      action: aaRuntimeControl,
      operation: op,
      consumer: x.id,
      target: req.route,
      route: req.route,
    )
  ):
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  let replayed = st.keys.replay(x.id, req.request_key, op, q.rc.request).valueOr:
    q.reply.answerError(ecInvalidParams, error)
    return
  if replayed.isSome:
    st.requireReady(q)
    q.reply.answer(Reply(bytes: replayed.get))
    return
  let r = st.route(req.route)
  if r.isNil or r.consumer != x.id:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if r.state == rtRevoked and r.endCode == ecNotAuthorised:
    # [SPEC RUNTIME §7.5 l.1347] A known authorization failure comes first.
    q.reply.answerError(ecNotAuthorised, "the route is " & $r.state)
    return
  let ans = st.authorizer.decide(
    AuthzRequest(
      action: aaRoute,
      operation: op,
      consumer: x.id,
      target: r.provider,
      route: r.id,
      module: r.selected.module,
    )
  )
  if ans.outcome != azAllow:
    # [G170 interim (TF-17)] No call is served under a decision a later check
    # withdrew (CA l.906-911); a terminal route keeps its first end.
    st.endRoute(
      r,
      rtRevoked,
      Opt.some(
        if ans.outcome == azDeny: rfAuthorityDenied else: rfAuthorityEvaluationFailed
      ),
    )
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  st.requireReady(q)
  if r.isTerminal:
    # [SPEC RUNTIME §9.3 l.1915, l.3482-3483] Closed or failed: NOT_READY;
    # revoked: by its cause (§7.5).
    q.reply.answerError(
      (if r.state == rtRevoked: r.endCode else: ecNotReady), "the route is " & $r.state
    )
    return
  r.decisionId = ans.decisionId
  let bytes = encode(
    LogosNSRuntimeControlRenewRouteResponse(route: r.record(st.runtimeId))
  ).valueOr:
    q.reply.answerError(ecModule, "the response cannot be encoded")
    return
  st.keys.retain(x.id, req.request_key, op, q.rc.request, bytes)
  q.reply.answer(Reply(bytes: bytes))

proc closeRoute(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §9.3 l.3486-3492] One decision for the method on that
  ## route decides for its own consumer and for any other.
  let req = q.rc.close
  if st.denied(
    AuthzRequest(
      action: aaRuntimeControl,
      operation: "close_route",
      consumer: x.id,
      target: req.route,
      route: req.route,
    )
  ):
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  let r = st.route(req.route)
  if r.isNil:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  st.requireReady(q)
  # [G170 interim (TF-17)] A terminal route keeps its state and is reported as
  # it is.
  st.endRoute(r, rtClosed, Opt.none(RouteFailureCode))
  q.reply.answerEncoded(
    encode(
      LogosNSRuntimeControlCloseRouteResponse(route: r.id, state: routeState(r.state))
    )
  )

proc rc(st: State, q: Request) =
  ## [SPEC RUNTIME §9, §9.3] One Runtime Control method through a module's
  ## binding.
  let x = st.caller(q).valueOr:
    q.reply.answerError(error.code, error.message)
    return
  case q.rc.m
  of rmGetSelf:
    # [SPEC RUNTIME §9.3 l.2553-2560] Caller-bound: no policy grant.
    st.requireReady(q)
    q.reply.answerEncoded(
      encode(
        LogosNSRuntimeControlGetSelfResponse(
          consumer: LogosNSRuntimeModuleInstanceAddress(
            runtime_instance_id: st.runtimeId, module_instance_id: x.id
          )
        )
      )
    )
  of rmGetExecutionPermissions:
    # [SPEC RUNTIME §9.3 l.2562-2574] Caller-bound; no operating-system
    # permission enforcement is installed here, so no enforced snapshot.
    st.requireReady(q)
    q.reply.answerEncoded(
      encode(
        LogosNSRuntimeControlGetExecutionPermissionsResponse(
          kind: LogosNSRuntimeControlGetExecutionPermissionsResponseKind.Unavailable
        )
      )
    )
  of rmReportFailure:
    st.requireReady(q)
    let response = encode(LogosNSRuntimeControlReportFailureResponse()).valueOr:
      q.reply.answerError(ecModule, "the response cannot be encoded")
      return
    var r = q
    r.instance = x.id
    r.reason = q.rc.report.reason.get("")
    st.reportFailure(r, Reply(bytes: response))
  of rmStartModule, rmStopModule:
    st.lifecycleCall(q, x)
  of rmGetReadiness:
    st.readiness(q, x)
  of rmEstablishRoute:
    st.establish(q, x)
  of rmRenewRoute:
    st.renew(q, x)
  of rmCloseRoute:
    st.closeRoute(q, x)
  of rmShutdownRuntime:
    # [SPEC RUNTIME §9.3 l.3695-3700] Runtime-wide; the response acknowledges
    # acceptance and is attempted before teardown.
    if st.denied(
      AuthzRequest(
        action: aaRuntimeControl, operation: "shutdown_runtime", consumer: x.id
      )
    ):
      q.reply.answerError(ecNotAuthorised, "not authorised")
      return
    st.requireReady(q)
    q.reply.answerEncoded(encode(LogosNSRuntimeControlShutdownRuntimeResponse()))
    st.beginShutdown()

# Bootstrap ----------------------------------------------------------------------

proc checkBootstrap(st: State) =
  ## [IMPL-DECISION G190, interim] Answers the bootstrap once its outcome is
  ## decided, in this one place. A shutdown accepted before the orchestration
  ## instance's `ready` was committed is CANCELLED (RUN-0759), and stays so
  ## whatever the attempt does next; `ready` is OK; a refused execution is
  ## NOT_AUTHORISED; any other failure, `startup-timeout` included, is
  ## MODULE_ERROR with the classification in the message. Never the code
  ## `_MODULE_init` returned, and never VERSION_MISMATCH, which §13 keeps for
  ## its own structures (l.3952). A failed bootstrap stops nothing.
  if st.bootstrapReply == nil:
    return
  let x = st.orchestrator
  var outcome: Opt[Reply]
  if st.shuttingDown:
    outcome = Opt.some(
      Reply(
        error: Opt.some(
          engineError(ecCancelled, "shutdown was requested before bootstrap completed")
        )
      )
    )
  elif x.state == msReady:
    outcome = Opt.some(Reply(view: x.view))
  elif x.state == msError or (x.state == msUnloaded and x.failure.isSome):
    let f = x.failure.get(Failure(kind: fkOther))
    if f.kind in {fkAuthorityDenied, fkAuthorityEvaluationFailed}:
      outcome = Opt.some(
        Reply(
          error: Opt.some(
            engineError(
              ecNotAuthorised, "starting the orchestration instance is not authorised"
            )
          )
        )
      )
    else:
      var message = "the orchestration instance failed to start: " & f.classification
      if f.reason.len > 0:
        message.add(": " & f.reason)
      outcome = Opt.some(Reply(error: Opt.some(engineError(ecModule, message))))
  if outcome.isSome:
    st.bootstrapReply.answer(outcome.get)
    st.bootstrapReply = nil

proc bootstrap(st: State, q: Request) =
  ## [SPEC RUNTIME l.187-192, l.1640, §13.2] Bootstrap policy is in place (the
  ## authorizer exists before this request). Creates every configured instance
  ## in configuration order, with its protected identity and the host's
  ## origin, records the orchestration role, and starts that one instance
  ## through the ordinary start path: execution authorization, the startup
  ## deadline, binding, `_MODULE_init` with its Runtime Control binding and
  ## the contract checks. Its intent becomes `requested` with the host's
  ## protected-input origin (G191 interim).
  if st.bootstrapped:
    q.reply.answerError(ecNotReady, "the Runtime has already been bootstrapped")
    return
  st.bootstrapped = true
  if st.shuttingDown:
    q.reply.answerError(
      ecCancelled, "shutdown was requested before bootstrap completed"
    )
    return
  for b in q.bootstrap:
    let x = st.createInst(b.record, b.instance, hostOrigin()).valueOr:
      q.reply.answerError(error.code, error.message)
      return
    if b.instance == q.instance:
      x.orchestration = true
      st.orchestrator = x
  if st.orchestrator.isNil:
    q.reply.answerError(ecInvalidParams, "no orchestration instance was configured")
    return
  st.bootstrapReply = q.reply
  st.start(Request(kind: rqStart, instance: q.instance, origin: hostOrigin()))
  st.checkBootstrap()

# Route handles ------------------------------------------------------------------

proc materialize(st: State, q: Request) =
  ## [SPEC INTERFACE §5.2 l.3880-3890] Ownership and non-disclosure first,
  ## then authorization and readiness (§7.5), then the contract root [IMPL:
  ## readiness before the root].
  let x = st.caller(q).valueOr:
    q.reply.answerError(error.code, error.message)
    return
  let r = st.route(q.route)
  if r.isNil or r.consumer != x.id:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  # [SPEC RUNTIME §4.3 l.982-984] The caller's access to the selected provider
  # is verified before a handle is returned [IMPL: one route decision].
  if st.denied(
    AuthzRequest(
      action: aaRoute,
      operation: "materialize_route",
      consumer: x.id,
      target: r.provider,
      route: r.id,
      module: r.selected.module,
    )
  ):
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if r.isTerminal and r.endCode == ecNotAuthorised:
    q.reply.answerError(ecNotAuthorised, "the route is " & $r.state)
    return
  st.requireReady(q)
  if r.isTerminal:
    q.reply.answerError(r.endCode, "the route is " & $r.state)
    return
  if r.selected.root != q.root or not q.rebuilt:
    q.reply.answerError(
      ecVersionMismatch, "the expected contract root is not the route's contract"
    )
    return
  r.pins.add(Pin(handle: q.handle, attempt: q.attempt))
  q.reply.answer(Reply())

proc admit(st: State, q: Request) =
  ## [SPEC RUNTIME §4.1, §6.4, §7.5, l.1732] Step 1 of a direct route call
  ## (`bindings.nim`): the method and its scope, then authorization, then
  ## readiness, so a known authorization failure takes precedence (l.1347).
  let r = st.route(q.route)
  if r.isNil or r.consumer != q.origin.instance:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if r.selected.methodRoot(q.bare).isNone:
    q.reply.answerError(ecMethodNotFound, "unknown method " & q.bare)
    return
  if not r.allowsMethod(q.bare):
    q.reply.answerError(ecNotAuthorised, "the method is outside the route's access")
    return
  if r.isTerminal and r.endCode == ecNotAuthorised:
    q.reply.answerError(ecNotAuthorised, "the route is " & $r.state)
    return
  if st.denied(
    AuthzRequest(
      action: aaCall,
      operation: q.bare,
      consumer: r.consumer,
      target: r.provider,
      route: r.id,
      module: r.selected.module,
    )
  ):
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if r.isTerminal:
    q.reply.answerError(r.endCode, "the route is " & $r.state)
    return
  let x = st.instances.getOrDefault(r.consumer)
  if x.isNil or q.attempt != x.current or x.state notin {msLoaded, msReady} or
      st.shuttingDown:
    q.reply.answerError(ecNotReady, "the consumer is not live")
    return
  if r.selected.isWellKnown(q.bare):
    # [SPEC INTERFACE l.3275-3277; RUNTIME l.429-431] The boundary answers;
    # no provider code runs and no invocation context is made current.
    q.reply.answer(Reply(admission: Admission(introspection: true)))
    return
  let p = st.instances.getOrDefault(r.providerInstance)
  if p.isNil or p.state != msReady or p.realization.isNil or p.services.isNil:
    q.reply.answerError(ecNotReady, "the provider is not ready")
    return
  inc p.inflight
  let ticket = newTicket()
  r.calls.add(ticket)
  if q.call != nil:
    let a = st.asyncCalls.getOrDefault(q.call)
    if a != nil:
      a.ticket = ticket
      a.provider = p.id
      if a.cancelled:
        ticket.cancelled.store(true)
      if a.terminal:
        ticket.closed.store(true)
  let b = p.realization.binding
  q.reply.answer(
    Reply(
      admission: Admission(
        dispatch: b.dispatch,
        free: b.free,
        context: p.realization.context,
        access: p.services,
        provider: p.id,
        route: r.id,
        ticket: ticket,
        runtimeId: st.runtimeId,
        asyncApi: b.asyncApi,
      )
    )
  )

proc observeEnd(st: State, q: Request) =
  ## [SPEC INTERFACE §2.5 l.1477-1491] Installed in order with termination.
  let r = st.route(q.route)
  if r.isNil:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if r.isTerminal:
    q.reply.answerError(r.endCode, "the route is " & $r.state)
    return
  if q.handle in r.handles:
    q.reply.answerError(ecInvalidParams, "an observer is already installed")
    return
  installEnd(q.handle, q.handler, q.userData)
  r.handles.add(q.handle)
  q.reply.answer(Reply())

proc releaseHandle(st: State, q: Request) =
  ## No terminal callback is scheduled for the handle after this, and its
  ## subscriptions are inactive; they go back to the releasing thread, which
  ## waits for their handlers (INTERFACE l.1465, l.3895-3897).
  let r = st.route(q.route)
  var gone: seq[pointer]
  if not r.isNil:
    let i = r.handles.find(q.handle)
    if i >= 0:
      r.handles.del(i)
    for j, p in r.pins:
      if p.handle == q.handle:
        r.pins.delete(j)
        break
    var kept: seq[pointer]
    for p in r.subs:
      if subOf(p).generation == q.generation:
        deactivate(subOf(p))
        gone.add(p)
      else:
        kept.add(p)
    r.subs = kept
    st.settle(r)
  q.reply.answer(Reply(subs: gone))

# Events -----------------------------------------------------------------------------

proc subscribe(st: State, q: Request) =
  ## [SPEC INTERFACE §2.5 l.1417-1432; RUNTIME §4.4 l.1018-1021, §7.5; G175]
  ## Ownership, then the event under the selected contract and the route's
  ## subscribe scope, a revoked route and the subscribe-event decision
  ## (NOT_AUTHORISED), then readiness. The id is written before activation.
  let r = st.route(q.route)
  if r.isNil or r.consumer != q.origin.instance:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if r.selected.eventRoot(q.bare).isNone:
    q.reply.answerError(
      ecNotAuthorised, q.bare & " is not an event of the selected contract"
    )
    return
  if not r.allowsSubscribe(q.bare):
    q.reply.answerError(ecNotAuthorised, "the event is outside the route's access")
    return
  if r.isTerminal and r.endCode == ecNotAuthorised:
    q.reply.answerError(ecNotAuthorised, "the route is " & $r.state)
    return
  if st.denied(
    AuthzRequest(
      action: aaSubscribeEvent,
      operation: q.bare,
      consumer: r.consumer,
      target: r.provider,
      route: r.id,
      module: r.selected.module,
    )
  ):
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if r.isTerminal:
    q.reply.answerError(r.endCode, "the route is " & $r.state)
    return
  let x = st.instances.getOrDefault(r.consumer)
  if x.isNil or q.attempt != x.current or x.state notin {msLoaded, msReady} or
      st.shuttingDown:
    q.reply.answerError(ecNotReady, "the consumer is not live")
    return
  inc r.nextSub
  q.outId[] = r.nextSub
  let s = subOf(q.handle)
  retain(s)
  activate(s, r.nextSub)
  r.subs.add(q.handle)
  q.reply.answer(Reply())

proc unsubscribe(st: State, q: Request) =
  ## [SPEC INTERFACE §2.5 l.1446-1459; RUNTIME §7.5 l.1341-1347] An ended
  ## route answers with its code first; an id that names no active
  ## subscription of this handle is INVALID_PARAMS (TRANSPORT l.748 through
  ## RUNTIME l.1012-1016) and changes nothing.
  let r = st.route(q.route)
  if r.isNil or r.consumer != q.origin.instance:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if r.isTerminal:
    q.reply.answerError(r.endCode, "the route is " & $r.state)
    return
  for i, p in r.subs:
    let s = subOf(p)
    if s.id == q.subId and s.generation == q.generation and s.isActive:
      deactivate(s)
      r.subs.delete(i)
      q.reply.answer(Reply(subs: @[p]))
      return
  q.reply.answerError(
    ecInvalidParams, "no active subscription of this handle has that id"
  )

proc candidates(st: State, q: Request) =
  ## [SPEC RUNTIME §7.3] The active subscriptions to `q.bare` on the ready
  ## routes of a ready publisher's current realization, in route and then
  ## subscription creation order [IMPL].
  var r = Reply()
  let x = st.instances.getOrDefault(q.origin.instance)
  if not x.isNil and q.attempt == x.current and x.state == msReady:
    for route in st.routes.values:
      if route.providerInstance != x.id or route.isTerminal:
        continue
      for p in route.subs:
        let s = subOf(p)
        if s.eventName == q.bare and s.isActive:
          retain(s)
          r.subs.add(p)
  q.reply.answer(r)

proc scoped(st: State, q: Request) =
  ## [SPEC RUNTIME §7.3.1 l.1254-1273; INTERFACE l.2193-2196] The destination
  ## of one invocation: the active subscriptions to `q.bare` on its route and
  ## path generation. An event outside `publish_events` or a revoked route is
  ## NOT_AUTHORISED; `ready` says whether the destination is open.
  let r = st.route(q.route)
  if r.isNil:
    q.reply.answerError(ecNotReady, "the invocation's destination is closed")
    return
  if not r.allowsPublish(q.bare):
    q.reply.answerError(ecNotAuthorised, "the event is outside the route's access")
    return
  if r.isTerminal and r.endCode == ecNotAuthorised:
    q.reply.answerError(ecNotAuthorised, "the route is " & $r.state)
    return
  var reply = Reply(
    ready:
      not r.isTerminal and q.ticket != nil and not q.ticket.cancelled.load and
      not q.ticket.closed.load
  )
  if reply.ready:
    for p in r.subs:
      let s = subOf(p)
      if s.generation == q.generation and s.eventName == q.bare and s.isActive:
        retain(s)
        reply.subs.add(p)
  q.reply.answer(reply)

proc deliver(st: State, q: Request) =
  ## [SPEC RUNTIME l.1229-1231, l.1275-1283; CA l.973-975; G175] The admission
  ## of one handler invocation, decided afresh for each: the subscription is
  ## active, the route ready, the consumer live, both access scopes hold, and
  ## the publish-event and subscribe-event decisions allow it. An ordinary
  ## publication skips what fails; an invocation-scoped one stops on a revoked
  ## route or a denied publish-event decision (NOT_AUTHORISED) or a closed
  ## destination (NOT_READY), and skips what only concerns the subscriber.
  let s = subOf(q.handle)
  let r = st.route(s.routeId)
  let name = q.bare
  template skip() =
    q.reply.answer(Reply())
    return

  template stop(code: ErrorCode, message: string) =
    q.reply.answerError(code, message)
    return

  if r.isNil:
    skip()
  if q.scoped:
    if r.isTerminal and r.endCode == ecNotAuthorised:
      stop(ecNotAuthorised, "the route is " & $r.state)
    if r.isTerminal or q.ticket == nil or q.ticket.cancelled.load or q.ticket.closed.load:
      stop(ecNotReady, "the invocation's destination is closed")
    if not r.allowsPublish(name):
      stop(ecNotAuthorised, "the event is outside the route's access")
  else:
    let x = st.instances.getOrDefault(q.origin.instance)
    if x.isNil or q.attempt != x.current or x.state != msReady or
        r.providerInstance != x.id or r.isTerminal or not r.allowsPublish(name):
      skip()
  if not s.isActive:
    skip()
  let c = st.instances.getOrDefault(r.consumer)
  if c.isNil or c.state notin {msLoaded, msReady} or not r.allowsSubscribe(name):
    skip()
  if st.denied(
    AuthzRequest(
      action: aaPublishEvent,
      operation: name,
      consumer: r.providerInstance,
      target: r.consumer,
      route: r.id,
      module: r.selected.module,
    )
  ):
    if q.scoped:
      stop(ecNotAuthorised, "the publication is not authorised")
    skip()
  if st.denied(
    AuthzRequest(
      action: aaSubscribeEvent,
      operation: name,
      consumer: r.consumer,
      target: r.provider,
      route: r.id,
      module: r.selected.module,
    )
  ):
    skip()
  q.reply.answer(Reply(admitted: true))

# The Runtime thread ---------------------------------------------------------------

proc handle(st: State, q: Request) =
  case q.kind
  of rqConfigure:
    discard
  of rqCreate:
    st.create(q)
  of rqStart:
    st.start(q)
  of rqStop:
    st.stop(q)
  of rqReportFailure:
    st.reportFailure(q)
  of rqView:
    let x = st.instances.getOrDefault(q.instance)
    if x.isNil:
      q.reply.answerError(ecInvalidParams, "unknown module instance")
    else:
      q.reply.answerView(x)
  of rqList:
    var r = Reply()
    for x in st.instances.values:
      r.views.add(x.view)
    q.reply.answer(r)
  of rqAnswers:
    q.reply.answer(Reply(answers: st.authorizer.answers))
  of rqChanges:
    q.reply.answer(Reply(changes: st.changes))
  of rqShutdown:
    # [SPEC RUNTIME §10.2] One engine-owned sequence; admission closes first.
    if st.shutdownDone:
      q.reply.answer(Reply(error: st.shutdownResult))
      return
    st.shutdownWaiters.add(q.reply)
    st.beginShutdown()
  of rqRequestShutdown:
    # [SPEC RUNTIME §13.2] Accepted here; the sequence continues on the
    # Runtime thread, whoever waits (RUN-0726). A repeat joins it (RUN-0727).
    q.reply.answer(Reply())
    if not st.shuttingDown:
      st.beginShutdown()
  of rqAwaitShutdown:
    # [SPEC RUNTIME §13.2] Never initiates shutdown (RUN-0728).
    if st.shutdownDone:
      q.reply.answer(Reply(error: st.shutdownResult))
    else:
      st.shutdownWaiters.add(q.reply)
  of rqBootstrap:
    st.bootstrap(q)
  of rqTerminate:
    # `close`: only after shutdown, and only while no worker or call worker is
    # inside module code that may still report here. A refusal leaves the
    # Runtime thread running, so `close` can be tried again.
    if not st.shutdownDone:
      q.reply.answerError(ecNotReady, "the Runtime has not shut down")
      return
    if st.busy + st.callBusy > 0:
      q.reply.answerError(ecNotReady, "module code is still running")
      return
    st.done = true
    q.reply.answer(Reply())
  of rqRcPrecheck:
    st.rcPrecheck(q)
  of rqRc:
    st.rc(q)
  of rqMaterialize:
    st.materialize(q)
  of rqAdmit:
    st.admit(q)
  of rqObserveEnd:
    st.observeEnd(q)
  of rqReleaseHandle:
    st.releaseHandle(q)
  of rqIdentity:
    q.reply.answer(Reply(id: st.runtimeId))
  of rqSubscribe:
    st.subscribe(q)
  of rqUnsubscribe:
    st.unsubscribe(q)
  of rqCandidates:
    st.candidates(q)
  of rqScoped:
    st.scoped(q)
  of rqDeliver:
    st.deliver(q)
  of rqDiagnostics:
    var r = Reply()
    for d in st.diagnostics:
      r.diagnostics.add(d)
    q.reply.answer(r)
  of rqRoutes:
    var r = Reply()
    for x in st.routes.values:
      if not x.dropped:
        r.routes.add(x.record(st.runtimeId))
    q.reply.answer(r)

proc destroyed(st: State, job: int) =
  if job in st.teardowns:
    var x: Inst
    discard st.teardowns.pop(job, x)
    x.teardown = 0
    st.realizer.finishRelease(x.id)
    x.realization = nil
    st.endServices(x.services, x.id)
    freeAttemptServices(x.services)
    x.services = nil
    let a = x.attempt
    if a != nil and a.phase == apCleanup:
      st.finishAttempt(a)
    elif x.state == msStopping:
      x.state = msUnloaded
      x.failure = Opt.none(Failure)
      x.current = ""
      st.commit(x)
      st.releaseWaiters(x)
  elif job in st.attempts:
    var a: Attempt
    discard st.attempts.pop(job, a)
    st.finishAttempt(a)

proc callLeft(st: State, provider, route: string, ticket: ptr CallTicket) =
  ## An admitted call has left its provider: its ticket goes, and a provider
  ## being stopped is released once none is left.
  let r = st.route(route)
  if r != nil:
    let i = r.calls.find(ticket)
    if i >= 0:
      r.calls.del(i)
    st.settle(r)
  for a in st.asyncCalls.values:
    if a.ticket == ticket:
      a.ticket = nil
  if ticket != nil:
    freeTicket(ticket)
  let p = st.instances.getOrDefault(provider)
  if p != nil:
    dec p.inflight
    if p.inflight == 0 and p.releasePending:
      st.releaseRealization(p)

proc asyncEvent(st: State, m: Msg) =
  case m.event
  of aeSubmit:
    let c = asyncOf(m.target)
    let a = AsyncRec(
      call: m.target,
      rc: c.rc,
      consumer: $c.consumer,
      attempt: $c.attempt,
      route: $c.route,
      deadline: c.deadline,
    )
    st.asyncCalls[m.target] = a
    if not a.rc:
      let r = st.route(a.route)
      if r != nil:
        inc r.pending
    if c.isTerminal:
      st.asyncTerminal(a)
    else:
      a.executing = true
      st.dispatchCall(m.target)
  of aeTerminal:
    let a = st.asyncCalls.getOrDefault(m.target)
    if a != nil:
      st.asyncTerminal(a)
  of aeDeferred:
    let a = st.asyncCalls.getOrDefault(m.target)
    if a != nil:
      a.deferred = m.extra
      if a.cancelled and cancelKnown(m.extra):
        st.dispatch(Job(id: st.nextJobId(), kind: jkRequestCancel, deferred: m.extra))
  of aeHook:
    st.dispatch(Job(id: st.nextJobId(), kind: jkRequestCancel, deferred: m.extra))

proc settle(st: State) =
  ## After every message and deadline: shutdown progress, then the bootstrap's
  ## outcome, so a `ready` committed by one message is answered before a
  ## shutdown accepted by the next.
  if st.shuttingDown and not st.shutdownDone:
    st.shutdownStep()
    if st.shutdownComplete():
      st.finishShutdown()
  st.checkBootstrap()

proc handle(st: State, m: sink Msg) =
  case m.kind
  of mkRequest:
    st.handle(m.request)
    st.checkBootstrap()
    return
  of mkBound, mkInitialized, mkDestroyed, mkJobDone, mkCompleted:
    dec st.busy
  of mkCallDone, mkDiagnostic, mkAsync, mkCallJobDone, mkDeferredIdle:
    discard
  case m.kind
  of mkBound:
    var a: Attempt
    if st.attempts.pop(m.job, a):
      st.bound(a, move m.bound)
  of mkInitialized:
    var a: Attempt
    if st.attempts.pop(m.job, a):
      st.initialized(a, m.res, m.context)
  of mkDestroyed:
    st.destroyed(m.job)
  of mkCallDone:
    st.callLeft(m.provider, m.route, m.ticket)
  of mkDiagnostic:
    st.diagnose(m.text)
  of mkAsync:
    st.asyncEvent(m)
  of mkCallJobDone:
    dec st.callBusy
    let a = st.asyncCalls.getOrDefault(m.target)
    if a != nil:
      a.executing = false
      st.maybeForget(a)
  of mkCompleted:
    let a = st.asyncCalls.getOrDefault(m.target)
    if a != nil:
      a.completing = false
      st.maybeForget(a)
  of mkDeferredIdle:
    var owner: AsyncRec
    for a in st.asyncCalls.values:
      if a.deferred == m.target:
        owner = a
    let (provider, route, ticket) = finishDeferred(m.target)
    st.callLeft(provider, route, ticket)
    if owner != nil:
      owner.deferred = nil
      st.maybeForget(owner)
  of mkRequest, mkJobDone:
    discard
  st.settle()

proc checkDeadlines(st: State) =
  let now = getMonoTime()
  for a in st.records:
    if not a.terminal and a.deadline.isSome and now >= a.deadline.get:
      # [SPEC INTERFACE l.2059-2068] TIMEOUT, without waiting for the provider.
      st.endCall(a, failure(ecTimeout, "the call timed out"), okTimeout)
  for x in st.instances.values:
    let a = x.attempt
    if a != nil and a.phase in {apBind, apInit} and not a.expired and not a.cancelled and
        not a.failed and now >= a.deadline:
      # [SPEC RUNTIME §3.4 l.664-669] The attempt can no longer make the
      # instance ready; the module code still running is not interrupted.
      st.failAttempt(
        a, Failure(kind: fkStartupTimeout, reason: "the startup deadline passed")
      )
      a.expired = true
    if x.state == msStopping and x.stopDeadline.isSome and now >= x.stopDeadline.get:
      # [G61, revised by A18; SPEC RUNTIME §10.2 l.3835-3838, l.3873-3874]
      # The cleanup failure is recorded; nothing still in use is released.
      x.state = msError
      x.failure =
        Opt.some(Failure(kind: fkCleanupTimeout, reason: "the stop deadline passed"))
      st.commit(x)
      st.releaseWaiters(x)
  if st.shuttingDown and not st.shutdownDone and now >= st.shutdownDeadline:
    # [SPEC RUNTIME §10.2 step 6] The cleanup failure is recorded and shutdown
    # continues; nothing still in use is released.
    for x in st.instances.values:
      if x.state in {msLoaded, msReady, msStopping}:
        x.state = msError
        x.failure = Opt.some(
          Failure(kind: fkCleanupTimeout, reason: "the shutdown grace period passed")
        )
        st.commit(x)
        for w in x.stopWaiters:
          w.reply.answerView(x)
        x.stopWaiters.setLen(0)
    st.finishShutdown()

proc nextDeadline(st: State): Opt[MonoTime] =
  var t = Opt.none(MonoTime)
  template consider(d: MonoTime) =
    if t.isNone or d < t.get:
      t = Opt.some(d)

  for x in st.instances.values:
    let a = x.attempt
    if a != nil and a.phase in {apBind, apInit} and not a.expired and not a.cancelled and
        not a.failed:
      consider(a.deadline)
    if x.state == msStopping and x.stopDeadline.isSome:
      consider(x.stopDeadline.get)
  if st.shuttingDown and not st.shutdownDone:
    consider(st.shutdownDeadline)
  for a in st.asyncCalls.values:
    if not a.terminal and a.deadline.isSome:
      consider(a.deadline.get)
  t

proc runtimeLoop(s: ptr Shared) =
  var first: Msg
  try:
    first = s.inbox.recv()
  except Exception:
    return
  doAssert first.kind == mkRequest and first.request.kind == rqConfigure
  let cfg = first.request.config
  var rnd: array[8, byte]
  doAssert urandom(rnd), "no system randomness"
  var prefix = ""
  for b in rnd:
    prefix.add(toHex(int(b), 2).toLowerAscii)
  let st = State(
    shared: s,
    cfg: cfg,
    realizer: newRealizer(cfg.workDir, cfg.stateRoot),
    authorizer: initAuthorizer(cfg.policy),
    prefix: prefix,
    runtimeId: cfg.runtimeInstanceId,
    ctx: pinnedContext(),
  )
  for reg in cfg.statics:
    discard st.realizer.registerStatic(reg)
  first.request.reply.answer(Reply())
  while not st.done:
    while true:
      var got: tuple[dataAvailable: bool, msg: Msg]
      try:
        got = s.inbox.tryRecv()
      except Exception:
        break
      if not got.dataAvailable:
        break
      st.handle(move got.msg)
      if st.done:
        break
    if st.done:
      break
    st.checkDeadlines()
    st.checkBootstrap()
    if st.done:
      break
    st.compactRoutes()
    s.bell.wait(st.nextDeadline())
  # Idle workers leave; one still inside module code keeps its thread.
  for i in 0 ..< s.spawned:
    try:
      s.jobs.send(Job(kind: jkQuit))
    except Exception:
      discard
  for i in 0 ..< s.callSpawned:
    try:
      s.calls.send(CallJob(kind: cjQuit))
    except Exception:
      discard
  s.finished = true

proc runtimeMain(s: ptr Shared) {.thread.} =
  markRuntimeThread()
  runtimeLoop(s)
  releasePerThread() # after the loop's locals are gone

# The engine handle ------------------------------------------------------------------

proc newEngine*(cfg: EngineConfig): Engine =
  ## Starts the Runtime thread with `cfg`. Static registrations whose table
  ## is invalid were rejected by `checkStaticRegistration` before this, and a
  ## Runtime identity has 1 to 128 UTF-8 bytes (§9.2).
  doAssert cfg.runtimeInstanceId.len in 1 .. 128 and isValidUtf8(cfg.runtimeInstanceId),
    "invalid runtime instance id"
  result = createShared(Shared)
  result.inbox.open()
  result.jobs.open()
  result.calls.open()
  result.bell = newBell()
  initLock(result.slotLock)
  try:
    createThread(result.runtime, runtimeMain, result)
  except ResourceExhaustedError:
    doAssert false, "cannot start the Runtime thread"
  discard result.call(Request(kind: rqConfigure, config: cfg))

template toResult(r: Reply, body: untyped): untyped =
  if r.error.isSome:
    err(r.error.get)
  else:
    ok(body)

proc create*(
    e: Engine, record: ModuleRecord, instance = "", origin = hostOrigin()
): Result[InstanceView, EngineError] =
  ## Creates a module instance from a resolved record; `instance` is a
  ## protected input's instance identity, or empty for a fresh one.
  let r =
    e.call(Request(kind: rqCreate, record: record, instance: instance, origin: origin))
  r.toResult(r.view)

proc start*(
    e: Engine,
    instance: string,
    origin = hostOrigin(),
    expectedRevision = Opt.none(uint64),
): Result[InstanceView, EngineError] =
  ## [SPEC RUNTIME §9.3 start_module] Returns the resulting state.
  let r = e.call(
    Request(
      kind: rqStart,
      instance: instance,
      origin: origin,
      expectedRevision: expectedRevision,
    )
  )
  r.toResult(r.view)

proc stop*(
    e: Engine,
    instance: string,
    origin = hostOrigin(),
    expectedRevision = Opt.none(uint64),
): Result[InstanceView, EngineError] =
  ## [SPEC RUNTIME §9.3 stop_module] Returns the resulting state.
  let r = e.call(
    Request(
      kind: rqStop,
      instance: instance,
      origin: origin,
      expectedRevision: expectedRevision,
    )
  )
  r.toResult(r.view)

proc reportFailure*(
    e: Engine, instance, attempt: string, reason = ""
): Result[void, EngineError] =
  ## [SPEC RUNTIME §9.3 report_failure] Through the binding of `attempt`.
  let r = e.call(
    Request(kind: rqReportFailure, instance: instance, attempt: attempt, reason: reason)
  )
  if r.error.isSome:
    err(r.error.get)
  else:
    ok()

proc view*(e: Engine, instance: string): Result[InstanceView, EngineError] =
  let r = e.call(Request(kind: rqView, instance: instance))
  r.toResult(r.view)

proc list*(e: Engine): seq[InstanceView] =
  e.call(Request(kind: rqList)).views

proc answers*(e: Engine): seq[AuthzAnswer] =
  ## The retained authorization answers, oldest first.
  e.call(Request(kind: rqAnswers)).answers

proc changes*(e: Engine): seq[StateChange] =
  ## The retained committed changes, in commit order.
  e.call(Request(kind: rqChanges)).changes

proc runtimeInstanceId*(e: Engine): string =
  e.call(Request(kind: rqIdentity)).id

proc routes*(e: Engine): seq[LogosNSRuntimeControlRouteRecord] =
  ## The route records not dropped, in creation order (host and test
  ## observation).
  e.call(Request(kind: rqRoutes)).routes

proc diagnostics*(e: Engine): seq[string] =
  ## [SPEC RUNTIME l.1227] The retained diagnostics, oldest first: dropped
  ## publications, ignored provider completions, long delivery waits.
  e.call(Request(kind: rqDiagnostics)).diagnostics

proc bootstrap*(
    e: Engine, instances: seq[BootstrapInstance], orchestration: string
): Result[InstanceView, EngineError] =
  ## [SPEC RUNTIME l.1640, §13.2; G190 interim] Creates `instances` and starts
  ## `orchestration`, one of them; returns once it is `ready`, or with the
  ## code its failure maps to (`checkBootstrap`).
  let r =
    e.call(Request(kind: rqBootstrap, bootstrap: instances, instance: orchestration))
  r.toResult(r.view)

proc shutdown*(e: Engine) =
  ## [SPEC RUNTIME §10.2] Host-initiated graceful shutdown; returns once every
  ## realization is released or its cleanup failure is recorded.
  discard e.call(Request(kind: rqShutdown))

proc requestShutdown*(e: Engine) =
  ## [SPEC RUNTIME §13.2] Accepts shutdown and returns without waiting.
  discard e.call(Request(kind: rqRequestShutdown))

proc awaitShutdown*(e: Engine): Result[void, EngineError] =
  ## [SPEC RUNTIME §13.2; G60] Waits for shutdown, initiated by anyone, without
  ## initiating it; the one stored result.
  let r = e.call(Request(kind: rqAwaitShutdown))
  if r.error.isSome:
    err(r.error.get)
  else:
    ok()

proc tryClose*(e: Engine): Result[void, EngineError] =
  ## Stops the Runtime thread after shutdown and frees the engine. NOT_READY,
  ## with the engine intact and running, before shutdown completed or while a
  ## worker is inside module code that may still report to it.
  let r = e.call(Request(kind: rqTerminate))
  if r.error.isSome:
    return err(r.error.get)
  joinThread(e.runtime)
  for i in 0 ..< e.spawned:
    joinThread(e.workers[i])
  for i in 0 ..< e.callSpawned:
    joinThread(e.callWorkers[i])
  # No thread sends to any channel or rings the bell any more.
  e.inbox.close()
  e.jobs.close()
  e.calls.close()
  e.closeSlots()
  deinitLock(e.slotLock)
  freeBell(e.bell)
  deallocShared(e)
  ok()

proc close*(e: Engine, patience = initDuration(seconds = 10)): bool =
  ## `tryClose`, tried again while module code is still running, for up to
  ## `patience`. False when the engine is still open.
  let until = getMonoTime() + patience
  while true:
    let r = e.tryClose()
    if r.isOk:
      return true
    if r.error.message != "module code is still running" or getMonoTime() >= until:
      return false
    sleep(1)
