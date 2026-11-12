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
import ../hash/hashinput
import ../iface/outcome
import ./[authz, bell, records, realizer, routes]

export authz, records, realizer, routes, outcome.ErrorCode, hashinput.Digest

const
  DefaultStartupDeadline* = initDuration(seconds = 120)
  DefaultStopDeadline* = initDuration(seconds = 10)
  DefaultShutdownGrace* = initDuration(seconds = 10)
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

  EngineConfig* = object
    runtimeInstanceId*: string
      ## [SPEC RUNTIME §9.2 l.2665-2672] this Runtime's identity, assigned by
      ## the host (`newRuntimeInstanceId`). Until execution state and routes
      ## persist, a host gives each engine start a fresh one, so instance
      ## addresses and execution revisions never repeat under one identity
      ## [IMPL].
    workDir*: string ## private copies of dynamic artifacts
    stateRoot*: Opt[string] ## module state directories [G143]
    statics*: seq[StaticRegistration] ## protected static bindings (§2.3, §13.3)
    policy*: AuthzPolicy
    ordering*: seq[(string, string)]
      ## [SPEC RUNTIME §3.7] accepted lifecycle-ordering constraints as
      ## (prerequisite instance, dependent instance)
    startupDeadline*: Duration
    stopDeadline*: Duration
    shutdownGrace*: Duration

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

  CallJobKind* = enum
    cjQuit ## first and without fields, as `MsgKind`
    cjRun

  CallJob* = object ## What a call worker runs (`asynccall.runCall`).
    case kind*: CallJobKind
    of cjRun:
      call*: pointer
    of cjQuit:
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
    of mkAsync, mkCallJobDone, mkCompleted, mkDeferredIdle:
      event*: AsyncEvent
      target*: pointer ## the asynchronous call, or the deferred invocation
      extra*: pointer

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
    outstanding*: Atomic[int] ## asynchronous calls prepared and not yet freed
    finished*: bool ## the Runtime thread has left its loop

  Engine* = ptr Shared

func classification*(f: Failure): string =
  ## [SPEC RUNTIME §9.3] The failure code reported for `f`.
  if f.kind == fkLoader:
    "loader-" & $f.loader
  else:
    $f.kind

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
  )

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
