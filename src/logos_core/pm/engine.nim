## The Package Manager's engine (Tier 5 step 5-3b; DECISIONS G401, G402, G405;
## docs/PACKAGE-MANAGER.md §3, §4). It owns the checked input, the catalog
## state, the bindings and their routes, the verification cache and the
## resolution drivers, and does no I/O: each entry point returns the
## `Command`s to carry out, and their results come back as `Event`s. The shell
## (`pm/shell.nim`, 5-3b-2) carries them out over the kit: routes through
## Runtime Control, calls on `lcn.storage_fetch`, timers and the state file.
##
## **Routes** (G402). At `start`, every binding gets a route to its provider
## instance:
## - **every establishment has a new key** from the injected source: a replay
##   returns the retained result and revives nothing (R l.3072-3082), so a
##   fixed key would hand a lost route's old record back. A key is reused only
##   to retry an establishment whose response was lost (R l.3077);
## - once a route is ready, its readiness is watched (`cmWatch`: subscribe to
##   `fetch_readiness_changed_event`, then call `fetch_readiness`);
## - **a lost route** (`evRouteLost`, or a call answered `akRouteLost`) is
##   renewed with a new key (`renew_route`, then `materialize`, R l.3081,
##   l.3089-3090); a renewal refused as unknown, closed, failed or revoked
##   releases the old handles and establishes anew (R l.3094-3096);
## - **a refused establishment** is retried after a bounded back-off; until
##   the route is ready the binding's material is unavailable;
## - **after `stop`** (`_MODULE_destroy` began) nothing is issued: no
##   establishment starts while the module is destroyed (G437).
##
## **Retrieval** (G402) runs one object at a time per binding, in order of
## request (`fetcher.nim`). Every call carries `read_deadline_ms` as its
## deadline, and the engine's own timer ends a call that passes it, whatever
## the provider does; a late answer is ignored.
##
## **The catalog** (G401) is acquired once its binding reports `ready`, then
## retried on each later `ready` and after a bounded back-off while the
## binding stays `ready`. One accepted or refused document ends acquisition
## for this start: the locator names fixed bytes, so reading it again gives
## the same answer (no refresh). An accepted document's kept file is written
## by `cmWriteKept`; the catalog is in use whether or not that write succeeds.
##
## **Resolution** (G405) goes through `driver.nim`: each source it needs is
## retrieved on its binding and inspected through the verification cache
## (`vcache.nim`). A source naming no binding is unavailable, and the name is
## logged once per start. With no catalog in use, an operation fails
## `package-unavailable`, never as if the catalog were empty (PM l.1308-1309).

{.push raises: [], gcsafe.}

import std/[sets, strutils, tables]
import results
import logos_sdk/base/hex
import ../package/[errors, records, resolver]
import ./[input, catalog, fetcher, vcache, driver]

export results, input, catalog, fetcher, vcache, driver

const
  RouteBackoffMs* = [1_000'u32, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000]
    ## [IMPL; G402] the waits before establishing again after a refusal; the
    ## last repeats
  AcquireBackoffMs* = [1_000'u32, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000]
    ## [IMPL; G401] the waits before reading the catalog again while its binding
    ## stays `ready`; the last repeats
  MaxLostResponses* = 3
    ## [IMPL; G402] an establishment or renewal whose response was lost is retried
    ## under the same key this many times, then counts as refused

type
  Readiness* = enum
    ## [SPEC STORAGE-FETCH §4] `lcn.storage_fetch.readiness`
    rdStarting = "starting"
    rdReady = "ready"
    rdOffline = "offline"

  RouteState* = enum
    rsIdle ## before `start`
    rsEstablishing
    rsReady
    rsRenewing
    rsBackoff ## an establishment was refused; another follows a back-off
    rsStopped

  KeySource* = proc(): string {.gcsafe, raises: [].}
    ## A fresh `request_key`: 128 random bits in hex in the shell, never a fixed
    ## value. An empty key counts as a refused establishment.

  CommandKind* = enum
    cmEstablish ## `openRoute` to `instance` for `lcn.storage_fetch` under `key`
    cmRenew ## `renew_route` on `route` under `key`, then `materialize`
    cmRelease ## release `route`'s handles
    cmWatch
      ## subscribe to `fetch_readiness_changed_event` on the binding's route, then
      ## call `fetch_readiness`; each answer is an `evReadiness`
    cmStat ## `stat_object`
    cmRead ## `read_object`
    cmTimer ## report `evTimer` after `ms`
    cmWriteKept ## replace `catalog.kept` with `kept` (sync and rename)
    cmReply ## the outcome of `resolve`'s request
    cmLog ## a line for the module's log

  Command* = object
    case kind*: CommandKind
    of cmEstablish, cmRenew, cmRelease, cmWatch:
      binding*: string
      instance*: string
      route*: string ## renew and release
      key*: string ## establish and renew
    of cmStat, cmRead:
      call*: uint64
      target*: string ## the binding
      locator*: seq[byte]
      offset*: uint64
      length*: uint32
      deadlineMs*: uint32
    of cmTimer:
      timer*: uint64
      ms*: uint32
    of cmWriteKept:
      kept*: seq[byte]
    of cmReply:
      request*: uint64
      outcome*: Result[Resolution, PackageError]
    of cmLog:
      text*: string

  RouteAnswer* = enum
    raReady
    raRefused ## refused, unknown, closed, failed or revoked
    raLost ## no response arrived

  EventKind* = enum
    evEstablished ## the answer to `cmEstablish`
    evRenewed ## the answer to `cmRenew`
    evRouteLost ## `onRouteEnd` fired for the binding's route
    evReadiness
    evAnswer ## the answer to `cmStat` or `cmRead`
    evTimer

  Event* = object
    case kind*: EventKind
    of evEstablished, evRenewed:
      binding*: string
      key*: string
      answer*: RouteAnswer
      route*: string ## the established route's id
      reason*: string ## foreign text, for the log
    of evRouteLost:
      lostBinding*: string
      lostRoute*: string
    of evReadiness:
      readyBinding*: string
      readiness*: Readiness
    of evAnswer:
      call*: uint64
      reply*: Answer
    of evTimer:
      timer*: uint64

  JobWait = enum
    jwNone
    jwCall ## a call is outstanding; the timer is its deadline
    jwRoute ## waiting for the route; the timer bounds the wait
    jwReady ## waiting for `ready`; the timer bounds the wait
    jwBackoff ## the timer ends the back-off

  Job = object
    id: uint64
    catalog: bool ## the catalog document, else `source`'s archive for `request`
    request: uint64
    source: PackageSource
    fetch: Retrieval
    wait: JobWait
    call: uint64
    timer: uint64

  Binding = object
    name: string
    instance: string
    state: RouteState
    route: string
    key: string
    lost: int ## lost responses in a row under `key`
    generation: int
      ## counts the times a route became ready, a renewal included: a renewed
      ## route keeps its id
    backoff: int ## refusals in a row
    readiness: Opt[Readiness]
    jobs: seq[Job] ## the head runs
    active: bool ## the head has started

  TimerKind = enum
    tkRoute ## a binding's establishment back-off
    tkJob ## a job's call deadline, wait bound or back-off
    tkAcquire ## the catalog's back-off

  TimerTarget = object
    kind: TimerKind
    binding: int
    job: uint64

  BindingStatus* = object
    name*: string
    instance*: string
    state*: RouteState
    route*: string
    readiness*: Opt[Readiness]

  Engine* = object
    input*: PmInput
    keys: KeySource
    catalog*: CatalogState
    cache*: VerificationCache
    bindings: seq[Binding]
    catalogBinding: int
    acquired: bool ## the catalog was accepted or refused this start
    acquiring: bool ## a catalog job is queued or running
    acquireBackoff: int
    acquireTimer: uint64
    requests: Table[uint64, Driver]
    calls: Table[uint64, (int, uint64, int)] ## call id -> (binding, job, generation)
    timers: Table[uint64, TimerTarget]
    unknownLogged: HashSet[string]
    next: uint64
    started: bool
    stopped*: bool

# Construction -----------------------------------------------------------------------

proc initEngine*(
    input: PmInput,
    keptBytes: Opt[seq[byte]],
    keys: KeySource,
    platform = hostPlatform(),
    lgxLimits = DefaultLgxLimits,
    pathRules = hostPathRules(),
): (Engine, seq[Command]) =
  ## The engine at `_init`, before any I/O: the catalog state from the kept
  ## file (`keptBytes`), and the log lines that start produced. The resolver
  ## limits are the input's (G399, planning's ruling of 2026-11-22): no caller
  ## can pass values the input does not hold.
  var e = Engine(
    input: input,
    keys: keys,
    cache:
      initVerificationCache(input.limits.cacheEntries, platform, lgxLimits, pathRules),
    catalogBinding: -1,
  )
  var cmds: seq[Command]
  let (state, note) = initCatalogState(input.catalog, input.limits, keptBytes)
  e.catalog = state
  if note.isSome:
    cmds.add(Command(kind: cmLog, text: note.get))
  if e.catalog.inUse.isSome:
    let c = e.catalog.inUse.get
    cmds.add(
      Command(
        kind: cmLog,
        text:
          "the kept catalog is in use: sequence " & $c.sequence & ", " & $c.entries.len &
          " entries, digest " & c.digest.toHex,
      )
    )
  for i, b in input.bindings:
    e.bindings.add(Binding(name: b.name, instance: b.instance))
    if b.name == input.catalog.storage:
      e.catalogBinding = i
  doAssert e.catalogBinding >= 0 # checkedValue's rule
  (e, cmds)

# Ids, timers and status -------------------------------------------------------------

proc nextId(e: var Engine): uint64 =
  inc e.next
  e.next

proc timer(
    e: var Engine, cmds: var seq[Command], target: TimerTarget, ms: uint32
): uint64 =
  let id = e.nextId()
  e.timers[id] = target
  cmds.add(Command(kind: cmTimer, timer: id, ms: ms))
  id

proc log(cmds: var seq[Command], text: string) =
  cmds.add(Command(kind: cmLog, text: text))

func index(e: Engine, name: string): int =
  for i, b in e.bindings:
    if b.name == name:
      return i
  -1

func status*(e: Engine): seq[BindingStatus] =
  for b in e.bindings:
    result.add(
      BindingStatus(
        name: b.name,
        instance: b.instance,
        state: b.state,
        route: b.route,
        readiness: b.readiness,
      )
    )

func catalogInUse*(e: Engine): Opt[Catalog] =
  e.catalog.inUse

func pendingRequests*(e: Engine): int =
  e.requests.len

func queued*(e: Engine, binding: string): int =
  let i = e.index(binding)
  if i < 0:
    0
  else:
    e.bindings[i].jobs.len

func usable(b: Binding): bool =
  b.state == rsReady

# Routes -----------------------------------------------------------------------------

proc failJobs(e: var Engine, bi: int, reason: string, cmds: var seq[Command])
proc resumeRoute(e: var Engine, bi: int, cmds: var seq[Command])

proc establish(e: var Engine, bi: int, cmds: var seq[Command]) =
  let key = e.keys()
  template b(): untyped =
    e.bindings[bi]

  if key.len == 0:
    cmds.log(
      "binding " & b.name.escape & ": no fresh request key; establishment refused"
    )
    b.state = rsBackoff
    let ms = RouteBackoffMs[min(b.backoff, RouteBackoffMs.high)]
    inc b.backoff
    discard e.timer(cmds, TimerTarget(kind: tkRoute, binding: bi), ms)
    e.failJobs(bi, "the route to the binding's provider is not established", cmds)
    return
  b.key = key
  b.lost = 0
  b.state = rsEstablishing
  cmds.add(Command(kind: cmEstablish, binding: b.name, instance: b.instance, key: key))

proc refused(e: var Engine, bi: int, reason: string, cmds: var seq[Command]) =
  template b(): untyped =
    e.bindings[bi]

  cmds.log(
    "binding " & b.name.escape & ": the route to " & b.instance.escape & " was refused: " &
      reason.escape
  )
  b.state = rsBackoff
  b.route = ""
  b.readiness = Opt.none(Readiness)
  let ms = RouteBackoffMs[min(b.backoff, RouteBackoffMs.high)]
  inc b.backoff
  discard e.timer(cmds, TimerTarget(kind: tkRoute, binding: bi), ms)
  e.failJobs(bi, "the route to the binding's provider was refused", cmds)

proc routeReady(e: var Engine, bi: int, cmds: var seq[Command]) =
  template b(): untyped =
    e.bindings[bi]

  b.state = rsReady
  inc b.generation
  b.backoff = 0
  b.lost = 0
  b.readiness = Opt.none(Readiness)
  cmds.add(
    Command(kind: cmWatch, binding: b.name, instance: b.instance, route: b.route)
  )
  e.resumeRoute(bi, cmds)

proc lose(e: var Engine, bi: int, cmds: var seq[Command]) =
  ## The binding's ready route is lost: renew it under a new key.
  template b(): untyped =
    e.bindings[bi]

  if b.state != rsReady:
    return
  b.readiness = Opt.none(Readiness)
  let key = e.keys()
  if key.len == 0:
    cmds.add(
      Command(kind: cmRelease, binding: b.name, instance: b.instance, route: b.route)
    )
    b.route = ""
    e.establish(bi, cmds)
    return
  b.key = key
  b.lost = 0
  b.state = rsRenewing
  cmds.add(
    Command(
      kind: cmRenew, binding: b.name, instance: b.instance, route: b.route, key: key
    )
  )

proc onEstablished(e: var Engine, ev: Event, cmds: var seq[Command]) =
  let bi = e.index(ev.binding)
  if bi < 0:
    return
  template b(): untyped =
    e.bindings[bi]

  if ev.key != b.key:
    return # a stale answer
  if ev.kind == evEstablished and b.state == rsEstablishing:
    case ev.answer
    of raReady:
      b.route = ev.route
      e.routeReady(bi, cmds)
    of raLost:
      inc b.lost
      if b.lost > MaxLostResponses:
        e.refused(bi, "no response to " & $MaxLostResponses & " retries", cmds)
      else:
        cmds.add(
          Command(kind: cmEstablish, binding: b.name, instance: b.instance, key: b.key)
        )
    of raRefused:
      e.refused(bi, ev.reason, cmds)
  elif ev.kind == evRenewed and b.state == rsRenewing:
    case ev.answer
    of raReady:
      e.routeReady(bi, cmds)
    of raLost:
      inc b.lost
      if b.lost <= MaxLostResponses:
        cmds.add(
          Command(
            kind: cmRenew,
            binding: b.name,
            instance: b.instance,
            route: b.route,
            key: b.key,
          )
        )
        return
      cmds.add(
        Command(kind: cmRelease, binding: b.name, instance: b.instance, route: b.route)
      )
      b.route = ""
      e.establish(bi, cmds)
    of raRefused:
      cmds.log(
        "binding " & b.name.escape & ": the route could not be renewed: " &
          ev.reason.escape
      )
      cmds.add(
        Command(kind: cmRelease, binding: b.name, instance: b.instance, route: b.route)
      )
      b.route = ""
      e.establish(bi, cmds)

# Jobs -------------------------------------------------------------------------------

proc startHead(e: var Engine, bi: int, cmds: var seq[Command])
proc deliver(e: var Engine, bi: int, job: Job, step: FetchStep, cmds: var seq[Command])

proc apply(
    e: var Engine, bi: int, step: FetchStep, waitFor: JobWait, cmds: var seq[Command]
) =
  ## Carries out the head job's next step.
  template b(): untyped =
    e.bindings[bi]

  template j(): untyped =
    e.bindings[bi].jobs[0]

  case step.kind
  of skCall:
    if b.state == rsBackoff or b.state == rsStopped:
      e.apply(
        bi,
        FetchStep(
          kind: skUnavailable,
          reason: "the route to the binding's provider is not established",
        ),
        jwNone,
        cmds,
      )
      return
    if not b.usable:
      j.wait = jwRoute
      j.timer = e.timer(
        cmds, TimerTarget(kind: tkJob, binding: bi, job: j.id), j.fetch.deadlineMs
      )
      return
    let id = e.nextId()
    j.call = id
    j.wait = jwCall
    e.calls[id] = (bi, j.id, b.generation)
    case step.call.kind
    of ckStat:
      cmds.add(
        Command(
          kind: cmStat,
          call: id,
          target: b.name,
          locator: j.fetch.locator,
          deadlineMs: j.fetch.deadlineMs,
        )
      )
    of ckRead:
      cmds.add(
        Command(
          kind: cmRead,
          call: id,
          target: b.name,
          locator: j.fetch.locator,
          offset: step.call.offset,
          length: step.call.length,
          deadlineMs: j.fetch.deadlineMs,
        )
      )
    j.timer = e.timer(
      cmds, TimerTarget(kind: tkJob, binding: bi, job: j.id), j.fetch.deadlineMs
    )
  of skWait:
    j.wait = waitFor
    j.timer = e.timer(cmds, TimerTarget(kind: tkJob, binding: bi, job: j.id), step.ms)
  of skBackoff:
    j.wait = jwBackoff
    j.timer = e.timer(cmds, TimerTarget(kind: tkJob, binding: bi, job: j.id), step.ms)
  of skDone, skUnavailable:
    let job = e.bindings[bi].jobs[0]
    e.bindings[bi].jobs.delete(0)
    e.bindings[bi].active = false
    if job.call != 0:
      e.calls.del(job.call)
    e.deliver(bi, job, step, cmds)
    e.startHead(bi, cmds)

proc startHead(e: var Engine, bi: int, cmds: var seq[Command]) =
  if e.bindings[bi].active or e.bindings[bi].jobs.len == 0 or e.stopped:
    return
  e.bindings[bi].active = true
  let step = e.bindings[bi].jobs[0].fetch.start()
  e.apply(bi, step, jwNone, cmds)

proc enqueue(e: var Engine, bi: int, job: sink Job, cmds: var seq[Command]) =
  e.bindings[bi].jobs.add(job)
  e.startHead(bi, cmds)

proc failJobs(e: var Engine, bi: int, reason: string, cmds: var seq[Command]) =
  ## Every job of the binding ends unavailable: its route was refused. A job a
  ## delivery adds meanwhile fails the same way when it starts.
  while e.bindings[bi].jobs.len > 0:
    e.bindings[bi].active = true
    e.bindings[bi].jobs[0].wait = jwNone
    e.apply(bi, FetchStep(kind: skUnavailable, reason: reason), jwNone, cmds)

proc resumeRoute(e: var Engine, bi: int, cmds: var seq[Command]) =
  ## The route is ready: a head job waiting for it issues its call again.
  if e.bindings[bi].jobs.len == 0 or not e.bindings[bi].active:
    e.startHead(bi, cmds)
    return
  if e.bindings[bi].jobs[0].wait == jwRoute:
    e.bindings[bi].jobs[0].wait = jwNone
    e.bindings[bi].jobs[0].timer = 0
    let step = e.bindings[bi].jobs[0].fetch.resume()
    e.apply(bi, step, jwNone, cmds)

proc resumeReady(e: var Engine, bi: int, cmds: var seq[Command]) =
  if e.bindings[bi].jobs.len == 0 or not e.bindings[bi].active:
    return
  if e.bindings[bi].jobs[0].wait == jwReady:
    e.bindings[bi].jobs[0].wait = jwNone
    e.bindings[bi].jobs[0].timer = 0
    let step = e.bindings[bi].jobs[0].fetch.resume()
    e.apply(bi, step, jwNone, cmds)

# The catalog ------------------------------------------------------------------------

proc acquire(e: var Engine, cmds: var seq[Command]) =
  ## [G401] Reads the configured catalog when it is still to be read and its
  ## binding is ready.
  let bi = e.catalogBinding
  if e.acquired or e.acquiring or e.stopped:
    return
  if not e.bindings[bi].usable or e.bindings[bi].readiness != Opt.some(rdReady):
    return
  e.acquiring = true
  e.acquireTimer = 0
  let job = Job(
    id: e.nextId(),
    catalog: true,
    fetch: initRetrieval(
      e.input.catalog.locator,
      int64(e.input.limits.catalogBytes),
      e.input.limits.readDeadlineMs,
    ),
  )
  e.enqueue(bi, job, cmds)

proc catalogDone(e: var Engine, step: FetchStep, cmds: var seq[Command]) =
  e.acquiring = false
  case step.kind
  of skDone:
    e.acquired = true
    let r = e.catalog.offer(step.bytes)
    if r.isErr:
      cmds.log("the configured catalog is refused: " & r.error)
      return
    let c = r.get.catalog
    cmds.log(
      "the configured catalog is in use: sequence " & $c.sequence & ", " & $c.entries.len &
        " entries, digest " & c.digest.toHex
    )
    if r.get.keptBytes.isSome:
      cmds.add(Command(kind: cmWriteKept, kept: r.get.keptBytes.get))
  of skUnavailable:
    cmds.log("the configured catalog could not be read: " & step.reason)
    let bi = e.catalogBinding
    if e.bindings[bi].usable and e.bindings[bi].readiness == Opt.some(rdReady):
      let ms = AcquireBackoffMs[min(e.acquireBackoff, AcquireBackoffMs.high)]
      inc e.acquireBackoff
      e.acquireTimer = e.timer(cmds, TimerTarget(kind: tkAcquire, binding: bi), ms)
  else:
    discard

# Resolution -------------------------------------------------------------------------

func limitValue(e: Engine, name: string): int =
  ## The configured value of the resolver limit `name` (`ResolverCounters.limit`).
  let l = e.input.resolverLimits
  case name
  of "partial_closure_names": l.names
  of "dependency_depth": l.depth
  of "candidates_per_name": l.candidates
  else: l.attempts

proc advanceRequest(e: var Engine, request: uint64, cmds: var seq[Command]) =
  let d = e.requests.getOrDefault(request)
  if d.isNil:
    return
  while true:
    let s = d.step()
    case s.kind
    of dsDone:
      e.requests.del(request)
      let tripped = d.counters.limit
      if tripped.len > 0:
        # [G399; ruling M5] The operator's log names the limit, with its value:
        # the caller sees only `dependency-unavailable` (PM l.1501-1502, l.1514).
        cmds.log(
          "a root operation stopped at the resolver limit " & tripped & " (" &
            $e.limitValue(tripped) & ")"
        )
      cmds.add(Command(kind: cmReply, request: request, outcome: s.outcome))
      return
    of dsNeed:
      let source = s.source
      let bi = e.index(source.storage)
      if bi < 0:
        if source.storage notin e.unknownLogged:
          e.unknownLogged.incl(source.storage)
          cmds.log(
            "a source names the binding " & source.storage.escape &
              ", which is not configured"
          )
        d.supply(
          source,
          Inspection(
            kind: ikUnavailable, reason: "the source names no configured binding"
          ),
        )
        continue
      let job = Job(
        id: e.nextId(),
        request: request,
        source: source,
        fetch: initRetrieval(
          source.objectLocator, e.input.limits.archiveBytes,
          e.input.limits.readDeadlineMs,
        ),
      )
      e.enqueue(bi, job, cmds)
      return

proc deliver(
    e: var Engine, bi: int, job: Job, step: FetchStep, cmds: var seq[Command]
) =
  if job.catalog:
    e.catalogDone(step, cmds)
    return
  let d = e.requests.getOrDefault(job.request)
  if d.isNil:
    return
  case step.kind
  of skDone:
    d.supply(job.source, e.cache.inspect(step.bytes, e.input.trust))
  of skUnavailable:
    d.supply(job.source, Inspection(kind: ikUnavailable, reason: step.reason))
  else:
    discard
  e.advanceRequest(job.request, cmds)

# Entry points -----------------------------------------------------------------------

proc start*(e: var Engine): seq[Command] =
  ## On start: a route for every binding.
  if e.started or e.stopped:
    return
  e.started = true
  for bi in 0 ..< e.bindings.len:
    e.establish(bi, result)

proc resolve*(e: var Engine, request: uint64, root: RootReference): seq[Command] =
  ## [G405] One root operation; its outcome is a later `cmReply`.
  if e.stopped:
    return
  if request in e.requests:
    result.add(
      Command(
        kind: cmReply,
        request: request,
        outcome: Result[Resolution, PackageError].err(
          packageError(pecInvalidRequest, "the request id is in use")
        ),
      )
    )
    return
  if e.catalog.inUse.isNone:
    result.add(
      Command(
        kind: cmReply,
        request: request,
        outcome: Result[Resolution, PackageError].err(
          packageError(pecPackageUnavailable, "no catalog is in use")
        ),
      )
    )
    return
  e.requests[request] =
    initDriver(e.catalog.inUse.get.entries, e.input.trust, e.input.resolverLimits, root)
  e.advanceRequest(request, result)

proc onAnswer(e: var Engine, call: uint64, a: Answer, cmds: var seq[Command]) =
  if call notin e.calls:
    return # late: its deadline passed, or its job ended
  let (bi, jobId, generation) = e.calls.getOrDefault(call)
  e.calls.del(call)
  if e.bindings[bi].jobs.len == 0 or e.bindings[bi].jobs[0].id != jobId:
    return
  e.bindings[bi].jobs[0].call = 0
  e.bindings[bi].jobs[0].timer = 0
  e.bindings[bi].jobs[0].wait = jwNone
  var waitFor = jwNone
  if a.kind == akRouteLost:
    waitFor = jwRoute
  elif a.kind == akFailure and a.code == fcNotReady:
    waitFor = jwReady
    e.bindings[bi].readiness = Opt.none(Readiness)
  let step = e.bindings[bi].jobs[0].fetch.onAnswer(a)
  e.apply(bi, step, waitFor, cmds)
  if a.kind == akRouteLost:
    if e.bindings[bi].generation == generation:
      # The route the call went over is the binding's: it is lost. A renewal or
      # a new establishment resumes the waiting job, or a refusal fails it.
      e.lose(bi, cmds)
    elif e.bindings[bi].usable:
      # The route was already replaced: issue the call again at once.
      e.resumeRoute(bi, cmds)

proc onTimer(e: var Engine, id: uint64, cmds: var seq[Command]) =
  if id notin e.timers:
    return
  let t = e.timers.getOrDefault(id)
  e.timers.del(id)
  case t.kind
  of tkRoute:
    if e.bindings[t.binding].state == rsBackoff:
      e.establish(t.binding, cmds)
  of tkAcquire:
    if e.acquireTimer == id:
      e.acquireTimer = 0
      e.acquire(cmds)
  of tkJob:
    let bi = t.binding
    if e.bindings[bi].jobs.len == 0 or e.bindings[bi].jobs[0].id != t.job or
        e.bindings[bi].jobs[0].timer != id:
      return # stale
    e.bindings[bi].jobs[0].timer = 0
    let wait = e.bindings[bi].jobs[0].wait
    e.bindings[bi].jobs[0].wait = jwNone
    case wait
    of jwCall:
      e.calls.del(e.bindings[bi].jobs[0].call)
      e.bindings[bi].jobs[0].call = 0
      let step = e.bindings[bi].jobs[0].fetch.onDeadline()
      e.apply(bi, step, jwNone, cmds)
    of jwRoute, jwReady:
      let step = e.bindings[bi].jobs[0].fetch.onWaitExpired()
      e.apply(bi, step, jwNone, cmds)
    of jwBackoff:
      let step = e.bindings[bi].jobs[0].fetch.resume()
      e.apply(bi, step, jwNone, cmds)
    of jwNone:
      discard

proc handle*(e: var Engine, ev: Event): seq[Command] =
  ## One event; nothing after `stop`.
  if e.stopped or not e.started:
    return
  case ev.kind
  of evEstablished, evRenewed:
    e.onEstablished(ev, result)
  of evRouteLost:
    let bi = e.index(ev.lostBinding)
    if bi >= 0 and e.bindings[bi].route == ev.lostRoute:
      e.lose(bi, result)
  of evReadiness:
    let bi = e.index(ev.readyBinding)
    if bi < 0 or not e.bindings[bi].usable:
      return
    e.bindings[bi].readiness = Opt.some(ev.readiness)
    if ev.readiness == rdReady:
      e.resumeReady(bi, result)
      if bi == e.catalogBinding:
        e.acquire(result)
  of evAnswer:
    e.onAnswer(ev.call, ev.reply, result)
  of evTimer:
    e.onTimer(ev.timer, result)

proc stop*(e: var Engine) =
  ## `_MODULE_destroy` began: route upkeep and retrieval stop, and no command
  ## follows (G437).
  e.stopped = true
  for b in e.bindings.mitems:
    b.state = rsStopped

# Event constructors, for the shell and the tests ------------------------------------

func established*(binding, key, route: string): Event =
  Event(kind: evEstablished, binding: binding, key: key, answer: raReady, route: route)

func establishRefused*(binding, key, reason: string): Event =
  Event(
    kind: evEstablished, binding: binding, key: key, answer: raRefused, reason: reason
  )

func establishLost*(binding, key: string): Event =
  Event(kind: evEstablished, binding: binding, key: key, answer: raLost)

func renewed*(binding, key: string): Event =
  Event(kind: evRenewed, binding: binding, key: key, answer: raReady)

func renewRefused*(binding, key, reason: string): Event =
  Event(kind: evRenewed, binding: binding, key: key, answer: raRefused, reason: reason)

func renewLost*(binding, key: string): Event =
  Event(kind: evRenewed, binding: binding, key: key, answer: raLost)

func routeLost*(binding, route: string): Event =
  Event(kind: evRouteLost, lostBinding: binding, lostRoute: route)

func readinessOf*(binding: string, r: Readiness): Event =
  Event(kind: evReadiness, readyBinding: binding, readiness: r)

func answered*(call: uint64, a: Answer): Event =
  Event(kind: evAnswer, call: call, reply: a)

func fired*(timer: uint64): Event =
  Event(kind: evTimer, timer: timer)

func sized*(size: uint64): Answer =
  Answer(kind: akValue, size: size)

func dataOf*(data: openArray[byte]): Answer =
  Answer(kind: akValue, data: @data)

func failureOf*(code: FailureCode, detail = ""): Answer =
  Answer(kind: akFailure, code: code, detail: detail)

func invocationError*(error: string): Answer =
  Answer(kind: akError, error: error)

func routeGone*(error = "the route is no longer usable"): Answer =
  Answer(kind: akRouteLost, error: error)

{.pop.}
