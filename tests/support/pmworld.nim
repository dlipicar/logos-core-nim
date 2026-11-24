## A scripted world for the Package Manager's engine (Tier 5 step 5-3b): it
## keeps the commands the engine issues, answers calls from a table of
## objects, and feeds events back. The engine does no I/O, so this is the
## whole of its environment in `test_pm_fetch` and `test_pm_driver`.
##
## [G447] The worker's jobs (`cmWork`) run here, inline, once the command that
## issued them is taken, in order, with their answers fed back as events: the
## shell's worker thread runs the same `runJob`. Each world spools into a
## directory of its own below `<tmp>/lcn-pmworld-<pid>`, removed at exit.

import std/[exitprocs, os, sequtils, tables]
import ../../src/logos_core/durable
import ../../src/logos_core/package/resolver
import ../../src/logos_core/pm/engine
import ./pmfixture

when defined(posix):
  import ../../src/logos_core/pm/store

export engine, tables

type
  KeyCounter* = ref object
    n*: int

  FakeClock* = ref object ## [G449] the world's monotonic milliseconds
    ms*: int64

  World* = object
    e*: Engine
    queue*: seq[Command] ## issued and not yet taken
    logs*: seq[string]
    kept*: seq[seq[byte]]
    replies*: seq[Command]
    answers*: seq[Command] ## [G449] `cmAnswer`s, in order
    keys*: KeyCounter
    clock*: FakeClock
    continues*: seq[uint64]
      ## [G455] `cmContinue`s issued and not yet run, oldest first: each runs
      ## as a later event (`turn`), as the shell's own `callSoon` runs it
    worker*: WorkerState
    spoolDir*: string ## [G447] the world's own
    work*: seq[WorkerJob] ## [G447] issued and not yet run
    working: bool
    holdWork*: bool ## the tests' own: leave `work` for them to run (`runWork`)
    jobs*: seq[WorkerJobKind] ## every job run, in order

var worldDirs = 0

proc worldRoot(): string =
  getTempDir() / ("lcn-pmworld-" & $getCurrentProcessId())

proc removeWorlds() {.noconv.} =
  try:
    removeDir(worldRoot())
  except OSError:
    discard

proc spoolDirOf(): string =
  ## A fresh spool directory for one world.
  if worldDirs == 0:
    addExitProc(removeWorlds)
  inc worldDirs
  result = worldRoot() / $worldDirs
  doAssert ensurePrivateDir(result).isOk # 0700, as the shell's `install/spool/`

proc emit*(w: var World, cmds: seq[Command])

proc runOne*(w: var World): bool =
  ## [G447] Runs the oldest worker job and feeds back its answer; false when none waits.
  if w.work.len == 0:
    return false
  var job = w.work[0]
  w.work.delete(0)
  w.jobs.add(job.kind)
  let r = w.worker.runJob(job, nil)
  if r.isSome:
    w.emit(w.e.handle(worked(r.get)))
  true

proc runWork*(w: var World) =
  ## Runs worker jobs until none waits.
  while w.runOne():
    discard

proc emit*(w: var World, cmds: seq[Command]) =
  for c in cmds:
    case c.kind
    of cmLog:
      w.logs.add(c.text)
    of cmWriteKept:
      w.kept.add(c.kept)
    of cmReply:
      w.replies.add(c)
    of cmAnswer:
      w.answers.add(c)
    of cmContinue:
      w.continues.add(c.operation)
    of cmWork:
      w.work.add(c.job)
    else:
      w.queue.add(c)
  if w.holdWork or w.working:
    return
  w.working = true
  w.runWork()
  w.working = false

proc handle*(w: var World, ev: Event) =
  w.emit(w.e.handle(ev))

proc turn*(w: var World): bool =
  ## [G455] Runs the oldest pending continue; false when none is pending.
  if w.continues.len == 0:
    return false
  let op = w.continues[0]
  w.continues.delete(0)
  w.handle(continued(op))
  true

proc take*(w: var World, kinds: set[CommandKind]): Command =
  for i, c in w.queue:
    if c.kind in kinds:
      w.queue.delete(i)
      return c
  doAssert false, "no command of " & $kinds & " in " & $w.queue.mapIt(it.kind)

proc has*(w: World, kinds: set[CommandKind]): bool =
  w.queue.anyIt(it.kind in kinds)

proc count*(w: World, kinds: set[CommandKind]): int =
  w.queue.countIt(it.kind in kinds)

proc timerFor*(w: var World, ms: uint32): uint64 =
  ## The newest timer of `ms`, taken.
  for i in countdown(w.queue.high, 0):
    if w.queue[i].kind == cmTimer and w.queue[i].ms == ms:
      let id = w.queue[i].timer
      w.queue.delete(i)
      return id
  doAssert false, "no timer of " & $ms & " ms"

proc newWorld*(
    doc: seq[byte],
    bindings: openArray[(string, string)] = [("main", "storage_module")],
    kept = Opt.none(seq[byte]),
    limits = Opt.none(LcnPmLimits),
    trust = defaultTrust(),
    resolverLimits = MaxResolverLimits,
    turnWork = ResolverTurnWork,
    spoolBudgetArchives = SpoolBudgetArchives,
): World =
  let input = decodePmInput(
    pmValue(
      trust,
      doc,
      bindings,
      limits = limits,
      resolverLimits = limitsValue(resolverLimits),
    ).encode.get
  ).get
  let counter = KeyCounter()
  let keys: KeySource = proc(): string {.gcsafe, raises: [].} =
    inc counter.n
    "key-" & $counter.n
  let fake = FakeClock()
  let clock: Clock = proc(): int64 {.gcsafe, raises: [].} =
    fake.ms
  let (e, cmds) = initEngine(
    input,
    kept,
    keys,
    linuxHost,
    pathRules = PathRules(),
    turnWork = turnWork,
    clock = clock,
    spoolBudgetArchives = spoolBudgetArchives,
  )
  result = World(e: e, keys: counter, clock: fake, spoolDir: spoolDirOf())
  discard result.worker.runJob(
    WorkerJob(kind: wjStart, config: result.e.workerConfig(result.spoolDir)), nil
  )
  result.emit(cmds)

when defined(posix):
  proc attachStore*(w: var World, store: var InstalledStore) =
    ## [5-5-4] The installed state `store` opened: the engine's snapshot is built from it,
    ## and its file half goes to the inline worker, as the shell's open does.
    w.e.setSnapshot(snapshotOf(store))
    var config = w.e.workerConfig(w.spoolDir)
    config.store = store.handOver()
    config.hasStore = true
    discard w.worker.runJob(WorkerJob(kind: wjStart, config: config), nil)

proc bringUp*(w: var World, binding = "main", route = "route-1", ready = true) =
  ## Answers the binding's establishment and its readiness.
  let c = w.take({cmEstablish})
  doAssert c.binding == binding, c.binding
  w.handle(established(binding, c.key, route))
  discard w.take({cmWatch})
  if ready:
    w.handle(readinessOf(binding, rdReady))

proc serve*(
    w: var World, objects: Table[seq[byte], seq[byte]], calls: var seq[Command]
) =
  ## Answers every call the engine makes, from `objects`, and runs every
  ## continue, until neither is left.
  while w.has({cmStat, cmRead}) or w.continues.len > 0:
    if not w.has({cmStat, cmRead}):
      discard w.turn()
      continue
    let c = w.take({cmStat, cmRead})
    calls.add(c)
    let data = objects.getOrDefault(c.locator, @[])
    let present = c.locator in objects
    let a =
      if not present:
        failureOf(fcUnavailable)
      elif c.kind == cmStat:
        sized(uint64(data.len))
      else:
        dataOf(data[int(c.offset) ..< int(c.offset) + int(c.length)])
    w.handle(answered(c.call, a))

proc keptFor*(doc: seq[byte]): Opt[seq[byte]] =
  var (s, _) = initCatalogState(pinOf(doc), defaultLimits(), Opt.none(seq[byte]))
  s.offer(doc).get.keptBytes
