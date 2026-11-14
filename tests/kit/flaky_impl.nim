## A native module written with the lcn-gen kit for `flaky_module`
## (`tests/kit/flaky_module.cddl`): no method, whose initialization and
## cleanup the orchestration tests steer per instance (DECISIONS I94).
##
## Instances `flaky-0` to `flaky-15` map to fixed slots of atomics, so nothing
## the garbage collector owns is shared between the test thread and the
## Runtime's lifecycle workers. Each instance learns its id from `get_self`
## during `_MODULE_init` (RUNTIME l.2555-2556). Per slot:
##
## - `failInits`: the next n initializations fail (`initialization-failed`);
## - `initGate`: `_MODULE_init` waits while it is set;
## - `destroyGate`: `_MODULE_destroy` waits while it is set (a cleanup that
##   overruns its deadline, G180);
## - `inits` and the monotonic time of each, for spacing;
## - `reportFlakyFailure(slot)`: `report_failure` through the live instance's
##   binding, from the test thread.

{.used.} # imported by the tests for the C symbols it exports
import std/[atomics, monotimes, os, strutils]
import ../generated/flaky_module_kit
import ../../src/logos_core/kit/rcclient

const
  FlakySlots* = 16
  FlakyTimes* = 64

type FlakySlot* = object
  failInits*: Atomic[int]
  initGate*: Atomic[bool]
  destroyGate*: Atomic[bool]
  inits*: Atomic[int]
  initNs*: array[FlakyTimes, Atomic[int64]]
  heldInit*: Atomic[int] ## inits waiting at `initGate` now
  heldDestroy*: Atomic[int] ## destroys waiting at `destroyGate` now
  destroys*: Atomic[int]
  rc: Atomic[pointer] ## the live instance's binding

var flaky*: array[FlakySlots, FlakySlot]

type Flaky* = ref object
  slot: int

proc flakyInstance*(slot: int): string =
  "flaky-" & $slot

proc slotOf(instance: string): int =
  if not instance.startsWith("flaky-"):
    return -1
  try:
    let n = parseInt(instance[6 .. ^1])
    if n >= 0 and n < FlakySlots: n else: -1
  except ValueError:
    -1

proc resetFlaky*() =
  ## Every slot back to its initial values; call in each test's setup.
  for i in 0 ..< FlakySlots:
    flaky[i].failInits.store(0)
    flaky[i].initGate.store(false)
    flaky[i].destroyGate.store(false)
    flaky[i].inits.store(0)
    flaky[i].heldInit.store(0)
    flaky[i].heldDestroy.store(0)
    flaky[i].destroys.store(0)
    for k in 0 ..< FlakyTimes:
      flaky[i].initNs[k].store(0)

proc initTimesNs*(slot: int): seq[int64] =
  ## The monotonic time of each initialization of `slot`, in order.
  let n = min(flaky[slot].inits.load, FlakyTimes)
  for k in 0 ..< n:
    result.add(flaky[slot].initNs[k].load)

proc initModule(_: type Flaky, init: ModuleInit): Result[Flaky, InvocationFailure] =
  let me = call(
    init.services.runtimeControl,
    "get_self",
    LogosNSRuntimeControlGetSelfRequest(),
    LogosNSRuntimeControlGetSelfResponse,
  ).valueOr:
    return err(failure(ecModule, "flaky: get_self: " & $error))
  let i = slotOf(me.consumer.module_instance_id)
  if i < 0:
    return err(failure(ecModule, "flaky: not a flaky-<n> instance"))
  let k = flaky[i].inits.fetchAdd(1)
  if k < FlakyTimes:
    flaky[i].initNs[k].store(getMonoTime().ticks)
  if flaky[i].initGate.load:
    flaky[i].heldInit += 1
    while flaky[i].initGate.load:
      sleep(2)
    flaky[i].heldInit -= 1
  if flaky[i].failInits.load > 0:
    flaky[i].failInits -= 1
    return err(failure(ecModule, "flaky: this initialization fails"))
  flaky[i].rc.store(cast[pointer](init.services.runtimeControl))
  ok(Flaky(slot: i))

proc destroyModule(f: Flaky) =
  flaky[f.slot].rc.store(nil)
  if flaky[f.slot].destroyGate.load:
    flaky[f.slot].heldDestroy += 1
    while flaky[f.slot].destroyGate.load:
      sleep(2)
    flaky[f.slot].heldDestroy -= 1
  flaky[f.slot].destroys += 1

exportFlakyModule(Flaky)

proc reportFlakyFailure*(slot: int): ErrorCode =
  ## `report_failure` through the live instance of `slot`, from the caller's
  ## thread; MODULE_ERROR when none is live.
  let rc = cast[ptr LogosRuntimeControlBinding](flaky[slot].rc.load)
  if rc == nil:
    return ecModule
  let r = call(
    rc,
    "report_failure",
    LogosNSRuntimeControlReportFailureRequest(reason: Opt.some("flaky: reported")),
    LogosNSRuntimeControlReportFailureResponse,
  )
  if r.isOk: ecOk else: r.error.code

proc flakyBinding*(slot: int): ptr LogosRuntimeControlBinding =
  ## The live instance's Runtime Control binding, for a test that calls as
  ## that instance; nil when none is live.
  cast[ptr LogosRuntimeControlBinding](flaky[slot].rc.load)
