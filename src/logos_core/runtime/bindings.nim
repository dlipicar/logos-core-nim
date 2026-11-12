## INTERFACE §2.5, §2.9, §5.2; RUNTIME §3.4, §4.1, §6.4, §7.3, §7.5, §9.3: the
## native bindings the engine gives module code.
##
## Each execution attempt gets one Runtime Control binding, the engine's
## publish callback and one invocation-access closure (`AttemptServices`),
## passed in its initialization input. `materialize_route` makes route handles
## (`HandleState`). Both live on the shared heap and hold plain values only, so
## any thread may use them.
##
## Every operation runs on its caller's thread. What depends on Runtime-owned
## state (bindings, routes, subscriptions, authorization, provider readiness)
## is decided by one round trip to the Runtime thread, which orders it with
## every other change. What only needs the selected contract (validation,
## payload commitments, copies) stays on the caller's thread, which loads its
## own copy of the schemas it needs (`base/perthread`).
##
## The call paths are in `invoke.nim`, events in `events.nim`, asynchronous
## calls in `asynccall.nim`; this module wires them into the vtables.

{.push raises: [], gcsafe.}

import std/[atomics, locks]
import results
import ../abi/[checks, types]
import ../cbor/utf8
import ../hash/hashinput
import ../iface/[accept, outcome, payload, surface]
import ./[asynccall, callside, events, invoke, plumbing]

export callside.AttemptServices

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
  let r = rcInvoke(s.engine, $s.instance, $s.attempt, $`method`, bytes)
  if r.isErr:
    return status(r.error)
  give(r.get, outBuf, outLen)

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
  ## [I78] Runtime Control subscriptions are a later step (G178).
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
  ## [SPEC INTERFACE §2.9, §2.9.1; RUNTIME §7.5 l.1360-1371]
  bindingEnter()
  let s = servicesOf(binding)
  prepare(
    s.engine,
    rc = true,
    s.instance,
    s.attempt,
    FixedText(),
    0,
    nil,
    `method`,
    params,
    paramsLen,
    options,
    callbacks,
    outCall,
  )

# Route handles ------------------------------------------------------------------------

proc handleOf(r: ptr LogosRouteHandle): ptr HandleState =
  cast[ptr HandleState](r.state)

proc routeCallOp(
    route: ptr LogosRouteHandle,
    `method`: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outBuf: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §5.2; RUNTIME §4.1, §6.4, §7.5] (`invoke.nim`)
  bindingEnter()
  if outBuf == nil or outLen == nil:
    return status(ecInvalidParams, "null response outputs")
  outBuf[] = nil
  outLen[] = 0
  if `method` == nil or params == nil or paramsLen == 0:
    return status(ecInvalidParams, "null method or empty request")
  let r = routeCall(handleOf(route), $`method`, view(params, paramsLen))
  if r.isErr:
    return status(r.error)
  give(r.get, outBuf, outLen)

proc routeReleaseResponseOp(
    route: ptr LogosRouteHandle, response: ptr UncheckedArray[uint8], len: csize_t
) {.cdecl.} =
  ## The Runtime's copy: the provider's buffer is long released.
  cFree(response)

proc routeSubscribeOp(
    route: ptr LogosRouteHandle,
    eventName: cstring,
    handler: LogosEventHandler,
    userData: pointer,
    outId: ptr LogosSubscriptionId,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.5; RUNTIME §4.4] (`events.nim`)
  bindingEnter()
  subscribe(handleOf(route), eventName, handler, userData, outId)

proc routeUnsubscribeOp(
    route: ptr LogosRouteHandle, id: LogosSubscriptionId
): LogosResult {.cdecl.} =
  bindingEnter()
  unsubscribe(handleOf(route), id)

proc routePrepareCallOp(
    route: ptr LogosRouteHandle,
    `method`: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    options: ptr LogosAsyncOptions,
    callbacks: ptr LogosAsyncCallbacks,
    outCall: ptr LogosAsyncCall,
): LogosResult {.cdecl.} =
  ## [SPEC INTERFACE §2.9.1; RUNTIME §4.1 l.880-884] The call keeps the
  ## handle's consumer, route, path generation and contract (`asynccall.nim`).
  bindingEnter()
  let h = handleOf(route)
  prepare(
    h.engine,
    rc = false,
    h.consumer,
    h.attempt,
    h.route,
    h.generation,
    h.blob,
    `method`,
    params,
    paramsLen,
    options,
    callbacks,
    outCall,
  )

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
  ## [SPEC INTERFACE §2.5 l.1461-1468, l.1503-1506, §5.2 l.3895-3897,
  ## l.3912-3916] The handle's subscriptions are deactivated and no callback
  ## begins after release; a handler or terminal callback already running on
  ## another thread is waited for. The logical route and the calls prepared
  ## through the handle stay as they are.
  bindingEnter()
  let h = handleOf(route)
  let reply = h.engine.call(
    Request(
      kind: rqReleaseHandle,
      origin: moduleOrigin($h.consumer),
      route: $h.route,
      handle: h,
      generation: h.generation,
    )
  )
  quiesce(reply.subs)
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
  ## [G177] Each handle is its own invocation-path generation.
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
  h.blob = newBlob(root, schema, int(schemaLen))
  h.generation = nextGeneration()
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
  if set.primary.root == root:
    cacheSelected(root, set)
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
  ## The Runtime Control binding, publish state and invocation-access state of
  ## one attempt.
  result = createShared(AttemptServices)
  result.engine = e
  result.instance = fixed(instance)
  result.attempt = fixed(attempt)
  result.binding = LogosRuntimeControlBinding(vtable: addr rcVtable, state: result)

proc freeAttemptServices*(s: ptr AttemptServices) =
  ## Once the attempt's context is destroyed, or its initialization made none.
  if s != nil:
    freeShared(s)

func attemptOf*(s: ptr AttemptServices): string =
  $s.attempt

proc fill*(services: var InitServices, s: ptr AttemptServices) =
  ## [SPEC RUNTIME §7.4 l.1305-1323] The attempt's Runtime Control binding, the
  ## engine's publish callback and invocation access: every attempt gets the
  ## same non-null callback, with its own user data.
  services.runtimeControl = addr s.binding
  services.publish = publishOp
  services.publishUserData = s
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
