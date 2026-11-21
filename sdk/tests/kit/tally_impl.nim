## A native module written with the lcn-gen kit for `tally_module` (DECISIONS
## G339): a primary document that declares only a type and implements the
## §3.9.2 `metrics_provider` interface (INTERFACE l.2839). `snapshot` answers
## the number of steps taken, `step` at a time.

{.used.} # imported by the tests for the C symbols it exports
import std/atomics
import ../generated/tally_module_kit

type Tally* = ref object
  step*: TallyStep
  count*: Atomic[uint64]

proc initModule(_: type Tally, init: ModuleInit): Result[Tally, InvocationFailure] =
  ok(Tally(step: 3))

proc snapshot(
    t: Tally, request: MetricsProviderSnapshotRequest
): Result[MetricsProviderSnapshotResponse, InvocationFailure] =
  let n = t.count.fetchAdd(t.step) + t.step
  ok(MetricsProviderSnapshotResponse(count: n))

exportTallyModule(Tally)
