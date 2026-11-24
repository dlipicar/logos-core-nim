## A call to a hosted provider, on the Runtime's call worker (Tier 4b step
## 4b-3, part 4b-3.2; plan §2.7 [Rev R14, R16]; DECISIONS G273, G274) [IMPL].
##
## The payloads stay in the Module Host (the owner's direct layout,
## 2026-11-14). The Runtime decides and records; the host checks, runs and
## commits:
##
## 1. The host's loop resolved the Request under the session's contract and
##    access and reported it without its params (`io_dispatch`).
## 2. The Runtime admits it as it admits a direct route call (`rqAdmit`: the
##    method scope, the call decision, the retention capture, IFC-0581's
##    marked-payload refusal, readiness) and sends the verdict
##    (`admit_verdict`).
## 3. A refused call is answered by the host, which first checks the params
##    of a NOT_READY one (RUNTIME l.1828, l.1832). An admitted one is checked, run and answered
##    there: the provider's result checked as on the direct path (INTERFACE
##    l.3306-3311), its
##    response checked against the schema, its Response committed by the
##    host's loop (K38 interim, G273).
## 4. While it runs, the call worker answers the host's scoped publication
##    steps (`scoped_check`, `scoped_admit`, `scoped_done`) as a direct
##    invocation's `publish` decides them, and forwards cancellation
##    (`call_cancel`, behind the lane-2 orders) once the ticket is cancelled.
## 5. The host reports the end (`call_ended`): whether its loop committed a
##    success, and the commitments the capture asked for, which go into the
##    call record (K44 interim, G274: the provider host's verified roots).
##
## A host that ends first fails the call (MODULE_ERROR) and its record says
## so (CA l.1193); its sessions are closed by the Runtime thread
## (`hostEnded`).

{.push raises: [], gcsafe.}

import std/atomics
from std/os import sleep
import results
import logos_sdk/abi/[checks, types]
import logos_sdk/hash/hashinput
import logos_sdk/iface/outcome
import ./[callside, events, hostsup, invoke, plumbing]
from ./tport import hostedContext

const MaxStepMs = 10 ## [IMPL] the longest wait between looks at the call's state

proc hostOf*(e: Engine, conn: uint64): Host =
  ## The live Module Host serving hosted connection `conn`, retained; nil
  ## once it has ended.
  let ctx = e.tport.hostedContext
  if ctx == nil:
    return nil
  findHost(cast[HostSupervisor](ctx), conn)

proc refuseHosted*(
    h: Host, conn, requestId: uint64, root: Digest, f: InvocationFailure
) =
  ## Step 3: the host answers a refused call.
  discard h.sendMsg(
    toMessage(
      LcnCarrierAdmitVerdict(
        conn: hostConnOf(conn),
        request: requestId,
        contract: @root,
        failure: Opt.some(toCarrier(f)),
      )
    )
  )

proc carrierFailure(f: Result[void, InvocationFailure]): Opt[LcnCarrierFailure] =
  if f.isErr:
    return Opt.some(toCarrier(f.error))
  Opt.none(LcnCarrierFailure)

proc runHosted*(
    h: Host,
    adm: Admission,
    engine: Engine,
    consumer, route: FixedText,
    generation: uint64,
    blob: ptr SchemaBlob,
    conn, requestId: uint64,
    trail: var CallTrail,
    system = false,
): Result[void, InvocationFailure] =
  ## Steps 2-5 for an admitted call: ok once the host's loop committed a
  ## success; the commitments the capture asks for are put in `trail`.
  ## [G492] `system`: a call on a system-service session. The verdict names
  ## no consumer, so the provider's caller view is LOGOS_CALLER_SYSTEM_SERVICE
  ## (RUNTIME l.835), and no invocation-scoped event is in the binding's
  ## scope (C4; TRN-0344, TRN-0345).
  let call = h.nextRequest()
  let d = h.beginDispatch(call)
  if d == nil:
    return err(failure(ecModule, "the Module Host has ended"))
  defer:
    endDispatch(d)
  var verdict = LcnCarrierAdmitVerdict(
    conn: hostConnOf(conn),
    request: requestId,
    contract: @(blob.root),
    call: Opt.some(call),
    consumer: (if system: Opt.none(string) else: Opt.some($consumer)),
    system: (if system: Opt.some(true) else: Opt.none(bool)),
    retain_request: adm.capture.retainRequest,
    retain_response: adm.capture.retainResponse,
  )
  if h.sendMsg(toMessage(verdict)).isErr:
    return err(failure(ecModule, "the Module Host has ended"))
  var inv =
    invocationFor(adm, consumer, route, generation, blob, engine, conn, requestId)
  type K = LcnCarrierMessageKind
  var cancelSent = false
  var step = 0
  while true:
    let f = d.nextFrame()
    if f.isNone:
      if not cancelSent and adm.ticket != nil and adm.ticket.cancelled.load:
        # [IMPL; I91] Queued behind the Runtime's lane-2 orders: whatever it
        # answered before it marked the call cancelled reaches the host's
        # loop first (`engine.endRoute`, `asyncTerminal`).
        cancelSent = true
        h.notify(toMessage(LcnCarrierCallCancel(call: call)))
      sleep(step)
      step = min(step + 1, MaxStepMs)
      continue
    step = 0
    if f.get.len == 0:
      return err(failure(ecModule, "the Module Host ended during the call"))
    let m = decodeMessage(f.get).valueOr:
      return err(failure(ecModule, "the Module Host's answer does not decode"))
    case m.kind
    of K.lcn_Carrier_scoped_check:
      # [SPEC INTERFACE l.2187-2199] The module's bytes, checked as given.
      let p = m.arm_lcn_Carrier_scoped_check
      var r = LcnCarrierScopedResult(id: p.id)
      let name = checkEventName(p.event)
      if system:
        r.failure = Opt.some(
          toCarrier(
            failure(
              ecNotAuthorised, "no event is in the system-service binding's scope"
            )
          )
        )
      elif name.isErr:
        r.failure = Opt.some(toCarrier(name.error))
      else:
        let ready = scopedCheck(addr inv, name.get)
        if ready.isErr:
          r.failure = Opt.some(toCarrier(ready.error))
        else:
          r.ready = Opt.some(ready.get)
      discard h.sendMsg(toMessage(r))
    of K.lcn_Carrier_scoped_admit:
      let p = m.arm_lcn_Carrier_scoped_admit
      var r = LcnCarrierScopedResult(id: p.id)
      # [SPEC INTERFACE §1.5; I106] The host's name, checked as given.
      let name = checkEventName(p.event)
      if system:
        r.failure = Opt.some(
          toCarrier(
            failure(
              ecNotAuthorised, "no event is in the system-service binding's scope"
            )
          )
        )
      elif name.isErr:
        r.failure = Opt.some(toCarrier(name.error))
      else:
        let tag = scopedAdmit(addr inv, name.get)
        if tag.isErr:
          r.failure = Opt.some(toCarrier(tag.error))
        else:
          r.tag = tag.get
      discard h.sendMsg(toMessage(r))
    of K.lcn_Carrier_scoped_done:
      let p = m.arm_lcn_Carrier_scoped_done
      discard h.sendMsg(
        toMessage(
          LcnCarrierScopedResult(
            id: p.id, failure: carrierFailure(scopedVerdict(addr inv, p.tag, p.abandon))
          )
        )
      )
    of K.lcn_Carrier_call_ended:
      let r = m.arm_lcn_Carrier_call_ended
      # [SPEC CA l.1176-1177; IFC-0581] Only what the capture asked for.
      if r.request.isSome and adm.capture.retainRequest:
        let c = commitmentOf(r.request.get).valueOr:
          return err(failure(ecModule, "the Module Host's answer does not decode"))
        trail.request = Opt.some(c)
      if r.response.isSome and adm.capture.retainResponse:
        let c = commitmentOf(r.response.get).valueOr:
          return err(failure(ecModule, "the Module Host's answer does not decode"))
        trail.response = Opt.some(c)
      if r.succeeded:
        return ok()
      return err(failure(ecModule, "the provider's call did not succeed"))
    else:
      return err(failure(ecModule, "the Module Host answered with " & $m.kind))
