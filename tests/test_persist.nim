## Persistent Runtime state across engine restarts (`runtime/engine.nim`,
## `runtime/store.nim`; DECISIONS I82): every change is written before it is
## exposed or its attempt runs, revisions after a restart pass every earlier
## one, a failed write holds changes back without delaying withdrawal, and
## identities, intent, origins and state assignments stay with their
## instances. Static modules only: the route fixture's consumer and meter,
## plus `keeper_module`, which records the state directory it is given and
## what the store shows when it starts.

import std/[algorithm, atomics, monotimes, os, sequtils, strutils, times, typedthreads]
when defined(posix):
  import std/posix
import unittest2
import ../src/logos_core/runtime/[engine, store]
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, surface]
import ../src/logos_core/iface/common_types
import ./support/[kitbuild, kitruntime, withoutloader]
import ./kit/meter_impl
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "persist" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

# The keeper module --------------------------------------------------------------------

var
  keeperInits, keeperDestroys: Atomic[int]
  seenDir: array[1024, char] ## the state directory of the latest initialization
  seenDirLen: Atomic[int]
  probe: array[1024, char] ## a store file `keeper` reads at initialization
  probeLen: Atomic[int]
  probeLoaded: Atomic[int]
    ## at the latest initialization: keeper instances the store showed `loaded`
    ## with `requested` intent, or -1

proc keeperName(): cstring {.cdecl.} =
  "keeper_module"

proc keeperInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl.} =
  {.cast(gcsafe).}:
    let dir = (if input.stateDir == nil: "" else: $input.stateDir)
    for i, c in dir:
      seenDir[i] = c
    seenDirLen.store(dir.len)
    if dir.len > 0:
      try:
        let f = open(dir / "inits", fmAppend)
        f.write("init\n")
        f.close()
      except CatchableError:
        discard
    if probeLen.load > 0:
      var path = newString(probeLen.load)
      for i in 0 ..< path.len:
        path[i] = probe[i]
      var n = -1
      try:
        let text = readFile(path)
        let snap = decodeSnapshot(text.toOpenArrayByte(0, text.high))
        if snap.isOk:
          n = 0
          for s in snap.get.instances:
            if s.record.module == "keeper_module" and s.state == msLoaded and
                s.intent == inRequested:
              inc n
      except CatchableError:
        discard
      probeLoaded.store(n)
  keeperInits += 1
  outContext[] = cast[ptr LogosModuleContext](allocShared0(16))

proc keeperDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  keeperDestroys += 1
  deallocShared(module)

proc keeperTable(): seq[(string, pointer)] =
  @[
    ("logos_keeper_module_MODULE_name", cast[pointer](keeperName)),
    ("logos_keeper_module_MODULE_init", cast[pointer](keeperInit)),
    ("logos_keeper_module_MODULE_destroy", cast[pointer](keeperDestroy)),
  ]

func keeper(assignment = Opt.none(string)): ModuleRecord =
  ModuleRecord(
    module: "keeper_module",
    strategy: stDirectStatic,
    binding: "keeper",
    stateAssignment: assignment,
  )

proc lastDir(): string =
  result = newString(seenDirLen.load)
  for i in 0 ..< result.len:
    result[i] = seenDir[i]

proc probeStore(path: string) =
  for i, c in path:
    probe[i] = c
  probeLen.store(path.len)

# Persistent engines ---------------------------------------------------------------------

var bases = 0

proc freshBase(): string =
  inc bases
  work / ("p" & $bases)

proc storeOf(base: string): string =
  base / "store"

proc pconfig(base: string, policy = allowAll(), budget = 0'u64): EngineConfig =
  result = config(policy, @[checkStaticRegistration("keeper", keeperTable()).tryGet])
  result.runtimeInstanceId = ""
  result.storeDir = Opt.some(storeOf(base))
  result.stateRoot = Opt.some(base / "state")
  result.revisionBudget = budget

proc openAt(base: string, policy = allowAll(), budget = 0'u64): Engine =
  openEngine(pconfig(base, policy, budget)).tryGet

proc stored(base: string): Snapshot =
  let text = readFile(storeOf(base) / SnapshotName)
  decodeSnapshot(text.toOpenArrayByte(0, text.high)).tryGet

proc storedOf(base, instance: string): StoredInstance =
  for s in stored(base).instances:
    if s.instance == instance:
      return s
  check false

proc restart(e: var Engine, base: string, policy = allowAll()) =
  e.finish()
  e = openAt(base, policy)

proc writeSnapshot(base: string, snap: Snapshot) =
  var (s, _) = openStore(storeOf(base)).tryGet
  s.write(snap).tryGet
  s.close()

proc setMode(dir: string, mode: int) =
  when defined(posix):
    doAssert chmod(cstring(dir), Mode(mode)) == 0

proc asRoot(): bool =
  when defined(posix):
    getuid() == 0
  else:
    true

proc diagnosed(e: Engine, text: string): bool =
  e.diagnostics.anyIt(text in it)

var startReply: Atomic[int] ## the state `startOn` got, or -1; -2 while it waits

proc startOn(arg: (Engine, string)) {.thread.} =
  let r = arg[0].start(arg[1])
  startReply.store(
    if r.isOk:
      ord(r.get.state)
    else:
      -1
  )

func prefixOf(id: string): string =
  ## The random part of a Runtime-assigned name: `m-<32 hex>-<n>`.
  id[2 .. 33]

const
  Unclean = "the Runtime ended without completing shutdown"
  NotPersisted = "the execution state could not be persisted"

# Tests ----------------------------------------------------------------------------------

suite "run.persist: execution state across a restart (RUNTIME §9.3 l.3500-3507)":
  test "[RUN-0631] [RUN-0630] a change is in the store before it is exposed or its attempt runs":
    let base = freshBase()
    var e = openAt(base)
    let v = e.create(keeper(), "k1").tryGet
    check storedOf(base, "k1").revision == v.execution.revision
    check storedOf(base, "k1").state == msUnloaded
    # The attempt starts only once the store shows it accepted.
    probeStore(storeOf(base) / SnapshotName)
    let s = e.start("k1").tryGet
    probeLen.store(0)
    check probeLoaded.load == 1
    check s.state == msReady
    check storedOf(base, "k1").state == msReady
    check storedOf(base, "k1").revision == s.execution.revision
    check storedOf(base, "k1").intent == inRequested
    let t = e.stop("k1").tryGet
    check storedOf(base, "k1").state == msUnloaded
    check storedOf(base, "k1").revision == t.execution.revision
    check storedOf(base, "k1").intent == inStopped
    # Every exposed change of k1: positive revisions, none past the store's.
    let last = storedOf(base, "k1").revision
    var previous = 0'u64
    for c in e.changes.withoutLoader:
      check c.view.execution.revision > previous
      check c.view.execution.revision <= last
      previous = c.view.execution.revision
    e.finish()

  test "[RUN-0632] after a restart every revision passes the values exposed before, a restored older store included":
    let base = freshBase()
    var e = openAt(base)
    discard e.create(keeper(), "k1").tryGet
    let older = readFile(storeOf(base) / SnapshotName)
    discard e.start("k1").tryGet
    discard e.stop("k1").tryGet
    var exposed = 0'u64
    for c in e.changes:
      exposed = max(exposed, c.view.execution.revision)
    e.restart(base)
    let first = e.view("k1").tryGet.execution.revision
    check first > exposed
    discard e.start("k1").tryGet
    for c in e.changes:
      exposed = max(exposed, c.view.execution.revision)
    let epoch2 = stored(base).epoch
    e.finish()
    # [IMPL] A store restored from a backup: the wall clock carries the epoch
    # past every run since, once it has passed theirs (docs/HOST-CONFIG.md).
    check waitUntil(
      proc(): bool =
        uint64(getTime().toUnix) > epoch2
    )
    writeFile(storeOf(base) / SnapshotName, older)
    e = openAt(base)
    check e.view("k1").tryGet.execution.revision > exposed
    e.finish()

  test "[RUN-0633] [IMPL] a failed write holds changes back and refuses new attempts, and withdrawal does not wait":
    if asRoot():
      skip()
    else:
      let base = freshBase()
      var e = openAt(base)
      let (c, rc) = e.startClient("c")
      discard c
      let m = e.started(meter(), "m")
      let route = rc.routeId("r")
      let k3 = e.started(keeper(), "k3")
      discard e.create(keeper(), "k2").tryGet
      let k2 = e.view("k2").tryGet
      let entries = e.changes.len
      let destroyedBefore = destroyed.load
      setMode(storeOf(base), 0o500)
      # A new attempt is refused, and nothing changes.
      let r = e.start("k2")
      check r.isErr and r.error.code == ecModule
      check e.view("k2").tryGet.execution == k2.execution
      check e.changes.len == entries
      check e.diagnosed(NotPersisted)
      # A stop still withdraws and cleans at once; its answer is MODULE_ERROR.
      let s = e.stop("m")
      check s.isErr and s.error.code == ecModule and NotPersisted in s.error.message
      check destroyed.load == destroyedBefore + 1
      check e.routes.filterIt(it.route == route)[0].state.kind ==
        LogosNSRuntimeControlRouteStateKind.Failed
      # Observers see the last written state.
      check e.view("m").tryGet.state == msReady
      check e.view("m").tryGet.execution == m.execution
      # A reported failure still takes effect.
      check e.reportFailure("k3", k3.attempt).isOk
      check e.view("k3").tryGet.state == msReady
      check e.changes.len == entries
      # The store comes back: the next write, at most a second later, exposes
      # each change held back once.
      setMode(storeOf(base), 0o700)
      check waitUntil(
        proc(): bool =
          e.view("m").tryGet.state == msUnloaded
      )
      check e.view("k3").tryGet.state == msError
      let after = e.changes[entries ..^ 1]
      check after.len == 2
      check after.mapIt(it.view.instance).toSeq.len == 2
      check e.diagnosed("persisted again")
      check e.start("k2").tryGet.state == msReady
      # A shutdown whose final state cannot be written says so.
      setMode(storeOf(base), 0o500)
      e.requestShutdown()
      let w = e.awaitShutdown()
      check w.isErr and w.error.code == ecModule and NotPersisted in w.error.message
      setMode(storeOf(base), 0o700)
      check e.close()
      # The last state written showed k2 ready: an unclean end (G193).
      e = openAt(base)
      check e.view("k2").tryGet.state == msError
      check e.view("k2").tryGet.failure.get.reason == Unclean
      e.finish()

  test "[RUN-0631] [RUN-0633] [IMPL] ready is written before it is exposed; until then the instance stays loaded":
    if asRoot():
      skip()
    else:
      let base = freshBase()
      var e = openAt(base)
      discard e.create(slow(), "s").tryGet
      slowGate.store(true)
      startReply.store(-2)
      var t: Thread[(Engine, string)]
      createThread(t, startOn, (e, "s"))
      check waitUntil(
        proc(): bool =
          e.view("s").tryGet.state == msLoaded
      )
      setMode(storeOf(base), 0o500)
      slowGate.store(false)
      check waitUntil(
        proc(): bool =
          e.diagnosed(NotPersisted)
      )
      sleep(300)
      check e.view("s").tryGet.state == msLoaded
      check startReply.load == -2
      setMode(storeOf(base), 0o700)
      joinThread(t)
      check startReply.load == ord(msReady)
      check storedOf(base, "s").state == msReady
      e.finish()

  test "[RUN-0633] [IMPL] the startup deadline ends an attempt whose ready cannot be written":
    if asRoot():
      skip()
    else:
      let base = freshBase()
      var cfg = pconfig(base)
      cfg.startupDeadline = initDuration(milliseconds = 1500)
      var e = openEngine(cfg).tryGet
      discard e.create(slow(), "s").tryGet
      slowGate.store(true)
      startReply.store(-2)
      var t: Thread[(Engine, string)]
      createThread(t, startOn, (e, "s"))
      check waitUntil(
        proc(): bool =
          e.view("s").tryGet.state == msLoaded
      )
      setMode(storeOf(base), 0o500)
      slowGate.store(false)
      joinThread(t)
      check startReply.load == -1 # MODULE_ERROR: the failure is not written
      setMode(storeOf(base), 0o700)
      # `error` comes before the abandoned attempt's cleanup ends; a start
      # until then is NOT_READY.
      check waitUntil(
        proc(): bool =
          e.view("s").tryGet.state == msError and not e.cleanupPending("s")
      )
      check e.view("s").tryGet.failure.get.kind == fkStartupTimeout
      check e.start("s").tryGet.state == msReady
      e.finish()

  test "[RUN-0633] [IMPL] an exhausted revision refuses new attempts, not their withdrawal":
    let base = freshBase()
    var e = openAt(base, budget = 4)
    discard e.create(keeper(), "k").tryGet
    check e.start("k").tryGet.state == msReady
    check e.stop("k").tryGet.state == msUnloaded
    let r = e.start("k")
    check r.isErr and r.error.code == ecModule and "exhausted" in r.error.message
    check e.view("k").tryGet.execution.intent == inStopped
    # A new start brings a new epoch, and the budget is whole again.
    e.restart(base)
    check e.start("k").tryGet.state == msReady
    e.finish()

  test "[IMPL-DECISION G160] [RUN-0258] [RUN-0486] [RUN-0919] [RUN-0920] [RUN-0921] [RUN-0924] a configured instance keeps its id while its declaration facts are equal":
    let base = freshBase()
    var old = keeper(Opt.some("gone-state"))
    var k1 = keeper()
    k1.requestedPermissions = @[
      RequestedPermission(
        permission: "net", constraints: encodeCbor(cbor(1'u64)), reason: Opt.some("a")
      )
    ]
    writeSnapshot(
      base,
      Snapshot(
        runtimeInstanceId: "rt-g160",
        epoch: 7,
        instances: @[
          StoredInstance(
            instance: "k1",
            record: k1,
            state: msUnloaded,
            revision: (7'u64 shl 32) + 3,
            intent: inUninitialized,
          )
        ],
        retired: @[RetiredId(instance: "gone", stateAssignment: Opt.some("gone-state"))],
      ),
    )
    let before = storedOf(base, "k1").record
    proc boot(more: seq[BootstrapInstance]): Result[InstanceView, EngineError] =
      let e = openAt(base)
      result = e.bootstrap(
        @[BootstrapInstance(instance: "orch", record: client())] & more, "orch"
      )
      e.finish()

    # A retired id cannot come back.
    let gone = boot(@[BootstrapInstance(instance: "gone", record: keeper())])
    check gone.isErr and gone.error.code == ecInvalidParams
    check "gone was retired" in gone.error.message
    # Nor can the assignment a retired instance keeps.
    let held = boot(@[BootstrapInstance(instance: "k9", record: old)])
    check held.isErr and held.error.code == ecInvalidParams
    check "held by gone" in held.error.message
    # Other facts: refused, naming the instance; the retained record stays.
    var changed = k1
    changed.requires =
      @[ProviderRequirement(contract: meterRoot, cardinality: cardSingle)]
    let differs = boot(@[BootstrapInstance(instance: "k1", record: changed)])
    check differs.isErr and differs.error.code == ecInvalidParams
    check "instance k1" in differs.error.message
    check recordBytes(storedOf(base, "k1").record) == recordBytes(before)
    # Equal facts: the same instance, which takes the configured reason.
    var reason = k1
    reason.requestedPermissions[0].reason = Opt.some("another reason")
    check boot(@[BootstrapInstance(instance: "k1", record: reason)]).isOk
    check storedOf(base, "k1").record.requestedPermissions[0].reason ==
      Opt.some("another reason")
    check stored(base).runtimeInstanceId == "rt-g160"

  test "[RUN-0922] [RUN-0947] [RUN-0948] [RUN-0949] names made after a restart never repeat earlier ones":
    let base = freshBase()
    var e = openAt(base)
    var earlier: seq[string]
    let (c, rc) = e.startClient()
    let m = e.started(meter())
    earlier.add(m.instance)
    earlier.add(m.providerId)
    let route = rc.routeId("r")
    for i in 0 ..< 3:
      let v = e.create(meter()).tryGet
      earlier.add(v.instance)
      earlier.add(v.providerId)
    let decisions = e.answers.mapIt(it.decisionId)
    let firstPrefix = prefixOf(earlier[0])
    e.restart(base)
    var later: seq[string]
    for i in 0 ..< 100:
      let v = e.create(meter()).tryGet
      later.add(v.instance)
      later.add(v.providerId)
    for id in later:
      check id notin earlier
      check prefixOf(id) != firstPrefix
    # The consumer comes back with a new binding; its old route id is unknown,
    # and nothing revived it.
    check e.start(c.instance).tryGet.state == msReady
    let rc2 = cast[ptr LogosRuntimeControlBinding](clients[
      (clientInits.load - 1) mod MaxClients
    ].load)
    check rc2.renew("r2", route).code == ecNotAuthorised
    check e.routes.allIt(it.route != route)
    check e.start(m.instance).tryGet.state == msReady
    let fresh = rc2.establish("r3", provider = Opt.some(providerAddress(m.providerId)))
    check fresh.code == ecOk
    check fresh.routesOf.routes[0].route != route
    for d in e.answers.mapIt(it.decisionId):
      check d notin decisions
      check d.startsWith("d-") and d[2 .. 33] != decisions[0][2 .. 33]
    e.finish()

  test "[RUN-0931] [RUN-0932] [RUN-0933] [RUN-0934] provider ids stay with their instance":
    let base = freshBase()
    var e = openAt(base)
    let m = e.started(meter(), "m")
    let p = m.providerId
    check p.len > 0
    discard e.stop("m").tryGet
    check e.start("m").tryGet.providerId == p
    let v = e.view("m").tryGet
    check e.reportFailure("m", v.attempt).isOk
    check waitUntil(
      proc(): bool =
        e.view("m").tryGet.state == msError and not e.cleanupPending("m")
    )
    let r = e.recover("m", e.view("m").tryGet.execution.revision).tryGet
    check r.state == msReady and r.providerId == p
    e.restart(base)
    check e.view("m").tryGet.providerId == p
    check e.start("m").tryGet.providerId == p
    let n = e.create(meter(), "n").tryGet
    check n.providerId.len > 0 and n.providerId != p
    e.finish()

  test "[RUN-0270] [RUN-0271] [RUN-0272] [RUN-0273] [RUN-0274] [RUN-0275] [RUN-0276] [RUN-0924] [LDR-0039] a state assignment stays with its instance across a restart (RUN-0923)":
    let base = freshBase()
    var e = openAt(base)
    discard e.create(keeper(Opt.some("k1-state")), "k1").tryGet
    check e.start("k1").tryGet.state == msReady
    let dir = lastDir()
    check dir == base / "state" / "k1-state"
    e.restart(base)
    check e.start("k1").tryGet.state == msReady
    check lastDir() == dir
    check readFile(dir / "inits") == "init\ninit\n"
    # The same module name attaches nothing; the assignment is not shared.
    check e.started(keeper(), "k2").state == msReady
    check lastDir() == ""
    let shared = e.create(keeper(Opt.some("k1-state")), "k3")
    check shared.isErr and shared.error.code == ecInvalidParams
    e.finish()

  test "[RUN-0999] [RUN-0924] a configured instance with the module name, binding and contract of a retained one gets none of its state":
    let base = freshBase()
    let orch = BootstrapInstance(instance: "orch", record: client())
    var e = openAt(base)
    check e.bootstrap(
      @[orch, BootstrapInstance(instance: "a", record: keeper(Opt.some("a-state")))],
      "orch",
    ).isOk
    check e.start("a").tryGet.state == msReady
    let aDir = lastDir()
    check aDir == base / "state" / "a-state"
    writeFile(aDir / "data", "a's state")
    proc contents(dir: string): seq[(string, string)] =
      for f in walkDirRec(dir, relative = true):
        result.add((f, readFile(dir / f)))
      result.sort()

    let before = contents(aDir)
    e.restart(base)
    # `a` is no longer configured (it stays retained); `b` is, with the same
    # module name, binding and (absent) primary contract and its own assignment.
    check e.bootstrap(
      @[orch, BootstrapInstance(instance: "b", record: keeper(Opt.some("b-state")))],
      "orch",
    ).isOk
    check e.start("b").tryGet.state == msReady
    let bDir = lastDir()
    check bDir == base / "state" / "b-state"
    # Empty when `b` was initialized: only its own first write is there.
    check contents(bDir) == @[("inits", "init\n")]
    check contents(aDir) == before
    check e.view("a").tryGet.state == msUnloaded
    e.finish()

  test "[RUN-0646] intent, its revision and its origin survive a restart (RUN-0923)":
    let base = freshBase()
    var e = openAt(base)
    let (c, rc) = e.startClient("c")
    discard e.create(keeper(), "k1").tryGet
    check rc.lifecycle("start_module", "keeper_module", Opt.some("k1")).code == ecOk
    discard e.started(keeper(), "k2")
    discard e.stop("k2").tryGet
    let before = @[e.view("c").tryGet, e.view("k1").tryGet, e.view("k2").tryGet]
    e.restart(base)
    let after = @[e.view("c").tryGet, e.view("k1").tryGet, e.view("k2").tryGet]
    for i in 0 ..< 3:
      check after[i].execution.intent == before[i].execution.intent
      check after[i].execution.intentRevision == before[i].execution.intentRevision
    check after[0].intentOrigin.host
    check after[1].intentOrigin.instance == c.instance
    check after[2].execution.intent == inStopped
    check after[2].execution.intentRevision.isNone
    for v in after:
      check v.state == msUnloaded
    e.finish()

  test "[IMPL-DECISION G193] an unclean end leaves error with other, intent kept, and nothing to clean":
    let base = freshBase()
    let ep = 1_000_000'u64
    proc inst(id: string, s: ModuleState, intent: Intent): StoredInstance =
      result = StoredInstance(
        instance: id,
        record: keeper(),
        state: s,
        revision: (ep shl 32) + 9,
        intent: intent,
      )
      if intent == inRequested:
        result.intentRevision = (ep shl 32) + 2
        result.origin = hostOrigin()

    var e5 = inst("e", msError, inRequested)
    e5.failure = Opt.some(Failure(kind: fkStartupTimeout, reason: "slow"))
    writeSnapshot(
      base,
      Snapshot(
        runtimeInstanceId: "rt-g193",
        epoch: ep,
        instances: @[
          inst("r", msReady, inRequested),
          inst("l", msLoaded, inRequested),
          inst("s", msStopping, inStopped),
          e5,
          inst("u", msUnloaded, inUninitialized),
        ],
      ),
    )
    let inits = keeperInits.load
    var e = openAt(base)
    for id in ["r", "l", "s"]:
      let v = e.view(id).tryGet
      check v.state == msError
      check v.failure.get.kind == fkOther and v.failure.get.reason == Unclean
      check v.execution.revision > (ep + 1) shl 32
    check e.view("r").tryGet.execution.intentRevision == Opt.some((ep shl 32) + 2)
    check e.view("s").tryGet.execution.intent == inStopped
    check e.view("e").tryGet.failure.get.kind == fkStartupTimeout
    check e.view("u").tryGet.state == msUnloaded
    # Nothing ran; each can be started or recovered at once.
    check keeperInits.load == inits
    for id in ["r", "l", "e"]:
      check e.recover(id, e.view(id).tryGet.execution.revision).tryGet.state == msReady
    check e.start("s").tryGet.state == msReady
    check e.start("u").tryGet.state == msReady
    check e.view("r").tryGet.execution.intentRevision == Opt.some((ep shl 32) + 2)
    e.finish()

  test "[RUN-1030] a retained instance no longer configured starts from its stored record":
    let base = freshBase()
    var e = openAt(base)
    check e.bootstrap(
      @[
        BootstrapInstance(instance: "orch", record: client()),
        BootstrapInstance(instance: "k1", record: keeper(Opt.some("k1-a"))),
      ],
      "orch",
    ).isOk
    e.restart(base)
    check e.bootstrap(@[BootstrapInstance(instance: "orch", record: client())], "orch").isOk
    check e.start("k1").tryGet.state == msReady
    check lastDir() == base / "state" / "k1-a"
    e.finish()

  test "[RUN-0698] [RUN-0646] [IMPL-DECISION G191] bootstrap resumes host-origin orchestration and re-establishes any other":
    let base = freshBase()
    var e = openAt(base)
    let first = e.bootstrap(
      @[BootstrapInstance(instance: "orch", record: client())], "orch"
    ).tryGet
    let revision = first.execution.intentRevision
    e.restart(base)
    let resumed = e.bootstrap(
      @[BootstrapInstance(instance: "orch", record: client())], "orch"
    ).tryGet
    check resumed.state == msReady
    check resumed.execution.intentRevision == revision
    check resumed.intentOrigin.host
    check not e.diagnosed("re-established")
    discard e.stop("orch").tryGet
    e.restart(base)
    let again = e.bootstrap(
      @[BootstrapInstance(instance: "orch", record: client())], "orch"
    ).tryGet
    check again.state == msReady
    check again.execution.intentRevision.get > revision.get
    check again.intentOrigin.host
    check e.diagnosed("re-established orchestration whose intent was stopped")
    e.finish()

  test "[IMPL-DECISION G192] the store keeps the Runtime's identity":
    let base = freshBase()
    var e = openAt(base)
    let id = e.runtimeInstanceId
    check id.len == 36 and id[14] == '4'
    e.restart(base)
    check e.runtimeInstanceId == id
    # One store, one engine.
    let second = openEngine(pconfig(base))
    check second.isErr and second.error.code == ecModule
    check "in use" in second.error.message
    e.finish()
    # Another configured identity is refused, and nothing is written.
    let bytes = readFile(storeOf(base) / SnapshotName)
    var other = pconfig(base)
    other.runtimeInstanceId = "rt-other"
    let r = openEngine(other)
    check r.isErr and r.error.code == ecInvalidParams
    check readFile(storeOf(base) / SnapshotName) == bytes
    # A new store takes the configured identity.
    var named = pconfig(freshBase())
    named.runtimeInstanceId = "rt-named"
    e = openEngine(named).tryGet
    check e.runtimeInstanceId == "rt-named"
    e.finish()

  test "[RUN-0697] [RUN-0693] the engine restarts nothing on its own":
    let base = freshBase()
    var e = openAt(base)
    let k = e.started(keeper(), "k")
    let inits = keeperInits.load
    check e.reportFailure("k", k.attempt).isOk
    check waitUntil(
      proc(): bool =
        e.view("k").tryGet.state == msError
    )
    sleep(1200)
    check e.view("k").tryGet.state == msError
    check keeperInits.load == inits
    # Nor after a restart: retained `requested` intent waits for orchestration.
    e.restart(base)
    sleep(1200)
    check e.view("k").tryGet.state == msError
    check e.view("k").tryGet.execution.intent == inRequested
    check keeperInits.load == inits
    e.finish()
