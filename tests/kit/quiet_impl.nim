## A native module written with the lcn-gen kit for `quiet_module`
## (`tests/kit/quiet_module.cddl`): no method, configured with
## `tests/kit/tuner_config.cddl` at startup only (CONFIG §6; DECISIONS I87).

{.used.} # imported by the tests for the C symbols it exports
import std/atomics
import ../generated/quiet_module_kit

type Quiet* = ref object
  revision*: uint64 ## the revision `_MODULE_init` delivered
  volume*: uint32 ## the volume it was configured with

var quietInits*: Atomic[int] ## calls of `initModule`

proc initModule(
    _: type Quiet, init: ModuleInit, config: TunerConfig
): Result[Quiet, InvocationFailure] =
  quietInits += 1
  ok(Quiet(revision: init.configurationRevision.get(0), volume: config.volume))

exportQuietModule(Quiet)
