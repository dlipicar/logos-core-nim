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
## [IMPL] Persistent Runtime state (step 6, `store.nim`; DECISIONS I82). With
## a `storeDir` the engine keeps one snapshot of the Runtime-owned persistent
## state, rewritten on the Runtime thread at every commit before the change is
## exposed (RUNTIME l.3505). A commit that accepts an operation (`accept`:
## intent, an attempt, a creation, a retirement, a refreshed record) is written
## first and rolled back, MODULE_ERROR, when the write fails. `ready` is
## written first too; while its write fails the instance stays `loaded` and
## the write is retried every second until the startup deadline. Any other
## commit (`commit`: stopping, unloaded, error, a refused execution, a stop's
## intent cancellation) withdraws at once, then writes, then exposes; when the
## write fails nothing is exposed: observers keep the last written view, and a
## reply that would carry the view is MODULE_ERROR. The write is retried every
## second, at every commit and before every lifecycle request; the first that
## succeeds exposes every change held back (U6 option (b); l.3507). Without a
## `storeDir` nothing is written and every commit is exposed at once.
##
## Not yet built: the other Runtime Control methods, Runtime Control
## subscriptions (G178), remote Runtimes, and persistence of routes.

{.push raises: [].}

import
  std/[
    atomics, deques, locks, monotimes, sequtils, sets, strutils, sysrand, tables, times,
    typedthreads,
  ]
from std/os import sleep
import results
import ../abi/types
import ../base/perthread
import ../cbor/utf8
import ../commitment
import ../iface/[accept, outcome]
import
  ./[
    asynccall, authbinding, authscopes, bell, bindings, callside, dcache, events,
    execauth, invoke, plumbing, store,
  ]

export plumbing

type
  # Runtime-thread state ---------------------------------------------------------
  AttemptPhase = enum
    apBind
    apInit
    apReadyPending
      ## [IMPL] the realization is made and checked; `ready` waits for its
      ## write (I82)
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
    provides: bool ## its realization exposes a provider view once `ready`
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
    created: bool ## made by `create_module`, not named by the host
    configured: bool ## named by the host configuration at bootstrap
    pending: bool ## [IMPL] a committed change not yet written, so not yet exposed (I82)
    shown: InstanceView ## the view last exposed, which observers see while `pending`
    pendingExec: PendingExec
      ## [I85] an accepted start or recovery waiting for its execution decision
    exec: Opt[ExecAuth]
      ## [I85] the execution authorization of the attempt or realization in
      ## progress (`execauth.nim`)
    execSerial: int ## advanced whenever `exec` is replaced or ended
    enforced: Opt[Failure]
      ## [G168 extended] the classification an authority stop in progress
      ## leaves on `unloaded`

  Saved = object ## What an accepting commit rolls back when its write fails.
    record: ModuleRecord
    state: ModuleState
    failure: Opt[Failure]
    revision: uint64
    intent: Intent
    intentRevision: uint64
    intentOrigin: Origin
    current: string
    provider: bool
    pending: bool

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

  OpCtx = ref object
    ## [IMPL] One request while its handler obtains its decisions (I85). A
    ## handler obtains every decision before its first mutation; when one
    ## needs an evaluation the request is parked and its handler runs again
    ## once the evaluations answer, finding the decisions made so far here.
    q: Request
    decided: Table[string, AuthzAnswer]
    reserved: Table[string, string]
      ## by provider: the route ids `establish_route` allocated (l.3155)
    passes: int
    waited: Table[string, int]
      ## by route: the re-authorization it waited for (`routeAuthorized`)

  Then = proc(answers: seq[AuthzAnswer]) {.closure, gcsafe, raises: [].}
  Abort = proc() {.closure, gcsafe, raises: [].}

  Pending = ref object
    ## Decisions some evaluations are still to give (`decideDetached`).
    id: int
    reqs: seq[AuthzRequest]
    answers: seq[AuthzAnswer]
    filled: seq[bool]
    remaining: int
    deadline: MonoTime ## [IMPL] the evaluation deadline
    then: Then
    abort: Abort ## shutdown: the operation is answered NOT_READY
    done: bool

  Eval = ref object ## One `evaluate` on the evaluation lane.
    id: int
    gen: uint64 ## the binding generation it was dispatched under
    pending: Pending
    index: int
    bytes: seq[byte] ## the encoded `evaluate_request`
    authority: Inst ## the instance whose in-flight count it holds
    ticket: ptr CallTicket
    seqAt: uint64 ## the invalidation sequence at dispatch
    retries: int
    cacheable: bool
    abandoned: bool ## its answer was given without it
    renewal: bool ## on the renewal lane

  PendingExec = ref object
    ## [SPEC RUNTIME §3.6 step 3; plan §2.9] An accepted start or recovery
    ## waiting for its execution decision; the instance stays as it was.
    waiters: seq[Waiter]
    joined: seq[OpCtx] ## later starts that join while it can still succeed
    cancelled: bool

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
    store: Store ## [IMPL] the persistent state; in memory without `storeDir`
    epoch: uint64 ## the revision epoch of this start (I82)
    budget: uint64 ## `revisionBudget`
    storeFailed: bool ## the last write failed: changes are held back
    nextStoreTry: MonoTime
    tombstones: OrderedTable[string, Opt[string]]
      ## retired host-assigned instance ids, with the state assignment each
      ## keeps reserved (RUNTIME l.3582, l.3587)
    createKeys: seq[CreateKey] ## `create_module` key associations
    assignments: int ## state assignments `create_module` gave (`s-<prefix>-<n>`)
    clock: Clock ## [I85] decision validity
    timed: HashSet[string] ## ready routes with an `expires_at`
    caRoot: Opt[Digest] ## the pinned Capability Authority contract root
    op: OpCtx ## the request being handled
    pendings: Table[int, Pending]
    nextPending: int
    evals: Table[int, Eval] ## by job id
    nextEval: int
    evalBusy: int ## ordinary-lane evaluations dispatched and not yet answered
    renewBusy: int ## renewal-lane evaluations dispatched and not yet answered
    gen: uint64 ## [CAP-0344] the binding generation
    caInst: Inst ## the bound Capability Authority instance, if any
    boundToken: string ## the realization the binding checked
    everBound: bool ## a binding existed: the derived rules are recovery rules
    bindNote: string ## the realization whose binding refusal was diagnosed
    cache: DecisionCache
    policyRevision: uint64 ## of the last `policy_changed` processed
    invalidations: uint64 ## processed invalidations, in order
    revokedGrants: seq[(uint64, string)]
      ## (invalidation, grant) for the revocations and expiries processed while
      ## an evaluation was outstanding (CAP-0343)
    reauthQueue: Deque[string] ## routes waiting for a re-authorization slot
    reauthBusy: int ## route re-authorizations being evaluated
    reauthWaiters: Table[string, seq[OpCtx]]
      ## by route: operations parked on its re-authorization

const
  MaxPasses = 8 ## [IMPL] handler passes per operation; more is an evaluation failure
  ReauthBatch = 64
    ## [IMPL; S8b-2 interim] route re-authorizations evaluated at once after
    ## a notice, the rest queued, so they never fill the ordinary lane's queue
  NotPersisted = "the execution state could not be persisted"
  StoreRetry = initDuration(seconds = 1)
  RevisionMask = 0xFFFF_FFFF'u64

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

func exposed(x: Inst): InstanceView =
  ## [IMPL] What observers see: the last view written to the store while a
  ## later change is held back (I82).
  if x.pending: x.shown else: x.view

var
  rcCaptures {.threadvar.}: Table[pointer, CallCapture]
    ## [SPEC CA l.1176-1177; I85] Runtime thread: the applied Runtime Control
    ## call decisions that require a call record, by their call's reply
    ## channel, until that call is answered (`captureRc`).
  rcCapturesHooked {.threadvar.}: bool

proc dropRcCaptures() {.nimcall, gcsafe, raises: [].} =
  ## [IMPL] Nim never destroys thread-local storage: the table's storage stays
  ## allocated after its last entry is answered, so the thread's release
  ## frees it (`base/perthread`).
  rcCaptures = default(Table[pointer, CallCapture])
  rcCapturesHooked = false

proc keepCapture(reply: pointer, c: CallCapture) =
  if not rcCapturesHooked:
    rcCapturesHooked = true
    onThreadRelease(dropRcCaptures)
  rcCaptures[reply] = c

proc answer(r: ReplyChannel, reply: sink Reply) =
  if r != nil:
    var reply = reply
    if rcCaptures.len > 0:
      var c: CallCapture
      if rcCaptures.pop(cast[pointer](r), c):
        reply.capture = c
    try:
      r[].send(reply)
    except Exception:
      discard

proc answerError(r: ReplyChannel, code: ErrorCode, message: string) =
  r.answer(Reply(error: Opt.some(engineError(code, message))))

proc answerView(r: ReplyChannel, x: Inst) =
  ## The state an operation reached; MODULE_ERROR while that state is not
  ## written (I82; RUNTIME l.3442).
  if x.pending:
    r.answerError(ecModule, NotPersisted)
  else:
    r.answer(Reply(view: x.view))

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
  if state == rtRevoked and r.calls.len > 0:
    # [SPEC CA l.917-918; CAP-0193, CAP-0194; I85] Provider code already
    # running cannot be interrupted: its invocation is marked cancelled, no
    # response is committed through the route, and the limitation is kept.
    st.diagnose(
      $r.calls.len & " admitted call(s) were still running in provider " & r.provider &
        " when route " & r.id &
        "'s authority was withdrawn; their invocations are marked cancelled and commit no response"
    )
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
    let pe = y.pendingExec
    if pe != nil:
      var waiting: seq[Waiter]
      for w in pe.waiters:
        if w.origin == x.id:
          w.reply.answerError(ecNotReady, "the Runtime Control binding is invalidated")
        else:
          waiting.add(w)
      pe.waiters = waiting
      var joined: seq[OpCtx]
      for op in pe.joined:
        if not op.q.origin.host and op.q.origin.instance == x.id:
          op.q.reply.answerError(
            ecNotReady, "the Runtime Control binding is invalidated"
          )
        else:
          joined.add(op)
      pe.joined = joined
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

# Commits --------------------------------------------------------------------------

proc snapshot(st: State): Snapshot =
  ## The persistent state as it is now (store.cddl).
  result = Snapshot(runtimeInstanceId: st.runtimeId, epoch: st.epoch)
  for x in st.instances.values:
    var s = StoredInstance(
      instance: x.id,
      providerId: x.providerId,
      created: x.created,
      record: x.record,
      state: x.state,
      failure: x.failure,
      revision: x.revision,
      intent: x.intent,
    )
    if x.intent == inRequested:
      s.intentRevision = x.intentRevision
      s.origin = x.intentOrigin
    result.instances.add(s)
  for id, assignment in st.tombstones:
    result.retired.add(RetiredId(instance: id, stateAssignment: assignment))
  result.createKeys = st.createKeys

proc persist(st: State): Result[void, string] =
  if not st.store.isPersistent:
    return ok()
  st.store.write(st.snapshot())

proc storeFailure(st: State, error: string) =
  ## [IMPL] Changes are held back until a write succeeds (I82).
  if not st.storeFailed:
    st.diagnose(NotPersisted & ": " & error)
  st.storeFailed = true
  st.nextStoreTry = getMonoTime() + StoreRetry

proc expose(st: State, x: Inst) =
  ## The change joins the ordered log (§9.1 l.1851).
  x.pending = false
  if st.store.isPersistent:
    x.shown = x.view
  inc st.serial
  if st.changes.len >= MaxRetainedChanges:
    st.changes.delete(0)
  st.changes.add(StateChange(serial: st.serial, view: x.view))

proc written(st: State, x: Inst) =
  ## A write succeeded: every change held back is exposed, one entry per
  ## instance, then `x`'s own (nil: none).
  if st.storeFailed:
    st.storeFailed = false
    st.diagnose("the execution state is persisted again")
    for y in st.instances.values:
      if y.pending and y != x:
        st.expose(y)
  if x != nil and x.pending:
    st.expose(x)

proc retryStore(st: State) =
  ## [IMPL] While writes fail: every second, and before every lifecycle
  ## request.
  if not st.storeFailed:
    return
  let w = st.persist()
  if w.isErr:
    st.storeFailure(w.error)
  else:
    st.written(nil)

proc commit(st: State, x: Inst) =
  ## Records one committed change that follows from an operation, a failure
  ## or cleanup: the execution revision advances (§9.3 l.3504-3505), the
  ## routes that depend on the instance follow it and its callers are
  ## released, at once (withdrawal never waits for a write, l.3507); then the
  ## store is written, then the change is exposed. When the write fails the
  ## change is held back (I82).
  inc x.revision
  if x.state != msStopping:
    x.stopDeadline = Opt.none(MonoTime)
  x.pending = true
  st.routesFollow(x)
  if x.state notin {msLoaded, msReady}:
    st.releaseCallers(x)
  let w = st.persist()
  if w.isErr:
    st.storeFailure(w.error)
    return
  st.written(x)

func save(x: Inst): Saved =
  Saved(
    record: x.record,
    state: x.state,
    failure: x.failure,
    revision: x.revision,
    intent: x.intent,
    intentRevision: x.intentRevision,
    intentOrigin: x.intentOrigin,
    current: x.current,
    provider: x.provider,
    pending: x.pending,
  )

proc restore(x: Inst, s: Saved) =
  x.record = s.record
  x.state = s.state
  x.failure = s.failure
  x.revision = s.revision
  x.intent = s.intent
  x.intentRevision = s.intentRevision
  x.intentOrigin = s.intentOrigin
  x.current = s.current
  x.provider = s.provider
  x.pending = s.pending

func exhausted(st: State, revision: uint64): bool =
  ## [SPEC RUNTIME l.3507; IMPL] This start's accepting commits for the
  ## instance reached the budget (I82).
  (revision and RevisionMask) >= st.budget

proc accept(st: State, x: Inst, saved: Saved, exempt = false): Opt[EngineError] =
  ## [SPEC RUNTIME §9.3 l.3505, l.3507; IMPL] Records a change that accepts an
  ## operation: written before it is exposed and before anything it permits
  ## happens. When the revision is exhausted (unless `exempt`) or the write
  ## fails, `x` is as it was (`saved`) and the error is returned (I82).
  if not exempt and st.exhausted(saved.revision):
    x.restore(saved)
    return Opt.some(engineError(ecModule, "the execution revision is exhausted"))
  inc x.revision
  x.pending = true
  let w = st.persist()
  if w.isErr:
    x.restore(saved)
    st.storeFailure(w.error)
    return Opt.some(engineError(ecModule, NotPersisted))
  if x.state != msStopping:
    x.stopDeadline = Opt.none(MonoTime)
  st.written(x)
  st.routesFollow(x)
  if x.state notin {msLoaded, msReady}:
    st.releaseCallers(x)
  Opt.none(EngineError)

# Lifecycle ----------------------------------------------------------------------

proc releaseWaiters(st: State, x: Inst) =
  ## Stop requests wait for `unloaded`.
  if x.state in {msUnloaded, msError}:
    for w in x.stopWaiters:
      w.reply.answerView(x)
    x.stopWaiters.setLen(0)

proc takeEnforced(x: Inst): Opt[Failure] =
  ## [G168 extended (I85)] What a stop reaching `unloaded` leaves as
  ## `failure`: the classification of an authority stop, once; none for any
  ## other stop (RUNTIME l.3757).
  result = x.enforced
  x.enforced = Opt.none(Failure)

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
    # cleared (an authority stop's classification kept). A stop whose deadline
    # passed already left `error`, which the end of its cleanup does not
    # change (l.611).
    x.state = msUnloaded
    x.failure = x.takeEnforced()
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
  x.exec = Opt.none(ExecAuth)
  inc x.execSerial
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

proc promote(st: State, a: Attempt) {.gcsafe.}
proc checkBinding(st: State) {.gcsafe.}

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
  a.provides = provider
  st.promote(a)

proc promote(st: State, a: Attempt) {.gcsafe.} =
  ## [SPEC RUNTIME §3.4, l.3505; IMPL] `ready`, written before it is exposed.
  ## While the write fails the instance stays `loaded`, its realization made,
  ## and the write is tried again every second until the startup deadline
  ## (`checkDeadlines`; I82).
  let x = a.inst
  let saved = x.save
  x.provider = a.provides
  x.state = msReady
  if st.accept(x, saved, exempt = true).isSome:
    a.phase = apReadyPending
    return
  x.services = a.services
  a.services = nil
  # [SPEC RUNTIME l.1679-1680] A Capability Authority is bound before its
  # start is answered.
  st.checkBinding()
  st.finishAttempt(a)

proc abandon(st: State, a: Attempt) =
  ## [IMPL] An attempt whose `ready` was never written can no longer make the
  ## instance ready (a stop, a reported failure, its deadline): the
  ## realization it made is released through the realizer, as one made after
  ## the deadline (§3.4 l.668).
  if a.phase == apReadyPending:
    a.phase = apCleanup
    st.releaseRealization(a.inst)

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

# Authority (step 8b; DECISIONS I85) ------------------------------------------------------
#
# [IMPL] Every check point builds its `AuthzRequest`s and asks `decide`. An
# answer comes from the operation's decisions so far, the internal policy, the
# derived bootstrap or recovery rules, the decision cache, or a new
# evaluation on the evaluation lane. An operation whose answer needs an
# evaluation is parked: its handler returns without answering and runs again,
# from the top, once every evaluation answered (at most `MaxPasses` passes).
# This is safe because every handler obtains all its decisions before its
# first mutation. A start or recovery, which mutates intent before execution
# authorization (RUNTIME l.3644), waits in `PendingExec` instead
# (`decideDetached`).

proc handle(st: State, q: Request) {.gcsafe.}
proc beginAttempt(st: State, a: Attempt) {.gcsafe.}
proc stopInstance(
  st: State,
  x: Inst,
  reply: ReplyChannel,
  keepIntent: bool,
  origin = "",
  enforcement = false,
) {.gcsafe.}

proc reauthRoutes(st: State, grant: string) {.gcsafe.}
proc invalidateRoutes(st: State) {.gcsafe.}

func authorityMode(st: State): bool =
  st.cfg.authority.isSome

func moduleOf(x: Inst): string =
  if x.isNil: "" else: x.record.module

proc wallNow(st: State): uint64 =
  uint64(max(st.clock.wallMs, 0))

proc monoNow(st: State): int64 =
  st.clock.monoNs

proc evaluationDeadline(st: State): Duration =
  let d = st.cfg.authority.get(AuthorityPolicy()).evaluationDeadline
  if d <= initDuration(): DefaultEvaluationDeadline else: d

proc derivedRule(st: State, q: AuthzRequest): bool =
  ## [SPEC RUNTIME l.1635-1650, l.1674-1680; plan §2.13] The rules protected
  ## input derives while no binding exists: orchestration may start, recover,
  ## stop and observe the authority instance, which executes with
  ## orchestration as its origin. Before the first binding they are bootstrap
  ## policy; after a loss, recovery policy, and only when the host
  ## configuration enables it (RUN-0860 to RUN-0863). Nothing else, and never
  ## the authority acting for itself (RUN-0701).
  let a = st.cfg.authority.get
  if st.everBound and not a.recovery:
    return false
  let o = st.orchestrator
  if o.isNil or q.consumer != o.id or q.providerSelector or q.instance != a.instance:
    return false
  case q.action
  of aaLifecycle:
    q.operation in ["start_module", "recover_module", "stop_module"]
  of aaObserve:
    q.operation == "get_readiness"
  of aaExecute, aaStop:
    true
  else:
    false

proc failure(st: State, q: AuthzRequest, reason: string): AuthzAnswer =
  ## [SPEC RUNTIME l.1740-1744; CAP-0153] No valid decision was obtained:
  ## retained as an evaluation failure, never as a deny.
  st.authorizer.issue(q, azEvaluationFailed, psAuthority, reason)

proc immediate(st: State, q: AuthzRequest): Opt[AuthzAnswer] =
  ## The answer that needs no evaluation, if there is one.
  if not st.authorityMode:
    return Opt.some(st.authorizer.decide(q))
  if q.consumer.len == 0:
    # [SPEC RUNTIME l.1640, l.1690; RUN-0858] The host's protected input; the
    # engine is never a consumer.
    return Opt.some(st.authorizer.issue(q, azAllow, psBootstrap))
  if st.caInst.isNil:
    if st.derivedRule(q):
      return Opt.some(
        st.authorizer.issue(q, azAllow, (if st.everBound: psRecovery else: psBootstrap))
      )
    # [SPEC RUNTIME l.245-257, l.1674-1680, l.3813-3818; RUN-0050, RUN-0051,
    # RUN-0859; CAP-0260] Nothing falls back to less constrained behaviour.
    return Opt.some(st.failure(q, "no Capability Authority binding"))
  Opt.none(AuthzAnswer)

func bypassesCache(q: AuthzRequest): bool =
  ## [SPEC CA l.857, l.859; RUNTIME l.3184, l.3539; I85] Each needs a new
  ## evaluation and is never stored.
  q.action in {aaExecute, aaStop} or
    (q.action == aaRoute and q.operation == "renew_route")

proc fill(st: State, p: Pending, i: int, answer: AuthzAnswer) =
  if p.done or p.filled[i]:
    return
  p.answers[i] = answer
  p.filled[i] = true
  dec p.remaining
  if p.remaining == 0:
    p.done = true
    st.pendings.del(p.id)
    p.then(p.answers)

proc dispatchEval(st: State, job: sink EvalJob, renewal: bool) =
  let s = st.shared
  if renewal:
    inc st.renewBusy
    if not s.renewSpawned:
      try:
        createThread(s.renewWorker, renewWorkerMain, s)
        s.renewSpawned = true
      except ResourceExhaustedError:
        discard # [IMPL] the renewal waits; its deadline fails it closed
    try:
      s.renewals.send(job)
    except Exception:
      discard
    return
  inc st.evalBusy
  if st.evalBusy > s.evalSpawned and s.evalSpawned < EvalWorkers:
    try:
      createThread(s.evalWorkers[s.evalSpawned], evalWorkerMain, s)
      inc s.evalSpawned
    except ResourceExhaustedError:
      discard # the evaluation waits for a busy worker
  try:
    s.evals.send(job)
  except Exception:
    discard

proc startEval(
    st: State, p: Pending, i: int, bytes: seq[byte], cacheable: bool, retries = 0
) =
  ## [plan §2.4] One `evaluate` on the ordinary lane, or on the renewal lane
  ## for an execution renewal (CA §5.1). The authority's in-flight count
  ## holds its realization until the evaluation returns.
  let q = p.reqs[i]
  let ca = st.caInst
  if ca.isNil or ca.state != msReady or ca.current != st.boundToken or
      ca.realization.isNil or ca.services.isNil:
    # [CAP-0344] The binding is being lost; nothing is admitted under it.
    st.fill(p, i, st.failure(q, "no Capability Authority binding"))
    return
  if not q.renewal and st.evalBusy >= EvalWorkers + EvalQueue:
    # [IMPL] An admission failure before evaluation begins. [CA §5.1
    # l.592-595] Ordinary saturation never takes the renewal lane's place;
    # there is at most one renewal per running instance (`MaxInstances`).
    st.fill(p, i, st.failure(q, "the evaluation queue is full"))
    return
  inc st.nextEval
  let e = Eval(
    id: st.nextEval,
    gen: st.gen,
    pending: p,
    index: i,
    bytes: bytes,
    authority: ca,
    ticket: newTicket(),
    seqAt: st.invalidations,
    retries: retries,
    cacheable: cacheable,
    renewal: q.renewal,
  )
  st.evals[e.id] = e
  inc ca.inflight
  let b = ca.realization.binding
  st.dispatchEval(
    EvalJob(
      kind: ejRun,
      id: e.id,
      request: bytes,
      dispatch: b.dispatch,
      free: b.free,
      context: ca.realization.context,
      access: ca.services,
      ticket: e.ticket,
      runtimeId: st.runtimeId,
    ),
    e.renewal,
  )

proc decideDetached(
    st: State, reqs: seq[AuthzRequest], then: Then, abort: Abort = nil
) =
  ## [IMPL; C21] Decides `reqs` together, evaluating the ones that need it in
  ## parallel. `then` gets every answer, in order, on the Runtime thread: at
  ## once when none needs an evaluation. After shutdown is accepted no
  ## evaluation begins and `abort` runs instead (I85).
  let p = Pending(
    reqs: reqs,
    answers: newSeq[AuthzAnswer](reqs.len),
    filled: newSeq[bool](reqs.len),
    remaining: reqs.len,
    then: then,
    abort: abort,
  )
  var toEval: seq[(int, seq[byte], bool)]
  for i, q in reqs:
    var answer = st.immediate(q)
    if answer.isNone:
      let bytes = encodeRequest(q, st.runtimeId)
      if bytes.isErr:
        answer =
          Opt.some(st.failure(q, "the request cannot be expressed: " & bytes.error))
      else:
        let cacheable = not q.bypassesCache
        if cacheable:
          answer = st.cache.get(cacheKey(st.gen, bytes.get), st.wallNow, st.monoNow)
        if answer.isNone:
          toEval.add((i, bytes.get, cacheable))
    if answer.isSome:
      p.answers[i] = answer.get
      p.filled[i] = true
      dec p.remaining
  if p.remaining == 0:
    p.done = true
    then(p.answers)
    return
  if st.shuttingDown:
    p.done = true
    if abort != nil:
      abort()
    else:
      for (i, _, _) in toEval:
        p.answers[i] = st.failure(reqs[i], "the Runtime is shutting down")
      then(p.answers)
    return
  inc st.nextPending
  p.id = st.nextPending
  p.deadline = getMonoTime() + st.evaluationDeadline
  st.pendings[p.id] = p
  for (i, bytes, cacheable) in toEval:
    st.startEval(p, i, bytes, cacheable)

type DecideCtx = ref object
  sync, completed, aborted: bool

proc rerun(st: State, op: OpCtx) =
  ## The parked operation's handler again, with the decisions it has.
  inc op.passes
  let saved = st.op
  st.op = op
  st.handle(op.q)
  st.op = saved

proc captureOf(st: State, q: AuthzRequest, a: AuthzAnswer): CallCapture =
  ## [SPEC CA l.1176-1180; CAP-0389 to CAP-0392] The snapshot of an applied
  ## call decision: its own id (a cached decision's too), the enforced call
  ## scope and its retention; empty when it requires no record.
  if not a.allows or not (a.retainRequest or a.retainResponse):
    return CallCapture()
  let scope = enforcedScope(q, st.runtimeId).valueOr:
    return CallCapture()
  CallCapture(
    decisionId: a.decisionId,
    scope: scope,
    retainRequest: a.retainRequest,
    retainResponse: a.retainResponse,
    runtimeId: st.runtimeId,
    consumer: q.consumer,
  )

proc captureRc(st: State, reqs: openArray[AuthzRequest], answers: seq[AuthzAnswer]) =
  ## [SPEC CA l.1184-1188; CAP-0209] The decision applied to a Runtime Control
  ## call is the one over its Runtime Control scope (a `stop_module`'s
  ## execution decision is not); its capture goes back with the call's reply
  ## (`answer`), and the caller records the call after its outcome.
  let q = st.op.q
  let bare = (if q.kind == rqRc: $q.rc.m else: q.bare)
  for i, r in reqs:
    if r.action in {aaRuntimeControl, aaLifecycle, aaObserve} and r.operation == bare:
      let c = st.captureOf(r, answers[i])
      if c.retains:
        keepCapture(cast[pointer](q.reply), c)

proc shuttingDownReply(q: Request) =
  q.reply.answerError(ecNotReady, "the Runtime is shutting down")

proc decide(st: State, reqs: openArray[AuthzRequest]): Opt[seq[AuthzAnswer]] =
  ## [IMPL] The answers to `reqs`, or none when the operation is parked (its
  ## handler returns and runs again once its evaluations answer) or was
  ## answered NOT_READY because shutdown closed admission.
  var op = st.op
  if op.isNil:
    op = OpCtx() # [IMPL] no request to run again: a parked answer is dropped
  var todo: seq[AuthzRequest]
  for q in reqs:
    if q.key notin op.decided:
      var dup = false
      for t in todo:
        if t.key == q.key:
          dup = true
      if not dup:
        todo.add(q)
  if todo.len > 0:
    if op.passes >= MaxPasses:
      for q in todo:
        op.decided[q.key] = st.failure(q, "the operation took too many passes")
    else:
      let ctx = DecideCtx(sync: true)
      let operation = op
      let asked = todo
      st.decideDetached(
        asked,
        proc(got: seq[AuthzAnswer]) =
          for j, a in got:
            operation.decided[asked[j].key] = a
          ctx.completed = true
          if not ctx.sync:
            st.rerun(operation)
        ,
        proc() =
          ctx.aborted = true
          if not ctx.sync:
            shuttingDownReply(operation.q)
        ,
      )
      ctx.sync = false
      if ctx.aborted:
        shuttingDownReply(op.q)
        return Opt.none(seq[AuthzAnswer])
      if not ctx.completed:
        return Opt.none(seq[AuthzAnswer])
  var answers: seq[AuthzAnswer]
  for q in reqs:
    answers.add(op.decided.getOrDefault(q.key))
  if st.op != nil and st.op.q.kind in {rqRc, rqRcPrecheck}:
    st.captureRc(reqs, answers)
  Opt.some(answers)

const Parked = EngineError(code: ecOk, message: "parked")
  ## [IMPL] what a check gives when its operation was parked or answered

func parked(e: EngineError): bool =
  e.code == ecOk

proc answerFailure(q: Request, e: EngineError) =
  if not e.parked:
    q.reply.answerError(e.code, e.message)

func notAuthorised(): EngineError =
  engineError(ecNotAuthorised, "not authorised")

proc check(st: State, reqs: varargs[AuthzRequest]): Opt[EngineError] =
  ## [SPEC RUNTIME l.1737-1748; TL-04] None when every request is allowed;
  ## otherwise NOT_AUTHORISED, the same for a deny, an evaluation failure and
  ## an allow that excludes the operation (the code is only retained), or
  ## `Parked`.
  let d = st.decide(@reqs).valueOr:
    return Opt.some(Parked)
  for a in d:
    if not a.allows:
      return Opt.some(notAuthorised())
  Opt.none(EngineError)

template require(st: State, q: Request, reqs: varargs[AuthzRequest]) =
  let refused = st.check(reqs)
  if refused.isSome:
    q.answerFailure(refused.get)
    return

proc requestBytes(st: State, q: AuthzRequest): seq[byte] =
  encodeRequest(q, st.runtimeId).get(newSeq[byte]())

# Execution authorization over time (CA §8 l.828-866; plan §2.9, §2.10) ---------------

func executing(x: Inst): bool =
  ## An attempt or realization running under an authorization that ends.
  x.state in {msLoaded, msReady} and x.exec.isSome and x.exec.get.ends

func failureKind(e: ExecEnding): FailureKind =
  case e
  of eeExpired: fkAuthorityExpired
  of eeRevoked: fkAuthorityRevoked
  of eeDenied: fkAuthorityDenied
  of eeNone, eeFailed: fkAuthorityEvaluationFailed

proc stopForAuthority(st: State, x: Inst, kind: FailureKind) =
  ## [SPEC RUNTIME §10.1 l.3801-3804; CA l.854; plan §2.10] An ended execution
  ## authorization stops the instance at once, without waiting for a
  ## re-evaluation or a renewal answer (CAP-0349): its Runtime Control binding
  ## and admissions into it end as it enters `stopping` (RUN-0904), its
  ## routes follow (G170), its cleanup asks no stop grant (CAP-0291), and
  ## intent and origin stay (RUN-1066). It ends `unloaded` with `failure` set
  ## to `kind`, or `error` with `cleanup-timeout` when the stop deadline
  ## passes [G168 extended]. Orchestration resumes it with `recover_module`
  ## (RUN-0696); the engine never restarts it (RUN-0693).
  if x.state notin {msLoaded, msReady}:
    return
  st.diagnose("the execution authorization of " & x.id & " ended: " & $kind)
  x.enforced = Opt.some(Failure(kind: kind))
  st.stopInstance(x, nil, keepIntent = true, enforcement = true)

proc endExecution(st: State, x: Inst, ending: ExecEnding) =
  if ending != eeNone:
    st.stopForAuthority(x, ending.failureKind)

proc execRenewed(st: State, x: Inst, serial: int, a: AuthzAnswer) =
  ## [SPEC CA l.855-862; plan §2.9] A renewal's answer, unless the
  ## authorization it renews has ended meanwhile.
  if x.execSerial != serial or not x.executing:
    return
  st.endExecution(x, x.exec.get.renewed(a, st.gen, st.wallNow, st.monoNow))

proc renewExecution(st: State, x: Inst) =
  ## [SPEC CA §5.1 l.577-579, l.855-856; CAP-0304, CAP-0311] Before the
  ## validity end: the same decision for the same retained consumer, target
  ## and scopes, with `execution_renewal`, on the renewal lane. The field is
  ## set only here, while the authorization is valid.
  x.exec.get.renewing = true
  let serial = x.execSerial
  var q = x.exec.get.request
  q.renewal = true
  st.decideDetached(
    @[q],
    proc(got: seq[AuthzAnswer]) =
      st.execRenewed(x, serial, got[0]),
    proc() =
      discard, # [I85] shutdown; the validity end still applies
  )

proc checkExecutions(st: State) =
  ## [SPEC CA l.857-858; CAP-0342, CAP-0352] A validity end reached on either
  ## clock stops the instance as `authority-expired`, with no grace; a
  ## renewal is asked for when it is due (not after shutdown is accepted).
  var due: seq[Inst]
  for x in st.instances.values:
    if x.executing:
      due.add(x)
  for x in due:
    if not x.executing:
      continue
    if x.exec.get.expired(st.wallNow, st.monoNow):
      st.stopForAuthority(x, fkAuthorityExpired)
    elif not st.shuttingDown and x.exec.get.renewalDue(st.monoNow):
      st.renewExecution(x)

proc nextExecution(st: State): Opt[MonoTime] =
  ## When the Runtime thread next looks at an execution authorization, on the
  ## real monotonic clock.
  var t = Opt.none(int64)
  for x in st.instances.values:
    if x.executing:
      let ev = if st.shuttingDown: x.exec.get.deadline else: x.exec.get.nextEvent
      if ev.isSome and (t.isNone or ev.get < t.get):
        t = ev
  if t.isNone:
    return Opt.none(MonoTime)
  Opt.some(getMonoTime() + initDuration(nanoseconds = max(t.get - st.monoNow, 0)))

type Ending =
  proc(id: string, x: var ExecAuth): ExecEnding {.closure, gcsafe, raises: [].}

proc endExecutions(st: State, ending: Ending) =
  ## Each running execution's authorization through `ending`; those it ends
  ## are stopped once every one has been looked at.
  var hit: seq[(Inst, ExecEnding)]
  for x in st.instances.values:
    if x.executing:
      let e = ending(x.id, x.exec.get)
      if e != eeNone:
        hit.add((x, e))
  for (x, e) in hit:
    st.endExecution(x, e)

# The binding -----------------------------------------------------------------------------

proc bindingRefusal(st: State, x: Inst): string =
  ## [SPEC RUNTIME l.1652-1667: RUN-0314 to RUN-0317; CA §1: CAP-0003,
  ## CAP-0005, CAP-0006] A local instance realized in direct mode (every
  ## realization here is), `ready`, whose primary contract is the pinned
  ## Capability Authority contract, with a generic dispatch through which
  ## `evaluate`, `grant_changed` and `policy_changed` resolve. Empty when
  ## bindable.
  if x.realization.isNil or x.services.isNil:
    return "it has no realization"
  let roots = caRoots()
  let root = toDigest(roots.contract)
  let b = x.realization.binding
  if b.dispatch.isNil:
    return "it has no generic dispatch"
  let primary = b.contracts.primary
  # A record that names no primary contract is checked by what the
  # realization exposes (RUN-0316), as host configuration says.
  if root.isNone or
      (x.record.primaryContract.isSome and x.record.primaryContract != root) or
      primary.isNone or primary.get.root != root.get:
    return "its primary contract is not the pinned Capability Authority contract"
  let sel = selectContract(b.contracts, root.get, st.ctx)
  if sel.isNone or sel.get.methodRoot("evaluate") != toDigest(roots.evaluate):
    return "evaluate does not resolve"
  if sel.get.eventRoot(GrantChangedName) != toDigest(roots.grantChanged) or
      sel.get.eventRoot(PolicyChangedName) != toDigest(roots.policyChanged):
    return "its notifications do not resolve"
  ""

proc failOutstanding(st: State, reason: string, shutdown = false) =
  ## Every outstanding evaluation is abandoned: its invocation is marked
  ## cancelled and its late result discarded. Its operation gets an
  ## evaluation failure, or at shutdown its `abort`.
  var ps: seq[Pending]
  for p in st.pendings.values:
    ps.add(p)
  for e in st.evals.values:
    e.abandoned = true
    e.ticket.cancelled.store(true)
  for p in ps:
    if p.done:
      continue
    if shutdown and p.abort != nil:
      p.done = true
      st.pendings.del(p.id)
      p.abort()
    else:
      for i in 0 ..< p.reqs.len:
        if not p.filled[i]:
          st.fill(p, i, st.failure(p.reqs[i], reason))

proc loseBinding(st: State, reason: string) =
  ## [SPEC CA §8 l.826-832, l.872-878; plan §2.3] In one step: admission
  ## under the old generation closes (CAP-0344, CAP-0346), parked evaluations
  ## are answered as evaluation failures and their late results discarded,
  ## and the cache is cleared (CAP-0172, CAP-0345). [I85] Shutdown is not
  ## binding loss: parked operations were answered NOT_READY when it was
  ## accepted.
  if st.caInst.isNil:
    return
  st.caInst = nil
  st.boundToken = ""
  inc st.gen
  st.cache.clear()
  if st.shuttingDown:
    return
  st.diagnose("the Capability Authority binding is lost: " & reason)
  st.failOutstanding("the Capability Authority binding was lost")
  # [SPEC CA l.828; plan §2.13; I85] Every execution it authorized ends,
  # classified `authority-evaluation-failed`; bootstrap- and
  # recovery-authorized ones (orchestration, the authority) keep running.
  st.endExecutions(
    proc(id: string, x: var ExecAuth): ExecEnding =
      eeFailed
  )
  st.invalidateRoutes()

proc checkBinding(st: State) {.gcsafe.} =
  ## [SPEC RUNTIME l.1652-1667, l.1679-1680; plan §2.3] After every step: the
  ## binding is lost when its instance leaves `ready` or its realization
  ## changes, and established, with a fresh generation and its notification
  ## path, once the configured instance is `ready`, exposed and passes the
  ## checks, before any later request is handled. The host configuration
  ## authorizes it, never the candidate (RUN-0307, RUN-0308; CAP-0008).
  if not st.authorityMode:
    return
  let id = st.cfg.authority.get.instance
  let x = st.instances.getOrDefault(id)
  if st.caInst != nil and (
    x != st.caInst or x.state != msReady or x.current != st.boundToken or
    x.realization.isNil
  ):
    st.loseBinding(
      "the authority instance is " & (if x.isNil: "retired" else: $x.state)
    )
  if st.caInst.isNil and not st.shuttingDown and x != nil and x.state == msReady and
      not x.pending:
    let refused = st.bindingRefusal(x)
    if refused.len == 0:
      inc st.gen # [CAP-0344] fresh for each establishment
      st.caInst = x
      st.boundToken = x.current
      st.everBound = true
      st.bindNote = ""
      # [RUN-0855] An equal revision under a new binding gives no continuity.
      st.policyRevision = 0
      st.revokedGrants.setLen(0)
    elif st.bindNote != x.current:
      st.bindNote = x.current
      st.diagnose("the authority instance " & x.id & " is not bound: " & refused)

# Evaluation results ----------------------------------------------------------------------

proc isStale(st: State, e: Eval, res: EvalResult): bool =
  ## [CAP-0343] A result made before a notice processed since its dispatch.
  if res.policyRevision < st.policyRevision:
    return true
  for (n, g) in st.revokedGrants:
    if n > e.seqAt and g in res.grants:
      return true
  false

proc evaluated(st: State, id: int, res: EvalResult) =
  ## [plan §2.4] One evaluation's verdict on the Runtime thread: dropped when
  ## abandoned (a deadline, a lost binding, shutdown), evaluated again when a
  ## notice made it stale, an evaluation failure when it expired before use
  ## (CAP-0260), otherwise retained, cached when eligible, and given to its
  ## operation.
  var e: Eval
  if not st.evals.pop(id, e):
    return
  if e.renewal:
    dec st.renewBusy
  else:
    dec st.evalBusy
  freeTicket(e.ticket)
  let ca = e.authority
  dec ca.inflight
  if ca.inflight == 0 and ca.releasePending:
    st.releaseRealization(ca)
  let p = e.pending
  if e.abandoned or e.gen != st.gen or p.done or p.filled[e.index]:
    return
  let q = p.reqs[e.index]
  if res.verdict != evFailed and st.isStale(e, res):
    if e.retries + 1 >= MaxPasses:
      st.fill(p, e.index, st.failure(q, "the decisions kept going stale"))
    else:
      st.startEval(p, e.index, e.bytes, e.cacheable, e.retries + 1)
    return
  var a = AuthzAnswer(source: psAuthority, scope: q.scopeOf, request: q)
  case res.verdict
  of evFailed:
    a.decisionId = st.authorizer.nextId()
    a.outcome = azEvaluationFailed
    a.errorCode = res.errorCode
    a.reason = res.reason
  of evAllow, evDeny:
    a.decisionId = res.decisionId
    a.outcome = (if res.verdict == evAllow: azAllow else: azDeny)
    a.policyRevision = res.policyRevision
    a.issuedAt = res.issuedAt
    a.validUntil = res.validUntil
    a.grants = res.grants
    a.retainRequest = res.retainRequest
    a.retainResponse = res.retainResponse
    a.allowed = res.allowed
    a.denialCode = res.denialCode
    if res.validUntil.isSome and st.wallNow >= res.validUntil.get:
      # [CAP-0260, CAP-0342] expired before it could be used
      a.outcome = azEvaluationFailed
      a.reason = "the decision expired before it was used"
    elif a.outcome == azAllow:
      a.narrowed = a.narrowedFor(e.bytes, st.runtimeId)
  st.authorizer.retain(a)
  if a.outcome == azAllow and not a.narrowed and a.validUntil.isSome and e.cacheable:
    let left = int64(a.validUntil.get - st.wallNow)
    st.cache.put(cacheKey(e.gen, e.bytes), a, st.monoNow + left * 1_000_000)
  st.fill(p, e.index, a)

proc checkEvaluations(st: State, now: MonoTime) =
  ## [IMPL] The evaluation deadline: the operation gets an evaluation failure
  ## and the hung `evaluate`'s invocation is marked cancelled; its late
  ## result is discarded.
  var due: seq[Pending]
  for p in st.pendings.values:
    if not p.done and now >= p.deadline:
      due.add(p)
  for p in due:
    for e in st.evals.values:
      if e.pending == p:
        e.abandoned = true
        e.ticket.cancelled.store(true)
    for i in 0 ..< p.reqs.len:
      if not p.filled[i]:
        st.fill(p, i, st.failure(p.reqs[i], "the evaluation deadline passed"))

# Notifications ---------------------------------------------------------------------------

proc pathLoss(st: State, reason: string) =
  ## [SPEC CA §8 l.893-897; CAP-0177, CAP-0183] The notification path is
  ## lost: binding loss, then [IMPL] a new binding at once when the authority
  ## is still ready, with a fresh generation and nothing carried over.
  st.loseBinding("the notification path is lost: " & reason)
  st.checkBinding()

proc grantEnded(st: State, grant: string, expired: bool) =
  ## [SPEC CA l.884-891, l.913; CAP-0185, CAP-0170] A revoked or expired
  ## grant: the decisions listing it are no longer used, and the executions
  ## whose authorization used it end.
  inc st.invalidations
  if st.evals.len == 0:
    st.revokedGrants.setLen(0)
  else:
    var oldest = high(uint64)
    for e in st.evals.values:
      oldest = min(oldest, e.seqAt)
    st.revokedGrants.keepItIf(it[0] > oldest)
    st.revokedGrants.add((st.invalidations, grant))
  st.cache.dropGrant(grant)
  st.endExecutions(
    proc(id: string, x: var ExecAuth): ExecEnding =
      x.onGrantEnded(grant, expired)
  )
  st.reauthRoutes(grant)

proc policyChanged(st: State, n: Notice) =
  ## [SPEC CA l.845-850, l.899-903; CAP-0184, CAP-0166 to CAP-0169] The cache
  ## is cleared and every execution authorization not kept by the retention
  ## rule ends as revoked (`execauth.onPolicyChange`).
  inc st.invalidations
  st.policyRevision = max(st.policyRevision, n.revision)
  st.cache.clear()
  let gen = st.gen
  st.endExecutions(
    proc(id: string, x: var ExecAuth): ExecEnding =
      x.onPolicyChange(n, id, gen)
  )
  st.reauthRoutes("")

proc notice(st: State, q: Request) =
  ## [SPEC CA §8 l.884-903; RUNTIME l.1660-1667; plan §2.8] A notice from the
  ## publishing thread, in order with every admission (CAP-0341). Under
  ## internal policy it is an ordinary publication (`admitted` false).
  ## Otherwise it is consumed: one not from the bound authority's current
  ## realization is ignored; one that does not read is notification-path
  ## loss. Issuance invalidates nothing (CAP-0171).
  if not st.authorityMode:
    q.reply.answer(Reply())
    return
  q.reply.answer(Reply(admitted: true))
  let x = st.caInst
  if x.isNil or q.origin.instance != x.id or q.attempt != st.boundToken:
    st.diagnose(
      "a " & q.bare & " notice from " & q.origin.instance &
        ", which is not the bound authority, was ignored"
    )
    return
  if q.payload.len == 0:
    st.pathLoss("a notice was dropped")
    return
  let n = readNotice(q.bare, q.payload, st.runtimeId).valueOr:
    st.pathLoss(error)
    return
  case n.kind
  of nkGrant:
    if n.ended:
      st.grantEnded(n.grant, n.expired)
  of nkPolicy:
    st.policyChanged(n)

# Facts -------------------------------------------------------------------------------------

proc putFacts(st: State, x: Inst) =
  ## [G47; C11] The attribute source learns an instance before it is exposed.
  let f = st.cfg.facts
  if f == nil:
    return
  putInstance(f, x.id, InstanceFacts(module: x.record.module)).isOkOr:
    st.diagnose("the attribute source refused instance " & x.id & ": " & error)
    return
  if x.providerId.len > 0:
    putProvider(f, x.providerId, x.id).isOkOr:
      st.diagnose(
        "the attribute source refused provider " & x.providerId & ": " & error
      )

proc dropFacts(st: State, x: Inst) =
  let f = st.cfg.facts
  if f != nil:
    if x.providerId.len > 0:
      discard removeProvider(f, x.providerId)
    removeInstance(f, x.id).isOkOr:
      st.diagnose("the attribute source kept instance " & x.id & ": " & error)
  st.cache.dropInstance(x.id)

# Routes under authority ------------------------------------------------------------------

proc expired(st: State, r: Route): bool =
  ## [SPEC RUNTIME l.2996, l.3168-3176; RUN-0939] At `expires_at` by the wall
  ## clock or by the monotonic deadline fixed when it was set.
  r.expiresAt.isSome and (
    st.wallNow >= r.expiresAt.get or
    (r.monoDeadline.isSome and st.monoNow >= r.monoDeadline.get)
  )

proc expireIfDue(st: State, r: Route) =
  ## [TL-03 interim (G218)] An expired route is `revoked` with
  ## `authority-expired`: its handles and observers get NOT_AUTHORISED
  ## (RUN-0550, CAP-0050, RUN-0836) and it cannot be renewed (l.3188).
  if r != nil and not r.isTerminal and st.expired(r):
    st.endRoute(r, rtRevoked, Opt.some(rfAuthorityExpired))

proc expireRoutes(st: State) =
  var due: seq[Route]
  var gone: seq[string]
  for id in st.timed:
    let r = st.routes.getOrDefault(id)
    if r.isNil or r.isTerminal:
      gone.add(id)
    elif st.expired(r):
      due.add(r)
      gone.add(id)
  for id in gone:
    st.timed.excl(id)
  for r in due:
    st.endRoute(r, rtRevoked, Opt.some(rfAuthorityExpired))

proc setValidity(st: State, r: Route, a: AuthzAnswer) =
  ## [SPEC RUNTIME l.3157-3166; RUN-0938] A Capability Authority route allow
  ## sets `expires_at` to its `valid_until`.
  r.decisionId = a.decisionId
  r.grants = a.grants
  r.authority = a.source == psAuthority
  if a.source == psAuthority and a.validUntil.isSome:
    r.expiresAt = a.validUntil
    let left = int64(a.validUntil.get) - int64(st.wallNow)
    r.monoDeadline = Opt.some(st.monoNow + max(left, 0) * 1_000_000)
    st.timed.incl(r.id)
  else:
    r.expiresAt = Opt.none(uint64)
    r.monoDeadline = Opt.none(int64)

proc nextExpiry(st: State): Opt[MonoTime] =
  ## When the Runtime thread next checks route validity, on the real
  ## monotonic clock.
  var t = Opt.none(MonoTime)
  for id in st.timed:
    let r = st.routes.getOrDefault(id)
    if r != nil and r.monoDeadline.isSome:
      let d =
        getMonoTime() +
        initDuration(nanoseconds = max(r.monoDeadline.get - st.monoNow, 0))
      if t.isNone or d < t.get:
        t = Opt.some(d)
  t

# Execution authorization (RUNTIME §3.6 step 3; plan §2.9) ------------------------------

proc answerExec(pe: PendingExec, code: ErrorCode, message: string) =
  for w in pe.waiters:
    w.reply.answerError(code, message)
  pe.waiters.setLen(0)
  for op in pe.joined:
    op.q.reply.answerError(code, message)
  pe.joined.setLen(0)

proc cancelExec(st: State, x: Inst, pe: PendingExec) =
  ## [I85] Shutdown was accepted while the execution decision was pending:
  ## the start and every start that joined it are NOT_READY; intent stays.
  if pe.cancelled:
    return
  pe.cancelled = true
  if x.pendingExec == pe:
    x.pendingExec = nil
  pe.answerExec(ecNotReady, "the Runtime is shutting down")

proc executeDecided(st: State, x: Inst, pe: PendingExec, a: AuthzAnswer) =
  ## [SPEC RUNTIME §3.6, §9.3; C17] The execution decision for an accepted
  ## start or recovery.
  if pe.cancelled or x.pendingExec != pe:
    return
  x.pendingExec = nil
  if not a.allows:
    # [G168 interim] NOT_AUTHORISED; the state stays, the failure records why
    # and intent stays `requested` with its origin. [IMPL] A narrowed allow
    # is `authority-denied`. Each start that joined is then taken again as a
    # fresh acceptance, with its own origin (I85).
    x.failure = Opt.some(
      Failure(
        kind: (
          if a.outcome == azEvaluationFailed: fkAuthorityEvaluationFailed
          else: fkAuthorityDenied
        )
      )
    )
    st.commit(x)
    for w in pe.waiters:
      w.reply.answerError(ecNotAuthorised, "execution is not authorised")
    let joined = pe.joined
    pe.joined.setLen(0)
    for op in joined:
      st.rerun(op)
    return
  if x.state notin {msUnloaded, msError} or x.attempt != nil or x.teardown != 0 or
      x.realization != nil or x.intent != inRequested or not st.prerequisitesReady(x):
    pe.answerExec(ecNotReady, "the module instance can no longer start")
    return
  # The attempt is accepted: `loaded`, failure cleared (§9.3 l.3758-3759),
  # written before the attempt begins (l.3505).
  var waiters = pe.waiters
  for op in pe.joined:
    waiters.add(Waiter(reply: op.q.reply, origin: op.q.origin.instance))
  let saved = x.save
  let id = st.nextJobId()
  let at = Attempt(
    id: id,
    token: "a-" & st.prefix & "-" & $id,
    inst: x,
    deadline: getMonoTime() + st.cfg.startupDeadline,
    waiters: waiters,
  )
  x.current = at.token
  x.state = msLoaded
  x.failure = Opt.none(Failure)
  x.enforced = Opt.none(Failure)
  x.provider = false
  let refused = st.accept(x, saved)
  if refused.isSome:
    for w in waiters:
      w.reply.answerError(refused.get.code, refused.get.message)
    return
  # [SPEC CA §8 l.828-866; plan §2.9] The authorization the attempt runs
  # under, with its validity end and renewal time.
  x.exec = Opt.some(authorization(a, st.gen, st.wallNow, st.monoNow))
  inc x.execSerial
  st.beginAttempt(at)

proc execute(st: State, x: Inst, reply: ReplyChannel, origin: string) {.gcsafe.} =
  ## [SPEC RUNTIME §3.6, §9.3] What `start` and `recover` share once intent is
  ## `requested`: prerequisites, execution authorization for the retained
  ## origin (pending meanwhile, `PendingExec`), the accepting commit, then
  ## the attempt (`beginAttempt`).
  if not st.prerequisitesReady(x):
    # [SPEC RUNTIME §3.7, §10.1] A dependent waits for every prerequisite.
    reply.answerError(ecNotReady, "a lifecycle prerequisite is not ready")
    return
  # [SPEC RUNTIME §3.6 step 3] Execution authorization, for the retained
  # origin, before any artifact code runs.
  let pe = PendingExec(waiters: @[Waiter(reply: reply, origin: origin)])
  x.pendingExec = pe
  let q = AuthzRequest(
    action: aaExecute,
    operation: "execute",
    consumer: (if x.intentOrigin.host: "" else: x.intentOrigin.instance),
    target: x.id,
    instance: x.id,
    module: x.record.module,
  )
  st.decideDetached(
    @[q],
    proc(got: seq[AuthzAnswer]) =
      st.executeDecided(x, pe, got[0]),
    proc() =
      st.cancelExec(x, pe),
  )

proc joinExec(st: State, x: Inst): bool =
  ## [I85] A start or recovery while one is waiting for its execution
  ## decision joins it: answered with its attempt's outcome, or taken again
  ## from the top when the decision refuses.
  let pe = x.pendingExec
  if pe.isNil or pe.cancelled or st.op.isNil:
    return false
  pe.joined.add(st.op)
  true

proc lookup(st: State, q: Request, operation: string): Result[Inst, EngineError] =
  ## [SPEC RUNTIME §9.3 l.3661-3662] For a module consumer, an unknown target
  ## and a refused one are the same NOT_AUTHORISED; a module-name mismatch is
  ## INVALID_PARAMS only after authorization (l.3663-3664). [I85] Under the
  ## Capability Authority an unknown target is refused without an evaluation,
  ## which could not name it (CA l.77), and `stop_module` also needs the
  ## `module_execution` `stop` constraint (CA l.335), decided with it.
  let x = st.instances.getOrDefault(q.instance)
  if not q.origin.host:
    if x.isNil and st.authorityMode:
      return err(notAuthorised())
    var reqs = @[
      AuthzRequest(
        action: aaLifecycle,
        operation: operation,
        consumer: q.origin.instance,
        target: q.instance,
        instance: q.instance,
        module: x.moduleOf,
      )
    ]
    if operation == "stop_module" and st.authorityMode:
      reqs.add(
        AuthzRequest(
          action: aaStop,
          operation: "stop",
          consumer: q.origin.instance,
          target: x.id,
          instance: x.id,
          module: x.record.module,
        )
      )
    let refused = st.check(reqs)
    if refused.isSome:
      return err(refused.get)
    if x.isNil:
      return err(notAuthorised())
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
    q.answerFailure(error)
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
  if st.joinExec(x):
    return
  # [SPEC RUNTIME §9.3 l.3644-3647] Acceptance establishes `requested` intent
  # with this origin, before execution authorization or startup.
  let saved = x.save
  x.intent = inRequested
  x.intentOrigin = q.origin
  x.intentRevision = x.revision + 1
  let refused = st.accept(x, saved)
  if refused.isSome:
    q.reply.answerError(refused.get.code, refused.get.message)
    return
  st.execute(x, q.reply, q.origin.instance)

proc beginAttempt(st: State, a: Attempt) {.gcsafe.} =
  ## [SPEC RUNTIME §3.6 steps 4-6] An accepted attempt: its token becomes
  ## live, its Runtime Control binding and invocation access are made, and
  ## the realizer begins. Step 9 puts its selection here.
  let x = a.inst
  let id = a.id
  x.tokens.incl(a.token)
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
    st: State,
    x: Inst,
    reply: ReplyChannel,
    keepIntent: bool,
    origin = "",
    enforcement = false,
) =
  ## [SPEC RUNTIME §3.4, §9.1, §10.2] Moves `x` toward `unloaded`; replies
  ## once it is there, or once the stop deadline passes and the instance is
  ## `error` with `cleanup-timeout` [G61]. [I85] A start or recovery waiting
  ## for its execution decision is cancelled: it and the starts that joined
  ## it get the view after the stop, or NOT_READY at shutdown. An
  ## `enforcement` stop (`stopForAuthority`) keeps intent, as a shutdown stop
  ## does, and has the stop deadline of an explicit one.
  x.exec = Opt.none(ExecAuth)
  inc x.execSerial
  if not keepIntent:
    # [SPEC RUNTIME l.3757] An explicit stop clears the classification.
    x.enforced = Opt.none(Failure)
  let pe = x.pendingExec
  if pe != nil:
    pe.cancelled = true
    x.pendingExec = nil
  defer:
    if pe != nil:
      if keepIntent:
        pe.answerExec(ecNotReady, "the Runtime is shutting down")
      else:
        for w in pe.waiters:
          w.reply.answerView(x)
        for op in pe.joined:
          op.q.reply.answerView(x)
  if not keepIntent and x.intent != inStopped:
    # [SPEC RUNTIME §9.1 l.1839] An explicit stop cancels retained intent.
    x.intent = inStopped
    st.commit(x)
  if not keepIntent and x.state == msUnloaded and x.failure.isSome:
    # [SPEC RUNTIME l.3757, l.3760; I85] It completes at once, so the
    # classification an authority refusal or stop left is cleared.
    x.failure = Opt.none(Failure)
    st.commit(x)
  case x.state
  of msUnloaded, msStopping:
    reply.answerView(x)
    return
  of msLoaded:
    # [SPEC RUNTIME §9.1 l.1840-1841] The incomplete start can no longer make
    # the instance ready; its outcome is cleaned, then `unloaded`.
    let a = x.attempt
    a.cancelled = true
    x.state = msStopping
    st.commit(x)
    for w in a.waiters:
      w.reply.answerView(x)
    a.waiters.setLen(0)
    st.abandon(a)
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
      x.failure = x.takeEnforced()
      x.current = ""
      st.commit(x)
      reply.answerView(x)
      return
  if x.state == msStopping and x.teardown == 0 and x.attempt.isNil and
      x.realization.isNil:
    x.state = msUnloaded
    x.failure = x.takeEnforced()
    x.current = ""
    st.commit(x)
  if x.state == msUnloaded:
    reply.answerView(x)
    return
  if not keepIntent or enforcement:
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
    q.answerFailure(error)
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

proc recover(st: State, q: Request) =
  ## [SPEC RUNTIME §9.3 recover_module, l.3537-3544; §10.1] A new attempt for
  ## retained `requested` intent, its origin and its record unchanged, once
  ## the earlier realization is cleaned. Execution is authorized for the
  ## retained origin, not the requester (l.3540). Answers as `start` does
  ## [G173 interim (TF-20)]. The check order is G171's: authority, then the
  ## module name and revision (`lookup`), then readiness.
  if q.expectedRevision.isNone:
    q.reply.answerError(ecInvalidParams, "an expected execution revision is required")
    return
  let x = st.lookup(q, "recover_module").valueOr:
    q.answerFailure(error)
    return
  st.requireReady(q)
  if x.intent != inRequested:
    # [SPEC RUNTIME l.3538, l.1914] after an explicit stop (l.3790) or before
    # any start
    q.reply.answerError(ecNotReady, "the execution intent is not requested")
    return
  if x.state notin {msUnloaded, msError}:
    q.reply.answerError(ecNotReady, "the module instance is " & $x.state)
    return
  if x.attempt != nil or x.teardown != 0 or x.realization != nil:
    # [SPEC RUNTIME l.3538; G20] cleanup of the earlier realization first
    q.reply.answerError(ecNotReady, "cleanup of the previous realization is pending")
    return
  if st.joinExec(x):
    return
  if st.exhausted(x.revision):
    q.reply.answerError(ecModule, "the execution revision is exhausted")
    return
  st.execute(x, q.reply, q.origin.instance)

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
    let a = x.attempt
    st.failAttempt(a, f)
    st.abandon(a)
  else:
    x.state = msError
    x.failure = Opt.some(f)
    x.provider = false
    st.commit(x)
    st.releaseRealization(x)
  q.reply.answer(success)

proc known(st: State, id: string): bool =
  ## [SPEC RUNTIME §9.2 l.2632-2633] An address that is or was in use here.
  id in st.instances or id in st.tombstones

proc assignmentInUse(st: State, assignment: string, skip = ""): Opt[string] =
  ## [SPEC RUNTIME §8 l.1468, §9.3 l.3587] The instance, live or retired, that
  ## holds `assignment`.
  for y in st.instances.values:
    if y.id != skip and y.record.stateAssignment == Opt.some(assignment):
      return Opt.some(y.id)
  for id, a in st.tombstones:
    if a == Opt.some(assignment):
      return Opt.some(id)
  Opt.none(string)

proc createInst(
    st: State,
    record: ModuleRecord,
    instance: string,
    origin: Origin,
    created = false,
    key = Opt.none(CreateKey),
): Result[Inst, EngineError] =
  ## A local module-instance record: `unloaded`, intent `uninitialized`
  ## (§9.3 l.3623), written before it is exposed. Records come from the host
  ## or, through `create_module`, from its declarations (G55); `key` is that
  ## request's key association, written with the record (l.3627-3628).
  if st.shuttingDown:
    return err(engineError(ecNotReady, "the Runtime is shutting down"))
  if not origin.host and not created:
    return err(engineError(ecNotAuthorised, "not authorised"))
  checkRecord(record).isOkOr:
    return err(engineError(ecInvalidParams, error))
  var id = instance
  if id.len == 0:
    # [SPEC RUNTIME §9.2 l.2630-2633; IMPL] The random prefix keeps a fresh
    # address apart from every earlier one; a collision fails closed.
    inc st.created
    id = "m-" & st.prefix & "-" & $st.created
    if st.known(id):
      return err(engineError(ecModule, "a fresh instance id collided"))
  elif id.len > MaxInstanceIdBytes or not isValidUtf8(id):
    return
      err(engineError(ecInvalidParams, "an instance id must have 1 to 128 UTF-8 bytes"))
  elif id in st.tombstones:
    # [SPEC RUNTIME §9.3 l.3582] A retired address never comes back.
    return err(engineError(ecInvalidParams, "the instance id was retired"))
  if id in st.instances:
    return err(engineError(ecInvalidParams, "the instance id is already in use"))
  if record.stateAssignment.isSome:
    # [SPEC RUNTIME §8 l.1468] no shared state assignment by default; a
    # retired instance keeps its own reserved (l.3587)
    if st.assignmentInUse(record.stateAssignment.get).isSome:
      return err(engineError(ecInvalidParams, "the state assignment is in use"))
  let x = Inst(
    id: id,
    record: record,
    state: msUnloaded,
    intent: inUninitialized,
    revision: st.epoch shl 32,
    created: created,
  )
  if record.primaryContract.isSome or record.implements.len > 0:
    # [SPEC RUNTIME §9.3 l.2862-2871] Its provider record, kept across stop,
    # start and restart [IMPL: one per instance].
    inc st.providerCount
    x.providerId = "p-" & st.prefix & "-" & $st.providerCount
    for y in st.instances.values:
      if y.providerId == x.providerId:
        return err(engineError(ecModule, "a fresh provider id collided"))
  st.instances[id] = x
  if key.isSome:
    var k = key.get
    k.instance = id
    st.createKeys.add(k)
  # [G47; C11] The attribute source knows it before anything can name it.
  st.putFacts(x)
  let refused = st.accept(x, x.save)
  if refused.isSome:
    st.instances.del(id)
    st.dropFacts(x)
    if key.isSome:
      st.createKeys.setLen(st.createKeys.len - 1)
    return err(refused.get)
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
  ## [IMPL] A state that could not be written is tried once more; if it still
  ## fails the result is MODULE_ERROR (G60 extended; I82).
  st.shutdownResult = st.shutdownOutcome()
  st.retryStore()
  if st.storeFailed:
    var message = NotPersisted
    if st.shutdownResult.isSome:
      message = st.shutdownResult.get.message & "; " & message
    st.shutdownResult = Opt.some(engineError(ecModule, message))
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
    # [I85] No evaluation begins after this: parked operations and pending
    # executions are NOT_READY and the cache is cleared. The binding is not
    # lost by it.
    st.failOutstanding("the Runtime is shutting down", shutdown = true)
    st.cache.clear()
  st.shutdownStep()
  if st.shutdownComplete():
    st.finishShutdown()

# Runtime Control ----------------------------------------------------------------

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
  if q.bare in [$rmEstablishRoute, $rmShutdownRuntime]:
    st.require(
      q, AuthzRequest(action: aaRuntimeControl, operation: q.bare, consumer: x.id)
    )
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
    if owner.isNil and st.authorityMode:
      return err(notAuthorised())
    let refused = st.check(
      AuthzRequest(
        action: aaLifecycle,
        operation: operation,
        consumer: x.id,
        target: p.provider,
        provider: p.provider,
        providerSelector: true,
        module: owner.moduleOf,
      )
    )
    if refused.isSome:
      return err(refused.get)
    if owner.isNil:
      return err(notAuthorised())
    return err(
      engineError(ecInvalidParams, "the provider selector names a local implementation")
    )
  if instance.isSome:
    return ok(instance.get)
  # [SPEC RUNTIME §9.3 l.3666-3670] Observation authority over the whole name
  # scope comes first, whatever the number of matches.
  let refused = st.check(
    AuthzRequest(
      action: aaObserve, operation: operation, consumer: x.id, module: module
    )
  )
  if refused.isSome:
    return err(refused.get)
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
    q.answerFailure(error)
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
    q.answerFailure(error)
    return
  let y = st.instances.getOrDefault(target)
  if y.isNil and st.authorityMode:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  st.require(
    q,
    AuthzRequest(
      action: aaObserve,
      operation: $rmGetReadiness,
      consumer: x.id,
      target: target,
      instance: target,
      module: y.moduleOf,
    ),
  )
  if y.isNil:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if req.module != y.record.module:
    q.reply.answerError(ecInvalidParams, "the module name does not match")
    return
  st.requireReady(q)
  let v = y.exposed
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

proc rcRecover(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §9.3 recover_module] Through Runtime Control: `x` requests,
  ## the retained origin's execution authority decides (`recover`).
  let req = q.rc.recover
  var r = q
  r.instance = req.instance
  r.module = req.module
  r.expectedRevision = Opt.some(req.expected_execution_revision)
  st.recover(r)

proc retireInst(st: State, y: Inst): Result[void, string] =
  ## [SPEC RUNTIME l.3585-3588, l.3595] One durable write before the answer:
  ## the instance and its provider record leave the inventory, a host-assigned
  ## id is kept as a tombstone with the state assignment it reserves, and its
  ## `create_module` keys are dropped (RUN-1028). On a failed write nothing
  ## changes. The state directory, packages, grants and history stay; nothing
  ## is transferred.
  let instances = st.instances
  let keys = st.createKeys
  st.instances.del(y.id)
  let tombstone = not isRuntimeForm(y.id)
  if tombstone:
    # [IMPL] A Runtime-assigned name never comes back anyway (I82, C-3).
    st.tombstones[y.id] = y.record.stateAssignment
  st.createKeys.keepItIf(it.instance != y.id)
  let w = st.persist()
  if w.isErr:
    st.instances = instances
    st.createKeys = keys
    if tombstone:
      st.tombstones.del(y.id)
    return err(w.error)
  # [SPEC RUNTIME l.3576] Nothing later publishes a change of the retired
  # record (RUN-1012).
  st.changes.keepItIf(it.view.instance != y.id)
  st.written(nil)
  ok()

proc retire(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §9.3 retire_module, l.3556-3595] Removes a stopped
  ## instance's record for good. The check order is G171's: the target's
  ## Runtime, this method's own authority (l.3557), the revision, readiness,
  ## then the absence of every realization, cleanup, call and dependency.
  let req = q.rc.retire
  if req.target.runtime_instance_id != st.runtimeId:
    # [G194 interim (TF-30 point 1)] INVALID_PARAMS without detail, as l.3659
    # answers a provider address on another Runtime.
    q.reply.answerError(ecInvalidParams, "the target names another Runtime")
    return
  let id = req.target.module_instance_id
  let y = st.instances.getOrDefault(id)
  # [SPEC RUNTIME l.3557, l.3561] Authorized on its own; an unknown target
  # and a refused one are the same.
  if y.isNil and st.authorityMode:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  st.require(
    q,
    AuthzRequest(
      action: aaLifecycle,
      operation: $rmRetireModule,
      consumer: x.id,
      target: id,
      instance: id,
      module: y.moduleOf,
    ),
  )
  if y.isNil:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if req.expected_execution_revision != y.revision:
    # [SPEC RUNTIME l.3559-3560] no mutation
    q.reply.answerError(ecInvalidParams, "execution revision mismatch")
    return
  st.requireReady(q)
  # [SPEC RUNTIME l.3563-3566] What the Runtime owns, not the state alone:
  # no attempt, realization or destroy job, no call or deferred invocation
  # in it, no stop waiting on it.
  var live =
    y.state notin {msUnloaded, msError} or y.attempt != nil or y.teardown != 0 or
    y.realization != nil or y.inflight > 0 or y.stopWaiters.len > 0 or
    y.pendingExec != nil
  for a in st.asyncCalls.values:
    if a.provider == y.id or a.consumer == y.id:
      live = true
  if live:
    q.reply.answerError(ecNotReady, "the module instance still has a realization")
    return
  if y.intent == inRequested:
    q.reply.answerError(ecNotReady, "the execution intent is requested")
    return
  for z in st.instances.values:
    # [SPEC RUNTIME l.3568-3570] Retained intent that names it as origin;
    # stopped or replaced intent does not count (l.3578).
    if z != y and z.intent == inRequested and not z.intentOrigin.host and
        z.intentOrigin.instance == y.id:
      q.reply.answerError(
        ecNotReady, "the module instance is the origin of retained execution intent"
      )
      return
  if y.configured:
    # [SPEC RUNTIME l.3581-3582] The host configuration still names it.
    q.reply.answerError(ecNotReady, "the host configuration names the module instance")
    return
  st.retireInst(y).isOkOr:
    st.storeFailure(error)
    q.reply.answerError(ecModule, NotPersisted)
    return
  st.dropFacts(y)
  # [SPEC RUNTIME l.3591] The retirement stands whether or not the answer
  # arrives.
  q.reply.answerEncoded(encode(LogosNSRuntimeControlRetireModuleResponse()))

proc createModule(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §9.3 create_module, l.3613-3634] A fresh instance from the
  ## one accepted declaration for `module` (G55), once per request key.
  let req = q.rc.createModule
  st.require(
    q,
    AuthzRequest(
      action: aaLifecycle,
      operation: $rmCreateModule,
      consumer: x.id,
      module: req.module,
    ),
  )
  st.requireReady(q)
  # [SPEC RUNTIME l.3627-3631] The key's scope is this method, this consumer
  # and this Runtime; the Runtime thread serializes requests, so one key
  # creates one instance (RUN-0663).
  for k in st.createKeys:
    if k.consumer == x.id and k.key == req.request_key:
      if k.module != req.module:
        q.reply.answerError(
          ecInvalidParams, "the request key was used for another module"
        )
      else:
        q.reply.answerEncoded(
          encode(
            LogosNSRuntimeControlCreateModuleResponse(
              module: k.module, instance: k.instance
            )
          )
        )
      return
  var found = false
  var d: ModuleDeclaration
  for c in st.cfg.declarations:
    if c.record.module == req.module:
      d = c
      found = true
  if not found:
    # [G195 interim (TF-30 point 2)] No accepted declaration: the answer a
    # denial gives, and nothing created (l.3619).
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if st.instances.len >= MaxInstances:
    # [SPEC RUNTIME l.3442-3443; BCP l.369] a resource bound, not readiness
    q.reply.answerError(ecModule, "the Runtime holds as many instances as it can")
    return
  var record = d.record
  if d.persistentState:
    # [SPEC RUNTIME §8 l.1451] its own fresh state assignment
    inc st.assignments
    record.stateAssignment = Opt.some("s-" & st.prefix & "-" & $st.assignments)
  let y = st.createInst(
    record,
    "",
    q.origin,
    created = true,
    key = Opt.some(CreateKey(consumer: x.id, key: req.request_key, module: req.module)),
  ).valueOr:
    q.reply.answerError(error.code, error.message)
    return
  q.reply.answerEncoded(
    encode(
      LogosNSRuntimeControlCreateModuleResponse(module: y.record.module, instance: y.id)
    )
  )

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

proc accessBytes(a: LogosNSRuntimeControlRouteAccess): seq[byte] =
  ## A route access as an `AuthzRequest` carries it: empty when it
  ## constrains nothing.
  if a.methods.isNone and a.publish_events.isNone and a.subscribe_events.isNone:
    return @[]
  encode(a).get(newSeq[byte]())

proc establish(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §4.2, §9.3 l.3086-3183] Local direct routes for consumer `x`.
  const op = "establish_route"
  let req = q.rc.establish
  # [SPEC RUNTIME l.1626, l.3138] The method itself; no provider access yet.
  st.require(q, AuthzRequest(action: aaRuntimeControl, operation: op, consumer: x.id))
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
  let contract = @root
  let access = accessBytes(req.access)
  let discover =
    AuthzRequest(action: aaDiscover, operation: op, consumer: x.id, contract: contract)
  var shown = Opt.none(seq[string])
  if all:
    let d = st.decide([discover]).valueOr:
      return
    if not d[0].allows:
      q.reply.answerError(ecNotAuthorised, "not authorised")
      return
    if d[0].source == psAuthority:
      # [SPEC CA l.247-248; CAP-0041] A discover allow may disclose fewer
      # providers; the others are not candidates.
      shown = providersOf(d[0], st.requestBytes(discover), st.runtimeId)
  # [SPEC RUNTIME §9.3 l.3088-3112] Candidates: the provider records whose
  # module record expects the contract, in creation order; readiness is
  # applied after the route decision.
  var candidates: seq[Inst]
  for y in st.instances.values:
    if y.providerId.len == 0 or not y.expects(root):
      continue
    if req.provider.isSome and y.providerId != req.provider.get.provider:
      continue
    if shown.isSome and y.providerId notin shown.get:
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
  var reqs: seq[AuthzRequest]
  for y in candidates:
    # [SPEC RUNTIME l.3155] The identifier is allocated before evaluation,
    # once per operation whatever its passes (I85).
    var id = ""
    if st.op != nil:
      id = st.op.reserved.getOrDefault(y.providerId)
    if id.len == 0:
      id = st.newRouteId()
      if st.op != nil:
        st.op.reserved[y.providerId] = id
    reqs.add(
      AuthzRequest(
        action: aaRoute,
        operation: op,
        consumer: x.id,
        target: y.providerId,
        provider: y.providerId,
        route: id,
        module: y.record.module,
        contract: contract,
        access: access,
      )
    )
  let answers = st.decide(reqs).valueOr:
    return
  var
    allowed: seq[(Inst, AuthzRequest, AuthzAnswer)]
    omitted = false
    made: seq[(Route, AuthzAnswer)]
  for i, y in candidates:
    if answers[i].allows:
      allowed.add((y, reqs[i], answers[i]))
    else:
      omitted = true
  if allowed.len == 0:
    # [SPEC RUNTIME l.3157-3159; G169 interim (TF-16)] Nothing the caller may
    # route to: NOT_AUTHORISED, unless a `discover` allow covers the contract
    # and no provider offers it, which the caller may learn.
    var discoverable = candidates.len == 0
    if discoverable and not all:
      let d = st.decide([discover]).valueOr:
        return
      discoverable = d[0].allows
    if not discoverable:
      q.reply.answerError(ecNotAuthorised, "not authorised")
      return
  st.requireReady(q)
  for (y, rq, ans) in allowed:
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
    var routeAccess = req.access
    if ans.source == psAuthority:
      # [SPEC RUNTIME l.3164-3166; RUN-0567, CAP-0051] A narrowed allow's
      # access becomes the route's.
      let narrowed = routeAccessOf(ans, st.requestBytes(rq), st.runtimeId)
      if narrowed.isSome:
        routeAccess = narrowed.get
    made.add(
      (
        Route(
          id: rq.route,
          consumer: x.id,
          provider: y.providerId,
          providerInstance: y.id,
          selected: sel.get,
          access: routeAccess,
          state: rtReady,
        ),
        ans,
      )
    )
  if made.len == 0:
    # [G169 interim (TF-16)] The caller holds a route allow for a provider, or
    # a `discover` allow and no provider offers the contract.
    q.reply.answerError(ecNotReady, "no selected provider is ready")
    return
  var response = LogosNSRuntimeControlEstablishRouteResponse(partial: all and omitted)
  for (r, ans) in made:
    st.routes[r.id] = r
    st.setValidity(r, ans)
    response.routes.add(r.record(st.runtimeId))
  let bytes = encode(response).valueOr:
    q.reply.answerError(ecModule, "the response cannot be encoded")
    return
  st.keys.retain(x.id, req.request_key, op, q.rc.request, bytes)
  q.reply.answer(Reply(bytes: bytes))

# Route re-authorization (CA l.869-873, l.906-914; S8b-2 interim, TF-33) ----------------

proc reauthRequest(r: Route): AuthzRequest =
  ## The `renew-route` decision for the route as it is bound: its id, provider
  ## and access (CA l.284-293).
  AuthzRequest(
    action: aaRoute,
    operation: "renew_route",
    consumer: r.consumer,
    target: r.provider,
    provider: r.provider,
    route: r.id,
    module: r.selected.module,
    contract: @(r.selected.root),
    access: accessBytes(r.access),
  )

proc releaseReauthWaiters(st: State, r: Route) =
  ## The operations parked on `r` run again and look at it afresh.
  var waiting: seq[OpCtx]
  if st.reauthWaiters.pop(r.id, waiting):
    for op in waiting:
      st.rerun(op)

proc shorten(st: State, r: Route, a: AuthzAnswer) =
  ## [S8b-2 interim] A re-authorization never extends `expires_at`; an
  ## earlier `valid_until` shortens it.
  if a.validUntil.isNone or (r.expiresAt.isSome and r.expiresAt.get <= a.validUntil.get):
    return
  r.expiresAt = a.validUntil
  let left = int64(a.validUntil.get) - int64(st.wallNow)
  let d = st.monoNow + max(left, 0) * 1_000_000
  if r.monoDeadline.isNone or d < r.monoDeadline.get:
    r.monoDeadline = Opt.some(d)
  st.timed.incl(r.id)

proc pumpReauth(st: State) {.gcsafe.}

proc reauthorized(st: State, r: Route, attempt: int, a: AuthzAnswer) =
  ## [SPEC CA l.906-911; CAP-0189; S8b-2 interim] An allow covering the bound
  ## access makes the route usable again with the new decision; a deny
  ## revokes it with `authority-denied`, a narrowed allow with
  ## `authority-revoked` (G170 extended); an evaluation failure leaves it
  ## `ready` and unusable (CAP-0174). TL-04: the outcome decides, never a
  ## code.
  dec st.reauthBusy
  if r.reauthTry == attempt and r.reauth == raPending and not r.isTerminal:
    if a.allows:
      r.decisionId = a.decisionId
      r.grants = a.grants
      st.shorten(r, a)
      r.reauth = raNone
    else:
      case a.outcome
      of azAllow:
        st.endRoute(r, rtRevoked, Opt.some(rfAuthorityRevoked))
      of azDeny:
        st.endRoute(r, rtRevoked, Opt.some(rfAuthorityDenied))
      of azEvaluationFailed, azRefused:
        r.reauth = raFailed
  st.pumpReauth()
  st.releaseReauthWaiters(r)

proc startReauth(st: State, r: Route) =
  inc r.reauthTry
  r.reauth = raPending
  inc st.reauthBusy
  let attempt = r.reauthTry
  st.decideDetached(
    @[reauthRequest(r)],
    proc(got: seq[AuthzAnswer]) =
      st.reauthorized(r, attempt, got[0]),
    proc() =
      # [I85] Shutdown: nothing more is admitted on it.
      dec st.reauthBusy
      r.reauth = raNeeded
      var waiting: seq[OpCtx]
      if st.reauthWaiters.pop(r.id, waiting):
        for op in waiting:
          shuttingDownReply(op.q)
    ,
  )

proc pumpReauth(st: State) =
  while st.reauthBusy < ReauthBatch and st.reauthQueue.len > 0:
    let r = st.routes.getOrDefault(st.reauthQueue.popFirst())
    if r != nil and r.reauth == raQueued and not r.isTerminal:
      st.startReauth(r)

proc reauthRoutes(st: State, grant: string) =
  ## [SPEC CA l.906-914; CAP-0188, CAP-0359; S8b-2 interim (TF-33)] After a
  ## `policy_changed` (`grant` empty) or the revocation or expiry of a grant
  ## its decision used, every dependent ready route is re-authorized at once,
  ## eagerly, a bounded number at a time; meanwhile it is unusable and the
  ## operations on it park (CAP-0174). One being evaluated already gives a
  ## stale result, evaluated again (CAP-0343).
  for r in st.routes.values:
    if r.authority and not r.isTerminal and r.reauth notin {raQueued, raPending} and
        (grant.len == 0 or grant in r.grants):
      r.reauth = raQueued
      st.reauthQueue.addLast(r.id)
  st.pumpReauth()

proc invalidateRoutes(st: State) =
  ## [SPEC CA l.869-873; CAP-0173, CAP-0174] Binding loss: every route the
  ## authority decided is unusable until it is re-authorized, at its next use
  ## under a new binding; nothing is evaluated now.
  st.reauthQueue.clear()
  for r in st.routes.values:
    if r.authority and not r.isTerminal:
      r.reauth = raNeeded

proc routeAuthorized(st: State, r: Route): Opt[EngineError] =
  ## [SPEC CA l.869-873, l.906-911; CAP-0173, CAP-0174, CAP-0188] None when
  ## `r` may carry a protected operation. A route waiting for its
  ## re-authorization parks the operation (`Parked`) until it answers; one
  ## that needs it, or whose last one failed, is re-authorized now. An
  ## operation that already waited for the re-authorization that failed, or
  ## has no passes left, is NOT_AUTHORISED.
  if not r.authority or r.isTerminal or r.reauth == raNone:
    return Opt.none(EngineError)
  let op = st.op
  if op.isNil or op.passes >= MaxPasses or
      (r.reauth == raFailed and op.waited.getOrDefault(r.id, -1) == r.reauthTry):
    return Opt.some(notAuthorised())
  if r.reauth in {raNeeded, raFailed, raQueued}:
    st.startReauth(r)
  if r.isTerminal:
    return Opt.some(notAuthorised())
  case r.reauth
  of raNone:
    Opt.none(EngineError)
  of raPending:
    op.waited[r.id] = r.reauthTry
    st.reauthWaiters.mgetOrPut(r.id, @[]).add(op)
    Opt.some(Parked)
  else:
    Opt.some(notAuthorised())

template requireRoute(st: State, q: Request, r: Route) =
  let refused = st.routeAuthorized(r)
  if refused.isSome:
    q.answerFailure(refused.get)
    return

proc renew(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §9.3 l.3183-3190, l.3471-3484] A new authority check for
  ## an existing ready route. An allow replaces the decision and, from the
  ## Capability Authority, `expires_at`, and makes a route waiting for its
  ## re-authorization usable again; a deny makes the route unusable [G170
  ## interim (TF-17)], and so does a narrowed allow, with `authority-revoked`
  ## [G170 extended, I85]. [S8b-2 interim] An evaluation failure is what it
  ## is for the Runtime's own re-authorization: the route stays `ready` and
  ## unusable until a later decision allows it.
  const op = "renew_route"
  let req = q.rc.renew
  st.require(
    q,
    AuthzRequest(
      action: aaRuntimeControl,
      operation: op,
      consumer: x.id,
      target: req.route,
      route: req.route,
    ),
  )
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
  st.expireIfDue(r)
  if r.state == rtRevoked and r.endCode == ecNotAuthorised:
    # [SPEC RUNTIME §7.5 l.1347] A known authorization failure comes first;
    # an expired route cannot be renewed (l.3188; TL-03 interim).
    q.reply.answerError(ecNotAuthorised, "the route is " & $r.state)
    return
  let d = st.decide(
    [
      AuthzRequest(
        action: aaRoute,
        operation: op,
        consumer: x.id,
        target: r.provider,
        provider: r.provider,
        route: r.id,
        module: r.selected.module,
        contract: @(r.selected.root),
        access: accessBytes(r.access),
      )
    ]
  ).valueOr:
    return
  let ans = d[0]
  if not ans.allows:
    # [G170 interim (TF-17)] No call is served under a decision a later check
    # withdrew (CA l.906-911); a terminal route keeps its first end. TL-04:
    # the outcome, never its code, picks the failure.
    case ans.outcome
    of azAllow:
      st.endRoute(r, rtRevoked, Opt.some(rfAuthorityRevoked))
    of azDeny:
      st.endRoute(r, rtRevoked, Opt.some(rfAuthorityDenied))
    of azEvaluationFailed, azRefused:
      if r.authority and not r.isTerminal:
        inc r.reauthTry
        r.reauth = raFailed
        st.releaseReauthWaiters(r)
      elif not r.authority:
        st.endRoute(r, rtRevoked, Opt.some(rfAuthorityEvaluationFailed))
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
  st.setValidity(r, ans)
  if r.reauth != raNone:
    inc r.reauthTry # a re-authorization still out no longer applies
    r.reauth = raNone
    st.releaseReauthWaiters(r)
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
  st.require(
    q,
    AuthzRequest(
      action: aaRuntimeControl,
      operation: "close_route",
      consumer: x.id,
      target: req.route,
      route: req.route,
    ),
  )
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
  of rmRecoverModule:
    st.rcRecover(q, x)
  of rmRetireModule:
    st.retire(q, x)
  of rmCreateModule:
    st.createModule(q, x)
  of rmEstablishRoute:
    st.establish(q, x)
  of rmRenewRoute:
    st.renew(q, x)
  of rmCloseRoute:
    st.closeRoute(q, x)
  of rmShutdownRuntime:
    # [SPEC RUNTIME §9.3 l.3695-3700] Runtime-wide; the response acknowledges
    # acceptance and is attempted before teardown.
    st.require(
      q,
      AuthzRequest(
        action: aaRuntimeControl, operation: "shutdown_runtime", consumer: x.id
      ),
    )
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
    outcome = Opt.some(
      if x.pending:
        Reply(error: Opt.some(engineError(ecModule, NotPersisted)))
      else:
        Reply(view: x.view)
    )
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

proc reconcile(st: State, configured: seq[BootstrapInstance]): Opt[EngineError] =
  ## [IMPL-DECISION G160 interim (TF-08)] The configured instances against the
  ## retained ones, all checked before any is changed. A retired id is
  ## refused (l.3582); a retained id is the same logical instance while its
  ## declaration facts are equal (the record without `local_path` and
  ## permission reasons, `store.factBytes`), and refused, naming it, when
  ## they differ: the host names a new id. A configured state assignment that
  ## another instance, live or retired, holds is refused (l.1468, l.3587).
  for b in configured:
    if b.instance in st.tombstones:
      return Opt.some(
        engineError(ecInvalidParams, "instance " & b.instance & " was retired")
      )
    let x = st.instances.getOrDefault(b.instance)
    if x != nil and factBytes(x.record) != factBytes(b.record):
      return Opt.some(
        engineError(
          ecInvalidParams,
          "the configured declaration of instance " & b.instance &
            " differs from the retained one",
        )
      )
    if b.record.stateAssignment.isSome:
      let holder = st.assignmentInUse(b.record.stateAssignment.get, b.instance)
      if holder.isSome:
        return Opt.some(
          engineError(
            ecInvalidParams,
            "the state assignment of instance " & b.instance & " is held by " &
              holder.get,
          )
        )
  Opt.none(EngineError)

proc bootstrap(st: State, q: Request) =
  ## [SPEC RUNTIME l.187-192, l.1640, §13.2] Bootstrap policy is in place (the
  ## authorizer exists before this request). Reconciles the configured
  ## instances with the retained ones (`reconcile`), creates the new ones in
  ## configuration order with their protected identity and the host's origin,
  ## records the orchestration role, and re-establishes that one instance
  ## [G191 interim (TF-26)]: retained `requested` intent with the host's
  ## origin is resumed through the recovery path, intent, origin and intent
  ## revision kept (l.3539); otherwise the ordinary start path establishes
  ## `requested` intent with the host's protected-input origin, with a
  ## diagnostic when it replaces retained intent (l.1640, l.3808). Either
  ## path authorizes execution, applies the startup deadline, binds, runs
  ## `_MODULE_init` with its Runtime Control binding and checks the
  ## contracts. No other instance is started (l.3774).
  if st.bootstrapped:
    q.reply.answerError(ecNotReady, "the Runtime has already been bootstrapped")
    return
  st.bootstrapped = true
  if st.shuttingDown:
    q.reply.answerError(
      ecCancelled, "shutdown was requested before bootstrap completed"
    )
    return
  var named = false
  for b in q.bootstrap:
    if b.instance == q.instance:
      named = true
  if not named:
    q.reply.answerError(ecInvalidParams, "no orchestration instance was configured")
    return
  if st.authorityMode and st.cfg.authority.get.instance == q.instance:
    # [SPEC RUNTIME l.1654-1656; C8] The authority is never the orchestration
    # instance: the derived rules would let it start itself (RUN-0701).
    q.reply.answerError(
      ecInvalidParams, "the orchestration instance cannot be the Capability Authority"
    )
    return
  let refused = st.reconcile(q.bootstrap)
  if refused.isSome:
    q.reply.answerError(refused.get.code, refused.get.message)
    return
  for b in q.bootstrap:
    var x = st.instances.getOrDefault(b.instance)
    if x.isNil:
      x = st.createInst(b.record, b.instance, hostOrigin()).valueOr:
        q.reply.answerError(error.code, error.message)
        return
    elif recordBytes(x.record) != recordBytes(b.record):
      # [IMPL-DECISION G160] Equal facts: the retained record takes the
      # configured artifact path and permission reasons.
      let saved = x.save
      x.record = b.record
      let failed = st.accept(x, saved, exempt = true)
      if failed.isSome:
        q.reply.answerError(failed.get.code, failed.get.message)
        return
    x.configured = true
    if b.instance == q.instance:
      x.orchestration = true
      st.orchestrator = x
  let x = st.orchestrator
  st.bootstrapReply = q.reply
  if x.intent == inRequested and x.intentOrigin.host:
    st.recover(
      Request(
        kind: rqRecover,
        instance: x.id,
        origin: hostOrigin(),
        expectedRevision: Opt.some(x.revision),
      )
    )
  else:
    if x.intent == inStopped:
      st.diagnose("startup re-established orchestration whose intent was stopped")
    elif x.intent == inRequested:
      st.diagnose(
        "startup re-established orchestration whose intent was requested by " &
          x.intentOrigin.instance
      )
    st.start(Request(kind: rqStart, instance: x.id, origin: hostOrigin()))
  if st.storeFailed and x.attempt.isNil and x.state notin {msLoaded, msReady} and
      st.bootstrapReply != nil:
    # [IMPL] The accepting write failed (I82).
    st.bootstrapReply.answerError(ecModule, NotPersisted)
    st.bootstrapReply = nil
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
  st.expireIfDue(r)
  if not st.authorityMode:
    # [SPEC RUNTIME §4.3 l.982-984] The caller's access to the selected
    # provider is verified before a handle is returned [IMPL: one route
    # decision]. [I85] Under the Capability Authority the route's own allow
    # and its validity are that verification: CA has no materialize action.
    st.require(
      q,
      AuthzRequest(
        action: aaRoute,
        operation: "materialize_route",
        consumer: x.id,
        target: r.provider,
        route: r.id,
        module: r.selected.module,
      ),
    )
  if r.isTerminal and r.endCode == ecNotAuthorised:
    q.reply.answerError(ecNotAuthorised, "the route is " & $r.state)
    return
  st.requireRoute(q, r)
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

proc isAuthorityContract(st: State, sel: SelectedContract): bool =
  ## [SPEC CA l.88-91] Whether a route selects the pinned Capability Authority
  ## contract. [IMPL] Its root is computed only for a contract that could be
  ## it.
  if "evaluate" notin sel.methods:
    return false
  if st.caRoot.isNone:
    st.caRoot = toDigest(caRoots().contract)
  st.caRoot == Opt.some(sel.root)

proc refusal(st: State, q: Request) =
  ## [S8b-1 interim (TF-31); RUNTIME l.1745-1748] A routed call to a
  ## Capability Authority method refused at the invocation boundary is kept
  ## among the retained answers as its own kind.
  let r = st.route(q.route)
  discard st.authorizer.issue(
    AuthzRequest(
      action: aaCall,
      operation: q.bare,
      consumer: q.origin.instance,
      target: (if r.isNil: "" else: r.provider),
      provider: (if r.isNil: "" else: r.provider),
      route: q.route,
      module: (if r.isNil: "" else: r.selected.module),
    ),
    azRefused,
    psBoundary,
    q.reason,
  )
  q.reply.answer(Reply())

proc admit(st: State, q: Request) =
  ## [SPEC RUNTIME §4.1, §6.4, §7.5, l.1732] Step 1 of a direct route call
  ## (`bindings.nim`): the method and its scope, then authorization, then
  ## readiness, so a known authorization failure takes precedence (l.1347).
  let r = st.route(q.route)
  if r.isNil or r.consumer != q.origin.instance:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  st.expireIfDue(r)
  let declaration = r.selected.methodRoot(q.bare)
  if declaration.isNone:
    q.reply.answerError(ecMethodNotFound, "unknown method " & q.bare)
    return
  if not r.allowsMethod(q.bare):
    q.reply.answerError(ecNotAuthorised, "the method is outside the route's access")
    return
  if r.isTerminal and r.endCode == ecNotAuthorised:
    q.reply.answerError(ecNotAuthorised, "the route is " & $r.state)
    return
  st.requireRoute(q, r)
  let callReq = AuthzRequest(
    action: aaCall,
    operation: q.bare,
    consumer: r.consumer,
    target: r.provider,
    provider: r.provider,
    route: r.id,
    module: r.selected.module,
    contract: @(r.selected.root),
    declaration: @(declaration.get),
  )
  st.require(q, callReq)
  if r.isTerminal:
    q.reply.answerError(r.endCode, "the route is " & $r.state)
    return
  # [SPEC CA l.1176-1177] The applied call decision, captured with its
  # retention at admission.
  let capture = st.captureOf(callReq, st.op.decided.getOrDefault(callReq.key))
  let marked = r.selected.marked(q.bare)
  if (capture.retainRequest and marked.request) or
      (capture.retainResponse and marked.response):
    # [SPEC INTERFACE l.395-397; CA l.479] A retention requirement on a
    # marked payload refuses the call before dispatch, per side: an
    # enforcement failure, retained as a refusal [IMPL].
    discard st.authorizer.issue(callReq, azRefused, psBoundary, "sensitive-retention")
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  let x = st.instances.getOrDefault(r.consumer)
  if x.isNil or q.attempt != x.current or x.state notin {msLoaded, msReady} or
      st.shuttingDown:
    q.reply.answerError(ecNotReady, "the consumer is not live")
    return
  if r.selected.isWellKnown(q.bare):
    # [SPEC INTERFACE l.3275-3277; RUNTIME l.429-431] The boundary answers;
    # no provider code runs and no invocation context is made current.
    q.reply.answer(Reply(admission: Admission(introspection: true, capture: capture)))
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
        authority: st.isAuthorityContract(r.selected),
        capture: capture,
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
  st.expireIfDue(r)
  let declaration = r.selected.eventRoot(q.bare)
  if declaration.isNone:
    q.reply.answerError(
      ecNotAuthorised, q.bare & " is not an event of the selected contract"
    )
    return
  if q.bare in [GrantChangedName, PolicyChangedName] and
      st.isAuthorityContract(r.selected):
    # [SPEC RUNTIME l.1660-1667; RUN-0856, RUN-0857] The Capability
    # Authority's notices reach the Runtime on its protected path only, never
    # through an ordinary subscription, whatever scope a grant gives, and
    # whatever the policy kind: an instance that is not bound is no exception.
    q.reply.answerError(ecNotAuthorised, "the authority's notices are protected")
    return
  if not r.allowsSubscribe(q.bare):
    q.reply.answerError(ecNotAuthorised, "the event is outside the route's access")
    return
  if r.isTerminal and r.endCode == ecNotAuthorised:
    q.reply.answerError(ecNotAuthorised, "the route is " & $r.state)
    return
  st.requireRoute(q, r)
  st.require(
    q,
    AuthzRequest(
      action: aaSubscribeEvent,
      operation: q.bare,
      consumer: r.consumer,
      target: r.provider,
      provider: r.provider,
      route: r.id,
      module: r.selected.module,
      contract: @(r.selected.root),
      declaration: @(declaration.get),
    ),
  )
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
  st.expireIfDue(r)
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
  # [CAP-0174, CAP-0188] A new delivery commitment waits for the route's
  # re-authorization, and is not made when it fails.
  let refused = st.routeAuthorized(r)
  if refused.isSome:
    if refused.get.parked:
      return
    if q.scoped:
      stop(ecNotAuthorised, "the route is not authorised")
    skip()
  let contract = @(r.selected.root)
  let declaration = @(r.selected.eventRoot(name).get)
  let published = st.decide(
    [
      AuthzRequest(
        action: aaPublishEvent,
        operation: name,
        consumer: r.providerInstance,
        target: r.consumer,
        provider: r.provider,
        route: r.id,
        module: r.selected.module,
        contract: contract,
        declaration: declaration,
      )
    ]
  ).valueOr:
    return
  if not published[0].allows:
    if q.scoped:
      stop(ecNotAuthorised, "the publication is not authorised")
    skip()
  let received = st.decide(
    [
      AuthzRequest(
        action: aaSubscribeEvent,
        operation: name,
        consumer: r.consumer,
        target: r.provider,
        provider: r.provider,
        route: r.id,
        module: r.selected.module,
        contract: contract,
        declaration: declaration,
      )
    ]
  ).valueOr:
    return
  if not received[0].allows:
    if received[0].outcome == azDeny:
      # [G175 extended (TF-24); CA l.913-915; CAP-0191] An explicit deny ends
      # the subscription: continuing it would exceed current authority.
      deactivate(s)
    skip()
  q.reply.answer(Reply(admitted: true))

# The Runtime thread ---------------------------------------------------------------

proc handle(st: State, q: Request) {.gcsafe.} =
  if q.kind in {
    rqCreate, rqStart, rqStop, rqReportFailure, rqRecover, rqBootstrap, rqRc
  }:
    # [IMPL] A lifecycle request first tries a write that failed (I82).
    st.retryStore()
  case q.kind
  of rqConfigure:
    discard
  of rqCreate:
    st.create(q)
  of rqStart:
    st.start(q)
  of rqRecover:
    st.recover(q)
  of rqStop:
    st.stop(q)
  of rqReportFailure:
    st.reportFailure(q)
  of rqView:
    let x = st.instances.getOrDefault(q.instance)
    if x.isNil:
      q.reply.answerError(ecInvalidParams, "unknown module instance")
    else:
      q.reply.answer(Reply(view: x.exposed))
  of rqRefusal:
    st.refusal(q)
  of rqStopForAuthority:
    let x = st.instances.getOrDefault(q.instance)
    if x.isNil:
      q.reply.answerError(ecInvalidParams, "unknown module instance")
    elif q.ending notin AuthorityEndings:
      q.reply.answerError(ecInvalidParams, "not an authority classification")
    else:
      st.stopForAuthority(x, q.ending)
      q.reply.answer(Reply(view: x.exposed))
  of rqList:
    var r = Reply()
    for x in st.instances.values:
      r.views.add(x.exposed)
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
    if st.busy + st.callBusy + st.evalBusy + st.renewBusy > 0:
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
  of rqCleanup:
    let x = st.instances.getOrDefault(q.instance)
    q.reply.answer(
      Reply(
        pending:
          not x.isNil and x.state in {msUnloaded, msError} and
          (x.attempt != nil or x.teardown != 0 or x.realization != nil)
      )
    )
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
  of rqAuthorityNotice:
    st.notice(q)
  of rqAuthorityState:
    q.reply.answer(Reply(bound: st.caInst != nil, generation: st.gen))
  of rqRoutes:
    st.expireRoutes()
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
      x.failure = x.takeEnforced()
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
  ## shutdown accepted by the next. The authority binding follows every step.
  st.checkBinding()
  if st.shuttingDown and not st.shutdownDone:
    st.shutdownStep()
    if st.shutdownComplete():
      st.finishShutdown()
  st.checkBootstrap()

proc handle(st: State, m: sink Msg) =
  case m.kind
  of mkRequest:
    # [I85] The request's decisions stay with it while it is parked.
    let saved = st.op
    st.op = OpCtx(q: m.request)
    st.handle(m.request)
    st.op = saved
    st.checkBinding()
    st.checkBootstrap()
    return
  of mkBound, mkInitialized, mkDestroyed, mkJobDone, mkCompleted:
    dec st.busy
  of mkCallDone, mkDiagnostic, mkAsync, mkCallJobDone, mkDeferredIdle, mkEvaluated:
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
  of mkEvaluated:
    st.evaluated(m.job, m.evaluated)
  of mkRequest, mkJobDone:
    discard
  st.settle()

proc checkDeadlines(st: State) =
  var now = getMonoTime()
  if st.storeFailed and now >= st.nextStoreTry:
    st.retryStore()
    now = getMonoTime()
  st.checkEvaluations(now)
  st.expireRoutes()
  st.checkExecutions()
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
    if a != nil and a.phase == apReadyPending:
      if now >= a.deadline:
        st.failAttempt(
          a, Failure(kind: fkStartupTimeout, reason: "the startup deadline passed")
        )
        a.expired = true
        st.abandon(a)
      elif not st.storeFailed or now >= st.nextStoreTry:
        # [IMPL] `ready` is written again (I82).
        st.promote(a)
    if x.state == msStopping and x.stopDeadline.isSome and now >= x.stopDeadline.get:
      # [G61, revised by A18; SPEC RUNTIME §10.2 l.3835-3838, l.3873-3874]
      # The cleanup failure is recorded; nothing still in use is released.
      # [G168 extended] It replaces an authority stop's classification.
      x.state = msError
      x.failure =
        Opt.some(Failure(kind: fkCleanupTimeout, reason: "the stop deadline passed"))
      x.enforced = Opt.none(Failure)
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
        x.enforced = Opt.none(Failure)
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
    if a != nil and a.phase == apReadyPending:
      consider(a.deadline)
      consider(
        if st.storeFailed:
          st.nextStoreTry
        else:
          getMonoTime()
      )
    if x.state == msStopping and x.stopDeadline.isSome:
      consider(x.stopDeadline.get)
  if st.storeFailed:
    consider(st.nextStoreTry)
  if st.shuttingDown and not st.shutdownDone:
    consider(st.shutdownDeadline)
  for a in st.asyncCalls.values:
    if not a.terminal and a.deadline.isSome:
      consider(a.deadline.get)
  for p in st.pendings.values:
    if not p.done:
      consider(p.deadline)
  let e = st.nextExpiry()
  if e.isSome:
    consider(e.get)
  let x = st.nextExecution()
  if x.isSome:
    consider(x.get)
  t

# Opening ------------------------------------------------------------------------

const UncleanEnd = "the Runtime ended without completing shutdown"

proc restore(st: State, snap: Snapshot) =
  ## [SPEC RUNTIME §9.3 l.3500-3506; IMPL] The retained instances, each with
  ## its id, provider id, record, intent, intent revision, origin and failure
  ## (RUN-0646), and a revision past every value exposed before (l.3506): the
  ## epoch's first. No realization survives the previous process (the store
  ## lock is the evidence), so cleanup is complete for every one of them.
  for s in snap.instances:
    let x = Inst(
      id: s.instance,
      record: s.record,
      providerId: s.providerId,
      created: s.created,
      state: s.state,
      failure: s.failure,
      revision: (st.epoch shl 32) + 1,
      intent: s.intent,
    )
    if s.intent == inRequested:
      x.intentRevision = s.intentRevision
      x.intentOrigin = s.origin
    if s.state in {msLoaded, msReady, msStopping}:
      # [IMPL-DECISION G193 (TF-29)] A completed shutdown leaves only
      # `unloaded` and `error` (G180), so the Runtime ended uncleanly: `error`
      # with `other`, intent kept. Resuming it is not a retry after failure.
      x.state = msError
      x.failure = Opt.some(Failure(kind: fkOther, reason: UncleanEnd))
    st.instances[x.id] = x
    st.putFacts(x)
  for r in snap.retired:
    st.tombstones[r.instance] = r.stateAssignment
  st.createKeys = snap.createKeys

proc load(st: State): Opt[EngineError] =
  ## [IMPL] Before any request (DECISIONS I82): the store is locked and read,
  ## the identity checked [G192 interim (TF-27)], the instances restored, a
  ## new revision epoch computed and everything written back. Without
  ## `storeDir` only the identity is set.
  if st.cfg.storeDir.isNone:
    st.runtimeId = st.cfg.runtimeInstanceId
    return Opt.none(EngineError)
  let (store, snap) = openStore(st.cfg.storeDir.get).valueOr:
    return Opt.some(engineError(ecModule, "the state store cannot be opened: " & error))
  st.store = store
  template fail(code: ErrorCode, message: string) =
    st.store.close()
    return Opt.some(engineError(code, message))

  var stored = 0'u64
  if snap.isSome:
    if st.cfg.runtimeInstanceId.len > 0 and
        st.cfg.runtimeInstanceId != snap.get.runtimeInstanceId:
      fail(
        ecInvalidParams, "the configuration names another Runtime than its state store"
      )
    st.runtimeId = snap.get.runtimeInstanceId
    stored = snap.get.epoch
  elif st.cfg.runtimeInstanceId.len > 0:
    st.runtimeId = st.cfg.runtimeInstanceId
  else:
    st.runtimeId = newRuntimeInstanceId()
  # [IMPL] The epoch passes the stored one and the wall clock, so a revision
  # of this start exceeds any exposed before, even from a run whose last
  # writes were lost or a store restored from a backup (RUN-0632).
  st.epoch = max(stored + 1, uint64(max(getTime().toUnix, 0)))
  if st.epoch > RevisionMask:
    fail(ecModule, "the revision epoch is exhausted")
  if snap.isSome:
    st.restore(snap.get)
  var known = initHashSet[string]()
  for id in st.instances.keys:
    known.incl(id)
  let reaped = st.store.reapSides(known).valueOr:
    fail(ecModule, "the state store cannot be read: " & error)
  for id in reaped:
    st.diagnose("removed the side records of unknown instance " & id)
  st.store.write(st.snapshot()).isOkOr:
    fail(ecModule, NotPersisted & ": " & error)
  Opt.none(EngineError)

proc runtimeLoop(s: ptr Shared) =
  var first: Msg
  try:
    first = s.inbox.recv()
  except Exception:
    return
  doAssert first.kind == mkRequest and first.request.kind == rqConfigure
  let cfg = first.request.config
  # [IMPL] 128 random bits per start keep every name this engine makes apart
  # from every earlier one (RUNTIME l.2633, l.3172-3175; I82).
  var rnd: array[16, byte]
  doAssert urandom(rnd), "no system randomness"
  var prefix = ""
  for b in rnd:
    prefix.add(toHex(int(b), 2).toLowerAscii)
  let st = State(
    shared: s,
    cfg: cfg,
    realizer: newRealizer(cfg.workDir, cfg.stateRoot),
    authorizer: initAuthorizer(cfg.policy, prefix),
    prefix: prefix,
    ctx: pinnedContext(),
    clock: cfg.clock,
    budget: (if cfg.revisionBudget == 0: DefaultRevisionBudget else: cfg.revisionBudget),
  )
  let failed = st.load()
  if failed.isSome:
    first.request.reply.answer(Reply(error: failed))
    s.finished = true
    return
  for reg in cfg.statics:
    discard st.realizer.registerStatic(reg)
  if cfg.authority.isSome:
    st.caRoot = toDigest(caRoots().contract)
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
    st.checkBinding()
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
  for i in 0 ..< s.evalSpawned:
    try:
      s.evals.send(EvalJob(kind: ejQuit))
    except Exception:
      discard
  if s.renewSpawned:
    try:
      s.renewals.send(EvalJob(kind: ejQuit))
    except Exception:
      discard
  st.store.close()
  s.finished = true

proc runtimeMain(s: ptr Shared) {.thread.} =
  markRuntimeThread()
  runtimeLoop(s)
  releasePerThread() # after the loop's locals are gone

# The engine handle ------------------------------------------------------------------

proc freeEngine(e: Engine) =
  ## Every thread has left; nothing sends to any channel or rings the bell.
  e.inbox.close()
  e.jobs.close()
  e.calls.close()
  e.evals.close()
  e.renewals.close()
  e.closeSlots()
  deinitLock(e.slotLock)
  freeBell(e.bell)
  freeAuditLog(e.audit)
  deallocShared(e)

proc openEngine*(cfg: EngineConfig): Result[Engine, EngineError] =
  ## Starts the Runtime thread with `cfg`; with `storeDir`, opens and restores
  ## the persistent state first (`load`). Static registrations whose table is
  ## invalid were rejected by `checkStaticRegistration` before this. A Runtime
  ## identity has 1 to 128 UTF-8 bytes (§9.2) and may be left empty only with
  ## a store. INVALID_PARAMS for a configuration the store refuses, MODULE_ERROR
  ## for a store that cannot be used; nothing is left running.
  let id = cfg.runtimeInstanceId
  if not (id.len in 1 .. 128 and isValidUtf8(id)) and
      not (id.len == 0 and cfg.storeDir.isSome):
    return err(engineError(ecInvalidParams, "invalid runtime instance id"))
  if cfg.authority.isSome and cfg.authority.get.instance.len == 0:
    return err(engineError(ecInvalidParams, "the authority policy names no instance"))
  let e = createShared(Shared)
  e.audit = newAuditLog(cfg.callRecords)
  e.clock = cfg.clock
  e.inbox.open()
  e.jobs.open()
  e.calls.open()
  e.evals.open()
  e.renewals.open()
  e.bell = newBell()
  initLock(e.slotLock)
  try:
    createThread(e.runtime, runtimeMain, e)
  except ResourceExhaustedError:
    doAssert false, "cannot start the Runtime thread"
  let r = e.call(Request(kind: rqConfigure, config: cfg))
  if r.error.isSome:
    joinThread(e.runtime)
    e.freeEngine()
    return err(r.error.get)
  ok(e)

proc newEngine*(cfg: EngineConfig): Engine =
  ## `openEngine` for a configuration without a store, which cannot fail.
  doAssert cfg.storeDir.isNone, "a persistent engine is opened with openEngine"
  let e = openEngine(cfg)
  doAssert e.isOk, "invalid runtime instance id"
  e.get

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

proc recover*(
    e: Engine, instance: string, expectedRevision: uint64, origin = hostOrigin()
): Result[InstanceView, EngineError] =
  ## [SPEC RUNTIME §9.3 recover_module] Returns the resulting state, as
  ## `start` does.
  let r = e.call(
    Request(
      kind: rqRecover,
      instance: instance,
      origin: origin,
      expectedRevision: Opt.some(expectedRevision),
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

proc cleanupPending*(e: Engine, instance: string): bool =
  ## [IMPL] Host and test observation: `instance` is `unloaded` or `error` and
  ## the cleanup of its previous realization has not completed, so a start or
  ## a recovery answers NOT_READY (RUNTIME §3.4 l.587-588, l.3538; G20). The
  ## view does not show it: an instance reaches `error` before its cleanup
  ## ends. False for an unknown instance.
  e.call(Request(kind: rqCleanup, instance: instance)).pending

proc routes*(e: Engine): seq[LogosNSRuntimeControlRouteRecord] =
  ## The route records not dropped, in creation order (host and test
  ## observation).
  e.call(Request(kind: rqRoutes)).routes

proc diagnostics*(e: Engine): seq[string] =
  ## [SPEC RUNTIME l.1227] The retained diagnostics, oldest first: dropped
  ## publications, ignored provider completions, long delivery waits.
  e.call(Request(kind: rqDiagnostics)).diagnostics

proc stopForAuthority*(
    e: Engine, instance: string, ending: FailureKind
): Result[InstanceView, EngineError] =
  ## [SPEC RUNTIME §10.1 l.3801-3804; plan §2.10; C26] Stops a running
  ## instance whose execution authority ended for a reason the Runtime did
  ## not see itself, as the engine does for its own (intent and origin kept,
  ## `unloaded` with `ending` as `failure`). `ending` is one of
  ## `AuthorityEndings`. Nothing happens to an instance that is not loading
  ## or ready. The hook for settings reconciliation (RUN-0914, deferred).
  let r = e.call(Request(kind: rqStopForAuthority, instance: instance, ending: ending))
  r.toResult(r.view)

proc authorityBound*(e: Engine): (bool, uint64) =
  ## [IMPL] Host and test observation (I85): whether a Capability Authority
  ## is bound, and the binding generation, which every establishment and
  ## every loss advances.
  let r = e.call(Request(kind: rqAuthorityState))
  (r.bound, r.generation)

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
  for i in 0 ..< e.evalSpawned:
    joinThread(e.evalWorkers[i])
  if e.renewSpawned:
    joinThread(e.renewWorker)
  for i in 0 ..< e.callSpawned:
    joinThread(e.callWorkers[i])
  e.freeEngine()
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
