## The Module Loader as a module (Tier 4b step 4b-1; DECISIONS I89): the
## `direct_static` module `logos_module_loader` (LOADER l.35), built with its
## lcn-gen kit over `core.nim`, and the protected wiring that gives an instance
## its deployment input (LOADER l.676-677).
##
## - **Wiring.** `wireLoader(key, wiring)` records, in shared memory, the static
##   registrations the Loader may realize (never its own: bootstrap is
##   non-recursive, BCP l.287), its private artifact and state roots and the
##   engine's side table. The key is the address of the Runtime Control
##   binding the bootstrap mechanism gives the Loader's attempt: engine-owned,
##   unique per attempt and not a value any module supplies. `_MODULE_init`
##   looks its wiring up by that binding; none fails init MODULE_ERROR.
## - **Caller** ([IMPL-DECISION G251]). Every method serves only a
##   SYSTEM_SERVICE caller: the Runtime's own call through its binding
##   (RUNTIME l.1652-1667). A module caller, or an invocation context that
##   names none, is NOT_AUTHORISED before the handler acts, and nothing
##   changes. (The kit checks the request against its schema first, which
##   changes nothing either: an undecodable request is INVALID_PARAMS,
##   INTERFACE l.3123-3124.) The engine refuses every route to the Loader, so
##   no module can call it; this is the second half of that rule.
## - **Target code** (`runBind`, `_MODULE_init`, `_MODULE_destroy`,
##   `_MODULE_apply_configuration`) runs on the calling thread behind
##   `callside.barrier`, so it never sees the invocation context of the
##   Loader's call (INTERFACE l.2170, by analogy with event handlers).
## - **Cancellation.** A `realize` whose invocation is cancelled before the
##   target's `_MODULE_init` creates nothing and fails CANCELLED, an Interface
##   outcome, never a Loader error (LOADER l.633-634).
## - **Private handoffs** come only from the side table (`runtime/sidetable`,
##   D14): a `realize` for an instance the Runtime put no handoff for is
##   `invalid-request` (LOADER l.427).

{.push raises: [], gcsafe.}

import std/[locks, tables]
import results
import ../abi/checks
import ../runtime/[config, native]
from ../runtime/callside import barrier, push, pop, Frame
import ../hash/hashinput
import ./[contract, core, logos_module_loader_kit]
import ../base/testhooks

export core, native, contract

testHooksMarker("loader")

# Wiring -------------------------------------------------------------------------------

type
  LoaderWiring* = object ## The protected deployment input of one Loader instance.
    statics*: seq[StaticRegistration]
      ## what it may realize: the host's static registrations and the
      ## Capability Authority's, never the Loader's own
    workDir*: string ## its private directory for verified library copies
    stateRoot*: Opt[string] ## the module state directories, one per assignment
    side*: SideTable

  SharedSymbol = object
    name: cstring
    address: pointer

  SharedStatic = object
    binding: cstring
    module: cstring
    system: bool
    symbols: ptr UncheckedArray[SharedSymbol]
    count: int

  WiringEntry = object ## One wiring, in shared memory: read from any thread.
    key: pointer
    statics: ptr UncheckedArray[SharedStatic]
    staticCount: int
    workDir: cstring
    stateRoot: cstring ## nil: none
    side: SideTable
    next: ptr WiringEntry

var wiringLock: Lock
var wirings: ptr WiringEntry
initLock(wiringLock)

proc sharedText(s: string): cstring =
  let p = cast[cstring](allocShared0(s.len + 1))
  if s.len > 0:
    copyMem(p, unsafeAddr s[0], s.len)
  p

proc freeEntry(e: ptr WiringEntry) =
  for i in 0 ..< e.staticCount:
    let s = addr e.statics[i]
    deallocShared(s.binding)
    deallocShared(s.module)
    for k in 0 ..< s.count:
      deallocShared(s.symbols[k].name)
    if s.symbols != nil:
      deallocShared(s.symbols)
  if e.statics != nil:
    deallocShared(e.statics)
  deallocShared(e.workDir)
  if e.stateRoot != nil:
    deallocShared(e.stateRoot)
  deallocShared(e)

proc wireLoader*(key: pointer, w: LoaderWiring): Result[void, string] =
  ## Records the wiring of the Loader instance whose attempt received the
  ## Runtime Control binding at `key`. A second wiring of one key is refused.
  if key == nil:
    return err("the wiring key is null")
  if w.side == nil:
    return err("the wiring has no side table")
  for reg in w.statics:
    if reg.binding == LoaderBindingId or reg.module == LoaderModuleName:
      return err("the Module Loader cannot realize itself")
  let e = cast[ptr WiringEntry](allocShared0(sizeof(WiringEntry)))
  e.key = key
  e.side = w.side
  e.workDir = sharedText(w.workDir)
  if w.stateRoot.isSome:
    e.stateRoot = sharedText(w.stateRoot.get)
  e.staticCount = w.statics.len
  if w.statics.len > 0:
    e.statics = cast[ptr UncheckedArray[SharedStatic]](allocShared0(
      sizeof(SharedStatic) * w.statics.len
    ))
    for i, reg in w.statics:
      let s = addr e.statics[i]
      s.binding = sharedText(reg.binding)
      s.module = sharedText(reg.module)
      s.system = reg.system
      s.count = reg.symbols.len
      if s.count > 0:
        s.symbols = cast[ptr UncheckedArray[SharedSymbol]](allocShared0(
          sizeof(SharedSymbol) * s.count
        ))
        var k = 0
        for name, address in reg.symbols:
          s.symbols[k] = SharedSymbol(name: sharedText(name), address: address)
          inc k
  var taken = false
  withLock wiringLock:
    var p = wirings
    while p != nil:
      if p.key == key:
        taken = true
        break
      p = p.next
    if not taken:
      e.next = wirings
      wirings = e
  if taken:
    freeEntry(e)
    return err("the key is already wired")
  ok()

proc unwireLoader*(key: pointer) =
  ## Forgets the wiring at `key`. A Loader already started keeps its copy.
  var gone: ptr WiringEntry
  withLock wiringLock:
    var p = addr wirings
    while p[] != nil:
      if p[].key == key:
        gone = p[]
        p[] = gone.next
        break
      p = addr p[].next
  if gone != nil:
    freeEntry(gone)

proc readWiring(key: pointer): Opt[LoaderWiring] =
  withLock wiringLock:
    var p = wirings
    while p != nil:
      if p.key == key:
        var w = LoaderWiring(workDir: $p.workDir, side: p.side)
        if p.stateRoot != nil:
          w.stateRoot = Opt.some($p.stateRoot)
        for i in 0 ..< p.staticCount:
          let s = addr p.statics[i]
          var reg =
            StaticRegistration(binding: $s.binding, module: $s.module, system: s.system)
          for k in 0 ..< s.count:
            reg.symbols[$s.symbols[k].name] = s.symbols[k].address
          w.statics.add reg
        return Opt.some(w)
      p = p.next
  Opt.none(LoaderWiring)

# The module ---------------------------------------------------------------------------

type RecordResult = Result[RealizationRecord, LoaderError]

type LoaderModule* = ref object
  ## One Loader instance: its thread and the services it was given.
  core: LoaderCore
  services: ModuleServices
  side: SideTable

const NotWired = "the Module Loader has no protected wiring"

proc initModule(
    _: type LoaderModule, init: ModuleInit
): Result[LoaderModule, InvocationFailure] =
  let w = readWiring(init.services.runtimeControl).valueOr:
    return err(moduleError(NotWired))
  let c = openCore(
    CoreConfig(
      statics: w.statics, workDir: w.workDir, stateRoot: w.stateRoot, side: w.side
    )
  ).valueOr:
    return err(moduleError("the Module Loader does not start: " & error))
  ok(LoaderModule(core: c, services: init.services, side: w.side))

proc destroyModule(m: LoaderModule) =
  ## Stops and joins the Loader's thread.
  closeCore(m.core)

proc refusal(m: LoaderModule): Opt[InvocationFailure] =
  ## [IMPL-DECISION G251] Only the Runtime's SYSTEM_SERVICE call is served.
  let c = m.services.caller()
  if c.isOk and c.get.kind == ckSystemService:
    return Opt.none(InvocationFailure)
  Opt.some(failure(ecNotAuthorised, "the Module Loader serves only the Runtime"))

template served(m: LoaderModule) =
  let refused = m.refusal()
  if refused.isSome:
    return err(refused.get)

when defined(lcnTestHooks):
  proc journal(m: LoaderModule, meth: LoaderMethod, instance = "", realization = "") =
    ## A test hook (plan §2.12): a request served, in the side table's journal.
    m.side.journal(
      JournalEntry(meth: $meth, instance: instance, realization: realization)
    )

  proc journal(m: LoaderModule, request: LogosNSModuleLoaderRealizeRequest) =
    type K = LogosNSModuleLoaderRealizationDescriptorKind
    let d = request.descriptor
    var e = JournalEntry(meth: $lmRealize, instance: request.module_instance)
    case d.kind
    of K.Direct_static:
      e.strategy = "direct_static"
      e.module = d.arm_Direct_static.module
      e.source = d.arm_Direct_static.static_binding.binding
    of K.Direct_dynamic:
      e.strategy = "direct_dynamic"
      e.module = d.arm_Direct_dynamic.module
      e.source = d.arm_Direct_dynamic.artifact.id
    of K.Hosted_dynamic:
      e.strategy = "hosted_dynamic"
      e.module = d.arm_Hosted_dynamic.module
      e.source = d.arm_Hosted_dynamic.artifact.id
    m.side.journal(e)

# Values -------------------------------------------------------------------------------

func codeOf(c: LoaderErrorCode): LogosNSModuleLoaderErrorCode =
  type K = LogosNSModuleLoaderErrorCodeKind
  let k =
    case c
    of lecInvalidRequest: K.Invalid_request
    of lecUnsupportedStrategy: K.Unsupported_strategy
    of lecArtifactUnavailable: K.Artifact_unavailable
    of lecArtifactIntegrityFailed: K.Artifact_integrity_failed
    of lecAbiInvalid: K.Abi_invalid
    of lecRealizationFailed: K.Realization_failed
    of lecInstanceConflict: K.Instance_conflict
    of lecRealizationNotFound: K.Realization_not_found
    of lecConfigurationRejected: K.Configuration_rejected
  LogosNSModuleLoaderErrorCode(kind: k)

func errorOf*(e: LoaderError): LogosNSModuleLoaderError =
  ## [SPEC LOADER §10] The contract error: the code and the message, which
  ## names no host path; the module's own status stays out (`cause`).
  result.code = codeOf(e.code)
  if e.message.len > 0:
    result.message = Opt.some(e.message)

func failedOf(x: RealizationRecord): LogosNSModuleLoaderFailedRealization =
  LogosNSModuleLoaderFailedRealization(
    realization: x.realization,
    module_instance: x.moduleInstance,
    failure: errorOf(
      x.failure.get(loaderError(lecRealizationFailed, "the realization failed"))
    ),
  )

func activeOf(x: RealizationRecord): LogosNSModuleLoaderActiveRealization =
  ## [SPEC LOADER §7] A direct realization has no provider endpoint (l.325).
  LogosNSModuleLoaderActiveRealization(
    realization: x.realization,
    module_instance: x.moduleInstance,
    call_surface: x.callSurface,
  )

func realizationOf(x: RealizationRecord): LogosNSModuleLoaderRealization =
  type K = LogosNSModuleLoaderRealizationKind
  case x.status
  of rsActive:
    LogosNSModuleLoaderRealization(
      kind: K.logos_NS_module_loader_Active_realization,
      arm_logos_NS_module_loader_Active_realization: activeOf(x),
    )
  of rsFailed:
    LogosNSModuleLoaderRealization(
      kind: K.logos_NS_module_loader_Failed_realization,
      arm_logos_NS_module_loader_Failed_realization: failedOf(x),
    )

func realizeResponse(
    r: Result[RealizationRecord, LoaderError]
): LogosNSModuleLoaderRealizeResponse =
  type K = LogosNSModuleLoaderRealizeResponseKind
  if r.isErr:
    return LogosNSModuleLoaderRealizeResponse(
      kind: K.Case0,
      arm_0: LogosNSModuleLoaderRealizeResponseAR0Map(error: errorOf(r.error)),
    )
  let x = r.get
  case x.status
  of rsActive:
    LogosNSModuleLoaderRealizeResponse(
      kind: K.Case1,
      arm_1: LogosNSModuleLoaderRealizeResponseAR1Map(realization: activeOf(x)),
    )
  of rsFailed:
    LogosNSModuleLoaderRealizeResponse(
      kind: K.Case2,
      arm_2: LogosNSModuleLoaderRealizeResponseAR2Map(realization: failedOf(x)),
    )

proc digestOf(b: seq[byte]): Opt[Digest] =
  if b.len != 32:
    return Opt.none(Digest)
  var d: Digest
  for i in 0 ..< 32:
    d[i] = b[i]
  Opt.some(d)

func placementText(p: LogosNSModuleLoaderHostedPlacement): string =
  type K = LogosNSModuleLoaderHostedPlacementKind
  case p.kind
  of K.Process: "process"
  of K.Sandbox: "sandbox"
  of K.Container: "container"

proc artifactOf(a: LogosNSModuleLoaderArtifact): Result[ArtifactRecord, LoaderError] =
  var r = ArtifactRecord(id: a.id, localPath: a.local_path, hashSuite: a.hash_suite)
  if a.hash.len != r.hash.len:
    return err(loaderError(lecInvalidRequest, "artifact.hash has 32 bytes"))
  for i in 0 ..< a.hash.len:
    r.hash[i] = a.hash[i]
  ok(r)

proc descriptorOf(
    d: LogosNSModuleLoaderRealizationDescriptor
): Result[RealizationDescriptor, LoaderError] =
  type K = LogosNSModuleLoaderRealizationDescriptorKind
  case d.kind
  of K.Direct_static:
    ok(
      RealizationDescriptor(
        strategy: stDirectStatic,
        module: d.arm_Direct_static.module,
        binding: d.arm_Direct_static.static_binding.binding,
      )
    )
  of K.Direct_dynamic:
    let artifact = ?artifactOf(d.arm_Direct_dynamic.artifact)
    ok(
      RealizationDescriptor(
        strategy: stDirectDynamic,
        module: d.arm_Direct_dynamic.module,
        artifact: artifact,
      )
    )
  of K.Hosted_dynamic:
    let artifact = ?artifactOf(d.arm_Hosted_dynamic.artifact)
    ok(
      RealizationDescriptor(
        strategy: stHostedDynamic,
        module: d.arm_Hosted_dynamic.module,
        artifact: artifact,
        placement: placementText(d.arm_Hosted_dynamic.placement),
      )
    )

proc configurationOf(
    h: LogosNSModuleLoaderConfigurationHandoff
): Result[ConfigurationHandoff, LoaderError] =
  ## [SPEC LOADER l.304; CONFIG §6] The handoff's input, encoded again
  ## deterministically: the bytes `_MODULE_init` receives.
  let c = h.input.schema_commitment
  let schemaRoot = digestOf(c.schema_root).valueOr:
    return err(loaderError(lecInvalidRequest, "the schema root has 32 bytes"))
  let subtreeRoot = digestOf(c.schema_subtree_root).valueOr:
    return err(loaderError(lecInvalidRequest, "the subtree root has 32 bytes"))
  let roots = SchemaRoots(schemaRoot: schemaRoot, subtreeRoot: subtreeRoot)
  let bytes = encode(h.input).valueOr:
    return
      err(loaderError(lecInvalidRequest, "the configuration input does not encode"))
  ok(
    ConfigurationHandoff(
      input: newBlob(bytes),
      live: h.live_reconfiguration.get(false),
      commitment: roots,
      valueRevision: h.input.value_revision,
    )
  )

# Handlers -----------------------------------------------------------------------------

proc `list_capabilities`(
    m: LoaderModule, request: LogosNSModuleLoaderListCapabilitiesRequest
): Result[LogosNSModuleLoaderListCapabilitiesResponse, InvocationFailure] =
  ## [SPEC LOADER §4] The strategies of its drivers; `force_release` never
  ## (K7, K10).
  m.served()
  when defined(lcnTestHooks):
    m.journal(lmListCapabilities)
  let c = m.core.capabilities().valueOr:
    return err(moduleError(ClosingText))
  var caps = LogosNSModuleLoaderCapabilities()
  if c.directStatic:
    caps.direct_static = Opt.some(true)
  if c.directDynamic:
    caps.direct_dynamic = Opt.some(true)
  if c.hostedPlacements.len > 0:
    var h = LogosNSModuleLoaderCapabilitiesHostedDynamicMap()
    for p in c.hostedPlacements:
      case p
      of "process":
        h.process = Opt.some(true)
      of "sandbox":
        h.sandbox = Opt.some(true)
      of "container":
        h.container = Opt.some(true)
      else:
        discard
    caps.hosted_dynamic = Opt.some(h)
  ok(LogosNSModuleLoaderListCapabilitiesResponse(capabilities: caps))

proc runInit(
    m: LoaderModule, instance: string, call: InitCall
): Result[LogosNSModuleLoaderRealizeResponse, InvocationFailure] =
  ## [SPEC LOADER §6 step 8] `_MODULE_init` on this thread, behind the
  ## barrier; an orphan is destroyed here before the error returns.
  var res: LogosResult
  var ctx: ptr LogosModuleContext
  var outcome: AbiCheck
  var returnedOk: bool
  barrier:
    (res, ctx) = initModule(call.init, call.input)
    (outcome, returnedOk) = checkInit(res, ctx)
  let reply = m.core.initDone(instance, outcome, returnedOk, ctx)
  if reply.orphan.isSome:
    let t = reply.orphan.get
    barrier:
      t.destroy(t.context)
  ok(realizeResponse(reply.outcome))

proc `realize`(
    m: LoaderModule, request: LogosNSModuleLoaderRealizeRequest
): Result[LogosNSModuleLoaderRealizeResponse, InvocationFailure] =
  ## [SPEC LOADER §6] Every phase that runs module code runs here; the
  ## Loader's thread keeps the state between them.
  m.served()
  when defined(lcnTestHooks):
    m.journal(request)
  let instance = request.module_instance
  let descriptor = descriptorOf(request.descriptor).valueOr:
    return ok(realizeResponse(RecordResult.err(error)))
  var req = RealizeRequest(moduleInstance: instance, descriptor: descriptor)
  if request.state.isSome:
    req.state = Opt.some(request.state.get.assignment)
  let handoff = m.side.inbound(instance)
  if handoff.isSome:
    let h = handoff.get
    req.services = InitServices(
      runtimeControl: h.runtimeControl,
      publish: h.publish,
      publishUserData: h.publishUserData,
      invocationAccess: h.invocationAccess,
    )
  if request.configuration.isSome:
    let c = configurationOf(request.configuration.get).valueOr:
      return ok(realizeResponse(RecordResult.err(error)))
    req.configuration = Opt.some(c)
  var step = m.core.beginRealize(req, handoff.isSome)
  while true:
    case step.kind
    of pkDone:
      return ok(realizeResponse(step.outcome))
    of pkBind:
      if m.services.isCancelled():
        m.core.abandon(instance)
        return err(failure(ecCancelled, "the realize was cancelled"))
      var res: BindResult
      barrier:
        res = runBind(step.spec)
      step = m.core.bound(instance, res)
    of pkInit:
      if m.services.isCancelled():
        m.core.abandon(instance)
        return err(failure(ecCancelled, "the realize was cancelled"))
      return m.runInit(instance, step.call)

proc `get_status`(
    m: LoaderModule, request: LogosNSModuleLoaderGetStatusRequest
): Result[LogosNSModuleLoaderGetStatusResponse, InvocationFailure] =
  ## [SPEC LOADER §7] `realization-not-found` discloses nothing (l.505).
  m.served()
  when defined(lcnTestHooks):
    m.journal(lmGetStatus, request.module_instance, request.realization.get(""))
  type K = LogosNSModuleLoaderGetStatusResponseKind
  let r = m.core.status(request.module_instance, request.realization)
  if r.isErr:
    return ok(
      LogosNSModuleLoaderGetStatusResponse(
        kind: K.Failed,
        arm_Failed:
          LogosNSModuleLoaderGetStatusResponseARFailedMap(error: errorOf(r.error)),
      )
    )
  ok(
    LogosNSModuleLoaderGetStatusResponse(
      kind: K.Succeeded,
      arm_Succeeded: LogosNSModuleLoaderGetStatusResponseARSucceededMap(
        realization: realizationOf(r.get)
      ),
    )
  )

proc `apply_configuration`(
    m: LoaderModule, request: LogosNSModuleLoaderApplyConfigurationRequest
): Result[LogosNSModuleLoaderApplyConfigurationResponse, InvocationFailure] =
  ## [SPEC LOADER §8, §11] The hook once, through the retained context,
  ## excluded from release. An indeterminate outcome leaves the realization
  ## failed, owned until its release.
  m.served()
  when defined(lcnTestHooks):
    m.journal(lmApplyConfiguration, request.module_instance, request.realization)
  type K = LogosNSModuleLoaderApplyConfigurationResponseKind
  template failed(e: LoaderError): untyped =
    LogosNSModuleLoaderApplyConfigurationResponse(
      kind: K.Case1,
      arm_1: LogosNSModuleLoaderApplyConfigurationResponseAR1Map(error: errorOf(e)),
    )

  let instance = request.module_instance
  let bytes = encode(request.configuration).valueOr:
    return ok(
      failed(loaderError(lecInvalidRequest, "the configuration input does not encode"))
    )
  let hook = m.core.beginApply(request.realization, instance).valueOr:
    return ok(failed(error))
  var status: AbiCheck
  barrier:
    let res = hook.apply(
      hook.context,
      cast[ptr UncheckedArray[uint8]](unsafeAddr bytes[0]),
      csize_t(bytes.len),
    )
    status = readStatus(res)
  let applied = m.core.applyDone(instance, status)
  if applied.isOk:
    return ok(
      LogosNSModuleLoaderApplyConfigurationResponse(
        kind: K.Case0, arm_0: LogosNSModuleLoaderApplyConfigurationResponseAR0Map()
      )
    )
  if applied.error.code == lecRealizationFailed:
    let record = m.core.status(instance, Opt.some(request.realization))
    if record.isOk and record.get.status == rsFailed:
      return ok(
        LogosNSModuleLoaderApplyConfigurationResponse(
          kind: K.Case2,
          arm_2: LogosNSModuleLoaderApplyConfigurationResponseAR2Map(
            realization: failedOf(record.get)
          ),
        )
      )
  ok(failed(applied.error))

proc `release`(
    m: LoaderModule, request: LogosNSModuleLoaderReleaseRequest
): Result[LogosNSModuleLoaderReleaseResponse, InvocationFailure] =
  ## [SPEC LOADER §9] `_MODULE_destroy` exactly once, on this thread; `force`
  ## is refused before anything changes (l.577-580).
  m.served()
  when defined(lcnTestHooks):
    m.journal(lmRelease, request.module_instance, request.realization)
  type K = LogosNSModuleLoaderReleaseResponseKind
  let instance = request.module_instance
  let t = m.core.beginRelease(request.realization, instance, request.force.get(false)).valueOr:
    return ok(
      LogosNSModuleLoaderReleaseResponse(
        kind: K.Case1,
        arm_1: LogosNSModuleLoaderReleaseResponseAR1Map(error: errorOf(error)),
      )
    )
  if t.isSome:
    let d = t.get
    barrier:
      d.destroy(d.context)
    m.core.releaseDone(instance)
  ok(
    LogosNSModuleLoaderReleaseResponse(
      kind: K.Case0, arm_0: LogosNSModuleLoaderReleaseResponseAR0Map()
    )
  )

exportLogosModuleLoader(LoaderModule)

proc loaderStaticRegistration*(): StaticRegistration =
  ## [SPEC RUNTIME §13.3; BCP l.287] The Loader's symbol table, for the
  ## bootstrap mechanism's one registration (binding `LoaderBindingId`).
  ## [SPEC INTERFACE §1.3; LOADER l.35] A Logos-defined system module: its call
  ## surface uses the reserved `logos` names.
  result = checkStaticRegistration(LoaderBindingId, logosModuleLoaderStaticSymbols())
    .expect("the Module Loader's symbol table")
  result.system = true

proc loaderLive*(context: ptr LogosModuleContext): int =
  ## The realizations held by the Loader instance behind `context`, for tests.
  let x {.cursor.} = cast[LoaderModule](instanceOf(context))
  x.core.liveCount
