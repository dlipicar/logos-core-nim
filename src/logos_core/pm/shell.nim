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
##   kept catalog (`catalog.kept`, G401) is loaded and the engine made. Nothing
##   waits on a route, so the instance is Runtime-ready at once; the engine
##   starts in the module thread's next turn, after `_MODULE_init` returned.
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
## - **A replaced handle** is released once no call through it is
##   outstanding; its calls are cancelled first and end by their deadline in
##   any case. Its callbacks are ignored from then on.
## - **The log** (`cmLog`): one line each, `package-manager: <text>`, made one
##   line (`logtext.oneLine`), on stderr unless the module gives its own sink.
##   The engine's lines hold names, codes, digests and counts, never a
##   payload.
## - **`closeShell`** (`_MODULE_destroy`): the engine stops (no command
##   follows, G437), timers are cancelled, outstanding calls are cancelled and
##   awaited (bounded), the route set is closed, and a root operation still
##   running is answered `package-unavailable`. Only `catalog.kept` was ever
##   written.

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
import ./engine

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
    replies: Table[uint64, Future[Result[Resolution, PackageError]].Raising([])]
    nextRequest: uint64
    closed: bool

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

proc exec(s: Shell, c: Command)

proc run(s: Shell, cmds: seq[Command]) =
  for c in cmds:
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
    let r = await f
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
    let r = await f
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

proc exec(s: Shell, c: Command) =
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
    var f: Future[Result[Resolution, PackageError]].Raising([])
    if s.replies.pop(c.request, f):
      f.complete(c.outcome)
  of cmLog:
    s.say(c.text)

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
): Result[Shell, InvocationFailure] =
  ## [G405] The shell at `_MODULE_init`, on the module thread: the protected
  ## input read and checked, the kept catalog loaded, the engine made; it
  ## starts once `_MODULE_init` returned. A refusal is also logged: the
  ## Runtime records only `_MODULE_init`'s code, and the operator's log is
  ## where the field it names is read ([IMPL]).
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
  let routeSet = newRouteSet(init.services).valueOr:
    refuse(error)
  let (e, notes) = initEngine(input, kept, freshKey, platform, pathRules = pathRules)
  let s = Shell(engine: e, routeSet: routeSet, stateDir: dir, log: log)
  for c in notes:
    s.exec(c)
  GC_ref(s)
  callSoon(startSoon, cast[pointer](s))
  ok(s)

# Operations -------------------------------------------------------------------------------

proc resolveRoot*(
    s: Shell, root: RootReference
): Future[Result[Resolution, PackageError]].Raising([]) =
  ## [G405] One root operation through the driver; completes with its outcome.
  # A cancellation leaves it to the engine's answer: the operation is not
  # abandoned midway.
  let f = Future[Result[Resolution, PackageError]].Raising([]).init(
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
  s.run(s.engine.resolve(id, root))
  f

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
  s.engine.stop()
  s.events.clear()
  for _, t in s.timers:
    t.cancelSoon()
  s.timers.clear()
  for _, l in s.links:
    for f in l.inflight:
      f.cancelSoon()
  await within(s.tasks, CloseWait)
  s.tasks.setLen(0)
  for _, f in s.replies:
    f.complete(
      Result[Resolution, PackageError].err(
        packageError(pecPackageUnavailable, "the Package Manager is stopping")
      )
    )
  s.replies.clear()
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

{.pop.}
