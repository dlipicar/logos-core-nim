## The §3.9.2 sensor written against its confined kit with `_MODULE_async_api`
## (`lcn-gen kit --confined --async-api`; DECISIONS G338;
## `sdk/tests/generated/confined/`), which `test_kit_dylib` builds as a library
## to compare a provider's three surfaces (INTERFACE l.2072-2077).
## `configure`, of the primary contract, is plain: it keeps the limit and
## refuses a limit of 13. `snapshot`, of the implemented interface, is `async`:
## it counts the configurations once it has awaited.

{.used.}
import ../generated/confined/sensor_module_kit

type SensorC = ref object
  limit: uint64
  configured: uint64 ## module thread only: no atomics

proc initModule(_: type SensorC, init: ModuleInit): Result[SensorC, InvocationFailure] =
  ok(SensorC())

proc configure(
    s: SensorC, request: SensorNSControlConfigureRequest
): Result[SensorNSControlConfigureResponse, InvocationFailure] =
  if request.settings.limit == 13:
    return err(failure(ecModule, "limit 13 is refused"))
  s.limit = request.settings.limit
  inc s.configured
  ok(SensorNSControlConfigureResponse())

proc snapshot(
    s: SensorC, request: MetricsProviderSnapshotRequest, inv: Invocation
): Future[Result[MetricsProviderSnapshotResponse, InvocationFailure]] {.
    async: (raises: [])
.} =
  try:
    await sleepAsync(1.milliseconds)
  except CancelledError:
    discard
  Result[MetricsProviderSnapshotResponse, InvocationFailure].ok(
    MetricsProviderSnapshotResponse(count: s.configured)
  )

exportSensorModule(SensorC)
