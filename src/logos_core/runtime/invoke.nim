## INTERFACE §2.9.3, §4, §5.2; RUNTIME §4.1, §6.4, §7.5, §9.3: the call paths a
## synchronous call and an asynchronous one share, and the invocation context.
##
## [IMPL] A direct route call (RUNTIME §4.1, §6.4, §7.5):
## 1. The Runtime thread admits it, in the order of G171's interim (TF-18):
##    the method resolves under the selected contract (METHOD_NOT_FOUND), it
##    is inside the route's method scope and the per-call decision allows it
##    (NOT_AUTHORISED, RUNTIME l.1732, G52; a route revoked for its authority
##    is NOT_AUTHORISED too), then the route is ready, its consumer live and
##    the provider ready (NOT_READY, after the request has been validated as
##    in step 2), and the call joins the provider's in-flight count.
## 2. The request is validated and its payload commitment computed: a failure
##    is INVALID_PARAMS before any provider code runs.
## 3. The provider runs with an invocation context current that names the
##    consumer (§2.9.3): `_MODULE_dispatch` on the calling thread for a
##    synchronous call or a call worker for an asynchronous one, or the
##    deferred surface's `submit` (`asynccall.nim`).
## 4. The result and outputs are checked together; a success is validated and
##    its commitment computed (MODULE_ERROR otherwise), copied into a buffer
##    the Runtime owns, and the provider's buffer is released at once with its
##    `_MODULE_free` (response copy), so a provider never waits on a
##    consumer's buffers to stop (RUNTIME l.1581-1583).
## 5. [G174] The result is committed only after the route's end cause is read
##    under the ticket's lock, the lock the Runtime thread takes to record it:
##    a route revoked while the provider ran turns the result into
##    NOT_AUTHORISED; a closed or failed route lets it complete.
## 6. The call leaves the in-flight count; a provider being stopped is
##    destroyed only once its count is zero.
##
## The well-known `logos.schema` method is answered by the boundary itself
## from the selected contract (TRANSPORT §8.1 does the same for a session); no
## provider code runs for it.

{.push raises: [], gcsafe.}

import std/[atomics, locks]
import results
import ../cbor
import ../abi/[checks, types]
import ../iface/[accept, outcome, payload, surface]
import ../transport/boundary
import ./[callside, events, plumbing]

const RcNamespace = "logos.runtime_control."

# The invocation context --------------------------------------------------------------

proc callerOp(
    invocation: ptr LogosInvocationContext, outCaller: ptr LogosCallerView
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.9.3; RUNTIME §4.1 l.869-873] The consumer of the route
  ## the invocation came through: a module caller.
  bindingEnter()
  if invocation == nil or outCaller == nil:
    return status(ecInvalidParams, "null caller output")
  let s = cast[ptr InvocationState](invocation.state)
  if not s.enterGuard():
    return status(ecModule, "the invocation was released")
  if s.system:
    outCaller[] = LogosCallerView(
      kind: CallerSystemService,
      runtimeInstanceId: s.runtimeId.utf8View,
      moduleInstanceId: LogosUtf8View(data: nil, len: 0),
    )
  else:
    outCaller[] = LogosCallerView(
      kind: CallerModule,
      runtimeInstanceId: s.runtimeId.utf8View,
      moduleInstanceId: s.consumer.utf8View,
    )
  s.leaveGuard()
  LogosResult()

proc isCancelledOp(invocation: ptr LogosInvocationContext): bool {.cdecl.} =
  ## [SPEC INTERFACE §2.9.3 l.2101-2102, l.2143] Sticky: set by the Runtime
  ## thread once the call's route or consumer has ended, or the asynchronous
  ## call was cancelled or timed out.
  bindingEnter()
  if invocation == nil:
    return false
  let s = cast[ptr InvocationState](invocation.state)
  if not s.enterGuard():
    return true
  result = s.ticket != nil and s.ticket.cancelled.load
  s.leaveGuard()

proc publishOp(
    invocation: ptr LogosInvocationContext,
    eventName: cstring,
    data: ptr UncheckedArray[uint8],
    dataLen: csize_t,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.9.3 l.2187-2199; RUNTIME §7.3.1]
  bindingEnter()
  if invocation == nil:
    return status(ecInvalidParams, "a null invocation context")
  let s = cast[ptr InvocationState](invocation.state)
  if not s.enterGuard():
    return status(ecNotReady, "the invocation was released")
  result = scopedPublish(s, eventName, data, dataLen)
  s.leaveGuard()

var contextVtable = LogosInvocationContextVtable(
  abiVersion: InvocationContextAbiVersion,
  structSize: csize_t(sizeof(LogosInvocationContextVtable)),
  caller: callerOp,
  isCancelled: isCancelledOp,
  publish: publishOp,
)

proc initContext*(s: var InvocationState) =
  ## `s` must stay where it is while its context is in use.
  s.context = LogosInvocationContext(vtable: addr contextVtable, state: addr s)

# Route calls ---------------------------------------------------------------------------

proc checkRequest*(
    sel: Selected, bare: string, params: openArray[byte], trail: var CallTrail
): Result[CborValue, InvocationFailure] =
  ## [SPEC RUNTIME §4.1 l.833-841, l.852-853] A request is validated and
  ## committed before provider code runs; `logos.schema` is the boundary's.
  ## [RUN-0332; I85] The commitment is kept in `trail`.
  let request =
    if sel.validator.surface.findMethod(bare).isSome:
      sel.validator.checkParams(bare, params).valueOr:
        return err(toFailure(error))
    else:
      decodePayload(params).valueOr:
        return err(toFailure(error))
  let c = sel.boundary.commitRequest(bare, request).valueOr:
    return err(error.failure)
  trail.request = Opt.some(c)
  ok(request)

proc checkRequest*(
    sel: Selected, bare: string, params: openArray[byte]
): Result[CborValue, InvocationFailure] =
  var trail: CallTrail
  checkRequest(sel, bare, params, trail)

proc record*(e: Engine, c: CallCapture, trail: CallTrail) =
  ## [SPEC CA l.1172-1174; I85] The call's record after its outcome, when the
  ## decision applied to it requires one (`callaudit.nim`).
  if not c.retains:
    return
  let kept = e.audit.keep(c, trail, uint64(max(e.clock.wallMs, 0'i64)))
  if kept.isErr:
    e.diagnose("a call record could not be kept: " & kept.error)

proc notReadyAfter*(
    b: ptr SchemaBlob, bare: string, params: openArray[byte], e: EngineError
): InvocationFailure =
  ## [G171 interim (TF-18)] A call the Runtime thread answered NOT_READY is
  ## authorized; its payload is validated before readiness is reported.
  if e.code == ecNotReady:
    let sel = selectedOf(b)
    if sel.isOk:
      let r = checkRequest(sel.get, bare, params)
      if r.isErr:
        return r.error
  failureOf(e)

proc introspect*(
    b: ptr SchemaBlob, bare: string, params: openArray[byte], trail: var CallTrail
): Result[seq[byte], InvocationFailure] =
  ## [SPEC INTERFACE §5.1; RUNTIME §9.3 l.2990-2992] `logos.schema`: the
  ## selected contract's `logos.schema_response`, from the boundary, whose
  ## commitments are under the common schema (CA l.1203-1204).
  let sel = selectedOf(b).valueOr:
    return err(failure(ecModule, "the selected contract cannot be loaded"))
  discard ?checkRequest(sel, bare, params, trail)
  let v = schemaResponse(sel.boundary.contracts, b.root).valueOr:
    return err(failure(ecModule, "the schema response cannot be built"))
  let c = sel.boundary.commitResponse(bare, v).valueOr:
    return err(failure(ecModule, "the schema response cannot be committed"))
  trail.response = Opt.some(c)
  ok(encodeCbor(v))

proc invocationFor*(
    adm: Admission,
    consumer, route: FixedText,
    generation: uint64,
    blob: ptr SchemaBlob,
    engine: Engine,
): InvocationState =
  ## The state of an admitted call's invocation context; `initContext` once it
  ## is where it stays.
  InvocationState(
    engine: engine,
    access: adm.access,
    ticket: adm.ticket,
    runtimeId: fixed(adm.runtimeId),
    consumer: consumer,
    provider: fixed(adm.provider),
    route: route,
    generation: generation,
    blob: blob,
  )

proc checkResponse*(
    sel: Selected, bare: string, bytes: openArray[byte], trail: var CallTrail
): Result[void, InvocationFailure] =
  ## [SPEC RUNTIME §4.1 l.838-840] A response that does not validate or commit
  ## is not returned as a success. [RUN-0332; I85] Its commitment is kept in
  ## `trail`.
  let response = sel.validator.checkResult(bare, bytes).valueOr:
    return err(failure(ecModule, "the provider's response does not match its schema"))
  let c = sel.boundary.commitResponse(bare, response).valueOr:
    return err(failure(ecModule, "the provider's response cannot be committed"))
  trail.response = Opt.some(c)
  ok()

func sameAddress(v: CborValue, runtimeId, instance: string): bool =
  if v.kind != ckMap:
    return false
  let r = v.lookup("runtime_instance_id")
  let m = v.lookup("module_instance_id")
  r.isSome and r.get.kind == ckText and r.get.text == runtimeId and m.isSome and
    m.get.kind == ckText and m.get.text == instance

proc authorityRefusal*(
    adm: Admission, engine: Engine, consumer, route, bare: string, request: CborValue
): Result[void, InvocationFailure] =
  ## [SPEC CA l.88-91, §5.1 l.579; RUNTIME l.1716-1718; S8b-1 interim (TF-31)]
  ## After the call's own decision and before dispatch: a request to a
  ## Capability Authority method must name the authenticated caller as its
  ## `consumer`, which is validated, never replaced, and an `evaluate` from
  ## a module never carries `execution_renewal`. Either failure is
  ## NOT_AUTHORISED without dispatch, and is retained as a refusal of its own
  ## kind. A request that does not read is left to the schema check.
  if not adm.authority:
    return ok()
  var reason = ""
  let c = request.lookup("consumer")
  if c.isSome and not sameAddress(c.get, adm.runtimeId, consumer):
    reason = "the request names another consumer"
  elif bare == "evaluate" and request.lookup("execution_renewal").isSome:
    reason = "execution_renewal is set by the Runtime only"
  if reason.len == 0:
    return ok()
  discard engine.call(
    Request(
      kind: rqRefusal,
      origin: moduleOrigin(consumer),
      route: route,
      bare: bare,
      reason: reason,
    )
  )
  err(failure(ecNotAuthorised, "not authorised"))

proc callProvider*(
    adm: Admission,
    engine: Engine,
    consumer, route: FixedText,
    generation: uint64,
    blob: ptr SchemaBlob,
    bare: string,
    params: openArray[byte],
    trail: var CallTrail,
): Result[seq[byte], InvocationFailure] =
  ## Steps 2-4 for an admitted call through `_MODULE_dispatch`, on this
  ## thread; the caller commits the result, records the call and leaves the
  ## in-flight count.
  let sel = selectedOf(blob).valueOr:
    return err(failure(ecModule, "the selected contract cannot be loaded"))
  let request = ?checkRequest(sel, bare, params, trail)
  ?authorityRefusal(adm, engine, $consumer, $route, bare, request)
  var inv = invocationFor(adm, consumer, route, generation, blob, engine)
  initContext(inv)
  var buf: ptr UncheckedArray[uint8] = nil
  var len: csize_t = 0
  var f = Frame(context: addr inv.context, access: adm.access)
  push(f)
  let r = adm.dispatch(
    adm.context,
    cstring(bare),
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr buf,
    addr len,
  )
  pop(f)
  checkOutcome(r, bufferShape(buf, len)).isOkOr:
    if transfersBuffer(r, buf):
      adm.free(adm.context, buf)
    return err(failureOf(error))
  var bytes: seq[byte]
  if len <= csize_t(high(int)):
    bytes = view(buf, len)
  adm.free(adm.context, buf)
  if bytes.len == 0:
    return err(failure(ecModule, "the provider's response is too long"))
  ?checkResponse(sel, bare, bytes, trail)
  ok(bytes)

proc systemCall*(
    engine: Engine,
    dispatch: ModuleDispatchFn,
    free: ModuleFreeFn,
    context: ptr LogosModuleContext,
    access: pointer,
    ticket: ptr CallTicket,
    runtimeId: string,
    bare: string,
    params: openArray[byte],
): Result[seq[byte], InvocationFailure] =
  ## [SPEC RUNTIME l.1652-1667; CA l.88; plan §2.4] One call of a system
  ## service's method by the Runtime itself, on this thread, through the
  ## provider's generic dispatch, with a SYSTEM_SERVICE invocation context
  ## current (step 8b: the Capability Authority's `evaluate`). The caller
  ## checks the response.
  var inv = InvocationState(
    engine: engine,
    access: access,
    ticket: ticket,
    runtimeId: fixed(runtimeId),
    system: true,
  )
  initContext(inv)
  var buf: ptr UncheckedArray[uint8] = nil
  var len: csize_t = 0
  var f = Frame(context: addr inv.context, access: access)
  push(f)
  let r = dispatch(
    context,
    cstring(bare),
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr buf,
    addr len,
  )
  pop(f)
  checkOutcome(r, bufferShape(buf, len)).isOkOr:
    if transfersBuffer(r, buf):
      free(context, buf)
    return err(failureOf(error))
  var bytes: seq[byte]
  if len <= csize_t(high(int)):
    bytes = view(buf, len)
  free(context, buf)
  if bytes.len == 0:
    return err(failure(ecModule, "the response is empty or too long"))
  ok(bytes)

proc revokedResult*(): InvocationFailure =
  ## [G174] X1 interim: a route revoked while the call ran ends it with the
  ## handle's retained termination code.
  failure(ecNotAuthorised, "the route was revoked")

proc commitSync*(
    t: ptr CallTicket, r: sink Result[seq[byte], InvocationFailure]
): Result[seq[byte], InvocationFailure] =
  ## [G174] Step 5: the commit decision, ordered with the route's revocation.
  withLock t.lock:
    if t.endCode == ord(ecNotAuthorised):
      return err(revokedResult())
  r

proc leave*(e: Engine, adm: Admission) =
  ## Step 6: the call has left the provider.
  e.post(
    Msg(kind: mkCallDone, provider: adm.provider, route: adm.route, ticket: adm.ticket)
  )

proc routeCall*(
    h: ptr HandleState, bare: string, params: seq[byte]
): Result[seq[byte], InvocationFailure] =
  ## [SPEC INTERFACE §5.2; RUNTIME §4.1, §6.4, §7.5] A synchronous route call,
  ## on the calling thread.
  let reply = h.engine.call(
    Request(
      kind: rqAdmit,
      origin: moduleOrigin($h.consumer),
      attempt: $h.attempt,
      route: $h.route,
      bare: bare,
    )
  )
  if reply.error.isSome:
    return err(notReadyAfter(h.blob, bare, params, reply.error.get))
  let adm = reply.admission
  var trail: CallTrail
  if adm.introspection:
    result = introspect(h.blob, bare, params, trail)
    trail.succeeded = result.isOk
    h.engine.record(adm.capture, trail)
    return
  result = commitSync(
    adm.ticket,
    callProvider(
      adm, h.engine, h.consumer, h.route, h.generation, h.blob, bare, params, trail
    ),
  )
  trail.succeeded = result.isOk
  h.engine.record(adm.capture, trail)
  leave(h.engine, adm)

# Runtime Control requests ----------------------------------------------------------------

proc rcRequest(
    bare: string, params: openArray[byte], trail: var CallTrail
): Result[RcCall, InvocationFailure] =
  ## [SPEC INTERFACE §4.3, §4.5, §5.2] The checked request of a Runtime Control
  ## method: METHOD_NOT_FOUND for a name the contract does not declare,
  ## INVALID_PARAMS with its detail for bytes that are not a value of the
  ## method's request schema. A method this Runtime does not perform yet is
  ## MODULE_ERROR [IMPL].
  let declaration = RcNamespace & bare & "_request"
  if bare.len == 0 or not rcSchema().declares(declaration) or
      not rcSchema().declares(RcNamespace & bare & "_response"):
    return err(InvocationFailure(code: ecMethodNotFound))
  let v = decodePayload(params).valueOr:
    return err(toFailure(error))
  rcSchema().checkPath(declaration, v).isOkOr:
    return err(
      InvocationFailure(
        code: ecInvalidParams,
        detail: Opt.some(invalidParamsDetail(iprSchemaMismatch, Opt.some(error))),
      )
    )
  # [SPEC RUNTIME l.225-230] The binding keeps the commitment semantics.
  let (subtree, root) = rcSchema().commitment(declaration, v).valueOr:
      return err(
        InvocationFailure(
          code: ecModule, message: Opt.some("the request commitment cannot be computed")
        )
      )
  trail.request = Opt.some(PayloadCommitment(subtreeRoot: subtree, valueRoot: root))
  let request = @params
  template call(which: RcMethod): RcCall =
    RcCall(m: which, request: request)

  case bare
  of $rmGetSelf:
    ok(call(rmGetSelf))
  of $rmShutdownRuntime:
    ok(call(rmShutdownRuntime))
  of $rmGetExecutionPermissions:
    ok(call(rmGetExecutionPermissions))
  of $rmEstablishRoute:
    var c = call(rmEstablishRoute)
    c.establish = fromChecked(LogosNSRuntimeControlEstablishRouteRequest, v)
    ok(c)
  of $rmRenewRoute:
    var c = call(rmRenewRoute)
    c.renew = fromChecked(LogosNSRuntimeControlRenewRouteRequest, v)
    ok(c)
  of $rmCloseRoute:
    var c = call(rmCloseRoute)
    c.close = fromChecked(LogosNSRuntimeControlCloseRouteRequest, v)
    ok(c)
  of $rmStartModule:
    var c = call(rmStartModule)
    c.start = fromChecked(LogosNSRuntimeControlStartModuleRequest, v)
    ok(c)
  of $rmStopModule:
    var c = call(rmStopModule)
    c.stop = fromChecked(LogosNSRuntimeControlStopModuleRequest, v)
    ok(c)
  of $rmReportFailure:
    var c = call(rmReportFailure)
    c.report = fromChecked(LogosNSRuntimeControlReportFailureRequest, v)
    ok(c)
  of $rmGetReadiness:
    var c = call(rmGetReadiness)
    c.readiness = fromChecked(LogosNSRuntimeControlGetReadinessRequest, v)
    ok(c)
  of $rmRecoverModule:
    var c = call(rmRecoverModule)
    c.recover = fromChecked(LogosNSRuntimeControlRecoverModuleRequest, v)
    ok(c)
  of $rmRetireModule:
    var c = call(rmRetireModule)
    c.retire = fromChecked(LogosNSRuntimeControlRetireModuleRequest, v)
    ok(c)
  of $rmCreateModule:
    var c = call(rmCreateModule)
    c.createModule = fromChecked(LogosNSRuntimeControlCreateModuleRequest, v)
    ok(c)
  of $rmDescribeProvider:
    var c = call(rmDescribeProvider)
    c.describe = fromChecked(LogosNSRuntimeControlDescribeProviderRequest, v)
    ok(c)
  of $rmListModules:
    var c = call(rmListModules)
    c.listModules = fromChecked(LogosNSRuntimeControlListModulesRequest, v)
    ok(c)
  of $rmListRoutes:
    var c = call(rmListRoutes)
    c.listRoutes = fromChecked(LogosNSRuntimeControlListRoutesRequest, v)
    ok(c)
  of $rmGetExecutionSummary:
    var c = call(rmGetExecutionSummary)
    c.summary = fromChecked(LogosNSRuntimeControlGetExecutionSummaryRequest, v)
    ok(c)
  of $rmGetPermissionSettings:
    var c = call(rmGetPermissionSettings)
    c.getSettings = fromChecked(LogosNSRuntimeControlGetPermissionSettingsRequest, v)
    ok(c)
  of $rmUpdatePermissionSettings:
    var c = call(rmUpdatePermissionSettings)
    c.updateSettings =
      fromChecked(LogosNSRuntimeControlUpdatePermissionSettingsRequest, v)
    ok(c)
  else:
    err(
      InvocationFailure(
        code: ecModule,
        message: Opt.some(bare & " is not supported by this Runtime yet"),
      )
    )

proc lifecycleResponse(m: RcMethod, v: InstanceView): Result[seq[byte], string] =
  ## [SPEC RUNTIME §9.3 l.3496-3497] A local instance: its exact `instance`,
  ## no `provider`.
  let state = LogosNSRuntimeControlState(
    kind:
      case v.state
      of msUnloaded: LogosNSRuntimeControlStateKind.Unloaded
      of msLoaded: LogosNSRuntimeControlStateKind.Loaded
      of msReady: LogosNSRuntimeControlStateKind.Ready
      of msStopping: LogosNSRuntimeControlStateKind.Stopping
      of msError: LogosNSRuntimeControlStateKind.Error
  )
  if m == rmStartModule:
    encode(
      LogosNSRuntimeControlStartModuleResponse(
        module: v.module, instance: Opt.some(v.instance), state: state
      )
    )
  elif m == rmRecoverModule:
    encode(
      LogosNSRuntimeControlRecoverModuleResponse(
        module: v.module, instance: v.instance, state: state
      )
    )
  else:
    encode(
      LogosNSRuntimeControlStopModuleResponse(
        module: v.module, instance: Opt.some(v.instance), state: state
      )
    )

proc checkedResponse(
    bare: string, bytes: seq[byte], trail: var CallTrail
): Result[seq[byte], string] =
  ## [SPEC RUNTIME l.229, l.3747] A successful Runtime Control response is a
  ## value of the method's response schema, and its commitment is computed
  ## and kept (RUN-0332).
  let declaration = RcNamespace & bare & "_response"
  let v = ?rcSchema().decodeChecked(declaration, bytes)
  let (subtree, root) = ?rcSchema().commitment(declaration, v)
  trail.response = Opt.some(PayloadCommitment(subtreeRoot: subtree, valueRoot: root))
  ok(bytes)

proc rcInvoke*(
    e: Engine, instance, attempt, bare: string, params: seq[byte]
): Result[seq[byte], InvocationFailure] =
  ## [SPEC INTERFACE §5.2; RUNTIME §9, §9.3] One Runtime Control method through
  ## the binding of `attempt`, synchronous or on a call worker. [CA l.1172-
  ## 1174; I85] A call whose applied decision requires retention is recorded
  ## after its outcome, here.
  var trail: CallTrail
  let rc = rcRequest(bare, params, trail).valueOr:
    if error.code == ecInvalidParams:
      # [G171 interim (TF-18)] What is authorized without the payload comes
      # before its validation.
      let pre = e.call(
        Request(
          kind: rqRcPrecheck,
          origin: moduleOrigin(instance),
          attempt: attempt,
          bare: bare,
        )
      )
      e.record(pre.capture, trail)
      if pre.error.isSome:
        return err(failureOf(pre.error.get))
    return err(error)
  let m = rc.m
  let reply = e.call(
    Request(kind: rqRc, origin: moduleOrigin(instance), attempt: attempt, rc: rc)
  )
  if reply.error.isSome:
    e.record(reply.capture, trail)
    return err(failureOf(reply.error.get))
  let encoded =
    if m in {rmStartModule, rmStopModule, rmRecoverModule}:
      lifecycleResponse(m, reply.view)
    else:
      Result[seq[byte], string].ok(reply.bytes)
  let response = block:
    let body = encoded.valueOr:
      e.record(reply.capture, trail)
      return err(failure(ecModule, "the response does not match its schema"))
    checkedResponse($m, body, trail).valueOr:
      e.record(reply.capture, trail)
      return err(failure(ecModule, "the response does not match its schema"))
  trail.succeeded = true
  e.record(reply.capture, trail)
  ok(response)
