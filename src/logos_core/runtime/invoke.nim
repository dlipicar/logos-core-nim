## INTERFACE §2.9.3, §4, §5.2; RUNTIME §4.1, §6.4, §7.5, §9.3: the call paths a
## synchronous call and an asynchronous one share, and the invocation context.
##
## [IMPL] A direct route call (RUNTIME §4.1, §6.4, §7.5):
## 1. The Runtime thread admits it, in the order of RUNTIME l.1824-1833:
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
## 5. The result is committed only after the route's end cause is read under
##    the ticket's lock, the lock the Runtime thread takes to record it
##    (RUNTIME l.1212): a route revoked or expired while the provider ran ends
##    the call TRANSPORT_ERROR and drops the result (l.1271); a closed or
##    failed route lets it complete, unless the result is the CANCELLED the
##    end's own cancellation caused, which is TRANSPORT_ERROR too.
## 6. The call leaves the in-flight count; a provider being stopped is
##    destroyed only once its count is zero.
##
## The well-known `logos.schema` method is answered by the boundary itself
## from the selected contract (TRANSPORT §8.1 does the same for a session); no
## provider code runs for it.

{.push raises: [], gcsafe.}

import std/[atomics, locks]
import results
import logos_sdk/cbor
import logos_sdk/abi/[checks, types]
import logos_sdk/iface/[accept, outcome, payload, surface]
import logos_sdk/kit/rc_arms
import ../transport/boundary
import ./[callside, events, forwarded, plumbing, rcaddress]
from ./remoterecords import NoRemoteTransport

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

proc record*(e: Engine, c: CallCapture, trail: var CallTrail) =
  ## [SPEC CA l.1172-1174; I85] The call's record after its outcome, when the
  ## decision applied to it requires one (`callaudit.nim`). The trail's value
  ## roots are zeroed afterwards [DECISIONS G276].
  if c.retains:
    let kept = e.audit.keep(c, trail, uint64(max(e.clock.wallMs, 0'i64)))
    if kept.isErr:
      # [SPEC RUNTIME l.1770; I95 amended 2026-11-16] a failed requirement:
      # logosd logs it as a warning
      e.diagnose("a call record could not be kept: " & kept.error, warn = true)
  wipe(trail)

proc notReadyAfter*(
    b: ptr SchemaBlob, bare: string, params: openArray[byte], e: EngineError
): InvocationFailure =
  ## [SPEC RUNTIME l.1828, l.1832] A call the Runtime thread answered
  ## NOT_READY is authorized; its payload is validated (step 3) before
  ## readiness (step 7) is reported.
  if e.code != ecNotReady:
    return failureOf(e)
  notReadyAfter(selectedOf(b), bare, params, failureOf(e))

proc introspect*(
    b: ptr SchemaBlob,
    bare: string,
    params: openArray[byte],
    schema: openArray[byte],
    trail: var CallTrail,
): Result[seq[byte], InvocationFailure] =
  ## [SPEC INTERFACE §5.1; RUNTIME §9.3 l.2990-2992] `logos.schema`, from the
  ## provider's validated surface at admission (`callcheck.introspect`).
  let sel = selectedOf(b).valueOr:
    return err(failure(ecModule, "the selected contract cannot be loaded"))
  introspect(sel, bare, params, schema, trail)

proc invocationFor*(
    adm: Admission,
    consumer, route: FixedText,
    generation: uint64,
    blob: ptr SchemaBlob,
    engine: Engine,
    conn = 0'u64,
    requestId = 0'u64,
): InvocationState =
  ## The state of an admitted call's invocation context; `initContext` once it
  ## is where it stays. `conn` and `requestId`: a served invocation's session.
  InvocationState(
    conn: conn,
    requestId: requestId,
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
    conn = 0'u64,
    requestId = 0'u64,
): Result[seq[byte], InvocationFailure] =
  ## Steps 2-4 for an admitted call through `_MODULE_dispatch`, on this
  ## thread; the caller commits the result, records the call and leaves the
  ## in-flight count. `conn`, `requestId`: a served invocation's session.
  let sel = selectedOf(blob).valueOr:
    return err(failure(ecModule, "the selected contract cannot be loaded"))
  let marked = sel.marked(bare)
  let request = ?checkRequest(sel, bare, params, trail)
  let refused = authorityRefusal(adm, engine, $consumer, $route, bare, request)
  if marked.request:
    wipe(request) # [DECISIONS G276] the tree serves the authority check only
  ?refused
  var inv =
    invocationFor(adm, consumer, route, generation, blob, engine, conn, requestId)
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
  # [SPEC INTERFACE l.3306-3311] a provider's own status
  var outcome =
    checkOutcome(r, bufferShape(buf, len)).providerChecked(ticketCancelled(adm.ticket))
  if outcome.isErr:
    if transfersBuffer(r, buf):
      adm.free(adm.context, buf)
    return err(takeFailure(outcome))
  var bytes: seq[byte]
  if len <= csize_t(high(int)):
    bytes = view(buf, len)
  adm.free(adm.context, buf)
  if bytes.len == 0:
    return err(failure(ecModule, "the provider's response is too long"))
  checkResponse(sel, bare, bytes, trail).isOkOr:
    wipe(bytes) # [DECISIONS G276] a response that is not returned
    return err(error)
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
  # [SPEC INTERFACE l.3306-3311; re-pin P4 R4b] The Capability Authority is
  # provider code behind the ABI too: a status outside the set is
  # MODULE_ERROR, a failed evaluation (G172).
  checkOutcome(r, bufferShape(buf, len)).providerChecked(ticketCancelled(ticket)).isOkOr:
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
  ## [SPEC RUNTIME l.1261; TRANSPORT l.971] A call its route's revocation or
  ## expiry found not yet admitted is a new operation: NOT_AUTHORISED.
  failure(ecNotAuthorised, "the route was revoked")

proc routeEndedResult*(): InvocationFailure =
  ## [SPEC RUNTIME l.1271-1272] An admitted call that its route's end ended
  ## before a valid final result was accepted; the code does not say whether
  ## the provider ran it.
  failure(ecTransport, "the route ended before the call's result was accepted")

func endedByRoute*(endCode: int, r: Result[seq[byte], InvocationFailure]): bool =
  ## [SPEC RUNTIME l.1271, l.1212; INTERFACE l.2024] Read under the ticket's
  ## lock: whether the route's end decides an admitted call instead of `r`. A
  ## revoked or expired route commits no result of a call it ends. After any
  ## other end a CANCELLED result is the end's doing (P5 reading d4): the end
  ## marked the invocation cancelled, and a cancellation by the caller, a
  ## timeout or the session decides the call before its provider returns.
  endCode == ord(ecNotAuthorised) or
    (endCode != ord(ecOk) and r.isErr and r.error.code == ecCancelled)

proc commitSync*(
    t: ptr CallTicket, r: var Result[seq[byte], InvocationFailure]
): Result[seq[byte], InvocationFailure] =
  ## Step 5: the commit decision, ordered with the route's end (RUNTIME l.1212,
  ## l.1271). A response the end keeps from its caller is zeroed, and so is a
  ## provider's failure text, which may quote a marked request
  ## [DECISIONS G276].
  withLock t.lock:
    if endedByRoute(t.endCode, r):
      wipe(r)
      return err(routeEndedResult())
  move r

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
    result = introspect(h.blob, bare, params, adm.schema, trail)
    trail.succeeded = result.isOk
    h.engine.record(adm.capture, trail)
    return
  var r = callProvider(
    adm, h.engine, h.consumer, h.route, h.generation, h.blob, bare, params, trail
  )
  result = commitSync(adm.ticket, r)
  trail.succeeded = result.isOk
  h.engine.record(adm.capture, trail)
  leave(h.engine, adm)

# Runtime Control requests ----------------------------------------------------------------

proc rcDeclares(bare: string): bool =
  ## [SPEC INTERFACE §4.3] Whether the Runtime Control contract declares the
  ## method `bare` (its request and its response).
  bare.len > 0 and rcSchema().declares(RcNamespace & bare & "_request") and
    rcSchema().declares(RcNamespace & bare & "_response")

proc rcRequest(
    bare: string,
    params: openArray[byte],
    depth: int,
    trail: var CallTrail,
    value: var seq[byte],
): Result[RcCall, InvocationFailure] =
  ## [SPEC INTERFACE §4.3, §4.5, §5.2] The checked request of a Runtime Control
  ## method: METHOD_NOT_FOUND for a name the contract does not declare,
  ## INVALID_PARAMS with its detail for bytes that are not a value of the
  ## method's request schema (a configuration value over 8 MiB included,
  ## CFG-0025). [K19 interim; G298] The four remote listener and export
  ## methods are decoded like the others and answered after their
  ## authorization (`engine.remoteList`, `engine.setExport`). [SPEC RUNTIME
  ## l.2704-2705; M8] A listener address whose `profile` does not name the one
  ## its `transport` selects, or a `quic` one whose `alpn` is not
  ## `logos.remote.quic`, is INVALID_PARAMS without validation detail. It is
  ## answered as a payload that fails validation: what is authorized without
  ## the payload comes first (`rcInvoke`, step 2 of l.1824-1833), a target the
  ## payload names after it [reading, Fable synthesis §14.3]. A method this
  ## Runtime does not perform yet is MODULE_ERROR [IMPL]. A staged
  ## configuration value is taken out into `value`: it stays on this thread
  ## (I87).
  let declaration = RcNamespace & bare & "_request"
  if not rcDeclares(bare):
    return err(InvocationFailure(code: ecMethodNotFound))
  # [IF-02, I88] Counted from the request's root, under the engine's setting.
  let v = decodePayload(params, maxDepth = depth).valueOr:
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
  # Kept for `request_key` replay; an update, which has none, may be 8 MiB.
  let request = (if bare == $rmUpdateConfiguration: newSeq[byte]()
  else: @params)
  template call(which: RcMethod): RcCall =
    RcCall(m: which, request: request)

  template mismatched(): Result[RcCall, InvocationFailure] =
    err(
      InvocationFailure(
        code: ecInvalidParams,
        message:
          Opt.some("the address does not match the profile its transport selects"),
      )
    )

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
  of $rmGetConfigurationSchema:
    var c = call(rmGetConfigurationSchema)
    c.cfgTarget =
      fromChecked(LogosNSRuntimeControlGetConfigurationSchemaRequest, v).target
    ok(c)
  of $rmGetConfigurationSummary:
    var c = call(rmGetConfigurationSummary)
    c.cfgTarget =
      fromChecked(LogosNSRuntimeControlGetConfigurationSummaryRequest, v).target
    ok(c)
  of $rmGetConfiguration:
    var c = call(rmGetConfiguration)
    c.cfgTarget = fromChecked(LogosNSRuntimeControlGetConfigurationRequest, v).target
    ok(c)
  of $rmUpdateConfiguration:
    var r = fromChecked(LogosNSRuntimeControlUpdateConfigurationRequest, v)
    var c = call(rmUpdateConfiguration)
    case r.kind
    of LogosNSRuntimeControlUpdateConfigurationRequestKind.Stage:
      let a = addr r.arm_Stage
      c.cfgUpdate = ConfigUpdate(
        target: a.target,
        expectedRevision: a.expected_state_revision,
        expectedCommitment: a.expected_schema_commitment,
        stage: true,
      )
      value = move a.value
    of LogosNSRuntimeControlUpdateConfigurationRequestKind.Discard:
      let a = r.arm_Discard
      c.cfgUpdate = ConfigUpdate(
        target: a.target,
        expectedRevision: a.expected_state_revision,
        expectedCommitment: a.expected_schema_commitment,
      )
    ok(c)
  of $rmApplyConfiguration:
    var c = call(rmApplyConfiguration)
    c.cfgApply = fromChecked(LogosNSRuntimeControlApplyConfigurationRequest, v)
    ok(c)
  of $rmListRemoteListeners:
    var c = call(rmListRemoteListeners)
    c.listListeners = fromChecked(LogosNSRuntimeControlListRemoteListenersRequest, v)
    ok(c)
  of $rmSetRemoteListener:
    var c = call(rmSetRemoteListener)
    c.setListener = fromChecked(LogosNSRuntimeControlSetRemoteListenerRequest, v)
    if c.setListener.listener.address.mismatching:
      return mismatched()
    ok(c)
  of $rmListProviderExports:
    var c = call(rmListProviderExports)
    c.listExports = fromChecked(LogosNSRuntimeControlListProviderExportsRequest, v)
    if c.listExports.listener.isSome and c.listExports.listener.get.mismatching:
      return mismatched()
    ok(c)
  of $rmSetProviderExport:
    var c = call(rmSetProviderExport)
    c.setExport = fromChecked(LogosNSRuntimeControlSetProviderExportRequest, v)
    if c.setExport.export.listener.mismatching:
      return mismatched()
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
      LogosNSRuntimeControlStartModuleResponse.accepted(
        LogosNSRuntimeControlStartModuleResponseARMapModuleStateMap(
          module: v.module, instance: Opt.some(v.instance), state: state
        )
      )
    )
  elif m == rmRecoverModule:
    encode(
      LogosNSRuntimeControlRecoverModuleResponse.accepted(
        LogosNSRuntimeControlRecoverModuleResponseARMapInstanceModuleStateMap(
          module: v.module, instance: v.instance, state: state
        )
      )
    )
  else:
    encode(
      LogosNSRuntimeControlStopModuleResponse.accepted(
        LogosNSRuntimeControlStopModuleResponseARMapModuleStateMap(
          module: v.module, instance: Opt.some(v.instance), state: state
        )
      )
    )

proc typedResponse(m: RcMethod, t: TypedError): Result[seq[byte], string] =
  ## [SPEC RUNTIME l.1818-1822] A typed outcome as the method's error arm.
  let e = rcError(
    case t.code
    of recStaleRevision:
      LogosNSRuntimeControlErrorCodeKind.Stale_revision
    of recConfigurationRejected:
      LogosNSRuntimeControlErrorCodeKind.Configuration_rejected
    of recDeclarationUnavailable:
      LogosNSRuntimeControlErrorCodeKind.Declaration_unavailable,
    t.currentRevision,
  )
  case m
  of rmCreateModule:
    encode(LogosNSRuntimeControlCreateModuleResponse.refused(e))
  of rmStartModule:
    encode(LogosNSRuntimeControlStartModuleResponse.refused(e))
  of rmStopModule:
    encode(LogosNSRuntimeControlStopModuleResponse.refused(e))
  of rmRecoverModule:
    encode(LogosNSRuntimeControlRecoverModuleResponse.refused(e))
  of rmRetireModule:
    encode(LogosNSRuntimeControlRetireModuleResponse.refused(e))
  of rmUpdatePermissionSettings:
    encode(LogosNSRuntimeControlUpdatePermissionSettingsResponse.refused(e))
  of rmUpdateConfiguration:
    encode(LogosNSRuntimeControlUpdateConfigurationResponse.refused(e))
  of rmApplyConfiguration:
    encode(LogosNSRuntimeControlApplyConfigurationResponse.refused(e))
  else:
    err($m & " has no error arm")

proc configResponse(
    m: RcMethod, target: LogosNSRuntimeModuleInstanceAddress, s: ConfigState
): Result[seq[byte], string] =
  ## [SPEC CONFIG §5; I87] A configuration response, encoded here from the
  ## state the Runtime thread retained, so no value is copied there.
  case m
  of rmGetConfigurationSchema:
    encode(
      LogosNSRuntimeControlGetConfigurationSchemaResponse(
        target: target, state_revision: s.revision, schema: bindingOf(s.binding)
      )
    )
  of rmGetConfiguration:
    encode(
      LogosNSRuntimeControlGetConfigurationResponse(target: target, state: stateOf(s))
    )
  else:
    # [SPEC CONFIG l.208] the complete staged record, if any
    var r = LogosNSRuntimeControlUpdateConfigurationResponseARMapStateRevisionTargetMap(
      target: target, state_revision: s.revision
    )
    if s.staged.isSome:
      r.staged = Opt.some(toRc(s.staged.get))
    encode(LogosNSRuntimeControlUpdateConfigurationResponse.accepted(r))

proc checkedResponse(
    bare: string, bytes: seq[byte], depth: int, trail: var CallTrail
): Result[seq[byte], string] =
  ## [SPEC RUNTIME l.229, l.3747] A successful Runtime Control response is a
  ## value of the method's response schema, and its commitment is computed
  ## and kept (RUN-0332).
  let declaration = RcNamespace & bare & "_response"
  let v = decodePayload(bytes, ecModule, depth).valueOr:
    return err(error.msg)
  ?rcSchema().check(declaration, v)
  let (subtree, root) = ?rcSchema().commitment(declaration, v)
  trail.response = Opt.some(PayloadCommitment(subtreeRoot: subtree, valueRoot: root))
  ok(bytes)

proc stage(
    e: Engine,
    instance, attempt: string,
    update: ConfigUpdate,
    phase1: Reply,
    value: seq[byte],
    trail: var CallTrail,
): Result[Reply, InvocationFailure] =
  ## [SPEC CONFIG §5 l.196-200; I87 §2.7 step 2] Phase 2 of a `stage`, on
  ## this thread: the value decoded, validated and its value root computed
  ## against the binding phase 1 returned, then committed by the Runtime
  ## thread (`rqConfigCommit`). Malformed or too deep is INVALID_PARAMS
  ## without detail, answered here (row 3 follows rows 1-2 and the revision,
  ## which phase 1 checked); a value not of the root (row 4) goes to the
  ## Runtime thread, which decides whether its detail may be disclosed.
  let b = phase1.config.binding
  var u = update
  var path: seq[CborValue]
  let checked = checkValue(
    b.digest, b.document, b.root, b.commitment.subtreeRoot, value, e.payloadDepth
  )
  if checked.isErr:
    if checked.error.fault != vfMismatch:
      e.record(phase1.capture, trail)
      return err(
        failure(
          ecInvalidParams, "the configuration value is not one deterministic-CBOR value"
        )
      )
    u.mismatch = true
    path = checked.error.path
  else:
    u.value = newBlob(value)
    u.valueRoot = checked.get
  u.answers = phase1.answers
  u.gen = phase1.generation
  u.invalidations = phase1.invalidations
  let reply = e.call(
    Request(
      kind: rqConfigCommit,
      origin: moduleOrigin(instance),
      attempt: attempt,
      rc: RcCall(m: rmUpdateConfiguration, cfgUpdate: u),
    )
  )
  drop(u.value) # the Runtime thread took its own reference when it staged
  if reply.error.isSome and not reply.error.get.isTyped:
    # a typed outcome goes back to `rcInvoke` as phase 1's would
    var held = reply.config
    held.release()
    e.record(reply.capture, trail)
    if u.mismatch and reply.schemaAllowed:
      return err(
        InvocationFailure(
          code: ecInvalidParams,
          message: Opt.some(reply.error.get.message),
          detail: Opt.some(
            invalidParamsDetail(iprConfigurationSchemaMismatch, Opt.some(path))
          ),
        )
      )
    return err(failureOf(reply.error.get))
  ok(reply)

const NotRecorded =
  "disabled for this run; not recorded, so the next start applies the configuration: "
  ## [G412; Q4] the MODULE_ERROR of a disable whose record could not be written

proc remoteWork(
    e: Engine, instance, attempt: string, rc: RcCall, phase1: Reply
): Reply =
  ## [G412; Q4] The work of a remote record change, on this thread under the
  ## remote lock, in the order that leaves a failure in the cautious state.
  ## A change that turns nothing on was committed by phase 1: its listener
  ## process ends, then the fields it left off are recorded; a failed write
  ## keeps the change for the run and fails the call. A change that turns
  ## something on first removes the retained disable, then starts the
  ## listener process and waits until it listens, then commits
  ## (`rqRemoteCommit`); a failure leaves the record as it was, and a commit
  ## refused after the start ends that process again.
  let w = phase1.remote
  let d = e.remote
  if not w.pending:
    if w.close.len > 0 and d.close != nil:
      d.close(d.data, w.close)
    if w.stop and d.stop != nil:
      d.stop(d.data, w.key)
    if w.persist and d.persist != nil:
      let written = d.persist(d.data, w.key, w.provider, w.off, w.consumer)
      if written.isErr:
        let text = (if w.off.len > 0: NotRecorded else: "") & written.error
        return
          Reply(error: Opt.some(engineError(ecModule, text)), capture: phase1.capture)
    return phase1
  if w.persist and d.persist != nil:
    let written = d.persist(d.data, w.key, w.provider, w.off, w.consumer)
    if written.isErr:
      return Reply(
        error: Opt.some(engineError(ecModule, written.error)), capture: phase1.capture
      )
  if w.start:
    if d.start == nil:
      return Reply(
        error: Opt.some(engineError(ecModule, NoRemoteTransport)),
        capture: phase1.capture,
      )
    let started = d.start(d.data, w.key, w.host, w.port)
    if started.isErr:
      return Reply(error: Opt.some(started.error), capture: phase1.capture)
  var reply = e.call(
    Request(
      kind: rqRemoteCommit, origin: moduleOrigin(instance), attempt: attempt, rc: rc
    )
  )
  if reply.error.isSome and w.start and d.stop != nil:
    d.stop(d.data, w.key)
  reply.capture = phase1.capture
  reply

proc remoteAdmit*(
    e: Engine, listener: seq[byte], consumer: string
): Result[string, EngineError] =
  ## [G413] Admits a remote Runtime Control connection at the listener whose
  ## address bytes are `listener` for the forwarded consumer `consumer`
  ## (`forwarded.forwardedId`), once the remote judge checked its Hello: the
  ## token its invocations go through (`rcInvoke`'s `attempt`).
  let r = e.call(
    Request(kind: rqRemoteHello, origin: moduleOrigin(consumer), payload: listener)
  )
  if r.error.isSome:
    return err(r.error.get)
  ok(r.id)

proc remoteClosed*(e: Engine, token: string) =
  ## [G413] The connection `remoteAdmit` gave `token` ended.
  discard e.call(Request(kind: rqRemoteClosed, attempt: token))

proc rcAuthorizeMethod*(
    e: Engine, instance, attempt, bare: string
): Result[void, InvocationFailure] =
  ## [SPEC RUNTIME l.1824-1828, l.1835; RUN-1124; G413] Steps 1 and 2 of the
  ## order of checks for Runtime Control served to another Runtime: the
  ## method resolved, then what is authorized without the payload (the
  ## caller's association, and the method's authority where it names no
  ## target from the payload), before the payload is decoded or validated. A
  ## refusal is recorded as the call's outcome; an allow is asked again, from
  ## the cache, by the call itself.
  if not rcDeclares(bare):
    return err(InvocationFailure(code: ecMethodNotFound))
  let pre = e.call(
    Request(
      kind: rqRcPrecheck, origin: moduleOrigin(instance), attempt: attempt, bare: bare
    )
  )
  if pre.error.isSome:
    var trail: CallTrail
    e.record(pre.capture, trail)
    return err(failureOf(pre.error.get))
  ok()

proc rcInvoke*(
    e: Engine, instance, attempt, bare: string, params: seq[byte], authorized = false
): Result[seq[byte], InvocationFailure] =
  ## [SPEC INTERFACE §5.2; RUNTIME §9, §9.3] One Runtime Control method through
  ## the binding of `attempt`, synchronous or on a call worker. [CA l.1172-
  ## 1174; I85] A call whose applied decision requires retention is recorded
  ## after its outcome, here. A forwarded consumer's call passes
  ## `rcAuthorizeMethod` first: here, unless the caller did (`authorized`).
  var trail: CallTrail
  var value: seq[byte]
  let forwarded = instance.isForwarded
  if forwarded and not authorized:
    ?e.rcAuthorizeMethod(instance, attempt, bare)
  let rc = rcRequest(bare, params, e.payloadDepth, trail, value).valueOr:
    if error.code == ecInvalidParams and not forwarded:
      # [SPEC RUNTIME l.1827-1828] What is authorized without the payload
      # (step 2) comes before its validation (step 3).
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
  # [G412] A remote record change holds the engine's remote lock from its
  # phase 1 to its end, so its work on this thread never interleaves with
  # another's.
  let remoteSet = m in {rmSetRemoteListener, rmSetProviderExport}
  if remoteSet:
    acquire(e.remoteLock)
  defer:
    if remoteSet:
      release(e.remoteLock)
  var reply = e.call(
    Request(kind: rqRc, origin: moduleOrigin(instance), attempt: attempt, rc: rc)
  )
  if remoteSet and reply.error.isNone:
    reply = e.remoteWork(instance, attempt, rc, reply)
  var held = reply.config # [I87] references this thread releases
  defer:
    held.release()
  if reply.error.isSome and not reply.error.get.isTyped:
    e.record(reply.capture, trail)
    return err(failureOf(reply.error.get))
  if reply.error.isNone and m == rmUpdateConfiguration and rc.cfgUpdate.stage:
    reply = e.stage(instance, attempt, rc.cfgUpdate, reply, value, trail).valueOr:
      return err(error)
    held.release()
    held = reply.config
  # [SPEC RUNTIME l.1818-1822; re-pin P4a] A typed outcome is a successful
  # response holding the method's error arm, checked and recorded as one.
  let typed =
    if reply.error.isSome:
      reply.error.get.typed
    else:
      Opt.none(TypedError)
  let encoded =
    if typed.isSome:
      typedResponse(m, typed.get)
    elif m in {rmStartModule, rmStopModule, rmRecoverModule}:
      lifecycleResponse(m, reply.view)
    elif m in {rmGetConfigurationSchema, rmGetConfiguration, rmUpdateConfiguration}:
      let target = if m == rmUpdateConfiguration: rc.cfgUpdate.target else: rc.cfgTarget
      configResponse(m, target, held)
    else:
      Result[seq[byte], string].ok(reply.bytes)
  let response = block:
    let body = encoded.valueOr:
      e.record(reply.capture, trail)
      return err(failure(ecModule, "the response does not match its schema"))
    checkedResponse($m, body, e.payloadDepth, trail).valueOr:
      e.record(reply.capture, trail)
      return err(failure(ecModule, "the response does not match its schema"))
  trail.succeeded = true
  e.record(reply.capture, trail)
  when defined(lcnTestHooks):
    waitAtRcAnswerHold(m)
  ok(response)
