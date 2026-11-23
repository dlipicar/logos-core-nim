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
##
## **Turns** (G455): a resolution runs one turn of work at a time. When a turn
## is spent the engine returns `cmContinue`, and the shell posts
## `evContinue` for the next turn of the event loop, so routes, timers and
## other operations go on between turns, and operations alternate turn by
## turn. `cancel` drops an operation whose caller gave it up; a continue that
## arrives for an operation that is gone is ignored (Fable F3). What a finished
## or cancelled operation's run holds is freed a turn at a time, by continues
## of their own (`ReleaseOperation`), never at once.
##
## **The worker** (5-5-3; G446, G447): an archive is never held in memory. Its
## retrieval hands each `read_object` answer to the worker (`cmWork`), which
## appends it to the archive's spool file; at most `SpoolLag` pieces are
## unwritten, then the next read waits for the worker. Once `stat_object`
## gives the size, the retrieval takes that much of the inspections' share of
## the spool (`SpoolShareArchives` × `archive_bytes`), waiting first in, first
## out while it would pass it; the first always fits. With every byte written
## the worker gives the digest: a cache hit answers at once, a miss has the
## worker judge the file (`vcache.judge`). Either way the spool file is then
## deleted and its share released. The judgment crosses encoded (`jobs.nim`)
## and is decoded `DecodeTurnUnits` at a time, a turn each, by continues of
## their own (`DecodeOperation`); a small one at once. Nothing sees a judgment
## before it is whole, and one whose operation went is not finished but freed
## by the same turns. A spool file that cannot
## be written ends the retrieval: the archive is unavailable and the log names
## the cause (PM l.1094). An archive whose operation is gone (cancelled,
## answered) is dropped at its next step. The catalog's retrieval is kept in
## memory, bounded by `catalog_bytes`.

{.push raises: [], gcsafe.}

import std/[algorithm, sets, strutils, tables]
import results
import logos_sdk/base/hex
import ../package/[errors, records, resolver]
import ./[input, catalog, fetcher, vcache, driver, jobs]

export results, input, catalog, fetcher, vcache, driver, jobs

const
  ReleaseOperation* = 0'u64
    ## [IMPL; G455] the operation id of the continues that free finished and
    ## cancelled runs; no request has it
  DecodeOperation* = high(uint64)
    ## [IMPL; G447] the operation id of the continues that decode the worker's
    ## judgments; no request has it
  SpoolLag* = 4
    ## [IMPL; G447] the pieces of one retrieval handed to the worker and not yet
    ## written; the next `read_object` waits while this many are
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
    cmContinue
      ## [G455] report `evContinue` for `operation` in a later turn of the
      ## event loop, never in the drain that issued it (Fable F2)
    cmWork
      ## [G447] hand `job` to the worker; its answer, if it has one, is an
      ## `evWorked`

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
    of cmContinue:
      operation*: uint64
    of cmWork:
      job*: WorkerJob

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
    evContinue ## [G455] the next turn of `cmContinue`'s operation
    evWorked ## [G447] the worker's answer to a `cmWork`

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
    of evContinue:
      continued*: uint64
    of evWorked:
      worked*: WorkerResult

  JobWait = enum
    jwNone
    jwCall ## a call is outstanding; the timer is its deadline
    jwRoute ## waiting for the route; the timer bounds the wait
    jwReady ## waiting for `ready`; the timer bounds the wait
    jwBackoff ## the timer ends the back-off
    jwSpool ## [G447] `SpoolLag` pieces are not yet written
    jwShare ## [G446] the archive waits for its part of the inspections' share

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

  SpoolPhase = enum
    spWriting ## the retrieval runs
    spFinishing ## every piece is handed on; the digest is asked for
    spOpening ## the worker judges the file

  Spool = object
    ## [G446, G447] An archive's spool file, from the share's grant to its deletion. Its
    ## id is the retrieval job's.
    request: uint64
    source: PackageSource
    binding: int
    reserved: int64 ## its part of the inspections' share
    created: bool ## the first piece, which creates the file, is handed on
    unacked: int ## pieces handed to the worker and not yet written
    phase: SpoolPhase
    digest: Blake3Digest

  Decode = object ## [G447] A judgment being decoded on this thread, a turn at a time.
    request: uint64
    source: PackageSource
    digest: Blake3Digest
    estimate: int
      ## the cache's estimate, from the encoded lengths (`jobs.estimatedBytes`)
    decoding: Decoding

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
    releasing: seq[Driver] ## [G455] finished or cancelled, freed a turn at a time
    releaseQueued: bool ## a `ReleaseOperation` continue is issued
    turnWork: int64 ## [G455] the work of one resolution turn
    calls: Table[uint64, (int, uint64, int)] ## call id -> (binding, job, generation)
    timers: Table[uint64, TimerTarget]
    unknownLogged: HashSet[string]
    spools: Table[uint64, Spool] ## [G447] by the retrieval job's id
    shareUsed: int64 ## [G446] the spool's bytes the archives hold
    shareWaiters: seq[(int, uint64)] ## [G446] (binding, job), first in, first out
    decodes: seq[Decode] ## [G447] first in, first out
    dropping: seq[Decoding]
      ## [G447] judgments whose operation went while they were decoded, freed a turn at a time
    decodeQueued: bool ## a `DecodeOperation` continue is issued
    next: uint64
    started: bool
    stopped*: bool

# Construction -----------------------------------------------------------------------

proc initEngine*(
    input: PmInput,
    keptBytes: Opt[seq[byte]],
    keys: KeySource,
    platform = hostPlatform(),
    pathRules = hostPathRules(),
    turnWork = ResolverTurnWork,
): (Engine, seq[Command]) =
  ## The engine at `_init`, before any I/O: the catalog state from the kept
  ## file (`keptBytes`), and the log lines that start produced. The resolver
  ## limits are the input's (G399, planning's ruling of 2026-11-22): no caller
  ## can pass values the input does not hold. So are the operation bound
  ## (`operation_entries`, G477) and the LGX limits, G75's table scaled to
  ## `archive_bytes` (G453). `turnWork` is the work of one resolution turn
  ## (G455): `ResolverTurnWork`, a constant; the tests give others, which change
  ## no outcome.
  doAssert turnWork > 0, "a turn spends some work"
  let lgxLimits = scaledLimits(DefaultLgxLimits, input.limits.archiveBytes)
  var e = Engine(
    input: input,
    keys: keys,
    turnWork: turnWork,
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

func releasingRuns*(e: Engine): int =
  ## [G455] The finished or cancelled operations' runs still being freed.
  e.releasing.len

func spooled*(e: Engine): int =
  ## [G447] The spool files the engine holds: retrieved, being written, or judged.
  e.spools.len

func shareUsed*(e: Engine): int64 =
  ## [G446] The bytes of the inspections' share the spool files hold.
  e.shareUsed

func shareWaiting*(e: Engine): int =
  ## [G446] The retrievals waiting for their part of the share (stale entries included
  ## until reached).
  e.shareWaiters.len

func decoding*(e: Engine): int =
  ## [G447] The judgments being decoded a turn at a time.
  e.decodes.len

func droppingDecodes*(e: Engine): int =
  ## [G447] The dropped judgments still being freed a turn at a time.
  e.dropping.len

proc workerConfig*(e: Engine, spoolDir: string): WorkerConfig =
  ## [G447] What the shell starts the worker with: the inputs the cache judges by.
  workerConfig(
    spoolDir, e.input.trustBytes, e.cache.platform, e.cache.lgxLimits, e.cache.pathRules
  )

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
    if j.fetch.spooled and e.spools.getOrDefault(j.id).unacked >= SpoolLag:
      j.wait = jwSpool # [G447] an acknowledgement resumes it
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

proc retire(e: var Engine, d: sink Driver, cmds: var seq[Command]) =
  ## [G455] `d`'s run is freed by later turns, one at a time.
  e.releasing.add(d)
  if not e.releaseQueued:
    e.releaseQueued = true
    cmds.add(Command(kind: cmContinue, operation: ReleaseOperation))

proc releaseTurn(e: var Engine, cmds: var seq[Command]) =
  e.releaseQueued = false
  if e.releasing.len == 0:
    return
  if e.releasing[0].release():
    e.releasing.delete(0)
  if e.releasing.len > 0:
    e.releaseQueued = true
    cmds.add(Command(kind: cmContinue, operation: ReleaseOperation))

proc advanceRequest(e: var Engine, request: uint64, cmds: var seq[Command]) =
  let d = e.requests.getOrDefault(request)
  if d.isNil:
    return
  while true:
    var s = d.step()
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
      if d.counters.bound.len > 0:
        # [G477] So does the operation bound, with its value: the caller sees only
        # `package-unavailable` (PM l.1308-1309, l.1514).
        cmds.log(
          "a root operation stopped at the operation bound " & d.counters.bound & " (" &
            $e.input.limits.operationEntries & ")"
        )
      cmds.add(Command(kind: cmReply, request: request, outcome: move s.outcome))
      e.retire(d, cmds)
      return
    of dsTurn:
      # [G455] The turn's work is spent: the next one comes in a later turn of
      # the event loop.
      cmds.add(Command(kind: cmContinue, operation: request))
      return
    of dsRetained:
      # [G455] 5-3c resolves against no installed state, so no record is
      # asked for; 5-5 answers it from its worker (G448).
      d.supplyRetained(s.record, Result[void, string].err("no installed state"))
      continue
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
          source.objectLocator,
          e.input.limits.archiveBytes,
          e.input.limits.readDeadlineMs,
          spooled = true,
        ),
      )
      e.enqueue(bi, job, cmds)
      return

# Spool files and the worker (G446, G447) ----------------------------------------------

proc work(cmds: var seq[Command], job: sink WorkerJob) =
  cmds.add(Command(kind: cmWork, job: job))

func shareCap(e: Engine): int64 =
  ## [IMPL; G446] The inspections' share of the spool.
  int64(SpoolShareArchives) * e.input.limits.archiveBytes

proc supplyTo(
    e: var Engine,
    request: uint64,
    source: PackageSource,
    x: sink Inspection,
    cmds: var seq[Command],
) =
  ## The archive's inspection, to its operation if that is still running.
  let d = e.requests.getOrDefault(request)
  if d.isNil:
    return
  d.supply(source, x)
  e.advanceRequest(request, cmds)

proc reserve(e: var Engine, bi: int, size: int64) =
  ## [G446] The head job's archive takes `size` bytes of the share; its first piece
  ## creates its spool file.
  template j(): untyped =
    e.bindings[bi].jobs[0]

  e.shareUsed += size
  e.spools[j.id] =
    Spool(request: j.request, source: j.source, binding: bi, reserved: size)

proc append(e: var Engine, file: uint64, chunk: sink string, cmds: var seq[Command]) =
  ## [G447] A piece for the worker, the first creating the spool file.
  var sp = addr e.spools.mgetOrPut(file, Spool())
  var job = WorkerJob(kind: wjAppend, file: file, chunk: chunk)
  if not sp.created:
    sp.created = true
    job.first = true
    job.name = spoolName(sp.request, file)
  inc sp.unacked
  cmds.work(job)

proc fits(e: Engine, size: int64): bool =
  e.shareUsed == 0 or e.shareUsed + size <= e.shareCap

proc grantShare(e: var Engine, cmds: var seq[Command]) =
  ## [G446] The waiting retrievals that now fit, first in, first out.
  while e.shareWaiters.len > 0 and not e.stopped:
    let (bi, id) = e.shareWaiters[0]
    template j(): untyped =
      e.bindings[bi].jobs[0]

    if e.bindings[bi].jobs.len == 0 or j.id != id or j.wait != jwShare:
      e.shareWaiters.delete(0) # it ended meanwhile
      continue
    let size = int64(j.fetch.size.get(0))
    if not e.fits(size):
      return
    e.shareWaiters.delete(0)
    j.wait = jwNone
    e.reserve(bi, size)
    let step =
      if j.fetch.finished:
        FetchStep(kind: skDone)
      else:
        j.fetch.resume()
    e.apply(bi, step, jwNone, cmds)

proc unspool(e: var Engine, file: uint64, cmds: var seq[Command]) =
  ## [G446] The archive's spool file is deleted and its share released.
  var sp: Spool
  if not e.spools.pop(file, sp):
    return
  cmds.work(WorkerJob(kind: wjDrop, file: file))
  e.shareUsed -= sp.reserved
  e.grantShare(cmds)

proc spoolFailed(failure: string): string =
  "the archive could not be written to the spool on the state directory's file system: " &
    failure

proc finishDecode(e: var Engine, dc: sink Decode, cmds: var seq[Command]) =
  ## [G447] A decoded judgment: admitted to the cache and supplied.
  var o = dc.decoding.take()
  let x = e.cache.admit(dc.digest, o, dc.estimate)
  e.supplyTo(dc.request, dc.source, x, cmds)

proc queueDecodeTurn(e: var Engine, cmds: var seq[Command]) =
  if (e.decodes.len > 0 or e.dropping.len > 0) and not e.decodeQueued:
    e.decodeQueued = true
    cmds.add(Command(kind: cmContinue, operation: DecodeOperation))

proc decodeTurn(e: var Engine, cmds: var seq[Command]) =
  ## [G447] One turn of decoding: at most `DecodeTurnUnits` entries and contracts, decoded
  ## or freed. A judgment whose operation went is not finished: what it holds is freed in
  ## turns (Fable's D1 condition 5; its archive is no other operation's, which retrieves
  ## and judges its own). Nothing sees a judgment before it is whole.
  e.decodeQueued = false
  var budget = DecodeTurnUnits
  while budget > 0:
    if e.dropping.len > 0:
      if e.dropping[0].releaseSome(budget):
        e.dropping.delete(0)
      continue
    if e.decodes.len == 0:
      break
    if e.decodes[0].request notin e.requests:
      var dc = move e.decodes[0] # its operation is gone
      e.decodes.delete(0)
      e.dropping.add(move dc.decoding)
      continue
    if not e.decodes[0].decoding.decodeSome(budget):
      break
    var dc = move e.decodes[0]
    e.decodes.delete(0)
    e.finishDecode(dc, cmds)
  e.queueDecodeTurn(cmds)

proc spoolEnds(e: var Engine, file: uint64, reason: string, cmds: var seq[Command]) =
  ## [G446] A spool file failed while its retrieval runs: the retrieval ends now.
  let bi = e.spools.getOrDefault(file).binding
  if e.bindings[bi].jobs.len == 0 or e.bindings[bi].jobs[0].id != file or
      not e.bindings[bi].active:
    return
  template j(): untyped =
    e.bindings[bi].jobs[0]

  if j.call != 0:
    e.calls.del(j.call) # its answer is ignored
    j.call = 0
  j.timer = 0
  j.wait = jwNone
  let step = j.fetch.abandon(reason)
  e.apply(bi, step, jwNone, cmds)

proc onWorked(e: var Engine, r: sink WorkerResult, cmds: var seq[Command]) =
  ## [G447] The worker's answer about spool file `r.file`; one the engine dropped is
  ## ignored.
  if r.file notin e.spools:
    return
  template sp(): untyped =
    e.spools.mgetOrPut(r.file, Spool())
      # present: checked above, and read before `unspool`

  case r.kind
  of wrAppended:
    dec sp.unacked
    if sp.phase != spWriting:
      return
    let bi = sp.binding
    if r.failure.len > 0:
      cmds.log(spoolFailed(r.failure))
      e.spoolEnds(r.file, "the archive could not be spooled", cmds)
      return
    if e.bindings[bi].jobs.len > 0 and e.bindings[bi].jobs[0].id == r.file and
        e.bindings[bi].jobs[0].wait == jwSpool and sp.unacked < SpoolLag:
      e.bindings[bi].jobs[0].wait = jwNone
      let step = e.bindings[bi].jobs[0].fetch.resume()
      e.apply(bi, step, jwNone, cmds)
  of wrDigest:
    let (request, source) = (sp.request, sp.source)
    if request notin e.requests:
      e.unspool(r.file, cmds)
      return
    if r.failure.len > 0:
      cmds.log(spoolFailed(r.failure))
      e.unspool(r.file, cmds)
      e.supplyTo(
        request,
        source,
        Inspection(kind: ikUnavailable, reason: "the archive could not be spooled"),
        cmds,
      )
      return
    let hit = e.cache.lookup(r.digest, e.input.trust)
    if hit.isSome:
      e.unspool(r.file, cmds)
      e.supplyTo(request, source, hit.get, cmds)
      return
    sp.digest = r.digest
    sp.phase = spOpening
    cmds.work(WorkerJob(kind: wjOpen, file: r.file))
  of wrOpened:
    let (request, source, digest) = (sp.request, sp.source, sp.digest)
    e.unspool(r.file, cmds)
    let units = r.opened.units
    if request notin e.requests:
      if units > DecodeTurnUnits:
        e.dropping.add(initDecoding(move r.opened)) # freed in turns, as a dropped decode
        e.queueDecodeTurn(cmds)
      return
    let estimate = r.opened.estimatedBytes
    var dc = Decode(
      request: request,
      source: source,
      digest: digest,
      estimate: estimate,
      decoding: initDecoding(move r.opened),
    )
    if e.decodes.len == 0 and units <= DecodeTurnUnits:
      var budget = DecodeTurnUnits
      doAssert dc.decoding.decodeSome(budget)
      e.finishDecode(dc, cmds)
      return
    e.decodes.add(move dc)
    e.queueDecodeTurn(cmds)

proc deliver(
    e: var Engine, bi: int, job: Job, step: FetchStep, cmds: var seq[Command]
) =
  if job.catalog:
    e.catalogDone(step, cmds)
    return
  if job.fetch.spooled:
    case step.kind
    of skDone:
      # [G447] Every piece is handed on: the worker gives the digest once they are
      # written.
      if job.request notin e.requests or job.id notin e.spools:
        e.unspool(job.id, cmds)
        e.supplyTo(
          job.request,
          job.source,
          Inspection(kind: ikUnavailable, reason: "the archive was not spooled"),
          cmds,
        )
        return
      if not e.spools.getOrDefault(job.id).created:
        e.append(job.id, "", cmds) # an empty archive: its file still exists
      e.spools.mgetOrPut(job.id, Spool()).phase = spFinishing
      cmds.work(WorkerJob(kind: wjFinish, file: job.id))
    of skUnavailable:
      e.unspool(job.id, cmds)
      e.supplyTo(
        job.request,
        job.source,
        Inspection(kind: ikUnavailable, reason: step.reason),
        cmds,
      )
    else:
      discard
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
  ## [G405] One root operation; its outcome is a later `cmReply`. A request id
  ## in use, `ReleaseOperation`'s or `DecodeOperation`'s, is refused
  ## `invalid-request`.
  if e.stopped:
    return
  let reserved = request == ReleaseOperation or request == DecodeOperation
  if reserved or request in e.requests:
    result.add(
      Command(
        kind: cmReply,
        request: request,
        outcome: Result[Resolution, PackageError].err(
          packageError(
            pecInvalidRequest,
            if reserved: "the request id is reserved" else: "the request id is in use",
          )
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
  e.requests[request] = initDriver(
    e.catalog.inUse.get.entries,
    e.input.trust,
    e.input.resolverLimits,
    root,
    e.turnWork,
    Opt.some(e.input.limits.operationEntries),
  )
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
  let stat = e.bindings[bi].jobs[0].fetch.pending.kind == ckStat
  let step = e.bindings[bi].jobs[0].fetch.onAnswer(a)
  template j(): untyped =
    e.bindings[bi].jobs[0]

  if j.fetch.spooled and step.kind in {skCall, skDone}:
    if stat:
      # [G446] The size is known: the archive's part of the share, or a wait for it.
      let size = int64(j.fetch.size.get(0))
      if e.shareWaiters.len > 0 or not e.fits(size):
        j.wait = jwShare
        e.shareWaiters.add((bi, j.id))
        return
      e.reserve(bi, size)
    elif j.fetch.hasChunk and j.id in e.spools:
      # [G447] The piece goes to the worker, never kept here.
      e.append(j.id, j.fetch.takeChunk(), cmds)
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
    of jwNone, jwSpool, jwShare:
      discard

proc handle*(e: var Engine, ev: sink Event): seq[Command] =
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
  of evWorked:
    e.onWorked(move ev.worked, result)
  of evContinue:
    if ev.continued == ReleaseOperation:
      e.releaseTurn(result)
    elif ev.continued == DecodeOperation:
      e.decodeTurn(result)
    else:
      # [G455; Fable F3] An operation that is gone (done, cancelled) is not
      # advanced.
      e.advanceRequest(ev.continued, result)

proc cancel*(e: var Engine, request: uint64): seq[Command] =
  ## [G455; Fable F3] The caller gave the operation up: it takes no more turns
  ## and nothing answers it; its run is freed by later turns. Its retrieval, if
  ## one is queued behind another or waits for the share (G446), is dropped
  ## too; one that has started ends as it would, its answer is ignored, and its
  ## spool file is deleted (G447). A later `evContinue` for it is ignored.
  if e.stopped or request notin e.requests:
    return
  let d = e.requests.getOrDefault(request)
  e.requests.del(request)
  e.retire(d, result)
  for b in e.bindings.mitems:
    var i = b.jobs.high
    while i >= 1:
      if not b.jobs[i].catalog and b.jobs[i].request == request:
        b.jobs.delete(i)
      dec i
  for bi in 0 ..< e.bindings.len:
    if e.bindings[bi].jobs.len > 0 and not e.bindings[bi].jobs[0].catalog and
        e.bindings[bi].jobs[0].request == request and
        e.bindings[bi].jobs[0].wait == jwShare:
      e.bindings[bi].jobs[0].wait = jwNone
      e.apply(
        bi,
        FetchStep(kind: skUnavailable, reason: "the operation is cancelled"),
        jwNone,
        result,
      )

proc stop*(e: var Engine): seq[Command] =
  ## `_MODULE_destroy` began: route upkeep, retrieval and resolution stop, and
  ## no command follows (G437). Each root operation still running, sliced or
  ## waiting for a retrieval, is answered `package-unavailable` here, in
  ## request order, and its driver dropped (G405, G455); so are the runs being
  ## released, at once, since the module is going away.
  if e.stopped:
    return
  e.stopped = true
  for b in e.bindings.mitems:
    b.state = rsStopped
  var pending: seq[uint64]
  for id in e.requests.keys:
    pending.add(id)
  pending.sort()
  for id in pending:
    result.add(
      Command(
        kind: cmReply,
        request: id,
        outcome: Result[Resolution, PackageError].err(
          packageError(pecPackageUnavailable, "the Package Manager is stopping")
        ),
      )
    )
  e.requests.clear()
  e.releasing.setLen(0)
  e.releaseQueued = false
  # [G447] The shell stops the worker, which deletes the spool files it holds.
  e.spools.clear()
  e.shareWaiters.setLen(0)
  e.shareUsed = 0
  e.decodes.setLen(0)
  e.dropping.setLen(0)
  e.decodeQueued = false

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

func continued*(operation: uint64): Event =
  Event(kind: evContinue, continued: operation)

func worked*(r: sink WorkerResult): Event =
  Event(kind: evWorked, worked: r)

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
