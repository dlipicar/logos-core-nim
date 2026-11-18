## State transfer to a replacement instance (`runtime/engine.nim`
## `sweepTransfers`, `checkTransfers`, `applyTransfers`; `runtime/statexfer.nim`;
## DECISIONS I96, G92 as re-decided 2026-11-15, G305-G307): a replacement gets
## a fresh state assignment, filled from the source's preserved storage by
## `move` or `copy` at a Runtime start, and the source is retired in the same
## write.
## Engine level, with persistent engines in the worktree's `build/` (renames,
## modes and locks need POSIX semantics). `holder_module` records the state
## directory it is given and appends to `inits` there.

import std/[algorithm, atomics, monotimes, os, sequtils, strutils, times, typedthreads]
when defined(posix):
  import std/posix
import unittest2
import
  ../src/logos_core/runtime/[artifact, engine, store, store_types, hostlock, statexfer]
import ../src/logos_core/pins
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, surface]
import ../src/logos_core/codegen/common_types
import ./support/[kitbuild, kitruntime, withoutloader]
import ./kit/meter_impl
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "transfer" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

# The holder module ------------------------------------------------------------------

var
  holderInits: Atomic[int]
  seenDir: array[1024, char] ## the state directory of the latest initialization
  seenDirLen: Atomic[int]

proc holderName(): cstring {.cdecl.} =
  "holder_module"

proc holderInit(
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
  holderInits += 1
  outContext[] = cast[ptr LogosModuleContext](allocShared0(16))

proc holderDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  deallocShared(module)

proc holderTable(): seq[(string, pointer)] =
  @[
    ("logos_holder_module_MODULE_name", cast[pointer](holderName)),
    ("logos_holder_module_MODULE_init", cast[pointer](holderInit)),
    ("logos_holder_module_MODULE_destroy", cast[pointer](holderDestroy)),
  ]

func holder(assignment: string, module = "holder_module"): ModuleRecord =
  ModuleRecord(
    module: module,
    strategy: stDirectStatic,
    binding: "holder",
    stateAssignment: Opt.some(assignment),
  )

proc lastDir(): string =
  result = newString(seenDirLen.load)
  for i in 0 ..< result.len:
    result[i] = seenDir[i]

# Persistent engines -----------------------------------------------------------------

var bases = 0

proc freshBase(): string =
  inc bases
  work / ("t" & $bases)

proc storeOf(base: string): string =
  base / "store"

proc stateOf(base, assignment: string): string =
  base / "state" / assignment

proc pconfig(base: string): EngineConfig =
  result = config(
    allowAll(),
    @[
      checkStaticRegistration("holder", holderTable()).tryGet,
      checkStaticRegistration("holder_two", holderTable()).tryGet,
    ],
  )
  result.runtimeInstanceId = ""
  result.storeDir = Opt.some(storeOf(base))
  result.stateRoot = Opt.some(base / "state")
  result.workDir = base / "work"

proc openAt(base: string): Engine =
  openEngine(pconfig(base)).tryGet

proc stored(base: string): Snapshot =
  let text = readFile(storeOf(base) / SnapshotName)
  decodeSnapshot(text.toOpenArrayByte(0, text.high)).tryGet

proc storedIds(base: string): seq[string] =
  ## The stored instances but the Module Loader's.
  for s in stored(base).instances:
    if s.instance != LoaderInstanceId:
      result.add(s.instance)
  result.sort()

proc retiredOf(base: string): seq[RetiredId] =
  stored(base).retired

proc writeSnapshot(base: string, snap: Snapshot) =
  var (s, _) = openStore(storeOf(base)).tryGet
  s.write(snap).tryGet
  s.close()

proc xferOn(base, instance: string): Opt[XferRecord] =
  ## `instance`'s `xfer` record, read from the files without the store lock
  ## (the engine may hold it).
  for f in walkDir(storeOf(base), relative = true):
    if f.path.startsWith(XferSide & "-") and f.path.endsWith(".cbor"):
      let text = readFile(storeOf(base) / f.path)
      let side = LcnRsSide.decode(text.toOpenArrayByte(0, text.high)).tryGet
      if side.instance == instance:
        return Opt.some(xferOf(side.value).tryGet)
  Opt.none(XferRecord)

proc putXfer(base, instance: string, r: XferRecord) =
  var (s, _) = openStore(storeOf(base)).tryGet
  s.putSide(XferSide, instance, xferBytes(r).tryGet).tryGet
  s.close()

proc setMode(dir: string, mode: int) =
  when defined(posix):
    doAssert chmod(cstring(dir), Mode(mode)) == 0

proc makeFifo(path: string) =
  when defined(posix):
    doAssert mkfifo(cstring(path), Mode(0o600)) == 0
  else:
    doAssert false, "no FIFO on this platform"

proc asRoot(): bool =
  when defined(posix):
    getuid() == 0
  else:
    true

proc diagnosed(e: Engine, text: string): bool =
  e.diagnostics.anyIt(text in it)

proc contents(dir: string): seq[(string, string)] =
  var found: seq[(string, string)] = @[]
  for f in walkDirRec(dir, relative = true):
    found.add((f, readFile(dir / f)))
  found.sort()
  found

let orch = BootstrapInstance(instance: "orch", record: client())

proc mv(source, target: string): StateTransfer =
  StateTransfer(source: source, target: target, mode: tmMove)

proc boot(
    e: Engine, more: seq[BootstrapInstance], transfers: seq[StateTransfer] = @[]
): Result[InstanceView, EngineError] =
  e.bootstrap(@[orch] & more, "orch", transfers)

proc seeded(base: string, assignment = "a-state"): Engine =
  ## A persistent engine whose configured `a` ran once and wrote `data`.
  result = openAt(base)
  check result.boot(@[BootstrapInstance(instance: "a", record: holder(assignment))]).isOk
  check result.start("a").tryGet.state == msReady
  writeFile(stateOf(base, assignment) / "data", "a's state")
  check result.stop("a").tryGet.state == msUnloaded

proc restart(e: var Engine, base: string) =
  e.finish()
  e = openAt(base)

proc storeBytes(base: string): string =
  readFile(storeOf(base) / SnapshotName)

# Tests ------------------------------------------------------------------------------

suite "run.transfer: a replacement instance filled by move (I96; RUNTIME l.3546-3553)":
  teardown:
    leftover()

  test "[RUN-0998] [RUN-0925] [RUN-0272] [IMPL-DECISION G92] move: the source is retired, the target gets its directory under its own assignment":
    let base = freshBase()
    var e = seeded(base)
    e.restart(base)
    let b = BootstrapInstance(instance: "b", record: holder("b-state"))
    check e.boot(@[b], @[mv("a", "b")]).isOk
    # `a` is gone; its tombstone keeps `a-state`; `b` is new and has its own.
    check e.view("a").isErr
    check e.list.allIt(it.instance != "a")
    check storedIds(base) == @["b", "orch"]
    check retiredOf(base).anyIt(
      it.instance == "a" and it.stateAssignment == Opt.some("a-state")
    )
    let v = e.view("b").tryGet
    check v.state == msUnloaded
    check v.execution.intent == inUninitialized
    check v.stateAssignment == Opt.some("b-state")
    check not dirExists(stateOf(base, "a-state"))
    check readFile(stateOf(base, "b-state") / "data") == "a's state"
    check e.diagnosed("state transfer: a (a-state) to b (b-state), move")
    let x = xferOn(base, "b")
    check x.isSome
    check x.get.source == "a" and x.get.sourceAssignment == "a-state"
    check x.get.mode == tmMove
    # `b` starts on the moved directory.
    check e.start("b").tryGet.state == msReady
    check lastDir() == stateOf(base, "b-state")
    check readFile(stateOf(base, "b-state") / "inits") == "init\ninit\n"
    e.finish()

  test "[RUN-0998] the source's retained requested intent is cancelled by its retirement in the same write":
    let base = freshBase()
    var e = openAt(base)
    check e.boot(@[BootstrapInstance(instance: "a", record: holder("a-state"))]).isOk
    check e.start("a").tryGet.state == msReady
    e.restart(base)
    check e.view("a").tryGet.execution.intent == inRequested
    check e.boot(
      @[BootstrapInstance(instance: "b", record: holder("b-state"))], @[mv("a", "b")]
    ).isOk
    let snap = stored(base)
    check snap.instances.allIt(it.instance != "a")
    check snap.instances.anyIt(it.instance == "b" and it.intent == inUninitialized)
    check snap.retired.anyIt(it.instance == "a")
    e.finish()

  test "[RUN-0923] [RUN-0924] the replacement gets nothing else of the source: no intent, its own assignment":
    let base = freshBase()
    var e = seeded(base)
    let aProvider = e.view("a").tryGet.providerId
    e.restart(base)
    check e.boot(
      @[BootstrapInstance(instance: "b", record: holder("b-state"))], @[mv("a", "b")]
    ).isOk
    let v = e.view("b").tryGet
    check v.execution.intent == inUninitialized
    check v.execution.intentRevision.isNone
    check v.stateAssignment == Opt.some("b-state")
    check v.providerId == aProvider # both empty: no contract
    check stored(base).instances.allIt(it.record.stateAssignment != Opt.some("a-state"))
    e.finish()

  test "[RUN-0999] names transfer nothing; an entry between different module names applies":
    let base = freshBase()
    var e = seeded(base)
    e.restart(base)
    # The same module name and binding, without an entry: empty.
    check e.boot(@[BootstrapInstance(instance: "c", record: holder("c-state"))]).isOk
    check e.start("c").tryGet.state == msReady
    check contents(stateOf(base, "c-state")) == @[("inits", "init\n")]
    check readFile(stateOf(base, "a-state") / "data") == "a's state"
    discard e.stop("c").tryGet
    e.restart(base)
    # Another module name, with an entry: applied.
    var other = holder("d-state", module = "holder_two_module")
    other.binding = "holder_two"
    check e.boot(
      @[
        BootstrapInstance(instance: "c", record: holder("c-state")),
        BootstrapInstance(instance: "d", record: other),
      ],
      @[mv("a", "d")],
    ).isOk
    check readFile(stateOf(base, "d-state") / "data") == "a's state"
    e.finish()

  test "[RUN-0998] [RUN-1009] a retained requested intent whose origin is the source refuses the transfer, changing nothing":
    let base = freshBase()
    let ep = 2_000_000'u64
    createDir(stateOf(base, "a-state"))
    writeFile(stateOf(base, "a-state") / "data", "a's state")
    writeSnapshot(
      base,
      Snapshot(
        runtimeInstanceId: "rt-t7",
        epoch: ep,
        instances: @[
          StoredInstance(
            instance: "a",
            record: holder("a-state"),
            state: msUnloaded,
            revision: (ep shl 32) + 1,
            intent: inUninitialized,
          ),
          StoredInstance(
            instance: "c",
            record: holder("c-state"),
            state: msUnloaded,
            revision: (ep shl 32) + 2,
            intent: inRequested,
            intentRevision: (ep shl 32) + 2,
            origin: Origin(host: false, instance: "a"),
          ),
        ],
      ),
    )
    var e = openAt(base)
    let before = storeBytes(base)
    let r = e.boot(
      @[BootstrapInstance(instance: "b", record: holder("b-state"))], @[mv("a", "b")]
    )
    check r.isErr and r.error.code == ecNotReady
    check "origin of retained execution intent" in r.error.message
    check storeBytes(base) == before
    check readFile(stateOf(base, "a-state") / "data") == "a's state"
    check not dirExists(stateOf(base, "b-state"))
    check xferOn(base, "b").isNone
    e.finish()

  test "[RUN-0998] [RUN-0927] a source restored after an unclean end is quiescent by the store lock; the transfer applies":
    let base = freshBase()
    let ep = 2_100_000'u64
    createDir(stateOf(base, "a-state"))
    writeFile(stateOf(base, "a-state") / "data", "a's state")
    writeSnapshot(
      base,
      Snapshot(
        runtimeInstanceId: "rt-t8",
        epoch: ep,
        instances: @[
          StoredInstance(
            instance: "a",
            record: holder("a-state"),
            state: msReady,
            revision: (ep shl 32) + 4,
            intent: inRequested,
            intentRevision: (ep shl 32) + 2,
            origin: hostOrigin(),
          )
        ],
      ),
    )
    var e = openAt(base)
    check e.view("a").tryGet.state == msError
    check e.boot(
      @[BootstrapInstance(instance: "b", record: holder("b-state"))], @[mv("a", "b")]
    ).isOk
    check readFile(stateOf(base, "b-state") / "data") == "a's state"
    e.finish()

  test "[IMPL-DECISION I96] refusals are INVALID_PARAMS and change nothing":
    let base = freshBase()
    var e = seeded(base)
    e.finish()
    let b = BootstrapInstance(instance: "b", record: holder("b-state"))
    proc refused(
        more: seq[BootstrapInstance], t: seq[StateTransfer], text: string
    ): bool =
      let e = openAt(base)
      let before = storeBytes(base)
      let r = e.boot(more, t)
      let same = storeBytes(base) == before
      e.finish()
      result =
        r.isErr and r.error.code == ecInvalidParams and text in r.error.message and same and
        dirExists(stateOf(base, "a-state")) and xferOn(base, "b").isNone
      if not result:
        echo "refused: ", r

    # An unknown source.
    check refused(@[b], @[mv("zz", "b")], "unknown or kept no state assignment")
    # A source still configured.
    check refused(
      @[b, BootstrapInstance(instance: "a", record: holder("a-state"))],
      @[mv("a", "b")],
      "not a valid transfer",
    )
    # A target whose directory exists.
    createDir(stateOf(base, "b-state"))
    check refused(@[b], @[mv("a", "b")], "already exists")
    removeDir(stateOf(base, "b-state"))
    check not dirExists(stateOf(base, "b-state"))
    # A source without a directory.
    moveDir(stateOf(base, "a-state"), stateOf(base, "a-aside"))
    let e2 = openAt(base)
    let r2 = e2.boot(@[b], @[mv("a", "b")])
    e2.finish()
    check r2.isErr and r2.error.code == ecInvalidParams
    check "has no state directory" in r2.error.message
    moveDir(stateOf(base, "a-aside"), stateOf(base, "a-state"))
    # A target retained without provenance.
    let e3 = openAt(base)
    check e3.boot(@[b]).isOk
    e3.finish()
    removeDir(stateOf(base, "b-state"))
    let e4 = openAt(base)
    let r4 = e4.boot(@[b], @[mv("a", "b")])
    e4.finish()
    check r4.isErr and r4.error.code == ecInvalidParams
    check "populates only a new instance" in r4.error.message
    check dirExists(stateOf(base, "a-state"))

  test "[IMPL-DECISION I96] an applied entry left in the configuration is satisfied: nothing changes again":
    let base = freshBase()
    var e = seeded(base)
    e.restart(base)
    let b = BootstrapInstance(instance: "b", record: holder("b-state"))
    check e.boot(@[b], @[mv("a", "b")]).isOk
    let x = xferOn(base, "b").get
    e.restart(base)
    check e.boot(@[b], @[mv("a", "b")]).isOk
    check not e.diagnosed("state transfer:")
    check xferOn(base, "b").get == x
    check readFile(stateOf(base, "b-state") / "data") == "a's state"
    check storedIds(base) == @["b", "orch"]
    e.finish()

  test "[IMPL-DECISION I96] a crash after the commit: the next start renames before anything starts":
    let base = freshBase()
    var e = seeded(base)
    e.restart(base)
    let b = BootstrapInstance(instance: "b", record: holder("b-state"))
    check e.boot(@[b], @[mv("a", "b")]).isOk
    e.finish()
    # As if the rename had not happened.
    moveDir(stateOf(base, "b-state"), stateOf(base, "a-state"))
    e = openAt(base)
    check e.boot(@[b]).isOk
    check e.diagnosed("completed the state transfer to b")
    check readFile(stateOf(base, "b-state") / "data") == "a's state"
    check not dirExists(stateOf(base, "a-state"))
    e.finish()

  test "[IMPL-DECISION I96] a crash before the commit: the record of an unknown target is reaped":
    let base = freshBase()
    var e = seeded(base)
    e.finish()
    putXfer(
      base,
      "b",
      XferRecord(source: "a", sourceAssignment: "a-state", mode: tmMove, epoch: 1),
    )
    e = openAt(base)
    check e.diagnosed("removed the side records of unknown instance b")
    check xferOn(base, "b").isNone
    check readFile(stateOf(base, "a-state") / "data") == "a's state"
    check e.view("a").isOk
    e.finish()

  test "[IMPL-DECISION I96] the commit's write fails: the source stays, nothing is created, MODULE_ERROR":
    if asRoot():
      skip()
      break
    let base = freshBase()
    var e = seeded(base)
    e.restart(base)
    let before = e.view("a").tryGet
    # The snapshot's temporary name is taken by a directory: every write fails.
    createDir(storeOf(base) / (SnapshotName & ".tmp"))
    let r = e.boot(
      @[BootstrapInstance(instance: "b", record: holder("b-state"))], @[mv("a", "b")]
    )
    check r.isErr and r.error.code == ecModule
    check e.view("a").tryGet.execution == before.execution
    check e.view("b").isErr
    check xferOn(base, "b").isNone
    check readFile(stateOf(base, "a-state") / "data") == "a's state"
    check not dirExists(stateOf(base, "b-state"))
    e.finish()
    removeDir(storeOf(base) / (SnapshotName & ".tmp"))

  test "[RUN-1020] move from a retired instance: its tombstone's assignment is the source":
    let base = freshBase()
    var e = seeded(base)
    # Retirement refuses an instance the host configuration names.
    e.restart(base)
    check e.boot(@[]).isOk
    let (_, rc) = e.startClient("c")
    let v = e.view("a").tryGet
    let r = rcCall(
      rc,
      "retire_module",
      encode(
        LogosNSRuntimeControlRetireModuleRequest(
          target: LogosNSRuntimeModuleInstanceAddress(
            runtime_instance_id: e.runtimeInstanceId, module_instance_id: "a"
          ),
          expected_execution_revision: v.execution.revision,
        )
      ).tryGet,
    )
    check r.code == ecOk
    discard e.stop("c").tryGet
    e.restart(base)
    check e.boot(
      @[BootstrapInstance(instance: "b", record: holder("b-state"))], @[mv("a", "b")]
    ).isOk
    check readFile(stateOf(base, "b-state") / "data") == "a's state"
    e.finish()

  test "[RUN-0998] [RUN-0927] a hosted source whose restart lock file is absent is refused":
    when not defined(posix):
      skip()
      break
    let base = freshBase()
    let ep = 2_200_000'u64
    createDir(stateOf(base, "a-state"))
    writeFile(stateOf(base, "a-state") / "data", "a's state")
    var rec = holder("a-state")
    rec.strategy = stHostedDynamic
    rec.binding = ""
    rec.placement = "process"
    rec.artifact = ArtifactRecord(
      id: "holder", localPath: "/nonexistent/libholder.so", hashSuite: HashSuiteId
    )
    writeSnapshot(
      base,
      Snapshot(
        runtimeInstanceId: "rt-t19",
        epoch: ep,
        instances: @[
          StoredInstance(
            instance: "a",
            record: rec,
            state: msUnloaded,
            revision: (ep shl 32) + 1,
            intent: inUninitialized,
          )
        ],
      ),
    )
    var e = openAt(base)
    let before = storeBytes(base)
    let r = e.boot(
      @[BootstrapInstance(instance: "b", record: holder("b-state"))], @[mv("a", "b")]
    )
    check r.isErr and r.error.code == ecNotReady
    check "restart lock is missing" in r.error.message
    check lockPath(base / "work", "a") in r.error.message
    check storeBytes(base) == before
    check dirExists(stateOf(base, "a-state"))
    check not dirExists(stateOf(base, "b-state"))
    e.finish()

  test "[RUN-0998] [RUN-0927] a hosted source whose lock is held is refused until the holder ends":
    when not defined(posix):
      skip()
      break
    let base = freshBase()
    let ep = 2_300_000'u64
    createDir(stateOf(base, "a-state"))
    writeFile(stateOf(base, "a-state") / "data", "a's state")
    var rec = holder("a-state")
    rec.strategy = stHostedDynamic
    rec.binding = ""
    rec.placement = "process"
    rec.artifact = ArtifactRecord(
      id: "holder", localPath: "/nonexistent/libholder.so", hashSuite: HashSuiteId
    )
    writeSnapshot(
      base,
      Snapshot(
        runtimeInstanceId: "rt-t20",
        epoch: ep,
        instances: @[
          StoredInstance(
            instance: "a",
            record: rec,
            state: msUnloaded,
            revision: (ep shl 32) + 1,
            intent: inUninitialized,
          )
        ],
      ),
    )
    # As a surviving Module Host of an earlier run would.
    let (taken, fd) = takeHostLock(base / "work", "a")
    check taken == loTaken
    var e = openAt(base)
    let r = e.boot(
      @[BootstrapInstance(instance: "b", record: holder("b-state"))], @[mv("a", "b")]
    )
    check r.isErr and r.error.code == ecNotReady
    check "may still hold the transfer source's state" in r.error.message
    check lockPath(base / "work", "a") in r.error.message
    check dirExists(stateOf(base, "a-state"))
    e.finish()
    closeLock(fd)
    e = openAt(base)
    check e.boot(
      @[BootstrapInstance(instance: "b", record: holder("b-state"))], @[mv("a", "b")]
    ).isOk
    check readFile(stateOf(base, "b-state") / "data") == "a's state"
    e.finish()

  test "[IMPL-DECISION I96] a target whose transferred directory is missing is not realized on an empty one":
    let base = freshBase()
    var e = seeded(base)
    e.restart(base)
    let b = BootstrapInstance(instance: "b", record: holder("b-state"))
    check e.boot(@[b], @[mv("a", "b")]).isOk
    e.finish()
    removeDir(stateOf(base, "b-state"))
    e = openAt(base)
    check e.boot(@[b]).isOk
    check e.diagnosed("the state directory of b is missing")
    let inits = holderInits.load
    let s = e.start("b")
    let failed =
      if s.isOk:
        s.get
      else:
        e.view("b").tryGet
    check failed.state == msError
    check failed.failure.get.kind == fkOther
    check e.diagnosed("the state transferred to b is missing")
    check holderInits.load == inits
    check not dirExists(stateOf(base, "b-state"))
    # Made by hand (restored from a backup), `b` starts.
    createDir(stateOf(base, "b-state"))
    check e.recover("b", e.view("b").tryGet.execution.revision).tryGet.state == msReady
    e.finish()

  test "[IMPL-DECISION I96] a retired target keeps its transfer record; a record of an unknown id is reaped":
    let base = freshBase()
    var e = seeded(base)
    e.restart(base)
    check e.boot(
      @[BootstrapInstance(instance: "b", record: holder("b-state"))], @[mv("a", "b")]
    ).isOk
    e.restart(base)
    check e.boot(@[]).isOk
    let (_, rc) = e.startClient("c")
    let r = rcCall(
      rc,
      "retire_module",
      encode(
        LogosNSRuntimeControlRetireModuleRequest(
          target: LogosNSRuntimeModuleInstanceAddress(
            runtime_instance_id: e.runtimeInstanceId, module_instance_id: "b"
          ),
          expected_execution_revision: e.view("b").tryGet.execution.revision,
        )
      ).tryGet,
    )
    check r.code == ecOk
    discard e.stop("c").tryGet
    e.finish()
    putXfer(
      base,
      "zz",
      XferRecord(source: "q", sourceAssignment: "q-state", mode: tmMove, epoch: 1),
    )
    e = openAt(base)
    check xferOn(base, "b").isSome
    check xferOn(base, "zz").isNone
    e.finish()

proc cp(source, target: string, maxBytes = 0'u64): StateTransfer =
  StateTransfer(source: source, target: target, mode: tmCopy, maxBytes: maxBytes)

proc reserved(base: string): seq[string] =
  ## The names in `state_root` only a transfer or a purge makes.
  var found: seq[string] = @[]
  for f in walkDir(base / "state", relative = true):
    if isReserved(f.path):
      found.add(f.path)
  found

suite "run.transfer: a replacement instance filled by copy (I96; RUNTIME l.3546-3553)":
  teardown:
    leftover()

  test "[RUN-0998] [RUN-1020] copy: the source's directory is unchanged; a copy from the retired source rolls back":
    when not defined(posix):
      # [I96] `copy` is not supported on Windows: MODULE_ERROR, nothing changed.
      let base = freshBase()
      var e = seeded(base)
      e.restart(base)
      let r = e.boot(
        @[BootstrapInstance(instance: "b", record: holder("b-state"))], @[cp("a", "b")]
      )
      check r.isErr and r.error.code == ecModule
      check "not supported on this platform" in r.error.message
      check e.view("a").isOk
      e.finish()
    else:
      let base = freshBase()
      var e = seeded(base)
      createDir(stateOf(base, "a-state") / "sub" / "deeper")
      writeFile(stateOf(base, "a-state") / "sub" / "deeper" / "leaf", "leaf")
      writeFile(stateOf(base, "a-state") / "empty", "")
      setFilePermissions(
        stateOf(base, "a-state") / "sub" / "deeper" / "leaf", {fpUserRead}
      )
      let before = contents(stateOf(base, "a-state"))
      e.restart(base)
      let b = BootstrapInstance(instance: "b", record: holder("b-state"))
      check e.boot(@[b], @[cp("a", "b")]).isOk
      check e.view("a").isErr
      check retiredOf(base).anyIt(
        it.instance == "a" and it.stateAssignment == Opt.some("a-state")
      )
      check contents(stateOf(base, "a-state")) == before
      check contents(stateOf(base, "b-state")) == before
      check getFilePermissions(stateOf(base, "b-state") / "sub" / "deeper" / "leaf") ==
        {fpUserRead}
      let x = xferOn(base, "b").get
      check x.mode == tmCopy
      check x.files == 4 # data, inits, empty, leaf
      check x.bytes == uint64(before.mapIt(it[1].len).foldl(a + b, 0))
      check e.diagnosed(
        "state transfer: a (a-state) to b (b-state), copy, " & $x.bytes &
          " bytes in 4 files"
      )
      check reserved(base).len == 0
      # `b` runs and writes; `a`'s directory stays as it was.
      check e.start("b").tryGet.state == msReady
      check readFile(stateOf(base, "b-state") / "inits") == "init\ninit\n"
      check contents(stateOf(base, "a-state")) == before
      check e.stop("b").tryGet.state == msUnloaded
      # Rolling back: `c` from the retired `a` gets the state as it was.
      e.restart(base)
      let c = BootstrapInstance(instance: "c", record: holder("c-state"))
      check e.boot(@[b, c], @[cp("a", "c")]).isOk
      check contents(stateOf(base, "c-state")) == before
      check xferOn(base, "c").get.source == "a"
      e.finish()

  test "[IMPL-DECISION I96] copy refusals: other entries are INVALID_PARAMS, bounds MODULE_ERROR; nothing is staged":
    when not defined(posix):
      skip()
      break
    let base = freshBase()
    var e = seeded(base)
    e.finish()
    let b = BootstrapInstance(instance: "b", record: holder("b-state"))
    proc refused(t: StateTransfer, code: ErrorCode, text: string): bool =
      let e = openAt(base)
      let before = storeBytes(base)
      let r = e.boot(@[b], @[t])
      let same = storeBytes(base) == before
      e.finish()
      result =
        r.isErr and r.error.code == code and text in r.error.message and same and
        reserved(base).len == 0 and not dirExists(stateOf(base, "b-state")) and
        xferOn(base, "b").isNone
      if not result:
        echo "refused: ", r

    # A symbolic link inside, named by its relative path.
    createDir(stateOf(base, "a-state") / "sub")
    createSymlink(
      stateOf(base, "a-state") / "data", stateOf(base, "a-state") / "sub" / "ln"
    )
    check refused(
      cp("a", "b"), ecInvalidParams, "other than a directory or a regular file: sub/ln"
    )
    removeFile(stateOf(base, "a-state") / "sub" / "ln")
    # A FIFO.
    makeFifo(stateOf(base, "a-state") / "sub" / "pipe")
    check refused(cp("a", "b"), ecInvalidParams, "sub/pipe")
    removeFile(stateOf(base, "a-state") / "sub" / "pipe")
    # Over `max_bytes`: `data` and `inits` hold 14 bytes.
    check refused(cp("a", "b", 13), ecModule, "more than max_bytes (13)")
    # Deeper than `MaxTransferDepth`.
    var deep = stateOf(base, "a-state") / "sub"
    for i in 0 ..< MaxTransferDepth:
      deep = deep / "d"
    createDir(deep)
    check refused(
      cp("a", "b"), ecModule, "deeper than " & $MaxTransferDepth & " levels"
    )
    removeDir(stateOf(base, "a-state") / "sub")
    # Within the bounds, exactly, it applies.
    e = openAt(base)
    check e.boot(@[b], @[cp("a", "b", 14)]).isOk
    check readFile(stateOf(base, "b-state") / "data") == "a's state"
    e.finish()

  test "[IMPL-DECISION I96] a copy that cannot read a file: the staging is removed, nothing is committed, MODULE_ERROR":
    when not defined(posix):
      skip()
      break
    if asRoot():
      skip()
      break
    let base = freshBase()
    var e = seeded(base)
    e.finish()
    writeFile(stateOf(base, "a-state") / "secret", "unreadable")
    setMode(stateOf(base, "a-state") / "secret", 0)
    let b = BootstrapInstance(instance: "b", record: holder("b-state"))
    e = openAt(base)
    let before = storeBytes(base)
    let r = e.boot(@[b], @[cp("a", "b")])
    check r.isErr and r.error.code == ecModule
    check "cannot open secret" in r.error.message
    check storeBytes(base) == before
    check reserved(base).len == 0
    check not dirExists(stateOf(base, "b-state"))
    check e.view("a").isOk and e.view("b").isErr
    check xferOn(base, "b").isNone
    e.finish()
    # Readable again, the next start applies it.
    setMode(stateOf(base, "a-state") / "secret", 0o600)
    e = openAt(base)
    check e.boot(@[b], @[cp("a", "b")]).isOk
    check readFile(stateOf(base, "b-state") / "secret") == "unreadable"
    e.finish()

  test "[IMPL-DECISION I96] crash completion for copy: a committed staging is renamed; an uncommitted one and a purge's are removed; other names are kept":
    when not defined(posix):
      skip()
      break
    let base = freshBase()
    var e = seeded(base)
    e.restart(base)
    let b = BootstrapInstance(instance: "b", record: holder("b-state"))
    check e.boot(@[b], @[cp("a", "b")]).isOk
    e.finish()
    # As if the commit had happened and the rename had not.
    moveDir(stateOf(base, "b-state"), stateOf(base, stagingName("b-state")))
    # An uncommitted copy's staging, an interrupted purge, an operator's name.
    createDir(stateOf(base, stagingName("z-state")) / "half")
    writeFile(stateOf(base, stagingName("z-state")) / "half" / "f", "x")
    createDir(stateOf(base, PurgePrefix & "0123456789abcdef"))
    createDir(stateOf(base, "operator-notes"))
    e = openAt(base)
    check e.boot(@[b]).isOk
    check e.diagnosed("completed the state transfer to b")
    check readFile(stateOf(base, "b-state") / "data") == "a's state"
    check reserved(base).len == 0
    check dirExists(stateOf(base, "operator-notes"))
    check dirExists(stateOf(base, "a-state"))
    e.finish()
