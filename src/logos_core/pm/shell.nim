## The Package Manager's shell (Tier 5 step 5-3b; DECISIONS G405, G400, G401,
## G402; docs/PACKAGE-MANAGER.md §5): the engine's commands carried out over a
## thread-confined module kit (G335). A module body calls `openShell` from its
## `initModule`, `resolveRoot` and `shellStatus` from its handlers and
## `closeShell` from its `destroyModule`. 5-3b's test module `pmtest_module`
## uses it, and 5-6a's `logos_package_manager` uses it the same way.
##
## **Everything runs on the instance's module thread**, so the shell holds GC'd
## state and takes no lock: the kit's handlers, the route handles' callbacks
## (wrapped with the kit's dispatcher, G339), the calls' completions
## (`invokeAsync`, G338) and the timers.
##
## - **`_init`** (`openShell`): the protected input `<state_dir>/.lcn-protected-input`
##   (G400) is read and decoded as `lcn.pm_input` (G399). An instance without a
##   state directory, without the file, or with a refused input fails its
##   initialization, and the failure names what is missing or the field. The
##   kept catalog (`catalog.kept`, G401) is loaded and the engine made. The
##   installation root is opened (`store.openStore`, G444, G445; POSIX): its
##   lock taken, its index read, and what a crash left deleted, the spool
##   included. Then the worker thread starts (`worker.nim`, G447) with the
##   spool directory `install/spool/` (0700). A root that cannot be opened, or
##   a worker that cannot start, fails the initialization. Nothing waits on a
##   route, so the instance is Runtime-ready at once; the engine starts in the
##   module thread's next turn, after `_MODULE_init` returned.
## - **Routes** (G402): `establish_route` to `lcn.storage_fetch` with the
##   provider record of the binding's instance (looked up with `list_modules`
##   before each establishment), the engine's fresh key, and access to
##   the three methods and the readiness event (what logosd's S9 and S10
##   grant). A route record whose materialization fails is renewed once and
##   materialized again (a replayed record has no invocation, R l.3080);
##   otherwise the establishment counts as refused. An establishment or renewal
##   failing TRANSPORT_ERROR or TIMEOUT got no response (`raLost`); any other
##   failure is a refusal.
## - **Calls** go through `invokeAsync` with the engine's deadline. A call
##   failing TRANSPORT_ERROR or NOT_READY reports the route lost; any other
##   invocation failure is the call's error.
## - **Callbacks only queue an event**: the queue is drained by a task of its
##   own, since a handle may not be released from its own callbacks (INTERFACE
##   l.1485).
## - **A resolution's next turn** (`cmContinue`, G455) gets a `callSoon` of its
##   own, not a place in the queue: a drain runs until the queue is empty, so a
##   queued continue would run in the same drain, turns back to back (Fable
##   F2). One poll later, chronos has run I/O and timers first.
## - **A cancelled operation** (its caller gave the future up) is cancelled in
##   the engine (`cancel`, Fable F3): it takes no more turns, and its future
##   ends cancelled.
## - **A replaced handle** is released once no call through it is
##   outstanding; its calls are cancelled first and end by their deadline in
##   any case. Its callbacks are ignored from then on.
## - **The log** (`cmLog`): one line each, `package-manager: <text>`, made one
##   line (`logtext.oneLine`), on stderr unless the module gives its own sink.
##   The engine's lines hold names, codes, digests and counts, never a
##   payload.
## - **The worker's jobs** (`cmWork`, G447) are queued for its thread; its
##   answers come back through the kit's `post` and are queued as events.
## - **The read-only worker** (5-6b-1; G500): a second worker thread, started after the
##   first with the installation root's path and its own trust copy, runs the page jobs
##   (`cmPage`): `list_installed_packages` pages and readers' handoffs. It is stopped and
##   joined after the first. Test builds take the page byte budget from
##   `LCN_TEST_PM_PAGE_BUDGET`, and append a line to the file `LCN_TEST_HANDOFF_JOBS`
##   names for each `wjHandoff` the first worker gets.
## - **`closeShell`** (`_MODULE_destroy`): the engine stops (no command
##   follows, G437), timers are cancelled, outstanding calls are cancelled and
##   awaited (bounded), the route set is closed, and a root operation still
##   running is answered `package-unavailable`. Then the worker is stopped and
##   joined, which deletes its spool files, and the installation root is
##   released. Only `catalog.kept` and spool files were ever written.

{.push raises: [], gcsafe.}

import std/[algorithm, deques, os, tables]
import results
import logos_sdk/confined
import logos_sdk/kit/routes
from logos_sdk/base/logtext import oneLine
from logos_sdk/cbor/encode import cmpBytes
import
  logos_sdk/contracts/generated/[lcn_NS_storage_fetch_calls, lcn_storage_fetch_root]
import ../durable
import ../runtime/protinput
import ../package/[errors, resolver]
import ./[engine, worker]
from ./listing import PageBudget

when defined(posix):
  import ./store
else:
  const
    InstallDir = "install"
    SpoolDir = "spool"

export engine

const
  KeptOverheadBytes = 8192
    ## [IMPL] the kept file's bound beyond `catalog_bytes`: its format, binding
    ## name and locator (at most 4096 bytes)
  CloseWait = 10.seconds
    ## [IMPL] how long `closeShell` waits for outstanding calls, each bounded by
    ## its own deadline

type
  ShellLog* = proc(line: string) {.nimcall, gcsafe, raises: [].}
    ## Receives each log line, without its newline.

  Link = ref object ## One route of a binding, from establishment to release.
    shell {.cursor.}: Shell
    binding: string
    route: string
    handle: RouteHandle
    sub: Subscription
    subscribed: bool
    inflight: seq[FutureBase] ## calls through `handle` not yet completed
    retiring: bool ## replaced or released: its callbacks are ignored

  Shell* = ref object
    engine: Engine
    routeSet: RouteSet
    stateDir: string
    log: ShellLog
    links: Table[string, Link] ## the current route of each binding
    retired: seq[Link] ## replaced routes, kept until the shell closes
    established: Table[string, int] ## routes established per binding
    events: Deque[Event]
    scheduled: bool ## a drain of `events` is queued or running
    timers: Table[uint64, Future[void].Raising([])]
    tasks: seq[Future[void].Raising([])] ## running calls
    replies:
      Table[uint64, Future[Result[Resolution, PackageError]].Raising([CancelledError])]
    answers: Table[uint64, Future[OperationAnswer].Raising([CancelledError])]
      ## [G449] by request
    calls: Table[uint64, FutureBase] ## [G449] outstanding calls, by the engine's call id
    nextRequest: uint64
    closed: bool
    worker: Worker ## [G447]
    reader: Worker ## [5-6b-1; G500] the read-only worker
    when defined(posix):
      store: InstalledStore ## [G444] held from `_init` to `_destroy`

  LinkStatus* = object
    binding*: BindingStatus
    established*: int ## routes established for the binding this start

  ShellStatus* = object ## What `pmtest_module`'s `status` answers.
    catalog*: Opt[Catalog]
    bindings*: seq[LinkStatus]
    pending*: int ## root operations still running

proc stderrLog*(line: string) {.nimcall, gcsafe, raises: [].} =
  ## The default sink: the module's stderr, which a Module Host inherits.
  try:
    stderr.writeLine(line)
    stderr.flushFile()
  except IOError:
    discard

proc say(s: Shell, text: string) =
  s.log("package-manager: " & oneLine(text))

# The event queue ----------------------------------------------------------------------

proc exec(s: Shell, c: var Command)

proc run(s: Shell, cmds: sink seq[Command]) =
  var cmds = cmds
  for c in cmds.mitems:
    if s.closed:
      return
    s.exec(c)

proc drain(s: Shell) =
  while s.events.len > 0 and not s.closed:
    let ev = s.events.popFirst()
    s.run(s.engine.handle(ev))

proc drainSoon(arg: pointer) {.gcsafe, raises: [].} =
  let s = cast[Shell](arg)
  s.drain()
  s.scheduled = false
  GC_unref(s)

proc post(s: Shell, ev: Event) =
  ## Queues `ev` for the engine; a task drains the queue.
  if s.closed:
    return
  s.events.addLast(ev)
  if not s.scheduled:
    s.scheduled = true
    GC_ref(s)
    callSoon(drainSoon, cast[pointer](s))

# Callbacks ------------------------------------------------------------------------------

func toReadiness(r: LcnNSStorageFetchReadiness): Readiness =
  case r.kind
  of LcnNSStorageFetchReadinessKind.Starting: rdStarting
  of LcnNSStorageFetchReadinessKind.Ready: rdReady
  of LcnNSStorageFetchReadinessKind.Offline: rdOffline

proc onRouteEnded(code: ErrorCode, user: pointer) {.nimcall, gcsafe, raises: [].} =
  let l = cast[Link](user)
  if l.retiring:
    return
  l.shell.post(routeLost(l.binding, l.route))

proc onReadinessChanged(
    e: LcnNSStorageFetchFetchReadinessChangedEvent, user: pointer
) {.nimcall, gcsafe, raises: [].} =
  let l = cast[Link](user)
  if l.retiring:
    return
  l.shell.post(readinessOf(l.binding, toReadiness(e.readiness)))

proc onSubscriptionEnded(
    sub: Subscription, reason: ErrorCode, user: pointer
) {.nimcall, gcsafe, raises: [].} =
  let l = cast[Link](user)
  if l.retiring:
    return
  l.subscribed = false
  l.shell.say(
    "the readiness subscription on " & l.binding & "'s route ended: " & $reason
  )

# Routes ---------------------------------------------------------------------------------

func fetchAccess(): LogosNSRuntimeControlRouteAccess =
  ## [G402] What logosd's S9 and S10 grant the Package Manager. A route access
  ## list is a set: strictly ascending by its bytes (RUNTIME §9.3).
  var methods = @[
    @LcnStorageFetchStatObjectRoot,
    @LcnStorageFetchReadObjectRoot,
    @LcnStorageFetchFetchReadinessRoot,
  ]
  methods.sort(
    proc(a, b: seq[byte]): int =
      cmpBytes(a, b)
  )
  LogosNSRuntimeControlRouteAccess(
    methods: Opt.some(methods),
    subscribe_events: Opt.some(@[@LcnStorageFetchReadinessChangedRoot]),
  )

func noResponse(f: InvocationFailure): bool =
  f.code in {ecTransport, ecTimeout}

func reasonOf(f: InvocationFailure): string =
  $f.code & (if f.message.isSome: ": " & f.message.get else: "")

proc releaseIfIdle(s: Shell, l: Link) =
  if l.retiring and l.inflight.len == 0 and not l.handle.isNil:
    let r = s.routeSet.release(l.handle)
    if r.isErr:
      s.say(
        "a replaced route of " & l.binding & " was not released: " & reasonOf(r.error)
      )
    l.handle = nil

proc retire(s: Shell, binding: string) =
  ## The binding's current route is replaced: its calls are cancelled, and its
  ## handle released once they ended.
  var l: Link
  if not s.links.pop(binding, l):
    return
  l.retiring = true
  for f in l.inflight:
    f.cancelSoon()
  s.retired.add(l)
  s.releaseIfIdle(l)

proc adopt(s: Shell, l: Link) =
  s.retire(l.binding)
  s.links[l.binding] = l

proc materialized(s: Shell, l: Link): Result[RouteHandle, InvocationFailure] =
  s.routeSet.materialize(
    l.route, LcnStorageFetchRoot, LcnStorageFetchSchema, onRouteEnded, cast[pointer](l)
  )

proc providerOf(
    s: Shell, instance: string
): Result[LogosNSRuntimeModuleProviderAddress, InvocationFailure] =
  ## [G402] A binding names an instance; a route names its provider record,
  ## whose id the Runtime assigns (`list_modules`, RUNTIME §9.3).
  let r = call(
    s.routeSet.binding,
    "list_modules",
    LogosNSRuntimeControlListModulesRequest(instance: Opt.some(instance)),
    LogosNSRuntimeControlListModulesResponse,
  ).valueOr:
    return err(failure(error.code, error.message))
  for m in r.modules:
    if m.instance == Opt.some(instance) and m.provider.isSome:
      return ok(m.provider.get)
  err(failure(ecNotReady, instance & " has no provider record"))

proc establishRoute(s: Shell, binding, instance, key: string) =
  let provider = s.providerOf(instance).valueOr:
    if error.noResponse:
      s.post(establishLost(binding, key))
    else:
      s.post(establishRefused(binding, key, reasonOf(error)))
    return
  let l = Link(shell: s, binding: binding)
  let opened = s.routeSet.openRoute(
    LcnStorageFetchRoot,
    LcnStorageFetchSchema,
    access = fetchAccess(),
    provider = Opt.some(provider),
    requestKey = key,
    onRouteEnd = onRouteEnded,
    user = cast[pointer](l),
  )
  # The link stays alive as long as a handle may call back into it.
  s.retired.add(l)
  if opened.isErr:
    if opened.error.noResponse:
      s.post(establishLost(binding, key))
    else:
      s.post(establishRefused(binding, key, reasonOf(opened.error)))
    return
  let routes = opened.get.routes
  if routes.len != 1:
    for o in routes:
      if o.handle.isOk:
        discard s.routeSet.release(o.handle.get)
    s.post(establishRefused(binding, key, $routes.len & " routes for one provider"))
    return
  l.route = routes[0].record.route
  var h = routes[0].handle
  if h.isErr:
    # [SPEC RUNTIME l.3080] A replayed record has no invocation: renew it, then
    # materialize it.
    let renewedRecord = s.routeSet.renewRoute(l.route)
    if renewedRecord.isOk:
      h = s.materialized(l)
    if h.isErr:
      discard s.routeSet.closeRoute(l.route)
      s.post(establishRefused(binding, key, reasonOf(h.error)))
      return
  l.handle = h.get
  s.retired.setLen(s.retired.len - 1)
  s.adopt(l)
  s.established.mgetOrPut(binding, 0) += 1
  s.post(established(binding, key, l.route))

proc renewLink(s: Shell, binding, route, key: string) =
  let r = s.routeSet.renewRoute(route, key)
  if r.isErr:
    if r.error.noResponse:
      s.post(renewLost(binding, key))
    else:
      s.post(renewRefused(binding, key, reasonOf(r.error)))
    return
  let l = Link(shell: s, binding: binding, route: route)
  s.retired.add(l)
  let h = s.materialized(l)
  if h.isErr:
    s.post(renewRefused(binding, key, reasonOf(h.error)))
    return
  l.handle = h.get
  s.retired.setLen(s.retired.len - 1)
  s.adopt(l)
  s.post(renewed(binding, key))

proc drop(l: Link, f: FutureBase) =
  for i in 0 ..< l.inflight.len:
    if l.inflight[i] == f:
      l.inflight.del(i)
      return

proc askReadiness(s: Shell, l: Link) {.async: (raises: []).} =
  let f = l.handle.invokeAsync(
    LcnNSStorageFetchFetchReadinessRequest(),
    uint64(s.engine.input.limits.readDeadlineMs),
  )
  l.inflight.add(FutureBase(f))
  let r = await f
  l.drop(FutureBase(f))
  s.releaseIfIdle(l)
  if l.retiring or s.closed:
    return
  if r.isOk:
    s.post(readinessOf(l.binding, toReadiness(r.get.readiness)))
  elif r.error.code in {ecTransport, ecNotReady}:
    s.post(routeLost(l.binding, l.route))
  else:
    s.say("fetch_readiness on " & l.binding & " failed: " & reasonOf(r.error))

proc watch(s: Shell, binding: string) =
  let l = s.links.getOrDefault(binding)
  if l.isNil or l.handle.isNil:
    return
  if not l.subscribed:
    let sub = l.handle.subscribe(
      LcnNSStorageFetchFetchReadinessChangedEvent,
      onReadinessChanged,
      onSubscriptionEnded,
      nil,
      cast[pointer](l),
    )
    if sub.isOk:
      l.sub = sub.get
      l.subscribed = true
    else:
      s.say("no readiness subscription on " & binding & ": " & reasonOf(sub.error))
  s.tasks.add(s.askReadiness(l))

# Calls ----------------------------------------------------------------------------------

func answerOf(f: InvocationFailure): Answer =
  if f.code in {ecTransport, ecNotReady}:
    routeGone(reasonOf(f))
  else:
    invocationError(reasonOf(f))

func codeOf(c: LcnNSStorageFetchFailureCodeChoiceKind): FailureCode =
  type K = LcnNSStorageFetchFailureCodeChoiceKind
  case c
  of K.Invalid_length: fcInvalidLength
  of K.Invalid_locator: fcInvalidLocator
  of K.Not_ready: fcNotReady
  of K.Unavailable: fcUnavailable
  of K.Out_of_range: fcOutOfRange

func failed(f: LcnNSStorageFetchFailure): Answer =
  failureOf(codeOf(f.code.kind), f.detail.get(""))

proc callTask(s: Shell, l: Link, c: Command) {.async: (raises: []).} =
  var answer: Answer
  if c.kind == cmStat:
    let f = l.handle.invokeAsync(
      LcnNSStorageFetchStatObjectRequest(`object`: c.locator), uint64(c.deadlineMs)
    )
    l.inflight.add(FutureBase(f))
    s.calls[c.call] = FutureBase(f)
    let r = await f
    s.calls.del(c.call)
    l.drop(FutureBase(f))
    answer =
      if r.isErr:
        answerOf(r.error)
      else:
        case r.get.kind
        of LcnNSStorageFetchStatObjectResponseKind.Map_size:
          sized(r.get.arm_Map_size.size)
        of LcnNSStorageFetchStatObjectResponseKind.Map_failure:
          failed(r.get.arm_Map_failure.failure)
  else:
    let f = l.handle.invokeAsync(
      LcnNSStorageFetchReadObjectRequest(
        `object`: c.locator, offset: c.offset, length: c.length
      ),
      uint64(c.deadlineMs),
    )
    l.inflight.add(FutureBase(f))
    s.calls[c.call] = FutureBase(f)
    let r = await f
    s.calls.del(c.call)
    l.drop(FutureBase(f))
    answer =
      if r.isErr:
        answerOf(r.error)
      else:
        case r.get.kind
        of LcnNSStorageFetchReadObjectResponseKind.Map_data:
          dataOf(r.get.arm_Map_data.data)
        of LcnNSStorageFetchReadObjectResponseKind.Map_failure:
          failed(r.get.arm_Map_failure.failure)
  s.releaseIfIdle(l)
  s.post(answered(c.call, answer))

proc startCall(s: Shell, c: Command) =
  let l = s.links.getOrDefault(c.target)
  if l.isNil or l.handle.isNil:
    s.post(answered(c.call, routeGone("the binding has no route")))
    return
  s.tasks.add(s.callTask(l, c))

proc timerTask(s: Shell, id: uint64, ms: uint32) {.async: (raises: []).} =
  try:
    await sleepAsync(int(ms).milliseconds)
  except CancelledError:
    return
  s.timers.del(id)
  s.post(fired(id))

# Commands -------------------------------------------------------------------------------

type Turn = ref object ## [G455] a resolution's next turn, for `callSoon`
  shell: Shell
  operation: uint64

proc continueSoon(arg: pointer) {.gcsafe, raises: [].} =
  let t = cast[Turn](arg)
  if not t.shell.closed:
    t.shell.run(t.shell.engine.handle(continued(t.operation)))
  GC_unref(t)

when defined(lcnTestHooks):
  from std/strutils import parseInt

  proc testPageBudget(): int =
    ## [IMPL] A test build's page byte budget, from `LCN_TEST_PM_PAGE_BUDGET`.
    try:
      let v = parseInt(getEnv("LCN_TEST_PM_PAGE_BUDGET", "0"))
      if v > 0: v else: PageBudget
    except ValueError:
      PageBudget

  proc noteHandoffJob() =
    ## [IMPL; plan §10.3, ruling A] One line for each `wjHandoff`, in the file
    ## `LCN_TEST_HANDOFF_JOBS` names.
    let path = getEnv("LCN_TEST_HANDOFF_JOBS")
    if path.len == 0:
      return
    try:
      let f = open(path, fmAppend)
      f.write("wjHandoff\n")
      f.close()
    except CatchableError:
      discard

proc exec(s: Shell, c: var Command) =
  ## `c`'s outcome, if it has one, is moved out: a closure can be large.
  case c.kind
  of cmEstablish:
    s.establishRoute(c.binding, c.instance, c.key)
  of cmRenew:
    s.renewLink(c.binding, c.route, c.key)
  of cmRelease:
    s.retire(c.binding)
  of cmWatch:
    s.watch(c.binding)
  of cmStat, cmRead:
    s.startCall(c)
  of cmTimer:
    s.timers[c.timer] = s.timerTask(c.timer, c.ms)
  of cmWriteKept:
    let w = writeAtomic(s.stateDir, KeptName, c.kept)
    if w.isErr:
      s.say("the kept catalog was not written: " & w.error)
  of cmReply:
    var f: Future[Result[Resolution, PackageError]].Raising([CancelledError])
    if s.replies.pop(c.request, f):
      f.complete(move c.outcome)
  of cmLog:
    s.say(c.text)
  of cmContinue:
    # [G455; Fable F2] One poll later, never in this drain.
    let t = Turn(shell: s, operation: c.operation)
    GC_ref(t)
    callSoon(continueSoon, cast[pointer](t))
  of cmWork:
    when defined(lcnTestHooks):
      if c.job.kind == wjHandoff:
        noteHandoffJob()
    s.worker.submit(move c.job)
  of cmPage:
    s.reader.submit(move c.job)
  of cmAnswer:
    var f: Future[OperationAnswer].Raising([CancelledError])
    if s.answers.pop(c.answerTo, f):
      f.complete(move c.answer)
  of cmCancelCall:
    # [G449] Through the Interface's cancel; the call's answer still comes back.
    let f = s.calls.getOrDefault(c.cancelled)
    if not f.isNil:
      f.cancelSoon()

proc onWorkerResult(
    owner: pointer, r: sink WorkerResult
) {.nimcall, gcsafe, raises: [].} =
  ## [G447] The worker's answer, on the module thread: an event like any other.
  cast[Shell](owner).post(worked(r))

# Start -----------------------------------------------------------------------------------

proc startSoon(arg: pointer) {.gcsafe, raises: [].} =
  let s = cast[Shell](arg)
  if not s.closed:
    s.run(s.engine.start())
  GC_unref(s)

proc openShell*(
    init: ModuleInit,
    log: ShellLog = stderrLog,
    platform = hostPlatform(),
    pathRules = hostPathRules(),
    turnWork = ResolverTurnWork,
): Result[Shell, InvocationFailure] =
  ## [G405] The shell at `_MODULE_init`, on the module thread: the protected
  ## input read and checked, the kept catalog loaded, the engine made; it
  ## starts once `_MODULE_init` returned. A refusal is also logged: the
  ## Runtime records only `_MODULE_init`'s code, and the operator's log is
  ## where the field it names is read ([IMPL]). `turnWork` is the work of one
  ## resolution turn (G455): the constant, except in tests.
  template refuse(f: InvocationFailure): untyped =
    let failed = f
    log("package-manager: initialization failed: " & oneLine(failed.message.get("")))
    return err(failed)

  if init.stateDir.isNone:
    refuse(
      moduleError(
        "the Package Manager has no state directory, where its protected input is (G400)"
      )
    )
  let dir = init.stateDir.get
  let raw = readProtectedInput(dir).valueOr:
    refuse(moduleError("the protected input could not be read: " & error))
  if raw.isNone:
    refuse(
      moduleError("lcn.pm_input is absent: this instance has no protected input (G400)")
    )
  let input = decodePmInput(raw.get).valueOr:
    refuse(moduleError("lcn.pm_input is refused: " & error))
  let kept = readBounded(dir / KeptName, input.limits.catalogBytes + KeptOverheadBytes).valueOr:
    refuse(moduleError("the kept catalog could not be read: " & error))
  # [G444, G445] The installation root: its lock, its index, and the start's cleanup,
  # the spool's included, before the worker writes there (G447).
  when defined(posix):
    var store = openStore(dir).valueOr:
      refuse(moduleError("the installation root could not be opened: " & error.detail))
    for note in store.notes:
      log("package-manager: " & oneLine(note))
  let spoolDir = dir / InstallDir / SpoolDir
  ensurePrivateDir(spoolDir).isOkOr:
    when defined(posix):
      store.close()
    refuse(moduleError("the spool directory could not be made: " & error))
  let routeSet = newRouteSet(init.services).valueOr:
    when defined(posix):
      store.close()
    refuse(error)
  let budget =
    when defined(lcnTestHooks):
      testPageBudget()
    else:
      PageBudget
  var (e, notes) = initEngine(
    input,
    kept,
    freshKey,
    platform,
    pathRules = pathRules,
    turnWork = turnWork,
    pageBudget = budget,
  )
  let s = Shell(engine: move e, routeSet: routeSet, stateDir: dir, log: log)
  var config = s.engine.workerConfig(spoolDir)
  # [G500] The read-only worker's own copy, with the root's path and no store files.
  var readConfig = config
  readConfig.readOnly = true
  readConfig.root = dir / InstallDir
  when defined(posix):
    s.store = move store
    s.engine.setSnapshot(snapshotOf(s.store))
    # [Fable's 5-5-4 check §1.2] The file half, the descriptor with it, is the worker's
    # from now on; the shell keeps the lock, released after the worker is joined.
    config.store = s.store.handOver()
    config.hasStore = true
  let started =
    startWorker(init.services.poster, cast[pointer](s), onWorkerResult, move config)
  if started.isErr:
    discard s.routeSet.close()
    when defined(posix):
      s.store.close()
    refuse(moduleError(started.error))
  s.worker = started.get
  let reading =
    startWorker(init.services.poster, cast[pointer](s), onWorkerResult, move readConfig)
  if reading.isErr:
    discard s.routeSet.close()
    abandonWorker(s.worker)
    when defined(posix):
      s.store.close()
    refuse(moduleError(reading.error))
  s.reader = reading.get
  s.run(move notes)
  GC_ref(s)
  callSoon(startSoon, cast[pointer](s))
  ok(s)

# Operations -------------------------------------------------------------------------------

proc resolveRoot*(
    s: Shell, root: RootReference
): Future[Result[Resolution, PackageError]].Raising([CancelledError]) =
  ## [G405] One root operation through the driver; completes with its outcome.
  ## [G455; Fable F3] Cancelled by its caller, it is cancelled in the engine,
  ## so it takes no more turns, and the future ends cancelled.
  let f = Future[Result[Resolution, PackageError]].Raising([CancelledError]).init(
      "pm resolve", {FutureFlag.OwnCancelSchedule}
    )
  if s.closed:
    f.complete(
      Result[Resolution, PackageError].err(
        packageError(pecPackageUnavailable, "the Package Manager is stopping")
      )
    )
    return f
  inc s.nextRequest
  let id = s.nextRequest
  s.replies[id] = f
  f.cancelCallback = proc(arg: pointer) {.gcsafe, raises: [].} =
    var held: Future[Result[Resolution, PackageError]].Raising([CancelledError])
    if s.replies.pop(id, held):
      s.run(s.engine.cancel(id))
      held.cancelAndSchedule()
  s.run(s.engine.resolve(id, root))
  f

proc ask(
    s: Shell,
    issue: proc(e: var Engine, id: uint64): seq[Command] {.gcsafe, raises: [].},
): Future[OperationAnswer].Raising([CancelledError]) =
  ## One operation or query through the engine; completes with its answer. Cancelled by its
  ## caller, it is cancelled in the engine (leaving its queue, or ending at its next
  ## suspension), and the future ends cancelled.
  let f = Future[OperationAnswer].Raising([CancelledError]).init(
      "pm operation", {FutureFlag.OwnCancelSchedule}
    )
  if s.closed:
    f.complete(
      OperationAnswer(
        kind: oaResponse,
        response: errorResult(pecPackageUnavailable, "the Package Manager is stopping"),
      )
    )
    return f
  inc s.nextRequest
  let id = s.nextRequest
  s.answers[id] = f
  f.cancelCallback = proc(arg: pointer) {.gcsafe, raises: [].} =
    var held: Future[OperationAnswer].Raising([CancelledError])
    if s.answers.pop(id, held):
      s.run(s.engine.cancel(id))
      held.cancelAndSchedule()
  s.run(issue(s.engine, id))
  f

proc operate*(
    s: Shell, op: OperationRequest
): Future[OperationAnswer].Raising([CancelledError]) =
  ## [G449] One operation through the engine's slots.
  s.ask(
    proc(e: var Engine, id: uint64): seq[Command] {.gcsafe, raises: [].} =
      e.submit(id, op)
  )

proc handoff*(
    s: Shell, identity: PackageIdentity, module: string
): Future[OperationAnswer].Raising([CancelledError]) =
  ## [SPEC PM §12; 5-5-4] `get_runtime_handoff`, a query that does not queue.
  s.ask(
    proc(e: var Engine, id: uint64): seq[Command] {.gcsafe, raises: [].} =
      e.handoff(id, identity, module)
  )

proc listPackages*(
    s: Shell, origin: Origin, filter, cursor: Opt[string], limit: Opt[uint16]
): Future[OperationAnswer].Raising([CancelledError]) =
  ## [G500] One `list_packages` page for the reader `origin`.
  s.ask(
    proc(e: var Engine, id: uint64): seq[Command] {.gcsafe, raises: [].} =
      e.listPackages(id, origin, filter, cursor, limit)
  )

proc listInstalled*(
    s: Shell, origin: Origin, filter, cursor: Opt[string], limit: Opt[uint16]
): Future[OperationAnswer].Raising([CancelledError]) =
  ## [G500] One `list_installed_packages` page for the reader `origin`.
  s.ask(
    proc(e: var Engine, id: uint64): seq[Command] {.gcsafe, raises: [].} =
      e.listInstalled(id, origin, filter, cursor, limit)
  )

proc readerHandoff*(
    s: Shell, origin: Origin, identity: PackageIdentity, module: string
): Future[OperationAnswer].Raising([CancelledError]) =
  ## [G500, ruling A] A reader's `get_runtime_handoff`, a page job.
  s.ask(
    proc(e: var Engine, id: uint64): seq[Command] {.gcsafe, raises: [].} =
      e.readerHandoff(id, origin, identity, module)
  )

func readers*(s: Shell): seq[string] =
  ## [G498] The protected input's readers.
  s.engine.input.readers

func runtimeInstanceId*(s: Shell): string =
  ## [G498] The Runtime the readers' calls come from.
  s.engine.input.runtimeInstanceId

proc shellStatus*(s: Shell): ShellStatus =
  ## The catalog in use, each binding's route, and the running operations.
  result.catalog = s.engine.catalogInUse
  for b in s.engine.status:
    result.bindings.add(
      LinkStatus(binding: b, established: s.established.getOrDefault(b.name))
    )
  result.pending = s.engine.pendingRequests

proc within(
    fs: seq[Future[void].Raising([])], bound: Duration
): Future[void] {.async: (raises: []).} =
  let guard = sleepAsync(bound)
  for f in fs:
    if f.finished():
      continue
    try:
      discard await race(FutureBase(f), FutureBase(guard))
    except CancelledError:
      discard
    if guard.finished():
      break
  guard.cancelSoon()

proc closeShell*(s: Shell): Future[void] {.async: (raises: []).} =
  ## [G437] `_MODULE_destroy`: nothing is issued from now on; outstanding calls
  ## are cancelled and awaited (bounded), and the route set is closed.
  if s.closed:
    return
  s.closed = true
  # [G405] The engine names the operations still running; they are answered
  # once the calls have ended.
  var answers = s.engine.stop()
  s.events.clear()
  for _, t in s.timers:
    t.cancelSoon()
  s.timers.clear()
  for _, l in s.links:
    for f in l.inflight:
      f.cancelSoon()
  await within(s.tasks, CloseWait)
  s.tasks.setLen(0)
  for c in answers.mitems:
    if c.kind == cmReply:
      var f: Future[Result[Resolution, PackageError]].Raising([CancelledError])
      if s.replies.pop(c.request, f):
        f.complete(move c.outcome)
    elif c.kind == cmAnswer:
      var f: Future[OperationAnswer].Raising([CancelledError])
      if s.answers.pop(c.answerTo, f):
        f.complete(move c.answer)
  # None is left: every operation the shell holds a future for is the engine's.
  for _, f in s.replies:
    f.complete(
      Result[Resolution, PackageError].err(
        packageError(pecPackageUnavailable, "the Package Manager is stopping")
      )
    )
  s.replies.clear()
  for _, f in s.answers:
    f.complete(
      OperationAnswer(
        kind: oaResponse,
        response: errorResult(pecPackageUnavailable, "the Package Manager is stopping"),
      )
    )
  s.answers.clear()
  for _, l in s.links:
    l.retiring = true
  for l in s.retired:
    l.retiring = true
  let r = s.routeSet.close()
  if r.isErr:
    s.say("the route set was not closed cleanly: " & reasonOf(r.error))
  s.routeSet = nil
  s.links.clear()
  s.retired.setLen(0)
  # [G447] The worker after the engine: no job follows; it deletes its spool files.
  await stopWorker(s.worker)
  s.worker = nil
  if not s.reader.isNil:
    await stopWorker(s.reader)
    s.reader = nil
  when defined(posix):
    s.store.close()

{.pop.}
