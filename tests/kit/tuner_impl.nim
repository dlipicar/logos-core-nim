## A native module written with the lcn-gen kit for `tuner_module`
## (`tests/kit/tuner_module.cddl`), configured with `tests/kit/tuner_config.cddl`
## and live-reconfigurable (CONFIG §6, §8; DECISIONS I87): what a module author
## writes. `test_kit` links it and calls its exported C symbols; `test_config`
## binds it statically; on a host it is also built as a shared library.
##
## The configuration in force is kept as plain data under a lock, so no GC'd
## value from another thread is stored into the instance (`kitrt`, refc).
## Station `broken` refuses to start; station `refuse` refuses to be applied
## and leaves the value in force; station `hold` waits while `tunerGate` is
## set before it is applied.

{.used.} # imported by the tests for the C symbols it exports
import std/[atomics, locks, os]
import ../generated/tuner_module_kit

const StationBytes = 64 ## `tuner.station` has at most 64 bytes

type Tuner* = ref object
  services*: ModuleServices
  revision*: uint64 ## the revision `_MODULE_init` delivered
  applied*: Atomic[int] ## values `applyConfiguration` put in force
  lock: Lock
  stationBuf: array[StationBytes, char]
  stationLen: int
  volumeNow: uint32

var
  tunerDestroyed*: Atomic[int] ## instances `destroyModule` has seen
  tunerGate*: Atomic[bool] ## station `hold` waits while it is true
  tunerHeld*: Atomic[int] ## applications waiting at `tunerGate`
  tunerStarts*: Atomic[int] ## instances `initModule` created
  tunerLastRevision*: Atomic[uint64] ## the revision the latest one was given
  tunerLastVolume*: Atomic[uint32] ## and its volume

proc keep(t: Tuner, c: TunerConfig) =
  withLock t.lock:
    t.stationLen = min(c.station.len, StationBytes)
    for i in 0 ..< t.stationLen:
      t.stationBuf[i] = c.station[i]
    t.volumeNow = c.volume

proc station*(t: Tuner): string =
  ## The station in force.
  withLock t.lock:
    result = newString(t.stationLen)
    for i in 0 ..< t.stationLen:
      result[i] = t.stationBuf[i]

proc volume*(t: Tuner): uint32 =
  ## The volume in force.
  withLock t.lock:
    result = t.volumeNow

proc initModule(
    _: type Tuner, init: ModuleInit, config: TunerConfig
): Result[Tuner, InvocationFailure] =
  if config.station == "broken":
    return err(failure(ecModule, "the tuner is broken"))
  let t = Tuner(services: init.services, revision: init.configurationRevision.get(0))
  initLock(t.lock)
  t.keep(config)
  tunerLastRevision.store(t.revision)
  tunerLastVolume.store(config.volume)
  tunerStarts += 1
  ok(t)

proc destroyModule(t: Tuner) =
  deinitLock(t.lock)
  tunerDestroyed += 1

proc applyConfiguration(
    t: Tuner, config: TunerConfig
): Result[void, InvocationFailure] =
  ## [SPEC CONFIG §8 l.258-266] Success only once the new value governs; on
  ## failure the previous value stays in force.
  if config.station == "hold":
    tunerHeld += 1
    while tunerGate.load:
      sleep(1)
    tunerHeld -= 1
  if config.station == "refuse":
    return err(failure(ecModule, "the tuner refuses"))
  t.keep(config)
  t.applied += 1
  ok()

proc `now`(
    t: Tuner, request: RadioNowRequest
): Result[RadioNowResponse, InvocationFailure] =
  ok(
    RadioNowResponse(
      station: t.station,
      volume: t.volume,
      revision: t.revision,
      applied: uint64(t.applied.load),
    )
  )

exportTunerModule(Tuner)
