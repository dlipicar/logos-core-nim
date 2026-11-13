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
    algorithm, atomics, deques, locks, monotimes, sequtils, sets, strutils, sysrand,
    tables, times, typedthreads,
  ]
from std/os import sleep, `/`, createDir, dirExists, setFilePermissions, FilePermission
import results
import ../abi/types
import ../base/[perthread, testhooks]
import ../cbor/[decode, utf8]
import ../commitment
import ../iface/[accept, outcome, surface]
import ../loader/contract
from ../loader/provider import
  LoaderWiring, wireLoader, unwireLoader, loaderStaticRegistration
from ../transport/io/api import
  IoEvent, IoEventKind, IoSink, IoCommand, IoCommandKind, TransportConfig,
  defaultTransportConfig, ContractInput, EndpointId, ConnId, CallOutcome,
  ConnectFailure, PeerIdentity, SubmitResult, PublishFailure
from ../transport/envelope import MessageKind
from ../transport/session import PublishErrorKind
from ../transport/ticket import MaxTicketLifetime, RouteTicket
from ../transport/hello import
  acceptHello, HelloCheck, HelloFailure, HelloReason, RouteBinding, NotAuthorisedMessage
from ../transport/io/endpoint import checkEndpointBase
from ../transport/io/sock import unixStream
from ./tport import
  newTransportPorts, freeTransportPorts, ensureStarted, closeTransport, releaseOwner,
  closing, submit, submitOwner, newConnId, started
import
  ./[
    asynccall, authbinding, authscopes, bell, bindings, callside, dcache, events,
    execauth, inventory, invoke, loaderbinding, observe, plumbing, rcevents, served,
    sessionauth, sidetable, store, transported,
  ]

export plumbing

testHooksMarker("engine")

type
  # Runtime-thread state ---------------------------------------------------------
  AttemptPhase = enum
    apBind
    apInit
    apRealize ## [I89] `realize` sent to the bound Module Loader, not yet answered
    apReadyPending
      ## [IMPL] the realization is made and checked; `ready` waits for its
      ## write (I82)
    apCleanup ## the context made by the attempt is being destroyed
    apDone

  RealizationStatus = enum
    ## [SPEC RUNTIME l.3530-3534] `get_execution_summary`'s `realization`
    rsAbsent
    rsCurrent
    rsUnknown

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
    selected: Opt[ValueRecord]
      ## [I87] the configuration record selected before the attempt was
      ## accepted, borrowed from the instance's state until `beginAttempt`
      ## snapshots it
    ticket: ptr CallTicket
      ## [I89] its `realize` call's, marked cancelled when the attempt is
      ## cancelled or expires, so the Loader stops before `_MODULE_init`

  Waiter = object
    reply: ReplyChannel
    origin: string ## the module instance waiting, empty for the host

  ApplyRun = ref object
    ## [SPEC CONFIG §8; LOADER §8, §11; I87] One live configuration
    ## application in flight, until its hook has returned.
    job: int
    reply: ReplyChannel ## answered once the outcome is established
    valueRevision: uint64 ## the attempted record's (G236)
    input: Blob ## its `configuration_input`, kept until the hook returns
    deadline: MonoTime ## [G61, fourth deadline]
    expired: bool
      ## the deadline passed first: the outcome is indeterminate and already
      ## answered, and the hook's result is ignored (CFG-0139)

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
    realization: RealizationView ## the live realization, if any
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
    surface: seq[byte]
      ## [SPEC RUNTIME l.540-541; I86] the call surface validated at its last
      ## bind, kept for `describe_provider` after the realization ends
    surfaceContracts: seq[Digest] ## the exact contracts of `surface`
    schemas: Table[Digest, seq[byte]]
      ## [SPEC RUNTIME §2.4 l.432-434] by contract root: the deterministic
      ## `logos.schema_response` of each contract of `surface`, built from its
      ## exact documents (DECISIONS I88)
    realized: RealizationStatus
      ## [IMPL-DECISION G227 (TL-08)] the realization status as of its last
      ## commit
    rcSubs: seq[RcRec]
      ## [G178] the Runtime Control subscriptions it holds, until it
      ## unsubscribes them or the binding they were made through ends
    rcAttempt: string ## [G178] the binding its subscription ids count for
    rcNext: uint64 ## [G178] the last subscription id that binding gave
    rcHandlers: int
      ## [G178] handlers of its subscriptions admitted and not yet returned:
      ## its realization is released, and a context it made destroyed, only
      ## once none is left (INTERFACE l.1465, l.1999)
    heldAttempt: Attempt ## [G178] an attempt whose context waits for `rcHandlers`
    heldContext: ptr LogosModuleContext
    seen: bool ## [G178] its creation was exposed to observers
    seenState: ModuleState ## [G178] the state last exposed to observers
    config: ConfigState
      ## [I87] its configuration state, while `record.configuration` names a
      ## binding (`configurable`); owned here
    apply: ApplyRun
      ## [I87] the live configuration application in flight; its realization
      ## is not released before the hook returns (LDR-0136, CFG-0138)
    indeterminateStop: bool
      ## [IMPL-DECISION G237 interim (TF-28)] an explicit or shutdown stop is
      ## in progress although the instance is `error`: an application's
      ## outcome became indeterminate while it was `stopping`. The stop still
      ## completes it, to `unloaded`, within its stop deadline.

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

  InvKind = LogosNSRuntimeControlInventoryCollectionKind

  RcBlob = ref object
    ## [G178] One event value, encoded once for every subscription it reaches.
    name: string ## the fully qualified event name
    bytes: seq[byte]

  RcEntry = ref object
    ## [G178] One event, or one inventory hint, on its way to one subscription.
    blob: RcBlob
    subject: Subject ## what the event, or the hint's one affected record, concerns
    hint: bool
    collection: InvKind
    facts: seq[Subject]
      ## a pending hint: the affected subjects its decisions admitted (RUNTIME
      ## l.3419-3421), retained so a removal can still be judged (l.3420)
    keys: HashSet[string]
    overflowed: bool ## [G178 (D2)] an admitted subject was not retained
    gen, invalidations: uint64 ## the binding and invalidations it was judged under
    validUntil: Opt[uint64] ## the earliest end of the decisions it was judged by
    stale: bool ## a pending hint holds subjects judged under other conditions

  RcRec = ref object
    ## [G178] The Runtime thread's record of one Runtime Control subscription.
    sub: pointer ## its `rcevents.RcSub`, with the reference this record holds
    id: uint64
    attempt: string ## the binding it was made through
    subscriber: string
    event: RcEvent
    active: bool
    queue: Deque[RcEntry] ## judged and admitted, in committed order
    unjudged: Deque[RcEntry] ## waiting for their decisions, in committed order
    judging: bool ## the head of `unjudged` waits for an evaluation
    hints: array[InvKind, RcEntry] ## the pending hint per collection, while queued
    scheduled: bool ## waiting for a worker slot, or being drained
    running: bool ## a drain of it is dispatched
    served: int ## the entries this drain has served
    gone: bool ## unsubscribed or its binding ended: freed once no drain holds it

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
    order: int ## [I88] its place among dispatched calls
    completing: bool ## its completion job is dispatched
    session: bool
      ## [I90] a served invocation of a transported route: its outcome is a
      ## Response on `conn`, never a completion callback
    conn: uint64
    requestId: uint64
    linkTag: uint64
      ## [I90] a call through a transported handle: its tag on the link, once
      ## sent

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

  LoaderCallKind = enum
    lcCapabilities ## the binding check's `list_capabilities`
    lcRealize
    lcRelease
    lcApply
    lcStatus
      ## [plan §2.9] `get_status` after a `realize` (`attempt`) or a `release`
      ## (`realization`) whose invocation failed
    lcConfirm
      ## [plan §2.12] for the protected mechanism's confirmation: a release
      ## (`realization`), or `get_status` when the id was never learnt

  LoaderCall = object ## What one Module Loader call in flight is for.
    kind: LoaderCallKind
    inst: Inst ## the instance it acts on (not lcCapabilities)
    attempt: Attempt ## lcRealize, and lcStatus after a `realize`
    realization: string ## lcStatus after a `release`, lcConfirm
    ticket: ptr CallTicket

  LoaderLink = object
    ## [SPEC RUNTIME l.1641-1667; plan §2.6, §2.10] The Module Loader instance
    ## and the Runtime's system-service binding to it.
    inst: Inst ## the instance `LoaderInstanceId`, established at open
    bound: bool ## [SPEC RUNTIME l.1654] the binding is valid
    token: string ## the realization the binding checked
    capabilities: Capabilities
    checking: bool ## the binding's `list_capabilities` is out
    checked: string ## the realization that call checks
    wired: pointer ## the key of the Loader's protected wiring; nil when none
    configure: ReplyChannel
      ## the open, answered once the Loader is bound or cannot start
    cannotStart: Opt[string] ## why the open fails, once known
    calls: Table[int, LoaderCall] ## by job id
    issued: HashSet[string] ## [plan §2.8] every realization id this Loader gave
    lost: bool
      ## [SPEC RUNTIME l.3813-3825; plan §2.11 (G246, RT-05 interim)] its
      ## record is `error`: it reported its failure or gave an invalid
      ## response. Never undone in this process.
    termination: seq[string]
      ## [IMPL-DECISION G249] the instances whose cleanup needs the host
      ## process to end; empty unless the Loader was lost owning them
    when defined(lcnTestHooks):
      confirm: ReplyChannel ## [plan §2.12] `confirmTerminationForTests`, waiting
      confirmSent: bool ## its releases were sent
      confirming: int ## its releases in flight

  PubWait = ref object
    ## [I90; plan §2.7, E2] One invocation-scoped publication on a session,
    ## from its admission until its publisher has the verdict.
    conn: ConnId
    route: string
    done: bool ## the verdict came (`evPublishResult`, or the session closed)
    failure: Opt[InvocationFailure] ## the verdict; none: committed
    reply: ReplyChannel ## the publisher, once it waits

  State = ref object
    shared: ptr Shared
    cfg: EngineConfig
    realizer: Realizer
    authorizer: Authorizer
    instances: OrderedTable[string, Inst]
    attempts: Table[int, Attempt] ## by job id (bind and init jobs)
    teardowns: Table[int, Inst] ## by job id (destroy jobs)
    applies: Table[int, Inst] ## [I87] by job id (apply jobs)
    nextJob: int
    busy: int ## jobs dispatched and not yet answered
    jobClock: MonoTime
      ## [I88] the last time a lifecycle job finished, a worker was spawned or
      ## the queue stopped being empty
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
    callClock: MonoTime ## [I88] the same for the call pool
    callOrder: int ## [I88] calls dispatched so far
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
    tickets: TicketStore[RouteBinding]
      ## [SPEC TRANSPORT §8.1.1; I90] the live route tickets, in memory only
    sv: Served ## [G257; I90] the provider half of transported routes
    links: Table[uint64, Link]
      ## [I90] the caller half: one link per transported handle, by `ConnId`
    material: Table[string, Material]
      ## [I90; plan §2.4] by route: the latest live answer's unused material
    linkSubs: Table[pointer, (ConnId, uint64)]
      ## [I90; plan §2.7] a transported subscription's `SubState`: its link and
      ## id, while the link holds it
    linkHandling: Table[pointer, string]
      ## [I90] a transported subscription whose handler was handed an Event and
      ## has not returned: the consumer instance it counts in (`rcHandlers`)
    pubWaits: Table[uint64, PubWait] ## [I90; E2] by `pubTag`
    nextPubTag: uint64
    when defined(lcnTestHooks):
      connectFault: Opt[ConnectFailure]
        ## [plan §4.1] the next materialization fails with this cause
      spoilTicket: bool
        ## [plan §4.1] the next materialization's Hello carries a ticket the
        ## provider never issued
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
    limits: EngineLimits ## [I86] `cfg.limits` with the defaults filled in
    snapshots: Snapshots ## [I86] the list snapshots (`inventory.nim`)
    endRegs: CountTable[string]
      ## [I86] per consumer instance: its `observe_end` registrations
    endRegsTotal: int
    stepCommitted: HashSet[string]
      ## [IMPL-DECISION G227] the instances committed during the current step
    rcSubs: OrderedTable[pointer, RcRec]
      ## [G178] every Runtime Control subscription held, by its shared state
    rcByEvent: array[RcEvent, seq[RcRec]] ## [G178] the active ones, in creation order
    rcReady: Deque[RcRec]
      ## [G178] subscriptions with entries, waiting for a worker slot of their
      ## subscriber
    rcRunning: CountTable[string] ## [G178] per subscriber: its drains dispatched
    rcBusy: int ## [G178] drains dispatched and not yet ended
    rcHints: array[InvKind, RcBlob] ## [G178] the hint values, encoded once
    side: SideTable ## [D14; C-10] the private handoffs to and from the Loader
    ldr: LoaderLink ## [I89] the Module Loader and its binding

const
  MaxPasses = 8 ## [IMPL] handler passes per operation; more is an evaluation failure
  ReauthBatch = 64
    ## [IMPL; S8b-2 interim] route re-authorizations evaluated at once after
    ## a notice, the rest queued, so they never fill the ordinary lane's queue
  NotPersisted = "the execution state could not be persisted"
  ConfigNotPersisted = "the configuration state could not be persisted"
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
    of jkApply:
      # [SPEC LOADER §8; INTERFACE §2.6] The one hook call; provider calls
      # keep running on the call workers (IFC-0270).
      let res = job.apply(job.applyContext, job.applyData, csize_t(job.applyLen))
      s.post(Msg(kind: mkApplied, job: job.id, res: res))
    of jkLoader:
      # [SPEC RUNTIME l.1652-1667; plan §2.6, §2.8] One Loader method with a
      # SYSTEM_SERVICE context; the response is read and checked here.
      let j = job.loader
      if s.loaderLost.load(moAcquire) and not j.confirming:
        # [SPEC RUNTIME l.1657; plan §2.11 step 1] The binding is invalid: a
        # queued call is answered without reaching the Loader.
        let failure = InvocationFailure(
          code: ecModule, message: Opt.some("the Module Loader has failed")
        )
        s.post(
          Msg(
            kind: mkLoaderReply,
            job: job.id,
            loaderReply: LoaderReply(kind: lrFailed, invocation: failure),
          )
        )
        continue
      var fail, lose, garble, stall = false
      when defined(lcnTestHooks):
        # [D27 revised; plan §2.12] The faults a test selected for this method.
        let f = s.faults.takeFaults(j.meth)
        fail = j.meth in f.failInvocation
        lose = j.meth in f.loseReply
        garble = j.meth in f.garble
        stall = j.meth in f.stall
      const injected =
        InvocationFailure(code: ecModule, message: Opt.some("an injected failure"))
      var res =
        if fail:
          Result[seq[byte], InvocationFailure].err(injected)
        else:
          systemCall(
            s,
            j.dispatch,
            j.free,
            j.context,
            j.access,
            j.ticket,
            j.runtimeId,
            $j.meth,
            j.request,
          )
      if lose:
        res = Result[seq[byte], InvocationFailure].err(injected)
      elif garble and res.isOk:
        res = Result[seq[byte], InvocationFailure].ok(@[0xff'u8])
      when defined(lcnTestHooks):
        if stall:
          s.faults.stallHere()
      let reply = readReply(j.meth, j.instance, j.realization, res)
      s.post(Msg(kind: mkLoaderReply, job: job.id, loaderReply: reply))

proc workerMain(s: ptr Shared) {.thread.} =
  markRuntimeThread()
  workerLoop(s)
  releasePerThread() # after the loop's locals are gone

proc activation(s: ptr Shared, job: CallJob) =
  ## [plan §2.7, Rev R7] Call worker: a Subscribe a session received is
  ## decided on the Runtime thread (`servedActivate`), which records it on the
  ## session before it answers; only then is its SubscriptionResult sent, so a
  ## publication that follows the caller's LOGOS_OK finds it.
  let r =
    s.call(Request(kind: rqActivate, conn: job.conn, subId: job.subId, bare: job.event))
  var f = Opt.none(InvocationFailure)
  if r.error.isSome:
    f = Opt.some(failureOf(r.error.get))
  discard s.tport.submit(
    IoCommand(
      conn: job.conn,
      kind: IoCommandKind.cmdSubscriptionResult,
      subId: job.subId,
      subFailure: f,
    )
  )

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
    of cjActivate:
      activation(s, job)
      s.post(Msg(kind: mkCallJobDone, target: nil))

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
  if st.busy == s.spawned + 1:
    st.jobClock = getMonoTime() # [I88] the queue was empty until now
  try:
    s.jobs.send(job)
  except Exception:
    discard

proc nextJobId(st: State): int =
  inc st.nextJob
  st.nextJob

proc sendCallJob(st: State, job: sink CallJob) =
  ## A call worker for one job; spawned on demand.
  inc st.callBusy
  let s = st.shared
  if st.callBusy > s.callSpawned and s.callSpawned < MaxCallWorkers:
    try:
      createThread(s.callWorkers[s.callSpawned], callWorkerMain, s)
      inc s.callSpawned
    except ResourceExhaustedError:
      discard # the job waits for a busy call worker
  if st.callBusy == s.callSpawned + 1:
    st.callClock = getMonoTime() # [I88] the queue was empty until now
  try:
    s.calls.send(job)
  except Exception:
    discard

proc dispatchCall(st: State, a: AsyncRec) =
  ## A call worker for one submitted call.
  inc st.callOrder
  a.order = st.callOrder
  a.executing = true
  st.sendCallJob(CallJob(kind: cjRun, call: a.call))

proc overflow(st: State, calls: bool) =
  ## [IMPL; I88, deviation 5] One more worker beyond the pool's first 64.
  let s = st.shared
  try:
    if calls:
      createThread(s.callWorkers[s.callSpawned], callWorkerMain, s)
      inc s.callSpawned
    else:
      createThread(s.workers[s.spawned], workerMain, s)
      inc s.spawned
  except ResourceExhaustedError:
    discard # tried again after the next delay

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

# Runtime Control events (step 7b; DECISIONS I86) ----------------------------------
#
# [IMPL-DECISION G178 (TF-22)] The Runtime thread's side of `rcevents.nim`.
# Each committed change is fanned out where it becomes observable (`expose`,
# `endRoute`, route membership and record changes, `retireInst`), one entry
# per active subscription to its event. Entries are judged against the
# subscriber's authority in committed order (`judgeRc`): at once when no
# evaluation is needed, otherwise one evaluation at a time, through
# `decideDetached`. An admitted entry joins the subscription's queue and a
# refused one is dropped, so only what the subscriber may observe counts
# toward its bound (D3). An `inventory_changed` subscription keeps one pending
# hint per collection with the affected subjects its decisions admitted (D2).
# Event workers drain the queues, at most `rcWorkersPerSubscriber` per
# subscriber at a time (C1); each entry is admitted again just before its
# handler runs (`deliverRc`), with fresh decisions when the ones it was judged
# by may have changed (G161).

proc offerRc(st: State, rec: RcRec, e: RcEntry) {.gcsafe.}
proc observedRc(st: State, x: Inst) {.gcsafe.}

proc deactivateRc(st: State, rec: RcRec) =
  ## Nothing is judged, queued or admitted for it again.
  if not rec.active:
    return
  rec.active = false
  deactivate(rcSubOf(rec.sub))
  rec.queue.clear()
  rec.unjudged.clear()
  for k in InvKind:
    rec.hints[k] = nil
  let i = st.rcByEvent[rec.event].find(rec)
  if i >= 0:
    st.rcByEvent[rec.event].delete(i)

proc loseRc(st: State, rec: RcRec, why: string) =
  ## [IMPL-DECISION G225 (TF-35)] The Runtime ends the subscription without a
  ## signal to its subscriber: its entries are discarded and a diagnostic
  ## records it; `unsubscribe` of it is LOGOS_OK, and the subscriber
  ## resynchronizes by query (RUNTIME l.3426, l.3428).
  if rec.active:
    st.diagnose(
      "Runtime Control subscription " & $rec.id & " of " & rec.subscriber & " lost: " &
        why & " (G225)"
    )
    st.deactivateRc(rec)

proc freeRc(st: State, rec: RcRec) =
  st.rcSubs.del(rec.sub)
  drop(rcSubOf(rec.sub))

proc removeRc(st: State, rec: RcRec) =
  ## Unsubscribed, or its binding ended: the record goes once no drain holds
  ## it.
  st.deactivateRc(rec)
  if rec.gone:
    return
  rec.gone = true
  let x = st.instances.getOrDefault(rec.subscriber)
  if x != nil:
    let i = x.rcSubs.find(rec)
    if i >= 0:
      x.rcSubs.delete(i)
  if not rec.running:
    st.freeRc(rec)

proc endRcSubs(st: State, x: Inst) =
  ## [G178] The commit that takes `x` out of `loaded`/`ready` ends every
  ## subscription it holds before that commit is exposed, so `x` never
  ## receives the event of its own `stopping`. The records stay until
  ## `unsubscribe` or the end of their binding.
  for rec in x.rcSubs:
    st.deactivateRc(rec)

proc freeRcAttempt(st: State, x: Inst, token: string) =
  ## [IMPL] The subscriptions a binding's module never unsubscribed go with
  ## the binding.
  if x.isNil:
    return
  var gone: seq[RcRec]
  for rec in x.rcSubs:
    if rec.attempt == token:
      gone.add(rec)
  for rec in gone:
    st.removeRc(rec)

proc dispatchRc(st: State, rec: RcRec) =
  ## One drain of `rec` for an event worker; spawned on demand.
  inc st.rcBusy
  let s = st.shared
  if st.rcBusy > s.rcSpawned and s.rcSpawned < MaxEventWorkers:
    try:
      createThread(s.rcWorkers[s.rcSpawned], rcWorkerMain, s)
      inc s.rcSpawned
    except ResourceExhaustedError:
      discard # the drain waits for a busy event worker
  retain(rcSubOf(rec.sub))
  try:
    s.rcJobs.send(RcJob(kind: rjDrain, sub: rec.sub))
  except Exception:
    discard

proc pumpRc(st: State) =
  ## [G178 (C1 point 3)] A subscription with entries gets a drain while its
  ## subscriber has fewer than `rcWorkersPerSubscriber`; the others wait in
  ## order, so two blocked subscribers cannot hold the whole pool.
  var waiting: Deque[RcRec]
  while st.rcReady.len > 0:
    let rec = st.rcReady.popFirst()
    if not rec.active or rec.gone or rec.queue.len == 0:
      rec.scheduled = false
    elif st.rcRunning.getOrDefault(rec.subscriber) >= st.limits.rcWorkersPerSubscriber:
      waiting.addLast(rec)
    else:
      st.rcRunning.inc(rec.subscriber)
      rec.running = true
      rec.served = 0
      st.dispatchRc(rec)
  st.rcReady = move waiting

proc scheduleRc(st: State, rec: RcRec) =
  if not rec.scheduled and rec.active and rec.queue.len > 0:
    rec.scheduled = true
    st.rcReady.addLast(rec)
    st.pumpRc()

proc enqueueRc(st: State, rec: RcRec, e: RcEntry) =
  ## [G178, G225] An admitted entry; one more than `rcQueue` loses the
  ## subscription.
  if rec.queue.len >= st.limits.rcQueue:
    st.loseRc(rec, "its handler fell behind")
    return
  rec.queue.addLast(e)
  st.scheduleRc(rec)

proc publishRc(st: State, event: RcEvent, subject: Subject, bytes: seq[byte]) =
  ## [C29; G178] One committed change, `subject` its observed facts (G226),
  ## to every active subscription of `event`.
  if st.rcByEvent[event].len == 0:
    return
  let blob = RcBlob(name: event.qualified, bytes: bytes)
  # A copy: refc shares a `let` seq, and a loss in the loop removes from it.
  var subs = st.rcByEvent[event]
  for rec in subs:
    st.offerRc(rec, RcEntry(blob: blob, subject: subject))

proc hintRc(st: State, collection: InvKind, subject: Subject) =
  ## [SPEC RUNTIME l.3415-3421; G178 (D2)] A membership or record change of
  ## one record in `collection`, `subject` the facts its list method judges.
  if st.rcByEvent[reInventory].len == 0:
    return
  if st.rcHints[collection].isNil:
    st.rcHints[collection] = RcBlob(
      name: reInventory.qualified,
      bytes: encode(
          LogosNSRuntimeControlInventoryChangedEvent(
            collection: LogosNSRuntimeControlInventoryCollection(kind: collection)
          )
        )
        .get(newSeq[byte]()),
    )
  let blob = st.rcHints[collection]
  # A copy: refc shares a `let` seq, and a loss in the loop removes from it.
  var subs = st.rcByEvent[reInventory]
  for rec in subs:
    st.offerRc(
      rec, RcEntry(blob: blob, subject: subject, hint: true, collection: collection)
    )

func recordSubject(r: Route): Subject =
  ## [G226] What a route record exposes: its route, provider module, provider
  ## instance and target provider; never its consumer.
  routeSubject(r.id, r.selected.module, r.providerInstance, r.provider)

proc routeEndedRc(st: State, r: Route, before: RouteState) =
  ## [SPEC RUNTIME l.3226-3229, l.3717; G226] A route's end: its
  ## `route_state_changed` with the target's module and provider, no
  ## `reason` (route, module and provider are its facts), then a `routes`
  ## hint.
  if st.rcByEvent[reRouteState].len > 0:
    let provider = LogosNSRuntimeModuleProviderAddress(
      provider: r.provider, runtime_instance_id: Opt.some(st.runtimeId)
    )
    st.publishRc(
      reRouteState,
      routeSubject(r.id, r.selected.module, "", r.provider),
      encode(
        LogosNSRuntimeControlRouteStateChangedEvent(
          route: r.id,
          module: Opt.some(r.selected.module),
          provider: Opt.some(provider),
          old_state: routeState(before),
          new_state: routeState(r.state),
        )
      )
        .get(newSeq[byte]()),
    )
  st.hintRc(InvKind.Routes, recordSubject(r))

proc routeChangedRc(st: State, r: Route, decision: string, expires: Opt[uint64]) =
  ## [SPEC RUNTIME l.3417-3418] A renewal or re-authorization that changed
  ## the record's `decision_id` or `expires_at` is a record change; one that
  ## changed neither produces no hint (RUN-0978).
  if r.decisionId != decision or r.expiresAt != expires:
    st.hintRc(InvKind.Routes, recordSubject(r))

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
      # [SPEC RUNTIME l.3417, l.3420] A membership change, judged by the facts
      # retained with it.
      st.hintRc(InvKind.Routes, recordSubject(old))

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
    if a.session:
      # [SPEC TRANSPORT §6, §8.6] Nothing of it runs any more: its slot goes.
      st.sv.callEnded(a.conn, a.requestId)
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
    if a.linkTag != 0 and c.callEnd in {okCancelled, okTimeout}:
      # [IFC-0729; TRANSPORT §3.4] A sent call cancelled or timed out: Cancel
      # on its link; its late Response is discarded (`linkResponse`).
      let l = st.links.getOrDefault(c.link)
      if l != nil and l.state == lkOpen and a.linkTag in l.asyncs:
        discard st.shared.tport.submitOwner(
          IoCommand(conn: l.conn, kind: IoCommandKind.cmdCancel, callTag: a.linkTag)
        )
  if a.session:
    # [I90; plan §2.5] No callback: a decision no worker answered is the
    # Runtime's to answer (an end, a refused queue).
    let f = c.unsentFailure()
    if f.isSome:
      discard st.shared.tport.submitOwner(
        IoCommand(
          conn: a.conn,
          kind: IoCommandKind.cmdRespond,
          requestId: a.requestId,
          outcome: f.get,
          workEnded: false,
        )
      )
    c.suppress()
  elif a.attempt in st.liveAttempts:
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

proc refuseQueuedCall(st: State) =
  ## [IMPL; I88, deviation 5] The oldest call no call worker has begun is
  ## decided MODULE_ERROR (INTERFACE l.2041, a capacity limit, by analogy);
  ## its completion is an ordinary completion job (l.2053).
  var waiting: seq[AsyncRec]
  for a in st.asyncCalls.values:
    if a.executing and not a.terminal:
      waiting.add(a)
  waiting.sort(
    proc(x, y: AsyncRec): int =
      cmp(x.order, y.order)
  )
  for a in waiting:
    if asyncOf(a.call).refuseQueued(failure(ecModule, "no call worker is available")):
      st.diagnose("a queued call was refused: every call worker is busy")
      st.asyncTerminal(a)
      return

proc checkStarvation(st: State, now: MonoTime) =
  ## [IMPL; I88, deviation 5] A pool whose queue is not empty while every
  ## worker is busy and none has finished for `starvationDelay` gets one more
  ## worker, up to 64 beyond its first 64: nested calls and completions that
  ## each wait for the next one, from any thread, keep moving. Past the call
  ## pool's bound, after `refuseDelay`, the oldest queued call is refused;
  ## lifecycle jobs are never refused, so 128 that each wait for work queued
  ## behind them can still stall.
  let s = st.shared
  if st.busy > s.spawned and s.spawned < MaxWorkers + MaxNestedWorkers and
      now - st.jobClock >= st.limits.starvationDelay:
    st.overflow(calls = false)
    st.jobClock = now
  if st.callBusy > s.callSpawned:
    if s.callSpawned < MaxCallWorkers + MaxNestedCallWorkers:
      if now - st.callClock >= st.limits.starvationDelay:
        st.overflow(calls = true)
        st.callClock = now
    elif now - st.callClock >= st.limits.refuseDelay:
      st.refuseQueuedCall()
      st.callClock = now

proc starvationDeadline(st: State): Opt[MonoTime] =
  let s = st.shared
  var t = Opt.none(MonoTime)
  if st.busy > s.spawned and s.spawned < MaxWorkers + MaxNestedWorkers:
    t = Opt.some(st.jobClock + st.limits.starvationDelay)
  if st.callBusy > s.callSpawned:
    let d =
      st.callClock + (
        if s.callSpawned < MaxCallWorkers + MaxNestedCallWorkers:
          st.limits.starvationDelay
        else:
          st.limits.refuseDelay
      )
    if t.isNone or d < t.get:
      t = Opt.some(d)
  t

proc records(st: State): seq[AsyncRec] =
  for a in st.asyncCalls.values:
    result.add(a)

proc linksEnded(st: State, r: Route) {.gcsafe.}
proc keepMaterial(st: State, r: Route, path: string, t: RouteTicket) {.gcsafe.}
proc linksOfAttemptEnded(st: State, token: string) {.gcsafe.}
proc schemaBlob(st: State, r: Route): ptr SchemaBlob {.gcsafe.}

proc endServices(st: State, s: ptr AttemptServices, instance: string) =
  ## The realization an attempt made is gone, or the attempt made none: its
  ## bindings are invalid. Its calls are cancelled and their completions not
  ## yet begun suppressed; calls admitted into it as a provider and still
  ## without an outcome end NOT_READY, the bound of G174.
  if s == nil:
    return
  let token = attemptOf(s)
  st.liveAttempts.excl(token)
  st.linksOfAttemptEnded(token)
  # [SPEC RUNTIME l.629; I86] Its list snapshots go with its binding, and so
  # do the Runtime Control subscriptions its module never unsubscribed.
  st.snapshots.endAttempt(token)
  st.freeRcAttempt(st.instances.getOrDefault(instance), token)
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

proc endRegsGone(st: State, consumer: string, n: int) =
  ## [I86] `n` of the consumer's `observe_end` registrations fired or were
  ## released.
  if n <= 0:
    return
  let left = st.endRegs.getOrDefault(consumer) - n
  if left > 0:
    st.endRegs[consumer] = left
  else:
    st.endRegs.del(consumer)
  st.endRegsTotal = max(st.endRegsTotal - n, 0)

proc newStopDeadline(st: State): MonoTime =
  ## [G61, revised by A18] The stop deadline of a stop that starts now.
  getMonoTime() + st.cfg.stopDeadline

proc stopDeadlineOf(st: State, instance: string): MonoTime =
  ## The stop deadline of `instance`. The route's end runs inside the commit
  ## that made it `stopping`, before `stopInstance` sets the deadline, so the
  ## deadline is the one it is about to get.
  let x = st.instances.getOrDefault(instance)
  if x != nil and x.stopDeadline.isSome:
    x.stopDeadline.get
  else:
    st.newStopDeadline()

proc routeEnd(st: State, r: Route): RouteEnd =
  ## [G260] Which row of `ports.EndPolicies` the end of `r` is. Called inside
  ## the commit that ended it, while the instance that caused the end is in
  ## the state it entered.
  if r.endCode == ecNotAuthorised:
    return if r.failure == Opt.some(rfAuthorityExpired): reExpired else: reRevoked
  if r.failure == Opt.some(rfTransportError):
    return reTransport
  if r.failure == Opt.some(rfOther):
    return reNoSession # [I90] no ticket could be issued at its establishment
  if st.shuttingDown:
    return reShutdown
  if r.failure == Opt.some(rfProviderUnavailable):
    let p = st.instances.getOrDefault(r.providerInstance)
    return if p != nil and p.state == msError: reProviderFailure else: reProviderStop
  if r.failure == Opt.some(rfConsumerUnavailable):
    return reConsumerFailure
  let c = st.instances.getOrDefault(r.consumer)
  if c != nil and c.state in {msLoaded, msReady}: reCloseRoute else: reConsumerStop

proc drainDeadline(st: State, r: Route, bound: DrainBound): MonoTime =
  ## [G260; Rev R1] How long a session of `r` may still answer what it
  ## admitted (`ports.DrainBound`).
  case bound
  of dbNone:
    getMonoTime()
  of dbProviderStop:
    st.stopDeadlineOf(r.providerInstance)
  of dbConsumerStop:
    st.stopDeadlineOf(r.consumer)
  of dbShutdownGrace:
    st.shutdownDeadline
  of dbFromEnd, dbCleanup:
    st.newStopDeadline()

proc endTransported(st: State, r: Route) =
  ## [plan §2.8 steps 1 and 4; owner batch B 7; G260] A transported route
  ## ended: its tickets are revoked, then each of its sessions is ordered as
  ## the end's row of `ports.EndPolicies` says. An authority end terminates:
  ## the in-flight Requests are answered NOT_AUTHORISED, then ProtocolError
  ## NOT_AUTHORISED and close (TRANSPORT l.987-991). An end that leaves no
  ## usable session closes at once. A readiness end drains: no new admission,
  ## what was admitted answers until the bound, then close (K13).
  discard st.tickets.revokeRoute(r.id)
  if r.sessions.len == 0:
    return
  let policy = EndPolicies[st.routeEnd(r)]
  let deadline = st.drainDeadline(r, policy.bound)
  for conn in r.sessions:
    let s = st.sv.session(conn)
    if s.isNil:
      continue
    case policy.order
    of soTerminate:
      for c in st.sv.terminate(s):
        markSent(asyncOf(c))
    of soClose:
      st.sv.close(s)
    of soDrain:
      st.sv.drain(s, deadline)

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
  let before = r.state
  r.terminate(state, failure)
  st.routeEndedRc(r, before)
  st.linksEnded(r)
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
  if r.mode == rmLocalTransport:
    st.endTransported(r)
  for h in r.handles:
    scheduleEnd(h, r.endCode)
    st.dispatch(Job(id: st.nextJobId(), kind: jkObserveEnd, handle: h))
  st.endRegsGone(r.consumer, r.handles.len)
  r.handles.setLen(0)
  st.settle(r)

proc routesFollow(st: State, x: Inst) =
  ## [SPEC RUNTIME §3.4 l.620-626, §9.3 l.3225] A provider that is no longer
  ## `ready` fails its routes; a consumer that is no longer live closes its
  ## routes after an authorized stop and fails them after a failure.
  if x.state != msReady:
    # [plan §2.5] Its endpoints take no new connection (L3).
    st.sv.stopServingRealization(x.id)
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
  # [C19; G178] The one point where a committed change becomes observable.
  st.observedRc(x)

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
  st.stepCommitted.incl(x.id)
  if x.state != msStopping and not x.indeterminateStop:
    x.stopDeadline = Opt.none(MonoTime)
  x.pending = true
  st.routesFollow(x)
  if x.state notin {msLoaded, msReady}:
    st.releaseCallers(x)
    st.endRcSubs(x)
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
  st.stepCommitted.incl(x.id)
  if x.state != msStopping:
    x.stopDeadline = Opt.none(MonoTime)
  if x.state notin {msLoaded, msReady}:
    st.endRcSubs(x) # [G178] before the change is exposed
  st.written(x)
  st.routesFollow(x)
  if x.state notin {msLoaded, msReady}:
    st.releaseCallers(x)
  Opt.none(EngineError)

# Module configuration (step 9; DECISIONS I87) --------------------------------------

func configurable(x: Inst): bool =
  ## [SPEC CONFIG §2] Its declaration has a configuration-schema binding.
  x.record.configuration.isSome

func addressOf(st: State, id: string): LogosNSRuntimeModuleInstanceAddress =
  LogosNSRuntimeModuleInstanceAddress(
    runtime_instance_id: st.runtimeId, module_instance_id: id
  )

proc publishConfig(st: State, x: Inst) =
  ## [SPEC CONFIG l.324-331; C29] After every committed revision change, in
  ## revision order: the summary, never a value (CFG-0106, CFG-0108).
  if st.rcByEvent[reConfigurationState].len == 0:
    return
  st.publishRc(
    reConfigurationState,
    instanceSubject(x.record.module, x.id),
    encode(
      LogosNSRuntimeControlConfigurationStateChangedEvent(
        target: st.addressOf(x.id), state: summary(x.config)
      )
    )
      .get(newSeq[byte]()),
  )

proc persistConfig(st: State, x: Inst, next: ConfigState): Opt[EngineError] =
  ## [SPEC CONFIG §3 l.93; I87] A revision change of `x`'s configuration:
  ## written to its `cfg` side record before it is exposed, then taken and
  ## published. On a failed write nothing changes: MODULE_ERROR.
  let bytes = configBytes(next).valueOr:
    return Opt.some(engineError(ecModule, "the configuration state cannot be encoded"))
  st.store.putSide(ConfigSide, x.id, bytes).isOkOr:
    st.diagnose("the configuration of " & x.id & " was not written: " & error)
    return Opt.some(engineError(ecModule, ConfigNotPersisted))
  x.config.adopt(next)
  st.publishConfig(x)
  Opt.none(EngineError)

proc endAttempted(x: Inst) =
  ## [SPEC CONFIG §6 l.238-242 (CFG-0074, CFG-0075)] The attempt can no
  ## longer promote its snapshot: it is dropped and nothing else changes. A
  ## live application's snapshot ends with its own outcome.
  if x.configurable and x.config.attempted.isSome and x.apply.isNil:
    x.config.adopt(x.config.withoutAttempt)

proc releaseConfigs(st: State) =
  ## The engine ends: every configuration state's blobs are dropped.
  for x in st.instances.values:
    x.config.release()

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

func isLoader(st: State, x: Inst): bool =
  not st.ldr.inst.isNil and x == st.ldr.inst

proc cannotStart(st: State, why: string) =
  if st.ldr.cannotStart.isNone:
    st.ldr.cannotStart = Opt.some(why)
    st.diagnose("the Module Loader cannot start: " & why)

proc unwire(st: State) =
  ## The Loader's protected wiring ends after its `_MODULE_destroy` returned,
  ## or when its attempt ended without a realization.
  if st.ldr.wired != nil:
    unwireLoader(st.ldr.wired)
    st.ldr.wired = nil

proc finishAttempt(st: State, a: Attempt) =
  ## The attempt has nothing left to clean: its outcome is final.
  let x = a.inst
  a.phase = apDone
  if x.attempt == a or x.attempt.isNil:
    x.endAttempted()
  if a.request.configuration.isSome:
    # [I87] `_MODULE_init` has returned, or was never called.
    drop(a.request.configuration.get.input)
    a.request.configuration = Opt.none(ConfigurationHandoff)
  st.endServices(a.services, x.id)
  freeAttemptServices(a.services)
  a.services = nil
  for w in a.waiters:
    w.reply.answerView(x)
  a.waiters.setLen(0)
  if x.attempt == a:
    x.attempt = nil
  if st.isLoader(x) and x.realization.isNil:
    st.unwire()
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
  x.endAttempted()
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
  let x = a.inst
  if x.rcHandlers > 0:
    # [G178; INTERFACE l.1999] Its Runtime Control handlers return first.
    x.heldAttempt = a
    x.heldContext = ctx
    return
  let id = st.nextJobId()
  st.attempts[id] = a
  st.dispatch(
    Job(id: id, kind: jkDestroy, destroy: a.handoff.binding.destroy, context: ctx)
  )

# The Module Loader ---------------------------------------------------------------

proc loaderRefusal(st: State, meth: LoaderMethod): Opt[string] =
  ## [SPEC RUNTIME l.1654-1657 (RUN-0853, RUN-0854); plan §2.6] Each call
  ## checks the binding first: bound, the Loader `ready` with the realization
  ## the binding checked. During shutdown only `release` and `get_status`
  ## pass (RUN-1076).
  let l = st.ldr.inst
  if not st.ldr.bound or l.isNil or l.state != msReady or l.realization.isNil or
      l.current != st.ldr.token:
    return Opt.some("the Module Loader is not bound")
  if st.shuttingDown and meth notin {lmRelease, lmGetStatus}:
    return Opt.some("the Runtime is shutting down")
  Opt.none(string)

proc callLoader(
    st: State,
    call: LoaderCall,
    meth: LoaderMethod,
    request: sink seq[byte],
    instance = "",
    realization = Opt.none(string),
    confirming = false,
): int =
  ## [SPEC RUNTIME l.1652-1667; plan §2.6] One Loader method on a lifecycle
  ## worker through the Loader realization's generic dispatch, with a
  ## SYSTEM_SERVICE context; no module consumer is fabricated (RUN-0858).
  ## The Loader's in-flight count holds its realization until the reply.
  ## Returns the job id. `confirming`: a release for the confirmation after
  ## loss (plan §2.12), which a lost binding does not stop.
  let l = st.ldr.inst
  let r = l.realization
  var c = call
  if c.ticket.isNil:
    c.ticket = newTicket()
  let id = st.nextJobId()
  st.ldr.calls[id] = c
  inc l.inflight
  st.dispatch(
    Job(
      id: id,
      kind: jkLoader,
      loader: LoaderJob(
        meth: meth,
        request: request,
        instance: instance,
        realization: realization,
        dispatch: r.dispatch,
        free: r.free,
        context: r.context,
        access: l.services,
        ticket: c.ticket,
        runtimeId: st.runtimeId,
        confirming: confirming,
      ),
    )
  )
  id

func systemBinding(st: State, rec: ModuleRecord): bool =
  ## [IMPL] A static registration marked as a system module's (the Capability
  ## Authority's) has its call surface accepted as such.
  if rec.strategy == stDirectStatic:
    for reg in st.cfg.statics:
      if reg.binding == rec.binding:
        return reg.system
  false

func classify(e: LoaderError, phase: Opt[FailedPhase]): Failure =
  ## [SPEC RUNTIME §9.3 l.3750-3756; plan §2.7] A typed Loader error is
  ## `loader-<code>`, except `realization-failed` with the failed phase
  ## `init`, which is `initialization-failed` (l.1568-1569; S4b1-2 (b),
  ## owner batch A 3). The Loader's message is diagnostics only (I88).
  if e.code == lecRealizationFailed and phase == Opt.some(fpInit):
    Failure(kind: fkInitializationFailed, reason: e.message)
  else:
    Failure(kind: fkLoader, loader: e.code, reason: e.message, internal: true)

proc loaderLost(st: State, f: Failure) {.gcsafe.}

proc loaderInvalid(st: State, reason: string) =
  ## [SPEC RUNTIME l.3823; plan §2.8, §2.9; IMPL-DECISION G252] A response
  ## that breaks the contract or the engine's checks, on any call: continued
  ## realization control cannot be maintained, so the Loader has failed.
  st.diagnose("the Module Loader gave an invalid response: " & reason)
  st.loaderLost(
    Failure(kind: fkOther, reason: "the Module Loader gave an invalid response")
  )

func ownedBy(x: Inst, st: State): bool =
  ## The instance has a realization, or one being made, by the Loader.
  (x.realization != nil and x.realization.mechanism == mLoader) or
    (x.attempt != nil and x.attempt.phase == apRealize)

proc loaderOwns(st: State): bool =
  ## [SPEC RUNTIME l.3863; plan §2.10 (K5, R3)] The Loader owns a
  ## realization: active, failed, being made or released, or unresolved.
  for y in st.instances.values:
    if not st.isLoader(y) and y.ownedBy(st):
      return true
  false

proc loaderMissing(st: State, x: Inst): Opt[string] =
  ## [SPEC RUNTIME l.3816-3817 (RUN-0702); plan §2.10 (K4)] A start or
  ## recovery that needs the Loader while it is not bound; or of the Loader
  ## itself, which only the Runtime's bootstrap establishes.
  if st.isLoader(x):
    return Opt.some("the Module Loader is established only by the Runtime's bootstrap")
  if st.ldr.lost:
    # [SPEC RUNTIME l.3814 (K4); plan §2.11 step 7] Until a host restart.
    return Opt.some("the Module Loader has failed")
  if not st.ldr.bound:
    return Opt.some("the Module Loader is not available")
  Opt.none(string)

proc releaseRealization(st: State, x: Inst) =
  ## [SPEC RUNTIME §10.2 step 4] Graceful release through the realizer: one
  ## `_MODULE_destroy` on a worker, then the record is gone.
  let r = x.realization
  if r.isNil or x.teardown != 0:
    return
  if x.inflight > 0 or x.rcHandlers > 0 or x.apply != nil:
    # [IMPL] Calls already inside the provider finish first (§3.4 l.623), and
    # so do its Runtime Control handlers [G178] (INTERFACE l.1465, l.1999)
    # and a live configuration application [I87] (LOADER §11 (LDR-0136);
    # CONFIG l.272 (CFG-0137, CFG-0138)).
    x.releasePending = true
    return
  x.releasePending = false
  if r.mechanism == mLoader:
    # [SPEC LOADER §9; plan §2.6] Through the Loader. A realization whose
    # owner was lost or whose answer was unresolved is never released here.
    if r.unresolved:
      return
    let refused = st.loaderRefusal(lmRelease)
    if refused.isSome:
      r.unresolved = true
      st.diagnose("the realization of " & x.id & " cannot be released: " & refused.get)
      return
    x.teardown = st.callLoader(
      LoaderCall(kind: lcRelease, inst: x),
      lmRelease,
      releaseBytes(x.id, r.id),
      instance = x.id,
      realization = Opt.some(r.id),
    )
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

# Loader loss and lost answers ------------------------------------------------------

const LostAnswer = "the Module Loader's answer was lost and could not be resolved"

proc teardownDone(st: State, x: Inst) {.gcsafe.}
proc cleanupFailed(st: State, x: Inst, reason: string) {.gcsafe.}
when defined(lcnTestHooks):
  proc confirmStep(st: State) {.gcsafe.}

func lostView(st: State, id: string): RealizationView =
  RealizationView(
    mechanism: mLoader, id: id, issuer: st.ldr.token, unresolved: true, lost: true
  )

proc orphan(st: State, x: Inst, reason: string) =
  ## [SPEC RUNTIME l.613, l.3820-3825 (RUN-1067-RUN-1069); plan §2.9 (R5),
  ## §2.11 step 3] Nobody can say whether `x`'s realization, or the one its
  ## attempt was making, still exists: `error` with `other`, cleanup
  ## ownership kept (summary `unknown`, RUN-1067), intent and origin kept,
  ## nothing released by anyone (RUN-1068), and the bindings its module code
  ## may still use kept.
  if x.realization.isNil:
    x.realization = st.lostView("")
  x.realization.unresolved = true
  x.realization.lost = true
  x.teardown = 0
  x.releasePending = false
  x.indeterminateStop = false
  x.state = msError
  x.failure = Opt.some(Failure(kind: fkOther, reason: reason))
  x.enforced = Opt.none(Failure)
  x.exec = Opt.none(ExecAuth)
  inc x.execSerial
  x.provider = false
  let run = x.apply
  if run != nil:
    # [SPEC CONFIG §8 l.269-272] Its outcome is unknown; the request bytes
    # are the Loader's own copy, so the input goes now.
    x.apply = nil
    st.applies.del(run.job)
    drop(run.input)
    if not run.expired:
      x.config.adopt(x.config.withoutAttempt)
      run.reply.answerError(
        ecModule, "the configuration application failed: its outcome is unknown"
      )
  let a = x.attempt
  if a != nil:
    a.failed = true
    if a.services != nil and x.services.isNil:
      x.services = a.services
      a.services = nil
    st.finishAttempt(a)
  st.commit(x)
  st.releaseWaiters(x)

proc loaderLost(st: State, f: Failure) =
  ## [SPEC RUNTIME l.1657, l.3813-3825; plan §2.11 (RT-05 interim;
  ## IMPL-DECISION G246, G249)] The Module Loader has failed, in one step:
  ## its record is `error` and the binding invalid, so queued calls get an
  ## invocation failure. Owning nothing, it is released as any failed
  ## instance and the Runtime realizes nothing more until a host restart
  ## (K4). Otherwise every realization it owns, or was making, is orphaned,
  ## neither it nor they are released, and the host must end its process
  ## (S4b1-1 (a), owner batch A 6).
  let l = st.ldr.inst
  if l.isNil or st.ldr.lost:
    return
  st.ldr.lost = true
  st.ldr.bound = false
  st.shared.loaderLost.store(true, moRelease)
  var why = f.classification
  if f.reason.len > 0:
    why.add(": " & f.reason)
  st.diagnose("the Module Loader has failed: " & why)
  l.state = msError
  l.failure = Opt.some(f)
  l.enforced = Opt.none(Failure)
  l.exec = Opt.none(ExecAuth)
  inc l.execSerial
  l.provider = false
  st.commit(l)
  st.releaseWaiters(l)
  var owned: seq[Inst]
  var affected: seq[string]
  for x in st.instances.values:
    if not st.isLoader(x) and x.ownedBy(st):
      owned.add(x)
      affected.add(x.id)
  for x in owned:
    st.orphan(x, "its Module Loader failed")
  if affected.len == 0:
    # [plan §2.11 step 2] After the calls in flight return.
    st.releaseRealization(l)
    return
  # [SPEC RUNTIME l.3823; IMPL-DECISION G249 (R19)] Termination required.
  st.ldr.termination = affected
  st.diagnose(
    "termination required: the host process must end to clean " & affected.join(", ")
  )
  if st.cfg.onTerminationRequired != nil:
    st.cfg.onTerminationRequired(st.cfg.terminationData, affected)

proc resolve(st: State, c: LoaderCall) =
  ## [SPEC RUNTIME l.3793; plan §2.9] A `realize` or `release` whose
  ## invocation failed: `get_status` says whether its realization exists.
  ## While it is out the instance still counts as owned by the Loader.
  let x = c.inst
  let refused = st.loaderRefusal(lmGetStatus)
  if refused.isSome:
    st.diagnose("the realization of " & x.id & " cannot be resolved: " & refused.get)
    st.orphan(x, LostAnswer)
    return
  let id = st.callLoader(
    c,
    lmGetStatus,
    statusBytes(
      x.id,
      if c.attempt.isNil:
        Opt.some(c.realization)
      else:
        Opt.none(string),
    ),
    instance = x.id,
    realization =
      if c.attempt.isNil:
        Opt.some(c.realization)
      else:
        Opt.none(string),
  )
  if c.attempt.isNil:
    x.teardown = id

proc resolved(st: State, c: LoaderCall, reply: LoaderReply) =
  ## [SPEC RUNTIME l.3793; plan §2.9; IMPL-DECISION G252] What `get_status`
  ## answered. Not found: nothing was made (`realize`) or absence
  ## (`release`). Found: the engine owns it, so it is released (`realize`)
  ## or kept `current` with `cleanup-failed` (`release`). Another invocation
  ## failure: the question stays with this one instance (R5). Anything else
  ## is an invalid response.
  let x = c.inst
  let notFound = reply.kind == lrError and reply.error.code == lecRealizationNotFound
  let found = reply.kind in {lrActive, lrFailedRecord}
  if not (notFound or found or reply.kind == lrFailed):
    st.loaderInvalid(
      if reply.kind == lrInvalid:
        reply.reason
      else:
        "get_status answered " & $reply.kind
    )
    return
  if reply.kind == lrFailed:
    st.diagnose(
      "the status call for " & x.id & " failed with " & $reply.invocation.code
    )
    st.orphan(x, LostAnswer)
    return
  let a = c.attempt
  if a.isNil:
    if notFound:
      st.teardownDone(x)
    else:
      st.cleanupFailed(x, "the release call failed")
    return
  if notFound:
    st.failAttempt(a, Failure(kind: fkOther, reason: "the realize call failed"))
    st.finishAttempt(a)
    return
  let rec = reply.record
  if rec.realization in st.ldr.issued:
    st.loaderInvalid("a realization id was given twice")
    return
  st.ldr.issued.incl(rec.realization)
  x.realization = RealizationView(
    mechanism: mLoader,
    id: rec.realization,
    issuer: st.ldr.token,
    failed: reply.kind == lrFailedRecord,
    failure: rec.failure,
  )
  st.failAttempt(a, Failure(kind: fkOther, reason: "the realize call failed"))
  a.phase = apCleanup
  st.releaseRealization(x)

proc lateReply(st: State, c: LoaderCall, reply: LoaderReply) =
  ## [plan §2.11 step 3] A reply after the Loader was lost changes nothing it
  ## orphaned: a `realize` that made something gives the unresolved
  ## realization its id, never used.
  if c.kind == lcRealize:
    let x = c.inst
    discard st.side.withdrawInbound(x.id)
    c.attempt.ticket = nil
    if reply.kind in {lrActive, lrFailedRecord} and x.realization != nil and
        x.realization.lost and x.realization.id.len == 0:
      x.realization.id = reply.record.realization

proc bootstrapFailure(e: LoaderError): Failure =
  ## [SPEC RUNTIME §9.3 l.3753-3757] The bootstrap mechanism's errors while
  ## it realizes the Module Loader instance: `_MODULE_init()` failing is
  ## `initialization-failed`. The mechanism is implementation-local, not a
  ## Module Loader (RUNTIME l.212; G57), so its other errors are no "typed
  ## Module Loader error" (l.3754): they are `other`, with the realizer's code
  ## and message kept for diagnostics only (I88).
  if e.code == lecRealizationFailed and e.cause.isSome:
    Failure(kind: fkInitializationFailed, reason: e.message)
  else:
    Failure(
      kind: fkOther, reason: "realizer " & $e.code & ": " & e.message, internal: true
    )

proc checkContracts(x: Inst, r: RealizationView): Result[bool, string] =
  ## [SPEC RUNTIME §3.3, §3.6] The expected contracts against the validated
  ## call surface. Returns whether the instance exposes a provider view.
  let rec = x.record
  if rec.primaryContract.isNone and rec.implements.len == 0:
    # [SPEC RUNTIME §8 l.1423-1425] No declared contract: no provider record,
    # whatever the module exports.
    return ok(false)
  if not r.provider:
    return err("the module exposes no call surface")
  if rec.primaryContract.isSome:
    if r.contracts.primary.isNone or
        r.contracts.primary.get.root != rec.primaryContract.get:
      return err("the primary contract differs from the expected one")
  for c in rec.implements:
    var found = false
    for i in r.contracts.interfaces:
      if i.root == c:
        found = true
    if not found:
      return err("an expected interface contract is not implemented")
  ok(true)

proc promote(st: State, a: Attempt) {.gcsafe.}
proc checkBinding(st: State) {.gcsafe.}

proc adoptRealization(st: State, a: Attempt, r: RealizationView) =
  ## [SPEC RUNTIME §3.4, l.540-541; LOADER l.481-490] A realization made for
  ## the attempt, by either mechanism: its validated surface for
  ## `describe_provider` (kept after the realization ends; I86), then the
  ## checks before `ready`.
  let x = a.inst
  x.realization = r
  if r.provider:
    x.surface = r.callSurface
    x.surfaceContracts.setLen(0)
    if r.contracts.primary.isSome:
      x.surfaceContracts.add(r.contracts.primary.get.root)
    for c in r.contracts.interfaces:
      x.surfaceContracts.add(c.root)
    # [SPEC RUNTIME §2.4 l.432-434] `logos.schema` answers from these, never
    # from a consumer's construction input.
    x.schemas.clear()
    for root in x.surfaceContracts:
      let v = schemaResponse(r.contracts, root)
      if v.isOk:
        x.schemas[root] = encodeCbor(v.get)
  if not (a.cancelled or a.expired or a.failed) and getMonoTime() >= a.deadline:
    # [SPEC RUNTIME §3.4 l.664-669] The deadline passed before the Runtime
    # thread's next check: the attempt can no longer make the instance ready,
    # however soon after it the realization arrived.
    st.failAttempt(
      a, Failure(kind: fkStartupTimeout, reason: "the startup deadline passed")
    )
    a.expired = true
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

proc initialized(st: State, a: Attempt, res: LogosResult, ctx: ptr LogosModuleContext) =
  ## The bootstrap mechanism's `_MODULE_init` returned (the Loader's own).
  var orphan: ptr LogosModuleContext
  let made = st.realizer.completeInit(a.handoff, res, ctx, orphan)
  if made.isErr:
    st.failAttempt(a, bootstrapFailure(made.error))
    if orphan != nil:
      st.destroyContext(a, orphan)
    else:
      st.finishAttempt(a)
    return
  st.adoptRealization(a, viewOf(made.get))

proc promote(st: State, a: Attempt) {.gcsafe.} =
  ## [SPEC RUNTIME §3.4, l.3505; IMPL] `ready`, written before it is exposed.
  ## While the write fails the instance stays `loaded`, its realization made,
  ## and the write is tried again every second until the startup deadline
  ## (`checkDeadlines`; I82).
  let x = a.inst
  if x.configurable and x.config.attempted.isSome:
    # [SPEC CONFIG §6 l.233-236 (CFG-0072, CFG-0073); I87 C3] The snapshot
    # becomes current, written before `ready` is: a separate accepting write.
    # When it fails nothing changes and the attempt fails with `other`.
    let next = x.config.promoted
    if next.revision == x.config.revision:
      x.config.adopt(next)
    else:
      let refused = st.persistConfig(x, next)
      if refused.isSome:
        st.failAttempt(a, Failure(kind: fkOther, reason: ConfigNotPersisted))
        a.phase = apCleanup
        st.releaseRealization(x)
        return
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
    st.failAttempt(a, bootstrapFailure(error))
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
    st.failAttempt(a, bootstrapFailure(b.error))
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
  let r = ca.realization
  st.dispatchEval(
    EvalJob(
      kind: ejRun,
      id: e.id,
      request: bytes,
      dispatch: r.dispatch,
      free: r.free,
      context: r.context,
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

# Judging Runtime Control events (G161 extension, G178) ------------------------------

proc admits(st: State, a: AuthzAnswer, operation: string, s: Subject): bool {.gcsafe.}

func listOperation(k: InvKind): string =
  if k == InvKind.Routes:
    $rmListRoutes
  else:
    $rmListModules

func subjectKey(s: Subject): string =
  s.module & "\x1F" & s.instance & "\x1F" & s.provider & "\x1F" & s.route

func rcRequests(rec: RcRec, e: RcEntry): seq[AuthzRequest] =
  ## [G161 extension (TF-09)] The event's own decision, asked without a
  ## subject (its allow is applied to each); a hint also needs the list
  ## method's (RUNTIME l.3419), the one that method itself asks.
  result.add(
    AuthzRequest(
      action: aaObserveEvent,
      operation: $rec.event,
      consumer: rec.subscriber,
      filters: true,
    )
  )
  if e.hint:
    result.add(
      AuthzRequest(
        action: aaObserve,
        operation: listOperation(e.collection),
        consumer: rec.subscriber,
        filters: true,
      )
    )

proc rcAdmits(st: State, s: Subject, answers: seq[AuthzAnswer]): bool =
  ## Every decision admits the subject `s` (CA l.565-567; G226).
  for a in answers:
    if not st.admits(a, a.request.operation, s):
      return false
  true

proc judgedBy(st: State, e: RcEntry, answers: seq[AuthzAnswer]) =
  e.gen = st.gen
  e.invalidations = st.invalidations
  e.validUntil = Opt.none(uint64)
  for a in answers:
    if a.validUntil.isSome and
        (e.validUntil.isNone or a.validUntil.get < e.validUntil.get):
      e.validUntil = a.validUntil

proc addFact(st: State, rec: RcRec, e: RcEntry) =
  ## [G178 (D2)] An admitted subject joins its collection's pending hint; the
  ## first one makes the hint, one queue entry. Past `rcHintFacts` distinct
  ## subjects the hint is marked overflowed instead.
  var p = rec.hints[e.collection]
  if p.isNil:
    p = RcEntry(
      blob: e.blob,
      hint: true,
      collection: e.collection,
      gen: e.gen,
      invalidations: e.invalidations,
      validUntil: e.validUntil,
    )
    st.enqueueRc(rec, p)
    if not rec.active:
      return
    rec.hints[e.collection] = p
  else:
    if p.gen != e.gen or p.invalidations != e.invalidations:
      p.stale = true
    if e.validUntil.isSome and
        (p.validUntil.isNone or e.validUntil.get < p.validUntil.get):
      p.validUntil = e.validUntil
  let key = subjectKey(e.subject)
  if key notin p.keys:
    if p.keys.len >= st.limits.rcHintFacts:
      p.overflowed = true
    else:
      p.keys.incl(key)
      p.facts.add(e.subject)

proc judged(st: State, rec: RcRec, e: RcEntry, answers: seq[AuthzAnswer]) =
  ## [G178 (D3)] Admitted, the entry joins the queue or its pending hint;
  ## refused, it is dropped.
  if not rec.active:
    return
  st.judgedBy(e, answers)
  if not st.rcAdmits(e.subject, answers):
    return
  if e.hint:
    st.addFact(rec, e)
  else:
    st.enqueueRc(rec, e)

proc judgeRc(st: State, rec: RcRec) {.gcsafe.} =
  ## [G178 (D3); C21] The unjudged entries in order, one decision at a time:
  ## an answer that needs no evaluation is used at once, so the list only
  ## holds entries behind an evaluation, and a later entry never overtakes
  ## one parked on its decision.
  while rec.active and not rec.judging and rec.unjudged.len > 0:
    let e = rec.unjudged.peekFirst()
    rec.judging = true
    let ctx = DecideCtx(sync: true)
    st.decideDetached(
      rcRequests(rec, e),
      proc(answers: seq[AuthzAnswer]) =
        rec.judging = false
        ctx.completed = true
        if rec.unjudged.len > 0 and rec.unjudged.peekFirst() == e:
          discard rec.unjudged.popFirst()
          st.judged(rec, e, answers)
        if not ctx.sync:
          st.judgeRc(rec)
      ,
      proc() =
        # [I85] Shutdown: no evaluation begins; the entry is dropped.
        rec.judging = false
        ctx.completed = true
        if rec.unjudged.len > 0 and rec.unjudged.peekFirst() == e:
          discard rec.unjudged.popFirst()
        if not ctx.sync:
          st.judgeRc(rec)
      ,
    )
    ctx.sync = false
    if not ctx.completed:
      return

proc offerRc(st: State, rec: RcRec, e: RcEntry) {.gcsafe.} =
  ## [G178 (D3), G225] One fanned-out entry; one more than `rcUnjudged`
  ## waiting for decisions loses the subscription.
  if not rec.active:
    return
  if rec.unjudged.len >= st.limits.rcUnjudged:
    st.loseRc(rec, "the decisions on its events fell behind")
    return
  rec.unjudged.addLast(e)
  st.judgeRc(rec)

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
  let bare = (if q.kind in {rqRc, rqConfigCommit}: $q.rc.m
  else: q.bare)
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
  if st.op != nil and st.op.q.kind in {rqRc, rqRcPrecheck, rqConfigCommit}:
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
  if x.providerId.len == 0:
    # [SPEC RUNTIME l.165-173, l.1647; I88] A system service provider is a
    # provider backed by its instance: a record that declares no contract
    # has no provider record (l.1420-1421), so it is not bound.
    return "it has no provider record"
  let roots = caRoots()
  let root = toDigest(roots.contract)
  let b = x.realization
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

proc selectConfig(st: State, x: Inst, pe: PendingExec): Opt[Opt[ValueRecord]] =
  ## [SPEC CONFIG §3 l.123-126, §4 l.142-145; I87 C6, C17] For an otherwise
  ## authorized startup attempt, before it is accepted: the staged record,
  ## else the current one. None, or an ineligible one, is NOT_READY [G162
  ## interim (TF-10)]: intent stays `requested`, nothing is accepted, and a
  ## retained execution refusal (G168) is cleared, since the decision now
  ## allows. A staged record whose promotion could not advance the revision
  ## is MODULE_ERROR [G234]. For the orchestration instance at bootstrap
  ## either fails the bootstrap with MODULE_ERROR [G190 (TF-25 point 4)].
  ## Returns none once the start is answered.
  if not x.configurable:
    return Opt.some(Opt.none(ValueRecord))
  var refusal: EngineError
  case x.config.select
  of selStaged:
    if x.config.canAdvance:
      return Opt.some(x.config.staged)
    refusal = engineError(ecModule, "the configuration revision is exhausted")
  of selCurrent:
    return Opt.some(x.config.current)
  of selNone, selIneligible:
    refusal =
      engineError(ecNotReady, "the module instance has no eligible configuration value")
    if x.failure.isSome and
        x.failure.get.kind in {fkAuthorityDenied, fkAuthorityEvaluationFailed}:
      x.failure = Opt.none(Failure)
      st.commit(x)
  if x.orchestration and st.bootstrapReply != nil:
    st.bootstrapReply.answerError(
      ecModule, "the orchestration instance cannot start: " & refusal.message
    )
    st.bootstrapReply = nil
  pe.answerExec(refusal.code, refusal.message)
  Opt.none(Opt[ValueRecord])

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
  let selected = st.selectConfig(x, pe).valueOr:
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
    selected: selected,
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
  let missing = st.loaderMissing(x)
  if missing.isSome:
    q.reply.answerError(ecNotReady, missing.get)
    return
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

proc realizeThroughLoader(st: State, a: Attempt) =
  ## [SPEC LOADER §6; RUNTIME l.1641, l.3816-3817; plan §2.6] Every instance
  ## but the Loader: its private handoffs into the side table (D14), then
  ## `realize` with the accepted record's descriptor.
  let x = a.inst
  template fail(why: string) =
    st.failAttempt(a, Failure(kind: fkOther, reason: why))
    st.finishAttempt(a)
    return

  let refused = st.loaderRefusal(lmRealize)
  if refused.isSome:
    fail(refused.get)
  let bytes = realizeBytes(a.request).valueOr:
    st.diagnose("the realize request of " & x.id & " cannot be encoded: " & error)
    fail("the realize request cannot be encoded")
  let s = a.request.services
  st.side.putInbound(
    x.id,
    InboundHandoff(
      runtimeControl: s.runtimeControl,
      publish: s.publish,
      publishUserData: s.publishUserData,
      invocationAccess: s.invocationAccess,
    ),
  ).isOkOr:
    st.diagnose("the private handoff of " & x.id & " cannot be placed: " & error)
    fail("the private handoff cannot be placed")
  a.phase = apRealize
  a.ticket = newTicket()
  discard st.callLoader(
    LoaderCall(kind: lcRealize, inst: x, attempt: a, ticket: a.ticket),
    lmRealize,
    bytes,
    instance = x.id,
  )

proc beginAttempt(st: State, a: Attempt) {.gcsafe.} =
  ## [SPEC RUNTIME §3.6 steps 4-6] An accepted attempt: its token becomes
  ## live, its Runtime Control binding and invocation access are made, the
  ## configuration record selected before acceptance is snapshotted, and the
  ## bound Module Loader realizes it; the Loader itself is realized by the
  ## bootstrap mechanism (BOOTSTRAP l.287-288).
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
  if a.selected.isSome:
    # [SPEC CONFIG §6 l.220-224 (CFG-0063, CFG-0064); LOADER l.300-302] The
    # attempt's immutable snapshot, delivered as one `configuration_input`.
    let r = a.selected.get
    a.selected = Opt.none(ValueRecord)
    x.config.adopt(x.config.withAttempt(r))
    a.request.configuration = Opt.some(
      ConfigurationHandoff(
        input: newBlob(encodeInput(r)),
        live: x.config.binding.live,
        commitment: r.commitment,
        valueRevision: r.valueRevision,
      )
    )
  x.attempt = a
  if not st.isLoader(x):
    st.realizeThroughLoader(a)
    return
  # [plan §2.4] The Loader's protected wiring, keyed by the address of the
  # Runtime Control binding this attempt was given: engine-owned, unique per
  # attempt, never a value a module supplies.
  st.unwire()
  let key = cast[pointer](services.runtimeControl)
  wireLoader(
    key,
    LoaderWiring(
      statics: st.cfg.statics,
      workDir: st.cfg.workDir,
      stateRoot: st.cfg.stateRoot,
      side: st.side,
    ),
  ).isOkOr:
    st.failAttempt(
      a, Failure(kind: fkOther, reason: "the Module Loader cannot be wired")
    )
    st.diagnose("the Module Loader cannot be wired: " & error)
    st.finishAttempt(a)
    return
  st.ldr.wired = key
  let step = st.realizer.begin(a.request).valueOr:
    st.failAttempt(a, bootstrapFailure(error))
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
  if x.indeterminateStop:
    # [G237 interim] The stop in progress completes it, as `stopping` would.
    reply.answerView(x)
    return
  case x.state
  of msUnloaded, msStopping:
    reply.answerView(x)
    return
  of msLoaded:
    # [SPEC RUNTIME §9.1 l.1840-1841] The incomplete start can no longer make
    # the instance ready; its outcome is cleaned, then `unloaded`.
    let a = x.attempt
    a.cancelled = true
    if a.ticket != nil:
      a.ticket.cancelled.store(true) # the Loader stops before `_MODULE_init`
    x.endAttempted()
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
    if x.realization != nil and x.realization.lost:
      # [plan §2.11 step 5 (R4)] Accepted: the intent is cancelled (l.1838);
      # nothing can be released, so it stays `error`.
      reply.answerView(x)
      return
    if x.attempt != nil:
      x.attempt.cancelled = true
      if x.attempt.ticket != nil:
        x.attempt.ticket.cancelled.store(true)
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
    x.stopDeadline = Opt.some(st.newStopDeadline())
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
  if st.isLoader(x) and st.loaderOwns():
    # [plan §2.10 (K5, decision 5); RUNTIME l.3563-3569 by analogy] Not while
    # it owns a realization; owning none, it is stopped as any instance and
    # the binding ends (l.3816-3817).
    q.reply.answerError(ecNotReady, "the Module Loader still owns realizations")
    return
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
  let missing = st.loaderMissing(x)
  if missing.isSome:
    q.reply.answerError(ecNotReady, missing.get)
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
  if st.isLoader(x) and x.state == msReady:
    # [SPEC RUNTIME l.3813-3825; plan §2.11] The Loader's own report: it has
    # failed (RT-05 interim).
    st.loaderLost(f)
    q.reply.answer(success)
    return
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
    configuration = Opt.none(AcceptedConfiguration),
): Result[Inst, EngineError] =
  ## A local module-instance record: `unloaded`, intent `uninitialized`
  ## (§9.3 l.3623), written before it is exposed. Records come from the host
  ## or, through `create_module`, from its declarations (G55); `key` is that
  ## request's key association, written with the record (l.3627-3628). A
  ## configurable record comes with its accepted declaration, whose state
  ## (`initialState`) is written to its side record first (I87 C2).
  if st.shuttingDown:
    return err(engineError(ecNotReady, "the Runtime is shutting down"))
  if not origin.host and not created:
    return err(engineError(ecNotAuthorised, "not authorised"))
  checkRecord(record).isOkOr:
    return err(engineError(ecInvalidParams, error))
  if instance != LoaderInstanceId and namesLoader(instance, record):
    # [IMPL-DECISION G246] The reserved module and binding are the Loader's.
    return
      err(engineError(ecInvalidParams, "the record names the reserved Module Loader"))
  if record.configuration.isSome != configuration.isSome or
      (configuration.isSome and configuration.get.digest != record.configuration.get):
    # [SPEC RUNTIME §8 l.1386-1387 (RUN-0259)] Only an accepted declaration
    # gives a record its binding.
    return err(
      engineError(
        ecInvalidParams,
        "the record does not name the accepted configuration declaration",
      )
    )
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
  if configuration.isSome:
    # [SPEC CONFIG §4 l.139-142; G141] Its state, with the provisioned value
    # or the default staged; the side record before the snapshot names it
    # (C2: a crash in between leaves a record `reapSides` removes).
    x.config = initialState(configuration.get)
    if not x.config.admissible:
      x.config.release()
      return err(
        engineError(
          ecModule, "the configuration state would not fit a get_configuration response"
        )
      )
    let bytes = configBytes(x.config).valueOr:
      x.config.release()
      return err(engineError(ecModule, "the configuration state cannot be encoded"))
    st.store.putSide(ConfigSide, id, bytes).isOkOr:
      st.diagnose("the configuration of " & id & " was not written: " & error)
      x.config.release()
      return err(engineError(ecModule, ConfigNotPersisted))
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
    if x.configurable:
      discard st.store.deleteSide(ConfigSide, id)
      x.config.release()
    return err(refused.get)
  if x.configurable and x.config.revision > 0:
    # [SPEC CONFIG l.324-325] The source's staging, after the creation.
    st.publishConfig(x)
  ok(x)

proc create(st: State, q: Request) =
  let x = st.createInst(q.record, q.instance, q.origin, configuration = q.configuration).valueOr:
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
      if x.state in {msUnloaded, msStopping} or x.indeterminateStop:
        continue
      if st.isLoader(x) and (st.loaderOwns() or x.inflight > 0 or st.ldr.lost):
        # [SPEC RUNTIME l.3847-3849, l.3863; plan §2.10 (R3)] The Loader is
        # released last, once it owns no realization and runs no call; a
        # lost one only as §2.11 says.
        continue
      if x.realization != nil and x.realization.lost:
        # [plan §2.11 step 4] Nothing releases an orphaned realization.
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
  let keepLoader = st.loaderOwns() or (st.ldr.inst != nil and st.ldr.inst.inflight > 0)
  for x in st.instances.values:
    if st.isLoader(x) and x.state == msReady and keepLoader:
      # [plan §2.10 (R3)] Shutdown completes with the failure; the Loader
      # stays, narrowed to `release` and `get_status`.
      continue
    if x.state in {msLoaded, msReady, msStopping} or x.indeterminateStop or
        x.apply != nil:
      # [I87] An application in flight is waited for as a call is.
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
    return Opt.none(EngineError)
  var message =
    "shutdown completed with cleanup unresolved or failed: " & unresolved.join(", ")
  if st.ldr.termination.len > 0:
    # [IMPL-DECISION G249; plan §2.11 step 6] S4b1-1 (a): a C host learns here.
    message.add("; the Module Loader failed: the host process must end")
  Opt.some(engineError(ecModule, message))

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
    # [SPEC RUNTIME l.3846-3849; plan §2.9] No endpoint takes a new
    # connection; established sessions drain as their routes end.
    st.sv.stopServingAll()
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

func listRequest(st: State, x: Inst, operation: string): AuthzRequest =
  ## [G161 extension (TF-09); I86] A list method is authorized once, without
  ## a subject; the allow is applied to each record (`admits`).
  AuthzRequest(action: aaObserve, operation: operation, consumer: x.id, filters: true)

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
  elif q.bare in [$rmListModules, $rmListRoutes]:
    st.require(q, st.listRequest(x, q.bare))
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

proc observedRc(st: State, x: Inst) {.gcsafe.} =
  ## [SPEC RUNTIME l.3509, l.3715-3717, l.3417; G178] What one exposure of
  ## `x` produces, in this order: `module_state_changed` from the state last
  ## exposed to the new one, with the new state's failure and never
  ## `provider` (l.3496); `execution_state_changed`; a `modules` hint. Changes
  ## held back by a failed write collapse into this one exposure. The first
  ## exposure, the instance's creation, produces only the hint (C7).
  let v = x.view
  let subject = instanceSubject(v.module, v.instance)
  if x.seen:
    if v.state != x.seenState and st.rcByEvent[reModuleState].len > 0:
      var ev = LogosNSRuntimeControlModuleStateChangedEvent(
        module: v.module,
        instance: Opt.some(v.instance),
        old_state: rcState(x.seenState),
        new_state: rcState(v.state),
      )
      if v.failure.isSome:
        ev.failure = Opt.some(v.failure.get.classification)
        ev.reason = disclosedReason(v.failure.get)
      st.publishRc(reModuleState, subject, encode(ev).get(newSeq[byte]()))
    if st.rcByEvent[reExecutionState].len > 0:
      st.publishRc(
        reExecutionState,
        subject,
        encode(
          LogosNSRuntimeControlExecutionStateChangedEvent(
            execution: rcExecution(v), instance: v.instance, module: v.module
          )
        )
          .get(newSeq[byte]()),
      )
  x.seen = true
  x.seenState = v.state
  st.hintRc(InvKind.Modules, instanceSubject(v.module, v.instance, x.providerId))

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
    response.reason = disclosedReason(v.failure.get)
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
  if y.configurable:
    # [I87 C7] After the commit point; a crash before this leaves a record
    # `reapSides` removes at the next open.
    st.store.deleteSide(ConfigSide, y.id).isOkOr:
      st.diagnose("the configuration of retired " & y.id & " was not removed: " & error)
    y.config.release()
  # [SPEC RUNTIME l.3417, l.3420] A membership change, judged by the retained
  # facts of the record that left.
  st.hintRc(InvKind.Modules, instanceSubject(y.record.module, y.id, y.providerId))
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
  if st.isLoader(y):
    # [SPEC RUNTIME l.3566, l.3572; plan §2.10] The Runtime's bootstrap
    # (protected deployment input) depends on it.
    q.reply.answerError(ecNotReady, "the Runtime's bootstrap names the Module Loader")
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
    configuration = d.configuration,
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

proc servedEndpoint(st: State, y: Inst): Result[ServedEndpoint, string] =
  ## [G257; plan §2.5] The endpoint serving provider `y`'s current
  ## realization, created on first need.
  let key = y.id & "/" & y.current
  let e = st.sv.endpointOf(key)
  if e != nil:
    return ok(e)
  if not st.shared.tport.started:
    return err("the transport is not running")
  let b = y.realization.contracts
  var roots: seq[Digest]
  if b.primary.isSome:
    roots.add(b.primary.get.root)
  for i in b.interfaces:
    roots.add(i.root)
  if roots.len == 0:
    return err("the provider has no contract")
  let primary = roots[0]
  let schema = y.schemas.getOrDefault(primary)
  if schema.len == 0:
    return err("the provider's schema response is missing")
  st.sv.openEndpoint(
    key,
    y.id,
    y.providerId,
    y.record.module,
    roots,
    ContractInput(
      root: primary, schema: schema, system: y.record.module.startsWith("logos_")
    ),
  )

proc issueTicket(
    st: State, r: Route
): Result[tuple[path: string, ticket: RouteTicket], string] =
  ## [SPEC TRANSPORT §8.1.1; plan §2.4] A fresh ticket for transported route
  ## `r`, bound to its endpoint.
  let e = st.sv.endpoints.getOrDefault(r.endpoint.get(0))
  if e.isNil or e.state != esServing:
    return err("the route's endpoint no longer serves")
  let t = ?st.tickets.issueFor(r, e.callee.endpoint, e.module, st.monoNow)
  ok((path: e.ep.path, ticket: t))

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
  let l = st.ldr.inst
  if toDigest(loaderRoots().contract) == Opt.some(root) or
      (req.provider.isSome and l != nil and req.provider.get.provider == l.providerId):
    # [IMPL-DECISION G251 (S4b1-3, owner batch A 4)] No route reaches the
    # Module Loader, whatever the policy, and no decision is asked: only the
    # Runtime's binding calls it (RUNTIME l.168; CA l.357; LOADER l.80,
    # l.426). The Loader serves only a SYSTEM_SERVICE caller as well.
    q.reply.answerError(ecNotAuthorised, "not authorised")
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
    if y.providerId.len == 0 or not y.expects(root) or st.isLoader(y):
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
        selectContract(y.realization.contracts, root, st.ctx)
      else:
        Opt.none(SelectedContract)
    if sel.isNone:
      omitted = true
      continue
    checkAccessRoots(req.access, sel.get).isOkOr:
      q.reply.answerError(ecInvalidParams, error)
      return
    if sel.get.sensitive.len > 0:
      # [SPEC INTERFACE l.388; I88 D-c, deferred:tier-4b] The erasure marked
      # payloads need (l.381-386) is not built, so no route to a contract
      # that marks one is made ready and no handle is ever returned (RUNTIME
      # l.3197). The request is valid and authorized: the internal-capability
      # failure (l.3442, by analogy).
      q.reply.answerError(
        ecModule, "marked payloads are not supported on this path (INTERFACE §1.4.1)"
      )
      return
    var routeAccess = req.access
    if ans.source == psAuthority:
      # [SPEC RUNTIME l.3164-3166; RUN-0567, CAP-0051] A narrowed allow's
      # access becomes the route's.
      let narrowed = routeAccessOf(ans, st.requestBytes(rq), st.runtimeId)
      if narrowed.isSome:
        routeAccess = narrowed.get
    # [IMPL-DECISION G254; I90] The mode, once per selected provider.
    let mode = selectMode(
      st.cfg.routing,
      RouteEnds(consumerModule: x.record.module, providerModule: y.record.module),
    )
    var endpoint = Opt.none(uint64)
    if mode == rmLocalTransport:
      let ep = st.servedEndpoint(y)
      if ep.isErr:
        # [IMPL; plan §2.5] An internal processing failure: no route.
        st.diagnose(
          "no transported route to " & y.providerId & " was made: " & ep.error
        )
        if all:
          omitted = true
          continue
        q.reply.answerError(ecModule, "the provider's endpoint cannot be served")
        return
      endpoint = Opt.some(ep.get.id)
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
          mode: mode,
          consumerAttempt: x.current,
          endpoint: endpoint,
        ),
        ans,
      )
    )
  if made.len == 0:
    # [G169 interim (TF-16)] The caller holds a route allow for a provider, or
    # a `discover` allow and no provider offers the contract.
    q.reply.answerError(ecNotReady, "no selected provider is ready")
    return
  # [plan §2.4] The live answer carries each transported route's ticket; the
  # redacted one, retained for replay (G255), carries none.
  var response = LogosNSRuntimeControlEstablishRouteResponse(partial: all and omitted)
  var redacted = response
  var issueFailed = false
  for (r, ans) in made:
    st.routes[r.id] = r
    st.setValidity(r, ans)
    let rec = r.record(st.runtimeId)
    redacted.routes.add(rec)
    if r.mode == rmLocalTransport:
      let t = st.issueTicket(r)
      if t.isErr:
        st.diagnose("no ticket was issued for route " & r.id & ": " & t.error)
        issueFailed = true
      else:
        response.routes.add(rec.live(t.get.path, t.get.ticket))
        st.keepMaterial(r, t.get.path, t.get.ticket)
    else:
      response.routes.add(rec)
    st.hintRc(InvKind.Routes, recordSubject(r)) # [SPEC RUNTIME l.3417]
  if issueFailed:
    for (r, _) in made:
      st.endRoute(r, rtFailed, Opt.some(rfOther))
    q.reply.answerError(ecModule, "a route ticket cannot be issued")
    return
  let bytes = encode(response).valueOr:
    q.reply.answerError(ecModule, "the response cannot be encoded")
    return
  let kept = encode(redacted).valueOr:
    q.reply.answerError(ecModule, "the response cannot be encoded")
    return
  st.keys.retain(x.id, req.request_key, op, q.rc.request, kept)
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
      let (decision, expires) = (r.decisionId, r.expiresAt)
      r.decisionId = a.decisionId
      r.grants = a.grants
      st.shorten(r, a)
      r.reauth = raNone
      st.routeChangedRc(r, decision, expires)
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
  let (decision, expires) = (r.decisionId, r.expiresAt)
  st.setValidity(r, ans)
  st.routeChangedRc(r, decision, expires)
  if r.reauth != raNone:
    inc r.reauthTry # a re-authorization still out no longer applies
    r.reauth = raNone
    st.releaseReauthWaiters(r)
  let rec = r.record(st.runtimeId)
  var answer = rec
  if r.mode == rmLocalTransport:
    # [SPEC RUNTIME l.3481; plan §2.4] A fresh ticket; the earlier unused one
    # expires on its own [IMPL].
    let t = st.issueTicket(r).valueOr:
      st.diagnose("no ticket was issued for route " & r.id & ": " & error)
      q.reply.answerError(ecModule, "a route ticket cannot be issued")
      return
    answer = rec.live(t.path, t.ticket)
    st.keepMaterial(r, t.path, t.ticket)
  let bytes = encode(LogosNSRuntimeControlRenewRouteResponse(route: answer)).valueOr:
    q.reply.answerError(ecModule, "the response cannot be encoded")
    return
  let kept = encode(LogosNSRuntimeControlRenewRouteResponse(route: rec)).valueOr:
    q.reply.answerError(ecModule, "the response cannot be encoded")
    return
  st.keys.retain(x.id, req.request_key, op, q.rc.request, kept)
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

# Observation (step 7; DECISIONS I86) ----------------------------------------------

proc realizationStatus(x: Inst): RealizationStatus =
  ## [SPEC RUNTIME l.3530-3534] `current` while the Runtime owns a realization
  ## for the instance, one retained for cleanup within its deadline included;
  ## `unknown` while a Loader bind is unresolved (static bindings resolve
  ## inside the accepting step) or a bind, `_MODULE_init` or cleanup has
  ## outlived its deadline (G180); `absent` otherwise, after a restart too.
  let a = x.attempt
  if a != nil and a.phase == apRealize:
    # [plan §2.6] A `realize` not yet answered: whether a realization exists
    # is not known until it is.
    return rsUnknown
  if x.realization != nil and x.realization.unresolved:
    # [SPEC RUNTIME l.3533] cleanup ownership kept, its outcome unknown
    return rsUnknown
  if a != nil and a.phase in {apBind, apInit}:
    if a.phase == apBind or a.expired:
      return rsUnknown
    return rsCurrent
  if x.realization != nil or x.teardown != 0 or
      (a != nil and a.phase in {apReadyPending, apCleanup}):
    if x.state == msError and x.failure.isSome and x.failure.get.kind == fkCleanupTimeout:
      return rsUnknown
    return rsCurrent
  rsAbsent

proc followRealizations(st: State) =
  ## [IMPL-DECISION G227 (TL-08)] After every step on the Runtime thread: an
  ## instance whose realization status moved without a commit of its own in
  ## that step is committed (its revision advances, it is written and
  ## exposed), so the change is observable (RUNTIME l.3504, l.3509). A guarded
  ## request prepared before it then carries a stale revision (l.1833,
  ## l.1913).
  for x in st.instances.values:
    let now = x.realizationStatus
    if x.id in st.stepCommitted:
      x.realized = now
    elif now != x.realized:
      x.realized = now
      st.commit(x)
  st.stepCommitted.clear()

func rcRealization(
    s: RealizationStatus
): LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoice =
  LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoice(
    kind:
      case s
      of rsAbsent:
        LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind.Absent
      of rsCurrent:
        LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind.Current
      of rsUnknown:
        LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind.Unknown
  )

proc admits(st: State, a: AuthzAnswer, operation: string, s: Subject): bool {.gcsafe.} =
  ## [G161 extension, G226 interim (TF-09, TF-34)] Whether the allow of an
  ## observation without a subject admits the subject `s`.
  if not a.allows:
    return false
  case a.source
  of psAuthority:
    let exact =
      if a.request.action == aaObserveEvent:
        eventScope(a.request.operation, s, st.runtimeId)
      else:
        methodScope(operation, s, st.runtimeId)
    a.admitsScope(exact, st.runtimeId)
  of psInternal:
    st.authorizer.permits(subjectRequest(a.request, s))
  of psBootstrap, psRecovery:
    true
  of psBoundary:
    false

func providerOf(st: State, provider: string): LogosNSRuntimeModuleProviderAddress =
  LogosNSRuntimeModuleProviderAddress(
    provider: provider, runtime_instance_id: Opt.some(st.runtimeId)
  )

proc moduleRecord(st: State, y: Inst): (LogosNSRuntimeControlModuleRecord, Subject) =
  ## [SPEC RUNTIME l.3494, l.3406-3413; RUN-0627] A local instance's record:
  ## its state, execution and failure from one committed view; `provider`
  ## when it has a provider record (keyed by it); never `remote`.
  let v = y.exposed
  var r = LogosNSRuntimeControlModuleRecord(
    module: v.module,
    instance: Opt.some(v.instance),
    execution: Opt.some(rcExecution(v)),
    state: rcState(v.state),
    mode: LogosNSRuntimeControlMode(kind: LogosNSRuntimeControlModeKind.Direct),
    state_assignment: v.stateAssignment,
  )
  if y.providerId.len > 0:
    r.provider = Opt.some(st.providerOf(y.providerId))
  if v.primaryContract.isSome:
    r.primary_contract = Opt.some(schemaCommitmentOf(v.primaryContract.get))
  if v.implements.len > 0:
    var cs: seq[SchemaCommitment]
    for c in v.implements:
      cs.add(schemaCommitmentOf(c))
    r.implements = Opt.some(cs)
  if v.failure.isSome:
    r.failure = Opt.some(v.failure.get.classification)
    r.reason = disclosedReason(v.failure.get)
  (r, instanceSubject(v.module, v.instance, y.providerId))

proc listAuthority(
    st: State, q: Request, x: Inst, operation: string
): Opt[AuthzAnswer] =
  ## The list method's own decision; none when the request was parked or
  ## answered NOT_AUTHORISED.
  let d = st.decide([st.listRequest(x, operation)]).valueOr:
    return Opt.none(AuthzAnswer)
  if not d[0].allows:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return Opt.none(AuthzAnswer)
  Opt.some(d[0])

proc listLimit(q: Request, limit: Opt[uint16]): Opt[int] =
  ## [SPEC RUNTIME l.3379-3380; RUN-0954, RUN-0955]
  if limit.isNone:
    return Opt.some(DefaultListLimit)
  let n = int(limit.get)
  if n < 1 or n > MaxListLimit:
    q.reply.answerError(ecInvalidParams, "the limit is out of range")
    return Opt.none(int)
  Opt.some(n)

const BadCursor = "the cursor is not valid"
  ## [SPEC RUNTIME l.3391] one message for every refused cursor

proc answerPage(
    st: State,
    q: Request,
    snap: ListSnapshot,
    first: int,
    a: AuthzAnswer,
    retained: bool,
) =
  ## [SPEC RUNTIME l.3379-3402] One page of `snap` under the current decision
  ## `a`. A first page that continues retains its snapshot, or fails
  ## MODULE_ERROR rather than return a page without a continuation.
  let operation = $snap.kind
  let p = snap.page(
    first,
    st.limits.listResponseBytes,
    proc(s: Subject): bool =
      st.admits(a, operation, s),
  ).valueOr:
    if retained:
      st.snapshots.drop(snap)
    q.reply.answerError(ecModule, "a visible record does not fit in a response")
    return
  var next = Opt.none(string)
  if p.next.isSome:
    if not retained:
      st.snapshots.retain(snap, getMonoTime()).isOkOr:
        q.reply.answerError(ecModule, "the list snapshot cannot be retained: " & error)
        return
    next = Opt.some(st.snapshots.issue(snap, p.next.get))
  case snap.kind
  of lkModules:
    var r = LogosNSRuntimeControlListModulesResponse(next_cursor: next)
    for i in p.picked:
      r.modules.add(snap.modules[i])
    q.reply.answerEncoded(encode(r))
  of lkRoutes:
    var r = LogosNSRuntimeControlListRoutesResponse(next_cursor: next)
    for i in p.picked:
      r.routes.add(snap.routes[i])
    q.reply.answerEncoded(encode(r))

proc continueList(
    st: State,
    q: Request,
    x: Inst,
    kind: ListKind,
    filters: string,
    limit: int,
    cursor: string,
    a: AuthzAnswer,
) =
  ## [SPEC RUNTIME l.3386-3392] After the method's authority: the cursor
  ## (INVALID_PARAMS without detail, one message), readiness, the page.
  let found = st.snapshots.resolve(cursor, x.id, kind, filters, limit, getMonoTime())
  if found.isNone:
    q.reply.answerError(ecInvalidParams, BadCursor)
    return
  st.requireReady(q)
  let (snap, position) = found.get
  st.answerPage(q, snap, position, a, retained = true)

func optKey(v: Opt[string]): string =
  if v.isSome:
    "1" & v.get
  else:
    "0"

proc listModules(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §9.3 l.3350-3357, l.3372-3413] Every local instance the
  ## caller may observe, instance-keyed records first, from one snapshot.
  let req = q.rc.listModules
  let a = st.listAuthority(q, x, $rmListModules).valueOr:
    return
  let limit = listLimit(q, req.limit).valueOr:
    return
  let filters = optKey(req.module) & "\x1F" & optKey(req.instance)
  if req.cursor.isSome:
    st.continueList(q, x, lkModules, filters, limit, req.cursor.get, a)
    return
  st.requireReady(q)
  var keyed: seq[(int, string, LogosNSRuntimeControlModuleRecord, Subject)]
  for y in st.instances.values:
    # [SPEC RUNTIME l.3376; RUN-0953] Both filters match; they grant nothing.
    if req.module.isSome and y.record.module != req.module.get:
      continue
    if req.instance.isSome and y.id != req.instance.get:
      continue
    let (r, subject) = st.moduleRecord(y)
    if not st.admits(a, $rmListModules, subject):
      continue
    # [SPEC RUNTIME l.3407-3411] Instance keys before provider keys, each by
    # its identifier's bytes; every provider key names this Runtime.
    if y.providerId.len > 0:
      keyed.add((1, y.providerId, r, subject))
    else:
      keyed.add((0, y.id, r, subject))
  keyed.sort(
    proc(p, o: (int, string, LogosNSRuntimeControlModuleRecord, Subject)): int =
      result = cmp(p[0], o[0])
      if result == 0:
        result = cmp(p[1], o[1])
  )
  let snap = ListSnapshot(
    consumer: x.id, attempt: q.attempt, kind: lkModules, filters: filters, limit: limit
  )
  for (_, _, r, subject) in keyed:
    let size = encode(r).get(newSeq[byte]()).len
    snap.modules.add(r)
    snap.subjects.add(subject)
    snap.sizes.add(size)
    snap.bytes += size + subject.factBytes
  st.answerPage(q, snap, 0, a, retained = false)

proc listRoutes(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §9.3 l.3359-3365, l.3372-3413] Every route record the
  ## caller may observe, ended ones still kept included, by route id, without
  ## `invocation`.
  let req = q.rc.listRoutes
  let a = st.listAuthority(q, x, $rmListRoutes).valueOr:
    return
  let limit = listLimit(q, req.limit).valueOr:
    return
  # [IMPL; D4] The provider filter is compared after normalization: an
  # omitted Runtime id is this Runtime; another Runtime's matches nothing.
  var provider = Opt.none(string)
  var foreign = false
  if req.provider.isSome:
    let p = req.provider.get
    let runtime = p.runtime_instance_id.get(st.runtimeId)
    foreign = runtime != st.runtimeId
    provider = Opt.some(runtime & "\x1F" & p.provider)
  let filters = optKey(req.module) & "\x1F" & optKey(provider)
  if req.cursor.isSome:
    st.continueList(q, x, lkRoutes, filters, limit, req.cursor.get, a)
    return
  st.requireReady(q)
  var picked: seq[Route]
  if not foreign:
    for r in st.routes.values:
      if r.dropped:
        continue
      if req.module.isSome and r.selected.module != req.module.get:
        continue
      if req.provider.isSome and r.provider != req.provider.get.provider:
        continue
      if not st.admits(
        a,
        $rmListRoutes,
        routeSubject(r.id, r.selected.module, r.providerInstance, r.provider),
      ):
        continue
      picked.add(r)
  picked.sort(
    proc(p, o: Route): int =
      cmp(p.id, o.id)
  )
  let snap = ListSnapshot(
    consumer: x.id, attempt: q.attempt, kind: lkRoutes, filters: filters, limit: limit
  )
  for r in picked:
    let rec = r.record(st.runtimeId)
    let subject = routeSubject(r.id, r.selected.module, r.providerInstance, r.provider)
    let size = encode(rec).get(newSeq[byte]()).len
    snap.routes.add(rec)
    snap.subjects.add(subject)
    snap.sizes.add(size)
    snap.bytes += size + subject.factBytes
  st.answerPage(q, snap, 0, a, retained = false)

proc localTarget(
    st: State,
    q: Request,
    x: Inst,
    target: LogosNSRuntimeModuleInstanceAddress,
    action: AuthzAction,
    operation: string,
): Opt[Inst] =
  ## [G194 order; IMPL-DECISION G228 (TF-30 point 1)] A target instance on
  ## another Runtime is INVALID_PARAMS without detail; an unknown and a
  ## refused target are the same NOT_AUTHORISED; then readiness.
  if target.runtime_instance_id != st.runtimeId:
    q.reply.answerError(ecInvalidParams, "the target names another Runtime")
    return Opt.none(Inst)
  let id = target.module_instance_id
  let y = st.instances.getOrDefault(id)
  if y.isNil and st.authorityMode:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return Opt.none(Inst)
  let refused = st.check(
    AuthzRequest(
      action: action,
      operation: operation,
      consumer: x.id,
      target: id,
      instance: id,
      module: y.moduleOf,
    )
  )
  if refused.isSome:
    q.answerFailure(refused.get)
    return Opt.none(Inst)
  if y.isNil:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return Opt.none(Inst)
  Opt.some(y)

proc summary(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §9.3 get_execution_summary, l.3513-3535] Authorized for
  ## the target on its own; state, execution and failure from one committed
  ## view; the realization as the Runtime owns it now.
  let y = st.localTarget(q, x, q.rc.summary.target, aaObserve, $rmGetExecutionSummary).valueOr:
    return
  st.requireReady(q)
  let v = y.exposed
  type
    C = LogosNSRuntimeControlExecutionSelectionImplementationChoice
    K = LogosNSRuntimeControlExecutionSelectionImplementationChoiceKind

  let implementation =
    if st.isLoader(y):
      C(kind: K.Implementation_specific)
    else:
      case y.record.strategy
      of stDirectStatic:
        C(kind: K.Direct_static)
      of stDirectDynamic:
        C(kind: K.Direct_dynamic)
      of stHostedDynamic:
        C(kind: K.Hosted_dynamic)
  var r = LogosNSRuntimeControlGetExecutionSummaryResponse(
    target: LogosNSRuntimeModuleInstanceAddress(
      runtime_instance_id: st.runtimeId, module_instance_id: y.id
    ),
    state: rcState(v.state),
    execution: rcExecution(v),
    realization: rcRealization(y.realizationStatus),
    # [SPEC RUNTIME l.3523-3528 (RUN-0639); plan §2.7] The strategy the
    # Module Loader realizes the instance with; the Loader itself, realized
    # by the bootstrap mechanism, is `implementation-specific` (G57). No
    # selection is package-backed, so no `package` or `signer` (RUN-0637,
    # RUN-0994); no path, configuration, credential or invocation descriptor
    # (RUN-0642).
    selection:
      Opt.some(LogosNSRuntimeControlExecutionSelection(implementation: implementation)),
  )
  if v.failure.isSome:
    r.failure = Opt.some(v.failure.get.classification)
  q.reply.answerEncoded(encode(r))

proc describeProvider(st: State, q: Request, x: Inst) =
  ## [SPEC RUNTIME §2.4 l.448-458; CA l.250-257] The exact call surface
  ## validated at the provider's last bind. Order: a foreign Runtime id
  ## (INVALID_PARAMS, RUN-0091); the provider and the method's authority over
  ## it (one non-revealing NOT_AUTHORISED, RUN-0093); a `discover` decision
  ## for each exact contract (CAP-0042, CAP-0043), asked before readiness so a
  ## caller without them never learns whether it was bound (RUNTIME
  ## l.1347-1348); then readiness: never bound is NOT_READY (l.660).
  let p = q.rc.describe.provider
  if p.runtime_instance_id.isSome and p.runtime_instance_id.get != st.runtimeId:
    q.reply.answerError(ecInvalidParams, "the provider names another Runtime")
    return
  var owner: Inst
  for y in st.instances.values:
    if y.providerId.len > 0 and y.providerId == p.provider:
      owner = y
  if owner.isNil and st.authorityMode:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  st.require(
    q,
    AuthzRequest(
      action: aaObserve,
      operation: $rmDescribeProvider,
      consumer: x.id,
      target: p.provider,
      provider: p.provider,
      providerSelector: true,
      module: owner.moduleOf,
    ),
  )
  if owner.isNil:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  # Before any bind, the contracts its record expects (the surface it can be
  # bound with); after, the exact contracts of the validated surface.
  var contracts = owner.surfaceContracts
  if owner.surface.len == 0:
    contracts.setLen(0)
    if owner.record.primaryContract.isSome:
      contracts.add(owner.record.primaryContract.get)
    for c in owner.record.implements:
      contracts.add(c)
  var reqs: seq[AuthzRequest]
  for c in contracts:
    reqs.add(
      AuthzRequest(
        action: aaDiscover,
        operation: $rmDescribeProvider,
        consumer: x.id,
        target: p.provider,
        provider: p.provider,
        module: owner.record.module,
        contract: @c,
      )
    )
  let d = st.decide(reqs).valueOr:
    return
  for i, a in d:
    if not a.allows:
      q.reply.answerError(ecNotAuthorised, "not authorised")
      return
    if a.source == psAuthority:
      # [SPEC CA l.247-248] A discover allow may disclose fewer providers.
      let shown = providersOf(a, st.requestBytes(reqs[i]), st.runtimeId)
      if shown.isSome and p.provider notin shown.get:
        q.reply.answerError(ecNotAuthorised, "not authorised")
        return
  st.requireReady(q)
  if owner.surface.len == 0:
    q.reply.answerError(ecNotReady, "the provider has not been bound")
    return
  q.reply.answerEncoded(
    encode(
      LogosNSRuntimeControlDescribeProviderResponse(
        provider: st.providerOf(p.provider), surface: owner.surface
      )
    )
  )

proc permissionSettings(st: State, q: Request, x: Inst) =
  ## [IMPL-DECISION G229] The constant form RUNTIME l.2536 and l.2541 give
  ## when no permission profile is selected: every local instance has
  ## revision 1, no permission and `applied` (l.2545: it grants nothing); a
  ## replacement naming any permission names an unknown definition
  ## (INVALID_PARAMS without detail, l.2536); an empty replacement at revision
  ## 1 gives the existing state (l.2584). Nothing is stored.
  let update = q.rc.m == rmUpdatePermissionSettings
  let target = if update: q.rc.updateSettings.target else: q.rc.getSettings.target
  let y = st.localTarget(
    q, x, target, (if update: aaLifecycle else: aaObserve), $q.rc.m
  ).valueOr:
    return
  if update:
    let req = q.rc.updateSettings
    if req.permissions.len > 0:
      q.reply.answerError(
        ecInvalidParams, "no permission definition is known to this Runtime"
      )
      return
    if req.expected_revision != 1:
      q.reply.answerError(ecInvalidParams, "permission settings revision mismatch")
      return
  st.requireReady(q)
  let state = LogosNSRuntimeControlPermissionSettingsState(
    revision: 1,
    application: LogosNSRuntimeControlPermissionSettingsStateApplicationChoice(
      kind: LogosNSRuntimeControlPermissionSettingsStateApplicationChoiceKind.Applied
    ),
  )
  let address = LogosNSRuntimeModuleInstanceAddress(
    runtime_instance_id: st.runtimeId, module_instance_id: y.id
  )
  if update:
    q.reply.answerEncoded(
      encode(
        LogosNSRuntimeControlUpdatePermissionSettingsResponse(
          target: address, state: state
        )
      )
    )
  else:
    q.reply.answerEncoded(
      encode(
        LogosNSRuntimeControlGetPermissionSettingsResponse(
          target: address, state: state
        )
      )
    )

# Module configuration operations (CONFIG §5; DECISIONS I87) ------------------------
#
# [G171 interim (TF-18), extended (TF-18 point 5)] Each operation checks, in
# order: the caller's association; a target on another Runtime (INVALID_PARAMS,
# G228 extended, TF-30 point 1); the method's own authority over the exact
# target, an unknown target answered as a refused one (CFG-0057); readiness;
# then CONFIG's table rows in their order; then, for a mutation, frame size
# [G233], revision headroom [G234] and the write.

proc configTarget(
    st: State,
    q: Request,
    x: Inst,
    target: LogosNSRuntimeModuleInstanceAddress,
    action: AuthzAction,
): Opt[Inst] =
  let y = st.localTarget(q, x, target, action, $q.rc.m).valueOr:
    return Opt.none(Inst)
  let notReady = st.originReady(q)
  if notReady.isSome:
    q.reply.answerError(notReady.get.code, notReady.get.message)
    return Opt.none(Inst)
  Opt.some(y)

func noBinding(): EngineError =
  ## [SPEC CONFIG §5 l.194 (CFG-0006)] without detail
  engineError(ecInvalidParams, "the module instance has no configuration binding")

proc updateRefusal(
    y: Inst,
    expectedRevision: uint64,
    expected: LogosNSModuleConfigurationSchemaCommitment,
): Opt[EngineError] =
  ## [SPEC CONFIG §5 l.192-196] Rows 1-3, in order, without detail.
  if not y.configurable:
    return Opt.some(noBinding())
  if expectedRevision != y.config.revision:
    # [G19; CFG-0059]
    return Opt.some(
      engineError(
        ecInvalidParams, "the configuration state revision is not the current one"
      )
    )
  let c = fromRc(expected)
  if c.isErr or c.get != y.config.binding.commitment:
    # [G21, revised B2]
    return Opt.some(
      engineError(
        ecVersionMismatch, "the expected schema commitment is not the accepted one"
      )
    )
  Opt.none(EngineError)

proc commitConfig(st: State, q: Request, y: Inst, next: ConfigState) =
  ## A Runtime Control mutation: frame size [G233], headroom [G234], the
  ## write, then the commit and its event; answered with the state.
  if not next.admissible:
    q.reply.answerError(
      ecModule, "the configuration state would not fit a get_configuration response"
    )
    return
  if not y.config.canMutate:
    q.reply.answerError(ecModule, "the configuration revision is exhausted")
    return
  let refused = st.persistConfig(y, next)
  if refused.isSome:
    q.reply.answerError(refused.get.code, refused.get.message)
    return
  q.reply.answer(Reply(config: retained(y.config)))

proc configSummary(st: State, q: Request, x: Inst) =
  ## [SPEC CONFIG §5 l.176-177] Metadata only (CFG-0058); without a binding,
  ## `{state_revision: 0}` [G235 interim (TL-09)].
  let y = st.configTarget(q, x, q.rc.cfgTarget, aaObserve).valueOr:
    return
  let state = (if y.configurable: summary(y.config) else: summaryWithout())
  q.reply.answerEncoded(
    encode(
      LogosNSRuntimeControlGetConfigurationSummaryResponse(
        target: st.addressOf(y.id), state: state
      )
    )
  )

proc configRead(st: State, q: Request, x: Inst) =
  ## [SPEC CONFIG §5 l.174-175, l.178-179] `get_configuration_schema` and
  ## `get_configuration`: one snapshot, whose blobs the caller's thread
  ## encodes and drops (CFG-0061).
  let y = st.configTarget(q, x, q.rc.cfgTarget, aaObserve).valueOr:
    return
  if not y.configurable:
    q.reply.answerError(noBinding().code, noBinding().message)
    return
  q.reply.answer(Reply(config: retained(y.config)))

proc configUpdate(st: State, q: Request, x: Inst) =
  ## [SPEC CONFIG §5 l.180-213] Rows 1-3 here. A `stage` ends phase 1 with
  ## the binding and the decisions' conditions: its value is validated on
  ## the caller's thread, then committed by `configCommit` (I87 §2.7). A
  ## `discard` is one step; with nothing staged it changes nothing (l.207).
  let u = q.rc.cfgUpdate
  let y = st.configTarget(q, x, u.target, aaLifecycle).valueOr:
    return
  let refused = y.updateRefusal(u.expectedRevision, u.expectedCommitment)
  if refused.isSome:
    q.reply.answerError(refused.get.code, refused.get.message)
    return
  if u.stage:
    var r = Reply(
      config: retained(y.config), generation: st.gen, invalidations: st.invalidations
    )
    if st.op != nil:
      for a in st.op.decided.values:
        r.answers.add(a)
    q.reply.answer(r)
    return
  if y.config.staged.isNone:
    q.reply.answer(Reply(config: retained(y.config)))
    return
  st.commitConfig(q, y, y.config.discarded)

proc configCommit(st: State, q: Request) =
  ## [SPEC CONFIG §5; I87 §2.7 step 3; C31] Phase 2 of a `stage`. Phase 1's
  ## decisions are used again while they hold (same binding, no
  ## invalidation since, none past its end), else decided again; then every
  ## check runs again, so a mutation ordered in between makes this request
  ## stale. A value that is not one of the root carries its detail only to a
  ## caller that also holds `get_configuration_schema` authority over the
  ## target (CONFIG l.172, l.202).
  let x = st.caller(q).valueOr:
    q.reply.answerError(error.code, error.message)
    return
  let u = q.rc.cfgUpdate
  if st.op != nil and st.op.passes == 0 and u.gen == st.gen and
      u.invalidations == st.invalidations:
    let now = st.wallNow
    var held = true
    for a in u.answers:
      if a.validUntil.isSome and now >= a.validUntil.get:
        held = false
    if held:
      for a in u.answers:
        st.op.decided[a.request.key] = a
  let y = st.configTarget(q, x, u.target, aaLifecycle).valueOr:
    return
  let refused = y.updateRefusal(u.expectedRevision, u.expectedCommitment)
  if refused.isSome:
    q.reply.answerError(refused.get.code, refused.get.message)
    return
  if u.mismatch:
    let d = st.decide(
      @[
        AuthzRequest(
          action: aaObserve,
          operation: $rmGetConfigurationSchema,
          consumer: x.id,
          target: y.id,
          instance: y.id,
          module: y.record.module,
        )
      ]
    ).valueOr:
      return
    q.reply.answer(
      Reply(
        error: Opt.some(
          engineError(
            ecInvalidParams, "the configuration value is not one of its schema"
          )
        ),
        schemaAllowed: d[0].allows,
      )
    )
    return
  st.commitConfig(
    q, y, y.config.withStaged(u.value, u.valueRoot, pvRuntimeControlUpdate)
  )

# Live reconfiguration (CONFIG §8; I87 step 9b) -----------------------------------

func applyDeadline(st: State): Duration =
  ## [IMPL-DECISION G61, fourth deadline]
  if st.cfg.applyDeadline == default(Duration):
    DefaultApplyDeadline
  else:
    st.cfg.applyDeadline

proc applyRefusal(y: Inst, expectedRevision: uint64): Opt[EngineError] =
  ## [SPEC CONFIG §8 l.290-298 (CFG-0093, CFG-0141)] The preconditions, in the
  ## table's row order [G171 extended (TF-18 point 5)], with the absent
  ## realization binding placed after NOT_READY, so an instance that is not
  ## `ready` is NOT_READY. INVALID_PARAMS carries no detail (CFG-0143).
  ## Nothing is invoked or changed on a refusal (CFG-0142).
  template refuse(code: ErrorCode, text: string) =
    return Opt.some(engineError(code, text))

  if not y.configurable:
    return Opt.some(noBinding())
  if expectedRevision != y.config.revision:
    refuse(ecInvalidParams, "the configuration state revision is not the current one")
  if y.config.staged.isNone:
    refuse(ecInvalidParams, "no configuration value is staged")
  if not y.config.binding.live:
    # [CFG-0090] a startup-only instance
    refuse(
      ecInvalidParams, "the configuration binding does not declare live reconfiguration"
    )
  if y.state != msReady:
    refuse(ecNotReady, "the module instance is not ready")
  if y.apply != nil:
    # [CFG-0095] at most one attempt per instance
    refuse(ecNotReady, "a configuration is already being applied")
  let r = y.realization
  if r.isNil or not r.live or r.initCommitment.isNone:
    refuse(ecInvalidParams, "the realization has no live configuration binding")
  if not commitmentsAgree(
    y.config.binding.commitment, y.config.staged.get.commitment, r.initCommitment.get
  ):
    # [SPEC CONFIG l.296] Unreachable while a binding is fixed for its
    # instance (CONFIG §7); kept for the rule.
    refuse(ecVersionMismatch, "the configuration schema commitments differ")
  if not y.config.canAdvance:
    # [IMPL-DECISION G234 (S9-2)] its promotion could not advance the revision
    refuse(ecModule, "the configuration revision is exhausted")
  Opt.none(EngineError)

proc configApply(st: State, q: Request, x: Inst) =
  ## [SPEC CONFIG §8 l.276-319; LOADER §8, §11] `apply_configuration`: the
  ## staged record is snapshotted as the attempted one (l.301-302) and its
  ## `configuration_input` handed to `_MODULE_apply_configuration` on a
  ## lifecycle worker (CFG-0092), under the apply deadline. The caller is
  ## answered once the outcome is established (`applied`, `applyExpired`).
  let r = q.rc.cfgApply
  let y = st.configTarget(q, x, r.target, aaLifecycle).valueOr:
    return
  let refused = y.applyRefusal(r.expected_state_revision)
  if refused.isSome:
    q.reply.answerError(refused.get.code, refused.get.message)
    return
  let staged = y.config.staged.get
  let rz = y.realization
  if rz.mechanism == mLoader:
    # [SPEC LOADER §8; plan §2.6] Through the Loader, which runs the hook on
    # the worker that calls it.
    let refused = st.loaderRefusal(lmApplyConfiguration)
    if refused.isSome:
      q.reply.answerError(ecNotReady, refused.get)
      return
    let input = newBlob(encodeInput(staged))
    let bytes = applyBytes(y.id, rz.id, input.bytesOf).valueOr:
      drop(input)
      st.diagnose("the apply request of " & y.id & " cannot be encoded: " & error)
      q.reply.answerError(ecModule, "the configuration cannot be applied")
      return
    y.config.adopt(y.config.withAttempt(staged))
    y.apply = ApplyRun(
      reply: q.reply,
      valueRevision: staged.valueRevision,
      input: input,
      deadline: getMonoTime() + st.applyDeadline,
    )
    let id = st.callLoader(
      LoaderCall(kind: lcApply, inst: y),
      lmApplyConfiguration,
      bytes,
      instance = y.id,
      realization = Opt.some(rz.id),
    )
    y.apply.job = id
    st.applies[id] = y
    return
  let hook = st.realizer.beginApply(y.realization.id, y.id).valueOr:
    # [IMPL] The preconditions make the Loader's refusals unreachable.
    q.reply.answerError(ecModule, "the configuration cannot be applied")
    return
  y.config.adopt(y.config.withAttempt(staged))
  let input = newBlob(encodeInput(staged))
  let id = st.nextJobId()
  y.apply = ApplyRun(
    job: id,
    reply: q.reply,
    valueRevision: staged.valueRevision,
    input: input,
    deadline: getMonoTime() + st.applyDeadline,
  )
  st.applies[id] = y
  st.dispatch(
    Job(
      id: id,
      kind: jkApply,
      apply: hook.apply,
      applyContext: hook.context,
      applyData: cast[ptr UncheckedArray[uint8]](input.address),
      applyLen: input.len,
    )
  )

proc applyFailed(st: State, x: Inst, f: Failure) =
  ## [SPEC CONFIG §8 l.311-313 (CFG-0101, CFG-0148)] An application whose
  ## outcome is indeterminate, or whose success could not be recorded:
  ## `error`, no further provider work, the realization released once the
  ## hook has returned. A later cause replaces an earlier one (RUNTIME
  ## l.3757). [IMPL-DECISION G237 interim (TF-28)] During a stop the
  ## instance enters `error` too, and the stop still completes it.
  case x.state
  of msReady:
    x.state = msError
    x.failure = Opt.some(f)
    x.provider = false
    st.commit(x)
    st.releaseRealization(x)
  of msStopping:
    x.indeterminateStop = true
    x.state = msError
    x.failure = Opt.some(f)
    st.commit(x)
  of msError:
    x.failure = Opt.some(f)
    st.commit(x)
  of msUnloaded, msLoaded:
    discard

proc applyExpired(st: State, x: Inst) =
  ## [SPEC CONFIG §8 l.269-272 (CFG-0136, CFG-0137)] No valid result before
  ## the apply deadline: the outcome is indeterminate, not a rejection. The
  ## caller gets MODULE_ERROR now, nothing is promoted, the hook's result is
  ## ignored when it comes (CFG-0139), and the context stays owned until then.
  let run = x.apply
  run.expired = true
  x.config.adopt(x.config.withoutAttempt)
  run.reply.answerError(
    ecModule, "the configuration was not applied in time: its outcome is unknown"
  )
  st.applyFailed(
    x, Failure(kind: fkConfigurationIndeterminate, reason: "the apply deadline passed")
  )

proc applyDone(
  st: State, x: Inst, run: ApplyRun, outcome: Result[void, LoaderError]
) {.gcsafe.}

proc applied(st: State, job: int, res: LogosResult) =
  ## [SPEC CONFIG §8 l.305-319; LOADER §8] The hook returned. Unless its
  ## deadline already passed: success promotes the attempted record, written
  ## before it is exposed, and answers its value revision [G236 interim
  ## (TL-10)], without any lifecycle change (CFG-0103), whatever the
  ## instance's state, a stop included (CFG-0140); a valid rejection changes
  ## nothing and is MODULE_ERROR, its status not forwarded (CFG-0145,
  ## CFG-0146); an invalid result is indeterminate (CFG-0147, direct mode).
  ## Then a release waiting for the hook goes on.
  var x: Inst
  if not st.applies.pop(job, x):
    return
  let run = x.apply
  x.apply = nil
  st.applyDone(
    x, run, st.realizer.completeApply(x.id, res, established = not run.expired)
  )

proc appliedThroughLoader(st: State, job: int, reply: LoaderReply) =
  ## [SPEC LOADER §8, §11; plan §2.6] `apply_configuration` returned through
  ## the Loader: `succeeded`, `configuration-rejected`, or a failed record
  ## (the outcome is indeterminate: `configuration-indeterminate`, the more
  ## specific Runtime classification, l.3754).
  var x: Inst
  if not st.applies.pop(job, x):
    return
  let run = x.apply
  x.apply = nil
  var outcome = Result[void, LoaderError].ok()
  case reply.kind
  of lrSucceeded:
    discard
  of lrError:
    outcome.err(reply.error)
  of lrFailedRecord:
    if x.realization != nil:
      x.realization.failed = true
      x.realization.failure = reply.record.failure
    outcome.err(loaderError(lecRealizationFailed, "the outcome is indeterminate"))
  of lrFailed:
    outcome.err(loaderError(lecRealizationFailed, "the apply call failed"))
  of lrInvalid, lrActive, lrCapabilities, lrNone:
    # [plan §2.9] The Loader has failed: `x` is orphaned with the rest, and
    # the application's outcome is unknown.
    drop(run.input)
    if not run.expired:
      x.config.adopt(x.config.withoutAttempt)
      run.reply.answerError(
        ecModule, "the configuration application failed: its outcome is unknown"
      )
    st.loaderInvalid(
      if reply.kind == lrInvalid:
        reply.reason
      else:
        "apply_configuration answered " & $reply.kind
    )
    return
  st.applyDone(x, run, outcome)

proc applyDone(
    st: State, x: Inst, run: ApplyRun, outcome: Result[void, LoaderError]
) {.gcsafe.} =
  ## The hook's outcome, by either mechanism.
  drop(run.input)
  if not run.expired:
    if outcome.isOk:
      let next = x.config.promoted
      let refused =
        if next.revision == x.config.revision:
          x.config.adopt(next)
          Opt.none(EngineError)
        else:
          st.persistConfig(x, next)
      if refused.isSome:
        # [I87] The module runs a value the Runtime could not record.
        x.config.adopt(x.config.withoutAttempt)
        run.reply.answerError(ecModule, ConfigNotPersisted)
        st.applyFailed(x, Failure(kind: fkOther, reason: ConfigNotPersisted))
      else:
        run.reply.answerEncoded(
          encode(
            LogosNSRuntimeControlApplyConfigurationResponse(
              target: st.addressOf(x.id),
              state_revision: x.config.revision,
              applied_value_revision: run.valueRevision,
            )
          )
        )
    elif outcome.error.code == lecConfigurationRejected:
      x.config.adopt(x.config.withoutAttempt)
      run.reply.answerError(ecModule, "the module rejected the configuration")
    else:
      x.config.adopt(x.config.withoutAttempt)
      run.reply.answerError(
        ecModule, "the configuration application failed: its outcome is unknown"
      )
      st.applyFailed(
        x,
        Failure(
          kind: fkConfigurationIndeterminate,
          reason: "apply_configuration returned an invalid result",
        ),
      )
  if x.releasePending and x.inflight == 0 and x.rcHandlers == 0:
    st.releaseRealization(x)

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
  of rmListModules:
    st.listModules(q, x)
  of rmListRoutes:
    st.listRoutes(q, x)
  of rmGetExecutionSummary:
    st.summary(q, x)
  of rmDescribeProvider:
    st.describeProvider(q, x)
  of rmGetPermissionSettings, rmUpdatePermissionSettings:
    st.permissionSettings(q, x)
  of rmEstablishRoute:
    st.establish(q, x)
  of rmRenewRoute:
    st.renew(q, x)
  of rmCloseRoute:
    st.closeRoute(q, x)
  of rmGetConfigurationSummary:
    st.configSummary(q, x)
  of rmGetConfigurationSchema, rmGetConfiguration:
    st.configRead(q, x)
  of rmUpdateConfiguration:
    st.configUpdate(q, x)
  of rmApplyConfiguration:
    st.configApply(q, x)
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

proc reprovision(st: State, configured: seq[BootstrapInstance]): Opt[EngineError] =
  ## [SPEC CONFIG §4 l.142; G141] A retained instance's provisioned value is
  ## staged again, as `protected-provisioning`, only when its value root
  ## differs from the last one accepted for it; a value removed from the
  ## host configuration leaves that root as it was. Every one is checked
  ## (frame size [G233], revision headroom [G234]: MODULE_ERROR naming the
  ## instance) before any is staged.
  var todo: seq[(Inst, ConfigState, Blob)]
  template unwind() =
    for (_, _, blob) in todo:
      drop(blob)

  for b in configured:
    let x = st.instances.getOrDefault(b.instance)
    if x.isNil or not x.configurable or b.configuration.isNone:
      continue
    let p = b.configuration.get.provisioned
    if p.isNone or x.config.lastProvisioned == Opt.some(p.get.valueRoot):
      continue
    if not x.config.canMutate:
      unwind()
      return Opt.some(
        engineError(
          ecModule, "the configuration revision of instance " & x.id & " is exhausted"
        )
      )
    let blob = newBlob(p.get.bytes)
    var next = x.config.withStaged(blob, p.get.valueRoot, pvProtectedProvisioning)
    next.lastProvisioned = Opt.some(p.get.valueRoot)
    todo.add((x, next, blob))
    if not next.admissible:
      unwind()
      return Opt.some(
        engineError(
          ecModule,
          "the provisioned configuration of instance " & x.id &
            " would not fit a get_configuration response",
        )
      )
  var failed = Opt.none(EngineError)
  for (x, next, blob) in todo:
    if failed.isNone:
      failed = st.persistConfig(x, next)
    drop(blob)
  failed

proc reconcile(st: State, configured: seq[BootstrapInstance]): Opt[EngineError] =
  ## [IMPL-DECISION G160 interim (TF-08)] The configured instances against the
  ## retained ones, all checked before any is changed. A retired id is
  ## refused (l.3582); a retained id is the same logical instance while its
  ## declaration facts are equal (the record without `local_path` and
  ## permission reasons, `store.factBytes`), and refused, naming it, when
  ## they differ: the host names a new id. A configured state assignment that
  ## another instance, live or retired, holds is refused (l.1468, l.3587).
  for b in configured:
    if namesLoader(b.instance, b.record):
      # [IMPL-DECISION G246] Only the Runtime's bootstrap names the Loader.
      return Opt.some(
        engineError(
          ecInvalidParams,
          "instance " & b.instance & " names the reserved Module Loader",
        )
      )
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
  let unprovisioned = st.reprovision(q.bootstrap)
  if unprovisioned.isSome:
    q.reply.answerError(unprovisioned.get.code, unprovisioned.get.message)
    return
  for b in q.bootstrap:
    var x = st.instances.getOrDefault(b.instance)
    if x.isNil:
      x = st.createInst(
        b.record, b.instance, hostOrigin(), configuration = b.configuration
      ).valueOr:
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

# The Module Loader instance --------------------------------------------------------

proc loaderRecord(): ModuleRecord =
  ## [IMPL-DECISION G246] The Loader instance's record: module and static
  ## binding `logos_module_loader`, primary contract the pinned Module Loader
  ## contract (so its provider record exists, RUN-0016), no state assignment.
  ModuleRecord(
    module: LoaderModuleName,
    strategy: stDirectStatic,
    binding: LoaderBindingId,
    primaryContract: toDigest(loaderRoots().contract),
  )

proc provisionBootstrapSettings(st: State, x: Inst) =
  ## [SPEC RUNTIME l.2538, l.2543, l.2549; plan §2.6 step 3 (R9)] Where the
  ## protected construction supplies the Loader's initial permission
  ## settings, before the instance is first exposed. [IMPL-DECISION G229]
  ## Without a profile there is nothing to provision: the constant form, as
  ## every instance has. 4b-4 writes the selected profile's required list
  ## here.
  discard

proc establishLoader(st: State) =
  ## [SPEC RUNTIME l.1635-1641, l.1667, l.1685; BOOTSTRAP l.287-288; plan §2.6
  ## steps 1-4] Before the open is answered: the Loader instance, created or
  ## retained and re-established as G191 does for orchestration (a retained
  ## `requested` intent of the host is resumed; any other is replaced, with a
  ## diagnostic), authorized by the protected construction itself (no
  ## decision and no `execute` check, CA l.343 [IMPL-DECISION G253]), then
  ## realized by the bootstrap mechanism under the startup deadline.
  let rec = loaderRecord()
  var x = st.instances.getOrDefault(LoaderInstanceId)
  if x.isNil:
    x = st.createInst(rec, LoaderInstanceId, hostOrigin()).valueOr:
      st.cannotStart(error.message)
      return
  elif recordBytes(x.record) != recordBytes(rec):
    let saved = x.save
    x.record = rec
    if st.accept(x, saved, exempt = true).isSome:
      st.cannotStart(NotPersisted)
      return
  x.configured = true
  st.ldr.inst = x
  st.provisionBootstrapSettings(x)
  let saved = x.save
  if not (x.intent == inRequested and x.intentOrigin.host):
    if x.intent == inStopped:
      st.diagnose("startup re-established the Module Loader whose intent was stopped")
    elif x.intent == inRequested:
      st.diagnose(
        "startup re-established the Module Loader whose intent was requested by " &
          x.intentOrigin.instance
      )
    x.intent = inRequested
    x.intentOrigin = hostOrigin()
    x.intentRevision = x.revision + 1
  let id = st.nextJobId()
  let at = Attempt(
    id: id,
    token: "a-" & st.prefix & "-" & $id,
    inst: x,
    deadline: getMonoTime() + st.cfg.startupDeadline,
  )
  x.current = at.token
  x.state = msLoaded
  x.failure = Opt.none(Failure)
  x.enforced = Opt.none(Failure)
  x.provider = false
  let refused = st.accept(x, saved)
  if refused.isSome:
    st.cannotStart(refused.get.message)
    return
  st.beginAttempt(at)

# Transported route handles: the caller half (4b-2b; DECISIONS I90) ---------------

proc dropMaterial(st: State, route: string) =
  ## [plan §2.4, Rev R9 (c)] The consumer's material for `route`, zeroed.
  var m: Material
  if st.material.pop(route, m):
    m.burn()

proc keepMaterial(st: State, r: Route, path: string, t: RouteTicket) {.gcsafe.} =
  ## [plan §2.4] A live answer's material; it replaces an older one, whose
  ## ticket is left to expire [IMPL].
  st.dropMaterial(r.id)
  st.material[r.id] = Material(
    path: path,
    ticket: t,
    expires: min(r.monoDeadline.get(high(int64)), st.monoNow + MaxTicketLifetime),
  )

proc releaseCredit(st: State, l: Link, credit: int) =
  ## [SPEC TRANSPORT l.721-725] The I/O thread holds an Event's bytes until
  ## the owner is done with them; a closed connection's go with it.
  if credit > 0 and l.state == lkOpen and not l.closeSent:
    discard st.shared.tport.submitOwner(
      IoCommand(conn: l.conn, kind: IoCommandKind.cmdRelease, releaseBytes: credit)
    )

proc dropLinkSub(st: State, l: Link, ls: LinkSub) =
  ## The link's reference to a subscription goes, with its queued Events.
  while ls.queue.len > 0:
    st.releaseCredit(l, ls.queue.popFirst().credit)
  st.linkSubs.del(ls.sub)
  drop(subOf(ls.sub))

proc dropLinkSubs(st: State, l: Link) =
  ## [plan §2.9] Every subscription the link still holds: inactive already.
  for ls in l.subs.values:
    deactivate(subOf(ls.sub))
    st.dropLinkSub(l, ls)
  l.subs.clear()

proc endLinkSubs(st: State, l: Link, code: ErrorCode) =
  ## [SPEC INTERFACE l.1462-1465; TRANSPORT l.596-599; plan §2.7] The handle's
  ## path ended (its route, its connection or its consumer): no handler begins
  ## from now on and undelivered Events go. A Subscribe still waiting fails
  ## with `code`; an Unsubscribe still waiting gets `code` and its
  ## subscription stays, inactive, until the handle is released, which waits
  ## for a handler still running (TRN-0290).
  var failed: seq[uint64]
  for ls in l.subs.values:
    deactivate(subOf(ls.sub))
    ls.active = false
    while ls.queue.len > 0:
      st.releaseCredit(l, ls.queue.popFirst().credit)
    if ls.subscribing != nil:
      ls.subscribing.answerError(code, "the handle's path ended")
      ls.subscribing = nil
      failed.add(ls.id)
    if ls.unsubscribing != nil:
      ls.unsubscribing.answerError(code, "the handle's path ended")
      ls.unsubscribing = nil
  for id in failed:
    var ls: LinkSub
    if l.subs.pop(id, ls):
      st.dropLinkSub(l, ls)

proc closeLink(st: State, l: Link) =
  ## [Rev R5] The link's connection goes: `cmdClose`, once.
  if l.state != lkClosed and not l.closeSent:
    l.closeSent = true
    discard
      st.shared.tport.submitOwner(IoCommand(conn: l.conn, kind: IoCommandKind.cmdClose))

proc settleLink(st: State, l: Link) =
  ## [Rev R5] A link nothing keeps closes; a closed one nothing keeps goes.
  if l.idle:
    if l.state == lkClosed:
      st.dropLinkSubs(l)
      st.links.del(l.conn)
    else:
      st.closeLink(l)

proc linkObserved(st: State, l: Link) =
  ## [Rev R4; INTERFACE l.1486-1490] The handle's path ended before its route:
  ## its observer, if one is installed, gets the first cause once.
  let r = st.route(l.route)
  if r.isNil:
    return
  let i = r.handles.find(l.handle)
  if i < 0:
    return
  r.handles.del(i)
  scheduleEnd(l.handle, l.observed.get)
  st.dispatch(Job(id: st.nextJobId(), kind: jkObserveEnd, handle: l.handle))
  st.endRegsGone(r.consumer, 1)

proc linkConnectFailed(st: State, ev: IoEvent) =
  ## [plan §2.6 step 8; G259] No handle: the materialization's code, from the
  ## cause (`connectOutcome`), or the route's own if it ended meanwhile (K42).
  ## [K12, Rev R2] A peer that is not the expected identity fails the route
  ## with `transport-error`, which revokes its tickets, before the
  ## materialization is answered.
  let l = st.links.getOrDefault(ev.conn)
  if l.isNil:
    return
  st.links.del(ev.conn)
  l.state = lkClosed
  let cause = l.routeCause
  let (code, failed) = connectOutcome(ev.failCause, ev.failCode)
  let r = st.route(l.route)
  if failed and r != nil and not r.isTerminal:
    st.diagnose(
      "route " & r.id &
        ": peer identity mismatch: the peer at its endpoint is not the expected identity; the route fails with transport-error"
    )
    st.endRoute(r, rtFailed, Opt.some(rfTransportError))
  if l.connecting != nil:
    let reply = l.connecting
    l.connecting = nil
    reply.answerError(cause.get(code), "the route's handle could not be connected")

proc connectLink(st: State, q: Request, r: Route) =
  ## [plan §2.6 steps 2-6; G258] A transported handle: the route's material,
  ## taken by move, opens one connection whose Hello redeems its ticket, and
  ## the reply waits for the outcome (`linkConnected`, `linkConnectFailed`),
  ## bounded by the Hello deadline. Without material, because the ticket was
  ## used or the answer was a replay, which carries none (G255), the handle is
  ## NOT_AUTHORISED and nothing is connected: `renew_route` issues a fresh
  ## ticket (K11).
  var m: Material
  if not st.material.pop(r.id, m):
    q.reply.answerError(
      ecNotAuthorised, "the route has no unused ticket; renew_route issues one"
    )
    return
  let e = st.sv.endpoints.getOrDefault(r.endpoint.get(0))
  if e.isNil:
    m.burn()
    q.reply.answerError(ecNotReady, "the provider's endpoint is gone")
    return
  let h = cast[ptr HandleState](q.handle)
  var schema = newSeq[byte](h.blob.len)
  for i in 0 ..< h.blob.len:
    schema[i] = h.blob.data[i]
  let conn = st.shared.tport.newConnId()
  let l = Link(
    conn: conn,
    route: r.id,
    consumer: r.consumer,
    attempt: q.attempt,
    handle: q.handle,
    generation: h.generation,
    state: lkConnecting,
    connecting: q.reply,
  )
  st.links[conn] = l
  when defined(lcnTestHooks):
    if st.connectFault.isSome:
      m.burn()
      let cause = st.connectFault.get
      st.connectFault = Opt.none(ConnectFailure)
      st.linkConnectFailed(
        IoEvent(
          conn: conn,
          kind: IoEventKind.evConnectFailed,
          failCode: ecTransport,
          failCause: cause,
          failMsg: "injected by the test",
        )
      )
      return
  var cmd = IoCommand(
    conn: conn,
    kind: IoCommandKind.cmdConnect,
    path: m.path,
    expected: PeerIdentity(uid: st.shared.tport.euid),
    module: e.module,
    ticket: m.ticket,
    selected: ContractInput(root: h.root, schema: schema, system: true),
    firstId: 0,
  )
  m.burn()
  when defined(lcnTestHooks):
    if st.spoilTicket:
      st.spoilTicket = false
      cmd.ticket[0] = cmd.ticket[0] xor 0xFF
  let sent = st.shared.tport.submitOwner(cmd)
  zeroMem(addr cmd.ticket[0], cmd.ticket.len)
  if sent != SubmitResult.sbOk:
    st.links.del(conn)
    q.reply.answerError(ecNotReady, "the transport is stopping")

proc linkConnected(st: State, conn: ConnId) =
  ## [plan §2.6 step 7; RUN-0800, RUN-0802] The provider holds the session
  ## before the handle is returned. [Rev R4; K42] A route that ended while
  ## the link connected gives its cause, and the connection closes.
  let l = st.links.getOrDefault(conn)
  if l.isNil or l.state != lkConnecting:
    return
  l.state = lkOpen
  let reply = l.connecting
  l.connecting = nil
  let r = st.route(l.route)
  if l.routeCause.isSome or r.isNil or r.isTerminal:
    let code = l.routeCause.get(if r.isNil: ecNotAuthorised else: r.endCode)
    reply.answerError(code, "the route ended while its handle connected")
    st.closeLink(l)
    return
  l.held = true
  r.pins.add(Pin(handle: l.handle, attempt: l.attempt))
  reply.answer(Reply(conn: conn))

proc linkAdmits(
    st: State, l: Link, r: Route, consumer, attempt, bare: string
): Opt[EngineError] =
  ## [SPEC RUNTIME §4.1, l.1343-1347; plan §2.6 step 1] A new call through a
  ## transported handle, in the order of a direct call's admission up to the
  ## per-call decision, which the provider side makes (l.1732): the method
  ## and the route's scope, then the route's end cause or the closed
  ## connection's, then the consumer's liveness.
  template refuse(code: ErrorCode, message: string): untyped =
    return Opt.some(engineError(code, message))

  if l.isNil or r.isNil or r.consumer != consumer or l.route != r.id:
    refuse(ecNotAuthorised, "not authorised")
  st.expireIfDue(r)
  if r.selected.methodRoot(bare).isNone:
    refuse(ecMethodNotFound, "unknown method " & bare)
  if not r.allowsMethod(bare):
    refuse(ecNotAuthorised, "the method is outside the route's access")
  if r.isTerminal:
    refuse(r.endCode, "the route is " & $r.state)
  let code = l.newCallCode
  if code.isSome:
    refuse(code.get, "the handle's connection has ended")
  let x = st.instances.getOrDefault(r.consumer)
  if x.isNil or attempt != x.current or x.state notin {msLoaded, msReady} or
      st.shuttingDown:
    refuse(ecNotReady, "the consumer is not live")
  Opt.none(EngineError)

proc linkCall(st: State, q: Request) =
  ## [plan §2.6; I90] A synchronous call through a transported handle: sent on
  ## its link once admitted; the reply waits for the Response.
  let l = st.links.getOrDefault(q.conn)
  let refused =
    st.linkAdmits(l, st.route(q.route), q.origin.instance, q.attempt, q.bare)
  if refused.isSome:
    q.reply.answerError(refused.get.code, refused.get.message)
    return
  let tag = l.takeTag()
  l.calls[tag] = q.reply
  let sent = st.shared.tport.submitOwner(
    IoCommand(
      conn: l.conn,
      kind: IoCommandKind.cmdCall,
      tag: tag,
      methodName: q.bare,
      params: q.payload,
    )
  )
  if sent != SubmitResult.sbOk:
    l.calls.del(tag)
    q.reply.answerError(ecNotReady, "the transport is stopping")

proc linkSubmit(st: State, a: AsyncRec, c: ptr AsyncCall) =
  ## [plan §2.6; I90] An asynchronous call through a transported handle: the
  ## Runtime thread admits it as `linkCall` does and sends it itself; no call
  ## worker is involved. Its Response decides it (`linkResponse`); until then
  ## it holds its link (IF l.1506, l.2044-2047).
  let bare = c.methodOf
  let l = st.links.getOrDefault(c.link)
  let refused = st.linkAdmits(l, st.route(a.route), a.consumer, a.attempt, bare)
  if refused.isSome:
    st.endCall(a, notReadyAfter(c.blobOf, bare, c.paramsOf, refused.get), okResult)
    if l != nil:
      st.settleLink(l)
    return
  let tag = l.takeTag()
  retainCall(c)
  l.asyncs[tag] = a.call
  a.linkTag = tag
  let sent = st.shared.tport.submitOwner(
    IoCommand(
      conn: l.conn,
      kind: IoCommandKind.cmdCall,
      tag: tag,
      methodName: bare,
      params: c.paramsOf,
    )
  )
  if sent != SubmitResult.sbOk:
    l.asyncs.del(tag)
    dropCall(c)
    st.endCall(a, failure(ecNotReady, "the transport is stopping"), okResult)

proc linkDecide(st: State, p: pointer, r: Result[seq[byte], InvocationFailure]) =
  ## An asynchronous call's Response, or its failure: its outcome unless one
  ## was decided (a cancellation, a timeout); the link's reference goes.
  let c = asyncOf(p)
  if c.decide(r, okResult):
    let a = st.asyncCalls.getOrDefault(p)
    if a != nil:
      st.asyncTerminal(a)
  dropCall(c)

proc linkResponse(st: State, conn: ConnId, tag: uint64, o: sink CallOutcome) =
  ## [SPEC TRANSPORT §3.2, §3.4] A call's terminal outcome on a link,
  ## including the synthetic TRANSPORT_ERROR of a lost connection (l.543). A
  ## late Response after Cancel finds its call decided and is discarded.
  let l = st.links.getOrDefault(conn)
  if l.isNil:
    return
  var reply: ReplyChannel
  var p: pointer
  if l.calls.pop(tag, reply):
    if o.ok:
      reply.answer(Reply(bytes: move o.result))
    else:
      reply.answer(Reply(failure: Opt.some(o.failure)))
  elif l.asyncs.pop(tag, p):
    if o.ok:
      st.linkDecide(p, Result[seq[byte], InvocationFailure].ok(move o.result))
    else:
      st.linkDecide(p, Result[seq[byte], InvocationFailure].err(o.failure))
  st.settleLink(l)

proc linkLocalFailure(st: State, ev: IoEvent) =
  ## [plan §2.6 step 3] A Request the caller session refused: nothing was
  ## sent. [G22] A connection already gone gives the handle's code. An
  ## INVALID_PARAMS gets its validation detail from the selected contract.
  let l = st.links.getOrDefault(ev.conn)
  if l.isNil:
    st.diagnose("transport: " & ev.localMsg)
    return
  var code = ev.localCode
  if code == ecNotReady:
    code = l.routeCause.get(l.observed.get(ecTransport))
  let f = InvocationFailure(code: code, message: Opt.some(ev.localMsg))
  var reply: ReplyChannel
  var p: pointer
  if l.calls.pop(ev.localTag, reply):
    reply.answer(Reply(failure: Opt.some(f), recheck: code == ecInvalidParams))
  elif l.asyncs.pop(ev.localTag, p):
    let c = asyncOf(p)
    var g = f
    if code == ecInvalidParams:
      let sel = selectedOf(c.blobOf)
      if sel.isOk:
        let v = checkRequest(sel.get, c.methodOf, c.paramsOf)
        if v.isErr:
          g = v.error
    st.linkDecide(p, Result[seq[byte], InvocationFailure].err(g))
  else:
    st.diagnose("transport: " & ev.localMsg)
  st.settleLink(l)

proc linkClosed(st: State, ev: IoEvent) =
  ## [plan §2.6, §2.8 step 5; Rev R4] The link's connection ended. Calls still
  ## awaiting it were answered TRANSPORT_ERROR by the I/O thread first (T
  ## l.543). Unless the route ended first, the handle's first cause is the
  ## connection's (`closedCode`: TF-15, G256); the route stays as it is (R
  ## l.3475), and `renew_route` with a new materialization gives a working
  ## handle.
  let l = st.links.getOrDefault(ev.conn)
  if l.isNil:
    return
  l.state = lkClosed
  for reply in l.calls.values:
    reply.answer(Reply(failure: Opt.some(InvocationFailure(code: ecTransport))))
  l.calls.clear()
  var held: seq[pointer]
  for p in l.asyncs.values:
    held.add(p)
  l.asyncs.clear()
  for p in held:
    st.linkDecide(
      p,
      Result[seq[byte], InvocationFailure].err(
        failure(ecTransport, "the connection closed")
      ),
    )
  # [SPEC TRANSPORT l.596-599, §3.2] Its subscriptions end with it.
  st.endLinkSubs(l, l.routeCause.get(closedCode(ev.cause, ev.code)))
  if l.held and l.observe(closedCode(ev.cause, ev.code)):
    st.linkObserved(l)
  st.settleLink(l)

proc linksEnded(st: State, r: Route) {.gcsafe.} =
  ## [plan §2.8 steps 1-2; K13] The caller half first: each of the route's
  ## links learns the route's cause, which new operations report from now on,
  ## and takes it as its first cause unless the connection ended before; the
  ## route's unused material goes with its tickets.
  st.dropMaterial(r.id)
  for l in st.links.values:
    if l.route == r.id:
      l.routeCause = Opt.some(r.endCode)
      discard l.observe(r.endCode)
      st.endLinkSubs(l, r.endCode)

proc linksOfAttemptEnded(st: State, token: string) {.gcsafe.} =
  ## [SPEC INTERFACE l.2004-2006] None of the attempt's handles remains valid:
  ## their links close; a materialization still connecting is NOT_READY.
  var mine: seq[Link]
  for l in st.links.values:
    if l.attempt == token:
      mine.add(l)
  for l in mine:
    if l.connecting != nil:
      l.connecting.answerError(ecNotReady, "the consumer's realization ended")
      l.connecting = nil
    st.endLinkSubs(l, ecNotReady)
    l.held = false
    st.closeLink(l)

proc linksStopped(st: State) =
  ## [plan §2.9] The Runtime thread leaves: nothing still parked on a link
  ## waits for an event that no longer comes.
  for l in st.links.values:
    if l.connecting != nil:
      l.connecting.answerError(ecNotReady, "the Runtime stopped")
    for reply in l.calls.values:
      reply.answerError(ecNotReady, "the Runtime stopped")
    for p in l.asyncs.values:
      dropCall(asyncOf(p))
    for ls in l.subs.values:
      if ls.subscribing != nil:
        ls.subscribing.answerError(ecNotReady, "the Runtime stopped")
      if ls.unsubscribing != nil:
        ls.unsubscribing.answerError(ecNotReady, "the Runtime stopped")
    l.state = lkClosed
    st.dropLinkSubs(l)
  st.links.clear()
  for w in st.pubWaits.values:
    if w.reply != nil:
      w.reply.answerError(ecNotReady, "the Runtime stopped")
  st.pubWaits.clear()
  for m in st.material.mvalues:
    m.burn()
  st.material.clear()

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
  if r.mode == rmLocalTransport:
    st.connectLink(q, r)
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
    # no provider code runs and no invocation context is made current. [SPEC
    # RUNTIME l.432-434, l.513-514] It answers from the provider's validated
    # surface; a provider never bound has none [IMPL: NOT_READY, as
    # `describe_provider` (l.660)] (DECISIONS I88).
    let p = st.instances.getOrDefault(r.providerInstance)
    if p.isNil or p.surface.len == 0:
      q.reply.answerError(ecNotReady, "the provider has not been bound")
      return
    q.reply.answer(
      Reply(
        admission: Admission(
          introspection: true,
          capture: capture,
          schema: p.schemas.getOrDefault(r.selected.root),
        )
      )
    )
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
  let b = p.realization
  q.reply.answer(
    Reply(
      admission: Admission(
        dispatch: b.dispatch,
        free: b.free,
        context: b.context,
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
  let l = st.links.getOrDefault(linkOf(q.handle))
  if l != nil and l.observed.isSome:
    # [Rev R4] The first terminal cause, the connection's or the route's.
    q.reply.answerError(l.observed.get, "the handle's path has ended")
    return
  if r.isTerminal:
    q.reply.answerError(r.endCode, "the route is " & $r.state)
    return
  if q.handle in r.handles:
    q.reply.answerError(ecInvalidParams, "an observer is already installed")
    return
  if st.endRegs.getOrDefault(r.consumer) >= st.limits.endRegsPerConsumer or
      st.endRegsTotal >= st.limits.endRegsTotal:
    # [SPEC INTERFACE l.1483-1484; IFC-0660; I86] Nothing is installed or
    # retained, and the existing registrations stay as they are.
    q.reply.answerError(ecModule, "no local registration capacity")
    return
  installEnd(q.handle, q.handler, q.userData)
  r.handles.add(q.handle)
  st.endRegs.inc(r.consumer)
  inc st.endRegsTotal
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
      st.endRegsGone(r.consumer, 1)
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
  let l = st.links.getOrDefault(linkOf(q.handle))
  if l != nil:
    # [SPEC TRANSPORT l.596-599; TRN-0290] Its subscriptions are abandoned:
    # their Events are no longer delivered, and they go back to the releasing
    # thread, which waits for a handler still running.
    for ls in l.subs.values:
      deactivate(subOf(ls.sub))
      while ls.queue.len > 0:
        st.releaseCredit(l, ls.queue.popFirst().credit)
      st.linkSubs.del(ls.sub)
      if ls.active and l.state == lkOpen and not l.closeSent:
        discard st.shared.tport.submitOwner(
          IoCommand(
            conn: l.conn, kind: IoCommandKind.cmdAbandonSubscription, subId: ls.id
          )
        )
      if ls.subscribing != nil:
        ls.subscribing.answerError(ecNotReady, "the handle was released")
        drop(subOf(ls.sub))
        continue
      if ls.unsubscribing != nil:
        ls.unsubscribing.answerError(ecNotReady, "the handle was released")
      gone.add(ls.sub)
    l.subs.clear()
    # [Rev R5] The handle's reference goes; the connection closes once no
    # asynchronous call prepared on it awaits its Response (IF l.1506).
    l.held = false
    st.settleLink(l)
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
      if route.mode == rmLocalTransport:
        # [SPEC RUNTIME l.1236-1237; plan §2.7] Each session with an active
        # subscription to the event gets its own Event (E1).
        for conn in route.sessions:
          let s = st.sv.session(conn)
          if s != nil and not s.ended and not s.draining and s.subscribed(q.bare):
            r.targets.add(
              PublishTarget(conn: conn, route: route.id, blob: st.schemaBlob(route))
            )
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

# Transported events (4b-2c; DECISIONS I90) ------------------------------------------

proc dispatchLinkDrain(st: State, ls: LinkSub) =
  ## [plan §2.7; G178] One drain of a transported subscription on an event
  ## worker, spawned on demand; the job holds its own reference.
  ls.draining = true
  ls.served = 0
  inc st.rcBusy
  let s = st.shared
  if st.rcBusy > s.rcSpawned and s.rcSpawned < MaxEventWorkers:
    try:
      createThread(s.rcWorkers[s.rcSpawned], rcWorkerMain, s)
      inc s.rcSpawned
    except ResourceExhaustedError:
      discard # the drain waits for a busy event worker
  retain(subOf(ls.sub))
  try:
    s.rcJobs.send(RcJob(kind: rjLinkDrain, sub: ls.sub))
  except Exception:
    discard

func deliverable(ls: LinkSub): bool =
  ls.active and not ls.paused and ls.queue.len > 0

proc linkConsumer(st: State, l: Link): Inst =
  ## The consumer instance a transported Event's handler may run in, if live.
  let x = st.instances.getOrDefault(l.consumer)
  if x != nil and x.current == l.attempt and x.state in {msLoaded, msReady}: x else: nil

proc linkSubscribe(st: State, q: Request) =
  ## [SPEC INTERFACE §2.5 l.1417-1432; RUNTIME §4.4 l.1018-1024; plan §2.7] A
  ## transported handle's `subscribe`: a direct one's local checks (ownership,
  ## the event under the selected contract and the route's subscribe scope,
  ## the route's end), then the handle's code and the consumer's liveness,
  ## with no wire traffic when one fails; the provider decides the activation
  ## (G175). The reply waits for the SubscriptionResult [Rev R6] (RUN-0192).
  let l = st.links.getOrDefault(q.conn)
  let r = st.route(q.route)
  if l.isNil or r.isNil or r.consumer != q.origin.instance or l.route != r.id:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  st.expireIfDue(r)
  if r.selected.eventRoot(q.bare).isNone:
    q.reply.answerError(
      ecNotAuthorised, q.bare & " is not an event of the selected contract"
    )
    return
  if q.bare in [GrantChangedName, PolicyChangedName] and
      st.isAuthorityContract(r.selected):
    q.reply.answerError(ecNotAuthorised, "the authority's notices are protected")
    return
  if not r.allowsSubscribe(q.bare):
    q.reply.answerError(ecNotAuthorised, "the event is outside the route's access")
    return
  if r.isTerminal:
    q.reply.answerError(r.endCode, "the route is " & $r.state)
    return
  let code = l.newCallCode
  if code.isSome:
    q.reply.answerError(code.get, "the handle's connection has ended")
    return
  let x = st.instances.getOrDefault(r.consumer)
  if x.isNil or q.attempt != x.current or x.state notin {msLoaded, msReady} or
      st.shuttingDown:
    q.reply.answerError(ecNotReady, "the consumer is not live")
    return
  inc l.nextSub
  let ls = LinkSub(
    id: l.nextSub, sub: q.handle, event: q.bare, subscribing: q.reply, outId: q.outId
  )
  retain(subOf(q.handle))
  l.subs[ls.id] = ls
  st.linkSubs[q.handle] = (l.conn, ls.id)
  let sent = st.shared.tport.submitOwner(
    IoCommand(
      conn: l.conn, kind: IoCommandKind.cmdSubscribe, subId: ls.id, subEvent: q.bare
    )
  )
  if sent != SubmitResult.sbOk:
    l.subs.del(ls.id)
    st.dropLinkSub(l, ls)
    q.reply.answerError(ecNotReady, "the transport is stopping")

proc linkUnsubscribe(st: State, q: Request) =
  ## [SPEC INTERFACE §2.5 l.1446-1459; plan §2.7] An ended route answers with
  ## its code first, as on a direct handle, then an ended connection with the
  ## handle's (G22); an id that names no active subscription of the handle is
  ## INVALID_PARAMS. Otherwise no handler of it begins from now on, and the
  ## reply waits for the provider's result: on success the subscription goes
  ## back to the caller, which waits for a handler still running on another
  ## thread (not its own, for a handler that unsubscribes itself); on failure
  ## it resumes, unchanged.
  let l = st.links.getOrDefault(q.conn)
  let r = st.route(q.route)
  if l.isNil or r.isNil or r.consumer != q.origin.instance or l.route != r.id:
    q.reply.answerError(ecNotAuthorised, "not authorised")
    return
  if r.isTerminal:
    q.reply.answerError(r.endCode, "the route is " & $r.state)
    return
  let code = l.newCallCode
  if code.isSome:
    q.reply.answerError(code.get, "the handle's connection has ended")
    return
  let ls = l.subs.getOrDefault(q.subId)
  if ls.isNil or not ls.active or ls.paused:
    q.reply.answerError(
      ecInvalidParams, "no active subscription of this handle has that id"
    )
    return
  ls.paused = true
  ls.unsubscribing = q.reply
  let sent = st.shared.tport.submitOwner(
    IoCommand(conn: l.conn, kind: IoCommandKind.cmdUnsubscribe, subId: ls.id)
  )
  if sent != SubmitResult.sbOk:
    ls.paused = false
    ls.unsubscribing = nil
    q.reply.answerError(ecNotReady, "the transport is stopping")

proc linkSubscription(st: State, ev: IoEvent) =
  ## [SPEC TRANSPORT §5.1; plan §2.7, Rev R6, R7] The provider's result for a
  ## Subscribe or an Unsubscribe of a link.
  let l = st.links.getOrDefault(ev.conn)
  if l.isNil:
    return
  let ls = l.subs.getOrDefault(ev.subscriptionId)
  if ls.isNil:
    return
  let f = ev.subscriptionFailure
  if ev.subscriptionOp == MessageKind.mkSubscribe:
    let reply = ls.subscribing
    if reply.isNil:
      return
    ls.subscribing = nil
    if f.isNone and l.routeCause.isNone and l.state == lkOpen:
      # [SPEC INTERFACE l.1427-1429; Rev R7] The id is written, then the
      # subscription is active, before the subscriber returns: an Event that
      # follows on the wire is queued, not dropped.
      ls.outId[] = ls.id
      activate(subOf(ls.sub), ls.id)
      ls.active = true
      reply.answer(Reply())
      return
    l.subs.del(ls.id)
    st.dropLinkSub(l, ls)
    if f.isSome:
      reply.answerError(f.get.code, f.get.message.get("the subscription was refused"))
    else:
      reply.answerError(l.routeCause.get(ecTransport), "the handle's path ended")
  else:
    let reply = ls.unsubscribing
    if reply.isNil:
      return
    ls.unsubscribing = nil
    if f.isNone:
      deactivate(subOf(ls.sub))
      ls.active = false
      l.subs.del(ls.id)
      while ls.queue.len > 0:
        st.releaseCredit(l, ls.queue.popFirst().credit)
      st.linkSubs.del(ls.sub)
      # The link's reference goes to the caller, which drops it once no
      # handler of the subscription runs on another thread.
      reply.answer(Reply(subs: @[ls.sub]))
      return
    ls.paused = false
    reply.answerError(f.get.code, f.get.message.get("the unsubscription was refused"))
    if ls.deliverable and not ls.draining:
      st.dispatchLinkDrain(ls)

proc linkEvent(st: State, ev: sink IoEvent) =
  ## [SPEC RUNTIME l.1184; TRANSPORT §5.2, l.721-725; plan §2.7] An Event for
  ## a subscription of a link: queued, in commitment order, while the
  ## subscription is active (also while an Unsubscribe is pending, in case it
  ## fails); otherwise its bytes are released at once.
  let l = st.links.getOrDefault(ev.conn)
  if l.isNil:
    return
  let ls = l.subs.getOrDefault(ev.eventSub)
  if ls.isNil or not ls.active:
    st.releaseCredit(l, ev.credit)
    return
  ls.queue.addLast(
    QueuedEvent(name: move ev.eventName, data: move ev.eventData, credit: ev.credit)
  )
  if not ls.paused and not ls.draining:
    st.dispatchLinkDrain(ls)

proc linkNext(st: State, q: Request) =
  ## [G178; plan §2.7] An event worker draining a transported subscription
  ## releases the credit of the Event its handler finished and asks for the
  ## next. One is admitted while the subscription is active and not paused,
  ## its path open and its consumer live; the handler then counts toward the
  ## consumer until it returns (`rcHandled`). The drain ends with the queue,
  ## the subscription or its quota (`rcDrainQuota`), and starts again behind
  ## the others when Events are left.
  let key = st.linkSubs.getOrDefault(q.handle, (ConnId(0), 0'u64))
  let l = st.links.getOrDefault(key[0])
  let ls = (if l.isNil: nil else: l.subs.getOrDefault(key[1]))
  if l != nil:
    st.releaseCredit(l, q.credit)
  let x = (if l.isNil: nil else: st.linkConsumer(l))
  if ls.isNil or ls.sub != q.handle or not q.gated or not ls.deliverable or
      ls.served >= st.limits.rcDrainQuota or x.isNil or l.routeCause.isSome:
    dec st.rcBusy
    q.reply.answer(Reply(drained: true))
    if ls != nil and ls.sub == q.handle:
      ls.draining = false
      ls.served = 0
      if q.gated and ls.deliverable and x != nil and l.routeCause.isNone:
        st.dispatchLinkDrain(ls)
    return
  inc ls.served
  let e = ls.queue.popFirst()
  inc x.rcHandlers
  st.linkHandling[q.handle] = l.consumer
  q.reply.answer(Reply(admitted: true, name: e.name, bytes: e.data, credit: e.credit))

proc subscriptionResult(
    st: State, conn: ConnId, id: uint64, f: Opt[InvocationFailure]
) =
  discard st.shared.tport.submitOwner(
    IoCommand(
      conn: conn, kind: IoCommandKind.cmdSubscriptionResult, subId: id, subFailure: f
    )
  )

proc servedSubscribe(st: State, ev: IoEvent) =
  ## [plan §2.7; G175] A Subscribe a session received, after the session's
  ## own checks (the selected contract, the route's subscribe scope): its
  ## activation is decided on a call worker (`activation`), which may wait for
  ## an evaluation.
  let s = st.sv.session(ev.conn)
  if s.isNil or s.ended or s.draining:
    let r = (if s.isNil: nil else: st.route(s.route))
    st.subscriptionResult(
      ev.conn,
      ev.subscribeId,
      Opt.some(
        failure(
          (if r != nil and r.isTerminal: r.endCode else: ecNotReady),
          "the session is closing",
        )
      ),
    )
    return
  st.sendCallJob(
    CallJob(
      kind: cjActivate, conn: ev.conn, subId: ev.subscribeId, event: ev.subscribeEvent
    )
  )

proc servedActivate(st: State, q: Request) =
  ## [SPEC RUNTIME §4.4 l.1018-1024, §7.5; G175 (TF-24); plan §2.7, Rev R7,
  ## R9 (a)] The activation of a Subscribe on a session, in a direct
  ## subscription's order: the event under the selected contract and the
  ## route's subscribe scope, the route's end, its re-authorization and the
  ## subscribe-event decision (an explicit deny is NOT_AUTHORISED), then the
  ## provider and the consumer live. Recorded on the session before the
  ## answer, so the SubscriptionResult is sent only once a publication finds
  ## it.
  let s = st.sv.session(q.conn)
  let r = (if s.isNil: nil else: st.route(s.route))
  if s.isNil or r.isNil or s.ended or s.draining:
    q.reply.answerError(
      (if r != nil and r.isTerminal: r.endCode else: ecNotReady),
      "the session is closing",
    )
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
  let p = st.instances.getOrDefault(r.providerInstance)
  let c = st.instances.getOrDefault(r.consumer)
  if p.isNil or p.state != msReady or c.isNil or c.current != s.consumerAttempt or
      c.state notin {msLoaded, msReady} or st.shuttingDown or s.ended or s.draining:
    q.reply.answerError(ecNotReady, "the provider or the consumer is not live")
    return
  s.subs[q.subId] = q.bare
  q.reply.answer(Reply())

proc servedUnsubscribe(st: State, ev: IoEvent) =
  ## [SPEC TRANSPORT §5.1] The session checked the id: the subscription ends.
  let s = st.sv.session(ev.conn)
  if s != nil:
    s.subs.del(ev.subscribeId)
  st.subscriptionResult(ev.conn, ev.subscribeId, Opt.none(InvocationFailure))

proc deliverConn(st: State, q: Request) =
  ## [SPEC RUNTIME l.1229-1231, l.1275-1283; G175; plan §2.7] The admission
  ## of one Event to one transported subscriber connection, decided afresh
  ## as a direct handler invocation is (`deliver`): the session open, the
  ## route ready, both access scopes, the consumer live, the route's
  ## re-authorization and both event decisions. [K40, Rev R9 (a)] A
  ## subscriber's deny skips this Event only: the provider side cannot end
  ## one subscription of a session. A scoped publication stops on an
  ## authority end or a denied publish-event decision (NOT_AUTHORISED) and on
  ## a closed destination (NOT_READY); once admitted, its verdict is awaited
  ## by tag (E2).
  let r = st.route(q.route)
  let s = st.sv.session(q.conn)
  let name = q.bare
  template skip() =
    q.reply.answer(Reply())
    return

  template stop(code: ErrorCode, message: string) =
    q.reply.answerError(code, message)
    return

  if r.isNil:
    if q.scoped:
      stop(ecNotReady, "the invocation's destination is closed")
    skip()
  st.expireIfDue(r)
  if q.scoped:
    if r.isTerminal and r.endCode == ecNotAuthorised:
      stop(ecNotAuthorised, "the route is " & $r.state)
    if r.isTerminal or s.isNil or s.ended or q.ticket == nil or q.ticket.cancelled.load or
        q.ticket.closed.load:
      stop(ecNotReady, "the invocation's destination is closed")
    if not r.allowsPublish(name):
      stop(ecNotAuthorised, "the event is outside the route's access")
  else:
    let x = st.instances.getOrDefault(q.origin.instance)
    if x.isNil or q.attempt != x.current or x.state != msReady or
        r.providerInstance != x.id or r.isTerminal or not r.allowsPublish(name) or
        s.isNil or s.ended or s.draining or not s.subscribed(name):
      skip()
  let c = st.instances.getOrDefault(r.consumer)
  if c.isNil or c.state notin {msLoaded, msReady} or not r.allowsSubscribe(name):
    skip()
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
    skip()
  var reply = Reply(admitted: true)
  if q.scoped:
    inc st.nextPubTag
    reply.pubTag = st.nextPubTag
    st.pubWaits[reply.pubTag] = PubWait(conn: q.conn, route: r.id)
  q.reply.answer(reply)

proc scopedConn(st: State, q: Request) =
  ## [SPEC RUNTIME §7.3.1 l.1254-1273; INTERFACE l.2193-2196] A served
  ## invocation's destination, before its payload is validated, as `scoped`
  ## judges a direct one's: an event outside `publish_events` or a revoked
  ## route is NOT_AUTHORISED; `ready` says whether the session and the
  ## invocation's destination are open.
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
  let s = st.sv.session(q.conn)
  q.reply.answer(
    Reply(
      ready:
        not r.isTerminal and s != nil and not s.ended and q.ticket != nil and
        not q.ticket.cancelled.load and not q.ticket.closed.load
    )
  )

proc publishFailure(st: State, route: string, f: PublishFailure): InvocationFailure =
  ## [SPEC INTERFACE l.2189-2196; plan §2.7, Rev R17] The code of a scoped
  ## publication the session did not commit: a closed destination or
  ## connection is NOT_READY, or NOT_AUTHORISED after an authority end; an
  ## oversized Event MODULE_ERROR; the others I54's mapping.
  let r = st.route(route)
  let authorityEnd = r != nil and r.isTerminal and r.endCode == ecNotAuthorised
  case f.kind
  of peNoDestination, peClosed:
    failure(
      (if authorityEnd: ecNotAuthorised else: ecNotReady),
      "the invocation's destination is closed",
    )
  of peEnded:
    failure(ecNotAuthorised, "the route's access ended")
  else:
    InvocationFailure(code: f.code, message: Opt.some(f.msg))

proc verdict(w: PubWait): Reply =
  if w.failure.isNone:
    Reply()
  else:
    Reply(
      error: Opt.some(
        engineError(w.failure.get.code, w.failure.get.message.get("not published"))
      )
    )

proc publishResult(st: State, ev: IoEvent) =
  ## [E2; plan §2.7] The session's verdict on a scoped publication.
  let w = st.pubWaits.getOrDefault(ev.pubResultTag)
  if w.isNil or w.done:
    return
  w.done = true
  if ev.pubResultFailure.isSome:
    w.failure = Opt.some(st.publishFailure(w.route, ev.pubResultFailure.get))
  if w.reply != nil:
    w.reply.answer(w.verdict)
    st.pubWaits.del(ev.pubResultTag)

proc publishVerdict(st: State, q: Request) =
  ## [E2] The publisher waits for its verdict, which may have come already.
  let w = st.pubWaits.getOrDefault(q.pubTag)
  if w.isNil:
    q.reply.answerError(ecNotReady, "the invocation's destination is closed")
    return
  if q.abandon:
    st.pubWaits.del(q.pubTag)
    q.reply.answerError(ecNotReady, "the transport is stopping")
    return
  if w.done:
    q.reply.answer(w.verdict)
    st.pubWaits.del(q.pubTag)
    return
  w.reply = q.reply

proc publicationsClosed(st: State, conn: ConnId) =
  ## [Rev R17] A session closed with scoped publications awaiting their
  ## verdict: each is a closed destination.
  var done: seq[uint64]
  for tag, w in st.pubWaits:
    if w.conn == conn and not w.done:
      w.done = true
      w.failure = Opt.some(
        st.publishFailure(
          w.route, PublishFailure(kind: peClosed, code: ecNotReady, msg: "")
        )
      )
      if w.reply != nil:
        w.reply.answer(w.verdict)
        done.add(tag)
  for tag in done:
    st.pubWaits.del(tag)

# Runtime Control subscriptions (step 7b; DECISIONS I86) --------------------------------

proc subscribeRc(st: State, q: Request) =
  ## [SPEC INTERFACE §2.5 l.1417-1432, l.3837; G178; G175 extended (TF-24)]
  ## Association, then the name (not a Runtime Control event: NOT_AUTHORISED,
  ## TRANSPORT l.735-736 by analogy), then the event's decision without a
  ## subject (a denial is NOT_AUTHORISED; a narrowed allow filters what is
  ## delivered), then readiness (NOT_READY), then capacity (MODULE_ERROR).
  ## The id is written, then the subscription is active.
  let x = st.caller(q).valueOr:
    q.reply.answerError(error.code, error.message)
    return
  let event = rcEventOf(q.bare).valueOr:
    q.reply.answerError(ecNotAuthorised, q.bare & " is not a Runtime Control event")
    return
  st.require(
    q,
    AuthzRequest(
      action: aaObserveEvent, operation: $event, consumer: x.id, filters: true
    ),
  )
  st.requireReady(q)
  if x.rcSubs.len >= st.limits.rcSubsPerSubscriber or
      st.rcSubs.len >= st.limits.rcSubsTotal:
    q.reply.answerError(ecModule, "no Runtime Control subscription capacity")
    return
  if x.rcAttempt != q.attempt:
    x.rcAttempt = q.attempt
    x.rcNext = 0
  inc x.rcNext
  q.outId[] = x.rcNext
  let s = rcSubOf(q.handle)
  retain(s)
  activate(s, x.rcNext)
  let rec = RcRec(
    sub: q.handle,
    id: x.rcNext,
    attempt: q.attempt,
    subscriber: x.id,
    event: event,
    active: true,
  )
  st.rcSubs[q.handle] = rec
  x.rcSubs.add(rec)
  st.rcByEvent[event].add(rec)
  q.reply.answer(Reply())

proc unsubscribeRc(st: State, q: Request) =
  ## [SPEC INTERFACE §2.5 l.1446-1459, l.2004; RUNTIME l.622; G178, G225]
  ## Ownership discharge: no authority or readiness check, so it works while
  ## stopping and inside `_MODULE_destroy`. A subscription of this binding the
  ## Runtime already ended is LOGOS_OK too; an id it never gave, or one
  ## already unsubscribed, is INVALID_PARAMS and changes nothing.
  let x = st.caller(q).valueOr:
    q.reply.answerError(error.code, error.message)
    return
  var found: RcRec
  for rec in x.rcSubs:
    if rec.attempt == q.attempt and rec.id == q.subId:
      found = rec
      break
  if found.isNil:
    q.reply.answerError(ecInvalidParams, "no subscription of this binding has that id")
    return
  let p = found.sub
  retain(rcSubOf(p)) # the caller's, for its wait
  st.removeRc(found)
  q.reply.answer(Reply(subs: @[p]))

proc rcLive(st: State, rec: RcRec): Inst =
  ## The subscriber, while the subscription is active and the binding it was
  ## made through current and `loaded` or `ready`; nil otherwise.
  let x = st.instances.getOrDefault(rec.subscriber)
  if rec.active and x != nil and x.current == rec.attempt and
      x.state in {msLoaded, msReady}: x else: nil

proc endDrain(st: State, rec: RcRec) =
  ## The drain is over: the subscription goes behind the others when it has
  ## more, and a waiting one may take the slot.
  rec.running = false
  rec.scheduled = false
  dec st.rcBusy
  let left = st.rcRunning.getOrDefault(rec.subscriber) - 1
  if left > 0:
    st.rcRunning[rec.subscriber] = left
  else:
    st.rcRunning.del(rec.subscriber)
  if rec.gone:
    st.freeRc(rec)
  else:
    st.scheduleRc(rec)
  st.pumpRc()

proc fresh(st: State, e: RcEntry): bool =
  ## [G161] The decisions `e` was judged by still hold: the same binding, no
  ## invalidation since, none past its `valid_until`.
  not e.stale and e.gen == st.gen and e.invalidations == st.invalidations and
    (e.validUntil.isNone or st.wallNow < e.validUntil.get)

proc deliverable(st: State, rec: RcRec, e: RcEntry, answers: seq[AuthzAnswer]): bool =
  ## [SPEC RUNTIME l.3498, l.3419-3421] An event: current authority admits
  ## its subject. A hint: it admits at least one retained subject. A hint
  ## with none admitted that did not retain every subject may be owed for one
  ## it dropped: the subscription is lost instead of silent [G178 (D2), G225].
  if not e.hint:
    return st.rcAdmits(e.subject, answers)
  for s in e.facts:
    if st.rcAdmits(s, answers):
      return true
  if e.overflowed:
    st.loseRc(rec, "a hint it may be owed names only subjects it did not retain")
  false

proc handOver(x: Inst, e: RcEntry, reply: ReplyChannel) =
  ## Admitted: the handler counts toward its subscriber until it returns.
  inc x.rcHandlers
  reply.answer(Reply(admitted: true, name: e.blob.name, bytes: e.blob.bytes))

proc deliverRc(st: State, q: Request) =
  ## [G178; SPEC RUNTIME l.3498, l.3419] An event worker draining a
  ## subscription asks for its next entry. It is admitted when the
  ## subscription is active, its binding current and live, and current
  ## authority admits it: judged again when the decisions it was judged by may
  ## have changed (G161). An entry not admitted is dropped and the worker asks
  ## again; the drain ends with the queue, the subscription or its quota
  ## (`rcDrainQuota`).
  let rec = st.rcSubs.getOrDefault(q.handle)
  if rec.isNil:
    q.reply.answer(Reply(drained: true))
    return
  if not q.gated or not rec.active or rec.queue.len == 0 or
      rec.served >= st.limits.rcDrainQuota:
    st.endDrain(rec)
    q.reply.answer(Reply(drained: true))
    return
  inc rec.served
  let e = rec.queue.popFirst()
  if e.hint and rec.hints[e.collection] == e:
    rec.hints[e.collection] = nil
  let x = st.rcLive(rec)
  if x.isNil:
    q.reply.answer(Reply())
    return
  if st.fresh(e):
    handOver(x, e, q.reply)
    return
  let reply = q.reply
  st.decideDetached(
    rcRequests(rec, e),
    proc(answers: seq[AuthzAnswer]) =
      let y = st.rcLive(rec)
      if y != nil and st.deliverable(rec, e, answers):
        handOver(y, e, reply)
      else:
        reply.answer(Reply()),
    proc() =
      reply.answer(Reply()),
  )

proc rcHandled(st: State, p: pointer) =
  ## [G178] A handler returned: a release or destroy of its subscriber's
  ## realization waiting for it may go on. [I90] So for a transported
  ## subscription's handler (`linkNext`).
  var subscriber: string
  let rec = st.rcSubs.getOrDefault(p)
  if rec != nil:
    subscriber = rec.subscriber
  elif not st.linkHandling.pop(p, subscriber):
    return
  let x = st.instances.getOrDefault(subscriber)
  if x.isNil or x.rcHandlers == 0:
    return
  dec x.rcHandlers
  if x.rcHandlers == 0:
    if x.heldAttempt != nil:
      let (a, ctx) = (x.heldAttempt, x.heldContext)
      x.heldAttempt = nil
      x.heldContext = nil
      st.destroyContext(a, ctx)
    if x.releasePending and x.inflight == 0:
      st.releaseRealization(x)

# The Runtime thread ---------------------------------------------------------------

when defined(lcnTestHooks):
  proc transportHook(st: State, q: Request) =
    ## [4b-2 plan §4.1] `closeSessionsForTests`: the provider side closes every
    ## session of route `q.route` at once, so its handles lose their
    ## connections with no known cause. `failNextConnectForTests`: the next
    ## materialization fails with cause `q.generation` instead of connecting.
    ## `spoilNextTicketForTests`: the next materialization's Hello carries a
    ## ticket the provider never issued, which its Hello rejects.
    case q.reason
    of "close-sessions":
      let r = st.route(q.route)
      if r != nil:
        for conn in r.sessions:
          let s = st.sv.session(conn)
          if s != nil:
            st.sv.close(s)
      q.reply.answer(Reply())
    of "connect-fault":
      st.connectFault = Opt.some(ConnectFailure(q.generation))
      q.reply.answer(Reply())
    of "spoil-ticket":
      st.spoilTicket = true
      q.reply.answer(Reply())
    else:
      q.reply.answerError(ecInvalidParams, "unknown transport hook")

proc handle(st: State, q: Request) {.gcsafe.} =
  if q.kind in {
    rqCreate, rqStart, rqStop, rqReportFailure, rqRecover, rqBootstrap, rqRc,
    rqConfigCommit,
  }:
    # [IMPL] A lifecycle request first tries a write that failed (I82).
    st.retryStore()
  case q.kind
  of rqConfigure:
    discard
  of rqConfirmTermination:
    when defined(lcnTestHooks):
      st.ldr.confirm = q.reply
      st.confirmStep()
    else:
      q.reply.answerError(ecInvalidParams, "not a test build")
  of rqTransportHook:
    when defined(lcnTestHooks):
      st.transportHook(q)
    else:
      q.reply.answerError(ecInvalidParams, "not a test build")
  of rqActivate:
    st.servedActivate(q)
  of rqLinkSubscribe:
    st.linkSubscribe(q)
  of rqLinkUnsubscribe:
    st.linkUnsubscribe(q)
  of rqLinkNext:
    st.linkNext(q)
  of rqDeliverConn:
    st.deliverConn(q)
  of rqScopedConn:
    st.scopedConn(q)
  of rqPublishVerdict:
    st.publishVerdict(q)
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
    if st.busy + st.callBusy + st.evalBusy + st.renewBusy + st.rcBusy > 0:
      q.reply.answerError(ecNotReady, "module code is still running")
      return
    if st.ldr.termination.len > 0:
      # [SPEC RUNTIME l.3837, l.4079 (RUN-1072); IMPL-DECISION G249] Module
      # code of the orphaned realizations may still reach what `close` frees.
      q.reply.answerError(
        ecNotReady, "the Module Loader failed: the host process must end"
      )
      return
    if st.ldr.inst != nil and st.ldr.inst.realization != nil:
      # [SPEC RUNTIME l.4079; plan §2.10 (R3)] The Loader is released only
      # once it owns no realization: until then its code may still run.
      q.reply.answerError(ecNotReady, "module code is still running")
      return
    st.done = true
    q.reply.answer(Reply())
  of rqRcPrecheck:
    st.rcPrecheck(q)
  of rqRc:
    st.rc(q)
  of rqConfigCommit:
    st.configCommit(q)
  of rqMaterialize:
    st.materialize(q)
  of rqLinkCall:
    st.linkCall(q)
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
  of rqRcSubscribe:
    st.subscribeRc(q)
  of rqRcUnsubscribe:
    st.unsubscribeRc(q)
  of rqRcDeliver:
    st.deliverRc(q)
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

proc teardownDone(st: State, x: Inst) =
  ## [SPEC RUNTIME §10.2 step 4] The realization is gone, absence established.
  x.teardown = 0
  x.realization = nil
  if st.isLoader(x):
    st.unwire() # after the Loader's `_MODULE_destroy` returned
  st.endServices(x.services, x.id)
  freeAttemptServices(x.services)
  x.services = nil
  let a = x.attempt
  if a != nil and a.phase == apCleanup:
    st.finishAttempt(a)
  elif x.state == msStopping or x.indeterminateStop:
    # [G237 interim] A stop during which an application's outcome became
    # indeterminate completes as any stop does.
    x.indeterminateStop = false
    x.state = msUnloaded
    x.failure = x.takeEnforced()
    x.current = ""
    st.commit(x)
    st.releaseWaiters(x)

proc destroyed(st: State, job: int) =
  if job in st.teardowns:
    var x: Inst
    discard st.teardowns.pop(job, x)
    st.realizer.finishRelease(x.id)
    st.teardownDone(x)
  elif job in st.attempts:
    var a: Attempt
    discard st.attempts.pop(job, a)
    st.finishAttempt(a)

proc cleanupFailed(st: State, x: Inst, reason: string) =
  ## [SPEC RUNTIME l.611-613, §10.2 step 6] Absence could not be established:
  ## the realization stays `current` and is never used or released again;
  ## start and recovery are NOT_READY.
  x.teardown = 0
  if x.realization != nil:
    x.realization.unresolved = true
  x.indeterminateStop = false
  x.state = msError
  x.failure = Opt.some(Failure(kind: fkCleanupFailed, reason: reason))
  x.enforced = Opt.none(Failure)
  st.commit(x)
  for w in x.stopWaiters:
    w.reply.answerView(x)
  x.stopWaiters.setLen(0)
  let a = x.attempt
  if a != nil and a.phase == apCleanup:
    st.finishAttempt(a)

proc releasedThroughLoader(st: State, x: Inst, reply: LoaderReply) =
  ## [SPEC LOADER §9; plan §2.6] `release` returned. `succeeded` is absence;
  ## a failed record is a cleanup failure; an invocation failure is resolved
  ## by `get_status` (§2.9); `realization-not-found` cannot happen for a pair
  ## the engine holds (idempotent success is `succeeded`, l.591), so it is an
  ## invalid response, and the Loader has failed.
  case reply.kind
  of lrSucceeded:
    st.teardownDone(x)
  of lrFailedRecord:
    st.cleanupFailed(x, "the Module Loader could not establish absence")
  of lrFailed:
    st.diagnose(
      "the release call for " & x.id & " failed with " & $reply.invocation.code
    )
    let r = x.realization
    st.resolve(LoaderCall(kind: lcStatus, inst: x, realization: r.id))
  of lrError, lrInvalid, lrActive, lrCapabilities, lrNone:
    st.loaderInvalid(
      if reply.kind == lrInvalid:
        reply.reason
      else:
        "release answered " & $reply.kind
    )

proc realized(st: State, a: Attempt, reply: LoaderReply) =
  ## [SPEC LOADER §6, §7; RUNTIME §3.4; plan §2.6-§2.8] `realize` returned:
  ## the inbound entry is withdrawn with the phase the Loader wrote in it; an
  ## active record takes its outbound handoff and is checked as the
  ## bootstrap mechanism's is (`adoptRealization`).
  let x = a.inst
  let phase = st.side.withdrawInbound(x.id)
  a.ticket = nil
  template invalid(why: string, made: string) =
    # [plan §2.9, §2.11 step 3] The Loader has failed; what it made for this
    # attempt is orphaned with the rest, never used or released.
    if made.len > 0 and x.realization.isNil:
      x.realization = st.lostView(made)
    st.loaderInvalid(why)
    return

  case reply.kind
  of lrActive:
    let rec = reply.record
    let handoff = st.side.outbound(rec.realization)
    if rec.realization in st.ldr.issued:
      invalid("a realization id was given twice", "")
    if handoff.isNone:
      invalid("an active realization has no handoff", rec.realization)
    st.ldr.issued.incl(rec.realization)
    var contracts: ModuleBinding
    if rec.callSurface.isSome:
      contracts = acceptSurface(
        rec.callSurface.get, x.record.module, st.systemBinding(x.record)
      ).valueOr:
        invalid(
          "the call surface of " & x.id & " is not acceptable: " & error,
          rec.realization,
        )
    let h = handoff.get
    let v = RealizationView(
      mechanism: mLoader,
      id: rec.realization,
      issuer: st.ldr.token,
      provider: rec.callSurface.isSome,
      callSurface: rec.callSurface.get(@[]),
      contracts: contracts,
      declaresEvents: h.declaresEvents,
      dispatch: h.dispatch,
      free: h.free,
      asyncApi: h.asyncApi,
      context: h.context,
    )
    if a.request.configuration.isSome:
      let c = a.request.configuration.get
      v.live = c.live
      v.initCommitment = Opt.some(c.commitment)
    st.adoptRealization(a, v)
  of lrError:
    st.failAttempt(a, classify(reply.error, phase))
    st.finishAttempt(a)
  of lrFailedRecord:
    # [plan §2.5] Defensive: the engine never sends `realize` for an instance
    # whose realization it holds. The record is kept `current` and released.
    let rec = reply.record
    if rec.realization in st.ldr.issued:
      invalid("a realization id was given twice", "")
    st.ldr.issued.incl(rec.realization)
    x.realization = RealizationView(
      mechanism: mLoader,
      id: rec.realization,
      issuer: st.ldr.token,
      failed: true,
      failure: rec.failure,
    )
    st.failAttempt(
      a,
      classify(
        rec.failure.get(loaderError(lecRealizationFailed, "")), Opt.none(FailedPhase)
      ),
    )
    a.phase = apCleanup
    st.releaseRealization(x)
  of lrFailed:
    # [SPEC LOADER l.633-634; RUNTIME l.3793; plan §2.9] An invocation
    # failure is not a Loader error: `get_status` says whether anything was
    # made.
    st.diagnose(
      "the realize call for " & x.id & " failed with " & $reply.invocation.code
    )
    st.resolve(LoaderCall(kind: lcStatus, inst: x, attempt: a))
  of lrInvalid, lrSucceeded, lrCapabilities, lrNone:
    invalid(
      if reply.kind == lrInvalid:
        reply.reason
      else:
        "realize answered " & $reply.kind,
      "",
    )

proc answerConfigure(st: State) =
  ## [plan §2.6 step 6] The open is answered once the Loader is bound, or
  ## once it cannot start and nothing it started is left running.
  if st.ldr.configure.isNil:
    return
  if st.ldr.cannotStart.isNone:
    st.ldr.configure.answer(Reply())
    st.ldr.configure = nil
    return
  let l = st.ldr.inst
  if l != nil and (l.attempt != nil or l.teardown != 0 or l.realization != nil):
    if l.realization != nil and l.teardown == 0 and l.attempt.isNil:
      st.releaseRealization(l)
    return
  if st.busy > 0:
    return
  st.ldr.configure.answer(
    Reply(
      error: Opt.some(
        engineError(
          ecModule, "the Module Loader cannot start: " & st.ldr.cannotStart.get
        )
      )
    )
  )
  st.ldr.configure = nil
  st.done = true

proc loaderChecked(st: State, reply: LoaderReply) =
  ## [SPEC RUNTIME l.1645-1650 (RUN-0313-RUN-0317); plan §2.6 step 5] The
  ## binding's last check: the path is usable, `list_capabilities` succeeds
  ## and names at least one strategy.
  st.ldr.checking = false
  let l = st.ldr.inst
  let c = reply.capabilities
  if reply.kind != lrCapabilities or
      not (c.directStatic or c.directDynamic or c.hostedPlacements.len > 0):
    st.cannotStart("list_capabilities did not name a strategy")
    return
  if l.state != msReady or l.current != st.ldr.checked:
    return # the realization it checked is gone
  st.ldr.bound = true
  st.ldr.token = l.current
  st.ldr.capabilities = c

proc loaderBindingRefusal(st: State, l: Inst): string =
  ## [SPEC RUNTIME l.1645-1649] A local instance (every one here is), `ready`,
  ## whose validated call surface's primary contract is the pinned Module
  ## Loader contract. Empty when bindable.
  let r = l.realization
  if r.isNil or r.dispatch.isNil:
    return "it has no generic dispatch"
  let root = toDigest(loaderRoots().contract)
  let primary = r.contracts.primary
  if root.isNone or primary.isNone or primary.get.root != root.get:
    return "its primary contract is not the pinned Module Loader contract"
  ""

proc checkLoader(st: State) =
  ## [SPEC RUNTIME l.1641-1657; plan §2.6, §2.10] After every step: the
  ## binding follows the Loader instance (invalid once it is not `ready` or
  ## its realization changed, l.1657); a Loader `ready` and unbound is
  ## checked; the open is answered; during shutdown, a Loader that owns
  ## nothing and runs no call is released.
  let l = st.ldr.inst
  if l.isNil:
    return
  if st.ldr.bound and (l.state != msReady or l.current != st.ldr.token):
    st.ldr.bound = false
  if st.ldr.configure != nil:
    if st.ldr.cannotStart.isNone and not st.ldr.bound and not st.ldr.checking:
      if l.state == msReady and l.realization != nil:
        let refused = st.loaderBindingRefusal(l)
        if refused.len > 0:
          st.cannotStart(refused)
        else:
          st.ldr.checking = true
          st.ldr.checked = l.current
          discard st.callLoader(
            LoaderCall(kind: lcCapabilities), lmListCapabilities, capabilitiesBytes()
          )
      elif l.attempt.isNil and l.state notin {msLoaded, msReady}:
        let f = l.failure.get(Failure(kind: fkOther))
        var why = f.classification
        if f.reason.len > 0 and not f.internal:
          why.add(": " & f.reason)
        st.cannotStart(why)
    if st.ldr.bound or st.ldr.cannotStart.isSome:
      st.answerConfigure()
  elif st.shuttingDown and l.state == msReady and not st.loaderOwns() and l.inflight == 0 and
      l.teardown == 0:
    var others = false
    for y in st.instances.values:
      if not st.isLoader(y) and
          (y.state in {msLoaded, msStopping} or y.attempt != nil or y.teardown != 0):
        others = true
    if not others:
      # [plan §2.10 (R3)] A late reply left the Loader owning nothing.
      st.stopInstance(l, nil, keepIntent = true)

when defined(lcnTestHooks):
  proc confirmCall(st: State, x: Inst, realization: string) =
    ## One call of the confirmation: a release, or `get_status` without an id.
    inc st.ldr.confirming
    if realization.len > 0:
      discard st.callLoader(
        LoaderCall(kind: lcConfirm, inst: x, realization: realization),
        lmRelease,
        releaseBytes(x.id, realization),
        instance = x.id,
        realization = Opt.some(realization),
        confirming = true,
      )
    else:
      discard st.callLoader(
        LoaderCall(kind: lcConfirm, inst: x),
        lmGetStatus,
        statusBytes(x.id),
        instance = x.id,
        confirming = true,
      )

  proc confirmStep(st: State) =
    ## [D27 revised; plan §2.12] The protected mechanism's confirmation in a
    ## test process. Once no Loader call is in flight, every unresolved
    ## realization (orphaned, or left by a cleanup failure) is released
    ## through the Loader directly (an injected failure left it working),
    ## found by `get_status` when its id was never learnt; once those
    ## returned they are absent (their instances stay `error`, R l.611) and a
    ## lost Loader is released, so the engine can close.
    let q = st.ldr.confirm
    if q.isNil:
      return
    let l = st.ldr.inst
    if not st.ldr.confirmSent:
      if l.inflight > 0:
        return
      st.ldr.confirmSent = true
      var pending: seq[(Inst, string)]
      for x in st.instances.values:
        let r = x.realization
        if not st.isLoader(x) and r != nil and r.unresolved:
          pending.add((x, r.id))
      for (x, id) in pending:
        st.confirmCall(x, id)
    if st.ldr.confirming > 0:
      return
    var gone: seq[Inst]
    for x in st.instances.values:
      if not st.isLoader(x) and x.realization != nil and x.realization.unresolved:
        gone.add(x)
    for x in gone:
      st.teardownDone(x)
    st.ldr.termination.setLen(0)
    st.ldr.confirm = nil
    st.ldr.confirmSent = false
    if st.ldr.lost and l.realization != nil:
      st.releaseRealization(l)
    q.answer(Reply())

proc loaderReplied(st: State, job: int, reply: sink LoaderReply) =
  ## A Module Loader call returned; its in-flight count is given back.
  var call: LoaderCall
  if not st.ldr.calls.pop(job, call):
    return
  freeTicket(call.ticket)
  let l = st.ldr.inst
  dec l.inflight
  if st.ldr.lost and call.kind in {lcRealize, lcRelease, lcApply, lcStatus}:
    if call.kind == lcApply:
      var x: Inst
      discard st.applies.pop(job, x) # orphaned: already answered
    st.lateReply(call, reply)
  else:
    case call.kind
    of lcCapabilities:
      st.loaderChecked(reply)
    of lcRealize:
      st.realized(call.attempt, reply)
    of lcRelease:
      st.releasedThroughLoader(call.inst, reply)
    of lcApply:
      st.appliedThroughLoader(job, reply)
    of lcStatus:
      st.resolved(call, reply)
    of lcConfirm:
      when defined(lcnTestHooks):
        dec st.ldr.confirming
        if call.realization.len == 0:
          if reply.kind in {lrActive, lrFailedRecord}:
            st.confirmCall(call.inst, reply.record.realization)
        elif reply.kind != lrSucceeded:
          st.diagnose(
            "the confirmation could not release " & call.realization & ": " & $reply.kind
          )
  if l.releasePending and l.inflight == 0 and l.rcHandlers == 0:
    st.releaseRealization(l)
  when defined(lcnTestHooks):
    st.confirmStep()

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
    if c.link != 0:
      let l = st.links.getOrDefault(c.link)
      if l != nil:
        dec l.prepared
    if c.isTerminal:
      st.asyncTerminal(a)
      let l = st.links.getOrDefault(c.link)
      if l != nil:
        st.settleLink(l)
    elif c.link != 0:
      st.linkSubmit(a, c)
    else:
      st.dispatchCall(a)
  of aeLinkHold, aeLinkDrop:
    let l = st.links.getOrDefault(cast[uint64](m.extra))
    if l != nil:
      if m.event == aeLinkHold:
        inc l.prepared
      else:
        dec l.prepared
        st.settleLink(l)
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
  ## shutdown accepted by the next. The authority and Loader bindings follow
  ## every step.
  st.checkBinding()
  st.checkLoader()
  if st.shuttingDown and not st.shutdownDone:
    st.shutdownStep()
    if st.shutdownComplete():
      st.finishShutdown()
  st.checkBootstrap()

proc hello(st: State, ev: IoEvent) =
  ## [SPEC TRANSPORT §3.1, §8.1; plan §2.5] `SessionAuthority.hello`: the
  ## Hello checks against the endpoint, then [Rev R9 (e)] the state behind
  ## the binding, then the atomic redemption. The state checks should never
  ## fail, since every route end revokes its tickets first; a failure is
  ## NOT_AUTHORISED (TRANSPORT l.1013-1014) and consumes nothing.
  let e = st.sv.endpoints.getOrDefault(ev.helloEndpoint)
  if e.isNil:
    st.sv.refused(
      ev.conn,
      HelloFailure(
        code: ecNotAuthorised, reason: HelloReason.hrTicket, msg: NotAuthorisedMessage
      ),
    )
    return
  var attempt = ""
  let check: HelloCheck = proc(b: RouteBinding): Result[void, HelloFailure] =
    let r = st.route(b.route)
    var ok =
      r != nil and r.state == rtReady and r.mode == rmLocalTransport and
      r.endpoint == Opt.some(e.id)
    if ok:
      let p = st.instances.getOrDefault(r.providerInstance)
      ok = p != nil and p.state == msReady and p.id & "/" & p.current == e.realization
    if ok:
      let x = st.instances.getOrDefault(r.consumer)
      ok =
        x != nil and x.current == r.consumerAttempt and x.state in {msLoaded, msReady}
    if not ok:
      st.diagnose(
        "a Hello with a live ticket for route " & b.route &
          " failed the Runtime's state checks"
      )
      return err(
        HelloFailure(
          code: ecNotAuthorised, reason: HelloReason.hrState, msg: NotAuthorisedMessage
        )
      )
    attempt = r.consumerAttempt
    ok()
  let est = acceptHello(e.callee, st.tickets, ev.frame, st.monoNow, st.sv.limits, check)
  if est.isErr:
    st.sv.refused(ev.conn, est.error)
    return
  let r = st.route(est.get.binding.route)
  discard st.sv.admitted(ev.conn, e, est.get, attempt)
  r.sessions.add(ev.conn)

proc schemaBlob(st: State, r: Route): ptr SchemaBlob {.gcsafe.} =
  ## [plan §2.5] The provider's construction input for the route's selected
  ## contract (its validated surface), for a served invocation's checks.
  let p = st.instances.getOrDefault(r.providerInstance)
  let schema =
    if p.isNil:
      newSeq[byte]()
    else:
      p.schemas.getOrDefault(r.selected.root)
  newBlob(
    r.selected.root,
    cast[ptr UncheckedArray[uint8]](if schema.len > 0:
      unsafeAddr schema[0]
    else:
      nil),
    schema.len,
    st.shared.payloadDepth,
  )

proc servedDispatch(st: State, ev: IoEvent) =
  ## [plan §2.5] One served invocation per dispatched Request, admitted and
  ## run on a call worker as a direct asynchronous call is (`asynccall.nim`).
  let s = st.sv.session(ev.conn)
  let r = (if s.isNil: nil else: st.route(s.route))
  if s.isNil or r.isNil or s.ended:
    st.sv.respondFailure(ev.conn, ev.requestId, ecNotReady)
    return
  let c = newSessionCall(
    st.shared,
    fixed(s.consumer),
    fixed(s.consumerAttempt),
    fixed(s.route),
    s.generation,
    st.schemaBlob(r),
    ev.methodName,
    ev.params,
    ev.conn,
    ev.requestId,
  )
  let a = AsyncRec(
    call: c,
    consumer: s.consumer,
    route: s.route,
    session: true,
    conn: ev.conn,
    requestId: ev.requestId,
  )
  st.asyncCalls[c] = a
  inc r.pending
  s.addCall(ev.requestId, c)
  st.dispatchCall(a)

proc servedStop(st: State, conn: ConnId, id: uint64) =
  ## [SPEC TRANSPORT l.869-871, l.887-889] The session committed CANCELLED:
  ## the served invocation is cancelled and answers nothing more.
  let s = st.sv.session(conn)
  if s.isNil:
    return
  let c = s.calls.getOrDefault(id)
  let a = st.asyncCalls.getOrDefault(c)
  if a.isNil:
    return
  markSent(asyncOf(c))
  st.cancelInvocation(a)
  st.endCall(a, failure(ecCancelled, "the call was cancelled"), okCancelled)

proc servedClosed(st: State, conn: ConnId) =
  ## [plan §2.5] `SessionAuthority.sessionEnded`: each served invocation still
  ## listed is cancelled and answers nothing; its work leaves the in-flight
  ## count as it ends, and its worker writes its record (CA l.1193). The
  ## route stays as it is (RUNTIME l.3475).
  st.publicationsClosed(conn)
  let s = st.sv.closed(conn)
  if s.isNil:
    return
  s.subs.clear()
  for c in s.calls.values:
    let a = st.asyncCalls.getOrDefault(c)
    if a.isNil:
      continue
    markSent(asyncOf(c))
    st.cancelInvocation(a)
    st.endCall(a, failure(ecCancelled, "the session closed"), okCancelled)
  let r = st.routes.getOrDefault(s.route)
  if r != nil:
    let i = r.sessions.find(conn)
    if i >= 0:
      r.sessions.del(i)
    st.settle(r)

proc endpointFailed(st: State, id: EndpointId, why: string) =
  ## [SPEC RUNTIME l.2516; plan §2.5] The I/O thread could not serve the
  ## endpoint: every transported route to it fails with `transport-error`.
  let e = st.sv.serveFailed(id)
  if e.isNil:
    return
  st.diagnose("the endpoint of " & e.provider & " cannot be served: " & why)
  for r in st.routes.values:
    if not r.isTerminal and r.endpoint == Opt.some(id):
      st.endRoute(r, rtFailed, Opt.some(rfTransportError))

proc ioEvent(st: State, ev: sink IoEvent) =
  ## [I90; plan §2.1] An event of the transport I/O thread. Accepted
  ## connections are the provider half's; outbound ones are links (4b-2b).
  case ev.kind
  of IoEventKind.evListening:
    st.sv.listening(ev.listening)
  of IoEventKind.evServeFailed:
    st.endpointFailed(ev.failedEndpoint, ev.serveError)
  of IoEventKind.evHello:
    st.hello(ev)
  of IoEventKind.evEstablished:
    st.sv.established(ev.conn)
  of IoEventKind.evDispatch:
    st.servedDispatch(ev)
  of IoEventKind.evStop:
    st.servedStop(ev.conn, ev.stopId)
  of IoEventKind.evClosed:
    if isServed(ev.conn):
      st.servedClosed(ev.conn)
    else:
      st.linkClosed(ev)
  of IoEventKind.evConnected:
    st.linkConnected(ev.conn)
  of IoEventKind.evConnectFailed:
    st.linkConnectFailed(ev)
  of IoEventKind.evResponse:
    st.linkResponse(ev.conn, ev.tag, move ev.outcome)
  of IoEventKind.evSubscribe:
    st.servedSubscribe(ev)
  of IoEventKind.evUnsubscribe:
    st.servedUnsubscribe(ev)
  of IoEventKind.evSubscription:
    st.linkSubscription(ev)
  of IoEventKind.evEvent:
    st.linkEvent(ev)
  of IoEventKind.evPublishResult:
    st.publishResult(ev)
  of IoEventKind.evPublishFailed:
    # [SPEC RUNTIME l.1227] An ordinary publication has no result: one not
    # committed on a connection is recorded (G165: an oversized one closed
    # that connection).
    st.diagnose(
      "a publication of " & ev.pubFailEvent & " was not delivered on connection " &
        $ev.conn & ": " & ev.pubFailMsg
    )
  of IoEventKind.evLocalFailure:
    if isServed(ev.conn):
      st.diagnose("transport: " & ev.localMsg)
    else:
      st.linkLocalFailure(ev)
  else:
    discard

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
  of mkBound, mkInitialized, mkDestroyed, mkJobDone, mkCompleted, mkApplied,
      mkLoaderReply:
    dec st.busy
    st.jobClock = getMonoTime()
  of mkCallDone, mkDiagnostic, mkAsync, mkCallJobDone, mkDeferredIdle, mkEvaluated,
      mkRcHandled, mkIo:
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
    st.callClock = getMonoTime()
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
  of mkRcHandled:
    st.rcHandled(m.target)
  of mkApplied:
    st.applied(m.job, m.res)
  of mkLoaderReply:
    st.loaderReplied(m.job, move m.loaderReply)
  of mkIo:
    st.ioEvent(move m.io)
  of mkRequest, mkJobDone:
    discard
  st.settle()

proc sessionExpired(st: State, s: Session) =
  ## [Rev R1; TRN-0317; TRANSPORT l.929-930] A session ends with the decision
  ## it was bound to, also after its route was renewed: its in-flight served
  ## invocations end NOT_AUTHORISED and it terminates; the route stays as it
  ## is, and a later session gets the renewed decision.
  var calls: seq[CallRef] # ending one may drop it from the session
  for c in s.calls.values:
    calls.add(c)
  for c in calls:
    let a = st.asyncCalls.getOrDefault(c)
    if a.isNil:
      continue
    if a.ticket != nil:
      withLock a.ticket.lock:
        a.ticket.endCode = ord(ecNotAuthorised)
      a.ticket.cancelled.store(true)
    st.cancelInvocation(a)
    st.endCall(a, revokedResult(), okEnded)
  for c in st.sv.terminate(s):
    markSent(asyncOf(c))

proc checkTransported(st: State, now: MonoTime) =
  ## [Rev R17] Expired tickets are deleted (TRANSPORT l.963, l.1062); sessions
  ## past their decision terminate; draining sessions past their deadline
  ## close.
  let mono = st.monoNow
  st.tickets.sweep(mono)
  var spent: seq[string]
  for id, m in st.material:
    if mono >= m.expires:
      spent.add(id)
  for id in spent:
    st.dropMaterial(id)
  var due: seq[Session]
  for s in st.sv.sessions.values:
    if not s.ended and s.endsAt.isSome and mono >= s.endsAt.get:
      due.add(s)
  for s in due:
    st.sessionExpired(s)
  st.sv.checkDrains(now)

proc nextTransported(st: State): Opt[MonoTime] =
  ## The next of those, on the real monotonic clock.
  var t = st.sv.nextDrain()
  template monoAt(ns: int64): MonoTime =
    getMonoTime() + initDuration(nanoseconds = max(ns - st.monoNow, 0))

  var first = st.tickets.nextExpiry()
  for s in st.sv.sessions.values:
    if not s.ended and s.endsAt.isSome:
      if first.isNone or s.endsAt.get < first.get:
        first = s.endsAt
  if first.isSome:
    let d = monoAt(first.get)
    if t.isNone or d < t.get:
      t = Opt.some(d)
  t

proc checkDeadlines(st: State) =
  var now = getMonoTime()
  if st.storeFailed and now >= st.nextStoreTry:
    st.retryStore()
    now = getMonoTime()
  st.checkEvaluations(now)
  st.checkStarvation(now)
  st.snapshots.reclaim(now)
  st.expireRoutes()
  st.checkTransported(now)
  st.checkExecutions()
  for a in st.records:
    if not a.terminal and a.deadline.isSome and now >= a.deadline.get:
      # [SPEC INTERFACE l.2059-2068] TIMEOUT, without waiting for the provider.
      st.endCall(a, failure(ecTimeout, "the call timed out"), okTimeout)
  for x in st.instances.values:
    let a = x.attempt
    if a != nil and a.phase in {apBind, apInit, apRealize} and not a.expired and
        not a.cancelled and not a.failed and now >= a.deadline:
      # [SPEC RUNTIME §3.4 l.664-669] The attempt can no longer make the
      # instance ready; the module code still running is not interrupted.
      st.failAttempt(
        a, Failure(kind: fkStartupTimeout, reason: "the startup deadline passed")
      )
      a.expired = true
      if a.ticket != nil:
        a.ticket.cancelled.store(true)
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
    let run = x.apply
    if run != nil and not run.expired and now >= run.deadline:
      st.applyExpired(x)
    if (x.state == msStopping or x.indeterminateStop) and x.stopDeadline.isSome and
        now >= x.stopDeadline.get:
      # [G61, revised by A18; SPEC RUNTIME §10.2 l.3835-3838, l.3873-3874]
      # The cleanup failure is recorded; nothing still in use is released.
      # [G168 extended] It replaces an authority stop's classification.
      # [G237] So it does an indeterminate application's.
      x.indeterminateStop = false
      x.state = msError
      x.failure =
        Opt.some(Failure(kind: fkCleanupTimeout, reason: "the stop deadline passed"))
      x.enforced = Opt.none(Failure)
      st.commit(x)
      st.releaseWaiters(x)
  if st.shuttingDown and not st.shutdownDone and now >= st.shutdownDeadline:
    # [SPEC RUNTIME §10.2 step 6] The cleanup failure is recorded and shutdown
    # continues; nothing still in use is released. [plan §2.10 (R3)] A Loader
    # that still owns a realization or runs a call stays `ready` and bound.
    let keepLoader =
      st.loaderOwns() or (st.ldr.inst != nil and st.ldr.inst.inflight > 0)
    for x in st.instances.values:
      if st.isLoader(x) and x.state == msReady and keepLoader:
        continue
      if x.state in {msLoaded, msReady, msStopping} or x.indeterminateStop:
        x.indeterminateStop = false
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
    if a != nil and a.phase in {apBind, apInit, apRealize} and not a.expired and
        not a.cancelled and not a.failed:
      consider(a.deadline)
    if a != nil and a.phase == apReadyPending:
      consider(a.deadline)
      consider(
        if st.storeFailed:
          st.nextStoreTry
        else:
          getMonoTime()
      )
    if (x.state == msStopping or x.indeterminateStop) and x.stopDeadline.isSome:
      consider(x.stopDeadline.get)
    if x.apply != nil and not x.apply.expired:
      consider(x.apply.deadline)
  if st.storeFailed:
    consider(st.nextStoreTry)
  if st.shuttingDown and not st.shutdownDone:
    consider(st.shutdownDeadline)
  for a in st.asyncCalls.values:
    if not a.terminal and a.deadline.isSome:
      consider(a.deadline.get)
  let starving = st.starvationDeadline()
  if starving.isSome:
    consider(starving.get)
  for p in st.pendings.values:
    if not p.done:
      consider(p.deadline)
  let e = st.nextExpiry()
  if e.isSome:
    consider(e.get)
  let r = st.snapshots.nextReclaim()
  if r.isSome:
    consider(r.get)
  let x = st.nextExecution()
  if x.isSome:
    consider(x.get)
  let tr = st.nextTransported()
  if tr.isSome:
    consider(tr.get)
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
    # [G178] Created in an earlier process: its next exposure is a change.
    x.seen = true
    x.seenState = x.state
    st.instances[x.id] = x
    st.putFacts(x)
  for r in snap.retired:
    st.tombstones[r.instance] = r.stateAssignment
  st.createKeys = snap.createKeys

proc restoreConfigs(st: State): Opt[string] =
  ## [SPEC CONFIG §7 l.249-254; I87] Each configurable instance's state from
  ## its side record, nothing re-accepted or re-validated (CFG-0048,
  ## CFG-0131). A missing record, or one that does not hold the binding its
  ## instance record names, refuses the open, naming the instance: the
  ## instance cannot keep its identity without it (CFG-0029).
  for x in st.instances.values:
    if not x.configurable:
      continue
    let data = st.store.getSide(ConfigSide, x.id).valueOr:
      return
        Opt.some("the configuration of instance " & x.id & " cannot be read: " & error)
    if data.isNone:
      return Opt.some("the configuration of instance " & x.id & " is missing")
    x.config = configOf(data.get, x.record.configuration.get).valueOr:
      return Opt.some(
        "the configuration of instance " & x.id & " cannot be restored: " & error
      )
  Opt.none(string)

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
  let lost = st.restoreConfigs()
  if lost.isSome:
    st.releaseConfigs()
    fail(ecModule, lost.get)
  st.store.write(st.snapshot()).isOkOr:
    st.releaseConfigs()
    fail(ecModule, NotPersisted & ": " & error)
  Opt.none(EngineError)

proc ioSink(ev: sink IoEvent, ctx: pointer) {.nimcall, gcsafe, raises: [].} =
  ## [I90; plan §2.1] Every event of the transport I/O thread goes to the
  ## Runtime thread's inbox, in order; never blocks. Dropped once the port
  ## closes (`freeEngine`).
  let s = cast[ptr Shared](ctx)
  if not s.tport.closing:
    s.post(Msg(kind: mkIo, io: ev))

func endpointBase(cfg: EngineConfig): string =
  ## [C36] `runtime.endpoint_dir`, by default `<work_dir>/endpoints`.
  if cfg.endpointDir.len > 0:
    cfg.endpointDir
  else:
    cfg.workDir / "endpoints"

proc startTransportFor(s: ptr Shared, cfg: EngineConfig): Opt[EngineError] =
  ## [I90; plan §2.3] On the Runtime thread at open, when some routing rule
  ## selects local transport: the endpoint directory (made 0700 when missing,
  ## and it must pass the endpoint base check), then the I/O thread. A failure
  ## fails the open.
  let base = endpointBase(cfg)
  try:
    if not dirExists(base):
      createDir(base)
      setFilePermissions(base, {fpUserRead, fpUserWrite, fpUserExec})
  except OSError, IOError:
    return Opt.some(
      engineError(
        ecModule, "the endpoint directory cannot be made: " & getCurrentExceptionMsg()
      )
    )
  checkEndpointBase(base).isOkOr:
    return Opt.some(engineError(ecModule, "the endpoint directory: " & error.msg))
  s.tport.ensureStarted(ioSink, s).isOkOr:
    return Opt.some(engineError(ecModule, "the transport cannot start: " & error))
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
    limits: cfg.limits.effective,
    snapshots: initSnapshots(cfg.limits.effective),
    sv: newServed(s.tport, endpointBase(cfg)),
  )
  for reg in cfg.statics:
    if reg.binding == LoaderBindingId or reg.module == LoaderModuleName:
      # [IMPL-DECISION G246] Only the bootstrap mechanism holds the Loader's
      # registration, so bootstrap is non-recursive (BOOTSTRAP l.287, K4).
      first.request.reply.answer(
        Reply(
          error: Opt.some(
            engineError(
              ecInvalidParams,
              "the static registration names the reserved Module Loader",
            )
          )
        )
      )
      s.finished = true
      return
  if anyTransported(cfg.routing):
    let failed = startTransportFor(s, cfg)
    if failed.isSome:
      first.request.reply.answer(Reply(error: failed))
      s.finished = true
      return
  let failed = st.load()
  if failed.isSome:
    first.request.reply.answer(Reply(error: failed))
    s.finished = true
    return
  # [plan §2.6 step 1] The bootstrap mechanism's one registration.
  discard st.realizer.registerStatic(loaderStaticRegistration())
  st.side = s.side
  if cfg.authority.isSome:
    st.caRoot = toDigest(caRoots().contract)
  st.ldr.configure = first.request.reply
  st.establishLoader()
  st.checkLoader()
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
      st.followRealizations()
      if st.done:
        break
    if st.done:
      break
    st.checkDeadlines()
    st.followRealizations()
    st.checkBinding()
    st.checkLoader()
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
  for i in 0 ..< s.rcSpawned:
    try:
      s.rcJobs.send(RcJob(kind: rjQuit))
    except Exception:
      discard
  st.releaseConfigs()
  st.unwire()
  st.store.close()
  st.linksStopped()
  st.sv.removeAll() # [plan §2.9] what is still present
  s.finished = true

proc runtimeMain(s: ptr Shared) {.thread.} =
  markRuntimeThread()
  runtimeLoop(s)
  releaseOwner() # [I90] the transport's owner thread is leaving
  releasePerThread() # after the loop's locals are gone

# The engine handle ------------------------------------------------------------------

proc freeEngine(e: Engine) =
  ## Every thread but the transport I/O thread has left. [I90; plan §2.9] That
  ## one stops first, once no port call is inside; the sink drops what it
  ## reports after that, so nothing then sends to any channel or rings the bell.
  closeTransport(e.tport)
  freeTransportPorts(e.tport)
  e.inbox.close()
  e.jobs.close()
  e.calls.close()
  e.evals.close()
  e.renewals.close()
  e.rcJobs.close()
  e.closeSlots()
  deinitLock(e.slotLock)
  freeBell(e.bell)
  freeAuditLog(e.audit)
  freeSideTable(e.side)
  when defined(lcnTestHooks):
    freeLoaderFaultBox(e.faults)
  deallocShared(e)

proc joinAll(e: Engine) =
  ## The Runtime thread has left, and asked every worker to.
  joinThread(e.runtime)
  for i in 0 ..< e.spawned:
    joinThread(e.workers[i])
  for i in 0 ..< e.evalSpawned:
    joinThread(e.evalWorkers[i])
  if e.renewSpawned:
    joinThread(e.renewWorker)
  for i in 0 ..< e.callSpawned:
    joinThread(e.callWorkers[i])
  for i in 0 ..< e.rcSpawned:
    joinThread(e.rcWorkers[i])

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
  # [SPEC INTERFACE §4.5.1 l.3150; IF-02, I88] one setting, at least 128.
  let depth = (if cfg.maxPayloadDepth == 0: DefaultMaxDepth else: cfg.maxPayloadDepth)
  if depth < MinMaxDepth or depth > DefaultMaxDepth:
    return err(
      engineError(
        ecInvalidParams,
        "the payload depth is outside " & $MinMaxDepth & ".." & $DefaultMaxDepth,
      )
    )
  # [IMPL-DECISION G254; I90] Rules built in code get the decode checks.
  checkRules(cfg.routing, unixStream).isOkOr:
    return err(engineError(ecInvalidParams, "routing: " & error))
  var tcfg = cfg.transport.get(defaultTransportConfig())
  tcfg.maxPayloadDepth = depth # [G241] one payload depth for every decoder
  tcfg.terminationDrain = 0 # [plan §2.8] the Runtime answers before terminating
  let tp = newTransportPorts(tcfg).valueOr:
    return err(engineError(ecInvalidParams, "transport: " & error))
  let e = createShared(Shared)
  e.tport = tp
  e.audit = newAuditLog(cfg.callRecords)
  e.clock = cfg.clock
  e.payloadDepth = depth
  e.inbox.open()
  e.jobs.open()
  e.calls.open()
  e.evals.open()
  e.renewals.open()
  e.rcJobs.open()
  e.bell = newBell()
  e.side = newSideTable()
  when defined(lcnTestHooks):
    e.faults = newLoaderFaultBox()
  initLock(e.slotLock)
  try:
    createThread(e.runtime, runtimeMain, e)
  except ResourceExhaustedError:
    doAssert false, "cannot start the Runtime thread"
  let r = e.call(Request(kind: rqConfigure, config: cfg))
  if r.error.isSome:
    e.joinAll()
    e.freeEngine()
    return err(r.error.get)
  ok(e)

when defined(lcnTestHooks):
  proc closeSessionsForTests*(e: Engine, route: string): Result[void, EngineError] =
    ## A test hook (4b-2 plan §4.1): the provider side closes every session of
    ## `route` at once; the caller sees a lost connection (TF-15).
    let r =
      e.call(Request(kind: rqTransportHook, reason: "close-sessions", route: route))
    if r.error.isSome:
      return err(r.error.get)
    ok()

  proc failNextConnectForTests*(
      e: Engine, cause: ConnectFailure
  ): Result[void, EngineError] =
    ## A test hook (4b-2 plan §4.1, [Rev R15]): the next materialization of a
    ## transported route fails with `cause`, as if the I/O thread reported it
    ## (K12: one process cannot fake another uid).
    let r = e.call(
      Request(
        kind: rqTransportHook, reason: "connect-fault", generation: uint64(ord(cause))
      )
    )
    if r.error.isSome:
      return err(r.error.get)
    ok()

  proc spoilNextTicketForTests*(e: Engine): Result[void, EngineError] =
    ## A test hook (4b-2 plan §4.1): the next materialization of a transported
    ## route connects with a ticket the provider never issued, so the
    ## provider's Hello answers ProtocolError NOT_AUTHORISED (RUN-0803).
    let r = e.call(Request(kind: rqTransportHook, reason: "spoil-ticket"))
    if r.error.isSome:
      return err(r.error.get)
    ok()

when defined(lcnTestHooks):
  export sidetable.JournalEntry

  proc loaderJournalForTests*(e: Engine): seq[JournalEntry] =
    ## A test hook (plan §2.12): each request the Module Loader served, in
    ## order, as plain values. [Rev R14] 4b-6's BCP-0021-0024 evidence.
    e.side.journalOf()

  proc setLoaderFaultsForTests*(e: Engine, f: LoaderFaults): Result[void, EngineError] =
    ## A test hook (plan §2.12): faults for the next Module Loader call of
    ## each method; with `reportFailure`, the Loader reports its own failure
    ## through its realization-bound association now.
    e.faults.setFaults(f)
    if f.reportFailure:
      let v = e.call(Request(kind: rqView, instance: LoaderInstanceId))
      if v.error.isSome:
        return err(v.error.get)
      let r = e.call(
        Request(
          kind: rqReportFailure,
          instance: LoaderInstanceId,
          attempt: v.view.attempt,
          reason: "a failure injected by the test",
        )
      )
      if r.error.isSome:
        return err(r.error.get)
    ok()

  proc releaseLoaderStallForTests*(e: Engine) =
    ## A test hook: every Loader call held by `stall` replies.
    e.faults.releaseStall()

  proc clearLoaderFaultsForTests*(e: Engine) =
    ## A test hook for teardown: every armed fault is dropped and every held
    ## call replies.
    e.faults.clearFaults()

  proc stalledLoaderCallsForTests*(e: Engine): int =
    ## A test hook: how many Loader calls are held by `stall` now.
    e.faults.stalledCalls()

  proc confirmTerminationForTests*(e: Engine) =
    ## A test hook (plan §2.12): the protected mechanism's confirmation that
    ## the realizations a lost Loader owned are gone. Returns once they are
    ## absent and a lost Loader's release has begun.
    discard e.call(Request(kind: rqConfirmTermination))

proc newEngine*(cfg: EngineConfig): Engine =
  ## `openEngine` for a configuration without a store, which cannot fail.
  doAssert cfg.storeDir.isNone, "a persistent engine is opened with openEngine"
  let e = openEngine(cfg)
  doAssert e.isOk, "invalid runtime instance id or payload depth"
  e.get

template toResult(r: Reply, body: untyped): untyped =
  if r.error.isSome:
    err(r.error.get)
  else:
    ok(body)

proc create*(
    e: Engine,
    record: ModuleRecord,
    instance = "",
    origin = hostOrigin(),
    configuration = Opt.none(AcceptedConfiguration),
): Result[InstanceView, EngineError] =
  ## Creates a module instance from a resolved record; `instance` is a
  ## protected input's instance identity, or empty for a fresh one. A record
  ## that names a configuration binding comes with its accepted declaration.
  let r = e.call(
    Request(
      kind: rqCreate,
      record: record,
      instance: instance,
      origin: origin,
      configuration: configuration,
    )
  )
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
  e.joinAll()
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
