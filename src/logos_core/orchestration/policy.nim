## The reference orchestration module's decisions (DECISIONS I94; RUNTIME
## §10.1 l.3774-3790): pure functions of one fresh view of an instance, its
## retry-accounting episode, its in-memory spacing and its restart policy. No
## I/O, no threads, no clock: the caller passes the time, monotonic for
## scheduling and wall-clock only for what the state file keeps.
##
## The rules, in order (plan §2.6):
##
## 1. The module's own instance and the Module Loader are left out; nothing
##    else is.
## 2. Intent `uninitialized`: only a startup default acts, by a request guarded
##    with the revision just read (RUNTIME l.194, l.1832-1833, l.2247; a
##    Reading, I94). A `start` default waits for its prerequisites (G287). A
##    default refused before acceptance is retried on the probe spacing.
## 3. Intent `stopped`: the episode and its timers go (RUNTIME l.3790).
## 4. Intent `requested`: (a) another intent revision opens a new episode;
##    (b) `loaded` or `stopping` waits; (c) `ready` closes the episode after
##    `stable_ms`; (d) a prerequisite not `ready` waits (G287); (e) a call whose
##    answer was lost is charged once (C-9); (f) the module's first decision
##    after it starts resumes uncharged, under every policy, unless an episode
##    is open under an enabled policy (G289, amending G193); (g) `unloaded`, or
##    `error` from an enforcement stop that overran its deadline, is probed
##    uncharged and never exhausts (G288, G291); (h) any other `error` is a
##    live failure under the restart policy (RUNTIME l.3786-3789).

{.push raises: [], gcsafe.}

import results
import ../iface/outcome

export results

const
  PackageInitialMs* = 1_000'i64 ## [D8, I94] the package default restart policy
  PackageMaxMs* = 60_000'i64
  PackageMultiplier* = 2'i64
  PackageMaxAttempts* = 8'i64
  PackageStableMs* = 60_000'i64
  DefaultResyncMs* = 30_000'i64 ## [IMPL] `resync_ms` when the value leaves it out
  OverranFailure* = "cleanup-timeout"
    ## [SPEC RUNTIME l.3754; G180, G291] the one failure classification the
    ## rules read

type
  Backoff* = object ## `restart.backoff`, in milliseconds
    initialMs*, maxMs*, multiplier*: int64
    maxAttempts*: int64 ## 0: no limit (RUNTIME l.3789 "MAY limit")
    stableMs*: int64

  Restart* = object
    ## One instance's restart policy. Under `disabled`, `backoff` is the
    ## package default's, the spacing of probes and refused defaults (G288).
    enabled*: bool
    backoff*: Backoff

  Intent* = enum
    intentUninitialized
    intentRequested
    intentStopped

  Life* = enum
    lifeUnloaded
    lifeLoaded
    lifeReady
    lifeStopping
    lifeError

  View* = object ## One instance as one read showed it.
    module*, instance*: string
    life*: Life
    intent*: Intent
    intentRevision*: uint64 ## with `requested` or `stopped` intent
    revision*: uint64 ## the execution revision a guarded request carries
    prerequisitesReady*: bool ## every prerequisite in `ordering` is `ready`
    isSelf*, isLoader*: bool
    overran*: bool ## `failure` is `cleanup-timeout`

  DefaultKind* = enum
    defaultNone
    defaultStart
    defaultStop

  Entry* = object
    ## One retry-accounting episode (`lcn_orch.entry`): one instance and
    ## intent revision, opened by its first charged recovery.
    module*, instance*: string
    intentRevision*: uint64
    attempts*: int64 ## charged recoveries: the policy's limit
    calls*: int64 ## charged recoveries made, refusals included: the spacing
    lastCallAt*: Opt[int64] ## wall clock, ms since the epoch
    lastCallMono*: Opt[int64] ## the same moment on the monotonic clock
    pending*: Opt[uint64] ## the guarded revision of an unanswered call
    exhausted*: bool

  Waiting* = enum
    waitingNone
    waitingProbe ## for a probe (rule g) or a refused default (rule 2)
    waitingFailure ## for a charged retry (rule h)

  Memo* = object
    ## What the module remembers of one instance in memory only (I94: what is
    ## uncharged is never written).
    firstPassDone*: bool
    waiting*: Waiting
    seenAt*: int64 ## when `waiting` was first observed, monotonic ms
    probes*: int64 ## uncharged calls since the instance was last `ready`
    lastProbeAt*: Opt[int64]
    readySince*: Opt[int64]
    disabledNoted*: bool
    hinted*: bool ## an event named the instance since its last uncharged call

  Step* = enum
    stepNone
    stepStart ## `start_module`, guarded
    stepStop ## `stop_module`, guarded
    stepRecover ## `recover_module`, guarded

  Decision* = object
    step*: Step
    revision*: uint64 ## `expected_execution_revision`
    charged*: bool ## a retry under the restart policy (rule h)
    entryChanged*: bool ## the episode changed and is written
    dueAt*: Opt[int64] ## nothing now: decide again then (monotonic ms)
    note*: string ## a diagnostic line; empty for none

  Answer* = enum
    answerAccepted ## OK: the attempt was accepted (it may have failed since)
    answerRefused ## refused before acceptance: no attempt (C-9)
    answerLost ## no usable answer: charged once (C-9, RUNTIME l.3511)
    answerCancelled ## the module's own destroy cancelled it

func packageBackoff*(): Backoff =
  Backoff(
    initialMs: PackageInitialMs,
    maxMs: PackageMaxMs,
    multiplier: PackageMultiplier,
    maxAttempts: PackageMaxAttempts,
    stableMs: PackageStableMs,
  )

func packageRestart*(): Restart =
  Restart(enabled: true, backoff: packageBackoff())

func disabledRestart*(): Restart =
  Restart(enabled: false, backoff: packageBackoff())

func delay*(b: Backoff, n: int64): int64 =
  ## [IMPL; I94] `delay(0) = delay(1) = initial`, then
  ## `min(max, initial × multiplier^(n−1))`, saturating; no jitter.
  let cap = max(b.maxMs, 0)
  var d = min(max(b.initialMs, 0), cap)
  if n <= 1 or b.multiplier <= 1:
    return d
  var i = 1'i64
  while i < n:
    if d >= cap or d > cap div b.multiplier:
      return cap
    d = d * b.multiplier
    inc i
  min(d, cap)

func classifyRecover*(code: ErrorCode): Answer =
  ## [SPEC RUNTIME l.3537-3544; I94, plan §2.7] What a `recover_module`
  ## answer means for the accounting. Every code the table does not list is a
  ## lost answer.
  case code
  of ecOk: answerAccepted
  of ecInvalidParams, ecNotReady, ecNotAuthorised, ecModule: answerRefused
  of ecCancelled: answerCancelled
  else: answerLost

func monoOfLastCall*(lastCallAt, delayMs, nowWall, nowMono: int64): int64 =
  ## [IMPL; I94] The monotonic moment standing for a loaded `last_call_at`:
  ## the remaining delay is `clamp(last_call_at + delay − now, 0, delay)`, so a
  ## clock moved backwards or forwards neither shortens a delay below zero nor
  ## stretches it past one full delay.
  let d = max(delayMs, 0)
  var remaining: int64
  if lastCallAt > nowWall:
    remaining = d # the clock went backwards: a full delay, never more
  elif nowWall - lastCallAt >= d:
    remaining = 0
  else:
    remaining = d - (nowWall - lastCallAt)
  nowMono + remaining - d

func openEpisode*(v: View): Entry =
  Entry(module: v.module, instance: v.instance, intentRevision: v.intentRevision)

proc charge*(entry: var Opt[Entry], v: View, nowWall, nowMono: int64) =
  ## [I94] The write-ahead before a charged `recover_module`: one more call
  ## and attempt, the time, and the guarded revision as `pending`.
  if entry.isNone:
    entry = Opt.some(openEpisode(v))
  entry.get.calls = entry.get.calls + 1
  entry.get.attempts = entry.get.attempts + 1
  entry.get.lastCallAt = Opt.some(nowWall)
  entry.get.lastCallMono = Opt.some(nowMono)
  entry.get.pending = Opt.some(v.revision)

proc settle*(entry: var Entry, a: Answer) =
  ## [I94; C-9] A charged call's answer: accepted keeps the charge; a refusal
  ## refunds the attempt and keeps the spacing; a lost answer keeps the charge,
  ## once; a cancellation leaves `pending` for the next start (rule 4e).
  case a
  of answerAccepted, answerLost:
    entry.pending = Opt.none(uint64)
  of answerRefused:
    entry.pending = Opt.none(uint64)
    entry.attempts = max(entry.attempts - 1, 0)
  of answerCancelled:
    discard

proc noteProbe*(memo: var Memo, nowMono: int64) =
  ## An uncharged call (a probe, a resumption or a default) was made; a hint
  ## that brought it forward is spent.
  memo.probes = memo.probes + 1
  memo.lastProbeAt = Opt.some(nowMono)
  memo.hinted = false

proc see(memo: var Memo, w: Waiting, now: int64) =
  if memo.waiting != w:
    memo.waiting = w
    memo.seenAt = now

proc probeDue(memo: var Memo, b: Backoff, now: int64, immediate: bool): int64 =
  ## [G288] `delay(probes)` after the last uncharged call; the first is due
  ## at once (`immediate`) or `initial` after the state was first seen. A hint
  ## brings it forward to `max(last call + initial, now)`, never sooner, and
  ## stays in force until that call is made: a decision taken before it is
  ## due (a resync, another read) does not spend it.
  result =
    if memo.lastProbeAt.isSome:
      memo.lastProbeAt.get + delay(b, memo.probes)
    elif immediate:
      now
    else:
      memo.seenAt + delay(b, 0)
  if memo.hinted:
    let early =
      if memo.lastProbeAt.isSome:
        max(memo.lastProbeAt.get + b.initialMs, now)
      else:
        now
    result = min(result, early)

proc resetSpacing(memo: var Memo) =
  memo.waiting = waitingNone
  memo.probes = 0
  memo.lastProbeAt = Opt.none(int64)
  memo.hinted = false
  memo.disabledNoted = false

proc drop(entry: var Opt[Entry], d: var Decision) =
  if entry.isSome:
    entry = Opt.none(Entry)
    d.entryChanged = true

proc due(d: var Decision, at, now: int64): bool =
  ## True when `at` has come; otherwise `d` waits for it.
  if at <= now:
    return true
  d.dueAt = Opt.some(at)
  false

proc decide*(
    v: View,
    entry: var Opt[Entry],
    memo: var Memo,
    r: Restart,
    default: DefaultKind,
    now: int64,
    firstPass: bool,
): Decision =
  ## [SPEC RUNTIME l.3774-3790; I94] The decision for one fresh view. `entry`
  ## and `memo` are updated; `now` is monotonic ms. `firstPass` is true for
  ## the module's first decision on the instance since it started.
  result = Decision(step: stepNone)
  # Rule 1 [I94]: its own instance and the Module Loader, nothing else.
  if v.isSelf or v.isLoader:
    return
  case v.intent
  of intentUninitialized:
    # Rule 2 [SPEC RUNTIME l.194, l.1913; G287]
    drop(entry, result)
    memo.readySince = Opt.none(int64)
    if default == defaultNone:
      memo.resetSpacing()
      return
    if default == defaultStart and not v.prerequisitesReady:
      return
    memo.see(waitingProbe, now)
    if not result.due(memo.probeDue(r.backoff, now, immediate = true), now):
      return
    result.step = (if default == defaultStart: stepStart else: stepStop)
    result.revision = v.revision
  of intentStopped:
    # Rule 3 [SPEC RUNTIME l.3790]
    drop(entry, result)
    memo.resetSpacing()
    memo.readySince = Opt.none(int64)
  of intentRequested:
    # 4a: another intent revision is another episode.
    if entry.isSome and entry.get.intentRevision != v.intentRevision:
      drop(entry, result)
    if entry.isSome and entry.get.pending.isSome:
      # 4e [C-9]: a lost answer stays charged, once; the state just read
      # decides.
      entry.get.pending = Opt.none(uint64)
      result.entryChanged = true
    case v.life
    of lifeLoaded, lifeStopping:
      return # 4b
    of lifeReady:
      # 4c: the episode closes once the instance has been ready for stable_ms.
      memo.resetSpacing()
      if memo.readySince.isNone:
        memo.readySince = Opt.some(now)
      if entry.isSome:
        if entry.get.exhausted or not r.enabled:
          drop(entry, result)
        elif result.due(memo.readySince.get + r.backoff.stableMs, now):
          drop(entry, result)
      return
    of lifeUnloaded, lifeError:
      memo.readySince = Opt.none(int64)
      if not v.prerequisitesReady:
        return # 4d [G287]
      let live = v.life == lifeError and not v.overran
      if firstPass:
        # 4f [G289, amending G193]
        if not live or not r.enabled or entry.isNone:
          if not r.enabled:
            drop(entry, result)
          memo.see((if live: waitingFailure else: waitingProbe), now)
          result.step = stepRecover
          result.revision = v.revision
          return
      if not live:
        # 4g [G288, G291]: uncharged, never exhausted, under every policy.
        memo.see(waitingProbe, now)
        if not result.due(memo.probeDue(r.backoff, now, immediate = false), now):
          return
        result.step = stepRecover
        result.revision = v.revision
        return
      # 4h [SPEC RUNTIME l.3786-3789]: a live failure.
      memo.see(waitingFailure, now)
      memo.hinted = false
      if not r.enabled:
        if not memo.disabledNoted:
          memo.disabledNoted = true
          result.note = "the restart policy is disabled: no recovery"
        return
      if entry.isSome and entry.get.exhausted:
        return
      if entry.isSome and r.backoff.maxAttempts > 0 and
          entry.get.attempts >= r.backoff.maxAttempts:
        entry.get.exhausted = true
        result.entryChanged = true
        result.note =
          "restart attempts exhausted after " & $entry.get.attempts & " of " &
          $r.backoff.maxAttempts
        return
      let at =
        if entry.isSome and entry.get.lastCallMono.isSome:
          entry.get.lastCallMono.get + delay(r.backoff, entry.get.calls)
        else:
          memo.seenAt + delay(r.backoff, 0)
      if not result.due(at, now):
        return
      result.step = stepRecover
      result.revision = v.revision
      result.charged = true

{.pop.}
