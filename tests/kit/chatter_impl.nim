## A native module for `beacon_module` (`tests/kit/beacon_module.cddl`) that
## writes one line to its stderr at `_MODULE_init`, for `test_logosd` (Tier 4b
## step 4b-6; G146): hosted, the line shows a Module Host's stderr reaching
## logosd's log unfiltered; realized in logosd's process instead, it would
## show there too, so a case that expects no realization expects no line.

{.used.} # imported by the tests for the C symbols it exports
import ../generated/beacon_module_kit

when defined(posix):
  import std/posix

const ChatterLine* = "chatter: beacon_module initialized in process "

type Chatter* = ref object

proc initModule(_: type Chatter, init: ModuleInit): Result[Chatter, InvocationFailure] =
  when defined(posix):
    let line = ChatterLine & $getpid() & "\n"
    discard write(2, cstring(line), line.len)
  ok(Chatter())

exportBeaconModule(Chatter)
