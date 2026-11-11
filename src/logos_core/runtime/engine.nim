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
## `start` is NOT_READY (l.585-587). A stop waits up to the stop deadline
## (10 s) for `unloaded` and otherwise reports `stopping`; shutdown waits up to
## the shutdown grace (10 s) and then records `cleanup-timeout` (§10.2). A
## direct realization is never force-released (§10.2 l.3838).
##
## Not yet built: Runtime Control (step 3: the engine takes the Runtime
## Control binding and publish callback for each instance from
## `EngineConfig.services`), routes and provider calls, events, the host API,
## `recover_module` and `retire_module`, and persistence of execution state.

{.push raises: [].}

import std/[locks, monotimes, sets, strutils, sysrand, tables, times, typedthreads]
import results
import ../abi/types
import ../cbor/utf8
import ../iface/[accept, outcome]
import ./[authz, bell, records, realizer]

export authz, records, realizer, outcome.ErrorCode

const
  DefaultStartupDeadline* = initDuration(seconds = 120)
  DefaultStopDeadline* = initDuration(seconds = 10)
  DefaultShutdownGrace* = initDuration(seconds = 10)
  MaxWorkers* = 64 ## [IMPL] worker threads; more jobs wait in the queue
  MaxRetainedChanges* = 4096 ## [IMPL] committed state changes kept for observation

type
  ModuleState* = enum
    ## [SPEC RUNTIME §3.4] `logos.runtime_control.state` for a local instance
    msUnloaded = "unloaded"
    msLoaded = "loaded"
    msReady = "ready"
    msStopping = "stopping"
    msError = "error"

  Intent* = enum ## [SPEC RUNTIME §9.3] `execution_state.intent`
    inUninitialized = "uninitialized"
    inRequested = "requested"
    inStopped = "stopped"

  FailureKind* = enum
    ## [SPEC RUNTIME §9.3 l.3750-3756] The initial classifications; fkLoader
    ## is `loader-` followed by a typed Module Loader error code.
    fkStartupTimeout = "startup-timeout"
    fkInitializationFailed = "initialization-failed"
    fkReportedByModule = "reported-by-module"
    fkHostTerminated = "host-terminated"
    fkAuthorityDenied = "authority-denied"
    fkAuthorityExpired = "authority-expired"
    fkAuthorityRevoked = "authority-revoked"
    fkAuthorityEvaluationFailed = "authority-evaluation-failed"
    fkPermissionEnforcementFailed = "permission-enforcement-failed"
    fkConfigurationIndeterminate = "configuration-indeterminate"
    fkCleanupFailed = "cleanup-failed"
    fkCleanupTimeout = "cleanup-timeout"
    fkRemoteStateUnknown = "remote-state-unknown"
    fkOther = "other"
    fkLoader = "loader"

  Failure* = object
    kind*: FailureKind
    loader*: LoaderErrorCode ## for fkLoader
    reason*: string ## diagnostics only; never replaces the classification

  Origin* = object
    ## The authenticated requester: the host's protected input, or a module
    ## instance through its Runtime Control binding.
    host*: bool
    instance*: string

  ExecutionState* = object ## [SPEC RUNTIME §9.3] `execution_state`
    revision*: uint64
    intent*: Intent
    intentRevision*: Opt[uint64] ## exactly when intent is `requested`

  InstanceView* = object ## One committed snapshot of an instance (§9.1 l.1849-1850).
    instance*: string
    module*: string
    state*: ModuleState
    failure*: Opt[Failure]
    execution*: ExecutionState
    intentOrigin*: Origin ## the origin of `requested` intent
    stateAssignment*: Opt[string]
    primaryContract*: Opt[Digest]
    implements*: seq[Digest]
    provider*: bool ## a provider view passed the §3.3 checks
    attempt*: string
      ## the current execution attempt; Runtime Control bindings for this
      ## realization are associated with it (report_failure)

  StateChange* = object ## one committed transition, in commit order
    serial*: uint64
    view*: InstanceView

  EngineError* = object
    code*: ErrorCode ## NOT_AUTHORISED, NOT_READY or INVALID_PARAMS
    message*: string

  ServicesFn* =
    proc(instance, attempt: cstring): InitServices {.nimcall, gcsafe, raises: [].}
    ## The instance-bound initialization services for one execution attempt:
    ## they must stay valid until that context's `_MODULE_destroy` returns.

  EngineConfig* = object
    workDir*: string ## private copies of dynamic artifacts
    stateRoot*: Opt[string] ## module state directories [G143]
    statics*: seq[StaticRegistration] ## protected static bindings (§2.3, §13.3)
    policy*: AuthzPolicy
    services*: ServicesFn
    ordering*: seq[(string, string)]
      ## [SPEC RUNTIME §3.7] accepted lifecycle-ordering constraints as
      ## (prerequisite instance, dependent instance)
    startupDeadline*: Duration
    stopDeadline*: Duration
    shutdownGrace*: Duration

  # Messages ---------------------------------------------------------------------
  RequestKind = enum
    rqConfigure
    rqCreate
    rqStart
    rqStop
    rqReportFailure
    rqView
    rqList
    rqAnswers
    rqChanges
    rqShutdown
    rqTerminate

  Reply = object
    error: Opt[EngineError]
    busy: int ## rqTerminate: jobs still running
    view: InstanceView
    views: seq[InstanceView]
    answers: seq[AuthzAnswer]
    changes: seq[StateChange]

  ReplyChannel = ptr Channel[Reply]

  Request = object
    kind: RequestKind
    origin: Origin
    instance: string
    record: ModuleRecord
    expectedRevision: Opt[uint64]
    attempt: string
    reason: string
    config: EngineConfig
    reply: ReplyChannel

  JobKind = enum
    jkBind
    jkInit
    jkDestroy
    jkQuit

  Job = object
    id: int
    case kind: JobKind
    of jkBind:
      spec: BindSpec
    of jkInit:
      init: ModuleInitFn
      input: ptr LogosModuleInitInput
    of jkDestroy:
      destroy: ModuleDestroyFn
      context: ptr LogosModuleContext
    of jkQuit:
      discard

  MsgKind = enum
    mkRequest
    mkBound
    mkInitialized
    mkDestroyed

  Msg = object
    job: int
    case kind: MsgKind
    of mkRequest:
      request: Request
    of mkBound:
      bound: BindResult
    of mkInitialized:
      res: LogosResult
      context: ptr LogosModuleContext
    of mkDestroyed:
      discard

  ReplySlot = object
    ## One reply channel, reused by one call after another [IMPL]. A sender
    ## signals the channel after releasing its lock (Nim 2.2.14
    ## `channels_builtin.sendImpl`), so the receiver cannot tell when the
    ## sender is done with it; a channel closed and freed after each reply
    ## takes that late signal in freed memory, often the next call's channel,
    ## whose wake-up is then lost. Slots are closed only by `close`, after the
    ## Runtime thread has been joined.
    ch: Channel[Reply]
    nextFree: ptr ReplySlot
    nextAll: ptr ReplySlot

  Shared = object
    inbox: Channel[Msg]
    jobs: Channel[Job]
    bell: Bell
    slotLock: Lock
    freeSlots: ptr ReplySlot
    allSlots: ptr ReplySlot
    runtime: Thread[ptr Shared]
    workers: array[MaxWorkers, Thread[ptr Shared]]
    spawned: int ## written by the Runtime thread only
    finished: bool ## the Runtime thread has left its loop

  Engine* = ptr Shared

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
    waiters: seq[ReplyChannel]

  StopWaiter = object
    reply: ReplyChannel
    deadline: MonoTime

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
    done: bool ## `close` asked the Runtime thread to leave

func classification*(f: Failure): string =
  ## [SPEC RUNTIME §9.3] The failure code reported for `f`.
  if f.kind == fkLoader:
    "loader-" & $f.loader
  else:
    $f.kind

func defaultConfig*(workDir: string): EngineConfig =
  EngineConfig(
    workDir: workDir,
    policy: allowAll(),
    startupDeadline: DefaultStartupDeadline,
    stopDeadline: DefaultStopDeadline,
    shutdownGrace: DefaultShutdownGrace,
  )

func hostOrigin*(): Origin =
  Origin(host: true)

func moduleOrigin*(instance: string): Origin =
  Origin(instance: instance)

func engineError(code: ErrorCode, message: string): EngineError =
  EngineError(code: code, message: message)

# Worker threads -----------------------------------------------------------------

proc post(s: ptr Shared, m: sink Msg) =
  try:
    s.inbox.send(m)
  except Exception:
    discard # [IMPL] cannot happen for these value-only messages
  s.bell.ring()

proc workerMain(s: ptr Shared) {.thread.} =
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
    attempt: x.current,
  )
  if x.intent == inRequested:
    result.execution.intentRevision = Opt.some(x.intentRevision)
    result.intentOrigin = x.intentOrigin

proc commit(st: State, x: Inst) =
  ## Records one committed change: the execution revision advances (§9.3
  ## l.3504-3505) and the change joins the ordered log (§9.1 l.1851).
  inc x.revision
  inc st.serial
  if st.changes.len >= MaxRetainedChanges:
    st.changes.delete(0)
  st.changes.add(StateChange(serial: st.serial, view: x.view))

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
  for w in a.waiters:
    w.answerView(x)
  a.waiters.setLen(0)
  if x.attempt == a:
    x.attempt = nil
  if a.cancelled:
    # [SPEC RUNTIME §3.4] A completed explicit stop: `unloaded`, failure cleared.
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
    w.answerView(x)
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
  ## and a refused one are the same NOT_AUTHORISED.
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
  if q.expectedRevision.isSome and q.expectedRevision.get != x.revision:
    # [SPEC RUNTIME §9.1 l.1832-1833] compared atomically with acceptance
    return err(engineError(ecInvalidParams, "execution revision mismatch"))
  ok(x)

proc start(st: State, q: Request) =
  ## [SPEC RUNTIME §9.1, §9.3 start_module; §3.6] Replies once the attempt
  ## is ready or failed, or once its deadline passed.
  if st.shuttingDown:
    q.reply.answerError(ecNotReady, "the Runtime is shutting down")
    return
  let x = st.lookup(q, "start_module").valueOr:
    q.reply.answerError(error.code, error.message)
    return
  case x.state
  of msLoaded, msReady:
    q.reply.answerView(x) # §9.1 l.1837: no new realization, intent unchanged
    return
  of msStopping:
    q.reply.answerError(ecNotReady, "the module instance is stopping")
    return
  of msError:
    if x.attempt != nil or x.teardown != 0:
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
  if st.cfg.services.isNil:
    q.reply.answerError(ecNotReady, "the Runtime has no initialization services")
    return
  # The attempt is accepted: `loaded`, failure cleared (§9.3 l.3758-3759).
  let id = st.nextJobId()
  let a = Attempt(
    id: id,
    token: "a-" & st.prefix & "-" & $id,
    inst: x,
    deadline: getMonoTime() + st.cfg.startupDeadline,
    waiters: @[q.reply],
  )
  x.tokens.incl(a.token)
  x.current = a.token
  a.request = RealizeRequest(
    moduleInstance: x.id,
    descriptor: x.record.descriptor,
    state: x.record.stateAssignment,
    services: st.cfg.services(cstring(x.id), cstring(a.token)),
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

proc stopInstance(st: State, x: Inst, reply: ReplyChannel, keepIntent: bool) =
  ## [SPEC RUNTIME §3.4, §9.1, §10.2] Moves `x` toward `unloaded`; replies
  ## once it is there or once the stop deadline passes.
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
      w.answerView(x)
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
    elif x.teardown != 0:
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
  elif reply != nil:
    x.stopWaiters.add(
      StopWaiter(reply: reply, deadline: getMonoTime() + st.cfg.stopDeadline)
    )

proc stop(st: State, q: Request) =
  ## [SPEC RUNTIME §9.1, §9.3 stop_module]
  if st.shuttingDown:
    q.reply.answerError(ecNotReady, "the Runtime is shutting down")
    return
  let x = st.lookup(q, "stop_module").valueOr:
    q.reply.answerError(error.code, error.message)
    return
  st.stopInstance(x, q.reply, keepIntent = false)

proc reportFailure(st: State, q: Request) =
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
  q.reply.answer(Reply())

proc create(st: State, q: Request) =
  ## A local module-instance record: `unloaded`, intent `uninitialized`
  ## (§9.3 l.3623). The slice takes records from the host only (G55).
  if st.shuttingDown:
    q.reply.answerError(ecNotReady, "the Runtime is shutting down")
    return
  if not q.origin.host:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  checkRecord(q.record).isOkOr:
    q.reply.answerError(ecInvalidParams, error)
    return
  var id = q.instance
  if id.len == 0:
    inc st.created
    id = "m-" & st.prefix & "-" & $st.created
  elif id.len > MaxInstanceIdBytes or not isValidUtf8(id):
    q.reply.answerError(
      ecInvalidParams, "an instance id must have 1 to 128 UTF-8 bytes"
    )
    return
  if id in st.instances:
    q.reply.answerError(ecInvalidParams, "the instance id is already in use")
    return
  if q.record.stateAssignment.isSome:
    for y in st.instances.values:
      if y.record.stateAssignment == q.record.stateAssignment:
        # [SPEC RUNTIME §8 l.1468] no shared state assignment by default
        q.reply.answerError(ecInvalidParams, "the state assignment is in use")
        return
  let x = Inst(id: id, record: q.record, state: msUnloaded, intent: inUninitialized)
  st.instances[id] = x
  st.commit(x)
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
      if x.state == msError and x.attempt.isNil and x.teardown == 0:
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

proc finishShutdown(st: State) =
  ## [IMPL] The Runtime thread keeps running after shutdown: it refuses new
  ## lifecycle requests and still cleans contexts that module code returns
  ## late, until `close`.
  for w in st.shutdownWaiters:
    w.answer(Reply())
  st.shutdownWaiters.setLen(0)
  st.shutdownDone = true

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
      q.reply.answer(Reply())
      return
    st.shutdownWaiters.add(q.reply)
    if not st.shuttingDown:
      st.shuttingDown = true
      st.shutdownDeadline = getMonoTime() + st.cfg.shutdownGrace
    st.shutdownStep()
    if st.shutdownComplete():
      st.finishShutdown()
  of rqTerminate:
    # `close`: only after shutdown. The reply says whether module code is
    # still running on a worker.
    if not st.shutdownDone:
      q.reply.answerError(ecNotReady, "the Runtime has not shut down")
      return
    st.done = true
    q.reply.answer(Reply(busy: st.busy))

proc destroyed(st: State, job: int) =
  if job in st.teardowns:
    var x: Inst
    discard st.teardowns.pop(job, x)
    x.teardown = 0
    st.realizer.finishRelease(x.id)
    x.realization = nil
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

proc handle(st: State, m: sink Msg) =
  case m.kind
  of mkRequest:
    st.handle(m.request)
    return
  of mkBound, mkInitialized, mkDestroyed:
    dec st.busy
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
  of mkRequest:
    discard
  if st.shuttingDown and not st.shutdownDone:
    st.shutdownStep()
    if st.shutdownComplete():
      st.finishShutdown()

proc checkDeadlines(st: State) =
  let now = getMonoTime()
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
    var kept: seq[StopWaiter]
    for w in x.stopWaiters:
      if now >= w.deadline:
        w.reply.answerView(x)
      else:
        kept.add(w)
    x.stopWaiters = kept
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
    for w in x.stopWaiters:
      consider(w.deadline)
  if st.shuttingDown and not st.shutdownDone:
    consider(st.shutdownDeadline)
  t

proc runtimeMain(s: ptr Shared) {.thread.} =
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
    if st.done:
      break
    s.bell.wait(st.nextDeadline())
  # Idle workers leave; one still inside module code keeps its thread.
  for i in 0 ..< s.spawned:
    try:
      s.jobs.send(Job(kind: jkQuit))
    except Exception:
      discard
  s.finished = true

# The engine handle ------------------------------------------------------------------

proc takeSlot(e: Engine): ptr ReplySlot =
  withLock e.slotLock:
    result = e.freeSlots
    if result != nil:
      e.freeSlots = result.nextFree
    else:
      result = createShared(ReplySlot)
      result.ch.open()
      result.nextAll = e.allSlots
      e.allSlots = result

proc giveSlot(e: Engine, slot: ptr ReplySlot) =
  withLock e.slotLock:
    slot.nextFree = e.freeSlots
    e.freeSlots = slot

proc call(e: Engine, q: sink Request): Reply =
  ## Sends `q` to the Runtime thread and waits for its one reply.
  let slot = e.takeSlot()
  q.reply = addr slot.ch
  e.post(Msg(kind: mkRequest, request: q))
  try:
    result = slot.ch.recv()
  except Exception:
    # The slot stays out of use: its reply may still arrive.
    return Reply(error: Opt.some(engineError(ecNotReady, "no reply")))
  e.giveSlot(slot)

proc newEngine*(cfg: EngineConfig): Engine =
  ## Starts the Runtime thread with `cfg`. Static registrations whose table
  ## is invalid were rejected by `checkStaticRegistration` before this.
  result = createShared(Shared)
  result.inbox.open()
  result.jobs.open()
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

proc shutdown*(e: Engine) =
  ## [SPEC RUNTIME §10.2] Host-initiated graceful shutdown; returns once every
  ## realization is released or its cleanup failure is recorded.
  discard e.call(Request(kind: rqShutdown))

proc close*(e: Engine): bool =
  ## Stops the Runtime thread after `shutdown` and frees the engine. Returns
  ## false, and keeps the engine allocated for good, when a worker is still
  ## inside module code that may yet report to it.
  let r = e.call(Request(kind: rqTerminate))
  if r.error.isSome:
    return false
  joinThread(e.runtime)
  if r.busy > 0:
    return false
  for i in 0 ..< e.spawned:
    joinThread(e.workers[i])
  # No thread sends to any channel or rings the bell any more.
  e.inbox.close()
  e.jobs.close()
  var slot = e.allSlots
  while slot != nil:
    let next = slot.nextAll
    slot.ch.close()
    deallocShared(slot)
    slot = next
  deinitLock(e.slotLock)
  freeBell(e.bell)
  deallocShared(e)
  true
