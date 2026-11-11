## The engine's messages and the channels that carry them: what callers on any
## thread send to the Runtime thread (`call`, `post`) and what it answers.
## Shared by `engine.nim` (the Runtime thread) and `bindings.nim` (the native
## bindings modules call through).
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
    providerId*: string
      ## [SPEC RUNTIME §9.3 l.2862-2871] the instance's provider record, kept
      ## across stop and start; empty when its record expects no contract
    attempt*: string
      ## the current execution attempt; Runtime Control bindings for this
      ## realization are associated with it (report_failure)

  StateChange* = object ## one committed transition, in commit order
    serial*: uint64
    view*: InstanceView

  EngineError* = object
    code*: ErrorCode
    message*: string

  ServicesFn* =
    proc(instance, attempt: cstring): InitServices {.nimcall, gcsafe, raises: [].}
    ## The publish callback for one execution attempt (events are step 4):
    ## it must stay valid until that context's `_MODULE_destroy` returns. The
    ## engine supplies the Runtime Control binding and invocation access itself
    ## and ignores those fields.

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
    services*: ServicesFn ## nil: no publish callback
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
    of rmGetSelf, rmShutdownRuntime, rmGetExecutionPermissions:
      discard

  CallTicket* = object
    ## One admitted route call, on the shared heap: the Runtime thread marks
    ## it cancelled when its route or consumer ends (INTERFACE l.2101-2102),
    ## and frees it when the call has left.
    cancelled*: Atomic[bool]

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

  Reply* = object
    error*: Opt[EngineError]
    busy*: int ## rqTerminate: jobs still running
    view*: InstanceView
    views*: seq[InstanceView]
    answers*: seq[AuthzAnswer]
    changes*: seq[StateChange]
    bytes*: seq[byte] ## rqRc: the encoded response, unless `view` answers it
    admission*: Admission
    routes*: seq[LogosNSRuntimeControlRouteRecord]
    id*: string ## rqIdentity

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
    rc*: RcCall
    route*: string
    root*: Digest ## rqMaterialize: `expected_contract_root`
    rebuilt*: bool ## rqMaterialize: the construction input reconstructs `root`
    handle*: pointer ## a route handle's state
    bare*: string ## rqAdmit: the method name
    handler*: LogosRouteEndHandler
    userData*: pointer
    reply*: ReplyChannel

  JobKind* = enum
    jkQuit ## first and without fields, as `MsgKind`
    jkBind
    jkInit
    jkDestroy
    jkObserveEnd ## a route handle's terminal callback

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
    of jkQuit:
      discard

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
