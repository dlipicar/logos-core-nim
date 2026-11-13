## The engine's side of the Module Loader (plan 4b-1 §2.6, §2.8): the
## realization view the engine keeps for each instance, whichever mechanism
## made it.
##
## Two mechanisms realize module instances (DECISIONS I89):
## - the bootstrap mechanism (`realizer.nim` on the Runtime thread's
##   lifecycle workers) realizes the Module Loader instance itself, and
##   nothing else (BOOTSTRAP l.287-288, RUNTIME l.212);
## - the bound Module Loader realizes every other instance through its
##   contract.
##
## The view is engine-owned and read on the Runtime thread only. Route
## admission, evaluation, `describe_provider` and the binding checks read it,
## so one shape serves both mechanisms.

{.push raises: [].}

import results
import ../abi/types
import ../iface/[accept, outcome, provider]
import ../loader/[contract, logos_module_loader_types]
import ./[config, realizer]

export contract.LoaderMethod

type
  Mechanism* = enum
    mBootstrap ## the bootstrap mechanism: the Module Loader's own realization
    mLoader ## the bound Module Loader, through its contract

  ReplyKind* = enum
    ## What one Module Loader call gave, as the engine applies it.
    lrNone ## [IMPL] no reply yet; never produced by `readReply`
    lrFailed
      ## [SPEC LOADER l.633-634] the invocation failed: an Interface outcome,
      ## never a Loader error (`invocation`)
    lrInvalid
      ## [SPEC RUNTIME l.3823; plan §2.8] the response broke the contract or a
      ## check (`reason`): the Loader has failed
    lrError ## [SPEC LOADER §10] a typed Loader error (`error`)
    lrActive ## an active realization record (`record`, `contracts`)
    lrFailedRecord ## a retained failed realization record (`record`)
    lrSucceeded ## `release` or `apply_configuration` succeeded
    lrCapabilities ## `list_capabilities` (`capabilities`)

  LoaderReply* = object
    ## [IMPL] One reply as plain values, read and checked on the worker that
    ## made the call. Not a case object: Nim 2.2.14's `=wasMoved` (upstream
    ## issue 6, `plumbing.MsgKind`).
    kind*: ReplyKind
    invocation*: InvocationFailure
    reason*: string ## diagnostics only: what made the response invalid
    error*: LoaderError
    record*: RealizationRecord
    capabilities*: Capabilities

  RealizationView* = ref object
    ## [SPEC LOADER §7; RUNTIME §9.3] One realization the engine holds for an
    ## instance, with what the ABI caller handed over for it.
    mechanism*: Mechanism
    id*: string ## the realization id
    issuer*: string
      ## [SPEC RUNTIME l.3818-3822 (RUN-1069)] the Module Loader realization
      ## that issued it; empty for the bootstrap mechanism
    failed*: bool ## a retained failed record (an indeterminate live configuration)
    failure*: Opt[LoaderError] ## the typed error of a failed record
    provider*: bool ## the module exports the provider symbols
    callSurface*: seq[byte] ## the validated call surface bytes, as returned
    contracts*: ModuleBinding ## that surface, accepted by the engine
    declaresEvents*: bool ## an exposed contract declares an event
    dispatch*: ModuleDispatchFn
    free*: ModuleFreeFn
    asyncApi*: ptr LogosAsyncProviderApi ## nil: the synchronous provider ABI
    context*: ptr LogosModuleContext
    live*: bool ## [SPEC LOADER §8] its startup handoff declared live reconfiguration
    initCommitment*: Opt[SchemaRoots]
      ## [SPEC CONFIG §8 l.296] the commitment of the configuration it was
      ## initialized with
    unresolved*: bool
      ## [SPEC RUNTIME l.3823-3828] its cleanup ownership is kept after its
      ## Loader was lost or its answer could not be resolved: never used,
      ## never released in this process
    endpoint*: Opt[string]
      ## [SPEC LOADER §7] a hosted realization's endpoint; never set by the
      ## direct strategies (4b-3)

func viewOf*(r: Realization): RealizationView =
  ## The bootstrap mechanism's realization as the engine keeps it.
  let b = r.binding
  RealizationView(
    mechanism: mBootstrap,
    id: r.id,
    failed: r.status == rsFailed,
    failure:
      if r.status == rsFailed:
        Opt.some(r.failure)
      else:
        Opt.none(LoaderError),
    provider: b.provider,
    callSurface: b.callSurface,
    contracts: b.contracts,
    declaresEvents: b.declaresEvents,
    dispatch: b.dispatch,
    free: b.free,
    asyncApi: b.asyncApi,
    context: r.context,
    live: r.live,
    initCommitment: r.initCommitment,
  )

# Requests (on the Runtime thread) -----------------------------------------------------

type ContractInput =
  logos_module_loader_types.LogosNSModuleConfigurationConfigurationInput

func artifactOf(a: ArtifactRecord): LogosNSModuleLoaderArtifact =
  LogosNSModuleLoaderArtifact(
    id: a.id, local_path: a.localPath, hash: @(a.hash), hash_suite: a.hashSuite
  )

func descriptorOf(d: RealizationDescriptor): LogosNSModuleLoaderRealizationDescriptor =
  ## [SPEC LOADER §3] The accepted record's descriptor as the contract's.
  type K = LogosNSModuleLoaderRealizationDescriptorKind
  case d.strategy
  of stDirectStatic:
    LogosNSModuleLoaderRealizationDescriptor(
      kind: K.Direct_static,
      arm_Direct_static: LogosNSModuleLoaderRealizationDescriptorARDirectStaticMap(
        module: d.module,
        static_binding: LogosNSModuleLoaderStaticBinding(binding: d.binding),
      ),
    )
  of stDirectDynamic:
    LogosNSModuleLoaderRealizationDescriptor(
      kind: K.Direct_dynamic,
      arm_Direct_dynamic: LogosNSModuleLoaderRealizationDescriptorARDirectDynamicMap(
        module: d.module, artifact: artifactOf(d.artifact)
      ),
    )
  of stHostedDynamic:
    type P = LogosNSModuleLoaderHostedPlacementKind
    let placement =
      case d.placement
      of "sandbox": P.Sandbox
      of "container": P.Container
      else: P.Process
    LogosNSModuleLoaderRealizationDescriptor(
      kind: K.Hosted_dynamic,
      arm_Hosted_dynamic: LogosNSModuleLoaderRealizationDescriptorARHostedDynamicMap(
        module: d.module,
        artifact: artifactOf(d.artifact),
        placement: LogosNSModuleLoaderHostedPlacement(kind: placement),
      ),
    )

proc realizeBytes*(r: RealizeRequest): Result[seq[byte], string] =
  ## [SPEC LOADER §6] `realize_request` from the attempt's request: the
  ## descriptor of the accepted record, the state assignment and the
  ## configuration snapshot. The private handoffs go through the side table.
  var q = LogosNSModuleLoaderRealizeRequest(
    module_instance: r.moduleInstance, descriptor: descriptorOf(r.descriptor)
  )
  if r.state.isSome:
    q.state = Opt.some(LogosNSModuleLoaderStateContext(assignment: r.state.get))
  if r.configuration.isSome:
    let c = r.configuration.get
    let input = ContractInput.decode(c.input.bytesOf).valueOr:
      return err("the configuration input does not decode: " & error)
    var h = LogosNSModuleLoaderConfigurationHandoff(input: input)
    if c.live:
      h.live_reconfiguration = Opt.some(true)
    q.configuration = Opt.some(h)
  encode(q)

proc capabilitiesBytes*(): seq[byte] =
  encode(LogosNSModuleLoaderListCapabilitiesRequest()).expect("an empty map encodes")

proc statusBytes*(instance: string, id = Opt.none(string)): seq[byte] =
  encode(
    LogosNSModuleLoaderGetStatusRequest(module_instance: instance, realization: id)
  )
    .expect("a status request encodes")

proc releaseBytes*(instance, id: string): seq[byte] =
  encode(LogosNSModuleLoaderReleaseRequest(module_instance: instance, realization: id))
    .expect("a release request encodes")

proc applyBytes*(
    instance, id: string, input: openArray[byte]
): Result[seq[byte], string] =
  ## [SPEC LOADER §8] `apply_configuration_request` with the staged record's
  ## `configuration_input`.
  let c = ContractInput.decode(input).valueOr:
    return err("the configuration input does not decode: " & error)
  encode(
    LogosNSModuleLoaderApplyConfigurationRequest(
      module_instance: instance, realization: id, configuration: c
    )
  )

# Replies (on the worker that made the call) -------------------------------------------

func codeOf(c: LogosNSModuleLoaderErrorCode): LoaderErrorCode =
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

func errorOf(e: LogosNSModuleLoaderError): LoaderError =
  loaderError(codeOf(e.code), e.message.get(""))

func invalid(reason: string): LoaderReply =
  LoaderReply(kind: lrInvalid, reason: reason)

func failedRecord(
    f: LogosNSModuleLoaderFailedRealization, instance: string, id: Opt[string]
): LoaderReply =
  ## [SPEC LOADER §7] A failed record names the request's instance, and the
  ## request's realization when it named one; it carries no call surface.
  if f.module_instance != instance:
    return invalid("a failed record names another module instance")
  if id.isSome and f.realization != id.get:
    return invalid("a failed record names another realization")
  LoaderReply(
    kind: lrFailedRecord,
    record: RealizationRecord(
      realization: f.realization,
      moduleInstance: f.module_instance,
      status: rsFailed,
      failure: Opt.some(errorOf(f.failure)),
    ),
  )

proc activeRecord(
    a: LogosNSModuleLoaderActiveRealization, instance: string, id: Opt[string]
): LoaderReply =
  ## [SPEC LOADER §7, l.325] An active record names the request's instance;
  ## a direct realization has no provider endpoint.
  if a.module_instance != instance:
    return invalid("an active record names another module instance")
  if id.isSome and a.realization != id.get:
    return invalid("an active record names another realization")
  if a.provider_endpoint.isSome:
    return invalid("a direct realization names a provider endpoint")
  LoaderReply(
    kind: lrActive,
    record: RealizationRecord(
      realization: a.realization,
      moduleInstance: a.module_instance,
      status: rsActive,
      callSurface: a.call_surface,
    ),
  )

proc acceptSurface*(
    bytes: openArray[byte], module: string, system: bool
): Result[ModuleBinding, string] =
  ## [SPEC LOADER l.481-490; RUNTIME §2.4] An active record's call surface,
  ## accepted by the engine's own checks. [IMPL] On the Runtime thread, as
  ## the bootstrap mechanism's binding is (`realizer.storeBinding`): accepted
  ## contracts hold references shared with the thread's schema caches, which
  ## must not cross threads.
  let b = ?acceptCallSurfaceDescriptor(bytes, module, AcceptOptions(system: system))
  if not b.isProvider:
    return err("the call surface exposes no provider contract")
  ok(b)

proc readReply*(
    meth: LoaderMethod,
    instance: string,
    id: Opt[string],
    res: Result[seq[byte], InvocationFailure],
): LoaderReply =
  ## [SPEC LOADER §4-§9; plan §2.8] One response as plain values, checked
  ## against the request's `instance` and `id`.
  if res.isErr:
    return LoaderReply(kind: lrFailed, invocation: res.error)
  let bytes = res.get
  case meth
  of lmListCapabilities:
    let r = LogosNSModuleLoaderListCapabilitiesResponse.decode(bytes).valueOr:
      return invalid("the list_capabilities response does not decode")
    let c = r.capabilities
    var caps = Capabilities(
      directStatic: c.direct_static.get(false),
      directDynamic: c.direct_dynamic.get(false),
      forceRelease: c.force_release.get(false),
    )
    if c.hosted_dynamic.isSome:
      let h = c.hosted_dynamic.get
      if h.process.get(false):
        caps.hostedPlacements.add("process")
      if h.sandbox.get(false):
        caps.hostedPlacements.add("sandbox")
      if h.container.get(false):
        caps.hostedPlacements.add("container")
    LoaderReply(kind: lrCapabilities, capabilities: caps)
  of lmRealize:
    type K = LogosNSModuleLoaderRealizeResponseKind
    let r = LogosNSModuleLoaderRealizeResponse.decode(bytes).valueOr:
      return invalid("the realize response does not decode")
    case r.kind
    of K.Case0:
      LoaderReply(kind: lrError, error: errorOf(r.arm_0.error))
    of K.Case1:
      activeRecord(r.arm_1.realization, instance, id)
    of K.Case2:
      failedRecord(r.arm_2.realization, instance, id)
  of lmGetStatus:
    type K = LogosNSModuleLoaderGetStatusResponseKind
    type R = LogosNSModuleLoaderRealizationKind
    let r = LogosNSModuleLoaderGetStatusResponse.decode(bytes).valueOr:
      return invalid("the get_status response does not decode")
    case r.kind
    of K.Failed:
      LoaderReply(kind: lrError, error: errorOf(r.arm_Failed.error))
    of K.Succeeded:
      let x = r.arm_Succeeded.realization
      case x.kind
      of R.logos_NS_module_loader_Active_realization:
        activeRecord(x.arm_logos_NS_module_loader_Active_realization, instance, id)
      of R.logos_NS_module_loader_Failed_realization:
        failedRecord(x.arm_logos_NS_module_loader_Failed_realization, instance, id)
  of lmApplyConfiguration:
    type K = LogosNSModuleLoaderApplyConfigurationResponseKind
    let r = LogosNSModuleLoaderApplyConfigurationResponse.decode(bytes).valueOr:
      return invalid("the apply_configuration response does not decode")
    case r.kind
    of K.Case0:
      LoaderReply(kind: lrSucceeded)
    of K.Case1:
      LoaderReply(kind: lrError, error: errorOf(r.arm_1.error))
    of K.Case2:
      failedRecord(r.arm_2.realization, instance, id)
  of lmRelease:
    type K = LogosNSModuleLoaderReleaseResponseKind
    let r = LogosNSModuleLoaderReleaseResponse.decode(bytes).valueOr:
      return invalid("the release response does not decode")
    case r.kind
    of K.Case0:
      LoaderReply(kind: lrSucceeded)
    of K.Case1:
      LoaderReply(kind: lrError, error: errorOf(r.arm_1.error))
    of K.Case2:
      failedRecord(r.arm_2.realization, instance, id)
