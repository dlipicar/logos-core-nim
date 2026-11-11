## INTERFACE §2.5, §2.9.3, §5.2; RUNTIME §3.4, §4.1, §6.4, §7.5, §9.3: the
## native bindings the engine gives module code.
##
## Each execution attempt gets one Runtime Control binding and one invocation
## access closure (`AttemptServices`), passed in its initialization input.
## `materialize_route` makes route handles (`HandleState`). Both live on the
## shared heap and hold plain values only, so any thread may use them.
##
## Every operation runs on its caller's thread. What depends on Runtime-owned
## state (bindings, routes, authorization, provider readiness) is decided by
## one round trip to the Runtime thread, which orders it with every other
## change. What only needs the selected contract (validation, payload
## commitments, copies) stays on the caller's thread, which loads its own copy
## of the schemas it needs (`base/perthread`).
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
## 3. The provider's `_MODULE_dispatch` runs on this thread with an invocation
##    context current that names the consumer (§2.9.3).
## 4. The result and outputs are checked together; a success is validated and
##    its commitment computed (MODULE_ERROR otherwise), copied into a buffer
##    the Runtime owns, and the provider's buffer is released at once with its
##    `_MODULE_free` (response copy), so a provider never waits on a
##    consumer's buffers to stop (RUNTIME l.1581-1583).
## 5. The call leaves the in-flight count; a provider being stopped is
##    destroyed only once its count is zero.
##
## The well-known `logos.schema` method is answered at step 3 by the boundary
## itself from the selected contract (TRANSPORT §8.1 does the same for a
## session); no provider code runs for it.

{.push raises: [], gcsafe.}

import std/[atomics, locks, tables]
import results
import ../cbor
import ../cbor/utf8
import ../abi/[checks, types]
import ../base/perthread
import ../hash/hashinput
import ../iface/[accept, outcome, payload, surface]
import ../transport/boundary
import ./plumbing

const
  TextCapacity = 160 ## instance ids are at most 128 bytes; tokens are shorter
  RcNamespace = "logos.runtime_control."

type
  FixedText = object
    len: int
    data: array[TextCapacity, char]

  AttemptServices* = object
    ## One execution attempt's Runtime Control binding and invocation-access
    ## state. Valid until the attempt's context has been destroyed.
    engine: Engine
    instance: FixedText
    attempt: FixedText
    binding*: LogosRuntimeControlBinding

  CallbackState = enum
    cbNone
    cbScheduled
    cbRunning
    cbDone
    cbSuppressed

  HandleState* = object
    ## One materialized route handle. Freed when its `release` and every
    ## terminal callback scheduled for it are done.
    engine: Engine
    consumer, attempt, route: FixedText
    root: Digest
    schema: ptr UncheckedArray[byte] ## the validated construction input
    schemaLen: int
    refs: Atomic[int]
    lock: Lock
    cond: Cond
    cb: CallbackState
    handler: LogosRouteEndHandler
    userData: pointer
    code: CErrorCode

  ActiveInvocation = object
    ## The invocation context of one direct provider entry on this thread.
    context: LogosInvocationContext
    access: pointer ## the provider's invocation-access state
    ticket: ptr CallTicket
    runtimeId: string
    consumer: string
    previous: ptr ActiveInvocation

proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

template bindingEnter() =
  ## [IMPL] As the module kit's entries: a thread this Nim runtime did not
  ## create (a module's own) registers before its first allocation.
  setupForeignThreadGc()
  enterThread()
  when not defined(gcDestructors):
    var stackBottom {.volatile, noinit.}: pointer
    nimGC_setStackBottom(addr stackBottom)

func fixed(s: string): FixedText =
  doAssert s.len <= TextCapacity
  result.len = s.len
  for i, c in s:
    result.data[i] = c

func `$`(t: FixedText): string =
  result = newString(t.len)
  for i in 0 ..< t.len:
    result[i] = t.data[i]

# Results -------------------------------------------------------------------------

var
  statusMessage {.threadvar.}: array[MaxMessageBytes + 1, char]
  statusDetail {.threadvar.}: array[MaxDetailBytes, uint8]

func clip(m: string): string =
  ## At most `MaxMessageBytes` bytes, cut before a continuation byte, no NUL.
  var s = m
  for c in s.mitems:
    if c == '\0':
      c = ' '
  if s.len <= MaxMessageBytes:
    return s
  var n = MaxMessageBytes
  while n > 0 and (uint8(s[n]) and 0xC0'u8) == 0x80'u8:
    dec n
  s[0 ..< n]

proc status(f: InvocationFailure): LogosResult =
  ## [SPEC INTERFACE §5.1, §5.2] A failure status whose message and detail live
  ## in this thread's storage until the next binding operation on it.
  var r = LogosResult(code: CErrorCode(ord(f.code)))
  if f.message.isSome:
    let m = clip(f.message.get)
    for i, c in m:
      statusMessage[i] = c
    statusMessage[m.len] = '\0'
    r.message = cast[cstring](addr statusMessage[0])
  if f.detail.isSome and f.detail.get.len <= MaxDetailBytes and f.code == ecInvalidParams:
    let d = f.detail.get
    for i, b in d:
      statusDetail[i] = b
    r.detail = cast[ptr UncheckedArray[uint8]](addr statusDetail[0])
    r.detailLen = csize_t(d.len)
  r

proc status(code: ErrorCode, message: string): LogosResult =
  status(InvocationFailure(code: code, message: Opt.some(message)))

proc status(e: EngineError): LogosResult =
  status(e.code, e.message)

proc status(f: AbiFailure): LogosResult =
  ## A producer's own valid failure, forwarded as it gave it; any other
  ## rejection as MODULE_ERROR without its diagnostics (I66).
  if f.reason.len == 0:
    status(InvocationFailure(code: f.code, message: f.message, detail: f.detail))
  else:
    status(InvocationFailure(code: f.code))

proc give(
    bytes: openArray[byte], outBuf: ptr ptr UncheckedArray[uint8], outLen: ptr csize_t
): LogosResult =
  ## A success: the response in a C buffer the caller releases once.
  let p = cast[ptr UncheckedArray[uint8]](cMalloc(csize_t(max(bytes.len, 1))))
  if p == nil:
    return status(ecModule, "out of memory")
  for i, b in bytes:
    p[i] = b
  outBuf[] = p
  outLen[] = csize_t(bytes.len)
  LogosResult()

func view(p: ptr UncheckedArray[uint8], len: csize_t): seq[byte] =
  result = newSeq[byte](int(len))
  for i in 0 ..< int(len):
    result[i] = p[i]

# Runtime Control requests -----------------------------------------------------------

proc rcRequest(
    bare: string, params: openArray[byte]
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
  discard rcSchema().commitment(declaration, v).valueOr:
      return err(
        InvocationFailure(
          code: ecModule, message: Opt.some("the request commitment cannot be computed")
        )
      )
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
  else:
    encode(
      LogosNSRuntimeControlStopModuleResponse(
        module: v.module, instance: Opt.some(v.instance), state: state
      )
    )

proc checkedResponse(bare: string, bytes: seq[byte]): Result[seq[byte], string] =
  ## [SPEC RUNTIME l.229, l.3747] A successful Runtime Control response is a
  ## value of the method's response schema, and its commitment is computed.
  let declaration = RcNamespace & bare & "_response"
  let v = ?rcSchema().decodeChecked(declaration, bytes)
  discard ?rcSchema().commitment(declaration, v)
  ok(bytes)

# The Runtime Control binding --------------------------------------------------------

proc servicesOf(b: ptr LogosRuntimeControlBinding): ptr AttemptServices =
  cast[ptr AttemptServices](b.state)

proc rcCallOp(
    binding: ptr LogosRuntimeControlBinding,
    `method`: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outBuf: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §5.2; RUNTIME §9, §9.3]
  bindingEnter()
  if outBuf == nil or outLen == nil:
    return status(ecInvalidParams, "null response outputs")
  outBuf[] = nil
  outLen[] = 0
  if `method` == nil or (params == nil and paramsLen != 0):
    return status(ecInvalidParams, "null method or request")
  let s = servicesOf(binding)
  let bytes =
    if params == nil:
      newSeq[byte]()
    else:
      view(params, paramsLen)
  let rc = rcRequest($`method`, bytes).valueOr:
    if error.code == ecInvalidParams:
      # [G171 interim (TF-18)] What is authorized without the payload comes
      # before its validation.
      let pre = s.engine.call(
        Request(
          kind: rqRcPrecheck,
          origin: moduleOrigin($s.instance),
          attempt: $s.attempt,
          bare: $`method`,
        )
      )
      if pre.error.isSome:
        return status(pre.error.get)
    return status(error)
  let m = rc.m
  let reply = s.engine.call(
    Request(kind: rqRc, origin: moduleOrigin($s.instance), attempt: $s.attempt, rc: rc)
  )
  if reply.error.isSome:
    return status(reply.error.get)
  let encoded =
    if m in {rmStartModule, rmStopModule}:
      lifecycleResponse(m, reply.view)
    else:
      Result[seq[byte], string].ok(reply.bytes)
  let body = encoded.valueOr:
    return status(ecModule, "the response does not match its schema")
  let response = checkedResponse($m, body).valueOr:
    return status(ecModule, "the response does not match its schema")
  give(response, outBuf, outLen)

proc rcReleaseResponseOp(
    binding: ptr LogosRuntimeControlBinding,
    response: ptr UncheckedArray[uint8],
    responseLen: csize_t,
) {.cdecl.} =
  cFree(response)

proc rcSubscribeOp(
    binding: ptr LogosRuntimeControlBinding,
    eventName: cstring,
    handler: LogosEventHandler,
    userData: pointer,
    outId: ptr LogosSubscriptionId,
): LogosResult {.cdecl.} =
  bindingEnter()
  status(ecModule, "Runtime Control events are not supported by this Runtime yet")

proc rcUnsubscribeOp(
    binding: ptr LogosRuntimeControlBinding, id: LogosSubscriptionId
): LogosResult {.cdecl.} =
  bindingEnter()
  status(ecModule, "Runtime Control events are not supported by this Runtime yet")

proc rcConnectRemoteOp(
    binding: ptr LogosRuntimeControlBinding,
    endpoint: ptr UncheckedArray[uint8],
    endpointLen: csize_t,
    expectedRoot: ptr ContractRoot,
    outBinding: ptr LogosRuntimeControlBinding,
): LogosResult {.cdecl.} =
  bindingEnter()
  if outBinding != nil:
    outBinding.vtable = nil
    outBinding.state = nil
  checkConnectRemoteInput(endpoint, endpointLen, expectedRoot).isOkOr:
    return status(error)
  # [SPEC RUNTIME l.1783-1784] A valid endpoint names no enrolled Runtime:
  # this Runtime has no enrollments yet.
  let v = decodePayload(view(endpoint, endpointLen)).valueOr:
    return status(toFailure(error))
  rcSchema().checkPath("logos.runtime_control.runtime_endpoint", v).isOkOr:
    return status(
      InvocationFailure(
        code: ecInvalidParams,
        detail: Opt.some(invalidParamsDetail(iprSchemaMismatch, Opt.some(error))),
      )
    )
  status(ecNotAuthorised, "not authorised")

proc rcReleaseOp(binding: ptr LogosRuntimeControlBinding) {.cdecl.} =
  ## [SPEC INTERFACE §5.2 l.3864] The initialization input's binding is
  ## borrowed and never released by the module; a release is ignored [IMPL].
  discard

proc rcPrepareCallOp(
    binding: ptr LogosRuntimeControlBinding,
    `method`: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    options: ptr LogosAsyncOptions,
    callbacks: ptr LogosAsyncCallbacks,
    outCall: ptr LogosAsyncCall,
): LogosResult {.cdecl.} =
  bindingEnter()
  status(ecModule, "asynchronous calls are not supported by this Runtime yet")

# Route handles ------------------------------------------------------------------------

proc handleOf(r: ptr LogosRouteHandle): ptr HandleState =
  cast[ptr HandleState](r.state)

proc freeHandle(h: ptr HandleState) =
  if h.schema != nil:
    deallocShared(h.schema)
  deinitCond(h.cond)
  deinitLock(h.lock)
  freeShared(h)

proc dropHandle(h: ptr HandleState) =
  if h.refs.fetchSub(1) == 1:
    freeHandle(h)

type Selected = object ## One selected contract, as this thread loaded it.
  boundary: Boundary
  validator: ContractValidator

var
  selectedCache {.threadvar.}: Table[Digest, Selected]
  selectedHooked {.threadvar.}: bool

proc dropSelected() {.nimcall, gcsafe, raises: [].} =
  selectedCache = default(Table[Digest, Selected])
  selectedHooked = false

proc selectedOf(h: ptr HandleState): Result[Selected, string] =
  ## This thread's copy of the handle's selected contract, rebuilt from the
  ## construction input `materialize_route` validated. Released with the
  ## thread's tables.
  if not selectedHooked:
    selectedHooked = true
    onThreadRelease(dropSelected)
  if h.root in selectedCache:
    try:
      return ok(selectedCache[h.root])
    except KeyError:
      discard
  let set = ?acceptSchemaResponse(
    h.schema.toOpenArray(0, h.schemaLen - 1), h.root, AcceptOptions(system: true)
  )
  let b = ?boundary(set, h.root)
  let s = Selected(boundary: b, validator: validator(set))
  selectedCache[h.root] = s
  ok(s)

var active {.threadvar.}: ptr ActiveInvocation

proc callerOp(
    invocation: ptr LogosInvocationContext, outCaller: ptr LogosCallerView
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.9.3; RUNTIME §4.1 l.869-873] The consumer of the route
  ## the active entry came through: a module caller.
  let a = cast[ptr ActiveInvocation](invocation.state)
  if outCaller == nil:
    return status(ecInvalidParams, "null caller output")
  outCaller[] = LogosCallerView(
    kind: CallerModule,
    runtimeInstanceId: LogosUtf8View(
      data: cast[ptr UncheckedArray[uint8]](unsafeAddr a.runtimeId[0]),
      len: csize_t(a.runtimeId.len),
    ),
    moduleInstanceId: LogosUtf8View(
      data: cast[ptr UncheckedArray[uint8]](unsafeAddr a.consumer[0]),
      len: csize_t(a.consumer.len),
    ),
  )
  LogosResult()

proc isCancelledOp(invocation: ptr LogosInvocationContext): bool {.cdecl.} =
  ## [SPEC INTERFACE §2.9.3 l.2101-2102, l.2143] Sticky: set by the Runtime
  ## thread once the call's route or consumer has ended.
  let a = cast[ptr ActiveInvocation](invocation.state)
  a.ticket != nil and a.ticket.cancelled.load

proc scopedPublishOp(
    invocation: ptr LogosInvocationContext,
    eventName: cstring,
    data: ptr UncheckedArray[uint8],
    dataLen: csize_t,
): LogosResult {.cdecl.} =
  status(ecModule, "invocation-scoped events are not supported by this Runtime yet")

var contextVtable = LogosInvocationContextVtable(
  abiVersion: InvocationContextAbiVersion,
  structSize: csize_t(sizeof(LogosInvocationContextVtable)),
  caller: callerOp,
  isCancelled: isCancelledOp,
  publish: scopedPublishOp,
)

proc currentOp(state: pointer): ptr LogosInvocationContext {.cdecl.} =
  ## [SPEC INTERFACE §2.9.3, l.2169] The context of the innermost provider
  ## entry active on this thread for the instance `state` belongs to, so a
  ## nested entry into another instance hides nothing; none outside one.
  var a = active
  while a != nil:
    if a.access == state:
      return addr a.context
    a = a.previous
  nil

proc dispatchWith(
    adm: Admission,
    consumer, bare: string,
    params: openArray[byte],
    outBuf: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult =
  ## The provider entry, with its invocation context current on this thread.
  var a = ActiveInvocation(
    access: adm.access,
    ticket: adm.ticket,
    runtimeId: adm.runtimeId,
    consumer: consumer,
    previous: active,
  )
  a.context = LogosInvocationContext(vtable: addr contextVtable, state: addr a)
  active = addr a
  result = adm.dispatch(
    adm.context,
    cstring(bare),
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    outBuf,
    outLen,
  )
  active = a.previous

proc leave(h: ptr HandleState, adm: Admission) =
  h.engine.post(
    Msg(kind: mkCallDone, provider: adm.provider, route: adm.route, ticket: adm.ticket)
  )

proc checkRequest(
    sel: Selected, bare: string, params: openArray[byte]
): Result[CborValue, LogosResult] =
  ## [SPEC RUNTIME §4.1 l.833-841, l.852-853] A request is validated and
  ## committed before provider code runs; `logos.schema` is the boundary's.
  let request =
    if sel.validator.surface.findMethod(bare).isSome:
      sel.validator.checkParams(bare, params).valueOr:
        return err(status(toFailure(error)))
    else:
      decodePayload(params).valueOr:
        return err(status(toFailure(error)))
  sel.boundary.commitRequest(bare, request).isOkOr:
    return err(status(error.failure))
  ok(request)

proc providerCall(
    h: ptr HandleState,
    adm: Admission,
    bare: string,
    params: openArray[byte],
    outBuf: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult =
  ## Steps 2-4 for an admitted call; the caller leaves the in-flight count.
  let sel = selectedOf(h).valueOr:
    return status(ecModule, "the selected contract cannot be loaded")
  discard checkRequest(sel, bare, params).valueOr:
    return error
  var buf: ptr UncheckedArray[uint8] = nil
  var len: csize_t = 0
  let r = dispatchWith(adm, $h.consumer, bare, params, addr buf, addr len)
  checkOutcome(r, bufferShape(buf, len)).isOkOr:
    if transfersBuffer(r, buf):
      adm.free(adm.context, buf)
    return status(error)
  # [SPEC RUNTIME §4.1 l.838-840] A response that does not validate or commit
  # is not returned as a success.
  var bytes: seq[byte]
  if len <= csize_t(high(int)):
    bytes = view(buf, len)
  adm.free(adm.context, buf)
  if bytes.len == 0:
    return status(ecModule, "the provider's response is too long")
  let response = sel.validator.checkResult(bare, bytes).valueOr:
    return status(ecModule, "the provider's response does not match its schema")
  sel.boundary.commitResponse(bare, response).isOkOr:
    return status(ecModule, "the provider's response cannot be committed")
  give(bytes, outBuf, outLen)

proc introspect(
    h: ptr HandleState,
    bare: string,
    params: openArray[byte],
    outBuf: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult =
  ## [SPEC INTERFACE §5.1; RUNTIME §9.3 l.2990-2992] `logos.schema`: the
  ## selected contract's `logos.schema_response`, from the boundary.
  let sel = selectedOf(h).valueOr:
    return status(ecModule, "the selected contract cannot be loaded")
  discard checkRequest(sel, bare, params).valueOr:
    return error
  let v = schemaResponse(sel.boundary.contracts, h.root).valueOr:
    return status(ecModule, "the schema response cannot be built")
  sel.boundary.commitResponse(bare, v).isOkOr:
    return status(ecModule, "the schema response cannot be committed")
  give(encodeCbor(v), outBuf, outLen)

proc routeCallOp(
    route: ptr LogosRouteHandle,
    `method`: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outBuf: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §5.2; RUNTIME §4.1, §6.4, §7.5]
  bindingEnter()
  if outBuf == nil or outLen == nil:
    return status(ecInvalidParams, "null response outputs")
  outBuf[] = nil
  outLen[] = 0
  if `method` == nil or params == nil or paramsLen == 0:
    return status(ecInvalidParams, "null method or empty request")
  let h = handleOf(route)
  let bare = $`method`
  let reply = h.engine.call(
    Request(
      kind: rqAdmit,
      origin: moduleOrigin($h.consumer),
      attempt: $h.attempt,
      route: $h.route,
      bare: bare,
      handle: h,
    )
  )
  let bytes = view(params, paramsLen)
  if reply.error.isSome:
    if reply.error.get.code == ecNotReady:
      # [G171 interim (TF-18)] The request is authorized; its payload is
      # validated before readiness is reported.
      let sel = selectedOf(h)
      if sel.isOk:
        discard checkRequest(sel.get, bare, bytes).valueOr:
          return error
    return status(reply.error.get)
  let adm = reply.admission
  if adm.introspection:
    return introspect(h, bare, bytes, outBuf, outLen)
  result = providerCall(h, adm, bare, bytes, outBuf, outLen)
  h.leave(adm)

proc routeReleaseResponseOp(
    route: ptr LogosRouteHandle, response: ptr UncheckedArray[uint8], len: csize_t
) {.cdecl.} =
  ## The Runtime's copy (step 4): the provider's buffer is long released.
  cFree(response)

proc routeSubscribeOp(
    route: ptr LogosRouteHandle,
    eventName: cstring,
    handler: LogosEventHandler,
    userData: pointer,
    outId: ptr LogosSubscriptionId,
): LogosResult {.cdecl.} =
  bindingEnter()
  status(ecModule, "route events are not supported by this Runtime yet")

proc routeUnsubscribeOp(
    route: ptr LogosRouteHandle, id: LogosSubscriptionId
): LogosResult {.cdecl.} =
  bindingEnter()
  status(ecModule, "route events are not supported by this Runtime yet")

proc routePrepareCallOp(
    route: ptr LogosRouteHandle,
    `method`: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    options: ptr LogosAsyncOptions,
    callbacks: ptr LogosAsyncCallbacks,
    outCall: ptr LogosAsyncCall,
): LogosResult {.cdecl.} =
  bindingEnter()
  status(ecModule, "asynchronous calls are not supported by this Runtime yet")

proc routeObserveEndOp(
    route: ptr LogosRouteHandle, handler: LogosRouteEndHandler, userData: pointer
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.5 l.1474-1497] Installation is ordered with
  ## termination on the Runtime thread; an already terminal handle returns its
  ## retained code and installs nothing.
  bindingEnter()
  if handler.isNil:
    return status(ecInvalidParams, "a null handler")
  let h = handleOf(route)
  let reply = h.engine.call(
    Request(
      kind: rqObserveEnd,
      origin: moduleOrigin($h.consumer),
      route: $h.route,
      handle: h,
      handler: handler,
      userData: userData,
    )
  )
  if reply.error.isSome:
    return status(reply.error.get)
  LogosResult()

proc routeReleaseOp(route: ptr LogosRouteHandle) {.cdecl.} =
  ## [SPEC INTERFACE §2.5, §5.2 l.3912-3916] No callback begins after release;
  ## one already running is waited for. The logical route stays as it is.
  bindingEnter()
  let h = handleOf(route)
  discard h.engine.call(
    Request(
      kind: rqReleaseHandle,
      origin: moduleOrigin($h.consumer),
      route: $h.route,
      handle: h,
    )
  )
  withLock h.lock:
    if h.cb == cbScheduled:
      h.cb = cbSuppressed
    while h.cb == cbRunning:
      wait(h.cond, h.lock)
  dropHandle(h)

var routeVtable = LogosRouteVtable(
  abiVersion: RouteVtableAbiVersion,
  structSize: csize_t(sizeof(LogosRouteVtable)),
  call: routeCallOp,
  releaseResponse: routeReleaseResponseOp,
  subscribe: routeSubscribeOp,
  unsubscribe: routeUnsubscribeOp,
  release: routeReleaseOp,
  prepareCall: routePrepareCallOp,
  observeEnd: routeObserveEndOp,
)

proc rcMaterializeOp(
    binding: ptr LogosRuntimeControlBinding,
    routeId: cstring,
    expectedRoot: ptr ContractRoot,
    schema: ptr UncheckedArray[uint8],
    schemaLen: csize_t,
    outRoute: ptr LogosRouteHandle,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §5.2 l.3880-3911; RUNTIME §4.1] Input and construction
  ## input are checked here; ownership, readiness and the recorded contract
  ## on the Runtime thread, which reports a root mismatch only after them.
  bindingEnter()
  if outRoute == nil:
    return status(ecInvalidParams, "null route output")
  outRoute.vtable = nil
  outRoute.state = nil
  checkMaterializeInput(routeId, expectedRoot, schema, schemaLen).isOkOr:
    return status(error)
  let id = $routeId
  if id.len == 0 or id.len > 128 or not isValidUtf8(id):
    return status(ecInvalidParams, "a route id has 1 to 128 UTF-8 bytes")
  let root: Digest = expectedRoot[]
  # [SPEC INTERFACE §5.2 l.3904-3906] Malformed or invalid construction input
  # is INVALID_PARAMS without detail [IMPL: detail is only permitted].
  let set = acceptSchemaResponse(
    schema.toOpenArray(0, int(schemaLen) - 1), AcceptOptions(system: true)
  ).valueOr:
    return status(ecInvalidParams, "invalid construction input: " & error)
  let s = binding.servicesOf
  let h = createShared(HandleState)
  h.engine = s.engine
  h.consumer = s.instance
  h.attempt = s.attempt
  h.route = fixed(id)
  h.root = root
  h.schemaLen = int(schemaLen)
  h.schema = cast[ptr UncheckedArray[byte]](allocShared(h.schemaLen))
  for i in 0 ..< h.schemaLen:
    h.schema[i] = schema[i]
  h.refs.store(1)
  initLock(h.lock)
  initCond(h.cond)
  let reply = s.engine.call(
    Request(
      kind: rqMaterialize,
      origin: moduleOrigin($s.instance),
      attempt: $s.attempt,
      route: id,
      root: root,
      rebuilt: set.primary.root == root,
      handle: h,
    )
  )
  if reply.error.isSome:
    freeHandle(h)
    return status(reply.error.get)
  if set.primary.root == root and root notin selectedCache:
    let b = boundary(set, root)
    if b.isOk:
      selectedCache[root] = Selected(boundary: b.get, validator: validator(set))
  outRoute.vtable = addr routeVtable
  outRoute.state = h
  LogosResult()

var rcVtable = LogosRuntimeControlVtable(
  abiVersion: RuntimeControlVtableAbiVersion,
  structSize: csize_t(sizeof(LogosRuntimeControlVtable)),
  call: rcCallOp,
  releaseResponse: rcReleaseResponseOp,
  subscribe: rcSubscribeOp,
  unsubscribe: rcUnsubscribeOp,
  materializeRoute: rcMaterializeOp,
  connectRemote: rcConnectRemoteOp,
  release: rcReleaseOp,
  prepareCall: rcPrepareCallOp,
)

# What the engine uses ----------------------------------------------------------------

proc newAttemptServices*(e: Engine, instance, attempt: string): ptr AttemptServices =
  ## The Runtime Control binding and invocation-access state of one attempt.
  result = createShared(AttemptServices)
  result.engine = e
  result.instance = fixed(instance)
  result.attempt = fixed(attempt)
  result.binding = LogosRuntimeControlBinding(vtable: addr rcVtable, state: result)

proc freeAttemptServices*(s: ptr AttemptServices) =
  ## Once the attempt's context is destroyed, or its initialization made none.
  if s != nil:
    freeShared(s)

proc fill*(services: var InitServices, s: ptr AttemptServices) =
  ## The attempt's Runtime Control binding and invocation access.
  services.runtimeControl = addr s.binding
  services.invocationAccess = LogosInvocationAccess(state: s, current: currentOp)

proc installEnd*(handle: pointer, handler: LogosRouteEndHandler, userData: pointer) =
  ## Runtime thread: the handle's one terminal observer.
  let h = cast[ptr HandleState](handle)
  withLock h.lock:
    h.handler = handler
    h.userData = userData

proc scheduleEnd*(handle: pointer, code: ErrorCode) =
  ## Runtime thread: the handle's path became terminal and a worker will run
  ## its observer (`runEnd`), which holds a reference until it is done.
  let h = cast[ptr HandleState](handle)
  discard h.refs.fetchAdd(1)
  withLock h.lock:
    h.code = CErrorCode(ord(code))
    h.cb = cbScheduled

proc runEnd*(handle: pointer) =
  ## Worker thread: the terminal callback, once, unless release suppressed it.
  let h = cast[ptr HandleState](handle)
  var run = false
  withLock h.lock:
    if h.cb == cbScheduled:
      h.cb = cbRunning
      run = true
  if run:
    h.handler(h.code, h.userData)
    withLock h.lock:
      h.cb = cbDone
      broadcast(h.cond)
  dropHandle(h)
