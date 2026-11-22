## The reference orchestration module at engine level (DECISIONS I94; RUNTIME
## §10.1 l.3774-3790, l.3801-3808): the engine, `lcn_orchestrator` registered
## from `orchestratorStaticSymbols()` as the orchestration instance, the
## `flaky_module` test kit (`tests/kit/flaky_impl.nim`), and a state directory
## under the test's work directory. Cases that change authority at run time
## bind the scripted Capability Authority (`support/fakeca.nim`). Cases on
## permissions select the shipped profile (DECISIONS I93) and change an
## instance's settings with `update_permission_settings`, called as another
## flaky instance.
##
## Module code runs on the engine's workers and the module's own worker, so
## the test reads what happened through atomics, the module's call record
## (its test hooks) and its state file. Spacing is asserted with lower bounds;
## upper bounds are `Slow`-scaled ceilings.

import std/[algorithm, atomics, locks, monotimes, os, sequtils, strutils, tables, times]
import unittest2
import ../src/logos_core/runtime/[configcheck, engine]
from ../src/logos_core/runtime/rcevents import setRcDrainDelayForTests
import ../src/logos_core/orchestration
import ../src/logos_core/orchestration/[accounting, testhooks]
import logos_sdk/kit/[rc_arms, rcclient]
import ../src/logos_core/loader/contract
import ./support/[coretuner, fakeca, permfixture, slowdown]
import ./kit/flaky_impl, logos_sdk/testing/fixtures/tuner_impl

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

const Patience = 30 * Slow
  ## Seconds a case waits for what will happen. CI's x86 runners ran these
  ## suites 5 to 13 times slower than framework.lan (run 43589472593); only a
  ## failing case waits this long.

proc waitUntil(cond: proc(): bool {.closure.}, seconds = Patience): bool =
  let until = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < until:
    if cond():
      return true
    sleep(2)
  cond()

proc cleaned(e: Engine, id: string): bool =
  ## [SPEC RUNTIME l.613, l.3538] The cleanup of `id`'s previous realization
  ## has ended: before it, a start or recovery is NOT_READY, and its commit
  ## would make a revision read earlier stale.
  waitUntil(
    proc(): bool =
      not e.cleanupPending(id)
  )

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

proc orchConfig(
    policy = allowAll(),
    authority = false,
    profiled = false,
    perms: seq[InitialSettings] = @[],
    profile: ProfileSource = profileV1,
): EngineConfig =
  ## With `profiled`, `profile` (the shipped one unless a case says) is
  ## selected and the orchestration and flaky modules are provisioned with
  ## host-ambient; `perms` come after, so an instance's entry overrides its
  ## module's.
  inc engines
  let dir = work / ("e" & $engines)
  result = defaultConfig(dir)
  result.stateRoot = Opt.some(dir / "state")
  stateDir = dir / "state" / OrchState
  result.policy = policy
  result.stopDeadline = initDuration(milliseconds = ms(300))
  if profiled:
    result.permissions = profile
    for m in [OrchestratorModule, Flaky]:
      result.initialSettings.add(InitialSettings(module: m, permissions: @[ambient()]))
    result.initialSettings.add(perms)
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
    profiled = false,
    perms: seq[InitialSettings] = @[],
    profile: ProfileSource = profileV1,
): Engine =
  ## A new engine with `orch` (holding the role, configured with `v`), the
  ## flaky instances of `slots`, the Capability Authority when `v` names one,
  ## and `extra`, bootstrapped.
  let authority = v.authority.isSome
  let e = newEngine(orchConfig(policy, authority, profiled, perms, profile))
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
  check e.close(initDuration(seconds = Patience))

proc leftover() =
  if live != nil:
    live.finish()

proc state(e: Engine, id: string): ModuleState =
  e.view(id).tryGet.state

proc isReady(e: Engine, id: string): proc(): bool =
  result = proc(): bool =
    e.state(id) == msReady

proc entries(): Accounting =
  ## The state file as the module last wrote it. On Windows a read can meet the
  ## module's replacing rename and fail to open the file, which a POSIX rename
  ## never shows (step 5-4's Windows run), so the read is retried.
  let path = stateDir / StateFileName
  for attempt in 0 ..< 200:
    if not fileExists(path):
      return Accounting()
    try:
      let s = readFile(path)
      var b = newSeq[byte](s.len)
      for i, c in s:
        b[i] = byte(c)
      return decodeState(b).tryGet
    except IOError:
      sleep(5)
  raise newException(IOError, "cannot read " & path)

proc entryOf(id: string): Opt[Entry] =
  let a = entries()
  if id in a.entries:
    Opt.some(a.entries.getOrDefault(id))
  else:
    Opt.none(Entry)

proc recovers(id: string): int =
  callsForTests("recover_module", id)

proc settled(id: string): proc(): bool =
  ## [IMPL] Every `recover_module` call on `id` counted so far is answered
  ## (the module's diagnostics). A probe is counted when the module sends it;
  ## until its answer the Runtime may still decide it, and decided after a
  ## settings replacement it is that replacement's resumption, not a refused
  ## probe (x86_64 orc-release CI, 2026-11-15).
  result = proc(): bool =
    diagText().count("recover_module " & id & ": answered") >= recovers(id)

proc recoverAnswers(id: string): seq[string] =
  ## How each answered `recover_module` call on `id` was answered (the
  ## module's diagnostics), in order: the state an accepted call reached, or the
  ## refusal.
  let marker = "recover_module " & id & ": answered "
  for line in diagText().splitLines:
    let at = line.find(marker)
    if at >= 0:
      result.add(line[at + marker.len .. ^1])

proc explain(e: Engine) =
  ## What the module and the engine reported, printed if a later check fails.
  checkpoint "orchestrator: " & diagText()
  checkpoint "engine: " & e.diagnostics().join(" | ")

proc gapsMs(times: seq[int64]): seq[int64] =
  for i in 1 ..< times.len:
    result.add((times[i] - times[i - 1]) div 1_000_000)

proc reportFailure(e: Engine, id: string) =
  let v = e.view(id).tryGet
  check e.reportFailure(id, v.attempt, "test").isOk

type SettingsView = LogosNSRuntimeControlPermissionSettingsState

func status(s: SettingsView): string =
  ($s.application.kind).toLowerAscii

proc settingsAs(e: Engine, slot: int, id: string): SettingsView =
  ## `id`'s permission settings, read as flaky instance `slot`.
  let t = LogosNSRuntimeModuleInstanceAddress(
    runtime_instance_id: e.runtimeInstanceId(), module_instance_id: id
  )
  let r = call(
    flakyBinding(slot),
    "get_permission_settings",
    LogosNSRuntimeControlGetPermissionSettingsRequest(target: t),
    LogosNSRuntimeControlGetPermissionSettingsResponse,
  )
  check r.isOk
  if r.isOk:
    result = r.get.state

proc replaceSettings(
    e: Engine, slot: int, id: string, xs: seq[PermissionSetting]
): SettingsView =
  ## [SPEC RUNTIME l.2580-2601] Replaces `id`'s settings with `xs`, as flaky
  ## instance `slot`: the state the reply reports.
  let t = LogosNSRuntimeModuleInstanceAddress(
    runtime_instance_id: e.runtimeInstanceId(), module_instance_id: id
  )
  var rc: seq[LogosNSRuntimeControlPermissionSetting]
  for x in xs:
    rc.add(
      LogosNSRuntimeControlPermissionSetting(
        permission: x.permission, constraints: x.constraints
      )
    )
  let r = call(
    flakyBinding(slot),
    "update_permission_settings",
    LogosNSRuntimeControlUpdatePermissionSettingsRequest(
      target: t, expected_revision: e.settingsAs(slot, id).revision, permissions: rc
    ),
    LogosNSRuntimeControlUpdatePermissionSettingsResponse,
  )
  check r.isOk
  if r.isOk:
    result = r.get.accepted.get.state

proc sites(dir: string, hit: proc(line: string): bool): seq[(string, string)] =
  ## Each (path relative to `dir`, with `/`, routine) under `dir` with a line
  ## `hit` accepts, comments skipped; a line outside any routine has the
  ## routine "".
  const routines = ["proc ", "func ", "template ", "iterator ", "method ", "converter "]
  for path in walkDirRec(dir):
    if not path.endsWith(".nim"):
      continue
    var routine = ""
    for raw in readFile(path).splitLines:
      let line = raw.strip
      if line.len == 0 or line.startsWith("#"):
        continue
      let indent = raw.len - raw.strip(trailing = false).len
      if indent == 0:
        routine = ""
      if indent <= 2:
        for kw in routines:
          if line.startsWith(kw):
            var n = line[kw.len .. ^1]
            let cut = n.find({'(', '*', '[', ':', ' ', '='})
            if cut >= 0:
              n = n[0 ..< cut]
            routine = n
      let site = (path.relativePath(dir).replace('\\', '/'), routine)
      if hit(line) and site notin result:
        result.add(site)

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
    var files = @[repo / "sdk" / "src" / "logos_sdk" / "kit" / "rcclient.nim"]
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

  test "[RUN-0025] [RUN-1113] [RUN-1114] a stop between the read and the guarded request: `stale-revision` with the current revision, read again, nothing done":
    setOrchestratorFaultsForTests(OrchestratorFaults(pauseBeforeRequest: true))
    let e = boot(value(defaults = starts(4)), slots = @[4])
    check waitUntil(
      proc(): bool =
        pausedForTests() >= 1
    )
    discard e.stop(flakyInstance(4)).tryGet
    let current = e.view(flakyInstance(4)).tryGet.execution.revision
    let reads = callsForTests("get_readiness", flakyInstance(4))
    openPauseGateForTests()
    check waitUntil(
      proc(): bool =
        "start_module flaky-4: answered stale-revision (current revision " & $current &
          ")" in diagText()
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
    # The note is the module's decision on the failure; the state alone can
    # come first, before the start call's answer reaches the module.
    check waitUntil(
      proc(): bool =
        "the restart policy is disabled" in diagText()
    )
    check e.state(flakyInstance(0)) == msError
    sleep(int(ms(300)))
    check recovers(flakyInstance(0)) == 0
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
        defaults = starts(0),
        restart = Opt.some(restart(initial = 300_000, maxMs = 300_000)),
      )
    )
    # The module has the start's answer; its first recovery is five minutes away.
    check waitUntil(
      proc(): bool =
        "start_module flaky-0: answered" in diagText() and
          e.state(flakyInstance(0)) == msError
    )
    sleep(int(ms(50)))
    let t0 = getMonoTime()
    live = nil
    e.shutdown()
    check (getMonoTime() - t0).inMilliseconds < ms(30_000) # a tenth of the delay
    let n = targetsForTests().len
    sleep(int(ms(200)))
    check targetsForTests().len == n
    check recovers(flakyInstance(0)) == 0
    check e.close(initDuration(seconds = Patience))

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
    check e.cleaned(Orch)
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
    check e.cleaned(Orch)
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
    # [SPEC RUNTIME l.3538] The failed realization's cleanup runs on after the
    # report. A recovery made before it ends is NOT_READY, and one guarding the
    # revision its commit replaced is stale; each is refunded and made again.
    # How many there are depends on how long the cleanup takes: a check for
    # exactly one call waited 30 s on a loaded x86_64 orc-release CI runner (run
    # 44991040073). Exactly one is accepted.
    let recovered = waitUntil(
      proc(): bool =
        e.state(flakyInstance(0)) == msReady and recovers(flakyInstance(0)) >= 1 and
          settled(flakyInstance(0))()
    )
    let answers = recoverAnswers(flakyInstance(0))
    if not recovered or answers.countIt(it == "ready") != 1:
      checkpoint "recover_module calls: " & $recovers(flakyInstance(0)) & "; state: " &
        $e.state(flakyInstance(0)) & "; answered: " & answers.join(", ")
      e.explain()
    check recovered
    check answers.len == recovers(flakyInstance(0))
    check answers.countIt(it == "ready") == 1
    for a in answers:
      check a == "ready" or a == "NOT_READY" or a.startsWith("stale-revision")
    e.finish()

  test "[RUN-1065] [RUN-0696] [TXT-0582] [IMPL-DECISION G288] a missing configuration: blocked with `configuration-missing`, the configuration event brings the probe forward":
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
    let blocked = e.view("t1").tryGet
    check blocked.execution.intent == inRequested
    # [SPEC RUNTIME l.3613] The cause that prevents it, while it waits.
    check blocked.state == msUnloaded
    check blocked.failure.get.kind == fkConfigurationMissing
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
    check e.cleaned(Orch)
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
    # The bring-up polls the authority on its own backoff, so the first probe
    # may come well after the authority is ready: count from that probe.
    check waitUntil(
      proc(): bool =
        callsForTests("list_modules") >= 2
    )
    sleep(int(ms(600)))
    check e.view(flakyInstance(0)).tryGet.execution.intent == inUninitialized
    let times = callTimesForTests("list_modules")
    let probes = times.len
    let elapsed = (getMonoTime().ticks - times[0]) div 1_000_000
    # The schedule is not scaled by Slow; the time since the first probe bounds
    # how many it allows (50 ms doubling to 2 s), plus one for slack.
    var allowed = 1
    var at = 0'i64
    var gap = 50'i64
    while at + gap <= elapsed:
      at += gap
      inc allowed
      gap = min(gap * 2, 2000)
    checkpoint "probes " & $probes & " in " & $elapsed & " ms, schedule allows " &
      $allowed
    check probes >= 2 and probes <= allowed + 1
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

  test "[RUN-0696] [RUN-1065] [RUN-1092] [IMPL-DECISION G291] an enforcement stop past its deadline completes `unloaded` with its classification when its cleanup ends, and is resumed by an uncharged probe, under disabled too":
    let e = boot(value(defaults = starts(0), restart = Opt.some(disabled())))
    check waitUntil(e.isReady(flakyInstance(0)))
    flaky[0].destroyGate.store(true)
    discard e.stopForAuthority(flakyInstance(0), fkAuthorityRevoked)
    check waitUntil(
      proc(): bool =
        let v = e.view(flakyInstance(0)).tryGet
        v.state == msStopping and v.failure.isSome and
          v.failure.get.kind == fkCleanupTimeout
    )
    flaky[0].destroyGate.store(false)
    check waitUntil(e.isReady(flakyInstance(0)))
    check recovers(flakyInstance(0)) >= 1
    check entryOf(flakyInstance(0)).isNone
    e.finish()

suite "orch: resumption when permissions become available (RUNTIME l.3801-3804) [IMPL-DECISION G288] [IMPL-DECISION G284]":
  ## The shipped profile is selected: every realization must hold host-ambient.
  ## After the first uncharged call, the next come 50 ms, 800 ms, then 12.8 s
  ## later (`Slow`-scaled), so a recovery within a few seconds of the settings
  ## event was brought forward by it, not found by the next probe.
  setup:
    resetFlaky()
    clearOrchestratorFaultsForTests()
    clearDiag()
    resetFake()

  teardown:
    setRcDrainDelayForTests(0)
    leftover()

  proc spaced(): Opt[LcnOrchestratorRestart] =
    Opt.some(restart(initial = 50, maxMs = 60_000, mult = 16))

  test "[RUN-0696] [RUN-0914] [RUN-1066] a permission withdrawn stops the instance, intent and origin kept; given back, the settings event brings its recovery forward":
    let e = boot(
      value(defaults = starts(0, 1), restart = spaced()),
      slots = @[0, 1],
      profiled = true,
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    check waitUntil(e.isReady(flakyInstance(1)))
    # The module reads the instance after its start's answer; seen ready, its
    # start no longer counts toward the probe spacing.
    check waitUntil(
      proc(): bool =
        callsForTests("get_readiness", flakyInstance(0)) >= 1
    )
    check e.replaceSettings(1, flakyInstance(0), @[]).status == "pending"
    # [RUN-0914] [RUN-1066] The reconciliation stop keeps intent and origin.
    check waitUntil(
      proc(): bool =
        e.settingsAs(1, flakyInstance(0)).status == "applied"
    )
    var v = e.view(flakyInstance(0)).tryGet
    check v.state == msUnloaded
    check v.execution.intent == inRequested
    check v.intentOrigin.instance == Orch
    # Probes, each refused for the settings (G284): uncharged, never exhausted.
    check waitUntil(
      proc(): bool =
        recovers(flakyInstance(0)) >= 3
    )
    check waitUntil(settled(flakyInstance(0)))
    v = e.view(flakyInstance(0)).tryGet
    check v.state == msUnloaded
    check v.failure.isSome and v.failure.get.kind == fkAuthorityDenied
    check v.execution.intent == inRequested
    check entryOf(flakyInstance(0)).isNone
    check "attempt" notin diagText()
    let before = recovers(flakyInstance(0))
    check e.replaceSettings(1, flakyInstance(0), @[ambient()]).status == "applied"
    let t0 = getMonoTime()
    check waitUntil(e.isReady(flakyInstance(0)))
    explain(e)
    check (getMonoTime() - t0).inMilliseconds < ms(6_000)
    check recovers(flakyInstance(0)) == before + 1
    v = e.view(flakyInstance(0)).tryGet
    check v.intentOrigin.instance == Orch and v.failure.isNone
    check entryOf(flakyInstance(0)).isNone
    e.finish()

  test "[RUN-0696] a startup default refused for a missing permission keeps requested intent; the permission given, it is resumed":
    let e = boot(
      value(defaults = starts(0, 1), restart = spaced()),
      slots = @[0, 1],
      profiled = true,
      perms = @[InitialSettings(module: Flaky, instance: flakyInstance(0))],
    )
    check waitUntil(e.isReady(flakyInstance(1)))
    # The start, then probes at +50 and +800: the next is 12.8 s away.
    check waitUntil(
      proc(): bool =
        recovers(flakyInstance(0)) >= 2
    )
    check waitUntil(settled(flakyInstance(0)))
    check callsForTests("start_module", flakyInstance(0)) == 1
    let v = e.view(flakyInstance(0)).tryGet
    check v.state == msUnloaded
    check v.failure.isSome and v.failure.get.kind == fkAuthorityDenied
    check v.execution.intent == inRequested
    check v.intentOrigin.instance == Orch
    check entryOf(flakyInstance(0)).isNone
    let before = recovers(flakyInstance(0))
    check e.replaceSettings(1, flakyInstance(0), @[ambient()]).status == "applied"
    let t0 = getMonoTime()
    check waitUntil(e.isReady(flakyInstance(0)))
    explain(e)
    check (getMonoTime() - t0).inMilliseconds < ms(6_000)
    check recovers(flakyInstance(0)) == before + 1
    check callsForTests("start_module", flakyInstance(0)) == 1
    e.finish()

  test "[RUN-0696] [IMPL] a settings event still queued when the module subscribes anew is delivered: it brings the resumption forward":
    # [I94] Ending a subscription discards its queue. The resync used to end
    # the generation that held the event (x86_64 orc CI on b3af640). Here
    # each drain starts half a resync interval late, so a resync falls
    # between the event and its delivery half the time.
    let e = boot(
      value(defaults = starts(0, 1), restart = spaced()),
      slots = @[0, 1],
      profiled = true,
      perms = @[InitialSettings(module: Flaky, instance: flakyInstance(0))],
    )
    check waitUntil(e.isReady(flakyInstance(1)))
    check waitUntil(
      proc(): bool =
        recovers(flakyInstance(0)) >= 2
    )
    check waitUntil(settled(flakyInstance(0)))
    let before = recovers(flakyInstance(0))
    setRcDrainDelayForTests(int(ms(100)))
    check e.replaceSettings(1, flakyInstance(0), @[ambient()]).status == "applied"
    let t0 = getMonoTime()
    check waitUntil(e.isReady(flakyInstance(0)))
    setRcDrainDelayForTests(0)
    explain(e)
    check (getMonoTime() - t0).inMilliseconds < ms(6_000)
    check recovers(flakyInstance(0)) == before + 1
    e.finish()

  test "[RUN-0696] [RUN-0686] a refused probe is not a failed resumption; one accepted that then fails is under the restart policy: charged":
    let e = boot(
      value(defaults = starts(0, 1), restart = spaced()),
      slots = @[0, 1],
      profiled = true,
      perms = @[InitialSettings(module: Flaky, instance: flakyInstance(0))],
    )
    check waitUntil(e.isReady(flakyInstance(1)))
    check waitUntil(
      proc(): bool =
        recovers(flakyInstance(0)) >= 2
    )
    check waitUntil(settled(flakyInstance(0)))
    check "attempt" notin diagText() # the probes were uncharged
    let before = recovers(flakyInstance(0))
    flaky[0].failInits.store(1)
    check e.replaceSettings(1, flakyInstance(0), @[ambient()]).status == "applied"
    # The resumption is accepted and its initialization fails: an execution
    # failure (l.3804), so the next recovery is the episode's first attempt.
    check waitUntil(e.isReady(flakyInstance(0)))
    check recovers(flakyInstance(0)) == before + 2
    check "recover_module flaky-0: attempt 1 of 3" in diagText()
    e.finish()

  test "[RUN-0696] [RUN-0684] under disabled, a resumption accepted that then fails is not retried":
    let e = boot(
      value(defaults = starts(0, 1), restart = Opt.some(disabled())),
      slots = @[0, 1],
      profiled = true,
      perms = @[InitialSettings(module: Flaky, instance: flakyInstance(0))],
    )
    check waitUntil(e.isReady(flakyInstance(1)))
    check waitUntil(
      proc(): bool =
        recovers(flakyInstance(0)) >= 1
    )
    flaky[0].failInits.store(1)
    check e.replaceSettings(1, flakyInstance(0), @[ambient()]).status == "applied"
    # [SPEC RUNTIME l.3804] The accepted resumption failed: a live failure.
    check waitUntil(
      proc(): bool =
        "the restart policy is disabled" in diagText()
    )
    let v = e.view(flakyInstance(0)).tryGet
    check v.state == msError
    check v.failure.isSome and v.failure.get.kind == fkInitializationFailed
    let n = recovers(flakyInstance(0))
    sleep(int(ms(300)))
    check recovers(flakyInstance(0)) == n
    e.finish()

  test "[RUN-0696] [RUN-1055] [RUN-1092] [IMPL-DECISION G291] under disabled, settings that failed when the reconciliation stop overran: the stop completes `unloaded` with permission-enforcement-failed, probes go on through the refusal, and an accepted replacement resumes it":
    let e = boot(
      value(defaults = starts(0, 1), restart = Opt.some(disabled())),
      slots = @[0, 1],
      profiled = true,
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    check waitUntil(e.isReady(flakyInstance(1)))
    flaky[0].destroyGate.store(true)
    check e.replaceSettings(1, flakyInstance(0), @[]).status == "pending"
    # [G285] The stop overruns its deadline: settings failed, still
    # `stopping` with cleanup-timeout (RUNTIME l.575).
    check waitUntil(
      proc(): bool =
        let v = e.view(flakyInstance(0)).tryGet
        v.state == msStopping and v.failure.isSome and
          v.failure.get.kind == fkCleanupTimeout
    )
    check waitUntil(
      proc(): bool =
        e.settingsAs(1, flakyInstance(0)).status == "failed"
    )
    flaky[0].destroyGate.store(false)
    check e.cleaned(flakyInstance(0))
    # [G284] A probe is refused for the failed settings; the classification
    # it leaves is still read as a resumption.
    check waitUntil(
      proc(): bool =
        let v = e.view(flakyInstance(0)).tryGet
        v.failure.isSome and v.failure.get.kind == fkPermissionEnforcementFailed
    )
    check e.state(flakyInstance(0)) == msUnloaded
    check e.replaceSettings(1, flakyInstance(0), @[ambient()]).status == "applied"
    check waitUntil(e.isReady(flakyInstance(0)))
    check "the restart policy is disabled" notin diagText()
    check "attempt" notin diagText()
    check entryOf(flakyInstance(0)).isNone
    e.finish()

  test "[RUN-0696] [RUN-1055] [RUN-1092] [IMPL-DECISION G291] under disabled, a recovery the authority denies after an authority stop overran and completed: probes go on, and once allowed it is resumed":
    let e = boot(
      value(defaults = starts(0), authority = true, restart = Opt.some(disabled()))
    )
    check waitUntil(e.isReady(flakyInstance(0)))
    flaky[0].destroyGate.store(true)
    discard e.stopForAuthority(flakyInstance(0), fkAuthorityRevoked)
    check waitUntil(
      proc(): bool =
        let v = e.view(flakyInstance(0)).tryGet
        v.state == msStopping and v.failure.isSome and
          v.failure.get.kind == fkCleanupTimeout
    )
    setScript(rule(vDeny, what = "execute", consumer = Orch))
    flaky[0].destroyGate.store(false)
    check e.cleaned(flakyInstance(0))
    # [G168] The denial leaves the state as it was, `authority-denied`.
    check waitUntil(
      proc(): bool =
        let v = e.view(flakyInstance(0)).tryGet
        v.failure.isSome and v.failure.get.kind == fkAuthorityDenied
    )
    check e.state(flakyInstance(0)) == msUnloaded
    setScript()
    check waitUntil(e.isReady(flakyInstance(0)))
    check "the restart policy is disabled" notin diagText()
    check entryOf(flakyInstance(0)).isNone
    e.finish()

  test "[RUN-0696] [RUN-1065] [IMPL-DECISION G288] settings events never bring a probe closer than initial_delay_ms after the last":
    let e = boot(
      value(defaults = starts(0, 1), restart = spaced()),
      slots = @[0, 1],
      profiled = true,
      profile = testProfile,
      perms = @[InitialSettings(module: Flaky, instance: flakyInstance(0))],
    )
    check waitUntil(e.isReady(flakyInstance(1)))
    check waitUntil(
      proc(): bool =
        recovers(flakyInstance(0)) >= 2
    )
    check waitUntil(settled(flakyInstance(0)))
    # The next probe is 12.8 s away; each replacement below lacks host-ambient,
    # applies at once and is published.
    let t0 = getMonoTime().ticks
    for i in 0 ..< 40:
      let limit = uint64(1 + i mod 2)
      check e.replaceSettings(1, flakyInstance(0), @[setting(Quota, quota(limit))]).status ==
        "applied"
      sleep(int(ms(10)))
    let all = callTimesForTests("recover_module", flakyInstance(0))
    var during = 0
    for t in all:
      if t >= t0:
        inc during
    check during >= 3 # brought forward by the events
    for x in gapsMs(all):
      check x >= ms(50) - 2
    check entryOf(flakyInstance(0)).isNone
    e.finish()

  test "[RUN-0696] [RUN-0687] an explicit stop ends the probes: a later settings event recovers nothing":
    let e = boot(
      value(defaults = starts(0, 1), restart = spaced()),
      slots = @[0, 1],
      profiled = true,
      perms = @[InitialSettings(module: Flaky, instance: flakyInstance(0))],
    )
    check waitUntil(e.isReady(flakyInstance(1)))
    check waitUntil(
      proc(): bool =
        recovers(flakyInstance(0)) >= 2
    )
    check e.stop(flakyInstance(0)).isOk
    check e.view(flakyInstance(0)).tryGet.execution.intent == inStopped
    let n = recovers(flakyInstance(0))
    check e.replaceSettings(1, flakyInstance(0), @[ambient()]).status == "applied"
    sleep(int(ms(500)))
    check recovers(flakyInstance(0)) == n
    check e.state(flakyInstance(0)) == msUnloaded
    check e.view(flakyInstance(0)).tryGet.execution.intent == inStopped
    e.finish()

  test "[RUN-1055] [IMPL-DECISION G291] the engine sets the resumable classifications only where it refuses, denies, fails settings or stops for authority, never for a failure of an accepted attempt":
    # Every routine in src/logos_core/runtime that names one of the kinds of
    # `ResumableFailures` the engine sets today, or builds a failure whose
    # kind a variable holds. A new site must be read against G291 before it
    # joins the list.
    let expected = @[
      ("engine.nim", "blockedBy"),
        # P5 §0.3 item 3: a start or recovery refused for an l.3613 cause
      ("engine.nim", "bootstrap"),
        # M14: a retained static instance mismatched at open (l.1322)
      ("engine.nim", "checkBootstrap"), # reads: the orchestration start refused
      ("engine.nim", "completeStop"),
        # C4: a reconciliation stop whose settings settled failed at its overrun
      ("engine.nim", "executeDecided"),
        # G168: a denied execution decision; M14: a start or recovery of a
        # mismatched instance
      ("engine.nim", "failureKind"),
        # CA §8: what an ended authorization's stop records
      ("engine.nim", "profiledSettings"), # G281: a replacement failed while unloaded
      ("engine.nim", "restoreSettings"), # G281: pending settings settled failed at open
      ("engine.nim", "selectConfig"),
        # M13: a start or recovery refused for want of configuration
      ("engine.nim", "settingsRefusal"), # G284: a start or recovery the settings refuse
      ("engine.nim", "settleSettings"),
        # G281, G285: settings settled failed while unloaded
      ("engine.nim", "startupFailure"),
        # reads: the code startup returns for a denial or a settings refusal
      ("engine.nim", "stopForAuthority"),
        # an enforcement stop; its kind is an AuthorityEnding
      ("plumbing.nim", ""), # the enumeration and AuthorityEndings
      ("store.nim", "classificationOf"), # reads a recorded classification back
    ]
    const kinds = [
      "fkAuthorityDenied", "fkAuthorityEvaluationFailed",
      "fkPermissionEnforcementFailed", "fkConfigurationMissing",
      "fkStaticBindingMismatch",
    ]
    const built = "Failure(kind: "
    let found = sites(
      repo / "src" / "logos_core" / "runtime",
      proc(line: string): bool =
        for k in kinds:
          if k in line:
            return true
        let i = line.find(built)
        i >= 0 and (i == 0 or line[i - 1] notin IdentChars) and
          not line[i + built.len .. ^1].startsWith("fk"),
    )
    check found.sorted == expected.sorted

  test "[RUN-1192] [RUN-1191] only a typed Module Loader error becomes a `loader-` classification: the engine builds one in `classify` alone, and the store reads a recorded one back":
    # Every routine under src/ that builds or assigns a `fkLoader` failure.
    # `classify` takes a `LoaderError` the Module Loader answered (RUNTIME
    # l.3607); the bootstrap mechanism, the Module Host and the engine's own
    # checks report `other`, `host-terminated` or a phase classification,
    # never `loader-` (l.3608).
    let found = sites(
      repo / "src",
      proc(line: string): bool =
        "kind: fkLoader" in line or "kind = fkLoader" in line,
    )
    check found.sorted ==
      @[
        ("logos_core/runtime/engine.nim", "classify"),
        ("logos_core/runtime/store.nim", "classificationOf"),
      ]
