## The reference orchestration module's worker thread (DECISIONS I94; RUNTIME
## l.71-72, l.182-194, l.1640-1643, l.3425-3428, l.3774-3790, l.3801-3808).
##
## One worker per orchestration instance makes every decision, every Runtime
## Control call and every state-file write. Other threads only hand it data:
##
## - Event handlers (the Runtime's event workers, G178) copy the event's bytes
##   into a ring of 64 hints and ring the bell; a full ring or a larger event
##   sets `overflow`, which makes the worker resynchronize at once.
## - Completions of the module's asynchronous lifecycle calls (the Runtime's
##   lifecycle workers) copy the code and response into the call's slot and
##   ring the bell.
##
## Nothing the garbage collector owns crosses threads, under orc or refc: the
## shared block is `allocShared0`'d, and the worker decodes its own settings
## from the configuration's bytes.
##
## Phases (plan §2.5): identity (`get_self`), bring-up of the authority under
## the derived rules (only with `authority`), the binding probe
## (`list_modules {limit: 1}`, G290), then operational: subscriptions, a full
## traversal with the first reconciliation pass, hints, timers and a periodic
## resync that subscribes anew (G225). A NOT_AUTHORISED on `list_modules`
## returns to bring-up when an authority is configured.
##
## Lifecycle calls are asynchronous (`prepare_call`; G173): one per instance,
## 16 at once [IMPL]. Every answer is followed by a fresh `get_readiness` of
## the instance before anything else is decided (RUNTIME l.3427).

{.push raises: [], gcsafe.}

import std/[atomics, locks, monotimes, os, sets, strutils, tables, times]
import results
import ../durable
import ../base/perthread
import ../runtime/bell
import ../kit/rcclient
import ../loader/contract
import ./[accounting, policy, settings]

when defined(lcnTestHooks):
  import ./testhooks

const
  HintSlots* = 64 ## [IMPL] queued hints before a resync
  HintBytes* = 1024 ## [IMPL] a larger event is a resync
  MaxInFlight* = 16 ## [IMPL] lifecycle calls at once
  PageLimit = 256'u16
  BringUpFirstMs = 100'i64 ## [IMPL] authority polls: 100 ms doubling to 5 s
  BringUpMaxMs = 5_000'i64
  ProbeFirstMs = 50'i64 ## [IMPL] binding probes: 50 ms doubling to 2 s
  ProbeMaxMs = 2_000'i64
  NoticeEveryMs = 30_000'i64 ## [IMPL] a repeated diagnostic at most this often
  EvModuleState = "logos.runtime_control.module_state_changed_event"
  EvExecutionState = "logos.runtime_control.execution_state_changed_event"
  EvInventory = "logos.runtime_control.inventory_changed_event"
  EvConfigurationState = "logos.runtime_control.configuration_state_changed_event"
  Events = [EvModuleState, EvExecutionState, EvInventory, EvConfigurationState]

type
  DiagnosticsSink* = proc(line: string) {.nimcall, gcsafe, raises: [].}
    ## [I94] P6: receives the module's diagnostic lines, on its worker thread

  HintKind = enum
    hintModuleState
    hintExecutionState
    hintInventory
    hintConfigurationState

  Hint = object
    kind: HintKind
    len: int
    data: array[HintBytes, byte]

  Slot = object
    shared: ptr Shared
    call: LogosAsyncCall ## the worker's, while `busy`
    busy: bool ## the worker's
    done: bool ## under `lock`: the completion came
    code: ErrorCode
    response: SharedBytes

  Shared* = object
    lock: Lock
    bell: Bell
    quit: Atomic[bool]
    hints: array[HintSlots, Hint]
    hintHead, hintCount: int
    overflow: bool
    slots: array[MaxInFlight, Slot]
    rc*: ptr LogosRuntimeControlBinding
    config: SharedBytes ## the configuration value's CBOR
    stateDir: SharedBytes ## empty: no state directory
    thread: Thread[ptr Shared]
    started: bool

  Phase = enum
    phaseIdentity
    phaseBringUp
    phaseProbe
    phaseOperational
    phaseHalted

  Issued = object
    module, instance: string
    step: Step
    charged: bool
    revision: uint64

  Worker = object
    sh: ptr Shared
    rc: ptr LogosRuntimeControlBinding
    s: Settings
    acc: Accounting
    phase: Phase
    selfId, runtimeId: string
    known: Table[string, View]
    memos: Table[string, Memo]
    timers: Table[string, int64]
    firstPassOpen: HashSet[string]
    inFlight: Table[string, int]
    issued: array[MaxInFlight, Issued]
    reads: seq[string]
    readSet: HashSet[string]
    blocked: HashSet[string]
    subs: seq[LogosSubscriptionId]
    nextTry: int64
    bringDelay, probeDelay: int64
    nextResync: int64
    rescan: bool
    firstTraversalDone: bool
    operationalSince: int64
    notices: Table[string, int64]

var sinkPtr: Atomic[pointer]

proc setOrchestratorDiagnostics*(sink: DiagnosticsSink) =
  ## [I94] P6: where the module's diagnostic lines go; nil for nowhere.
  sinkPtr.store(cast[pointer](sink))

proc diag(line: string) =
  let p = sinkPtr.load
  if p != nil:
    cast[DiagnosticsSink](p)("lcn_orchestrator: " & line)

proc monoMs(): int64 =
  getMonoTime().ticks div 1_000_000

proc wallMs(): int64 =
  let t = getTime()
  t.toUnix * 1000 + int64(t.nanosecond div 1_000_000)

proc notice(w: var Worker, key, line: string) =
  ## A repeated diagnostic, at most every 30 s per `key`.
  let now = monoMs()
  let last = w.notices.getOrDefault(key, low(int64))
  if last == low(int64) or now - last >= NoticeEveryMs:
    w.notices[key] = now
    diag(line)

proc sharedCopy(data: openArray[byte]): SharedBytes =
  if data.len == 0:
    return SharedBytes()
  result.len = data.len
  result.data = cast[ptr UncheckedArray[byte]](allocShared(data.len))
  copyMem(result.data, unsafeAddr data[0], data.len)

proc bytesOf(b: SharedBytes): seq[byte] =
  result = newSeq[byte](b.len)
  if b.len > 0:
    copyMem(addr result[0], b.data, b.len)

proc textOf(b: SharedBytes): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], b.data, b.len)

# Threads that only hand data over ------------------------------------------------------

proc onEvent(
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  ## [SPEC RUNTIME l.3427] A hint only: the worker reads before it decides.
  let sh = cast[ptr Shared](userData)
  when defined(lcnTestHooks):
    if hintsSuppressed():
      return
  let name = $eventName
  var kind: HintKind
  if name == EvModuleState:
    kind = hintModuleState
  elif name == EvExecutionState:
    kind = hintExecutionState
  elif name == EvInventory:
    kind = hintInventory
  elif name == EvConfigurationState:
    kind = hintConfigurationState
  else:
    return
  withLock sh.lock:
    if cborDataLen > csize_t(HintBytes) or sh.hintCount == HintSlots:
      sh.overflow = true
    else:
      let i = (sh.hintHead + sh.hintCount) mod HintSlots
      sh.hints[i].kind = kind
      sh.hints[i].len = int(cborDataLen)
      if cborDataLen > 0:
        copyMem(addr sh.hints[i].data[0], cborData, int(cborDataLen))
      inc sh.hintCount
  sh.bell.ring()

proc onComplete(
    userData: pointer,
    status: LogosResult,
    responseCbor: ptr UncheckedArray[uint8],
    responseCborLen: csize_t,
    owner: LogosResponseOwner,
) {.cdecl, gcsafe, raises: [].} =
  let slot = cast[ptr Slot](userData)
  let (code, copy) = readCompletion(status, responseCbor, responseCborLen, owner)
  let sh = slot.shared
  withLock sh.lock:
    slot.code = code
    slot.response = copy
    slot.done = true
  sh.bell.ring()

# Shared block --------------------------------------------------------------------------

proc newShared*(
    rc: ptr LogosRuntimeControlBinding, config: openArray[byte], stateDir: string
): ptr Shared =
  result = cast[ptr Shared](allocShared0(sizeof(Shared)))
  initLock(result.lock)
  result.bell = newBell()
  result.rc = rc
  result.config = sharedCopy(config)
  result.stateDir = sharedCopy(stateDir.toOpenArrayByte(0, stateDir.high))
  for i in 0 ..< MaxInFlight:
    result.slots[i].shared = result

proc freeShared*(sh: ptr Shared) =
  ## After the worker has ended: nothing else refers to the block.
  for i in 0 ..< MaxInFlight:
    free(sh.slots[i].response)
  free(sh.config)
  free(sh.stateDir)
  freeBell(sh.bell)
  deinitLock(sh.lock)
  deallocShared(sh)

# Views ---------------------------------------------------------------------------------

func lifeOf(s: LogosNSRuntimeControlState): Life =
  case s.kind
  of LogosNSRuntimeControlStateKind.Unloaded: lifeUnloaded
  of LogosNSRuntimeControlStateKind.Loaded: lifeLoaded
  of LogosNSRuntimeControlStateKind.Ready: lifeReady
  of LogosNSRuntimeControlStateKind.Stopping: lifeStopping
  of LogosNSRuntimeControlStateKind.Error: lifeError

proc viewOf(
    w: Worker,
    module, instance: string,
    state: LogosNSRuntimeControlState,
    execution: LogosNSRuntimeControlExecutionState,
    failure: Opt[string],
): View =
  View(
    module: module,
    instance: instance,
    life: lifeOf(state),
    intent: (
      case execution.intent.kind
      of LogosNSRuntimeControlExecutionStateIntentChoiceKind.Requested: intentRequested
      of LogosNSRuntimeControlExecutionStateIntentChoiceKind.Stopped: intentStopped
      of LogosNSRuntimeControlExecutionStateIntentChoiceKind.Uninitialized:
        intentUninitialized
    ),
    intentRevision: execution.intent_revision.get(0),
    revision: execution.revision,
    isSelf: instance == w.selfId,
    isLoader: instance == LoaderInstanceId,
    overran: failure.isSome and failure.get == OverranFailure,
  )

proc prerequisitesReady(w: Worker, instance: string): bool =
  ## [G287] Every prerequisite the module's `ordering` names is `ready`.
  for p in w.s.prerequisites.getOrDefault(instance):
    let v = w.known.getOrDefault(p)
    if v.instance.len == 0 or v.life != lifeReady:
      return false
  true

# Calls ---------------------------------------------------------------------------------

template counted(w: Worker, methodName, instance: string) =
  when defined(lcnTestHooks):
    recordCall(methodName, instance)

proc readiness(
    w: var Worker, module, instance: string
): Result[LogosNSRuntimeControlGetReadinessResponse, RcFailure] =
  w.counted("get_readiness", instance)
  call(
    w.rc,
    "get_readiness",
    LogosNSRuntimeControlGetReadinessRequest(
      module: module, instance: Opt.some(instance)
    ),
    LogosNSRuntimeControlGetReadinessResponse,
  )

proc save(w: var Worker): bool =
  when defined(lcnTestHooks):
    if writesFail():
      diag("the accounting could not be written: a test fault")
      return false
  let r = w.acc.save()
  if r.isErr:
    diag("the accounting could not be written: " & r.error)
    return false
  true

proc queueRead(w: var Worker, instance: string) =
  if not w.readSet.containsOrIncl(instance):
    w.reads.add(instance)

proc freeSlot(w: Worker): int =
  for i in 0 ..< MaxInFlight:
    if not w.sh.slots[i].busy:
      return i
  -1

proc methodOf(step: Step): string =
  case step
  of stepStart: "start_module"
  of stepStop: "stop_module"
  of stepRecover: "recover_module"
  of stepNone: ""

proc refund(w: var Worker, instance: string) =
  ## The write-ahead of a call that was never made is undone, as a refusal is.
  w.acc.entries.withValue(instance, e):
    e[].settle(answerRefused)
  discard w.save()

proc issue(w: var Worker, v: View, d: Decision, memo: var Memo): bool =
  ## [SPEC RUNTIME l.1832-1833, l.3537-3544; G173] One asynchronous lifecycle
  ## call; false when no slot was free. A charged call is written first.
  let i = w.freeSlot()
  if i < 0:
    w.blocked.incl(v.instance)
    return false
  let now = monoMs()
  if d.charged:
    if v.instance notin w.acc.entries and w.acc.entries.len >= MaxEntries:
      w.notice("entries", "more than 4096 open episodes: no new retry is made")
      w.timers[v.instance] = now + w.s.resyncMs
      return true
    var entry = w.acc.entries.getOrDefault(v.instance)
    var opt =
      if v.instance in w.acc.entries:
        Opt.some(entry)
      else:
        Opt.none(Entry)
    let before = opt
    opt.charge(v, wallMs(), now)
    w.acc.entries[v.instance] = opt.get
    if not w.save():
      # [I94] A failed write means no call: the bound never depends on a write
      # that did not happen. Retried at the next due time.
      if before.isSome:
        w.acc.entries[v.instance] = before.get
      else:
        w.acc.entries.del(v.instance)
      w.timers[v.instance] = now + w.s.restartFor(v.instance).backoff.initialMs
      return true
  else:
    memo.noteProbe(now)
  when defined(lcnTestHooks):
    if d.step in {stepStart, stepStop}:
      if pauseGateSet():
        notePaused()
        while pauseGateSet() and not w.sh.quit.load:
          sleep(5)
  let name = methodOf(d.step)
  w.counted(name, v.instance)
  let slot = addr w.sh.slots[i]
  var prepared: Result[void, RcFailure]
  case d.step
  of stepStart:
    prepared = prepare(
      w.rc,
      name,
      LogosNSRuntimeControlStartModuleRequest(
        module: v.module,
        instance: Opt.some(v.instance),
        expected_execution_revision: Opt.some(d.revision),
      ),
      onComplete,
      slot,
      slot.call,
    )
  of stepStop:
    prepared = prepare(
      w.rc,
      name,
      LogosNSRuntimeControlStopModuleRequest(
        module: v.module,
        instance: Opt.some(v.instance),
        expected_execution_revision: Opt.some(d.revision),
      ),
      onComplete,
      slot,
      slot.call,
    )
  of stepRecover:
    prepared = prepare(
      w.rc,
      name,
      LogosNSRuntimeControlRecoverModuleRequest(
        module: v.module, instance: v.instance, expected_execution_revision: d.revision
      ),
      onComplete,
      slot,
      slot.call,
    )
  of stepNone:
    return true
  if prepared.isErr:
    # [I94] No call was made: a charged one is refunded, the next is spaced.
    diag(name & " " & v.instance & ": not prepared: " & $prepared.error)
    if d.charged:
      w.refund(v.instance)
    w.timers[v.instance] = now + w.s.restartFor(v.instance).backoff.initialMs
    return true
  slot.busy = true
  w.issued[i] = Issued(
    module: v.module,
    instance: v.instance,
    step: d.step,
    charged: d.charged,
    revision: d.revision,
  )
  w.inFlight[v.instance] = i
  if d.charged:
    let e = w.acc.entries.getOrDefault(v.instance)
    let limit = w.s.restartFor(v.instance).backoff.maxAttempts
    diag(
      name & " " & v.instance & ": attempt " & $e.attempts &
        (if limit > 0: " of " & $limit else: "")
    )
  submit(slot.call)
  true

proc decideOne(w: var Worker, view: View) =
  ## [SPEC RUNTIME l.3774-3790] One decision on one fresh view, acted on.
  if view.instance in w.inFlight:
    return # one lifecycle call per instance
  var v = view
  v.prerequisitesReady = w.prerequisitesReady(v.instance)
  w.known[v.instance] = v
  var entry =
    if v.instance in w.acc.entries:
      Opt.some(w.acc.entries.getOrDefault(v.instance))
    else:
      Opt.none(Entry)
  var memo = w.memos.getOrDefault(v.instance)
  let firstPass = v.instance in w.firstPassOpen
  w.timers.del(v.instance)
  let d = decide(
    v,
    entry,
    memo,
    w.s.restartFor(v.instance),
    w.s.defaultFor(v.instance),
    monoMs(),
    firstPass,
  )
  if d.note.len > 0:
    diag(v.instance & ": " & d.note)
  if entry.isSome:
    w.acc.entries[v.instance] = entry.get
  else:
    w.acc.entries.del(v.instance)
  if d.entryChanged:
    discard w.save()
  if d.dueAt.isSome:
    w.timers[v.instance] = d.dueAt.get
  var consumed = true
  if v.intent == intentRequested and v.life in {lifeUnloaded, lifeError} and
      not v.prerequisitesReady:
    consumed = false # rule 4d: the first pass waits for the prerequisites
  if d.step != stepNone and not w.issue(v, d, memo):
    consumed = false
  if consumed:
    w.firstPassOpen.excl(v.instance)
  w.memos[v.instance] = memo

# Phases --------------------------------------------------------------------------------

proc identity(w: var Worker) =
  ## [SPEC RUNTIME l.2553-2560; I94] `get_self` first: the module's own id and
  ## the Runtime's, which the state file is checked against.
  w.counted("get_self", "")
  let r = call(
    w.rc,
    "get_self",
    LogosNSRuntimeControlGetSelfRequest(),
    LogosNSRuntimeControlGetSelfResponse,
  )
  let now = monoMs()
  if r.isErr:
    w.notice("identity", "get_self: " & $r.error & "; retrying")
    w.nextTry = now + w.bringDelay
    w.bringDelay = min(w.bringDelay * 2, BringUpMaxMs)
    return
  w.selfId = r.get.consumer.module_instance_id
  w.runtimeId = r.get.consumer.runtime_instance_id
  w.bringDelay = BringUpFirstMs
  if w.acc.checkRuntime(w.runtimeId):
    diag(
      "the accounting belongs to another Runtime instance: every entry is " & "discarded"
    )
  if w.acc.dir.len > 0:
    discard w.save()
  w.acc.placeOnClock(w.s, wallMs(), now)
  if w.s.authority.isSome and w.s.authority.get.instance == w.selfId:
    diag("authority names this module's own instance: ignored")
    w.s.authority = Opt.none(Target)
  if w.s.authority.isSome:
    w.firstPassOpen.incl(w.s.authority.get.instance)
    w.phase = phaseBringUp
  else:
    w.phase = phaseProbe
  w.nextTry = now

proc bringUp(w: var Worker) =
  ## [SPEC RUNTIME l.1640-1643, l.1674-1680; HOST-CONFIG "Who starts the
  ## authority"] The authority, under the derived rules, until it is `ready`.
  let a = w.s.authority.get
  let now = monoMs()
  if a.instance in w.inFlight:
    w.nextTry = now + w.bringDelay
    return
  let r = w.readiness(a.module, a.instance)
  if r.isErr:
    if r.error.code == ecNotAuthorised:
      # The derived rules do not apply: an authority already bound, or
      # `recovery: false` after a loss.
      w.phase = phaseProbe
      w.nextTry = now
      return
    w.notice("bringup", "get_readiness " & a.instance & ": " & $r.error)
    w.nextTry = now + w.bringDelay
    w.bringDelay = min(w.bringDelay * 2, BringUpMaxMs)
    return
  let g = r.get
  if g.execution.isNone:
    w.notice("bringup", "the authority " & a.instance & " has no execution state")
    w.nextTry = now + w.bringDelay
    w.bringDelay = min(w.bringDelay * 2, BringUpMaxMs)
    return
  let v = w.viewOf(a.module, a.instance, g.state, g.execution.get, g.failure)
  if v.life == lifeReady and v.intent == intentRequested:
    w.known[a.instance] = v
    w.phase = phaseProbe
    w.nextTry = now
    return
  w.decideOne(v)
  w.notice("bringup", "waiting for the authority " & a.instance & " to be ready")
  w.nextTry = now + w.bringDelay
  w.bringDelay = min(w.bringDelay * 2, BringUpMaxMs)

proc subscribeAll(w: var Worker): seq[LogosSubscriptionId] =
  for e in Events:
    let r = subscribe(w.rc, e, onEvent, w.sh)
    if r.isOk:
      result.add(r.get)
    else:
      # [SPEC RUNTIME l.3428] No events; the resync still runs.
      w.notice("subscribe " & e, "subscribe " & e & ": " & $r.error)

proc unsubscribeAll(w: var Worker, ids: seq[LogosSubscriptionId]) =
  for id in ids:
    let r = unsubscribe(w.rc, id)
    if r.isErr:
      diag("unsubscribe: " & $r.error)

proc lostAuthority(w: var Worker) =
  ## [I94, plan §2.5.3] Active policy no longer answers `list_modules`.
  let now = monoMs()
  if w.s.authority.isSome:
    diag("list_modules refused: back to the authority's bring-up")
    w.unsubscribeAll(w.subs)
    w.subs = @[]
    w.phase = phaseBringUp
    w.bringDelay = BringUpFirstMs
    w.nextTry = now
  else:
    w.notice("lost", "list_modules refused: retrying at the resync interval")
    w.nextResync = now + w.s.resyncMs

proc traverse(w: var Worker): bool =
  ## [SPEC RUNTIME l.3425-3428, l.3774] Every listed instance, read and
  ## decided: the topological order of `ordering` first, then listing order.
  var cursor = Opt.none(string)
  var listed: seq[View]
  var seen = initHashSet[string]()
  while true:
    w.counted("list_modules", "")
    let r = call(
      w.rc,
      "list_modules",
      LogosNSRuntimeControlListModulesRequest(
        limit: Opt.some(PageLimit), cursor: cursor
      ),
      LogosNSRuntimeControlListModulesResponse,
    )
    if r.isErr:
      if r.error.code == ecNotAuthorised:
        w.lostAuthority()
      else:
        w.notice("list", "list_modules: " & $r.error)
      return false
    let page = r.get
    for m in page.modules:
      if m.instance.isNone or m.execution.isNone or m.remote.isSome:
        continue
      let inst = m.instance.get
      if seen.containsOrIncl(inst):
        continue
      listed.add(w.viewOf(m.module, inst, m.state, m.execution.get, m.failure))
    if page.next_cursor.isNone:
      break
    cursor = Opt.some(page.next_cursor.get)
  # Retired instances: their episodes and memory go.
  var gone: seq[string]
  for k in w.acc.entries.keys:
    if k notin seen:
      gone.add(k)
  if gone.len > 0:
    for k in gone:
      w.acc.entries.del(k)
    discard w.save()
  var forget: seq[string]
  for k in w.known.keys:
    if k notin seen:
      forget.add(k)
  for k in forget:
    w.known.del(k)
    w.memos.del(k)
    w.timers.del(k)
  for v in listed:
    w.known[v.instance] = v
  if not w.firstTraversalDone:
    # [G289] The first traversal opens one first-pass decision for each
    # instance not decided yet (the authority was, in bring-up).
    w.firstTraversalDone = true
    for v in listed:
      if v.instance notin w.memos:
        w.firstPassOpen.incl(v.instance)
  var byName = initTable[string, int]()
  for i, v in listed:
    byName[v.instance] = i
  var done = initHashSet[string]()
  for inst in w.s.order:
    let i = byName.getOrDefault(inst, -1)
    if i >= 0:
      done.incl(inst)
      w.decideOne(listed[i])
  for v in listed:
    if v.instance notin done:
      w.decideOne(v)
  true

proc probe(w: var Worker) =
  ## [SPEC RUNTIME l.1643, l.1645-1657; G290] The first `list_modules` active
  ## policy allows shows the binding.
  let now = monoMs()
  if w.s.authority.isSome:
    let a = w.s.authority.get
    let r = w.readiness(a.module, a.instance)
    if r.isOk and r.get.state.kind != LogosNSRuntimeControlStateKind.Ready:
      w.phase = phaseBringUp
      w.nextTry = now
      return
  w.counted("list_modules", "")
  let r = call(
    w.rc,
    "list_modules",
    LogosNSRuntimeControlListModulesRequest(limit: Opt.some(1'u16)),
    LogosNSRuntimeControlListModulesResponse,
  )
  if r.isErr:
    w.notice("probe", "waiting for the authority binding: list_modules " & $r.error)
    w.nextTry = now + w.probeDelay
    w.probeDelay = min(w.probeDelay * 2, ProbeMaxMs)
    return
  # [I94; S4b5-2] Operational: subscriptions before the first traversal.
  w.subs = w.subscribeAll()
  w.phase = phaseOperational
  w.operationalSince = now
  w.nextResync = now + w.s.resyncMs
  diag("operational")
  discard w.traverse()

proc resync(w: var Worker) =
  ## [SPEC RUNTIME l.3426, l.3428; G225] Subscribe anew first, then end the
  ## old subscriptions, then traverse everything.
  let now = monoMs()
  let fresh = w.subscribeAll()
  w.unsubscribeAll(w.subs)
  w.subs = fresh
  w.nextResync = now + w.s.resyncMs
  w.rescan = false
  if now - w.operationalSince >= w.s.resyncMs:
    w.probeDelay = ProbeFirstMs
  discard w.traverse()

proc takeHints(w: var Worker): (seq[(HintKind, seq[byte])], bool) =
  var got: seq[(HintKind, seq[byte])]
  var overflow = false
  withLock w.sh.lock:
    while w.sh.hintCount > 0:
      let h = addr w.sh.hints[w.sh.hintHead]
      var b = newSeq[byte](h.len)
      if h.len > 0:
        copyMem(addr b[0], addr h.data[0], h.len)
      got.add((h.kind, b))
      w.sh.hintHead = (w.sh.hintHead + 1) mod HintSlots
      dec w.sh.hintCount
    overflow = w.sh.overflow
    w.sh.overflow = false
  (got, overflow)

proc hinted(w: var Worker, instance: string) =
  var m = w.memos.getOrDefault(instance)
  m.hinted = true
  w.memos[instance] = m
  w.queueRead(instance)

proc applyHints(w: var Worker) =
  ## [SPEC RUNTIME l.3427] Hints name what to read again.
  let (got, overflow) = w.takeHints()
  if overflow:
    w.rescan = true
    w.nextResync = monoMs()
  for (kind, bytes) in got:
    case kind
    of hintModuleState:
      let e = LogosNSRuntimeControlModuleStateChangedEvent.decode(bytes)
      if e.isErr or e.get.instance.isNone:
        continue
      let inst = e.get.instance.get
      w.hinted(inst)
      if e.get.new_state.kind == LogosNSRuntimeControlStateKind.Ready:
        for d in w.s.dependents.getOrDefault(inst):
          w.queueRead(d)
        if w.s.authority.isSome and inst == w.s.authority.get.instance:
          # [G288] The authority's return brings every probe forward.
          var waiting: seq[string]
          for k, m in w.memos:
            if m.waiting == waitingProbe:
              waiting.add(k)
          for k in waiting:
            w.hinted(k)
    of hintExecutionState:
      let e = LogosNSRuntimeControlExecutionStateChangedEvent.decode(bytes)
      if e.isOk:
        w.queueRead(e.get.instance)
    of hintInventory:
      w.rescan = true
    of hintConfigurationState:
      # [G162, G288] A configuration for the instance brings its probe forward.
      let e = LogosNSRuntimeControlConfigurationStateChangedEvent.decode(bytes)
      if e.isOk:
        let inst = e.get.target.module_instance_id
        if inst in w.known:
          w.hinted(inst)
        else:
          w.rescan = true

proc takeAnswers(w: var Worker) =
  ## [I94; C-9] Each answered call: the accounting settled, the instance read
  ## again.
  for i in 0 ..< MaxInFlight:
    if not w.sh.slots[i].busy:
      continue
    var done = false
    var code = ecOk
    var response = SharedBytes()
    withLock w.sh.lock:
      if w.sh.slots[i].done:
        done = true
        code = w.sh.slots[i].code
        response = w.sh.slots[i].response
        w.sh.slots[i].response = SharedBytes()
        w.sh.slots[i].done = false
    if not done:
      continue
    release(w.sh.slots[i].call)
    w.sh.slots[i].busy = false
    let c = w.issued[i]
    w.inFlight.del(c.instance)
    when defined(lcnTestHooks):
      if dropThisAnswer():
        free(response)
        diag("the answer of " & methodOf(c.step) & " " & c.instance & " was dropped")
        w.phase = phaseHalted
        return
    var stateText = ""
    if code == ecOk:
      let st =
        case c.step
        of stepRecover:
          decodeShared(response, LogosNSRuntimeControlRecoverModuleResponse).map(
            proc(x: LogosNSRuntimeControlRecoverModuleResponse): string =
              toLowerAscii($x.state.kind)
          )
        of stepStart:
          decodeShared(response, LogosNSRuntimeControlStartModuleResponse).map(
            proc(x: LogosNSRuntimeControlStartModuleResponse): string =
              toLowerAscii($x.state.kind)
          )
        of stepStop:
          decodeShared(response, LogosNSRuntimeControlStopModuleResponse).map(
            proc(x: LogosNSRuntimeControlStopModuleResponse): string =
              toLowerAscii($x.state.kind)
          )
        of stepNone:
          Result[string, string].err("")
      stateText = st.get("")
    free(response)
    if c.step == stepRecover and c.charged:
      let a = classifyRecover(code)
      var settled = false
      w.acc.entries.withValue(c.instance, e):
        e[].settle(a)
        settled = true
      if settled:
        discard w.save()
    diag(
      methodOf(c.step) & " " & c.instance & ": answered " &
        (if code == ecOk: stateText else: $code)
    )
    w.queueRead(c.instance)
  if w.blocked.len > 0 and w.freeSlot() >= 0:
    var b: seq[string]
    for k in w.blocked:
      b.add(k)
    w.blocked.clear()
    for k in b:
      w.queueRead(k)

proc runReads(w: var Worker) =
  ## [SPEC RUNTIME l.3427] Each named instance read with `get_readiness`, then
  ## decided.
  let names = w.reads
  w.reads = @[]
  w.readSet.clear()
  for inst in names:
    if w.sh.quit.load or w.phase != phaseOperational:
      return
    if inst in w.inFlight:
      continue
    let known = w.known.getOrDefault(inst)
    if known.instance.len == 0:
      w.rescan = true
      continue
    let r = w.readiness(known.module, inst)
    if r.isErr:
      w.notice("read " & inst, "get_readiness " & inst & ": " & $r.error)
      continue
    let g = r.get
    if g.execution.isNone:
      continue
    w.decideOne(w.viewOf(known.module, inst, g.state, g.execution.get, g.failure))

proc dueTimers(w: var Worker, now: int64) =
  var due: seq[string]
  for k, at in w.timers:
    if at <= now:
      due.add(k)
  for k in due:
    w.timers.del(k)
    w.queueRead(k)

proc nextWake(w: Worker, now: int64): int64 =
  case w.phase
  of phaseIdentity, phaseBringUp, phaseProbe:
    result = w.nextTry
  of phaseOperational:
    result = w.nextResync
    for at in w.timers.values:
      result = min(result, at)
    if w.reads.len > 0 or w.rescan:
      result = now
  of phaseHalted:
    result = now + 60_000

proc shutdown(w: var Worker) =
  ## [SPEC RUNTIME l.3806; I94] Nothing stays armed: subscriptions end (each
  ## waits for a running handler), calls in flight are cancelled and released
  ## (each waits for a running completion). A charged call keeps its
  ## `pending` for the next start.
  w.unsubscribeAll(w.subs)
  w.subs = @[]
  for i in 0 ..< MaxInFlight:
    if w.sh.slots[i].busy:
      cancel(w.sh.slots[i].call)
      release(w.sh.slots[i].call)
      w.sh.slots[i].busy = false
      withLock w.sh.lock:
        free(w.sh.slots[i].response)
        w.sh.slots[i].done = false

proc runWorker(sh: ptr Shared) =
  var w = Worker(
    sh: sh,
    rc: sh.rc,
    phase: phaseIdentity,
    bringDelay: BringUpFirstMs,
    probeDelay: ProbeFirstMs,
  )
  let config = LcnOrchestratorConfig.decode(bytesOf(sh.config))
  if config.isErr:
    diag("the configuration does not decode: " & config.error)
    return
  let s = settingsOf(config.get)
  if s.isErr:
    diag("the configuration is invalid: " & s.error)
    return
  w.s = s.get
  let dir = textOf(sh.stateDir)
  if dir.len > 0:
    let bytes = readBounded(dir / StateFileName, MaxStateBytes)
    if bytes.isErr:
      diag("the accounting cannot be read: " & bytes.error)
      return
    if bytes.get.isSome:
      let a = decodeState(bytes.get.get)
      if a.isErr:
        diag("the accounting cannot be read: " & a.error)
        return
      w.acc = a.get
    w.acc.dir = dir
  while not sh.quit.load:
    let now = monoMs()
    w.takeAnswers()
    if sh.quit.load:
      break
    case w.phase
    of phaseIdentity:
      if now >= w.nextTry:
        w.identity()
    of phaseBringUp:
      if now >= w.nextTry:
        w.bringUp()
    of phaseProbe:
      if now >= w.nextTry:
        w.probe()
    of phaseOperational:
      w.applyHints()
      if w.rescan or now >= w.nextResync:
        w.resync()
      w.dueTimers(monoMs())
      w.runReads()
    of phaseHalted:
      discard
    if sh.quit.load:
      break
    let at = w.nextWake(monoMs())
    let left = at - monoMs()
    if left > 0:
      sh.bell.wait(Opt.some(getMonoTime() + initDuration(milliseconds = left)))
  w.shutdown()

proc workerMain(sh: ptr Shared) {.thread.} =
  runWorker(sh)
  # [I94; R17] This thread's tables are freed before it ends.
  releasePerThread()

proc startWorker*(sh: ptr Shared): Result[void, string] =
  try:
    createThread(sh.thread, workerMain, sh)
    sh.started = true
    ok()
  except ResourceExhaustedError as e:
    err("the orchestration worker cannot start: " & e.msg)

proc stopWorker*(sh: ptr Shared) =
  ## Ends the worker and waits for it: nothing calls the binding after.
  sh.quit.store(true)
  sh.bell.ring()
  if sh.started:
    joinThread(sh.thread)
    sh.started = false

{.pop.}
