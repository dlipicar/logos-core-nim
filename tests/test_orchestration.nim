## The reference orchestration module at engine level (DECISIONS I94; RUNTIME
## §10.1 l.3774-3790, l.3801-3808): the engine, `lcn_orchestrator` registered
## from `orchestratorStaticSymbols()` as the orchestration instance, the
## `flaky_module` test kit (`tests/kit/flaky_impl.nim`), and a state directory
## under the test's work directory. Cases that change authority at run time
## bind the scripted Capability Authority (`support/fakeca.nim`).
##
## Module code runs on the engine's workers and the module's own worker, so
## the test reads what happened through atomics, the module's call record
## (its test hooks) and its state file. Spacing is asserted with lower bounds;
## upper bounds are `Slow`-scaled ceilings.

import std/[atomics, locks, monotimes, os, strutils, tables, times]
import unittest2
import ../src/logos_core/runtime/[configcheck, engine]
import ../src/logos_core/orchestration
import ../src/logos_core/orchestration/[accounting, testhooks]
import ../src/logos_core/kit/rcclient
import ../src/logos_core/loader/contract
import ./support/[fakeca, slowdown, tunerconfig]
import ./kit/[flaky_impl, tuner_impl]

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "orchestration"
removeDir(work)
createDir(work)

const
  Orch = "orch"
  Ca = "ca"
  OrchState = "orch-state"
  Flaky = "flaky_module"

let clk = newTestClock()
useClock(clk)

# Diagnostics: plain bytes behind a lock, written on the module's worker ---------------

var
  diagLock: Lock
  diagBuf: ptr UncheckedArray[char]
  diagLen: int
const DiagCap = 1 shl 20
initLock(diagLock)
diagBuf = cast[ptr UncheckedArray[char]](allocShared0(DiagCap))

proc sink(line: string) {.nimcall, gcsafe, raises: [].} =
  withLock diagLock:
    for c in line & "\n":
      if diagLen < DiagCap:
        diagBuf[diagLen] = c
        inc diagLen

proc diagText(): string =
  withLock diagLock:
    result = newString(diagLen)
    for i in 0 ..< diagLen:
      result[i] = diagBuf[i]

proc clearDiag() =
  withLock diagLock:
    diagLen = 0

setOrchestratorDiagnostics(sink)

# Engine set-up ----------------------------------------------------------------------

var
  engines = 0
  live: Engine
  stateDir: string

proc ms(n: int): int64 =
  int64(n) * Slow

proc waitUntil(cond: proc(): bool {.closure.}, seconds = 10 * Slow): bool =
  let until = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < until:
    if cond():
      return true
    sleep(2)
  cond()

proc flakyRecord(): ModuleRecord =
  ModuleRecord(module: Flaky, strategy: stDirectStatic, binding: "flaky")

proc restart(
    initial = 20, maxMs = 200, mult = 2, attempts = 3, stable = 100
): LcnOrchestratorRestart =
  LcnOrchestratorRestart(
    kind: LcnOrchestratorRestartKind.Backoff,
    arm_Backoff: LcnOrchestratorRestartARBackoffMap(
      initial_delay_ms: uint32(ms(initial)),
      max_delay_ms: uint32(ms(maxMs)),
      multiplier: uint32(mult),
      max_attempts: (if attempts > 0: Opt.some(uint32(attempts))
      else: Opt.none(uint32)),
      stable_ms: uint32(ms(stable)),
    ),
  )

func disabled(): LcnOrchestratorRestart =
  LcnOrchestratorRestart(
    kind: LcnOrchestratorRestartKind.Disabled,
    arm_Disabled: LcnOrchestratorRestartARDisabledMap(),
  )

proc starts(slots: varargs[int]): Opt[seq[LcnOrchestratorDefault]] =
  var ds: seq[LcnOrchestratorDefault]
  for s in slots:
    ds.add(LcnOrchestratorDefault(module: Flaky, instance: flakyInstance(s)))
  Opt.some(ds)

proc value(
    defaults = Opt.none(seq[LcnOrchestratorDefault]),
    restart = Opt.some(restart()),
    ordering = Opt.none(seq[LcnOrchestratorOrder]),
    overrides = Opt.none(seq[LcnOrchestratorOverride]),
    authority = false,
    resync = 200,
): OrchestratorSettings =
  OrchestratorSettings(
    authority: (
      if authority:
        Opt.some(LcnOrchestratorTarget(module: CaModuleName, instance: Ca))
      else:
        Opt.none(LcnOrchestratorTarget)
    ),
    defaults: defaults,
    ordering: ordering,
    restart: restart,
    overrides: overrides,
    resync_ms: Opt.some(uint32(ms(resync))),
  )

proc accepted(v: OrchestratorSettings): AcceptedConfiguration =
  acceptConfiguration(
    orchestratorDeclaration().tryGet, provisioned = Opt.some(encodeSettings(v).tryGet)
  ).tryGet

proc orchRecord(a: AcceptedConfiguration): ModuleRecord =
  ModuleRecord(
    module: OrchestratorModule,
    strategy: stDirectStatic,
    binding: OrchestratorBinding,
    stateAssignment: Opt.some(OrchState),
    configuration: Opt.some(a.digest),
  )

proc orchConfig(policy = allowAll(), authority = false): EngineConfig =
  inc engines
  let dir = work / ("e" & $engines)
  result = defaultConfig(dir)
  result.stateRoot = Opt.some(dir / "state")
  stateDir = dir / "state" / OrchState
  result.policy = policy
  result.stopDeadline = initDuration(milliseconds = ms(300))
  result.statics = @[
    checkStaticRegistration(OrchestratorBinding, orchestratorStaticSymbols()).tryGet,
    checkStaticRegistration("flaky", flakyModuleStaticSymbols()).tryGet,
    checkStaticRegistration("tuner_kit", tunerModuleStaticSymbols()).tryGet,
  ]
  if authority:
    result.statics.add(fakeCaRegistration())
    result.authority = Opt.some(
      AuthorityPolicy(instance: Ca, evaluationDeadline: initDuration(seconds = 60))
    )
    result.clock = clk

proc boot(
    v: OrchestratorSettings,
    slots: seq[int] = @[0],
    policy = allowAll(),
    extra: seq[BootstrapInstance] = @[],
    before: proc(e: Engine) {.closure.} = nil,
): Engine =
  ## A new engine with `orch` (holding the role, configured with `v`), the
  ## flaky instances of `slots`, the Capability Authority when `v` names one,
  ## and `extra`, bootstrapped.
  let authority = v.authority.isSome
  let e = newEngine(orchConfig(policy, authority))
  live = e
  if not before.isNil:
    before(e)
  let a = accepted(v)
  var all = @[
    BootstrapInstance(instance: Orch, record: orchRecord(a), configuration: Opt.some(a))
  ]
  if authority:
    all.add(BootstrapInstance(instance: Ca, record: fakeCaRecord()))
  for s in slots:
    all.add(BootstrapInstance(instance: flakyInstance(s), record: flakyRecord()))
  all.add(extra)
  let r = e.bootstrap(all, Orch)
  doAssert r.isOk, r.error.message
  e

proc finish(e: Engine) =
  if live == e:
    live = nil
  for i in 0 ..< FlakySlots:
    flaky[i].initGate.store(false)
    flaky[i].destroyGate.store(false)
  openPauseGateForTests()
  e.shutdown()
  check e.close(initDuration(seconds = 10 * Slow))

proc leftover() =
  if live != nil:
    live.finish()

proc state(e: Engine, id: string): ModuleState =
  e.view(id).tryGet.state

proc isReady(e: Engine, id: string): proc(): bool =
  result = proc(): bool =
    e.state(id) == msReady

proc entries(): Accounting =
  ## The state file as the module last wrote it.
  let path = stateDir / StateFileName
  if not fileExists(path):
    return Accounting()
  let s = readFile(path)
  var b = newSeq[byte](s.len)
  for i, c in s:
    b[i] = byte(c)
  decodeState(b).tryGet

proc entryOf(id: string): Opt[Entry] =
  let a = entries()
  if id in a.entries:
    Opt.some(a.entries.getOrDefault(id))
  else:
    Opt.none(Entry)

proc recovers(id: string): int =
  callsForTests("recover_module", id)

proc gapsMs(times: seq[int64]): seq[int64] =
  for i in 1 ..< times.len:
    result.add((times[i] - times[i - 1]) div 1_000_000)

proc reportFailure(e: Engine, id: string) =
  let v = e.view(id).tryGet
  check e.reportFailure(id, v.attempt, "test").isOk

proc imports(path: string): seq[string] =
  ## The module paths a Nim source's import and include statements name.
  for raw in readFile(path).splitLines:
    let line = raw.strip
    for kw in ["import ", "include ", "from "]:
      if line.startsWith(kw):
        var rest = line[kw.len .. ^1]
        let cut = rest.find(" import ")
        if cut >= 0:
          rest = rest[0 ..< cut]
        result.add(rest)

suite "orch: the reference orchestration module (RUNTIME §10.1) [IMPL-DECISION G287] [IMPL-DECISION G288] [IMPL-DECISION G289] [IMPL-DECISION G290] [IMPL-DECISION G291]":
  setup:
    resetFlaky()
    clearOrchestratorFaultsForTests()
    clearDiag()
    resetFake()

  teardown:
    leftover()

  test "[RUN-0021] [RUN-0022] it requests only through its binding, as the origin of what it starts; the role confers nothing; it never calls the Loader":
    let src = repo / "src" / "logos_core"
    var files = @[src / "kit" / "rcclient.nim"]
    for f in walkDir(src / "orchestration"):
      if f.path.endsWith(".nim"):
        files.add(f.path)
    check files.len >= 10
    for f in files:
      for imp in imports(f):
        for banned in ["engine", "host", "plumbing", "realizer"]:
          check banned notin
            imp.replace("host_config", "").split({'/', '[', ']', ',', ' ', '.'})
    let e = boot(
      value(defaults = starts(0, 1)),
      slots = @[0, 1],
      policy = denying(
        deny(consumer = Orch, target = flakyInstance(1), operation = "start_module")
      ),
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    let v = e.view(flakyInstance(0)).tryGet
    check v.intentOrigin.instance == Orch and not v.intentOrigin.host
    check waitUntil(
      proc(): bool =
        callsForTests("start_module", flakyInstance(1)) >= 2
    )
    let w = e.view(flakyInstance(1)).tryGet
    check w.execution.intent == inUninitialized
    check flaky[1].inits.load == 0
    check LoaderInstanceId notin targetsForTests()
    check entryOf(flakyInstance(1)).isNone # refused defaults are never written
    e.finish()

  test "[RUN-0025] startup defaults: start, stop, unlisted, already stopped":
    let defaults = Opt.some(
      @[
        LcnOrchestratorDefault(module: Flaky, instance: flakyInstance(0)),
        LcnOrchestratorDefault(
          module: Flaky,
          instance: flakyInstance(1),
          action: Opt.some(
            LcnOrchestratorDefaultActionChoice(
              kind: LcnOrchestratorDefaultActionChoiceKind.Stop
            )
          ),
        ),
        LcnOrchestratorDefault(module: Flaky, instance: flakyInstance(3)),
      ]
    )
    let e = boot(
      value(defaults = defaults),
      slots = @[0, 1, 2],
      before = proc(e: Engine) =
        discard e.create(flakyRecord(), flakyInstance(3)).tryGet
        discard e.stop(flakyInstance(3)).tryGet,
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    check waitUntil(
      proc(): bool =
        e.view(flakyInstance(1)).tryGet.execution.intent == inStopped
    )
    sleep(int(ms(200)))
    check e.view(flakyInstance(2)).tryGet.execution.intent == inUninitialized
    check e.view(flakyInstance(3)).tryGet.execution.intent == inStopped
    check callsForTests("start_module", flakyInstance(3)) == 0
    check flaky[2].inits.load == 0 and flaky[3].inits.load == 0
    e.finish()

  test "[RUN-0025] a stop between the read and the guarded request: INVALID_PARAMS, read again, nothing done":
    setOrchestratorFaultsForTests(OrchestratorFaults(pauseBeforeRequest: true))
    let e = boot(value(defaults = starts(4)), slots = @[4])
    check waitUntil(
      proc(): bool =
        pausedForTests() >= 1
    )
    discard e.stop(flakyInstance(4)).tryGet
    let reads = callsForTests("get_readiness", flakyInstance(4))
    openPauseGateForTests()
    check waitUntil(
      proc(): bool =
        "start_module flaky-4: answered INVALID_PARAMS" in diagText()
    )
    check waitUntil(
      proc(): bool =
        callsForTests("get_readiness", flakyInstance(4)) > reads
    )
    sleep(int(ms(200)))
    check e.view(flakyInstance(4)).tryGet.execution.intent == inStopped
    check callsForTests("start_module", flakyInstance(4)) == 1
    check flaky[4].inits.load == 0
    e.finish()

  test "[RUN-0684] [RUN-0686] failures are recovered on the backoff, then the episode closes after stable_ms":
    flaky[0].failInits.store(3)
    let e = boot(
      value(
        defaults = starts(0), restart = Opt.some(restart(attempts = 5, stable = 150))
      )
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    check recovers(flakyInstance(0)) == 3
    let started = callTimesForTests("start_module", flakyInstance(0))
    let calls = callTimesForTests("recover_module", flakyInstance(0))
    check started.len == 1 and calls.len == 3
    let g = gapsMs(@[started[0]] & calls)
    check g[0] >= ms(20) - 2 # delay(0) after the failure was seen
    check g[1] >= ms(20) - 2 # delay(1)
    check g[2] >= ms(40) - 2 # delay(2)
    check entryOf(flakyInstance(0)).get.attempts == 3
    check waitUntil(
      proc(): bool =
        entryOf(flakyInstance(0)).isNone
    )
    e.finish()

  test "[RUN-0686] always failing: exactly max_attempts recoveries, a diagnostic, nothing more":
    flaky[0].failInits.store(1000)
    let e = boot(
      value(
        defaults = starts(0), restart = Opt.some(restart(attempts = 3, maxMs = 100))
      )
    )
    check waitUntil(
      proc(): bool =
        "restart attempts exhausted after 3 of 3" in diagText()
    )
    sleep(int(ms(300)))
    check recovers(flakyInstance(0)) == 3
    check entryOf(flakyInstance(0)).get.exhausted
    check e.state(flakyInstance(0)) == msError
    e.finish()

  test "[RUN-0684] disabled: a failure is never recovered":
    flaky[0].failInits.store(1)
    let e = boot(value(defaults = starts(0), restart = Opt.some(disabled())))
    check waitUntil(
      proc(): bool =
        e.state(flakyInstance(0)) == msError
    )
    sleep(int(ms(300)))
    check recovers(flakyInstance(0)) == 0
    check "the restart policy is disabled" in diagText()
    e.finish()

  test "[RUN-0687] an explicit stop drops the armed recovery and its episode":
    flaky[0].failInits.store(3)
    let e = boot(
      value(
        defaults = starts(0),
        restart = Opt.some(restart(initial = 50, maxMs = 800, mult = 16, attempts = 9)),
      )
    )
    check waitUntil(
      proc(): bool =
        recovers(flakyInstance(0)) == 2 and flaky[0].inits.load == 3 and
          e.state(flakyInstance(0)) == msError
    )
    check waitUntil(
      proc(): bool =
        entryOf(flakyInstance(0)).isSome and entryOf(flakyInstance(0)).get.pending.isNone
    )
    discard e.stop(flakyInstance(0)).tryGet
    check waitUntil(
      proc(): bool =
        entryOf(flakyInstance(0)).isNone
    )
    sleep(int(ms(1000)))
    check recovers(flakyInstance(0)) == 2
    e.finish()

  test "[RUN-0687] shutdown with a recovery armed returns promptly and calls nothing after":
    flaky[0].failInits.store(1)
    let e = boot(
      value(
        defaults = starts(0), restart = Opt.some(restart(initial = 5000, maxMs = 5000))
      )
    )
    check waitUntil(
      proc(): bool =
        e.state(flakyInstance(0)) == msError
    )
    sleep(int(ms(50)))
    let t0 = getMonoTime()
    live = nil
    e.shutdown()
    check (getMonoTime() - t0).inMilliseconds < ms(2000)
    let n = targetsForTests().len
    sleep(int(ms(200)))
    check targetsForTests().len == n
    check recovers(flakyInstance(0)) == 0
    check e.close(initDuration(seconds = 10 * Slow))

  test "[RUN-0686] a lost answer is charged once; the restarted module reads before it decides":
    flaky[0].failInits.store(1)
    let e = boot(
      value(
        defaults = starts(0), restart = Opt.some(restart(attempts = 5, stable = 5000))
      )
    )
    check waitUntil(
      proc(): bool =
        "start_module flaky-0: answered" in diagText()
    )
    setOrchestratorFaultsForTests(OrchestratorFaults(dropNextAnswer: true))
    check waitUntil(
      proc(): bool =
        haltedForTests() == 1
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    let left = entryOf(flakyInstance(0)).get
    check left.pending.isSome and left.attempts == 1
    discard e.stop(Orch).tryGet
    check e.start(Orch).tryGet.state == msReady
    check waitUntil(
      proc(): bool =
        entryOf(flakyInstance(0)).isSome and entryOf(flakyInstance(0)).get.pending.isNone
    )
    check entryOf(flakyInstance(0)).get.attempts == 1
    sleep(int(ms(100)))
    check recovers(flakyInstance(0)) == 1
    check e.state(flakyInstance(0)) == msReady
    e.finish()

  test "[RUN-0686] [RUN-1063] [RUN-1065] an episode continues charged across an orchestration restart; a failure while it was down is resumed once, uncharged":
    flaky[0].failInits.store(3)
    let e = boot(
      value(
        defaults = starts(0, 1),
        restart = Opt.some(restart(initial = 50, maxMs = 3000, mult = 16, attempts = 9)),
      ),
      slots = @[0, 1],
    )
    check waitUntil(e.isReady(flakyInstance(1)))
    check waitUntil(
      proc(): bool =
        recovers(flakyInstance(0)) == 2 and flaky[0].inits.load == 3 and
          e.state(flakyInstance(0)) == msError and entryOf(flakyInstance(0)).isSome and
          entryOf(flakyInstance(0)).get.pending.isNone
    )
    e.reportFailure(Orch)
    check waitUntil(
      proc(): bool =
        e.state(Orch) == msError
    )
    let before = recovers(flakyInstance(1))
    e.reportFailure(flakyInstance(1))
    check waitUntil(
      proc(): bool =
        e.state(flakyInstance(1)) == msError
    )
    sleep(int(ms(150)))
    check recovers(flakyInstance(1)) == before # nothing while it is down (l.3806)
    let r = e.view(Orch).tryGet.execution.revision
    check e.recover(Orch, r).tryGet.state == msReady
    check waitUntil(e.isReady(flakyInstance(1)))
    check recovers(flakyInstance(1)) == before + 1
    check entryOf(flakyInstance(1)).isNone # a resumption is never charged
    check waitUntil(e.isReady(flakyInstance(0)))
    check entryOf(flakyInstance(0)).get.attempts == 3 # the episode went on at 2
    e.finish()

  test "[RUN-1065] [RUN-0684] another consumer's instance is recovered, and keeps its origin":
    flaky[2].failInits.store(1)
    let e = boot(value(), slots = @[2, 5])
    check e.start(flakyInstance(5)).tryGet.state == msReady
    discard e.start(flakyInstance(2), origin = moduleOrigin(flakyInstance(5)))
    check waitUntil(e.isReady(flakyInstance(2)))
    check recovers(flakyInstance(2)) == 1
    check e.view(flakyInstance(2)).tryGet.intentOrigin.instance == flakyInstance(5)
    e.finish()

  test "[RUN-1065] [IMPL-DECISION G287] a dependent's start waits until its prerequisite is ready":
    flaky[0].initGate.store(true)
    let e = boot(
      value(
        defaults = starts(0, 1),
        ordering = Opt.some(
          @[
            LcnOrchestratorOrder(
              prerequisite: flakyInstance(0), dependent: flakyInstance(1)
            )
          ]
        ),
      ),
      slots = @[0, 1],
    )
    check waitUntil(
      proc(): bool =
        flaky[0].heldInit.load == 1
    )
    sleep(int(ms(150)))
    check callsForTests("start_module", flakyInstance(1)) == 0
    let opened = getMonoTime().ticks
    flaky[0].initGate.store(false)
    check waitUntil(e.isReady(flakyInstance(1)))
    let t = callTimesForTests("start_module", flakyInstance(1))
    check t.len == 1 and t[0] >= opened
    check "NOT_READY" notin diagText()
    e.finish()

  test "[RUN-1065] [RUN-0696] a recovery refused for the origin's authority is an uncharged, spaced probe; allowed again, it recovers":
    setScript(rule(vDeny, what = "execute", consumer = Orch))
    let e = boot(
      value(
        defaults = starts(0),
        authority = true,
        restart = Opt.some(restart(initial = 30, maxMs = 120, attempts = 2)),
      )
    )
    check waitUntil(
      proc(): bool =
        recovers(flakyInstance(0)) >= 3
    )
    check e.view(flakyInstance(0)).tryGet.execution.intent == inRequested
    let g = gapsMs(callTimesForTests("recover_module", flakyInstance(0)))
    for i, x in g:
      check x >= ms(30) - 2
    check entryOf(flakyInstance(0)).isNone # never charged, never exhausted
    setScript()
    check waitUntil(e.isReady(flakyInstance(0)))
    e.finish()

  test "[RUN-1065] a recovery refused while cleanup is pending is refunded; it recovers once cleanup ends":
    let e = boot(
      value(defaults = starts(0), restart = Opt.some(restart(attempts = 3, maxMs = 60)))
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    flaky[0].destroyGate.store(true)
    e.reportFailure(flakyInstance(0))
    # Each refusal is refunded: between calls nothing stays charged, and
    # max_attempts (3) is never reached however often it is refused.
    check waitUntil(
      proc(): bool =
        let x = entryOf(flakyInstance(0))
        recovers(flakyInstance(0)) >= 4 and x.isSome and x.get.calls >= 4 and
          x.get.pending.isNone and x.get.attempts == 0
    )
    check e.state(flakyInstance(0)) == msError
    check "exhausted" notin diagText()
    flaky[0].destroyGate.store(false)
    check waitUntil(e.isReady(flakyInstance(0)))
    check "exhausted" notin diagText()
    e.finish()

  test "[RUN-0983] with every hint lost, the periodic resync alone finds a failure":
    setOrchestratorFaultsForTests(OrchestratorFaults(suppressHints: true))
    let e = boot(value(defaults = starts(0), resync = 200))
    check waitUntil(e.isReady(flakyInstance(0)))
    e.reportFailure(flakyInstance(0))
    check waitUntil(
      proc(): bool =
        recovers(flakyInstance(0)) == 1 and e.state(flakyInstance(0)) == msReady
    )
    e.finish()

  test "[RUN-1065] [IMPL-DECISION G288] a missing configuration: the configuration event brings the probe forward":
    let a = tunerAccepted()
    let tuner = ModuleRecord(
      module: "tuner_module",
      strategy: stDirectStatic,
      binding: "tuner_kit",
      configuration: Opt.some(a.digest),
    )
    let e = boot(
      value(
        defaults = Opt.some(
          @[
            LcnOrchestratorDefault(module: Flaky, instance: flakyInstance(0)),
            LcnOrchestratorDefault(module: "tuner_module", instance: "t1"),
          ]
        ),
        overrides = Opt.some(
          @[
            LcnOrchestratorOverride(
              instance: "t1", restart: restart(initial = 50, maxMs = 5000, mult = 16)
            )
          ]
        ),
      ),
      extra =
        @[BootstrapInstance(instance: "t1", record: tuner, configuration: Opt.some(a))],
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    # start NOT_READY, then probes at +50 and +800: the next is 5 s away.
    check waitUntil(
      proc(): bool =
        recovers("t1") >= 2
    )
    check e.view("t1").tryGet.execution.intent == inRequested
    let rc = flakyBinding(0)
    let t = LogosNSRuntimeModuleInstanceAddress(
      runtime_instance_id: e.runtimeInstanceId(), module_instance_id: "t1"
    )
    let staged = call(
      rc,
      "update_configuration",
      LogosNSRuntimeControlUpdateConfigurationRequest(
        kind: LogosNSRuntimeControlUpdateConfigurationRequestKind.Stage,
        arm_Stage: LogosNSRuntimeControlUpdateConfigurationRequestARStageMap(
          target: t,
          expected_state_revision: 0,
          expected_schema_commitment: tunerCommitment(),
          value: tunerValue(),
        ),
      ),
      LogosNSRuntimeControlUpdateConfigurationResponse,
    )
    check staged.isOk
    let t0 = getMonoTime()
    check waitUntil(e.isReady("t1"), seconds = 3 * Slow)
    check (getMonoTime() - t0).inMilliseconds < ms(2500)
    e.finish()

  test "[RUN-1063] while the orchestration instance is failed nothing is recovered; recovered, it reconciles":
    let e = boot(value(defaults = starts(0)))
    check waitUntil(e.isReady(flakyInstance(0)))
    e.reportFailure(Orch)
    check waitUntil(
      proc(): bool =
        e.state(Orch) == msError
    )
    e.reportFailure(flakyInstance(0))
    sleep(int(ms(200)))
    check recovers(flakyInstance(0)) == 0
    check e.state(flakyInstance(0)) == msError
    check e.recover(Orch, e.view(Orch).tryGet.execution.revision).tryGet.state == msReady
    check waitUntil(e.isReady(flakyInstance(0)))
    check recovers(flakyInstance(0)) == 1
    check entryOf(flakyInstance(0)).isNone
    e.finish()

  test "[RUN-1063] [IMPL-DECISION G290] until active policy answers list_modules nothing is started, and the probes are spaced":
    setScript(rule(vDeny, what = "rc:list_modules", consumer = Orch))
    let e = boot(value(defaults = starts(0), authority = true))
    check waitUntil(
      proc(): bool =
        e.state(Ca) == msReady
    )
    sleep(int(ms(600)))
    check e.view(flakyInstance(0)).tryGet.execution.intent == inUninitialized
    let probes = callsForTests("list_modules")
    # 50 ms doubling: at most 50, 100, 200, 400 in 600 ms, plus slack.
    check probes >= 2 and probes <= 6
    setScript()
    check waitUntil(e.isReady(flakyInstance(0)))
    e.finish()

  test "[RUN-0025] a start default refused before acceptance is retried, spaced and uncharged":
    setScript(rule(vDeny, what = "rc:start_module", consumer = Orch))
    let e = boot(
      value(
        defaults = starts(0),
        authority = true,
        restart = Opt.some(restart(initial = 30, maxMs = 120)),
      )
    )
    check waitUntil(
      proc(): bool =
        callsForTests("start_module", flakyInstance(0)) >= 3
    )
    check e.view(flakyInstance(0)).tryGet.execution.intent == inUninitialized
    for x in gapsMs(callTimesForTests("start_module", flakyInstance(0))):
      check x >= ms(30) - 2
    check entryOf(flakyInstance(0)).isNone
    setScript()
    check waitUntil(e.isReady(flakyInstance(0)))
    e.finish()

  test "[RUN-0696] [RUN-1065] [IMPL-DECISION G291] an enforcement stop past its deadline is resumed by an uncharged probe, under disabled too":
    let e = boot(value(defaults = starts(0), restart = Opt.some(disabled())))
    check waitUntil(e.isReady(flakyInstance(0)))
    flaky[0].destroyGate.store(true)
    discard e.stopForAuthority(flakyInstance(0), fkAuthorityRevoked)
    check waitUntil(
      proc(): bool =
        let v = e.view(flakyInstance(0)).tryGet
        v.state == msError and v.failure.isSome and
          v.failure.get.kind == fkCleanupTimeout
    )
    flaky[0].destroyGate.store(false)
    check waitUntil(e.isReady(flakyInstance(0)))
    check recovers(flakyInstance(0)) >= 1
    check entryOf(flakyInstance(0)).isNone
    e.finish()
