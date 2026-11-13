## Runtime Control `recover_module`, `retire_module` and `create_module`
## (`runtime/engine.nim`, `runtime/invoke.nim`; DECISIONS I82, G194, G195),
## and what the engine gives a restart policy to count with (D24): one
## accepted attempt per expected execution revision, no restart of its own.
## The consumer, the gated module and the meter are the route fixture's;
## `counter_module` counts its initializations and can fail one or hold its
## destruction. Module code runs on the engine's workers, so the test modules
## keep their state in atomics.

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
when defined(posix):
  import std/posix
import unittest2
import ../src/logos_core/runtime/[engine, store]
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, surface]
import ../src/logos_core/iface/common_types
import ./support/[kitbuild, kitruntime]
import ./kit/meter_impl
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "recovery" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

# The counter module ---------------------------------------------------------------------

var
  counterInits: Atomic[int]
  counterFail: Atomic[bool] ## initializations fail while true
  counterDestroyGate: Atomic[bool] ## destruction waits while true
  counterDestroys: Atomic[int]

proc counterName(): cstring {.cdecl.} =
  "counter_module"

proc counterInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl.} =
  counterInits += 1
  if counterFail.load:
    result.code = CErrorCode(ord(ecModule))
    result.message = "counter refuses to start"
    return
  outContext[] = cast[ptr LogosModuleContext](allocShared0(16))

proc counterDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  while counterDestroyGate.load:
    sleep(1)
  deallocShared(module)
  counterDestroys += 1

proc counterTable(): seq[(string, pointer)] =
  @[
    ("logos_counter_module_MODULE_name", cast[pointer](counterName)),
    ("logos_counter_module_MODULE_init", cast[pointer](counterInit)),
    ("logos_counter_module_MODULE_destroy", cast[pointer](counterDestroy)),
  ]

func counter(assignment = Opt.none(string), binding = "counter"): ModuleRecord =
  ModuleRecord(
    module: "counter_module",
    strategy: stDirectStatic,
    binding: binding,
    stateAssignment: assignment,
  )

proc rconfig(
    policy = allowAll(), declarations: seq[ModuleDeclaration] = @[]
): EngineConfig =
  result = config(
    policy,
    @[
      checkStaticRegistration("counter", counterTable()).tryGet,
      checkStaticRegistration("counter2", counterTable()).tryGet,
    ],
  )
  result.declarations = declarations

proc declaring(r: ModuleRecord, persistentState = false): ModuleDeclaration =
  ModuleDeclaration(record: r, persistentState: persistentState)

proc reset() =
  counterFail.store(false)
  counterDestroyGate.store(false)
  clientDestroyGate.store(false)
  slowGate.store(false)
  gate.store(false)

# Persistent engines ---------------------------------------------------------------------

var bases = 0

proc freshBase(): string =
  inc bases
  work / ("p" & $bases)

proc pconfig(
    base: string, policy = allowAll(), declarations: seq[ModuleDeclaration] = @[]
): EngineConfig =
  result = rconfig(policy, declarations)
  result.runtimeInstanceId = ""
  result.storeDir = Opt.some(base / "store")
  result.stateRoot = Opt.some(base / "state")

proc stored(base: string): Snapshot =
  let text = readFile(base / "store" / SnapshotName)
  decodeSnapshot(text.toOpenArrayByte(0, text.high)).tryGet

proc setMode(dir: string, mode: int) =
  when defined(posix):
    doAssert chmod(cstring(dir), Mode(mode)) == 0

proc asRoot(): bool =
  when defined(posix):
    getuid() == 0
  else:
    true

# Requests -------------------------------------------------------------------------------

proc recoverOn(
    rc: ptr LogosRuntimeControlBinding,
    instance: string,
    expected: uint64,
    module = "counter_module",
): RcResult =
  rcCall(
    rc,
    "recover_module",
    encode(
      LogosNSRuntimeControlRecoverModuleRequest(
        module: module, instance: instance, expected_execution_revision: expected
      )
    ).tryGet,
  )

proc retireOn(
    rc: ptr LogosRuntimeControlBinding, runtime, instance: string, expected: uint64
): RcResult =
  rcCall(
    rc,
    "retire_module",
    encode(
      LogosNSRuntimeControlRetireModuleRequest(
        target: LogosNSRuntimeModuleInstanceAddress(
          runtime_instance_id: runtime, module_instance_id: instance
        ),
        expected_execution_revision: expected,
      )
    ).tryGet,
  )

proc retire(rc: ptr LogosRuntimeControlBinding, e: Engine, instance: string): RcResult =
  ## Retires `instance` of `e` at its current revision.
  let v = e.view(instance)
  rc.retireOn(
    e.runtimeInstanceId, instance, (if v.isOk: v.get.execution.revision else: 0'u64)
  )

proc createOn(rc: ptr LogosRuntimeControlBinding, module, key: string): RcResult =
  rcCall(
    rc,
    "create_module",
    encode(LogosNSRuntimeControlCreateModuleRequest(module: module, request_key: key)).tryGet,
  )

proc createdId(r: RcResult): string =
  let c = LogosNSRuntimeControlCreateModuleResponse.decode(r.response).tryGet
  check c.module.len > 0
  c.instance

proc stateIn(r: RcResult): LogosNSRuntimeControlStateKind =
  LogosNSRuntimeControlRecoverModuleResponse.decode(r.response).tryGet.state.kind

proc rev(e: Engine, instance: string): uint64 =
  e.view(instance).tryGet.execution.revision

proc bound(rc: ptr LogosRuntimeControlBinding, e: Engine, instance: string): bool =
  ## Whether `instance`'s bind has finished: its realization is `current`, not
  ## `unknown` as during the bind. That change commits a revision of its own
  ## (G227), so a guarded request must read the revision after it.
  let r = rcCall(
    rc,
    "get_execution_summary",
    encode(
      LogosNSRuntimeControlGetExecutionSummaryRequest(
        target: LogosNSRuntimeModuleInstanceAddress(
          runtime_instance_id: e.runtimeInstanceId, module_instance_id: instance
        )
      )
    ).tryGet,
  )
  if r.code != ecOk:
    return false
  let s = LogosNSRuntimeControlGetExecutionSummaryResponse.decode(r.response).valueOr:
    return false
  s.realization.kind ==
    LogosNSRuntimeControlGetExecutionSummaryResponseRealizationChoiceKind.Current

proc failed(e: Engine, instance: string, cleaned = true) =
  ## The instance reports failure through its current realization. With
  ## `cleaned`, this waits until the realization's cleanup is complete too: the
  ## instance is `error` before it is, and until then a recovery is NOT_READY.
  let v = e.view(instance).tryGet
  check e.reportFailure(instance, v.attempt).isOk
  check waitUntil(
    proc(): bool =
      e.view(instance).tryGet.state == msError
  )
  if cleaned:
    check waitUntil(
      proc(): bool =
        not e.cleanupPending(instance)
    )

var startReply: Atomic[int] ## the state `startOn` got, or -1; -2 while it waits

proc startOn(arg: (Engine, string)) {.thread.} =
  let r = arg[0].start(arg[1])
  startReply.store(
    if r.isOk:
      ord(r.get.state)
    else:
      -1
  )

type RecoverArg = object
  rc: ptr LogosRuntimeControlBinding
  instance: string
  expected: uint64

var raceCodes: array[2, Atomic[int]]

proc recoverRace(arg: (RecoverArg, int)) {.thread.} =
  {.cast(gcsafe).}:
    let r = arg[0].rc.recoverOn(arg[0].instance, arg[0].expected)
    raceCodes[arg[1]].store(ord(r.code))

var createdIds: array[2, Atomic[pointer]]

proc createRace(arg: (ptr LogosRuntimeControlBinding, int)) {.thread.} =
  {.cast(gcsafe).}:
    let r = arg[0].createOn("counter_module", "same-key")
    if r.code == ecOk:
      let id =
        LogosNSRuntimeControlCreateModuleResponse.decode(r.response).tryGet.instance
      let p = cast[ptr UncheckedArray[char]](allocShared0(id.len + 1))
      for i, c in id:
        p[i] = c
      createdIds[arg[1]].store(p)

proc createdBy(i: int): string =
  let p = cast[ptr UncheckedArray[char]](createdIds[i].load)
  if p == nil:
    return ""
  var n = 0
  while p[n] != '\0':
    inc n
  result = newString(n)
  for k in 0 ..< n:
    result[k] = p[k]
  deallocShared(p)
  createdIds[i].store(nil)

# Tests ----------------------------------------------------------------------------------

suite "run.rc: recover_module (RUNTIME §9.3 l.3537-3544, §10.1)":
  setup:
    reset()

  test "[RUN-0643] [RUN-0874] recovery needs requested intent, a failed or unloaded instance and its cleanup complete [IMPL-DECISION G227]":
    let e =
      newEngine(rconfig(denying(deny(operation = "recover_module", consumer = "d"))))
    let (_, arc) = e.startClient("a")
    let (_, drc) = e.startClient("d")
    discard e.create(counter(), "w").tryGet
    # Intent `uninitialized`: no execution choice to recover.
    check arc.recoverOn("w", e.rev("w")).code == ecNotReady
    check e.start("w").tryGet.state == msReady
    check arc.recoverOn("w", e.rev("w")).code == ecNotReady # `ready`
    # `loaded`: initialization still runs.
    discard e.create(slow(), "s").tryGet
    slowGate.store(true)
    var t: Thread[(Engine, string)]
    startReply.store(-2)
    createThread(t, startOn, (e, "s"))
    # `_MODULE_init` waits; the revision read is the one after the bind.
    check waitUntil(
      proc(): bool =
        e.view("s").tryGet.state == msLoaded and arc.bound(e, "s")
    )
    check arc.recoverOn("s", e.rev("s"), "slow_module").code == ecNotReady
    slowGate.store(false)
    joinThread(t)
    check startReply.load == ord(msReady)
    # `error` whose destruction has not returned: cleanup is pending.
    counterDestroyGate.store(true)
    e.failed("w", cleaned = false)
    check e.cleanupPending("w")
    let r = e.rev("w")
    check arc.recoverOn("w", r).code == ecNotReady
    # What comes before readiness (G171): authority, the module name, the revision.
    let stale = arc.recoverOn("w", r - 1)
    check stale.code == ecInvalidParams
    check stale.detail.len == 0
    check arc.recoverOn("w", r, "meter_module").code == ecInvalidParams
    check arc.recoverOn("nobody", 0).code == ecNotAuthorised
    check drc.recoverOn("w", r).code == ecNotAuthorised
    # `expected_execution_revision` is required by the schema.
    let absent = rcCall(
      arc,
      "recover_module",
      encode(
        LogosNSRuntimeControlStartModuleRequest(
          module: "counter_module", instance: Opt.some("w")
        )
      ).tryGet,
    )
    check absent.code == ecInvalidParams
    check absent.detail.len > 0
    check e.rev("w") == r
    counterDestroyGate.store(false)
    # [G227] The end of the cleanup is a commit of its own (the realization
    # becomes `absent`): a revision read before it is stale, so the test
    # retries until a recovery is accepted.
    check waitUntil(
      proc(): bool =
        arc.recoverOn("w", e.rev("w")).code == ecOk
    )
    check e.view("w").tryGet.state == msReady
    e.finish()

  test "[RUN-0644] [RUN-0645] [RUN-0647] [RUN-0691] [RUN-0694] [IMPL-DECISION G173] recovery keeps intent and origin, and runs a new realization to ready":
    let e = newEngine(rconfig())
    let (_, arc) = e.startClient("a")
    let (_, brc) = e.startClient("b")
    discard e.create(counter(), "w").tryGet
    check arc.lifecycle("start_module", "counter_module", Opt.some("w")).code == ecOk
    let before = e.view("w").tryGet
    check before.intentOrigin.instance == "a"
    let inits = counterInits.load
    e.failed("w")
    # The initiator ends; its intent stays (l.3541).
    check e.stop("a").tryGet.state == msUnloaded
    check e.view("w").tryGet.execution.intent == inRequested
    let r = brc.recoverOn("w", e.rev("w"))
    check r.code == ecOk
    check r.stateIn == LogosNSRuntimeControlStateKind.Ready # answered at `ready`
    let after = e.view("w").tryGet
    check after.state == msReady
    check after.failure.isNone
    check after.execution.intent == inRequested
    check after.execution.intentRevision == before.execution.intentRevision
    check after.intentOrigin.instance == "a"
    check after.attempt != before.attempt
    check counterInits.load == inits + 1
    # The request was authenticated as `b`; execution was authorized for `a`,
    # whose provenance authenticated nothing.
    let answers = e.answers
    check answers.anyIt(
      it.request.operation == "recover_module" and it.request.consumer == "b"
    )
    check not answers.anyIt(
      it.request.operation == "recover_module" and it.request.consumer == "a"
    )
    check answers.anyIt(
      it.request.action == aaExecute and it.request.consumer == "a" and
        it.request.target == "w"
    )
    e.finish()

  test "[RUN-0692] [RUN-0644] [IMPL-DECISION G168] recovery is authorized for the retained origin, not the requester":
    let e = newEngine(
      rconfig(denying(deny(action = Opt.some(aaExecute), consumer = "a", target = "w")))
    )
    let (_, arc) = e.startClient("a")
    let (_, brc) = e.startClient("b")
    discard e.create(counter(), "w").tryGet
    # `a`'s start is accepted, so intent is `a`'s, and its execution denied.
    check arc.lifecycle("start_module", "counter_module", Opt.some("w")).code ==
      ecNotAuthorised
    let inits = counterInits.load
    let r = e.rev("w")
    let refused = brc.recoverOn("w", r)
    check refused.code == ecNotAuthorised
    let v = e.view("w").tryGet
    check v.state == msUnloaded
    check v.failure.get.kind == fkAuthorityDenied
    check v.execution.intent == inRequested
    check v.intentOrigin.instance == "a"
    # The refusal is recorded, so the revision moved with no attempt run: a
    # restart policy counts answered recoveries, not revision steps.
    check v.execution.revision > r
    check counterInits.load == inits
    e.finish()

  test "[RUN-0644] a dependent whose prerequisite is not ready is not recovered, and keeps its intent":
    var c = rconfig()
    c.ordering = @[("p", "w")]
    let e = newEngine(c)
    let (_, arc) = e.startClient("a")
    discard e.create(counter(), "p").tryGet
    discard e.create(counter(), "w").tryGet
    check e.start("p").tryGet.state == msReady
    check arc.lifecycle("start_module", "counter_module", Opt.some("w")).code == ecOk
    e.failed("w")
    check e.stop("p").tryGet.state == msUnloaded
    let r = e.rev("w")
    check arc.recoverOn("w", r).code == ecNotReady
    check e.rev("w") == r
    check e.view("w").tryGet.execution.intent == inRequested
    check e.start("p").tryGet.state == msReady
    check arc.recoverOn("w", r).code == ecOk
    check e.view("w").tryGet.state == msReady
    e.finish()

  test "[RUN-0699] routes that failed with the previous realization stay failed":
    let e = newEngine(rconfig())
    let (_, arc) = e.startClient("a")
    let m = e.started(meter(), "m")
    let old = arc.routeId("k1")
    e.failed("m")
    check arc.recoverOn("m", e.rev("m"), "meter_module").code == ecOk
    check e.routes.filterIt(it.route == old)[0].state.kind ==
      LogosNSRuntimeControlRouteStateKind.Failed
    check arc.renew("k2", old).code != ecOk
    check e.routes.filterIt(it.route == old)[0].state.kind ==
      LogosNSRuntimeControlRouteStateKind.Failed
    let fresh = arc.routeId("k3")
    check fresh != old
    var h = arc.handle(fresh)
    check h.read(7).tryGet.reading.value == 70
    h.release()
    check m.providerId == e.view("m").tryGet.providerId
    e.finish()

  test "[RUN-0693] a failed instance stays failed: the engine restarts nothing":
    let e = newEngine(rconfig())
    let (_, arc) = e.startClient("a")
    discard e.create(counter(), "w").tryGet
    check arc.lifecycle("start_module", "counter_module", Opt.some("w")).code == ecOk
    let inits = counterInits.load
    e.failed("w")
    let r = e.rev("w")
    sleep(300)
    let v = e.view("w").tryGet
    check v.state == msError
    check v.execution.revision == r
    check counterInits.load == inits
    e.finish()

  test "after an explicit stop, and during shutdown, recovery is refused (RUN-0687, the engine half)":
    let e = newEngine(rconfig())
    let (_, arc) = e.startClient("a")
    discard e.create(counter(), "w").tryGet
    discard e.create(counter(), "v").tryGet
    check arc.lifecycle("start_module", "counter_module", Opt.some("w")).code == ecOk
    check arc.lifecycle("start_module", "counter_module", Opt.some("v")).code == ecOk
    e.failed("w")
    e.failed("v")
    check e.stop("w").tryGet.execution.intent == inStopped
    check arc.recoverOn("w", e.rev("w")).code == ecNotReady
    check e.view("w").tryGet.execution.intent == inStopped
    # Shutdown accepted: a binding still alive is refused too.
    clientDestroyGate.store(true)
    e.requestShutdown()
    check arc.recoverOn("v", e.rev("v")).code == ecNotReady
    clientDestroyGate.store(false)
    e.finish()

  test "[IMPL] one accepted attempt per expected revision; a lost answer is resolved by reading readiness":
    # The step 6 plan's C-9: a restart policy keys its attempts by R.
    let e = newEngine(rconfig())
    let (_, arc) = e.startClient("a")
    let (_, brc) = e.startClient("b")
    discard e.create(counter(), "w").tryGet
    check arc.lifecycle("start_module", "counter_module", Opt.some("w")).code == ecOk
    var inits = counterInits.load
    # (1) A replay of R after an accepted attempt is refused.
    e.failed("w")
    var r = e.rev("w")
    check arc.recoverOn("w", r).code == ecOk
    check arc.recoverOn("w", r).code == ecInvalidParams
    check counterInits.load == inits + 1
    # (2) An answer the caller never read: readiness shows the attempt ran.
    e.failed("w")
    r = e.rev("w")
    inits = counterInits.load
    var t: Thread[(RecoverArg, int)]
    raceCodes[0].store(-1)
    createThread(t, recoverRace, (RecoverArg(rc: arc, instance: "w", expected: r), 0))
    joinThread(t) # its answer is dropped
    let seen = LogosNSRuntimeControlGetReadinessResponse.decode(
      arc.readiness("counter_module", Opt.some("w")).response
    ).tryGet
    check seen.execution.get.revision > r
    check seen.state.kind == LogosNSRuntimeControlStateKind.Ready
    check arc.recoverOn("w", r).code == ecInvalidParams
    check counterInits.load == inits + 1
    # (3) A change between reading R and recovering: the caller reads again.
    e.failed("w")
    r = e.rev("w")
    counterFail.store(true)
    let theirs = brc.recoverOn("w", r) # another party's attempt, which fails
    counterFail.store(false)
    check theirs.code == ecOk
    check theirs.stateIn == LogosNSRuntimeControlStateKind.Error
    check arc.recoverOn("w", r).code == ecInvalidParams
    check arc.recoverOn("w", e.rev("w")).code == ecOk
    # (4) Two recoveries with one R at once: one attempt.
    e.failed("w")
    r = e.rev("w")
    inits = counterInits.load
    var u: array[2, Thread[(RecoverArg, int)]]
    for i in 0 .. 1:
      raceCodes[i].store(-1)
      createThread(
        u[i],
        recoverRace,
        (RecoverArg(rc: (if i == 0: arc else: brc), instance: "w", expected: r), i),
      )
    joinThreads(u)
    let codes = @[raceCodes[0].load, raceCodes[1].load]
    check codes.count(ord(ecOk)) == 1
    check codes.count(ord(ecInvalidParams)) == 1
    check counterInits.load == inits + 1
    e.finish()

  test "[RUN-0633] when the state cannot be written, recovery is MODULE_ERROR and changes nothing":
    if asRoot():
      skip()
    else:
      let base = freshBase()
      let e = openEngine(pconfig(base)).tryGet
      let (_, arc) = e.startClient("a")
      discard e.create(counter(), "w").tryGet
      check arc.lifecycle("start_module", "counter_module", Opt.some("w")).code == ecOk
      e.failed("w")
      let r = e.rev("w")
      let inits = counterInits.load
      setMode(base / "store", 0o500)
      let refused = arc.recoverOn("w", r)
      setMode(base / "store", 0o700)
      check refused.code == ecModule
      check e.rev("w") == r
      check e.view("w").tryGet.state == msError
      check counterInits.load == inits
      check arc.recoverOn("w", r).code == ecOk
      e.finish()

suite "run.rc: retire_module (RUNTIME §9.3 l.3556-3595)":
  setup:
    reset()

  test "[RUN-1002] retire_module is authorized on its own":
    let e = newEngine(
      rconfig(denying(deny(operation = "retire_module")), @[declaring(counter())])
    )
    let (_, arc) = e.startClient("a")
    discard e.create(counter(), "w").tryGet
    check arc.retire(e, "w").code == ecNotAuthorised
    check arc.lifecycle("start_module", "counter_module", Opt.some("w")).code == ecOk
    check arc.lifecycle("stop_module", "counter_module", Opt.some("w")).code == ecOk
    check arc.createOn("counter_module", "k").code == ecOk
    check arc.retire(e, "w").code == ecNotAuthorised
    check e.view("w").isOk
    e.finish()

  test "[RUN-1003] [IMPL-DECISION G194] a target on another Runtime is INVALID_PARAMS without detail":
    let e = newEngine(rconfig())
    let (_, arc) = e.startClient("a")
    discard e.create(counter(), "w").tryGet
    let other = newRuntimeInstanceId()
    for target in ["w", "nobody"]:
      let r = arc.retireOn(other, target, 0)
      check r.code == ecInvalidParams
      check r.detail.len == 0
    check e.view("w").isOk
    e.finish()

  test "[RUN-1004] [RUN-1005] a stale revision is INVALID_PARAMS and changes nothing":
    let base = freshBase()
    let e = openEngine(pconfig(base)).tryGet
    let (_, arc) = e.startClient("a")
    discard e.create(counter(), "w").tryGet
    let changes = e.changes.len
    let before = readFile(base / "store" / SnapshotName)
    let r = arc.retireOn(e.runtimeInstanceId, "w", e.rev("w") + 1)
    check r.code == ecInvalidParams
    check r.detail.len == 0
    check e.changes.len == changes
    check readFile(base / "store" / SnapshotName) == before
    check e.view("w").isOk
    e.finish()

  test "[RUN-1006] [RUN-1007] [RUN-1008] [RUN-1009] retirement waits until no realization, cleanup or call remains":
    var cfg = rconfig(denying(deny(action = Opt.some(aaExecute), target = "denied")))
    # `w` stays `stopping` meanwhile: when the stop deadline passes, the instance
    # is `error` at a new revision, and a retirement that read the old one is
    # INVALID_PARAMS.
    cfg.stopDeadline = initDuration(seconds = 30)
    let e = newEngine(cfg)
    let (_, arc) = e.startClient("a")
    # `ready`
    discard e.create(counter(), "w").tryGet
    check e.start("w").tryGet.state == msReady
    check arc.retire(e, "w").code == ecNotReady
    # `stopping`, its destruction held
    counterDestroyGate.store(true)
    var t: Thread[(Engine, string)]
    check e.stopping("w", t)
    check arc.retire(e, "w").code == ecNotReady
    counterDestroyGate.store(false)
    joinThread(t)
    check arc.retire(e, "w").code == ecOk
    # `loaded`
    discard e.create(slow(), "s").tryGet
    slowGate.store(true)
    var s: Thread[(Engine, string)]
    startReply.store(-2)
    createThread(s, startOn, (e, "s"))
    # `_MODULE_init` waits; the revision read is the one after the bind.
    check waitUntil(
      proc(): bool =
        e.view("s").tryGet.state == msLoaded and arc.bound(e, "s")
    )
    check arc.retire(e, "s").code == ecNotReady
    slowGate.store(false)
    joinThread(s)
    # `unloaded` with `requested` intent: a start whose execution was denied.
    discard e.create(counter(), "denied").tryGet
    check e.start("denied").error.code == ecNotAuthorised
    check e.view("denied").tryGet.execution.intent == inRequested
    check arc.retire(e, "denied").code == ecNotReady
    e.finish()
    # `error` whose cleanup has not finished: the state alone is not the evidence.
    # The stop of an `error` instance whose cleanup is pending waits in
    # `stopping`; this engine's stop deadline (300 ms) ends it in `error` with
    # intent stopped, and nothing changes the revision after that.
    let f = newEngine(rconfig())
    let (_, frc) = f.startClient("a")
    discard f.create(counter(), "v").tryGet
    check f.start("v").tryGet.state == msReady
    counterDestroyGate.store(true)
    f.failed("v", cleaned = false)
    check f.stop("v").tryGet.execution.intent == inStopped
    check f.view("v").tryGet.state in {msError, msStopping}
    check frc.retire(f, "v").code == ecNotReady
    counterDestroyGate.store(false)
    check waitUntil(
      proc(): bool =
        frc.retire(f, "v").code == ecOk
    )
    # A call still in progress in a provider that failed.
    let m = f.started(meter(), "m")
    let route = frc.routeId("k")
    var h = frc.handle(route)
    gate.store(true)
    bgDone.store(false)
    var b: Thread[ptr LogosRouteHandle]
    createThread(b, background, addr h)
    check waitUntil(
      proc(): bool =
        held.load == 1
    )
    f.failed("m", cleaned = false)
    check f.stop("m").tryGet.execution.intent == inStopped
    check frc.retire(f, "m").code == ecNotReady
    gate.store(false)
    joinThread(b)
    h.release()
    check waitUntil(
      proc(): bool =
        frc.retire(f, "m").code == ecOk
    )
    check m.instance == "m"
    f.finish()

  test "[RUN-1010] [RUN-1013] an instance that is the origin of another's requested intent is not retired":
    let e = newEngine(rconfig())
    let (_, trc) = e.startClient("t")
    discard e.create(counter(), "w").tryGet
    check trc.lifecycle("start_module", "counter_module", Opt.some("w")).code == ecOk
    check e.stop("t").tryGet.execution.intent == inStopped
    let (_, arc) = e.startClient("a")
    check arc.retire(e, "t").code == ecNotReady
    # A stop cancels that intent; the origin left in history does not count.
    check e.stop("w").tryGet.execution.intent == inStopped
    check arc.retire(e, "t").code == ecOk
    check e.view("t").isErr
    e.finish()

  test "[RUN-1015] an instance the host configuration names is not retired":
    let e = newEngine(rconfig())
    discard e.bootstrap(
      @[
        BootstrapInstance(instance: "o", record: client()),
        BootstrapInstance(instance: "c", record: counter()),
      ],
      "o",
    ).tryGet
    let orc = cast[ptr LogosRuntimeControlBinding](clients[
      (clientInits.load - 1) mod MaxClients
    ].load)
    check orc.retire(e, "c").code == ecNotReady
    check e.view("c").isOk
    e.finish()

  test "[RUN-1018] [RUN-1022] [RUN-1012] [RUN-1017] [RUN-1019] [RUN-1014] retirement removes the instance durably before it answers, and nothing else":
    let base = freshBase()
    let e = openEngine(pconfig(base)).tryGet
    let (a, arc) = e.startClient("a")
    let m = e.started(meter(), "m")
    var h = arc.handle(arc.routeId("k1"))
    check h.read(3).tryGet.reading.value == 30
    h.release()
    check e.stop("m").tryGet.state == msUnloaded
    check e.changes.anyIt(it.view.instance == "m")
    let r = arc.retire(e, "m")
    check r.code == ecOk
    check r.response == @[0xA0'u8]
    # Durable before the answer: the store no longer lists it.
    let snap = stored(base)
    check snap.instances.allIt(it.instance != "m")
    check snap.retired.anyIt(it.instance == "m")
    # Gone: unknown to every later request.
    check e.view("m").isErr
    check arc.readiness("meter_module", Opt.some("m")).code == ecNotAuthorised
    check arc.lifecycle("start_module", "meter_module", Opt.some("m")).code ==
      ecNotAuthorised
    check arc.lifecycle("stop_module", "meter_module", Opt.some("m")).code ==
      ecNotAuthorised
    check arc.retireOn(e.runtimeInstanceId, "m", 0).code == ecNotAuthorised
    check not e.changes.anyIt(it.view.instance == "m")
    check arc.establish("k2", provider = Opt.some(providerAddress(m.providerId))).code !=
      ecOk
    # No cascade: the consumer keeps its state and intent.
    let after = e.view("a").tryGet
    check after.state == msReady
    check after.execution.intent == a.execution.intent
    e.finish()

  test "[RUN-1020] retirement keeps the state directory and its assignment reserved":
    let base = freshBase()
    let e = openEngine(pconfig(base)).tryGet
    let (_, arc) = e.startClient("a")
    discard e.create(counter(Opt.some("keep-1")), "w").tryGet
    check e.start("w").tryGet.state == msReady
    check dirExists(base / "state" / "keep-1")
    check e.stop("w").tryGet.state == msUnloaded
    check arc.retire(e, "w").code == ecOk
    check dirExists(base / "state" / "keep-1")
    check stored(base).retired.anyIt(
      it.instance == "w" and it.stateAssignment == Opt.some("keep-1")
    )
    check e.create(counter(Opt.some("keep-1")), "other").error.code == ecInvalidParams
    check e.create(counter(), "w").error.code == ecInvalidParams
    e.finish()

  test "[RUN-1016] after a restart, a configuration naming a retired instance is refused":
    let base = freshBase()
    var e = openEngine(pconfig(base)).tryGet
    let (_, arc) = e.startClient("a")
    discard e.create(counter(), "x").tryGet
    check arc.retire(e, "x").code == ecOk
    e.finish()
    e = openEngine(pconfig(base)).tryGet
    let r = e.bootstrap(
      @[
        BootstrapInstance(instance: "o", record: client()),
        BootstrapInstance(instance: "x", record: counter()),
      ],
      "o",
    )
    check r.isErr
    check r.error.code == ecInvalidParams
    check "x was retired" in r.error.message
    check e.view("o").isErr # nothing was created
    e.finish()

suite "run.rc: create_module (RUNTIME §9.3 l.3613-3634)":
  setup:
    reset()

  test "[RUN-0658] [RUN-1026] [IMPL-DECISION G195] a module with no declaration is refused as a denial is":
    let e = newEngine(
      rconfig(
        denying(deny(operation = "create_module", consumer = "d")),
        @[declaring(counter())],
      )
    )
    let (_, arc) = e.startClient("a")
    let (_, drc) = e.startClient("d")
    let count = e.list.len
    let missing = arc.createOn("meter_module", "k")
    let denied = drc.createOn("counter_module", "k")
    check missing.code == ecNotAuthorised
    check denied.code == ecNotAuthorised
    check missing.message == denied.message
    check missing.detail.len == 0 and denied.detail.len == 0
    check e.list.len == count
    # Nothing was kept for the key.
    check arc.createOn("counter_module", "k").code == ecOk
    e.finish()

  test "[RUN-0659] a created instance is fresh, unloaded and uninitialized, and its start is authorized apart":
    let e = newEngine(
      rconfig(
        denying(deny(operation = "start_module", consumer = "a")),
        @[declaring(counter()), declaring(meter())],
      )
    )
    let (_, arc) = e.startClient("a")
    let r = arc.createOn("meter_module", "k1")
    check r.code == ecOk
    let id = r.createdId
    check id.startsWith("m-") and isRuntimeForm(id)
    let v = e.view(id).tryGet
    check v.module == "meter_module"
    check v.state == msUnloaded
    check v.execution.intent == inUninitialized
    check v.providerId.startsWith("p-")
    check v.primaryContract == meter().primaryContract
    check arc.lifecycle("start_module", "meter_module", Opt.some(id)).code ==
      ecNotAuthorised
    check e.start(id).tryGet.state == msReady
    e.finish()

  test "[RUN-0660] [RUN-0661] [RUN-0662] a key replays its instance unchanged, and only for its module":
    let e =
      newEngine(rconfig(declarations = @[declaring(counter()), declaring(meter())]))
    let (_, arc) = e.startClient("a")
    let id = arc.createOn("counter_module", "k1").createdId
    check e.start(id).tryGet.state == msReady
    let before = e.view(id).tryGet
    let count = e.list.len
    let again = arc.createOn("counter_module", "k1")
    check again.code == ecOk
    check again.createdId == id
    let after = e.view(id).tryGet
    check after.state == msReady
    check after.execution == before.execution
    check e.list.len == count
    let other = arc.createOn("meter_module", "k1")
    check other.code == ecInvalidParams
    check other.detail.len == 0
    check e.list.len == count
    e.finish()

  test "[RUN-0663] concurrent requests with one key create one instance":
    let e = newEngine(rconfig(declarations = @[declaring(counter())]))
    let (_, arc) = e.startClient("a")
    let count = e.list.len
    var t: array[2, Thread[(ptr LogosRuntimeControlBinding, int)]]
    for i in 0 .. 1:
      createThread(t[i], createRace, (arc, i))
    joinThreads(t)
    let ids = @[createdBy(0), createdBy(1)]
    check ids[0].len > 0
    check ids[0] == ids[1]
    check e.list.len == count + 1
    e.finish()

  test "[IMPL] a key belongs to one consumer and to create_module alone":
    let e =
      newEngine(rconfig(declarations = @[declaring(counter()), declaring(meter())]))
    let (_, arc) = e.startClient("a")
    let (_, brc) = e.startClient("b")
    let mine = arc.createOn("counter_module", "k1").createdId
    let theirs = brc.createOn("counter_module", "k1").createdId
    check mine != theirs
    discard e.started(meter(), "m")
    check arc.establish("k1").code == ecOk
    check arc.createOn("counter_module", "k1").createdId == mine
    e.finish()

  test "[RUN-1028] after retirement the key creates a new instance":
    let e = newEngine(rconfig(declarations = @[declaring(counter())]))
    let (_, arc) = e.startClient("a")
    let first = arc.createOn("counter_module", "k9").createdId
    check arc.retire(e, first).code == ecOk
    let second = arc.createOn("counter_module", "k9").createdId
    check second != first
    e.finish()

  test "[RUN-1027] [RUN-0660] a changed declaration affects later creations only; keys survive a restart":
    let base = freshBase()
    var e = openEngine(pconfig(base, declarations = @[declaring(counter())])).tryGet
    var (_, arc) = e.startClient("a")
    let first = arc.createOn("counter_module", "k1").createdId
    e.finish()
    e = openEngine(
      pconfig(base, declarations = @[declaring(counter(binding = "counter2"))])
    ).tryGet
    check e.start("a").tryGet.state == msReady
    arc = cast[ptr LogosRuntimeControlBinding](clients[
      (clientInits.load - 1) mod MaxClients
    ].load)
    check arc.createOn("counter_module", "k1").createdId == first
    let second = arc.createOn("counter_module", "k2").createdId
    for s in stored(base).instances:
      if s.instance == first:
        check s.record.binding == "counter"
      if s.instance == second:
        check s.record.binding == "counter2"
    check e.start(first).tryGet.state == msReady
    check e.start(second).tryGet.state == msReady
    e.finish()

  test "[RUN-0272] [IMPL] a declaration with persistent state gives each instance a fresh assignment":
    let base = freshBase()
    let e = openEngine(
      pconfig(base, declarations = @[declaring(counter(), persistentState = true)])
    ).tryGet
    let (_, arc) = e.startClient("a")
    let one = arc.createOn("counter_module", "k1").createdId
    let two = arc.createOn("counter_module", "k2").createdId
    let s1 = e.view(one).tryGet.stateAssignment.get
    let s2 = e.view(two).tryGet.stateAssignment.get
    check s1 != s2
    check s1.startsWith("s-") and isRuntimeForm(s1)
    check e.start(one).tryGet.state == msReady
    check dirExists(base / "state" / s1)
    e.finish()

  test "[IMPL] past MaxInstances known instances, create_module is MODULE_ERROR":
    let e = newEngine(rconfig(declarations = @[declaring(counter())]))
    let (_, arc) = e.startClient("a")
    for i in e.list.len ..< MaxInstances:
      discard e.create(counter()).tryGet
    let r = arc.createOn("counter_module", "k")
    check r.code == ecModule
    check e.list.len == MaxInstances
    e.finish()
