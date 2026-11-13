## The realizer: the in-process ABI caller for the two direct strategies
## (LOADER §3-§7, §9-§11; DECISIONS I89). Since Tier 4b step 4b-1 it serves two
## mechanisms:
##
## - the Module Loader instance `logos_module_loader` keeps one, on its own
##   thread (`loader/core.nim`), and realizes every other module instance
##   through it when the Runtime calls the Loader's contract;
## - the Runtime's bootstrap mechanism keeps one whose only static
##   registration is the Loader's own, and realizes the Loader instance
##   through it (RUNTIME l.212, l.1641; BCP l.287; G57).
##
## A realizer is shaped like the Loader contract (realize, release,
## get_status, its descriptors, records and error codes). Its strategy
## drivers say what it can realize (`StrategyDriver`, §4): the two direct
## strategies by default; a strategy without a driver, `hosted_dynamic` in
## 4b-1, is refused with `unsupported-strategy` before any artifact code is
## loaded, and `force` with `invalid-request` (§4, §9).
##
## Direct realization is the ABI caller (§6): it binds the module code once per
## static registration or per verified artifact (`native.nim`, `artifact.nim`),
## initializes one context per module instance, and calls `_MODULE_destroy`
## exactly once on release. Bindings and libraries are kept for the realizer's
## lifetime (RUNTIME §2.2; TF-03).
##
## [IMPL-DECISION G250] No failed realization is retained at `realize`: every
## direct realization failure is cleaned up before `realize` returns, and what
## a module that broke the init contract left behind (a failure status with a
## context) cannot be cleaned by the Loader at all, so it is never destroyed
## (I88). The one failed realization retained is an indeterminate live
## configuration (§8): it stays, failed, until it is released.
## The configuration handoff (CONFIG §6; I87) carries the encoded
## `configuration_input` into `_MODULE_init`; a request without one gets the
## absent representation (INTERFACE l.3914).
## [IMPL] A realizer is owned by one thread; calls on it are serialized, which
## gives LOADER §11's per-instance total order. Module code runs in separate
## phases (`runBind`, `initModule`, a `Teardown`, an `ApplyHook`) that take
## plain values only, so the owner can run them on other threads while its
## own keeps serving requests; `realize` and `release` run every phase on the
## calling thread.

{.push raises: [].}

import std/[os, strutils, sysrand, tables]
import results
import ../abi/[checks, types]
import ../cbor/utf8
import ../iface/[accept, names, outcome]
import ../pins
import ./[artifact, config, native]

export artifact, native

const
  MaxInstanceIdBytes* = 128 ## [SPEC RUNTIME §8] `module_instance_id`
  MaxAssignmentIdBytes* = 128 ## [SPEC RUNTIME §8] `module_state_assignment_id`
  MaxArtifactIdBytes* = 128 ## [SPEC LOADER §3]
  MaxLocalPathBytes* = 4096 ## [SPEC LOADER §3]
  MaxLoaderMessageBytes* = 512 ## [SPEC LOADER §10]
  HostedPlacements* = ["process", "sandbox", "container"] ## [SPEC LOADER §3]

type
  Strategy* = enum
    stDirectStatic = "direct_static"
    stDirectDynamic = "direct_dynamic"
    stHostedDynamic = "hosted_dynamic"

  RealizationDescriptor* = object
    ## [SPEC LOADER §3] `logos.module_loader.realization_descriptor`
    strategy*: Strategy
    module*: string
    binding*: string ## `static_binding.binding` (direct_static)
    artifact*: ArtifactRecord ## direct_dynamic and hosted_dynamic
    placement*: string ## hosted_dynamic

  LoaderErrorCode* = enum
    ## [SPEC LOADER §10] `logos.module_loader.error_code`
    lecInvalidRequest = "invalid-request"
    lecUnsupportedStrategy = "unsupported-strategy"
    lecArtifactUnavailable = "artifact-unavailable"
    lecArtifactIntegrityFailed = "artifact-integrity-failed"
    lecAbiInvalid = "abi-invalid"
    lecRealizationFailed = "realization-failed"
    lecInstanceConflict = "instance-conflict"
    lecRealizationNotFound = "realization-not-found"
    lecConfigurationRejected = "configuration-rejected"

  LoaderError* = object
    ## [SPEC LOADER §10] `logos.module_loader.error`, plus what the module's own
    ## failure status said, for the Runtime's diagnostics only.
    code*: LoaderErrorCode
    message*: string ## at most 512 bytes; names no host path
    cause*: Opt[AbiFailure]

  InitServices* = object
    ## [SPEC LOADER §6 steps 5-6] The instance-bound bindings the Runtime
    ## supplies: they must stay valid until `_MODULE_destroy` returns.
    runtimeControl*: ptr LogosRuntimeControlBinding
    publish*: LogosPublishFn
    publishUserData*: pointer
    invocationAccess*: LogosInvocationAccess

  ConfigurationHandoff* = object
    ## [SPEC LOADER §5.2, §6; CONFIG §6] The attempt's configuration snapshot:
    ## one deterministic `configuration_input` and what the binding must
    ## provide for it. Never copied into a realization record or a Loader
    ## error (LDR-0045, LDR-0149).
    input*: Blob
      ## the encoded input, owned by the attempt (the engine drops it once
      ## `_MODULE_init` has returned); borrowed here
    live*: bool ## the binding declares live reconfiguration
    commitment*: SchemaRoots
    valueRevision*: uint64

  RealizeRequest* = object ## [SPEC LOADER §6] `logos.module_loader.realize_request`
    moduleInstance*: string
    descriptor*: RealizationDescriptor
    state*: Opt[string] ## `state.assignment`
    services*: InitServices
    configuration*: Opt[ConfigurationHandoff]

  RealizationStatus* = enum
    rsActive = "active"
    rsFailed = "failed"

  Realization* = ref object
    ## [SPEC LOADER §7] One retained realization and what the ABI caller keeps
    ## for it: the shared binding and the instance's context.
    id*: string
    moduleInstance*: string
    status*: RealizationStatus
    failure*: LoaderError
    binding*: ref NativeBinding
    context*: ptr LogosModuleContext ## nil once destruction has begun
    stateDir*: Opt[string]
    live*: bool ## [SPEC LOADER §8] its startup handoff declared live reconfiguration
    initCommitment*: Opt[SchemaRoots]
      ## [SPEC CONFIG §8 l.296] the schema commitment of the configuration it
      ## was initialized with; none without a configuration
    key: string
    releasing: bool ## `_MODULE_destroy` has been handed out
    applying: bool
      ## [SPEC LOADER §11] `_MODULE_apply_configuration` has been handed out
      ## and has not returned

  RealizationRecord* = object
    ## [SPEC LOADER §7] The public record: no descriptor, handoff or path.
    realization*: string
    moduleInstance*: string
    status*: RealizationStatus
    callSurface*: Opt[seq[byte]] ## an active provider realization only
    failure*: Opt[LoaderError]

  Capabilities* = object ## [SPEC LOADER §4] `logos.module_loader.capabilities`
    directStatic*: bool
    directDynamic*: bool
    hostedPlacements*: seq[string]
    forceRelease*: bool

  DriverKind* = enum
    dkInProcess
      ## bound and initialized in this process (the direct strategies): the
      ## phases below
    # 4b-3 adds a hosted driver kind, whose start and release run elsewhere.

  StrategyDriver* = object
    ## [SPEC LOADER §4; plan §2.15] One strategy this realizer can satisfy in
    ## full. `capabilities` is computed from the registered drivers, so a
    ## strategy is advertised exactly when a driver serves it.
    strategy*: Strategy
    kind*: DriverKind
    placements*: seq[string] ## the hosted placements served (hosted only)

  BindSpec* = object ## What binding module code needs, as plain values (`runBind`).
    key*: string
    module*: string
    case kind*: CodeKind
    of codeStatic:
      symbols*: Table[string, pointer]
      system*: bool ## a Logos-defined system module (`StaticRegistration`)
    of codeDynamic:
      artifact*: ArtifactRecord
      dir*: string ## the private artifact directory
      name*: string ## the staged copy's file name

  BindResult* = object
    ## Plain values only: no `ref` built on one thread reaches another (ORC
    ## keeps cycle candidates per thread).
    key*: string
    module*: string
    code*: ModuleCode
    probe*: Result[NativeProbe, LoaderError]
    cache*: bool ## a final outcome: the code was found or mapped
    system*: bool ## the call surface may use the reserved `logos` names

  StepKind* = enum
    skLive ## the instance already has this realization
    skBind ## run `runBind`, then `storeBinding`
    skInit ## the binding is ready: `prepareInit`

  Step* = object
    case kind*: StepKind
    of skLive:
      realization*: Realization
    of skBind:
      spec*: BindSpec
    of skInit:
      binding*: ref NativeBinding

  InitHandoff* = ref object
    ## The initialization input and what it points to: neither moves nor
    ## changes until `_MODULE_init` has returned.
    request*: RealizeRequest
    binding*: ref NativeBinding
    input*: LogosModuleInitInput
    stateDir: Opt[string]
    stateDirText: string

  Teardown* = object ## The one `_MODULE_destroy(context)` call a release hands out.
    destroy*: ModuleDestroyFn
    context*: ptr LogosModuleContext

  ApplyHook* = object
    ## [SPEC LOADER §8] The one `_MODULE_apply_configuration` call an apply
    ## hands out, through the retained context.
    apply*: ModuleApplyConfigurationFn
    context*: ptr LogosModuleContext

  Realizer* = ref object
    drivers: array[Strategy, Opt[StrategyDriver]]
    statics: Table[string, StaticRegistration] ## by binding identifier
    bindings: Table[string, Result[ref NativeBinding, LoaderError]]
      ## final binding outcomes: `s:` and the static binding identifier, or
      ## `d:`, the hash suite, the artifact digest and the module name
    live: Table[string, Realization] ## by module instance
    prefix: string
    issued: int
    staged: int
    workDir: string
    artifactDir: string
    stateRoot: Opt[string]

func hexOf(bytes: openArray[byte]): string =
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii)

func clipMessage*(s: string): string =
  ## At most 512 bytes, cut at a UTF-8 boundary.
  if s.len <= MaxLoaderMessageBytes:
    return s
  var n = MaxLoaderMessageBytes
  while n > 0 and (uint8(s[n]) and 0xC0) == 0x80:
    dec n
  s[0 ..< n]

func loaderError*(
    code: LoaderErrorCode, message: string, cause = Opt.none(AbiFailure)
): LoaderError =
  LoaderError(code: code, message: clipMessage(message), cause: cause)

template fail(code: LoaderErrorCode, message: string): untyped =
  err(loaderError(code, message))

proc newRealizer*(workDir: string, stateRoot = Opt.none(string)): Realizer =
  ## `workDir` holds the private directory for verified library copies;
  ## `stateRoot` the module state directories, one per assignment [G143].
  ## The two direct drivers are registered (K7, K10).
  var rnd: array[8, byte]
  doAssert urandom(rnd), "no system randomness"
  result = Realizer(prefix: hexOf(rnd), workDir: workDir, stateRoot: stateRoot)
  for s in [stDirectStatic, stDirectDynamic]:
    result.drivers[s] = Opt.some(StrategyDriver(strategy: s, kind: dkInProcess))

proc registerDriver*(r: Realizer, d: StrategyDriver): Result[void, string] =
  ## Adds the driver of a strategy no driver serves yet.
  if r.drivers[d.strategy].isSome:
    return err("the strategy " & $d.strategy & " already has a driver")
  if d.strategy == stHostedDynamic:
    for p in d.placements:
      if p notin HostedPlacements:
        return err("unknown hosted placement " & p)
  elif d.placements.len > 0:
    return err("only hosted_dynamic has placements")
  r.drivers[d.strategy] = Opt.some(d)
  ok()

func capabilities*(r: Realizer): Capabilities =
  ## [SPEC LOADER §4] Only what this Loader can satisfy in full: the strategies
  ## of its drivers. `force_release` is never advertised (K7).
  result.directStatic = r.drivers[stDirectStatic].isSome
  result.directDynamic = r.drivers[stDirectDynamic].isSome
  if r.drivers[stHostedDynamic].isSome:
    result.hostedPlacements = r.drivers[stHostedDynamic].get.placements

proc registerStatic*(r: Realizer, reg: StaticRegistration): Result[void, string] =
  ## [SPEC RUNTIME §13.3] A duplicate binding identifier leaves the existing
  ## registration unchanged.
  if reg.binding in r.statics:
    return err("binding " & reg.binding & " is already registered")
  r.statics[reg.binding] = reg
  ok()

proc registerStatic*(
    r: Realizer, binding: string, entries: openArray[(string, pointer)]
): Result[void, string] =
  r.registerStatic(?checkStaticRegistration(binding, entries))

# Requests ---------------------------------------------------------------------

func sized(s: string, lo, hi: int): bool =
  s.len >= lo and s.len <= hi and isValidUtf8(s)

func pathSafe*(s: string): bool =
  s notin [".", ".."] and
    s.allCharsInSet({'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '-'})

func checkRequest(req: RealizeRequest): Result[void, LoaderError] =
  ## [SPEC LOADER §3, §6] What makes a request semantically invalid.
  let d = req.descriptor
  if not req.moduleInstance.sized(1, MaxInstanceIdBytes):
    return fail(lecInvalidRequest, "module_instance must have 1 to 128 UTF-8 bytes")
  checkModuleName(d.module, system = true).isOkOr:
    return fail(lecInvalidRequest, error)
  case d.strategy
  of stDirectStatic:
    if not d.binding.sized(1, MaxBindingIdBytes):
      return fail(lecInvalidRequest, "static_binding.binding must have 1 to 128 bytes")
  of stDirectDynamic, stHostedDynamic:
    let a = d.artifact
    if not a.id.sized(1, MaxArtifactIdBytes):
      return fail(lecInvalidRequest, "artifact.id must have 1 to 128 bytes")
    if not a.localPath.sized(1, MaxLocalPathBytes):
      return fail(lecInvalidRequest, "artifact.local_path must have 1 to 4096 bytes")
    if "://" in a.localPath or '\0' in a.localPath:
      return fail(lecInvalidRequest, "artifact.local_path does not name a local file")
    if a.hashSuite != HashSuiteId:
      return fail(lecInvalidRequest, "artifact.hash_suite is not " & HashSuiteId)
    if d.strategy == stHostedDynamic and d.placement notin HostedPlacements:
      return fail(lecInvalidRequest, "unknown hosted placement")
  if req.state.isSome:
    let s = req.state.get
    # [IMPL] An assignment becomes one path component under the state root.
    if not s.sized(1, MaxAssignmentIdBytes) or not s.pathSafe:
      return fail(
        lecInvalidRequest, "state.assignment must be 1 to 128 bytes of [A-Za-z0-9._-]"
      )
  ok()

func addressText(p: pointer): string =
  toHex(cast[uint](p).BiggestInt, 2 * sizeof(pointer))

func keyOf(req: RealizeRequest): string =
  ## The descriptor and private handoffs that make two requests the same (§6):
  ## the initialization services are part of the request (LOADER l.370-372).
  let d = req.descriptor
  let s = req.services
  result =
    addressText(s.runtimeControl) & addressText(cast[pointer](s.publish)) &
    addressText(s.publishUserData) & addressText(s.invocationAccess.state) &
    addressText(cast[pointer](s.invocationAccess.current)) & "\0"
  result.add($d.strategy & "\0" & d.module & "\0")
  case d.strategy
  of stDirectStatic:
    result.add(d.binding)
  of stDirectDynamic, stHostedDynamic:
    result.add(
      d.artifact.id & "\0" & d.artifact.localPath & "\0" & hexOf(d.artifact.hash) & "\0" &
        d.placement
    )
  result.add("\0" & req.state.get("-"))
  if req.configuration.isSome:
    # [SPEC LOADER §6] A retry with another snapshot is another request.
    let c = req.configuration.get
    result.add(
      "\0" & hexOf(c.commitment.schemaRoot) & hexOf(c.commitment.subtreeRoot) & "\0" &
        $c.valueRevision & "\0" & $c.live
    )

func dynamicKey(d: RealizationDescriptor): string =
  "d:" & d.artifact.hashSuite & ":" & hexOf(d.artifact.hash) & "/" & d.module

# Bindings ---------------------------------------------------------------------
#
# [IMPL] Binding runs artifact code (the platform loader, `_MODULE_name()`,
# `_MODULE_call_surface()`, RUNTIME §3.6), so it is a separate phase: `begin`
# returns a `BindSpec` of plain values, any thread may run `runBind` on it, and
# the owning thread caches the result with `storeBinding`. The Runtime runs it
# on a worker thread under the startup deadline; `realize` runs it inline.

proc staticSpec(r: Realizer, d: RealizationDescriptor): Result[BindSpec, LoaderError] =
  if d.binding notin r.statics:
    # [IMPL] An unknown identifier is a request the Loader can never satisfy.
    return fail(lecInvalidRequest, "no static registration has that binding identifier")
  let reg = r.statics.getOrDefault(d.binding)
  if reg.module != d.module:
    return fail(lecAbiInvalid, "the registration holds another module's ABI symbols")
  ok(
    BindSpec(
      key: "s:" & d.binding,
      module: d.module,
      kind: codeStatic,
      symbols: reg.symbols,
      system: reg.system,
    )
  )

proc dynamicSpec(r: Realizer, d: RealizationDescriptor): Result[BindSpec, LoaderError] =
  ## [SPEC LOADER §3; RUNTIME §3.6 step 4] One verified copy and one mapping
  ## per artifact digest and module; a later instance reuses them (§2.2).
  if r.artifactDir.len == 0:
    r.artifactDir = privateDir(r.workDir).valueOr:
      return fail(lecRealizationFailed, "no private artifact directory: " & error)
  inc r.staged
  ok(
    BindSpec(
      key: dynamicKey(d),
      module: d.module,
      kind: codeDynamic,
      artifact: d.artifact,
      dir: r.artifactDir,
      name: "a" & $r.staged,
    )
  )

proc runBind*(spec: BindSpec): BindResult {.gcsafe.} =
  ## Maps and probes the module code `spec` names (`probeNative`). Runs
  ## artifact code; any thread may call it, and it touches no realizer
  ## state.
  result.key = spec.key
  result.module = spec.module
  let code =
    case spec.kind
    of codeStatic:
      result.system = spec.system
      ModuleCode(kind: codeStatic, table: spec.symbols)
    of codeDynamic:
      let path = stage(spec.artifact, spec.dir, spec.name).valueOr:
        # Not cached: a later request may find the artifact readable. A
        # staging control that cannot be established is `realization-failed`
        # [SPEC LOADER l.628; C-08].
        result.probe.err(
          loaderError(
            (
              case error.kind
              of sfUnavailable: lecArtifactUnavailable
              of sfIntegrity: lecArtifactIntegrityFailed
              of sfControls: lecRealizationFailed
            ),
            error.msg,
          )
        )
        return
      let lib = mapLibrary(path)
      if lib == nil:
        result.probe.err(
          loaderError(lecArtifactUnavailable, "the platform loader refused the library")
        )
        return
      ModuleCode(kind: codeDynamic, library: lib)
  result.cache = true # the code is mapped: its binding outcome is final
  result.code = code
  let p = probeNative(code, spec.module)
  if p.isOk:
    result.probe.ok(p.get)
  else:
    result.probe.err(loaderError(lecAbiInvalid, p.error))

proc storeBinding*(
    r: Realizer, res: sink BindResult
): Result[ref NativeBinding, LoaderError] =
  ## Validates a probe on the owning thread (`completeNative`, no module
  ## code) and caches a final outcome; an earlier cached outcome for the same
  ## key wins.
  if res.key in r.bindings:
    return r.bindings.getOrDefault(res.key)
  let x =
    if res.probe.isErr:
      Result[ref NativeBinding, LoaderError].err(res.probe.error)
    else:
      let c = completeNative(res.code, res.probe.get, AcceptOptions(system: res.system))
      if c.isOk:
        let b = new NativeBinding
        b[] = c.get
        Result[ref NativeBinding, LoaderError].ok(b)
      else:
        Result[ref NativeBinding, LoaderError].err(loaderError(lecAbiInvalid, c.error))
  if res.cache:
    r.bindings[res.key] = x
  x

# Realize and release ----------------------------------------------------------

proc stateDirFor(r: Realizer, assignment: string): Result[string, LoaderError] =
  ## [SPEC LOADER §5.1] Established before native initialization [G143].
  if r.stateRoot.isNone:
    return fail(lecRealizationFailed, "no state root is configured")
  let dir = r.stateRoot.get / assignment
  try:
    createDir(dir)
    when defined(posix):
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  except OSError, IOError:
    return fail(lecRealizationFailed, "the state directory cannot be established")
  ok(dir)

proc admissible*(r: Realizer, req: RealizeRequest): Result[void, LoaderError] =
  ## [SPEC LOADER §3, §4, §6] The checks of a request that touch nothing: its
  ## form, then whether a driver serves its strategy (`unsupported-strategy`
  ## before any artifact is read, l.364).
  ?checkRequest(req)
  if r.drivers[req.descriptor.strategy].isNone:
    return fail(lecUnsupportedStrategy, $req.descriptor.strategy & " is not advertised")
  ok()

proc begin*(r: Realizer, req: RealizeRequest): Result[Step, LoaderError] =
  ## [SPEC LOADER §6] The first phase of `realize`: the request checks, then
  ## the instance's current realization, a cached binding, or the binding work
  ## still to do. The caller runs one realization at a time per instance.
  ?checkRequest(req)
  let key = keyOf(req)
  if req.moduleInstance in r.live:
    let x = r.live.getOrDefault(req.moduleInstance)
    if x.key == key and not x.releasing:
      return ok(Step(kind: skLive, realization: x)) # §6: already realized
    return fail(lecInstanceConflict, "the instance has another realization")
  let d = req.descriptor
  if r.drivers[d.strategy].isNone:
    # [SPEC LOADER l.364 (LDR-0067)] Before any artifact is read.
    return fail(lecUnsupportedStrategy, $d.strategy & " is not advertised")
  let spec =
    case d.strategy
    of stHostedDynamic:
      # 4b-3's hosted driver starts the module elsewhere.
      return fail(lecUnsupportedStrategy, $d.strategy & " is not advertised")
    of stDirectStatic:
      ?r.staticSpec(d)
    of stDirectDynamic:
      if dynamicKey(d) in r.bindings:
        # A cached binding needs no new staged copy.
        BindSpec(key: dynamicKey(d), module: d.module, kind: codeDynamic)
      else:
        ?r.dynamicSpec(d)
  if spec.key in r.bindings:
    let b = ?r.bindings.getOrDefault(spec.key)
    return ok(Step(kind: skInit, binding: b))
  ok(Step(kind: skBind, spec: spec))

proc prepareInit*(
    r: Realizer, req: RealizeRequest, b: ref NativeBinding
): Result[InitHandoff, LoaderError] =
  ## [SPEC LOADER §6 steps 4-7] The state directory and the initialization
  ## input, which stay where they are until `_MODULE_init` has returned.
  if req.configuration.isSome and req.configuration.get.live and
      b.applyConfiguration.isNil:
    # [SPEC RUNTIME l.1386-1392 (RUN-1086); CONFIG l.264 (CFG-0091)] A live
    # declaration needs the apply hook; checked per instance, since bindings
    # are shared.
    return fail(
      lecAbiInvalid,
      "the module declares live reconfiguration but exports no apply_configuration",
    )
  let h = InitHandoff(request: req, binding: b)
  if req.state.isSome:
    h.stateDir = Opt.some(?r.stateDirFor(req.state.get))
    h.stateDirText = h.stateDir.get
  h.input = LogosModuleInitInput(
    abiVersion: ModuleInitAbiVersion,
    structSize: csize_t(sizeof(LogosModuleInitInput)),
    runtimeControl: req.services.runtimeControl,
    publishUserData: req.services.publishUserData,
    publish: req.services.publish,
    stateDir: (if h.stateDir.isSome: cstring(h.stateDirText) else: nil),
    invocationAccess: req.services.invocationAccess,
  )
  if req.configuration.isSome:
    # [SPEC CONFIG l.224-226 (CFG-0066, CFG-0067); RUNTIME RUN-0291] The
    # snapshot's bytes, borrowed for the call; absent stays NULL and 0.
    let input = req.configuration.get.input
    h.input.configurationCbor = cast[ptr UncheckedArray[uint8]](input.address)
    h.input.configurationCborLen = csize_t(input.len)
  checkInitInput(addr h.input, b.declaresEvents).isOkOr:
    return fail(
      lecRealizationFailed,
      "the Runtime's initialization services are invalid: " & error.message.get(""),
    )
  ok(h)

proc initModule*(
    init: ModuleInitFn, input: ptr LogosModuleInitInput
): (LogosResult, ptr LogosModuleContext) {.gcsafe.} =
  ## [SPEC INTERFACE §2.6; LOADER §6 step 8] The one `_MODULE_init` call, with
  ## `*out_context` set to null first. Plain values only, so a Runtime can run
  ## it on a thread of its choosing.
  var ctx: ptr LogosModuleContext = nil
  let res = init(input, addr ctx)
  (res, ctx)

proc initInstance*(h: InitHandoff): (LogosResult, ptr LogosModuleContext) =
  initModule(h.binding.init, addr h.input)

proc nextId(r: Realizer): string =
  ## [SPEC LOADER §7] Never issued before by this Loader: a random prefix per
  ## realizer and a counter.
  inc r.issued
  "r-" & r.prefix & "-" & $r.issued

proc completeInitChecked*(
    r: Realizer,
    h: InitHandoff,
    outcome: Result[void, AbiFailure],
    returnedOk: bool,
    ctx: ptr LogosModuleContext,
    orphan: var ptr LogosModuleContext,
): Result[Realization, LoaderError] =
  ## [SPEC LOADER §6, §7] Applies what `_MODULE_init` returned, checked where
  ## it ran (`checkInit`): `outcome` and whether its code was LOGOS_OK. A
  ## failure is not retained (§7 allows it; nothing about it can be cleaned
  ## later). [IMPL] LOGOS_OK with a context but an invalid status: the
  ## instance exists, so `orphan` names the context the caller must destroy
  ## exactly once.
  orphan = nil
  if outcome.isErr:
    if returnedOk and ctx != nil:
      orphan = ctx
    let f = outcome.error
    return err(
      loaderError(
        lecRealizationFailed, "_MODULE_init() failed with " & $f.code, Opt.some(f)
      )
    )
  let x = Realization(
    id: r.nextId(),
    moduleInstance: h.request.moduleInstance,
    status: rsActive,
    binding: h.binding,
    context: ctx,
    stateDir: h.stateDir,
    key: keyOf(h.request),
  )
  if h.request.configuration.isSome:
    let c = h.request.configuration.get
    x.live = c.live
    x.initCommitment = Opt.some(c.commitment)
  r.live[h.request.moduleInstance] = x
  ok(x)

proc checkInit*(
    res: LogosResult, ctx: ptr LogosModuleContext
): (Result[void, AbiFailure], bool) =
  ## [SPEC INTERFACE §2.6, §2.7] What `_MODULE_init` returned, checked on the
  ## thread that called it (its message lives in that thread's storage), as
  ## plain values for `completeInitChecked`.
  (checkOutcome(res, contextShape(ctx)), int64(res.code) == 0)

proc completeInit*(
    r: Realizer,
    h: InitHandoff,
    res: LogosResult,
    ctx: ptr LogosModuleContext,
    orphan: var ptr LogosModuleContext,
): Result[Realization, LoaderError] =
  ## `completeInitChecked` with the result checked here.
  let (outcome, returnedOk) = checkInit(res, ctx)
  r.completeInitChecked(h, outcome, returnedOk, ctx, orphan)

proc realize*(r: Realizer, req: RealizeRequest): Result[Realization, LoaderError] =
  ## [SPEC LOADER §6] Every phase on the calling thread. Returns the active
  ## realization, or an error after every partial context it can clean is
  ## cleaned.
  let step = ?r.begin(req)
  let b =
    case step.kind
    of skLive:
      return ok(step.realization)
    of skBind:
      ?r.storeBinding(runBind(step.spec))
    of skInit:
      step.binding
  let h = ?r.prepareInit(req, b)
  let (res, ctx) = initInstance(h)
  var orphan: ptr LogosModuleContext
  result = r.completeInit(h, res, ctx, orphan)
  if orphan != nil:
    b.destroy(orphan)

proc beginRelease*(
    r: Realizer, realization, moduleInstance: string, force = false
): Result[Opt[Teardown], LoaderError] =
  ## [SPEC LOADER §9] Graceful release, first phase: the context to destroy,
  ## if the realization still has one. The Runtime has already stopped and
  ## drained the instance's work. The record stays (as releasing) until
  ## `finishRelease`.
  if force:
    return fail(lecInvalidRequest, "force_release is not advertised")
  var found: Realization = nil
  for x in r.live.values:
    if x.id == realization:
      found = x
  if found.isNil:
    return ok(Opt.none(Teardown)) # idempotent; touches no other realization
  if found.moduleInstance != moduleInstance:
    return fail(lecRealizationNotFound, "no realization matches both identifiers")
  if found.applying:
    # [SPEC LOADER §11 (LDR-0136)] Application is excluded from release.
    return fail(lecInvalidRequest, "a configuration is being applied")
  found.releasing = true
  if found.context == nil:
    return ok(Opt.none(Teardown))
  let t = Teardown(destroy: found.binding.destroy, context: found.context)
  found.context = nil # destruction begins: the context is consumed
  ok(Opt.some(t))

proc finishRelease*(r: Realizer, moduleInstance: string) =
  ## [SPEC LOADER §9] `_MODULE_destroy` has returned: the record is gone. The
  ## binding stays (never unloaded).
  let x = r.live.getOrDefault(moduleInstance)
  if not x.isNil and x.releasing:
    r.live.del(moduleInstance)

proc release*(
    r: Realizer, realization, moduleInstance: string, force = false
): Result[void, LoaderError] =
  ## [SPEC LOADER §9] Both phases on the calling thread: `_MODULE_destroy`
  ## exactly once, then the record is gone.
  let t = ?r.beginRelease(realization, moduleInstance, force)
  if t.isSome:
    t.get.destroy(t.get.context)
  r.finishRelease(moduleInstance)
  ok()

proc beginApply*(
    r: Realizer, realization, moduleInstance: string
): Result[ApplyHook, LoaderError] =
  ## [SPEC LOADER §8, §11] Live application, first phase: the hook to call
  ## once on the retained context. An unknown or nonmatching realization is
  ## `realization-not-found`; one whose startup handoff declared no live
  ## reconfiguration, or one not active, releasing or already applying, is
  ## `invalid-request` [IMPL for the last three]. Neither invokes module
  ## behavior (LDR-0113). Release is refused until `completeApply`.
  let x = r.live.getOrDefault(moduleInstance)
  if x.isNil or x.id != realization:
    return fail(lecRealizationNotFound, "no realization matches both identifiers")
  if not x.live or x.binding.applyConfiguration.isNil:
    return
      fail(lecInvalidRequest, "the realization did not declare live reconfiguration")
  if x.status != rsActive or x.releasing or x.context == nil:
    return fail(lecInvalidRequest, "the realization is not active")
  if x.applying:
    return fail(lecInvalidRequest, "a configuration is already being applied")
  x.applying = true
  ok(ApplyHook(apply: x.binding.applyConfiguration, context: x.context))

proc completeApplyChecked*(
    r: Realizer,
    moduleInstance: string,
    status: Result[void, AbiFailure],
    established = true,
): Result[void, LoaderError] =
  ## [SPEC LOADER §8] The hook has returned, its status read where it ran
  ## (`readStatus`): release may go on. LOGOS_OK is `succeeded`; a valid
  ## failure status, `configuration-rejected`, the realization still active;
  ## anything else, or a result the caller no longer accepts (`established`
  ## false: its deadline passed), is `realization-failed` and the realization
  ## becomes `failed`, owned until its release. The hook's own diagnostics
  ## stay in `cause`, never forwarded (CFG-0146).
  let x = r.live.getOrDefault(moduleInstance)
  if x.isNil or not x.applying:
    return fail(lecRealizationNotFound, "no application is in progress")
  x.applying = false
  if established and status.isOk:
    return ok()
  if established and status.error.reason.len == 0:
    return err(
      loaderError(
        lecConfigurationRejected,
        "the module rejected the configuration",
        Opt.some(status.error),
      )
    )
  let e = loaderError(
    lecRealizationFailed,
    (
      if established: "_MODULE_apply_configuration() returned an invalid result"
      else: "the application outcome was not established in time"
    ),
  )
  x.status = rsFailed
  x.failure = e
  err(e)

proc completeApply*(
    r: Realizer, moduleInstance: string, res: LogosResult, established = true
): Result[void, LoaderError] =
  ## `completeApplyChecked` with the status read here.
  r.completeApplyChecked(moduleInstance, readStatus(res), established)

proc applyConfiguration*(
    r: Realizer, realization, moduleInstance: string, input: Blob
): Result[void, LoaderError] =
  ## [SPEC LOADER §8] Both phases on the calling thread.
  let h = ?r.beginApply(realization, moduleInstance)
  let res = h.apply(
    h.context, cast[ptr UncheckedArray[uint8]](input.address), csize_t(input.len)
  )
  r.completeApply(moduleInstance, res)

func record*(x: Realization): RealizationRecord =
  ## [SPEC LOADER §7] A provider's active record carries its exact call surface.
  result = RealizationRecord(
    realization: x.id, moduleInstance: x.moduleInstance, status: x.status
  )
  case x.status
  of rsActive:
    if x.binding.provider:
      result.callSurface = Opt.some(x.binding.callSurface)
  of rsFailed:
    result.failure = Opt.some(x.failure)

proc getStatus*(
    r: Realizer, moduleInstance: string, realization = Opt.none(string)
): Result[RealizationRecord, LoaderError] =
  ## [SPEC LOADER §7] The retained record for the instance, which must also
  ## carry `realization` when one is given.
  let x = r.live.getOrDefault(moduleInstance)
  if x.isNil or (realization.isSome and realization.get != x.id):
    return fail(lecRealizationNotFound, "no realization matches")
  ok(x.record)

func liveCount*(r: Realizer): int =
  r.live.len
