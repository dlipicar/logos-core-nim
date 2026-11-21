## A native module written with the lcn-gen kit for `metrics_only_module`
## (DECISIONS G339): the §3.9.2 `metrics_provider` interface implemented with
## no primary document (INTERFACE l.2833-2835). `snapshot` counts its calls.

{.used.} # imported by the tests for the C symbols it exports
import std/atomics
import ../generated/metrics_only_module_kit

type MetricsOnly* = ref object
  snapshots*: Atomic[uint64]

proc initModule(
    _: type MetricsOnly, init: ModuleInit
): Result[MetricsOnly, InvocationFailure] =
  ok(MetricsOnly())

proc snapshot(
    m: MetricsOnly, request: MetricsProviderSnapshotRequest
): Result[MetricsProviderSnapshotResponse, InvocationFailure] =
  m.snapshots += 1
  ok(MetricsProviderSnapshotResponse(count: m.snapshots.load))

exportMetricsOnlyModule(MetricsOnly)
