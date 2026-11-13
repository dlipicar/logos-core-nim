## The engine's messages and the channels that carry them: what callers on any
## thread send to the Runtime thread (`call`, `post`) and what it answers.
## Shared by `engine.nim` (the Runtime thread) and the native bindings modules
## call through (`bindings.nim`, `callside.nim`, `invoke.nim`, `events.nim`,
## `asynccall.nim`).
##
## Messages carry values only (no `ref`), so they move between threads under
## ORC and are deep-copied under refc.

{.push raises: [].}

import std/[atomics, locks, sysrand, times, typedthreads]
import results
import ../abi/types
import ../base/clock
import ../hash/hashinput
import ../iface/outcome
import ../authority/facts
import ./[authz, bell, callaudit, records, realizer, routes]

export
  authz, callaudit, clock, facts, records, realizer, routes, outcome.ErrorCode,
  hashinput.Digest

const
  DefaultStartupDeadline* = initDuration(seconds = 120)
  DefaultStopDeadline* = initDuration(seconds = 10)
  DefaultShutdownGrace* = initDuration(seconds = 10)
  DefaultEndedRoutes* = 4096
    ## [IMPL] ended route records kept per consumer once nothing reaches them
  MaxWorkers* = 64 ## [IMPL] worker threads; more jobs wait in the queue
  MaxCallWorkers* = 64
    ## [IMPL] threads that run asynchronous calls (INTERFACE §2.9), apart from
    ## the lifecycle workers so long provider calls never hold bind, init or
    ## destroy jobs; more calls wait in their queue
  MaxAsyncCalls* = 4096
    ## [IMPL] asynchronous calls prepared and not yet released, per engine;
    ## preparing another is MODULE_ERROR (INTERFACE l.2040-2041)
  MaxRetainedChanges* = 4096 ## [IMPL] committed state changes kept for observation
  MaxDiagnostics* = 4096 ## [IMPL] diagnostics kept for observation, oldest dropped
  DefaultRevisionBudget* = (1'u64 shl 32) - (1'u64 shl 16)
    ## [IMPL] accepting commits per instance and start; the 2^16 left over is
    ## for the commits that follow them, which must still advance (I82)
  MaxInstances* = 1024
    ## [IMPL] Runtime-known instances, retained ones included, past which
    ## `create_module` is MODULE_ERROR (BCP l.369; I82)
  EvalWorkers* = 4
    ## [IMPL] threads of the ordinary evaluation lane (I85): they call the
    ## Capability Authority's `evaluate`, apart from the lifecycle and call
    ## workers, so a CA `watch_changes` holding a call worker never delays an
    ## evaluation (CAP-0382)
  EvalQueue* = 256
    ## [IMPL] evaluations waiting for an ordinary-lane worker; one more is an
    ## admission failure, answered as an evaluation failure at once
  DefaultEvaluationDeadline* = initDuration(seconds = 5)
    ## [IMPL] how long an operation waits for its decisions (I85)
  DefaultListLimit* = 100 ## [SPEC RUNTIME l.3379] a list page without `limit`
  MaxEventWorkers* = 64
    ## [IMPL-DECISION G178] threads that run Runtime Control event handlers,
    ## apart from the lifecycle, call and evaluation workers, so a slow
    ## handler never delays a start or a call; more drains wait in their queue
  MaxListLimit* = 1000 ## [SPEC RUNTIME l.3379]

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
    providerId*: string
      ## [SPEC RUNTIME §9.3 l.2862-2871] the instance's provider record, kept
      ## across stop and start; empty when its record expects no contract
    attempt*: string
      ## the current execution attempt; Runtime Control bindings for this
      ## realization are associated with it (report_failure)
    orchestration*: bool
      ## [SPEC RUNTIME l.187-192; G53] the instance holds the orchestration
      ## role; observation only, it grants nothing (RUN-0785)

  StateChange* = object ## one committed transition, in commit order
    serial*: uint64
    view*: InstanceView

  EngineError* = object
    code*: ErrorCode
    message*: string

  BootstrapInstance* = object
    ## [SPEC RUNTIME §8, §13.2] One module instance of the protected bootstrap
    ## input, with its protected instance identity.
    instance*: string
    record*: ModuleRecord

  AuthorityPolicy* = object
    ## [SPEC RUNTIME §9; plan §2.3, §2.13] The `capability-authority` policy:
    ## protected input names the instance whose Capability Authority binding
    ## decides every module operation (DECISIONS I85).
    instance*: string ## the `logos_capability_authority` instance to bind
    evaluationDeadline*: Duration
      ## [IMPL] how long an operation waits for its decisions; 0 is
      ## `DefaultEvaluationDeadline`
    recovery*: bool
      ## [SPEC RUNTIME l.1674-1680] the derived rules also apply after a
      ## binding loss, so orchestration can recover the authority

  ModuleDeclaration* = object
    ## [G55] The one accepted declaration for a module name that
    ## `create_module` selects: protected deployment input (BCP l.367; RUNTIME
    ## l.3614-3621), a direct record.
    record*: ModuleRecord ## with no state assignment
    persistentState*: bool
      ## [IMPL] each created instance gets a fresh state assignment
      ## (RUNTIME §8 l.1451)

  EngineLimits* = object
    ## [IMPL; I86] The engine's limits that are not host-tunable, documented
    ## in docs/HOST-CONFIG.md; 0 is the default (`effective`). Tests set them
    ## small.
    listResponseBytes*: int
      ## the records of one list page (RUNTIME l.3381); default 4 MiB
    snapshotsPerConsumer*: int ## retained list snapshots per consumer; default 8
    snapshotBytesPerConsumer*: int ## their storage per consumer; default 8 MiB
    snapshotsTotal*: int ## retained list snapshots in all; default 256
    snapshotBytesTotal*: int ## their storage in all; default 64 MiB
    snapshotIdle*: Duration ## a snapshot without a page expires; default 10 min
    snapshotLifetime*: Duration
      ## a snapshot expires this long after it was made; default 1 h
    endRegsPerConsumer*: int
      ## `observe_end` registrations per consumer instance (INTERFACE l.1483);
      ## default 1024
    endRegsTotal*: int ## `observe_end` registrations in all; default 16384
    rcQueue*: int
      ## [G178, G225] judged Runtime Control events waiting for one
      ## subscription's handler; one more loses the subscription; default 256,
      ## at least 2
    rcUnjudged*: int
      ## [G178] events waiting for a decision before they can join one
      ## subscription's queue; one more loses the subscription; default 256
    rcHintFacts*: int
      ## [G178] distinct affected subjects one pending `inventory_changed`
      ## hint retains; past it the hint is marked overflowed; default 1024
    rcSubsPerSubscriber*: int
      ## Runtime Control subscriptions one module instance holds (until it
      ## unsubscribes them or its attempt ends); default 32
    rcSubsTotal*: int ## Runtime Control subscriptions in all; default 1024
    rcWorkersPerSubscriber*: int
      ## [G178] event workers running one subscriber's handlers at once;
      ## default 4
    rcDrainQuota*: int
      ## [G178] entries one drain of a subscription delivers before it goes
      ## behind the others; default 16

  EngineConfig* = object
    runtimeInstanceId*: string
      ## [SPEC RUNTIME §9.2 l.2665-2672] this Runtime's identity, assigned by
      ## the host (`newRuntimeInstanceId`). Without `storeDir` nothing
      ## persists, so a host gives each engine start a fresh one and instance
      ## addresses and execution revisions never repeat under one identity
      ## [IMPL]. With `storeDir` it may be empty: the store's identity is
      ## used, generated when the store was created [G192 interim (TF-27)].
    workDir*: string ## private copies of dynamic artifacts
    stateRoot*: Opt[string] ## module state directories [G143]
    storeDir*: Opt[string]
      ## [IMPL] the persistent Runtime state (`store.nim`; DECISIONS I82);
      ## none: nothing persists
    revisionBudget*: uint64
      ## [IMPL] accepting commits per instance and engine start before the
      ## execution revision counts as exhausted (RUNTIME l.3507); 0 is
      ## `DefaultRevisionBudget`
    statics*: seq[StaticRegistration] ## protected static bindings (§2.3, §13.3)
    policy*: AuthzPolicy
      ## the internal policy (`allow-all`, with the test rules); unused under
      ## `authority`
    authority*: Opt[AuthorityPolicy]
      ## [IMPL] the `capability-authority` policy; none: the internal policy
    clock*: Clock
      ## [IMPL] the wall clock of decision validity (8a's `base/clock.nim`);
      ## nil: the system clock. Evaluation deadlines use the monotonic clock.
    facts*: SharedFacts
      ## [IMPL] the Capability Authority's attribute source, which the engine
      ## keeps current (8a's `authority/facts.nim`); nil: none. The host owns
      ## it.
    ordering*: seq[(string, string)]
      ## [SPEC RUNTIME §3.7] accepted lifecycle-ordering constraints as
      ## (prerequisite instance, dependent instance)
    declarations*: seq[ModuleDeclaration]
      ## [G55] what `create_module` may create, one per module name; a change
      ## affects only later creations (RUNTIME l.3621)
    startupDeadline*: Duration
    stopDeadline*: Duration
    shutdownGrace*: Duration
    endedRoutes*: int
      ## [SPEC RUNTIME §9.3 l.3249] retention selection: how many ended route
      ## records each consumer keeps once nothing reaches them (`engine.nim`)
    callRecords*: int
      ## [IMPL] how many call audit records are retained (`callaudit.nim`); 0
      ## is `DefaultCallRecords`
    limits*: EngineLimits ## [IMPL; I86]

  # Messages ---------------------------------------------------------------------
  RequestKind* = enum
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
    rqRc ## a Runtime Control method through a module's binding
    rqRcPrecheck ## the checks before a malformed Runtime Control request
    rqMaterialize ## `materialize_route`
    rqAdmit ## a call through a route handle
    rqObserveEnd ## a route handle's `observe_end`
    rqReleaseHandle ## a route handle's `release`
    rqRoutes ## every route record (observation for the host and tests)
    rqIdentity ## this Runtime's identity
    rqCleanup
      ## whether an instance's previous realization still has cleanup to
      ## complete (observation for the host and tests)
    rqSubscribe ## a route handle's `subscribe`
    rqUnsubscribe ## a route handle's `unsubscribe`
    rqCandidates ## the subscriptions an ordinary publication may reach
    rqScoped ## the subscriptions an invocation-scoped publication may reach
    rqDeliver ## the admission of one event handler invocation
    rqDiagnostics ## the retained diagnostics
    rqBootstrap
      ## [SPEC RUNTIME l.1640, §13.2] the configured instances, then the
      ## orchestration instance realized to `ready` (G190)
    rqRequestShutdown ## [SPEC RUNTIME §13.2] accept shutdown and answer at once
    rqAwaitShutdown ## wait for shutdown without initiating it (RUN-0728)
    rqRecover ## [SPEC RUNTIME §9.3 recover_module] from the host or a test
    rqAuthorityNotice
      ## [SPEC CA §8; plan §2.8] a `grant_changed` or `policy_changed`
      ## publication, from the publishing thread (`events.publishOp`)
    rqAuthorityState ## the binding (observation for the host and tests)
    rqStopForAuthority
    rqRefusal
      ## [S8b-1 interim] a routed Capability Authority call refused at the
      ## invocation boundary, to be retained (`invoke.authorityRefusal`)
    rqRcSubscribe ## [G178] a Runtime Control binding's `subscribe`
    rqRcUnsubscribe ## [G178] a Runtime Control binding's `unsubscribe`
    rqRcDeliver
      ## [G178] an event worker asks for the next entry of a subscription it
      ## drains, admitted for one handler invocation
      ## [SPEC RUNTIME §10.1 l.3801-3804] an execution authorization ended
      ## outside the Runtime's own checks (`engine.stopForAuthority`)

  RcMethod* = enum
    ## The Runtime Control methods this Runtime performs (RUNTIME §9.3).
    rmGetSelf = "get_self"
    rmEstablishRoute = "establish_route"
    rmRenewRoute = "renew_route"
    rmCloseRoute = "close_route"
    rmStartModule = "start_module"
    rmStopModule = "stop_module"
    rmReportFailure = "report_failure"
    rmShutdownRuntime = "shutdown_runtime"
    rmGetExecutionPermissions = "get_execution_permissions"
    rmGetReadiness = "get_readiness"
    rmRecoverModule = "recover_module"
    rmRetireModule = "retire_module"
    rmCreateModule = "create_module"
    rmDescribeProvider = "describe_provider"
    rmListModules = "list_modules"
    rmListRoutes = "list_routes"
    rmGetExecutionSummary = "get_execution_summary"
    rmGetPermissionSettings = "get_permission_settings"
    rmUpdatePermissionSettings = "update_permission_settings"

  RcCall* = object ## One checked Runtime Control request.
    request*: seq[byte] ## its deterministic CBOR, for `request_key` replay
    case m*: RcMethod
    of rmEstablishRoute:
      establish*: LogosNSRuntimeControlEstablishRouteRequest
    of rmRenewRoute:
      renew*: LogosNSRuntimeControlRenewRouteRequest
    of rmCloseRoute:
      close*: LogosNSRuntimeControlCloseRouteRequest
    of rmStartModule:
      start*: LogosNSRuntimeControlStartModuleRequest
    of rmStopModule:
      stop*: LogosNSRuntimeControlStopModuleRequest
    of rmReportFailure:
      report*: LogosNSRuntimeControlReportFailureRequest
    of rmGetReadiness:
      readiness*: LogosNSRuntimeControlGetReadinessRequest
    of rmRecoverModule:
      recover*: LogosNSRuntimeControlRecoverModuleRequest
    of rmRetireModule:
      retire*: LogosNSRuntimeControlRetireModuleRequest
    of rmCreateModule:
      createModule*: LogosNSRuntimeControlCreateModuleRequest
    of rmDescribeProvider:
      describe*: LogosNSRuntimeControlDescribeProviderRequest
    of rmListModules:
      listModules*: LogosNSRuntimeControlListModulesRequest
    of rmListRoutes:
      listRoutes*: LogosNSRuntimeControlListRoutesRequest
    of rmGetExecutionSummary:
      summary*: LogosNSRuntimeControlGetExecutionSummaryRequest
    of rmGetPermissionSettings:
      getSettings*: LogosNSRuntimeControlGetPermissionSettingsRequest
    of rmUpdatePermissionSettings:
      updateSettings*: LogosNSRuntimeControlUpdatePermissionSettingsRequest
    of rmGetSelf, rmShutdownRuntime, rmGetExecutionPermissions:
      discard

  CallTicket* = object
    ## One admitted route call, on the shared heap: the Runtime thread marks
    ## it cancelled when its route or consumer ends, or the asynchronous call
    ## is cancelled or times out (INTERFACE l.2101-2102), and frees it when the
    ## call has left the provider.
    cancelled*: Atomic[bool]
    closed*: Atomic[bool]
      ## its invocation-scoped destination is closed: a terminal outcome was
      ## decided (RUNTIME l.1275-1283)
    lock*: Lock
    endCode*: int
      ## [G174] under `lock`: the termination code of the route the call came
      ## through, once it ended (0 while it is ready); a result is committed
      ## only after reading it under the same lock (RUNTIME l.1292-1293)

  Admission* = object
    ## What a route call needs once the Runtime thread admitted it: the
    ## selected provider's binding and context, read at admission.
    introspection*: bool
      ## a well-known method the boundary answers itself: no provider code runs
    dispatch*: ModuleDispatchFn
    free*: ModuleFreeFn
    context*: ptr LogosModuleContext
    access*: pointer ## the provider's invocation-access state
    provider*: string ## the provider instance, named again when the call leaves
    route*: string
    ticket*: ptr CallTicket
    runtimeId*: string
    asyncApi*: ptr LogosAsyncProviderApi
      ## the provider's deferred surface (INTERFACE §2.9.2); nil: synchronous
    authority*: bool
      ## [SPEC CA l.88-91, l.579] the route selects the Capability Authority
      ## contract: the caller checks the request before dispatch
      ## (`invoke.authorityRefusal`)
    capture*: CallCapture
      ## [SPEC CA l.1176-1177] what the applied call decision requires the
      ## boundary to record (`callaudit.nim`); empty: nothing

  Reply* = object
    error*: Opt[EngineError]
    view*: InstanceView
    views*: seq[InstanceView]
    answers*: seq[AuthzAnswer]
    changes*: seq[StateChange]
    bytes*: seq[byte] ## rqRc: the encoded response, unless `view` answers it
    admission*: Admission
    routes*: seq[LogosNSRuntimeControlRouteRecord]
    id*: string ## rqIdentity
    subs*: seq[pointer]
      ## rqUnsubscribe, rqReleaseHandle, rqCandidates, rqScoped: subscriptions,
      ## each with a reference the receiver drops
    ready*: bool ## rqScoped: the invocation's destination is open
    admitted*: bool ## rqDeliver: the handler may run
    diagnostics*: seq[string]
    pending*: bool ## rqCleanup
    bound*: bool ## rqAuthorityState: a Capability Authority is bound
    generation*: uint64 ## rqAuthorityState: the binding generation
    capture*: CallCapture
      ## rqRc, rqRcPrecheck: what the applied Runtime Control decision
      ## requires the caller to record (`callaudit.nim`); empty: nothing
    name*: string ## rqRcDeliver: the admitted event's name (its bytes in `bytes`)
    drained*: bool
      ## rqRcDeliver: the drain ends here (no entry left, the subscription
      ## inactive, or its quota used); the worker leaves it

  ReplyChannel* = ptr Channel[Reply]

  Request* = object
    kind*: RequestKind
    origin*: Origin
    instance*: string
    module*: string ## rqStart, rqStop: the expected module name, when given
    record*: ModuleRecord
    expectedRevision*: Opt[uint64]
    attempt*: string ## the attempt token of the binding a module called through
    reason*: string
    config*: EngineConfig
    bootstrap*: seq[BootstrapInstance] ## rqBootstrap; `instance` names orchestration
    rc*: RcCall
    route*: string
    root*: Digest ## rqMaterialize: `expected_contract_root`
    rebuilt*: bool ## rqMaterialize: the construction input reconstructs `root`
    handle*: pointer ## a route handle's state
    bare*: string ## rqAdmit: the method name
    handler*: LogosRouteEndHandler
    userData*: pointer
    generation*: uint64 ## a route handle's or an invocation's path generation
    subId*: LogosSubscriptionId ## rqUnsubscribe
    outId*: ptr LogosSubscriptionId
      ## rqSubscribe: written before the subscription becomes active
    call*: pointer ## rqAdmit: the asynchronous call being admitted, if any
    ticket*: ptr CallTicket ## rqScoped, rqDeliver: the invocation's ticket
    scoped*: bool ## rqDeliver: an invocation-scoped publication
    payload*: seq[byte]
      ## rqAuthorityNotice: the event payload; empty when the publication was
      ## dropped before it was read (a malformed notice)
    ending*: FailureKind ## rqStopForAuthority: the classification
    gated*: bool
      ## rqRcDeliver: the worker holds the subscription's gate, so an entry
      ## may be admitted
    reply*: ReplyChannel

  JobKind* = enum
    jkQuit ## first and without fields, as `MsgKind`
    jkBind
    jkInit
    jkDestroy
    jkObserveEnd ## a route handle's terminal callback
    jkComplete ## an asynchronous call's completion callback
    jkRequestCancel ## a deferred invocation's `request_cancel` hook

  Job* = object
    id*: int
    case kind*: JobKind
    of jkBind:
      spec*: BindSpec
    of jkInit:
      init*: ModuleInitFn
      input*: ptr LogosModuleInitInput
    of jkDestroy:
      destroy*: ModuleDestroyFn
      context*: ptr LogosModuleContext
    of jkObserveEnd:
      handle*: pointer
    of jkComplete:
      call*: pointer
    of jkRequestCancel:
      deferred*: pointer
    of jkQuit:
      discard

  EvalJobKind* = enum
    ejQuit ## first and without fields, as `MsgKind`
    ejRun

  EvalJob* = object
    ## One `evaluate` for an evaluation worker (`authbinding.nim`): the bound
    ## Capability Authority's realization, read when it was dispatched.
    case kind*: EvalJobKind
    of ejRun:
      id*: int
      request*: seq[byte] ## the encoded `evaluate_request`
      dispatch*: ModuleDispatchFn
      free*: ModuleFreeFn
      context*: ptr LogosModuleContext
      access*: pointer ## the authority's invocation-access state
      ticket*: ptr CallTicket ## marked cancelled when the deadline passes
      runtimeId*: string
    of ejQuit:
      discard

  CallJobKind* = enum
    cjQuit ## first and without fields, as `MsgKind`
    cjRun

  CallJob* = object ## What a call worker runs (`asynccall.runCall`).
    case kind*: CallJobKind
    of cjRun:
      call*: pointer
    of cjQuit:
      discard

  RcJobKind* = enum
    rjQuit ## first and without fields, as `MsgKind`
    rjDrain

  RcJob* = object
    ## [G178] What an event worker runs: one drain of one Runtime Control
    ## subscription (`rcevents.drain`), holding one reference to it.
    case kind*: RcJobKind
    of rjDrain:
      sub*: pointer
    of rjQuit:
      discard

  AsyncEvent* = enum
    aeSubmit ## an asynchronous call was submitted
    aeTerminal ## its terminal outcome was decided off the Runtime thread
    aeDeferred ## it was handed to a deferred provider (`extra`)
    aeHook ## a deferred invocation's `request_cancel` is due (`extra`)

  MsgKind* = enum
    ## [IMPL] The first kind carries no fields. Nim 2.2.14's `=wasMoved` for a
    ## case object resets the active branch, sets the discriminator to its
    ## first value and then resets that branch too, reading the discriminators
    ## of case objects nested in it from bytes another branch wrote. Their
    ## `switch` ends in `__builtin_unreachable()`, so a stale value is
    ## undefined behaviour: GCC -O3 on Linux ran off the end of the hook
    ## (`Msg` with `Request.rc` first, `Job` with `BindSpec` first). A
    ## field-less first branch leaves nothing to reset.
    mkJobDone ## any other job returned
    mkRequest
    mkBound
    mkInitialized
    mkDestroyed
    mkCallDone ## a route call admitted into a provider has left it
    mkDiagnostic ## a diagnostic recorded off the Runtime thread
    mkAsync ## an asynchronous call's event (`AsyncEvent`)
    mkCallJobDone ## a call worker finished with a call
    mkCompleted ## a completion callback job returned
    mkDeferredIdle ## a deferred invocation has no execution or entry left
    mkEvaluated ## an evaluation worker finished one `evaluate` (`job`)
    mkRcHandled ## [G178] a Runtime Control event handler returned (`target`)

  Msg* = object
    job*: int
    case kind*: MsgKind
    of mkRequest:
      request*: Request
    of mkBound:
      bound*: BindResult
    of mkInitialized:
      res*: LogosResult
      context*: ptr LogosModuleContext
    of mkDestroyed, mkJobDone:
      discard
    of mkCallDone:
      provider*: string
      route*: string
      ticket*: ptr CallTicket
    of mkDiagnostic:
      text*: string
    of mkAsync, mkCallJobDone, mkCompleted, mkDeferredIdle, mkRcHandled:
      event*: AsyncEvent
      target*: pointer ## the asynchronous call, or the deferred invocation
      extra*: pointer
    of mkEvaluated:
      evaluated*: EvalResult

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

  Shared* = object
    inbox*: Channel[Msg]
    jobs*: Channel[Job]
    bell*: Bell
    slotLock*: Lock
    freeSlots: ptr ReplySlot
    allSlots: ptr ReplySlot
    runtime*: Thread[ptr Shared]
    workers*: array[MaxWorkers, Thread[ptr Shared]]
    spawned*: int ## written by the Runtime thread only
    calls*: Channel[CallJob]
    callWorkers*: array[MaxCallWorkers, Thread[ptr Shared]]
    callSpawned*: int ## written by the Runtime thread only
    evals*: Channel[EvalJob] ## the ordinary evaluation lane
    evalWorkers*: array[EvalWorkers, Thread[ptr Shared]]
    evalSpawned*: int ## written by the Runtime thread only
    renewals*: Channel[EvalJob]
      ## [SPEC CA §5.1] the renewal lane: execution renewals only
    renewWorker*: Thread[ptr Shared]
    renewSpawned*: bool ## written by the Runtime thread only
    rcJobs*: Channel[RcJob] ## [G178] drains for the event workers
    rcWorkers*: array[MaxEventWorkers, Thread[ptr Shared]]
    rcSpawned*: int ## written by the Runtime thread only
    outstanding*: Atomic[int] ## asynchronous calls prepared and not yet freed
    finished*: bool ## the Runtime thread has left its loop
    audit*: AuditLog ## [SPEC CA l.1169, l.1330] the retained call records
    clock*: Clock ## the configured clock, for call-record timestamps

  Engine* = ptr Shared

const AuthorityEndings* = {
  fkAuthorityDenied, fkAuthorityExpired, fkAuthorityRevoked, fkAuthorityEvaluationFailed
} ## [SPEC RUNTIME l.3753; G168 extended] what an authority stop leaves

func classification*(f: Failure): string =
  ## [SPEC RUNTIME §9.3] The failure code reported for `f`.
  if f.kind == fkLoader:
    "loader-" & $f.loader
  else:
    $f.kind

func effective*(l: EngineLimits): EngineLimits =
  ## The limits with every 0 replaced by its default.
  result = l
  template fill(field, value: untyped) =
    if result.field <= default(typeof(result.field)):
      result.field = value

  fill(listResponseBytes, 4 * 1024 * 1024)
  fill(snapshotsPerConsumer, 8)
  fill(snapshotBytesPerConsumer, 8 * 1024 * 1024)
  fill(snapshotsTotal, 256)
  fill(snapshotBytesTotal, 64 * 1024 * 1024)
  fill(snapshotIdle, initDuration(minutes = 10))
  fill(snapshotLifetime, initDuration(hours = 1))
  fill(endRegsPerConsumer, 1024)
  fill(endRegsTotal, 16384)
  fill(rcQueue, 256)
  fill(rcUnjudged, 256)
  fill(rcHintFacts, 1024)
  fill(rcSubsPerSubscriber, 32)
  fill(rcSubsTotal, 1024)
  fill(rcWorkersPerSubscriber, 4)
  fill(rcDrainQuota, 16)
  # [G178 (D2)] Room for one pending hint of each collection: a stalled
  # `inventory_changed` handler never loses its subscription.
  result.rcQueue = max(result.rcQueue, 2)

proc newRuntimeInstanceId*(): string =
  ## A lowercase canonical UUID version 4 (RFC 9562), the form the remote
  ## profiles require (RUNTIME l.2669-2670).
  var b: array[16, byte]
  doAssert urandom(b), "no system randomness"
  b[6] = (b[6] and 0x0F'u8) or 0x40'u8
  b[8] = (b[8] and 0x3F'u8) or 0x80'u8
  const hex = "0123456789abcdef"
  for i, x in b:
    if i in [4, 6, 8, 10]:
      result.add('-')
    result.add(hex[int(x shr 4)])
    result.add(hex[int(x and 0x0F)])

proc defaultConfig*(workDir: string): EngineConfig =
  ## A configuration with a fresh Runtime identity and allow-all policy.
  EngineConfig(
    runtimeInstanceId: newRuntimeInstanceId(),
    workDir: workDir,
    policy: allowAll(),
    startupDeadline: DefaultStartupDeadline,
    stopDeadline: DefaultStopDeadline,
    shutdownGrace: DefaultShutdownGrace,
    endedRoutes: DefaultEndedRoutes,
  )

func isRuntimeForm*(name: string): bool =
  ## [IMPL] A name of the form this Runtime gives what it creates:
  ## `m-` (instance), `s-` (state assignment) or `p-` (provider), 32 lowercase
  ## hex digits, `-` and a decimal number. The host configuration may not use
  ## one, so a retired Runtime-assigned name needs no tombstone: the random
  ## prefix keeps every later one apart from it (I82).
  if name.len < 36 or name[0] notin {'m', 's', 'p'} or name[1] != '-' or name[34] != '-':
    return false
  for i in 2 .. 33:
    if name[i] notin {'0' .. '9', 'a' .. 'f'}:
      return false
  for i in 35 ..< name.len:
    if name[i] notin {'0' .. '9'}:
      return false
  true

func hostOrigin*(): Origin =
  Origin(host: true)

func moduleOrigin*(instance: string): Origin =
  Origin(instance: instance)

func engineError*(code: ErrorCode, message: string): EngineError =
  EngineError(code: code, message: message)

# Worker threads -----------------------------------------------------------------

proc post*(s: ptr Shared, m: sink Msg) =
  try:
    s.inbox.send(m)
  except Exception:
    discard # [IMPL] cannot happen for these value-only messages
  s.bell.ring()

proc diagnose*(s: ptr Shared, text: string) =
  ## [SPEC RUNTIME l.1227] Records a diagnostic from any thread.
  s.post(Msg(kind: mkDiagnostic, text: text))

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

proc call*(e: Engine, q: sink Request): Reply =
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

proc closeSlots*(e: Engine) =
  ## Closes and frees every reply channel: only after the Runtime thread has
  ## been joined.
  var slot = e.allSlots
  while slot != nil:
    let next = slot.nextAll
    slot.ch.close()
    deallocShared(slot)
    slot = next
  e.allSlots = nil
  e.freeSlots = nil
