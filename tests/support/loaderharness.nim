## A Runtime stand-in for contract-level tests of the Module Loader (Tier 4b
## step 4b-1; DECISIONS I89): it plays the engine's part. It keeps a side
## table, wires the Loader and realizes it through a bootstrap realizer whose
## only registration is the Loader's own, puts an inbound handoff (a stub
## Runtime Control binding, a publish callback that records and the Runtime's
## invocation access) before each `realize` and withdraws it after, and calls
## the Loader through its generic dispatch with a SYSTEM_SERVICE invocation
## context current (`invoke.systemCall`), a module caller's or none.
##
## Calls may come from any thread: `LoaderCall` is plain values. Teardown
## releases what the harness realized and is still held, then destroys the
## Loader, which joins its thread.

import std/[atomics, sets]
import results
import ../../src/logos_core/abi/[checks, types]
import ../../src/logos_core/iface/outcome
import ../../src/logos_core/runtime/[callside, invoke, plumbing]
import ../../src/logos_core/loader/[provider, logos_module_loader_types]
from ./kitruntime import armed, rcBinding, publishOp, publishState

export results, checks, types, outcome, provider, logos_module_loader_types, atomics

const HarnessRuntime* = "rt-loader-test"

var
  loaderRcVtable = armed(
    LogosRuntimeControlVtable(
      abiVersion: 2, structSize: csize_t(sizeof(LogosRuntimeControlVtable))
    )
  )
  loaderRcState: byte
  loaderRc =
    LogosRuntimeControlBinding(vtable: addr loaderRcVtable, state: addr loaderRcState)
    ## the Loader's own Runtime Control binding: the wiring key
  loaderAccess*: byte ## the Loader's invocation-access state
  targetAccess*: byte ## the targets' invocation-access state

type
  CallerAs* = enum
    asSystem ## the Runtime's SYSTEM_SERVICE call
    asModule ## a module caller, as a route would make
    asNone ## no invocation context at all

  LoaderCall* = object ## How to reach the Loader from any thread: plain values.
    dispatch*: ModuleDispatchFn
    free*: ModuleFreeFn
    context*: ptr LogosModuleContext

  LoaderHarness* = object
    boot*: Realizer ## the bootstrap mechanism: only the Loader's registration
    loader*: Realization
    side*: SideTable
    at*: LoaderCall
    realized: HashSet[string] ## instances the harness realized

proc targetServices*(publish = true): InboundHandoff =
  ## The inbound handoff a target instance gets: the stub Runtime Control
  ## binding (every operation fails the test), a recording publish callback
  ## and the Runtime's invocation access (`callside.currentOp`).
  InboundHandoff(
    runtimeControl: addr rcBinding,
    publish: (if publish: publishOp else: nil),
    publishUserData: addr publishState,
    invocationAccess:
      LogosInvocationAccess(state: addr targetAccess, current: callside.currentOp),
  )

proc openHarness*(
    statics: seq[StaticRegistration], workDir: string, stateRoot = Opt.none(string)
): Result[LoaderHarness, string] =
  ## Wires and realizes a Loader that may realize `statics`.
  var h = LoaderHarness(side: newSideTable())
  ?wireLoader(
    addr loaderRc,
    LoaderWiring(statics: statics, workDir: workDir, stateRoot: stateRoot, side: h.side),
  )
  h.boot = newRealizer(workDir)
  ?h.boot.registerStatic(loaderStaticRegistration())
  let x = h.boot.realize(
    RealizeRequest(
      moduleInstance: LoaderInstanceId,
      descriptor: RealizationDescriptor(
        strategy: stDirectStatic, module: LoaderModuleName, binding: LoaderBindingId
      ),
      services: InitServices(
        runtimeControl: addr loaderRc,
        publish: publishOp,
        publishUserData: addr publishState,
        invocationAccess:
          LogosInvocationAccess(state: addr loaderAccess, current: callside.currentOp),
      ),
    )
  )
  if x.isErr:
    unwireLoader(addr loaderRc)
    freeSideTable(h.side)
    return err(x.error.message)
  h.loader = x.get
  h.at = LoaderCall(
    dispatch: x.get.binding.dispatch, free: x.get.binding.free, context: x.get.context
  )
  ok(h)

proc call*(
    at: LoaderCall,
    bare: string,
    params: openArray[byte],
    caller = asSystem,
    ticket: ptr CallTicket = nil,
): Result[seq[byte], InvocationFailure] {.gcsafe.} =
  ## One call of the Loader's method `bare` from this thread.
  case caller
  of asSystem:
    systemCall(
      nil,
      at.dispatch,
      at.free,
      at.context,
      addr loaderAccess,
      ticket,
      HarnessRuntime,
      bare,
      params,
    )
  of asModule, asNone:
    var inv = InvocationState(
      access: addr loaderAccess,
      ticket: ticket,
      runtimeId: fixed(HarnessRuntime),
      consumer: fixed("intruder"),
    )
    initContext(inv)
    var f = Frame(context: addr inv.context, access: addr loaderAccess)
    if caller == asModule:
      push(f)
    var buf: ptr UncheckedArray[uint8] = nil
    var len: csize_t = 0
    let r = at.dispatch(
      at.context,
      cstring(bare),
      cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
      csize_t(params.len),
      addr buf,
      addr len,
    )
    if caller == asModule:
      pop(f)
    checkOutcome(r, bufferShape(buf, len)).isOkOr:
      if buf != nil:
        at.free(at.context, buf)
      return err(InvocationFailure(code: error.code, message: error.message))
    var bytes = newSeq[byte](int(len))
    for i in 0 ..< int(len):
      bytes[i] = buf[i]
    at.free(at.context, buf)
    ok(bytes)

proc typed*[Q, T](
    at: LoaderCall, bare: string, request: Q, R: typedesc[T], caller = asSystem
): Result[T, InvocationFailure] =
  ## One call with `request` encoded and the response decoded as `R`.
  let bytes = ?at.call(bare, encode(request).get, caller)
  let r = R.decode(bytes)
  doAssert r.isOk, "the Loader's response does not decode: " & r.error
  ok(r.get)

func codeOf*(c: LogosNSModuleLoaderErrorCode): LoaderErrorCode =
  type K = LogosNSModuleLoaderErrorCodeKind
  case c.kind
  of K.Invalid_request: lecInvalidRequest
  of K.Unsupported_strategy: lecUnsupportedStrategy
  of K.Artifact_unavailable: lecArtifactUnavailable
  of K.Artifact_integrity_failed: lecArtifactIntegrityFailed
  of K.Abi_invalid: lecAbiInvalid
  of K.Realization_failed: lecRealizationFailed
  of K.Instance_conflict: lecInstanceConflict
  of K.Realization_not_found: lecRealizationNotFound
  of K.Configuration_rejected: lecConfigurationRejected

# Descriptors and requests -----------------------------------------------------------

proc staticDescriptor*(
    module, binding: string
): LogosNSModuleLoaderRealizationDescriptor =
  LogosNSModuleLoaderRealizationDescriptor(
    kind: LogosNSModuleLoaderRealizationDescriptorKind.Direct_static,
    arm_Direct_static: LogosNSModuleLoaderRealizationDescriptorARDirectStaticMap(
      module: module, static_binding: LogosNSModuleLoaderStaticBinding(binding: binding)
    ),
  )

proc realizeRequest*(
    instance: string,
    d: LogosNSModuleLoaderRealizationDescriptor,
    state = Opt.none(string),
): LogosNSModuleLoaderRealizeRequest =
  result = LogosNSModuleLoaderRealizeRequest(module_instance: instance, descriptor: d)
  if state.isSome:
    result.state = Opt.some(LogosNSModuleLoaderStateContext(assignment: state.get))

type Realized* = object ## One `realize` as the harness saw it.
  response*: Result[LogosNSModuleLoaderRealizeResponse, InvocationFailure]
  phase*: Opt[FailedPhase] ## what the inbound entry said when it was withdrawn

proc realizeAs*(
    h: var LoaderHarness,
    request: LogosNSModuleLoaderRealizeRequest,
    services = Opt.some(targetServices()),
    caller = asSystem,
): Realized =
  ## Puts the inbound handoff (none when `services` is none), calls
  ## `realize`, then withdraws the handoff.
  let instance = request.module_instance
  if services.isSome:
    doAssert h.side.putInbound(instance, services.get).isOk
  result.response =
    h.at.typed("realize", request, LogosNSModuleLoaderRealizeResponse, caller)
  result.phase = h.side.withdrawInbound(instance)
  h.realized.incl instance

proc realize*(
    h: var LoaderHarness,
    instance, module, binding: string,
    state = Opt.none(string),
    publish = true,
): Realized =
  h.realizeAs(
    realizeRequest(instance, staticDescriptor(module, binding), state),
    Opt.some(targetServices(publish)),
  )

func active*(
    r: LogosNSModuleLoaderRealizeResponse
): Opt[LogosNSModuleLoaderActiveRealization] =
  if r.kind == LogosNSModuleLoaderRealizeResponseKind.Case1:
    return Opt.some(r.arm_1.realization)
  Opt.none(LogosNSModuleLoaderActiveRealization)

func errorCode*(r: LogosNSModuleLoaderRealizeResponse): Opt[LoaderErrorCode] =
  if r.kind != LogosNSModuleLoaderRealizeResponseKind.Case0:
    return Opt.none(LoaderErrorCode)
  Opt.some(codeOf(r.arm_0.error.code))

func errorOf*(r: LogosNSModuleLoaderRealizeResponse): LogosNSModuleLoaderError =
  doAssert r.kind == LogosNSModuleLoaderRealizeResponseKind.Case0
  r.arm_0.error

proc status*(
    h: LoaderHarness, instance: string, realization = Opt.none(string)
): LogosNSModuleLoaderGetStatusResponse =
  h.at.typed(
    "get_status",
    LogosNSModuleLoaderGetStatusRequest(
      module_instance: instance, realization: realization
    ),
    LogosNSModuleLoaderGetStatusResponse,
  ).get

func found*(
    s: LogosNSModuleLoaderGetStatusResponse
): Opt[LogosNSModuleLoaderRealization] =
  if s.kind == LogosNSModuleLoaderGetStatusResponseKind.Succeeded:
    return Opt.some(s.arm_Succeeded.realization)
  Opt.none(LogosNSModuleLoaderRealization)

func statusError*(s: LogosNSModuleLoaderGetStatusResponse): Opt[LoaderErrorCode] =
  if s.kind == LogosNSModuleLoaderGetStatusResponseKind.Failed:
    return Opt.some(codeOf(s.arm_Failed.error.code))
  Opt.none(LoaderErrorCode)

proc release*(
    h: LoaderHarness, realization, instance: string, force = Opt.none(bool)
): LogosNSModuleLoaderReleaseResponse =
  h.at.typed(
    "release",
    LogosNSModuleLoaderReleaseRequest(
      module_instance: instance, realization: realization, force: force
    ),
    LogosNSModuleLoaderReleaseResponse,
  ).get

func released*(r: LogosNSModuleLoaderReleaseResponse): bool =
  r.kind == LogosNSModuleLoaderReleaseResponseKind.Case0

func releaseError*(r: LogosNSModuleLoaderReleaseResponse): Opt[LoaderErrorCode] =
  if r.kind == LogosNSModuleLoaderReleaseResponseKind.Case1:
    return Opt.some(codeOf(r.arm_1.error.code))
  Opt.none(LoaderErrorCode)

proc liveCount*(h: LoaderHarness): int =
  loaderLive(h.at.context)

proc close*(h: var LoaderHarness) =
  ## Releases what is still held, destroys the Loader (joining its thread),
  ## then unwires it and frees the side table. Nothing when it is closed.
  if h.side == nil:
    return
  for instance in h.realized:
    let s = h.status(instance).found
    if s.isSome:
      let id =
        if s.get.kind ==
            LogosNSModuleLoaderRealizationKind.logos_NS_module_loader_Active_realization:
          s.get.arm_logos_NS_module_loader_Active_realization.realization
        else:
          s.get.arm_logos_NS_module_loader_Failed_realization.realization
      discard h.release(id, instance)
  h.realized.clear()
  if h.loader != nil:
    discard h.boot.release(h.loader.id, LoaderInstanceId)
    h.loader = nil
  unwireLoader(addr loaderRc)
  freeSideTable(h.side)
  h.side = nil
