## Runtime Control events (step 7b; DECISIONS I86): subscriptions through a
## module's Runtime Control binding (INTERFACE §2.5, applied by l.3837), the
## events of RUNTIME §9.3 (l.3415-3428, l.3496-3511, l.3715-3735) and their
## delivery under G178's interim: per subscription, in committed order, after
## the change is exposed, on the Runtime's event workers.
##
## The subscriber is the route fixture's client module: the test subscribes
## through that module's binding. Handlers record into `Watch` slots, plain
## data and atomics, since they run on event workers. `test_rcevents_ca` runs
## these cases with a Capability Authority bound, and adds the cases its
## narrowing needs.

import std/[atomics, monotimes, os, sequtils, strutils, times, typedthreads]
import unittest2
import ../src/logos_core/runtime/engine
from ../src/logos_core/runtime/rc_types import rcSchema
import ../src/logos_core/abi/types
import ../src/logos_core/cbor
import ../src/logos_core/codegen/nimrt
import ../src/logos_core/commitment
import ../src/logos_core/iface/[accept, outcome, payload, surface]
import ../src/logos_core/iface/common_types
import ./support/[kitbuild, kitruntime, tunerconfig]
import ./kit/meter_impl
import ./generated/meter_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work =
    repo / "build" / (when declared(caParity): "rcevents_ca" else: "rcevents") /
    kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture
include ./support/configrc

const
  ModuleState = "logos.runtime_control.module_state_changed_event"
  ExecutionState = "logos.runtime_control.execution_state_changed_event"
  RouteStateEv = "logos.runtime_control.route_state_changed_event"
  Inventory = "logos.runtime_control.inventory_changed_event"
  PermissionSettings = "logos.runtime_control.permission_settings_changed_event"
  ConfigurationState = "logos.runtime_control.configuration_state_changed_event"
  LogCap = 640 ## entries a watch records
  EntryBytes = 1024 ## a configuration summary with two records fits
  NameBytes = 96

# Handlers -----------------------------------------------------------------------------

type Watch = object
  count: Atomic[int] ## handler invocations that returned; the next entry's index
  inside: Atomic[int]
  overlaps: Atomic[int] ## invocations begun while another was active
  thread: Atomic[int]
  hold: Atomic[bool] ## the handler waits while it is true
  held: Atomic[int] ## invocations waiting at `hold`
  lens: array[LogCap, int]
  names: array[LogCap, array[NameBytes, char]]
  data: array[LogCap, array[EntryBytes, byte]]
  # Re-entry, each at most once: unsubscribe itself, call get_readiness, stop
  # an instance.
  rc: ptr LogosRuntimeControlBinding
  selfId: LogosSubscriptionId
  unsubSelf: bool
  selfCode: Atomic[int]
  readiness: bool
  readinessCode: Atomic[int]
  stopTarget: array[32, char]
  stopCode: Atomic[int]
  armed: Atomic[bool]

# One slot per subscription that can deliver: two subscriptions writing into
# one slot would race, as their handlers may run at once.
var watches: array[8, Watch]

proc clear(w: var Watch) =
  w.count.store(0)
  w.inside.store(0)
  w.overlaps.store(0)
  w.thread.store(0)
  w.hold.store(false)
  w.held.store(0)
  w.rc = nil
  w.unsubSelf = false
  w.selfCode.store(-1)
  w.readiness = false
  w.readinessCode.store(-1)
  w.stopTarget[0] = '\0'
  w.stopCode.store(-1)
  w.armed.store(true)

proc clearAll() =
  for w in watches.mitems:
    w.clear()

proc onEvent(
    name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  let w = cast[ptr Watch](userData)
  if w.inside.fetchAdd(1) > 0:
    w.overlaps += 1
  w.thread.store(getThreadId())
  let i = w.count.load
  if i < LogCap:
    let n = min(int(len), EntryBytes)
    for j in 0 ..< n:
      w.data[i][j] = data[j]
    w.lens[i] = n
    var k = 0
    while k < NameBytes - 1 and name[k] != '\0':
      w.names[i][k] = name[k]
      inc k
    w.names[i][k] = '\0'
  if w.hold.load:
    w.held += 1
    while w.hold.load:
      sleep(1)
    w.held -= 1
  var first = true
  if w.armed.compareExchange(first, false):
    if w.unsubSelf:
      let r = w.rc.vtable.unsubscribe(w.rc, w.selfId)
      w.selfCode.store(int(r.code))
    {.cast(gcsafe).}:
      try:
        if w.readiness:
          w.readinessCode.store(
            ord(
              rcCall(
                w.rc,
                "get_readiness",
                encode(LogosNSRuntimeControlGetReadinessRequest(module: "meter_module")).tryGet,
              ).code
            )
          )
        if w.stopTarget[0] != '\0':
          let target = $cast[cstring](addr w.stopTarget[0])
          w.stopCode.store(
            ord(
              w.rc.lifecycle("stop_module", "meter_module", instance = Opt.some(target)).code
            )
          )
      except CatchableError:
        discard
  w.inside -= 1
  w.count += 1

proc nameAt(w: var Watch, i: int): string =
  $cast[cstring](addr w.names[i][0])

proc bytesAt(w: var Watch, i: int): seq[byte] =
  result = newSeq[byte](w.lens[i])
  for j in 0 ..< w.lens[i]:
    result[j] = w.data[i][j]

proc subscribe(
    rc: ptr LogosRuntimeControlBinding,
    event: string,
    w: ptr Watch,
    id: var LogosSubscriptionId,
    handler: LogosEventHandler = onEvent,
): ErrorCode =
  toResult(rc.vtable.subscribe(rc, cstring(event), handler, w, addr id)).code

proc unsubscribe(
    rc: ptr LogosRuntimeControlBinding, id: LogosSubscriptionId
): ErrorCode =
  toResult(rc.vtable.unsubscribe(rc, id)).code

proc reached(w: var Watch, n: int): bool =
  let p = addr w
  waitUntil(
    proc(): bool =
      p.count.load >= n,
    10 * Slow,
  )

proc quiet(w: var Watch): int =
  ## The count once no entry has arrived for a while.
  var last = -1
  while w.count.load != last:
    last = w.count.load
    sleep(100 * Slow)
  last

# Decoding -------------------------------------------------------------------------------

type StateEv = LogosNSRuntimeControlModuleStateChangedEvent

proc stateEv(w: var Watch, i: int): StateEv =
  StateEv.decode(w.bytesAt(i)).tryGet

proc execEv(w: var Watch, i: int): LogosNSRuntimeControlExecutionStateChangedEvent =
  LogosNSRuntimeControlExecutionStateChangedEvent.decode(w.bytesAt(i)).tryGet

proc routeEv(w: var Watch, i: int): LogosNSRuntimeControlRouteStateChangedEvent =
  LogosNSRuntimeControlRouteStateChangedEvent.decode(w.bytesAt(i)).tryGet

proc hintEv(w: var Watch, i: int): LogosNSRuntimeControlInventoryCollectionKind =
  LogosNSRuntimeControlInventoryChangedEvent.decode(w.bytesAt(i)).tryGet.collection.kind

func st(s: LogosNSRuntimeControlState): string =
  ($s.kind).toLowerAscii

func st2(s: LogosNSRuntimeControlRouteState): string =
  ($s.kind).toLowerAscii

proc transitions(w: var Watch, instance: string, upTo = -1): seq[string] =
  ## `old>new` of each recorded `module_state_changed` of `instance`.
  let n = (if upTo < 0: w.count.load else: upTo)
  for i in 0 ..< min(n, LogCap):
    if w.nameAt(i) == ModuleState:
      let ev = w.stateEv(i)
      if ev.instance.get("") == instance:
        result.add(st(ev.old_state) & ">" & st(ev.new_state))

proc hints(w: var Watch, kind: LogosNSRuntimeControlInventoryCollectionKind): int =
  for i in 0 ..< min(w.count.load, LogCap):
    if w.nameAt(i) == Inventory and w.hintEv(i) == kind:
      inc result

const
  Modules = LogosNSRuntimeControlInventoryCollectionKind.Modules
  Routes = LogosNSRuntimeControlInventoryCollectionKind.Routes

# A subscriber whose `_MODULE_destroy` unsubscribes ---------------------------------------

var
  watcherRc: Atomic[pointer]
  watcherUnsub: Atomic[int] ## the subscription its destroy unsubscribes; 0: none
  watcherUnsubCode: Atomic[int]
  watcherDestroyBegan: Atomic[bool]
  watcherInsideAtDestroy: Atomic[int] ## handlers running when its destroy began

proc watcherName(): cstring {.cdecl.} =
  "watcher_module"

proc watcherInit(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl.} =
  watcherRc.store(input.runtimeControl)
  outContext[] = cast[ptr LogosModuleContext](allocShared0(16))

proc watcherDestroy(module: ptr LogosModuleContext) {.cdecl.} =
  watcherInsideAtDestroy.store(watches[3].inside.load)
  watcherDestroyBegan.store(true)
  let id = watcherUnsub.load
  if id != 0:
    let rc = cast[ptr LogosRuntimeControlBinding](watcherRc.load)
    watcherUnsubCode.store(int(rc.vtable.unsubscribe(rc, LogosSubscriptionId(id)).code))
  deallocShared(module)

proc watcherTable(): seq[(string, pointer)] =
  @[
    ("logos_watcher_module_MODULE_name", cast[pointer](watcherName)),
    ("logos_watcher_module_MODULE_init", cast[pointer](watcherInit)),
    ("logos_watcher_module_MODULE_destroy", cast[pointer](watcherDestroy)),
  ]

func watcher(): ModuleRecord =
  ModuleRecord(module: "watcher_module", strategy: stDirectStatic, binding: "watcher")

proc rcConfig(policy = allowAll()): EngineConfig =
  config(policy, @[checkStaticRegistration("watcher", watcherTable()).tryGet])

proc startWatcher(e: Engine, instance: string): ptr LogosRuntimeControlBinding =
  watcherUnsub.store(0)
  watcherUnsubCode.store(-1)
  watcherDestroyBegan.store(false)
  watcherInsideAtDestroy.store(-1)
  discard e.started(watcher(), instance)
  cast[ptr LogosRuntimeControlBinding](watcherRc.load)

proc slows(e: Engine, ids: varargs[string]) =
  for id in ids:
    discard e.create(slow(), id).tryGet

proc retireOf(
    rc: ptr LogosRuntimeControlBinding, e: Engine, instance: string
): RcResult =
  rcCall(
    rc,
    "retire_module",
    encode(
      LogosNSRuntimeControlRetireModuleRequest(
        target: LogosNSRuntimeModuleInstanceAddress(
          runtime_instance_id: e.runtimeInstanceId, module_instance_id: instance
        ),
        expected_execution_revision: e.view(instance).tryGet.execution.revision,
      )
    ).tryGet,
  )

var
  unsubThread: Thread[(ptr LogosRuntimeControlBinding, LogosSubscriptionId)]
  unsubDone: Atomic[bool]
  unsubCode: Atomic[int]

proc unsubOn(arg: (ptr LogosRuntimeControlBinding, LogosSubscriptionId)) {.thread.} =
  unsubCode.store(ord(unsubscribe(arg[0], arg[1])))
  unsubDone.store(true)

when declared(caParity):
  proc narrowing(what: string, alternatives: varargs[RcNarrow]): Rule =
    Rule(what: what, verdict: vAllow, validMs: Everything, narrowControl: @alternatives)

  proc changePolicy(revision: uint64) =
    ## A new script takes effect: the cached decisions go.
    check publish(PolicyChangedName, policyChanged(revision - 1, revision))

  func only(s: varargs[string]): Opt[seq[string]] =
    Opt.some(@s)

# subscribe and unsubscribe ---------------------------------------------------------------

suite "run.rc: subscribe and unsubscribe (INTERFACE §2.5, l.3837) [IMPL-DECISION G178]":
  setup:
    clearAll()

  teardown:
    leftover()

  test "[IFC-0174] [IFC-0175] [IFC-0180] null arguments and a malformed name are INVALID_PARAMS with the output untouched; an unknown event is NOT_AUTHORISED":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var id = LogosSubscriptionId(77)
    check toResult(rc.vtable.subscribe(rc, nil, onEvent, addr watches[0], addr id)).code ==
      ecInvalidParams
    check toResult(rc.vtable.subscribe(rc, ModuleState, nil, addr watches[0], addr id)).code ==
      ecInvalidParams
    check toResult(rc.vtable.subscribe(rc, ModuleState, onEvent, addr watches[0], nil)).code ==
      ecInvalidParams
    check rc.subscribe("", addr watches[0], id) == ecInvalidParams
    check id == 77
    for name in [
      "logos.runtime_control.nothing_changed_event", "meter.changed_event",
      "module_state_changed", "logos.runtime_control.module_state_changed",
    ]:
      check rc.subscribe(name, addr watches[0], id) == ecNotAuthorised
    check id == 77
    for i, name in [
      ModuleState, ExecutionState, RouteStateEv, Inventory, PermissionSettings,
      ConfigurationState,
    ]:
      check rc.subscribe(name, addr watches[i], id) == ecOk
    check id == 6
    e.finish()

  test "[IFC-0176] [IFC-0178] [IFC-0179] the id is written before the subscription is active; no handler runs on the subscribing thread":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var a, b: LogosSubscriptionId
    check rc.subscribe(ModuleState, addr watches[0], a) == ecOk
    check rc.subscribe(ModuleState, addr watches[1], b) == ecOk
    check a == 1 and b == 2
    discard e.started(meter(), "m")
    check watches[0].reached(2) and watches[1].reached(2)
    check watches[0].thread.load != getThreadId()
    check watches[0].transitions("m") == @["unloaded>loaded", "loaded>ready"]
    e.finish()

  test "[IMPL-DECISION G175] [IMPL-DECISION G178] a denied event decision is NOT_AUTHORISED; past the capacity is MODULE_ERROR; a subscriber leaving `ready` is NOT_READY":
    when declared(caParity):
      var cfg = rcConfig()
    else:
      var cfg = rcConfig(
        denying(
          deny(action = Opt.some(aaObserveEvent), operation = "route_state_changed")
        )
      )
    cfg.limits.rcSubsPerSubscriber = 2
    cfg.limits.rcSubsTotal = 3
    let e = fixtureEngine(cfg)
    when declared(caParity):
      setScript(rule(vDeny, "rcev:route_state_changed", code = 1))
    let (_, rc) = e.startClient("c")
    let (_, other) = e.startClient("d")
    var id = LogosSubscriptionId(5)
    check rc.subscribe(RouteStateEv, addr watches[0], id) == ecNotAuthorised
    check id == 5
    check rc.subscribe(ModuleState, addr watches[0], id) == ecOk
    check rc.subscribe(ExecutionState, addr watches[1], id) == ecOk
    var full = LogosSubscriptionId(9)
    check rc.subscribe(Inventory, addr watches[2], full) == ecModule
    check full == 9
    check other.subscribe(Inventory, addr watches[2], id) == ecOk
    check other.subscribe(ModuleState, addr watches[3], full) == ecModule
    # Capacity returns with an unsubscribe.
    check rc.unsubscribe(1) == ecOk
    check other.subscribe(ModuleState, addr watches[3], id) == ecOk
    clientDestroyGate.store(true)
    var t: Thread[(Engine, string)]
    check e.stopping("c", t)
    check rc.subscribe(Inventory, addr watches[4], full) == ecNotReady
    check rc.unsubscribe(2) == ecOk # ownership discharge while stopping
    clientDestroyGate.store(false)
    joinThread(t)
    e.finish()

  test "[IFC-0187] [IFC-0652] [IFC-0653] [IFC-0654] an external unsubscribe waits for the running handler; none begins after it; its undelivered entries are discarded; an unknown id is INVALID_PARAMS":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var id: LogosSubscriptionId
    check rc.subscribe(ExecutionState, addr watches[0], id) == ecOk
    check rc.unsubscribe(id + 7) == ecInvalidParams
    watches[0].hold.store(true)
    discard e.create(slow(), "s").tryGet
    check e.start("s").tryGet.state == msReady
    check waitUntil(
      proc(): bool =
        watches[0].held.load == 1
    )
    check e.stop("s").tryGet.state == msUnloaded # queued behind the held one
    unsubDone.store(false)
    createThread(unsubThread, unsubOn, (rc, id))
    sleep(100 * Slow)
    check not unsubDone.load # waiting for the running handler
    watches[0].hold.store(false)
    joinThread(unsubThread)
    check unsubCode.load == ord(ecOk)
    let n = watches[0].count.load
    check n == 1
    discard e.started(slow(), "s2")
    sleep(100 * Slow)
    check watches[0].count.load == n
    check rc.unsubscribe(id) == ecInvalidParams # unsubscribed already
    e.finish()

  test "[IFC-0186] a handler unsubscribing its own subscription returns without waiting for its own frame":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var id: LogosSubscriptionId
    check rc.subscribe(ModuleState, addr watches[0], id) == ecOk
    watches[0].rc = rc
    watches[0].selfId = id
    watches[0].unsubSelf = true
    discard e.started(slow(), "s")
    check watches[0].reached(1)
    check waitUntil(
      proc(): bool =
        watches[0].selfCode.load == ord(ecOk)
    )
    discard watches[0].quiet()
    check watches[0].count.load == 1
    e.finish()

  test "[IFC-0275] [IFC-0276] threads subscribing and unsubscribing on one binding while changes are fanned out":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    e.slows("s")
    type Arg =
      tuple[rc: ptr LogosRuntimeControlBinding, w: ptr Watch, fails: ptr Atomic[int]]

    var fails: Atomic[int]
    proc churn(a: Arg) {.thread.} =
      for i in 0 ..< 25:
        var id: LogosSubscriptionId
        let event = (if i mod 2 == 0: ExecutionState else: Inventory)
        if a.rc.subscribe(event, a.w, id) != ecOk:
          a.fails[] += 1
        elif a.rc.unsubscribe(id) != ecOk:
          a.fails[] += 1

    var threads: array[8, Thread[Arg]]
    for i in 0 ..< threads.len:
      createThread(threads[i], churn, (rc, addr watches[i], addr fails))
    for i in 0 ..< 5:
      check e.start("s").tryGet.state == msReady
      check e.stop("s").tryGet.state == msUnloaded
    for t in threads.mitems:
      joinThread(t)
    check fails.load == 0
    for w in watches.mitems:
      check w.overlaps.load == 0
    e.finish()

# Lifetime ------------------------------------------------------------------------------

suite "run.rc: subscriptions and their subscriber (INTERFACE l.1465, l.1999, l.2004) [IMPL-DECISION G178]":
  setup:
    clearAll()

  teardown:
    leftover()

  test "[IFC-0188] [IFC-0189] [IFC-0291] a stopping subscriber's subscriptions end before its own `stopping` is delivered; destroy waits for a running handler; unsubscribe inside `_MODULE_destroy` is LOGOS_OK; one never unsubscribed is freed":
    var cfg = rcConfig()
    # The stop waits for the held handler; past its deadline it would end in
    # `error` with `cleanup-timeout` (G180), as for a call still running.
    cfg.stopDeadline = initDuration(seconds = 10 * Slow)
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    let wrc = e.startWatcher("w")
    var seenByC, s1, s2: LogosSubscriptionId
    check rc.subscribe(ModuleState, addr watches[0], seenByC) == ecOk
    check wrc.subscribe(ModuleState, addr watches[3], s1) == ecOk
    check wrc.subscribe(ExecutionState, addr watches[2], s2) == ecOk
    watcherUnsub.store(int(s1))
    watches[3].hold.store(true)
    discard e.started(slow(), "s")
    check waitUntil(
      proc(): bool =
        watches[3].held.load == 1
    )
    var t: Thread[(Engine, string)]
    stopReply.store(-2)
    createThread(t, stopOn, (e, "w"))
    check waitUntil(
      proc(): bool =
        e.view("w").tryGet.state == msStopping
    )
    sleep(100 * Slow)
    check not watcherDestroyBegan.load # the running handler holds it back
    watches[3].hold.store(false)
    joinThread(t)
    check stopReply.load == ord(msUnloaded)
    check watcherDestroyBegan.load
    check watcherInsideAtDestroy.load == 0
    check watcherUnsubCode.load == ord(ecOk)
    # Nothing of its own stop reached it: `s`'s `loaded` arrived, held, and
    # nothing after; the other subscriber saw `w` stop.
    check watches[3].transitions("w").len == 0
    check watches[3].count.load == 1
    check watches[0].reached(4)
    check watches[0].transitions("w") == @["ready>stopping", "stopping>unloaded"]
    discard e.started(slow(), "s2")
    sleep(100 * Slow)
    check watches[3].count.load == 1
    e.finish()

  test "[IMPL-DECISION G178] a subscriber that fails in `_MODULE_init` after subscribing: the subscription ends with it, and its context waits for a running handler":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var id: LogosSubscriptionId
    check rc.subscribe(ExecutionState, addr watches[0], id) == ecOk
    watches[0].hold.store(true)
    discard e.started(slow(), "s")
    check waitUntil(
      proc(): bool =
        watches[0].held.load == 1
    )
    check e.reportFailure("c", e.view("c").tryGet.attempt, "gone").isOk
    check e.view("c").tryGet.state == msError
    sleep(100 * Slow)
    check e.cleanupPending("c") # the release waits for the handler
    watches[0].hold.store(false)
    check waitUntil(
      proc(): bool =
        not e.cleanupPending("c")
    )
    check watches[0].count.load == 1
    e.finish()

# Events -------------------------------------------------------------------------------

suite "run.rc: the events (RUNTIME §9.3 l.3496-3511, l.3715-3735)":
  setup:
    clearAll()

  teardown:
    leftover()

  test "[RUN-0991] [RUN-0464] [RUN-1052] [RUN-1056] [RUN-1057] [RUN-1060] start, stop and a reported failure give `module_state_changed` with the instance, never `provider`, and the new state's failure; creation gives none":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var id: LogosSubscriptionId
    check rc.subscribe(ModuleState, addr watches[0], id) == ecOk
    discard e.create(meter(), "m").tryGet
    check e.start("m").tryGet.state == msReady
    check e.stop("m").tryGet.state == msUnloaded
    discard e.started(slow(), "s")
    check e.reportFailure("s", e.view("s").tryGet.attempt, "it broke").isOk
    check watches[0].reached(7)
    check watches[0].transitions("m") ==
      @["unloaded>loaded", "loaded>ready", "ready>stopping", "stopping>unloaded"]
    check watches[0].transitions("s") ==
      @["unloaded>loaded", "loaded>ready", "ready>error"]
    for i in 0 ..< watches[0].count.load:
      let ev = watches[0].stateEv(i)
      check ev.provider.isNone
      check ev.module in ["meter_module", "slow_module"]
      if st(ev.new_state) == "error":
        check ev.failure == Opt.some("reported-by-module")
        check ev.reason == Opt.some("it broke")
      else:
        check ev.failure.isNone and ev.reason.isNone
    e.finish()

  test "[RUN-0630] [RUN-0463] `execution_state_changed` reports an intent change without a lifecycle transition, in revision order":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var a, b: LogosSubscriptionId
    check rc.subscribe(ExecutionState, addr watches[0], a) == ecOk
    check rc.subscribe(ModuleState, addr watches[1], b) == ecOk
    let made = e.create(meter(), "m").tryGet
    let stopped = e.stop("m").tryGet
    check stopped.state == msUnloaded
    check stopped.execution.intent == inStopped
    check watches[0].reached(1)
    discard watches[0].quiet()
    check watches[0].count.load == 1
    let ev = watches[0].execEv(0)
    check ev.instance == "m" and ev.module == "meter_module"
    check ev.execution.revision == stopped.execution.revision
    check ev.execution.revision > made.execution.revision
    check ev.execution.intent.kind ==
      LogosNSRuntimeControlExecutionStateIntentChoiceKind.Stopped
    check watches[1].count.load == 0
    e.finish()

  test "[RUN-0465] `route_state_changed` on close, provider failure and revocation, with the target's module and provider; none on establishment":
    when declared(caParity):
      let e = fixtureEngine(rcConfig())
    else:
      let e = fixtureEngine(
        rcConfig(denying(deny(action = Opt.some(aaRoute), operation = "renew_route")))
      )
    let (_, rc) = e.startClient("c")
    let m = e.started(meter(), "m")
    var id: LogosSubscriptionId
    check rc.subscribe(RouteStateEv, addr watches[0], id) == ecOk
    let r1 = rc.routeId("k1")
    let r2 = rc.routeId("k2")
    let r3 = rc.routeId("k3")
    sleep(100 * Slow)
    check watches[0].count.load == 0
    check rc.close(r1).code == ecOk
    check watches[0].reached(1)
    when declared(caParity):
      setScript(rule(vDeny, "renew-route", code = 1))
      check rc.renew("k9", r3).code == ecNotAuthorised
    else:
      check rc.renew("k9", r3).code == ecNotAuthorised
    check watches[0].reached(2)
    check e.stop("m").tryGet.state == msUnloaded
    check watches[0].reached(3)
    var seen: seq[(string, string, string)]
    for i in 0 ..< 3:
      let ev = watches[0].routeEv(i)
      check ev.module == Opt.some("meter_module")
      check ev.provider.get.provider == m.providerId
      check ev.reason.isNone
      check st2(ev.old_state) == "ready"
      seen.add((ev.route, st2(ev.new_state), ""))
    check seen.mapIt(it[0]) == @[r1, r3, r2]
    check seen.mapIt(it[1]) == @["closed", "revoked", "failed"]
    e.finish()

  test "[RUN-0363] [IFC-0181] [IFC-0182] [IFC-0183] 200 quick transitions of one instance arrive in commit order, one handler at a time per subscription; two subscriptions run at once":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    let (_, other) = e.startClient("d")
    var a, b, x: LogosSubscriptionId
    check rc.subscribe(ModuleState, addr watches[0], a) == ecOk
    check rc.subscribe(ExecutionState, addr watches[1], b) == ecOk
    e.slows("s")
    for i in 0 ..< 50:
      check e.start("s").tryGet.state == msReady
      check e.stop("s").tryGet.state == msUnloaded
    check watches[0].reached(200)
    let ts = watches[0].transitions("s")
    check ts.len == 200
    const cycle =
      ["unloaded>loaded", "loaded>ready", "ready>stopping", "stopping>unloaded"]
    for i in 0 ..< ts.len:
      check ts[i] == cycle[i mod 4]
    let n = watches[1].quiet()
    check n >= 200
    var last = 0'u64
    for i in 0 ..< min(n, LogCap):
      let ev = watches[1].execEv(i)
      check ev.execution.revision > last
      last = ev.execution.revision
    check watches[0].overlaps.load == 0 and watches[1].overlaps.load == 0
    # One subscription held does not hold another subscriber's back.
    check other.subscribe(ModuleState, addr watches[2], x) == ecOk
    watches[0].hold.store(true)
    check e.start("s").tryGet.state == msReady
    check waitUntil(
      proc(): bool =
        watches[0].held.load == 1
    )
    check watches[2].reached(2)
    check watches[0].held.load == 1
    watches[0].hold.store(false)
    e.finish()

  test "[IFC-0184] each payload is one deterministic CBOR value of its event's type":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var ids: array[4, LogosSubscriptionId]
    for i, name in [ModuleState, ExecutionState, RouteStateEv, Inventory]:
      check rc.subscribe(name, addr watches[i], ids[i]) == ecOk
    discard e.started(meter(), "m")
    check rc.close(rc.routeId("k")).code == ecOk
    check e.reportFailure("m", e.view("m").tryGet.attempt, "x").isOk
    for i in 0 ..< 4:
      check watches[i].reached(1)
      discard watches[i].quiet()
      for j in 0 ..< watches[i].count.load:
        let name = watches[i].nameAt(j)
        let bytes = watches[i].bytesAt(j)
        let v = rcSchema().decodeChecked(name, bytes)
        check v.isOk
        if v.isOk:
          check encodeCbor(v.get) == bytes
          check rcSchema().commitment(name, v.get).isOk
    e.finish()

  # Authority ------------------------------------------------------------------------------
  test "[RUN-0462] [CFG-0104] [CFG-0105] [CFG-0106] [CFG-0108] `configuration_state_changed` after each revision change, in revision order, with the summary and never a value":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var id: LogosSubscriptionId
    check rc.subscribe(ConfigurationState, addr watches[0], id) == ecOk
    let a = tunerAccepted(default = Opt.some(tunerValue()))
    var configured = meter()
    configured.configuration = Opt.some(a.digest)
    discard e.create(configured, "m", configuration = Opt.some(a)).tryGet
    discard e.create(meter(), "plain").tryGet
    let t = e.target("m")
    check rc.stage(t, 1, tunerValue("b")).updated.state_revision == 2
    check rc.discardStaged(t, 2).updated.state_revision == 3
    # A refused update changes nothing, and is not reported.
    check rc.stage(t, 1, tunerValue("c")).code == ecInvalidParams
    check watches[0].reached(3)
    check watches[0].quiet() == 3
    var evs: seq[LogosNSRuntimeControlConfigurationStateChangedEvent]
    for i in 0 ..< 3:
      check watches[0].nameAt(i) == ConfigurationState
      let raw = watches[0].bytesAt(i)
      check watches[0].lens[i] < EntryBytes
      var text = newString(raw.len)
      for j, b in raw:
        text[j] = char(b)
      check "radio-1" notin text and "station" notin text
      evs.add(LogosNSRuntimeControlConfigurationStateChangedEvent.decode(raw).tryGet)
    check evs.mapIt(it.state.state_revision) == @[1'u64, 2, 3]
    for ev in evs:
      check ev.target == t
      check ev.state.schema_commitment == Opt.some(tunerCommitment())
      check ev.state.current.isNone
    check evs[0].state.staged.get.provenance.kind ==
      LogosNSModuleConfigurationProvenanceKind.Package_default
    check evs[1].state.staged.get.provenance.kind ==
      LogosNSModuleConfigurationProvenanceKind.Runtime_control_update
    check evs[1].state.staged.get.schema_commitment == tunerCommitment()
    check evs[2].state.staged.isNone
    e.finish()

suite "run.rc: event authority (RUNTIME l.3498, l.3732-3735) [IMPL-DECISION G161] [IMPL-DECISION G226]":
  setup:
    clearAll()

  teardown:
    leftover()

  test "[RUN-0993] [RUN-0676] [RUN-0677] an event is delivered only when the subscriber may observe its exact subject":
    when declared(caParity):
      let e = fixtureEngine(rcConfig())
      setScript(
        narrowing("rcev:module_state_changed", RcNarrow(instances: only("a"))),
        narrowing(
          "rcev:execution_state_changed", RcNarrow(modules: only("meter_module"))
        ),
      )
    else:
      let e = fixtureEngine(
        rcConfig(
          denying(
            deny(action = Opt.some(aaObserveEvent), target = "b"),
            deny(
              action = Opt.some(aaObserveEvent),
              operation = "execution_state_changed",
              module = "slow_module",
            ),
          )
        )
      )
    let (_, rc) = e.startClient("c")
    var x, y: LogosSubscriptionId
    check rc.subscribe(ModuleState, addr watches[0], x) == ecOk
    check rc.subscribe(ExecutionState, addr watches[1], y) == ecOk
    discard e.started(slow(), "b")
    discard e.started(slow(), "a")
    discard e.started(meter(), "m")
    check watches[0].reached(2)
    check watches[1].reached(1)
    discard watches[0].quiet()
    discard watches[1].quiet()
    when declared(caParity):
      check watches[0].transitions("a") == @["unloaded>loaded", "loaded>ready"]
      check watches[0].transitions("b").len == 0
      check watches[0].transitions("m").len == 0
    else:
      check watches[0].transitions("a") == @["unloaded>loaded", "loaded>ready"]
      check watches[0].transitions("b").len == 0
      check watches[0].transitions("m") == @["unloaded>loaded", "loaded>ready"]
    for i in 0 ..< watches[1].count.load:
      check watches[1].execEv(i).module == "meter_module"
    e.finish()

  test "[RUN-0979] [RUN-0981] a hint needs the list method's authority for an affected record too":
    when declared(caParity):
      let e = fixtureEngine(rcConfig())
      setScript(narrowing("rc:list_modules", RcNarrow(instances: only("shown"))))
    else:
      let e = fixtureEngine(
        rcConfig(
          denying(
            deny(
              action = Opt.some(aaObserve),
              operation = "list_modules",
              target = "hidden",
            )
          )
        )
      )
    let (_, rc) = e.startClient("c")
    var id: LogosSubscriptionId
    check rc.subscribe(Inventory, addr watches[0], id) == ecOk
    discard e.create(slow(), "hidden").tryGet
    check e.start("hidden").tryGet.state == msReady
    check e.stop("hidden").tryGet.state == msUnloaded
    sleep(200 * Slow)
    check watches[0].count.load == 0
    discard e.create(slow(), "shown").tryGet
    check watches[0].reached(1)
    check watches[0].hintEv(0) == Modules
    e.finish()

when declared(caParity):
  suite "run.rc: a decision revoked mid-stream (RUNTIME l.3498; CA l.571) [IMPL-DECISION G161]":
    setup:
      clearAll()

    teardown:
      leftover()

    test "[RUN-0993] [CAP-0055] [IMPL-DECISION G161] queued entries are judged again at delivery once the policy changed; none is delivered while denied, and the subscription lives on":
      let e = fixtureEngine(rcConfig())
      let (_, rc) = e.startClient("c")
      var id: LogosSubscriptionId
      check rc.subscribe(ModuleState, addr watches[0], id) == ecOk
      watches[0].hold.store(true)
      e.slows("s")
      check e.start("s").tryGet.state == msReady
      check waitUntil(
        proc(): bool =
          watches[0].held.load == 1
      )
      check e.stop("s").tryGet.state == msUnloaded # admitted, queued behind the held one
      setScript(rule(vDeny, "rcev:module_state_changed", code = 1))
      changePolicy(1)
      watches[0].hold.store(false)
      discard watches[0].quiet()
      check watches[0].count.load == 1
      check e.start("s").tryGet.state == msReady # refused at fan-out
      sleep(100 * Slow)
      check watches[0].count.load == 1
      setScript()
      changePolicy(2)
      check e.stop("s").tryGet.state == msUnloaded
      check watches[0].reached(3)
      check watches[0].transitions("s") ==
        @["unloaded>loaded", "ready>stopping", "stopping>unloaded"]
      check not e.diagnostics().anyIt("G225" in it)
      e.finish()

# Inventory hints --------------------------------------------------------------------------

suite "run.rc: inventory_changed (RUNTIME l.3415-3428) [IMPL-DECISION G178]":
  setup:
    clearAll()

  teardown:
    leftover()

  test "[RUN-0977] [RUN-0884] creation, a state change and retirement give a `modules` hint; the payload is the collection only":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var id: LogosSubscriptionId
    check rc.subscribe(Inventory, addr watches[0], id) == ecOk
    discard e.create(slow(), "s").tryGet
    check watches[0].reached(1)
    check watches[0].bytesAt(0) ==
      encode(
        LogosNSRuntimeControlInventoryChangedEvent(
          collection: LogosNSRuntimeControlInventoryCollection(kind: Modules)
        )
      ).tryGet
    discard watches[0].quiet()
    let afterCreate = watches[0].count.load
    check e.start("s").tryGet.state == msReady
    check watches[0].reached(afterCreate + 1)
    check e.stop("s").tryGet.state == msUnloaded
    let before = watches[0].quiet()
    check rc.retireOf(e, "s").code == ecOk
    check watches[0].reached(before + 1)
    discard watches[0].quiet()
    check watches[0].hints(Routes) == 0
    check watches[0].hints(Modules) == watches[0].count.load
    e.finish()

  test "[RUN-0977] [RUN-0978] [RUN-0877] establishment, closure, a renewal that changes the record and a dropped record give a `routes` hint; a replayed renewal gives none":
    var cfg = rcConfig()
    cfg.endedRoutes = 0
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    discard e.started(meter(), "m")
    var id: LogosSubscriptionId
    check rc.subscribe(Inventory, addr watches[0], id) == ecOk
    let r = rc.routeId("k1")
    check watches[0].reached(1)
    check watches[0].hintEv(0) == Routes
    var n = watches[0].quiet()
    check rc.renew("k2", r).code == ecOk
    check watches[0].reached(n + 1)
    n = watches[0].quiet()
    check rc.renew("k2", r).code == ecOk # the same request_key: replayed
    # A marker in the other collection: everything committed before it was
    # delivered before it, in order.
    discard e.create(slow(), "marker").tryGet
    check watches[0].reached(n + 1)
    discard watches[0].quiet()
    check watches[0].hintEv(n) == Modules
    n = watches[0].count.load
    check rc.close(r).code == ecOk # closed, and dropped at once (`endedRoutes` 0)
    check watches[0].reached(n + 1)
    discard watches[0].quiet()
    check watches[0].hints(Routes) >= 3
    check e.routes().allIt(it.route != r)
    e.finish()

  test "[RUN-0979] [RUN-0982] many changes behind a held hint give one more hint":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var id: LogosSubscriptionId
    check rc.subscribe(Inventory, addr watches[0], id) == ecOk
    watches[0].hold.store(true)
    discard e.create(slow(), "s0").tryGet
    check waitUntil(
      proc(): bool =
        watches[0].held.load == 1
    )
    for i in 1 .. 20:
      discard e.create(slow(), "s" & $i).tryGet
    watches[0].hold.store(false)
    check watches[0].reached(2)
    check watches[0].quiet() == 2
    e.finish()

  test "[RUN-0980] a dropped route the subscriber may observe gives a hint, judged by the facts retained with it":
    var cfg = rcConfig()
    cfg.endedRoutes = 0
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    let (_, other) = e.startClient("d")
    discard e.started(meter(), "m")
    let r = other.routeId("k")
    var id: LogosSubscriptionId
    check rc.subscribe(Inventory, addr watches[0], id) == ecOk
    watches[0].hold.store(true)
    discard e.create(slow(), "s").tryGet
    check waitUntil(
      proc(): bool =
        watches[0].held.load == 1
    )
    check other.close(r).code == ecOk
    check e.routes().allIt(it.route != r) # gone before the hint is delivered
    watches[0].hold.store(false)
    check watches[0].reached(2)
    check watches[0].hintEv(1) == Routes
    e.finish()

# Delivery ------------------------------------------------------------------------------------

suite "run.rc: delivery (G178) [IMPL-DECISION G178]":
  setup:
    clearAll()

  teardown:
    leftover()

  test "[IMPL-DECISION G178] handlers run on an event worker, outside the operation that committed the change; a handler may call Runtime Control":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var id: LogosSubscriptionId
    check rc.subscribe(ModuleState, addr watches[0], id) == ecOk
    watches[0].hold.store(true)
    # The start returns while its own event's handler is held: it did not run
    # inside it, and the Runtime thread still answers.
    check e.started(meter(), "m").state == msReady
    check waitUntil(
      proc(): bool =
        watches[0].held.load == 1
    )
    check e.view("m").tryGet.state == msReady
    check watches[0].thread.load != getThreadId()
    watches[0].rc = rc
    watches[0].readiness = true
    for i, c in "m":
      watches[0].stopTarget[i] = c
    watches[0].stopTarget[1] = '\0'
    watches[0].hold.store(false)
    check waitUntil(
      proc(): bool =
        watches[0].stopCode.load >= 0
    )
    check watches[0].readinessCode.load == ord(ecOk)
    check watches[0].stopCode.load == ord(ecOk)
    check e.view("m").tryGet.state == msUnloaded
    check watches[0].reached(4)
    check watches[0].transitions("m") ==
      @["unloaded>loaded", "loaded>ready", "ready>stopping", "stopping>unloaded"]
    e.finish()

  test "[IMPL-DECISION G178] [IMPL-DECISION G225] a handler past the queue bound loses its subscription with a diagnostic; unsubscribing it is LOGOS_OK and a new one works":
    var cfg = rcConfig()
    cfg.limits.rcQueue = 4
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    var id: LogosSubscriptionId
    check rc.subscribe(ExecutionState, addr watches[0], id) == ecOk
    watches[0].hold.store(true)
    e.slows("s")
    for i in 0 ..< 4:
      check e.start("s").tryGet.state == msReady
      check e.stop("s").tryGet.state == msUnloaded
    check waitUntil(
      proc(): bool =
        e.diagnostics().anyIt(
          it ==
            "Runtime Control subscription " & $id &
            " of c lost: its handler fell behind (G225)"
        )
    )
    watches[0].hold.store(false)
    discard watches[0].quiet()
    check watches[0].count.load == 1 # the one held; the queue went
    check e.start("s").tryGet.state == msReady
    sleep(100 * Slow)
    check watches[0].count.load == 1
    check rc.unsubscribe(id) == ecOk
    check rc.unsubscribe(id) == ecInvalidParams
    var again: LogosSubscriptionId
    check rc.subscribe(ExecutionState, addr watches[1], again) == ecOk
    check again == id + 1
    check e.stop("s").tryGet.state == msUnloaded
    check watches[1].reached(1)
    e.finish()

  test "[IMPL] a stalled `inventory_changed` handler never loses its subscription":
    var cfg = rcConfig()
    cfg.limits.rcQueue = 2
    cfg.limits.rcHintFacts = 3
    let e = fixtureEngine(cfg)
    let (_, rc) = e.startClient("c")
    discard e.started(meter(), "m")
    var id: LogosSubscriptionId
    check rc.subscribe(Inventory, addr watches[0], id) == ecOk
    watches[0].hold.store(true)
    discard e.create(slow(), "s0").tryGet
    check waitUntil(
      proc(): bool =
        watches[0].held.load == 1
    )
    for i in 1 .. 30:
      discard e.create(slow(), "s" & $i).tryGet
    for i in 0 ..< 5:
      discard rc.routeId("k" & $i)
    watches[0].hold.store(false)
    check watches[0].reached(3)
    check watches[0].quiet() == 3
    check not e.diagnostics().anyIt("G225" in it)
    discard e.create(slow(), "later").tryGet
    check watches[0].reached(4)
    e.finish()

  test "[IMPL] shutdown waits for a running handler, and close for the event workers":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    var id: LogosSubscriptionId
    check rc.subscribe(ModuleState, addr watches[0], id) == ecOk
    watches[0].hold.store(true)
    discard e.started(slow(), "s")
    check waitUntil(
      proc(): bool =
        watches[0].held.load == 1
    )
    e.requestShutdown()
    sleep(100 * Slow)
    check e.tryClose().isErr # the subscriber's release waits for the handler
    check watches[0].count.load == 0
    watches[0].hold.store(false)
    discard e.awaitShutdown() # its result is the subscriber's cleanup, not checked here
    check watches[0].count.load == 1 # returned before shutdown completed
    check e.close()
    live = nil # closed here, not by `finish`

# Realization changes -----------------------------------------------------------------------

suite "run.rc: realization changes (G227)":
  setup:
    clearAll()

  teardown:
    leftover()

  test "[RUN-0630] [IMPL-DECISION G227] the late end of a cleanup gives `execution_state_changed` at a new revision and no state change":
    let e = fixtureEngine(rcConfig())
    let (_, rc) = e.startClient("c")
    discard e.started(client(), "w")
    var a, b: LogosSubscriptionId
    check rc.subscribe(ExecutionState, addr watches[0], a) == ecOk
    check rc.subscribe(ModuleState, addr watches[1], b) == ecOk
    clientDestroyGate.store(true)
    let stopped = e.stop("w").tryGet
    check stopped.state == msError
    check watches[1].reached(2)
    let states = watches[1].quiet()
    check watches[1].transitions("w") == @["ready>stopping", "stopping>error"]
    var errorRevision = 0'u64
    for i in 0 ..< watches[0].count.load:
      let ev = watches[0].execEv(i)
      if ev.instance == "w":
        errorRevision = ev.execution.revision
    clientDestroyGate.store(false)
    check waitUntil(
      proc(): bool =
        var later = false
        for i in 0 ..< watches[0].count.load:
          let ev = watches[0].execEv(i)
          if ev.instance == "w" and ev.execution.revision > errorRevision:
            later = true
        later,
      10 * Slow,
    )
    check watches[1].quiet() == states
    e.finish()
