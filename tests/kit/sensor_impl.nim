## A native module written with the lcn-gen kit for `sensor_module` (INTERFACE
## §3.9.2): a primary method in a dotted namespace and an implemented
## interface's method, with empty request and response maps. `configure` sets
## the limit; `snapshot` counts configurations.

{.used.} # imported by the tests for the C symbols it exports
import std/atomics
import ../generated/sensor_module_kit

type Sensor* = ref object
  limit*: Atomic[uint64]
  configured*: Atomic[uint64]

proc initModule(_: type Sensor, init: ModuleInit): Result[Sensor, InvocationFailure] =
  ok(Sensor())

proc configure(
    s: Sensor, request: SensorNSControlConfigureRequest
): Result[SensorNSControlConfigureResponse, InvocationFailure] =
  s.limit.store(request.settings.limit)
  s.configured += 1
  ok(SensorNSControlConfigureResponse())

proc snapshot(
    s: Sensor, request: MetricsProviderSnapshotRequest
): Result[MetricsProviderSnapshotResponse, InvocationFailure] =
  ok(MetricsProviderSnapshotResponse(count: s.configured.load))

exportSensorModule(Sensor)
