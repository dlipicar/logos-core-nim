## A native module written with the lcn-gen kit for `idle_module` (DECISIONS
## G339): lifecycle declarations and no contract (INTERFACE l.2573, l.2839),
## so no provider: the kit exports `_MODULE_name`, `_MODULE_init` and
## `_MODULE_destroy` alone.

{.used.} # imported by the tests for the C symbols it exports
import std/atomics
import ../generated/idle_module_kit

type Idle* = ref object

var idleInits*, idleDestroys*: Atomic[int]

proc initModule(_: type Idle, init: ModuleInit): Result[Idle, InvocationFailure] =
  idleInits += 1
  ok(Idle())

proc destroyModule(m: Idle) =
  idleDestroys += 1

exportIdleModule(Idle)
