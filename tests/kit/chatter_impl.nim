## A native module for `beacon_module` (`sdk/src/logos_sdk/testing/fixtures/beacon_module.cddl`) that
## writes one line to its stderr at `_MODULE_init`, for `test_logosd` (Tier 4b
## step 4b-6; G146): hosted, the line shows a Module Host's stderr reaching
## logosd's log unfiltered; realized in logosd's process instead, it would
## show there too, so a case that expects no realization expects no line.
##
## With `LCN_CHATTER_INIT_DELAY_MS` in its environment (a case lists it in
## `module_host_env`), `_MODULE_init` then waits that long before it returns,
## so a case can act while the realization is still in flight.

{.used.} # imported by the tests for the C symbols it exports
import std/[os, strutils]
import logos_sdk/testing/generated/beacon_module_kit

when defined(posix):
  import std/posix

const
  ChatterLine* = "chatter: beacon_module initialized in process "
  ChatterDelayVar* = "LCN_CHATTER_INIT_DELAY_MS"

type Chatter* = ref object

proc initModule(_: type Chatter, init: ModuleInit): Result[Chatter, InvocationFailure] =
  when defined(posix):
    let line = ChatterLine & $getpid() & "\n"
    discard write(2, cstring(line), line.len)
  let delay = getEnv(ChatterDelayVar)
  if delay.len > 0:
    try:
      sleep(parseInt(delay))
    except ValueError:
      discard
  ok(Chatter())

exportBeaconModule(Chatter)
