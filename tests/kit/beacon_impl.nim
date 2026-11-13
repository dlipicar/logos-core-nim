## A native module written with the lcn-gen kit for `beacon_module`
## (`tests/kit/beacon_module.cddl`): a provider whose contract set declares one
## event and no method (INTERFACE §2.6).

{.used.} # imported by the tests for the C symbols it exports
import ../generated/beacon_module_kit

type Beacon* = ref object
  services*: ModuleServices

proc initModule(_: type Beacon, init: ModuleInit): Result[Beacon, InvocationFailure] =
  ok(Beacon(services: init.services))

exportBeaconModule(Beacon)
