## INTERFACE §5.2: the native module ABI as Nim types, field for field and in
## the same order as `logos_types.h`, so each has the C layout (checked against
## the generated header by `tests/test_abi.nim`). Callbacks use the C calling
## convention. Nothing here allocates or calls through a pointer; the checks a
## binding consumer or producer applies are in `checks.nim`.
##
## Version-delimited structs: the module initialization input, the Runtime
## Control and route vtables (ABI version 2), the async call, option and
## callback structs (`LOGOS_ASYNC_CALL_ABI_VERSION`), the provider descriptor
## and provider invocation (`LOGOS_ASYNC_PROVIDER_ABI_VERSION`) and the
## invocation-context vtable (`LOGOS_INVOCATION_CONTEXT_ABI_VERSION`).

{.push raises: [].}

const
  ModuleInitAbiVersion* = 2'u32 ## `LOGOS_MODULE_INIT_ABI_VERSION`
  RuntimeControlVtableAbiVersion* = 2'u32 ## `LOGOS_RUNTIME_CONTROL_VTABLE_ABI_VERSION`
  RouteVtableAbiVersion* = 2'u32 ## `LOGOS_ROUTE_VTABLE_ABI_VERSION`
  AsyncCallAbiVersion* = 1'u32 ## `LOGOS_ASYNC_CALL_ABI_VERSION`
  AsyncProviderAbiVersion* = 1'u32 ## `LOGOS_ASYNC_PROVIDER_ABI_VERSION`
  InvocationContextAbiVersion* = 1'u32 ## `LOGOS_INVOCATION_CONTEXT_ABI_VERSION`
  CallerModule* = 1'u32 ## `LOGOS_CALLER_MODULE`
  CallerSystemService* = 2'u32 ## `LOGOS_CALLER_SYSTEM_SERVICE`

type
  CErrorCode* = cint
    ## `logos_error_code_t` as it crosses the ABI: any `int` a foreign producer
    ## writes, mapped to `ErrorCode` only after a range check.

  LogosResult* {.bycopy.} = object ## `logos_result_t`
    code*: CErrorCode
    message*: cstring
    detail*: ptr UncheckedArray[uint8]
    detailLen*: csize_t

  ReleaseFn* = proc(state: pointer) {.cdecl, gcsafe, raises: [].}

  LogosResponseOwner* {.bycopy.} = object ## `logos_response_owner_t`
    state*: pointer
    release*: ReleaseFn

  LogosModuleContext* {.incompleteStruct.} = object
    ## `struct logos_module_context`: module-owned and opaque.

  LogosUtf8View* {.bycopy.} = object ## `logos_utf8_view_t`
    data*: ptr UncheckedArray[uint8]
    len*: csize_t

  LogosCallerView* {.bycopy.} = object ## `logos_caller_view_t`
    kind*: uint32
    runtimeInstanceId*: LogosUtf8View
    moduleInstanceId*: LogosUtf8View

  LogosInvocationContext* {.bycopy.} = object ## `logos_invocation_context_t`
    vtable*: ptr LogosInvocationContextVtable
    state*: pointer

  LogosInvocationContextVtable* {.bycopy.} = object
    ## `logos_invocation_context_vtable_t`
    abiVersion*: uint32
    structSize*: csize_t
    caller*: proc(
      invocation: ptr LogosInvocationContext, outCaller: ptr LogosCallerView
    ): LogosResult {.cdecl, gcsafe, raises: [].}
    isCancelled*:
      proc(invocation: ptr LogosInvocationContext): bool {.cdecl, gcsafe, raises: [].}
    publish*: proc(
      invocation: ptr LogosInvocationContext,
      eventName: cstring,
      cborData: ptr UncheckedArray[uint8],
      cborDataLen: csize_t,
    ): LogosResult {.cdecl, gcsafe, raises: [].}

  LogosInvocationAccess* {.bycopy.} = object ## `logos_invocation_access_t`
    state*: pointer
    current*:
      proc(state: pointer): ptr LogosInvocationContext {.cdecl, gcsafe, raises: [].}

  LogosAsyncCompleteFn* = proc(
    userData: pointer,
    result: LogosResult,
    responseCbor: ptr UncheckedArray[uint8],
    responseCborLen: csize_t,
    owner: LogosResponseOwner,
  ) {.cdecl, gcsafe, raises: [].} ## `logos_async_complete_fn`

  LogosAsyncOptions* {.bycopy.} = object ## `logos_async_options_t`
    abiVersion*: uint32
    structSize*: csize_t
    hasTimeout*: bool
    timeoutMs*: uint64

  LogosAsyncCallbacks* {.bycopy.} = object ## `logos_async_callbacks_t`
    abiVersion*: uint32
    structSize*: csize_t
    complete*: LogosAsyncCompleteFn
    userData*: pointer

  LogosAsyncCall* {.bycopy.} = object ## `logos_async_call_t`
    vtable*: ptr LogosAsyncCallVtable
    state*: pointer

  AsyncCallOp* = proc(call: ptr LogosAsyncCall) {.cdecl, gcsafe, raises: [].}

  LogosAsyncCallVtable* {.bycopy.} = object ## `logos_async_call_vtable_t`
    abiVersion*: uint32
    structSize*: csize_t
    submit*: AsyncCallOp
    cancel*: AsyncCallOp
    release*: AsyncCallOp

  LogosProviderInvocation* {.bycopy.} = object ## `logos_provider_invocation_t`
    abiVersion*: uint32
    structSize*: csize_t
    `method`*: cstring
    paramsCbor*: ptr UncheckedArray[uint8]
    paramsCborLen*: csize_t
    context*: ptr LogosInvocationContext
    complete*: proc(
      invocation: ptr LogosProviderInvocation,
      result: LogosResult,
      responseCbor: ptr UncheckedArray[uint8],
      responseCborLen: csize_t,
      owner: LogosResponseOwner,
    ) {.cdecl, gcsafe, raises: [].}
    executionRelease*:
      proc(invocation: ptr LogosProviderInvocation) {.cdecl, gcsafe, raises: [].}

  ProviderOp* = proc(
    module: ptr LogosModuleContext, invocation: ptr LogosProviderInvocation
  ) {.cdecl, gcsafe, raises: [].}

  LogosAsyncProviderApi* {.bycopy.} = object ## `logos_async_provider_api_t`
    abiVersion*: uint32
    structSize*: csize_t
    submit*: ProviderOp
    requestCancel*: ProviderOp ## optional

  LogosPublishFn* = proc(
    userData: pointer,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
  ) {.cdecl, gcsafe, raises: [].} ## `logos_publish_fn`

  LogosModuleInitInput* {.bycopy.} = object ## `logos_module_init_input_t`
    abiVersion*: uint32
    structSize*: csize_t
    runtimeControl*: ptr LogosRuntimeControlBinding
    publishUserData*: pointer
    publish*: LogosPublishFn
    stateDir*: cstring
    configurationCbor*: ptr UncheckedArray[uint8]
    configurationCborLen*: csize_t
    invocationAccess*: LogosInvocationAccess

  LogosSubscriptionId* = uint64 ## `logos_subscription_id_t`

  LogosEventHandler* = proc(
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
    userData: pointer,
  ) {.cdecl, gcsafe, raises: [].} ## `logos_event_handler_t`

  LogosRouteEndHandler* =
    proc(reason: CErrorCode, userData: pointer) {.cdecl, gcsafe, raises: [].}
    ## `logos_route_end_handler_t`

  LogosRuntimeControlBinding* {.bycopy.} = object ## `logos_runtime_control_binding_t`
    vtable*: ptr LogosRuntimeControlVtable
    state*: pointer

  LogosRouteHandle* {.bycopy.} = object ## `logos_route_handle_t`
    vtable*: ptr LogosRouteVtable
    state*: pointer

  ContractRoot* = array[32, uint8]

  LogosRuntimeControlVtable* {.bycopy.} = object ## `logos_runtime_control_vtable_t`
    abiVersion*: uint32
    structSize*: csize_t
    call*: proc(
      binding: ptr LogosRuntimeControlBinding,
      `method`: cstring,
      paramsCbor: ptr UncheckedArray[uint8],
      paramsCborLen: csize_t,
      outResponseCbor: ptr ptr UncheckedArray[uint8],
      outResponseCborLen: ptr csize_t,
    ): LogosResult {.cdecl, gcsafe, raises: [].}
    releaseResponse*: proc(
      binding: ptr LogosRuntimeControlBinding,
      responseCbor: ptr UncheckedArray[uint8],
      responseCborLen: csize_t,
    ) {.cdecl, gcsafe, raises: [].}
    subscribe*: proc(
      binding: ptr LogosRuntimeControlBinding,
      eventName: cstring,
      handler: LogosEventHandler,
      userData: pointer,
      outSubscriptionId: ptr LogosSubscriptionId,
    ): LogosResult {.cdecl, gcsafe, raises: [].}
    unsubscribe*: proc(
      binding: ptr LogosRuntimeControlBinding, subscriptionId: LogosSubscriptionId
    ): LogosResult {.cdecl, gcsafe, raises: [].}
    materializeRoute*: proc(
      binding: ptr LogosRuntimeControlBinding,
      routeId: cstring,
      expectedContractRoot: ptr ContractRoot,
      schemaCbor: ptr UncheckedArray[uint8],
      schemaCborLen: csize_t,
      outRoute: ptr LogosRouteHandle,
    ): LogosResult {.cdecl, gcsafe, raises: [].}
    connectRemote*: proc(
      binding: ptr LogosRuntimeControlBinding,
      endpointCbor: ptr UncheckedArray[uint8],
      endpointCborLen: csize_t,
      expectedContractRoot: ptr ContractRoot,
      outBinding: ptr LogosRuntimeControlBinding,
    ): LogosResult {.cdecl, gcsafe, raises: [].}
    release*:
      proc(binding: ptr LogosRuntimeControlBinding) {.cdecl, gcsafe, raises: [].}
    prepareCall*: proc(
      binding: ptr LogosRuntimeControlBinding,
      `method`: cstring,
      paramsCbor: ptr UncheckedArray[uint8],
      paramsCborLen: csize_t,
      options: ptr LogosAsyncOptions,
      callbacks: ptr LogosAsyncCallbacks,
      outCall: ptr LogosAsyncCall,
    ): LogosResult {.cdecl, gcsafe, raises: [].}

  LogosRouteVtable* {.bycopy.} = object ## `logos_route_vtable_t`
    abiVersion*: uint32
    structSize*: csize_t
    call*: proc(
      route: ptr LogosRouteHandle,
      `method`: cstring,
      paramsCbor: ptr UncheckedArray[uint8],
      paramsCborLen: csize_t,
      outResponseCbor: ptr ptr UncheckedArray[uint8],
      outResponseCborLen: ptr csize_t,
    ): LogosResult {.cdecl, gcsafe, raises: [].}
    releaseResponse*: proc(
      route: ptr LogosRouteHandle,
      responseCbor: ptr UncheckedArray[uint8],
      responseCborLen: csize_t,
    ) {.cdecl, gcsafe, raises: [].}
    subscribe*: proc(
      route: ptr LogosRouteHandle,
      eventName: cstring,
      handler: LogosEventHandler,
      userData: pointer,
      outSubscriptionId: ptr LogosSubscriptionId,
    ): LogosResult {.cdecl, gcsafe, raises: [].}
    unsubscribe*: proc(
      route: ptr LogosRouteHandle, subscriptionId: LogosSubscriptionId
    ): LogosResult {.cdecl, gcsafe, raises: [].}
    release*: proc(route: ptr LogosRouteHandle) {.cdecl, gcsafe, raises: [].}
    prepareCall*: proc(
      route: ptr LogosRouteHandle,
      `method`: cstring,
      paramsCbor: ptr UncheckedArray[uint8],
      paramsCborLen: csize_t,
      options: ptr LogosAsyncOptions,
      callbacks: ptr LogosAsyncCallbacks,
      outCall: ptr LogosAsyncCall,
    ): LogosResult {.cdecl, gcsafe, raises: [].}
    observeEnd*: proc(
      route: ptr LogosRouteHandle, handler: LogosRouteEndHandler, userData: pointer
    ): LogosResult {.cdecl, gcsafe, raises: [].}

template extentOf*(T: typedesc, last: untyped): int =
  ## The bytes a versioned struct needs to hold every field through `last`:
  ## its offset plus its size, so trailing padding is not required.
  offsetOf(T, last) + sizeof(default(T).last)

const
  InitInputV2Extent* = extentOf(LogosModuleInitInput, invocationAccess)
    ## [SPEC INTERFACE §5.2] the least `struct_size` of an ABI version 2 input
  RuntimeControlVtableV2Extent* = extentOf(LogosRuntimeControlVtable, prepareCall)
  RouteVtableV2Extent* = extentOf(LogosRouteVtable, observeEnd)
    ## includes the required `observe_end` (§5.2 l.3817)
  AsyncOptionsV1Extent* = extentOf(LogosAsyncOptions, timeoutMs)
  AsyncCallbacksV1Extent* = extentOf(LogosAsyncCallbacks, userData)
  AsyncCallVtableV1Extent* = extentOf(LogosAsyncCallVtable, release)
  ProviderInvocationV1Extent* = extentOf(LogosProviderInvocation, executionRelease)
  AsyncProviderApiV1Extent* = extentOf(LogosAsyncProviderApi, requestCancel)
  InvocationContextVtableV1Extent* = extentOf(LogosInvocationContextVtable, publish)
