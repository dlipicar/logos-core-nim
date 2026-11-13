## Step 8b (DECISIONS I85): the evaluation lane of the Capability Authority
## binding (RUNTIME §9 l.1652-1667; CA §5; plan §2.3, §2.4).
##
## Module code never runs on the Runtime thread (I75), and the Capability
## Authority is module code: the Runtime thread parks the operation that
## needs a decision and an evaluation worker calls `evaluate`. The worker runs
## the bound instance's generic dispatch with a SYSTEM_SERVICE invocation
## context (`invoke.systemCall`; CA l.88, INTERFACE l.2183), then reads and
## checks the decision against its request off the Runtime thread
## (`authscopes.readDecision`) and posts the verdict (`mkEvaluated`). A
## dispatch failure, a non-OK status, an `error` arm or a malformed decision
## is an evaluation failure, never a deny (RUN-0329, CAP-0098).
##
## [IMPL] The ordinary lane has `EvalWorkers` threads, spawned on demand and
## joined at `close`, apart from the lifecycle and call workers: a CA
## `watch_changes` holds a call worker for as long as it runs, so evaluation
## never waits on that pool (CAP-0382). The renewal lane has one thread of
## its own and carries execution renewals only, so ordinary saturation never
## delays them (CA §5.1 l.584-595; CAP-0304, CAP-0311, CAP-0321).

{.push raises: [], gcsafe.}

import results
import ../base/perthread
import ../iface/outcome
import ../authority/logos_capability_authority_types
import ./[authscopes, callside, invoke, plumbing]

proc evaluateOn(s: ptr Shared, job: EvalJob): EvalResult =
  let request = EvaluateRequest.decode(job.request).valueOr:
    return EvalResult(verdict: evFailed, reason: "the request does not decode")
  let bytes = systemCall(
    s, job.dispatch, job.free, job.context, job.access, job.ticket, job.runtimeId,
    "evaluate", job.request,
  ).valueOr:
    return EvalResult(verdict: evFailed, reason: "evaluate failed with " & $error.code)
  readDecision(request, bytes, job.runtimeId)

proc evalWorkerLoop(s: ptr Shared, lane: ptr Channel[EvalJob]) =
  while true:
    var job: EvalJob
    try:
      job = lane[].recv()
    except Exception:
      return
    case job.kind
    of ejQuit:
      return
    of ejRun:
      let res = evaluateOn(s, job)
      s.post(Msg(kind: mkEvaluated, job: job.id, evaluated: res))

proc evalWorkerMain*(s: ptr Shared) {.thread.} =
  markRuntimeThread()
  evalWorkerLoop(s, addr s.evals)
  releasePerThread()

proc renewWorkerMain*(s: ptr Shared) {.thread.} =
  markRuntimeThread()
  evalWorkerLoop(s, addr s.renewals)
  releasePerThread()
