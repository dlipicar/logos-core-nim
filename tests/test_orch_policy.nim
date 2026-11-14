## The reference orchestration module's pure parts (DECISIONS I94): the
## decision rules and backoff (`orchestration/policy.nim`), the configuration
## checks (`orchestration/settings.nim`) and the retry-accounting file
## (`orchestration/accounting.nim`). No engine, no thread, no clock: every time
## is a number the test passes.

import std/[os, strutils, tables]
import unittest2
import ../src/logos_core/durable
import ../src/logos_core/iface/outcome
import ../src/logos_core/loader/contract
import ../src/logos_core/orchestration/[accounting, policy, settings]

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "orch_policy"
removeDir(work)
createDir(work)

func backoff(
    initial = 20'i64, maxMs = 200'i64, mult = 2'i64, attempts = 3'i64, stable = 100'i64
): Restart =
  Restart(
    enabled: true,
    backoff: Backoff(
      initialMs: initial,
      maxMs: maxMs,
      multiplier: mult,
      maxAttempts: attempts,
      stableMs: stable,
    ),
  )

func view(
    life: Life,
    intent = intentRequested,
    rev = 7'u64,
    intentRev = 3'u64,
    overran = false,
    ready = true,
    instance = "w",
): View =
  View(
    module: "m",
    instance: instance,
    life: life,
    intent: intent,
    intentRevision: intentRev,
    revision: rev,
    prerequisitesReady: ready,
    overran: overran,
  )

proc decideNow(
    v: View,
    entry: var Opt[Entry],
    memo: var Memo,
    r: Restart,
    now: int64,
    default = defaultNone,
    firstPass = false,
): Decision =
  decide(v, entry, memo, r, default, now, firstPass)

proc restartValue(
    initial = 20'u32,
    maxMs = 200'u32,
    mult = 2'u32,
    attempts = Opt.some(3'u32),
    stable = 100'u32,
): LcnOrchestratorRestart =
  LcnOrchestratorRestart(
    kind: LcnOrchestratorRestartKind.Backoff,
    arm_Backoff: LcnOrchestratorRestartARBackoffMap(
      initial_delay_ms: initial,
      max_delay_ms: maxMs,
      multiplier: mult,
      max_attempts: attempts,
      stable_ms: stable,
    ),
  )

func order(pre, dep: string): LcnOrchestratorOrder =
  LcnOrchestratorOrder(prerequisite: pre, dependent: dep)

suite "orch: backoff and attempts (RUNTIME l.3786-3789) [IMPL-DECISION G289]":
  test "[RUN-0686] delay(n): initial, then times the multiplier, capped, saturating":
    let b = backoff(initial = 20, maxMs = 200, mult = 2).backoff
    check delay(b, 0) == 20
    check delay(b, 1) == 20
    check delay(b, 2) == 40
    check delay(b, 3) == 80
    check delay(b, 4) == 160
    check delay(b, 5) == 200
    check delay(b, 1_000_000) == 200
    check delay(b, high(int64)) == 200
    let one = backoff(initial = 50, maxMs = 500, mult = 1).backoff
    check delay(one, 0) == 50
    check delay(one, 1_000_000) == 50
    let big = Backoff(initialMs: 3_600_000, maxMs: 86_400_000, multiplier: 16)
    check delay(big, 64) == 86_400_000

  test "[RUN-0686] exactly max_attempts charged recoveries, then exhausted; no limit when absent":
    var entry = Opt.none(Entry)
    var memo = Memo()
    let r = backoff(attempts = 3)
    var now = 1_000'i64
    var charged = 0
    for round in 0 ..< 10:
      let d = decideNow(view(lifeError), entry, memo, r, now)
      if d.step == stepRecover:
        check d.charged
        entry.charge(view(lifeError), now, now)
        entry.get.settle(answerAccepted)
        inc charged
      now += 10_000
    check charged == 3
    check entry.get.exhausted
    check entry.get.attempts == 3
    var unlimited = Opt.none(Entry)
    var m2 = Memo()
    let r2 = backoff(attempts = 0)
    now = 1_000
    charged = 0
    for round in 0 ..< 40:
      let d = decideNow(view(lifeError), unlimited, m2, r2, now)
      if d.step == stepRecover:
        unlimited.charge(view(lifeError), now, now)
        unlimited.get.settle(answerAccepted)
        inc charged
      now += 10_000
    check charged == 39 # the first is due `initial` after the failure was seen
    check not unlimited.get.exhausted

  test "[RUN-0686] [RUN-1065] refusals refund the charge and keep the spacing; a probe never exhausts":
    var entry = Opt.none(Entry)
    var memo = Memo()
    let r = backoff(attempts = 2)
    var d = decideNow(view(lifeError), entry, memo, r, 1_000)
    check d.step == stepNone
    check d.dueAt.get == 1_020 # delay(0) after the failure was seen
    d = decideNow(view(lifeError), entry, memo, r, 1_020)
    check d.step == stepRecover and d.charged
    entry.charge(view(lifeError), 1_020, 1_020)
    check entry.get.attempts == 1 and entry.get.calls == 1
    entry.get.settle(answerRefused)
    check entry.get.attempts == 0 # no attempt was accepted (C-9)
    check entry.get.calls == 1 # the spacing stays
    d = decideNow(view(lifeError), entry, memo, r, 1_030)
    check d.step == stepNone
    check d.dueAt.get == 1_040 # last call + delay(1)
    for i in 0 ..< 10: # refused again and again: never exhausted
      d = decideNow(view(lifeError), entry, memo, r, 100_000 * (i + 1))
      check d.step == stepRecover
      entry.charge(view(lifeError), 100_000 * (i + 1), 100_000 * (i + 1))
      entry.get.settle(answerRefused)
    check not entry.get.exhausted
    # A probe (unloaded with requested intent) is uncharged and never exhausts.
    var pe = Opt.none(Entry)
    var pm = Memo()
    var t = 0'i64
    var probes = 0
    for i in 0 ..< 50:
      let p = decideNow(view(lifeUnloaded), pe, pm, r, t)
      if p.step == stepRecover:
        check not p.charged
        pm.noteProbe(t)
        inc probes
      t += 1_000
    check probes == 49 # the first is due `initial` after the state was seen
    check pe.isNone

  test "[RUN-0686] an answer that was never recorded is charged once, never twice, and forces a read":
    var entry = Opt.some(
      Entry(
        module: "m",
        instance: "w",
        intentRevision: 3,
        attempts: 2,
        calls: 2,
        lastCallAt: Opt.some(500'i64),
        lastCallMono: Opt.some(500'i64),
        pending: Opt.some(6'u64),
      )
    )
    var memo = Memo()
    let d = decideNow(view(lifeError), entry, memo, backoff(attempts = 5), 600)
    check d.entryChanged # pending cleared and written
    check entry.get.pending.isNone
    check entry.get.attempts == 2 # charged once, at the write-ahead
    check d.step == stepRecover and d.charged # due at 500 + delay(2) = 540
    # A lost answer at runtime: the charge stays.
    var e2 = Opt.none(Entry)
    e2.charge(view(lifeError), 10, 10)
    e2.get.settle(classifyRecover(ecTimeout))
    check e2.get.attempts == 1 and e2.get.pending.isNone

  test "[RUN-0686] [IMPL-DECISION G289] a recover_module answered with a code the table does not list is lost: charge kept; a prepare that fails is refunded":
    check classifyRecover(ecOk) == answerAccepted
    for c in [ecInvalidParams, ecNotReady, ecNotAuthorised, ecModule]:
      check classifyRecover(c) == answerRefused
    check classifyRecover(ecCancelled) == answerCancelled
    for c in [ecTimeout, ecTransport, ecVersionMismatch, ecMethodNotFound]:
      check classifyRecover(c) == answerLost
    var e = Opt.none(Entry)
    e.charge(view(lifeError), 10, 10)
    e.get.settle(answerLost)
    check e.get.attempts == 1
    var f = Opt.none(Entry)
    f.charge(view(lifeError), 10, 10)
    f.get.settle(answerRefused) # what the worker does when prepare_call fails
    check f.get.attempts == 0 and f.get.calls == 1
    var g = Opt.none(Entry)
    g.charge(view(lifeError), 10, 10)
    g.get.settle(answerCancelled)
    check g.get.pending == Opt.some(7'u64) # settled at the next start (rule 4e)

suite "orch: the decision rules (RUNTIME l.3774-3790) [IMPL-DECISION G287] [IMPL-DECISION G288] [IMPL-DECISION G289] [IMPL-DECISION G291]":
  test "[RUN-0684] [RUN-0686] [IMPL-DECISION G288] disabled: no recovery of a live error; unloaded probes still happen, spaced by the package default":
    var entry = Opt.none(Entry)
    var memo = Memo()
    let r = disabledRestart()
    var d = decideNow(view(lifeError), entry, memo, r, 0)
    check d.step == stepNone
    check d.note.len > 0
    d = decideNow(view(lifeError), entry, memo, r, 1_000_000)
    check d.step == stepNone and d.note.len == 0 # one diagnostic
    var pm = Memo()
    var pe = Opt.none(Entry)
    d = decideNow(view(lifeUnloaded), pe, pm, r, 0)
    check d.step == stepNone and d.dueAt.get == PackageInitialMs
    d = decideNow(view(lifeUnloaded), pe, pm, r, PackageInitialMs)
    check d.step == stepRecover and not d.charged
    pm.noteProbe(PackageInitialMs)
    d = decideNow(view(lifeUnloaded), pe, pm, r, PackageInitialMs + 1)
    check d.step == stepNone
    check d.dueAt.get == PackageInitialMs + delay(packageBackoff(), 1)

  test "[RUN-0687] [RUN-1065] intent stopped drops the entry and its timers; a new intent revision opens a new episode":
    var entry =
      Opt.some(Entry(module: "m", instance: "w", intentRevision: 3, attempts: 2))
    var memo = Memo(probes: 4, lastProbeAt: Opt.some(5'i64))
    var d =
      decideNow(view(lifeError, intent = intentStopped), entry, memo, backoff(), 10)
    check entry.isNone and d.entryChanged
    check d.step == stepNone and d.dueAt.isNone
    check memo.probes == 0
    entry = Opt.some(Entry(module: "m", instance: "w", intentRevision: 3, attempts: 3))
    memo = Memo()
    d =
      decideNow(view(lifeError, intentRev = 4), entry, memo, backoff(attempts = 3), 10)
    check d.entryChanged
    check entry.isNone # the old episode went; nothing charged yet in the new one
    check d.dueAt.get == 30

  test "[RUN-1055] the same view with any failure classification but cleanup-timeout gives the same action":
    for failure in ["initialization-failed", "x-unheard-of", "loader-foo", ""]:
      var entry = Opt.none(Entry)
      var memo = Memo()
      # `overran` is the only classification the rules read; every other one,
      # and none, is a live failure.
      let v = view(lifeError, overran = false)
      let d = decideNow(v, entry, memo, backoff(), 100)
      check d.step == stepNone and d.dueAt.get == 120
      discard failure

  test "[RUN-0025] startup defaults: only for uninitialized, guarded by the observed revision; stop; unlisted":
    var entry = Opt.none(Entry)
    var memo = Memo()
    var d = decideNow(
      view(lifeUnloaded, intent = intentUninitialized, rev = 11),
      entry,
      memo,
      backoff(),
      0,
      default = defaultStart,
    )
    check d.step == stepStart and d.revision == 11 and not d.charged
    memo = Memo()
    d = decideNow(
      view(lifeUnloaded, intent = intentUninitialized, rev = 12),
      entry,
      memo,
      backoff(),
      0,
      default = defaultStop,
    )
    check d.step == stepStop and d.revision == 12
    memo = Memo()
    d = decideNow(
      view(lifeUnloaded, intent = intentUninitialized), entry, memo, backoff(), 0
    )
    check d.step == stepNone and d.dueAt.isNone
    # A default never touches a requested or stopped intent.
    memo = Memo()
    d = decideNow(
      view(lifeUnloaded, intent = intentStopped),
      entry,
      memo,
      backoff(),
      0,
      default = defaultStart,
    )
    check d.step == stepNone

  test "[RUN-0025] [RUN-1065] [IMPL-DECISION G287] a start default waits for its prerequisites; a refused default is retried on the probe spacing, never sooner":
    var entry = Opt.none(Entry)
    var memo = Memo()
    let r = backoff(initial = 20, maxMs = 200)
    var d = decideNow(
      view(lifeUnloaded, intent = intentUninitialized, ready = false),
      entry,
      memo,
      r,
      0,
      default = defaultStart,
    )
    check d.step == stepNone and d.dueAt.isNone
    d = decideNow(
      view(lifeUnloaded, intent = intentUninitialized),
      entry,
      memo,
      r,
      5,
      default = defaultStart,
    )
    check d.step == stepStart
    memo.noteProbe(5) # refused: still uninitialized
    d = decideNow(
      view(lifeUnloaded, intent = intentUninitialized),
      entry,
      memo,
      r,
      6,
      default = defaultStart,
    )
    check d.step == stepNone and d.dueAt.get == 25
    memo.hinted = true # a hint never brings it before last call + initial
    d = decideNow(
      view(lifeUnloaded, intent = intentUninitialized),
      entry,
      memo,
      r,
      7,
      default = defaultStart,
    )
    check d.dueAt.get == 25
    d = decideNow(
      view(lifeUnloaded, intent = intentUninitialized),
      entry,
      memo,
      r,
      25,
      default = defaultStart,
    )
    check d.step == stepStart

  test "[RUN-1065] [IMPL-DECISION G287] a dependent waits for every prerequisite; settings order them and reject a cycle, a self-edge, a duplicate":
    var entry = Opt.none(Entry)
    var memo = Memo()
    let d = decideNow(view(lifeError, ready = false), entry, memo, backoff(), 0)
    check d.step == stepNone and d.dueAt.isNone
    var c = OrchestratorSettings(
      ordering: Opt.some(@[order("a", "b"), order("b", "c"), order("a", "c")])
    )
    let s = settingsOf(c)
    check s.isOk
    check s.get.order == @["a", "b", "c"]
    check s.get.prerequisites.getOrDefault("c") == @["b", "a"]
    c.ordering = Opt.some(@[order("a", "b"), order("b", "a")])
    check settingsOf(c).isErr
    c.ordering = Opt.some(@[order("a", "a")])
    check settingsOf(c).isErr
    c.ordering = Opt.some(@[order("a", "b"), order("a", "b")])
    check settingsOf(c).isErr

  test "[RUN-1063] [RUN-1064] [IMPL-DECISION G289] first pass: no episode resumes uncharged under every policy; an open episode continues charged; disabled resumes an error once, also with a stale entry":
    for r in [backoff(), disabledRestart()]:
      var entry = Opt.none(Entry)
      var memo = Memo()
      var d = decideNow(view(lifeUnloaded), entry, memo, r, 0, firstPass = true)
      check d.step == stepRecover and not d.charged
      memo = Memo()
      d = decideNow(view(lifeError), entry, memo, r, 0, firstPass = true)
      check d.step == stepRecover and not d.charged
    var open = Opt.some(
      Entry(
        module: "m",
        instance: "w",
        intentRevision: 3,
        attempts: 2,
        calls: 2,
        lastCallMono: Opt.some(0'i64),
      )
    )
    var memo = Memo()
    var d = decideNow(
      view(lifeError), open, memo, backoff(attempts = 5), 1_000, firstPass = true
    )
    check d.step == stepRecover and d.charged
    var stale = Opt.some(
      Entry(module: "m", instance: "w", intentRevision: 3, attempts: 3, exhausted: true)
    )
    memo = Memo()
    d = decideNow(view(lifeError), stale, memo, disabledRestart(), 0, firstPass = true)
    check d.step == stepRecover and not d.charged
    check stale.isNone and d.entryChanged
    # The second failure under `disabled` is not retried.
    d = decideNow(view(lifeError), stale, memo, disabledRestart(), 10_000)
    check d.step == stepNone

  test "[RUN-0021] [RUN-1063] its own instance and the Module Loader are left out; nothing else is":
    var entry = Opt.none(Entry)
    var memo = Memo()
    var v = view(lifeError)
    v.isSelf = true
    check decideNow(v, entry, memo, backoff(), 0, firstPass = true).step == stepNone
    v = view(lifeUnloaded, instance = LoaderInstanceId)
    v.isLoader = true
    check decideNow(v, entry, memo, backoff(), 0, firstPass = true).step == stepNone
    check decideNow(
      view(lifeUnloaded, instance = "x"), entry, memo, backoff(), 0, firstPass = true
    ).step == stepRecover

  test "[RUN-0696] [RUN-1055] [IMPL-DECISION G291] error with cleanup-timeout and requested intent is an uncharged probe under every policy, never exhausted":
    for r in [backoff(attempts = 1), disabledRestart()]:
      var entry = Opt.none(Entry)
      var memo = Memo()
      var t = 0'i64
      var probes = 0
      for i in 0 ..< 20:
        let d = decideNow(view(lifeError, overran = true), entry, memo, r, t)
        if d.step == stepRecover:
          check not d.charged
          memo.noteProbe(t)
          inc probes
        t += 100_000
      check probes == 19
      check entry.isNone
    # The same view without the overrun is a live failure (rule h).
    var entry = Opt.none(Entry)
    var memo = Memo()
    check decideNow(view(lifeError), entry, memo, disabledRestart(), 0).step == stepNone

  test "[RUN-1065] [IMPL-DECISION G288] a hint brings the next probe forward to last call + initial, and stays in force until that probe is made":
    let r = backoff(initial = 50, maxMs = 5000, mult = 16)
    var entry = Opt.none(Entry)
    var memo = Memo()
    var d = decideNow(view(lifeUnloaded), entry, memo, r, 0)
    check d.dueAt.get == 50 # delay(0) after it was first seen
    for t in [50'i64, 100, 900]:
      d = decideNow(view(lifeUnloaded), entry, memo, r, t)
      check d.step == stepRecover and not d.charged
      memo.noteProbe(t)
    d = decideNow(view(lifeUnloaded), entry, memo, r, 910)
    check d.dueAt.get == 5900 # delay(3): capped at 5000
    memo.hinted = true
    d = decideNow(view(lifeUnloaded), entry, memo, r, 915)
    check d.dueAt.get == 950 # never before last call + initial
    # Decided again before it is due (a resync, another read): still 950.
    d = decideNow(view(lifeUnloaded), entry, memo, r, 930)
    check d.dueAt.get == 950
    d = decideNow(view(lifeUnloaded), entry, memo, r, 950)
    check d.step == stepRecover
    memo.noteProbe(950) # the hint is spent
    d = decideNow(view(lifeUnloaded), entry, memo, r, 960)
    check d.dueAt.get == 5950

  test "[RUN-0686] the clock clamp: last_call_at in the future or far past":
    check monoOfLastCall(1_000, 100, 1_050, 5_000) == 4_950 # 50 ms left
    check monoOfLastCall(1_000, 100, 9_000, 5_000) == 4_900 # due now
    check monoOfLastCall(9_000, 100, 1_000, 5_000) == 5_000 # backwards: one full delay
    check monoOfLastCall(1_000, 100, 1_000, 5_000) == 5_000

  test "[RUN-0684] a ready instance closes its episode after stable_ms; an exhausted one at once":
    var entry =
      Opt.some(Entry(module: "m", instance: "w", intentRevision: 3, attempts: 2))
    var memo = Memo()
    var d = decideNow(view(lifeReady), entry, memo, backoff(stable = 100), 1_000)
    check entry.isSome and d.dueAt.get == 1_100
    d = decideNow(view(lifeReady), entry, memo, backoff(stable = 100), 1_100)
    check entry.isNone and d.entryChanged
    var ex =
      Opt.some(Entry(module: "m", instance: "w", intentRevision: 3, exhausted: true))
    memo = Memo()
    d = decideNow(view(lifeReady), ex, memo, backoff(), 0)
    check ex.isNone

suite "orch: configuration (CONFIG l.52-53, l.132, l.142) [IMPL-DECISION G288]":
  test "[RUN-0685] bounds and defaults; the package default equals the absent-restart constants":
    let s = settingsOf(OrchestratorSettings()).get
    check s.restart == packageRestart()
    check s.resyncMs == DefaultResyncMs
    check s.defaults.len == 0
    let p = settingsOf(packageDefault()).get
    check p.restart == packageRestart()
    check p.restart.backoff.maxAttempts == 8
    var c = OrchestratorSettings(restart: Opt.some(restartValue(initial = 0)))
    check settingsOf(c).isErr
    c.restart = Opt.some(restartValue(initial = 100, maxMs = 50))
    check settingsOf(c).isErr
    c.restart = Opt.some(restartValue(mult = 17))
    check settingsOf(c).isErr
    c.restart = Opt.some(restartValue(attempts = Opt.some(0'u32)))
    check settingsOf(c).isErr
    c.restart = Opt.some(restartValue(attempts = Opt.none(uint32)))
    check settingsOf(c).get.restart.backoff.maxAttempts == 0
    c = OrchestratorSettings(resync_ms: Opt.some(5'u32))
    check settingsOf(c).isErr
    c = OrchestratorSettings(
      authority:
        Opt.some(LcnOrchestratorTarget(module: "x", instance: LoaderInstanceId))
    )
    check settingsOf(c).isErr
    c = OrchestratorSettings(
      defaults: Opt.some(
        @[
          LcnOrchestratorDefault(module: "m", instance: "a"),
          LcnOrchestratorDefault(module: "m", instance: "a"),
        ]
      )
    )
    check settingsOf(c).isErr
    c = OrchestratorSettings(
      overrides: Opt.some(
        @[
          LcnOrchestratorOverride(instance: "a", restart: restartValue()),
          LcnOrchestratorOverride(instance: "a", restart: restartValue()),
        ]
      )
    )
    check settingsOf(c).isErr
    c = OrchestratorSettings(
      authority: Opt.some(LcnOrchestratorTarget(module: "ca", instance: "auth")),
      defaults: Opt.some(@[LcnOrchestratorDefault(module: "m", instance: "a")]),
      restart: Opt.some(
        LcnOrchestratorRestart(
          kind: LcnOrchestratorRestartKind.Disabled,
          arm_Disabled: LcnOrchestratorRestartARDisabledMap(),
        )
      ),
      overrides:
        Opt.some(@[LcnOrchestratorOverride(instance: "a", restart: restartValue())]),
    )
    let t = settingsOf(c).get
    check t.defaults[0].instance == "auth" # the authority is the first default
    check t.defaultFor("auth") == defaultStart
    check t.defaultFor("a") == defaultStart
    check t.defaultFor("b") == defaultNone
    check not t.restartFor("b").enabled
    check t.restartFor("a").enabled
    check t.needsStateDir
    check encodeSettings(c).isOk
    check validateSettings(c).isOk
    check orchestratorDeclaration().isOk

suite "orch: the state file (RUNTIME l.3789) [IMPL-DECISION G289]":
  test "[RUN-0686] round trip; a corrupt file fails; another Runtime's file is discarded":
    let dir = work / "roundtrip"
    removeDir(dir)
    let s = settingsOf(OrchestratorSettings()).get
    var (a, lock) = openAccounting(Opt.some(dir), s).get
    a.runtimeId = Opt.some("runtime-1")
    a.entries["w"] = Entry(
      module: "m",
      instance: "w",
      intentRevision: 9,
      attempts: 2,
      calls: 3,
      lastCallAt: Opt.some(1_700_000_000_000'i64),
      pending: Opt.some(77'u64),
    )
    a.entries["v"] =
      Entry(module: "m", instance: "v", intentRevision: 1, exhausted: true)
    check a.save().isOk
    lock.release()
    var (b, lock2) = openAccounting(Opt.some(dir), s).get
    check b.runtimeId == Opt.some("runtime-1")
    check b.entries.len == 2
    check b.entries.getOrDefault("w").pending == Opt.some(77'u64)
    check b.entries.getOrDefault("w").calls == 3
    check b.entries.getOrDefault("v").exhausted
    # A second holder of the directory is refused.
    check openAccounting(Opt.some(dir), s).isErr
    check not b.checkRuntime("runtime-1")
    check b.entries.len == 2
    check b.checkRuntime("runtime-2")
    check b.entries.len == 0 and b.runtimeId == Opt.some("runtime-2")
    lock2.release()
    writeFile(dir / StateFileName, "not cbor")
    let broken = openAccounting(Opt.some(dir), s)
    check broken.isErr
    check StateFileName in broken.error
    # The lock was given back: the remedy (deleting the file) works.
    removeFile(dir / StateFileName)
    var (c, lock3) = openAccounting(Opt.some(dir), s).get
    check c.entries.len == 0
    lock3.release()

  test "[RUN-0686] no state directory: refused under an enabled policy, accepted when every policy is disabled":
    let enabled = settingsOf(OrchestratorSettings()).get
    check openAccounting(Opt.none(string), enabled).isErr
    let off = settingsOf(
      OrchestratorSettings(
        restart: Opt.some(
          LcnOrchestratorRestart(
            kind: LcnOrchestratorRestartKind.Disabled,
            arm_Disabled: LcnOrchestratorRestartARDisabledMap(),
          )
        )
      )
    ).get
    var (a, _) = openAccounting(Opt.none(string), off).get
    check a.dir.len == 0
    check a.save().isOk
