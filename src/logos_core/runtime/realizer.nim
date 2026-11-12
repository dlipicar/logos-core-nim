## LOADER §3-§7, §9-§11 for the two direct strategies: the Runtime's internal
## Module Loader [IMPL].
##
## The realizer is shaped like the Loader contract (realize, release, get_status,
## its descriptors, records and error codes), so the Runtime calls it the way it
## will call a Loader provider, but it is an in-process object, not a module.
## It advertises `direct_static` and `direct_dynamic`; `hosted_dynamic` is
## refused with `unsupported-strategy` before any artifact code is loaded, and
## `force` with `invalid-request` (§4, §9).
##
## Direct realization is the ABI caller (§6): it binds the module code once per
## static registration or per verified artifact (`native.nim`, `artifact.nim`),
## initializes one context per module instance, and calls `_MODULE_destroy`
## exactly once on release. Bindings and libraries are kept for the realizer's
## lifetime (RUNTIME §2.2; TF-03).
##
## [IMPL] Every direct realization failure is cleaned up before `realize`
## returns, so no failed realization is ever retained: what a module that broke
## the init contract left behind cannot be cleaned by the Loader at all.
## [IMPL] Configuration handoffs are not supported yet (CONFIG is not built):
## the Runtime rejects records that declare configuration, and the ABI caller
## always supplies the absent representation.
## [IMPL] A realizer is owned by one thread, the Runtime's; calls on it are
## serialized, which gives LOADER §11's per-instance total order. Module code
## runs in separate phases (`runBind`, `initModule`, a `Teardown`) that take
## plain values only, so the Runtime can run them on worker threads under its
## deadlines while its own thread keeps serving requests; `realize` and
## `release` run every phase on the calling thread.

{.push raises: [].}

import std/[os, strutils, sysrand, tables]
import results
import ../abi/[checks, types]
import ../cbor/utf8
import ../iface/[accept, names, outcome]
import ../pins
import ./[artifact, native]

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

  RealizeRequest* = object
    ## [SPEC LOADER §6] `logos.module_loader.realize_request` (no configuration)
    moduleInstance*: string
    descriptor*: RealizationDescriptor
    state*: Opt[string] ## `state.assignment`
    services*: InitServices

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
    key: string
    releasing: bool ## `_MODULE_destroy` has been handed out

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

  Realizer* = ref object
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
  var rnd: array[8, byte]
  doAssert urandom(rnd), "no system randomness"
  Realizer(prefix: hexOf(rnd), workDir: workDir, stateRoot: stateRoot)

func capabilities*(r: Realizer): Capabilities =
  ## [SPEC LOADER §4] Only what this Loader can satisfy in full.
  Capabilities(directStatic: true, directDynamic: true)

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

func keyOf(req: RealizeRequest): string =
  ## The descriptor and private handoffs that make two requests the same (§6).
  let d = req.descriptor
  result = $d.strategy & "\0" & d.module & "\0"
  case d.strategy
  of stDirectStatic:
    result.add(d.binding)
  of stDirectDynamic, stHostedDynamic:
    result.add(
      d.artifact.id & "\0" & d.artifact.localPath & "\0" & hexOf(d.artifact.hash) & "\0" &
        d.placement
    )
  result.add("\0" & req.state.get("-"))

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
        # Not cached: a later request may find the artifact readable.
        result.probe.err(
          loaderError(
            (
              case error.kind
              of sfUnavailable: lecArtifactUnavailable
              of sfIntegrity: lecArtifactIntegrityFailed
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
  let spec =
    case d.strategy
    of stHostedDynamic:
      return fail(lecUnsupportedStrategy, "hosted_dynamic is not advertised")
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

proc completeInit*(
    r: Realizer,
    h: InitHandoff,
    res: LogosResult,
    ctx: ptr LogosModuleContext,
    orphan: var ptr LogosModuleContext,
): Result[Realization, LoaderError] =
  ## [SPEC LOADER §6, §7] Checks what `_MODULE_init` returned. A failure is
  ## not retained (§7 allows it; nothing about it can be cleaned later).
  ## [IMPL] LOGOS_OK with a context but an invalid status: the instance exists,
  ## so `orphan` names the context the caller must destroy exactly once.
  orphan = nil
  let outcome = checkOutcome(res, contextShape(ctx))
  if outcome.isErr:
    if int64(res.code) == 0 and ctx != nil:
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
  r.live[h.request.moduleInstance] = x
  ok(x)

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
