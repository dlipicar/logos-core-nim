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
## serialized, which gives LOADER §11's per-instance total order.

{.push raises: [].}

import std/[os, strutils, sysrand, tables]
import results
import ../abi/[checks, types]
import ../cbor/utf8
import ../iface/[names, outcome]
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

  Realizer* = ref object
    statics: Table[string, StaticRegistration] ## by binding identifier
    staticBindings: Table[string, Result[ref NativeBinding, string]]
    dynamicBindings: Table[string, Result[ref NativeBinding, string]]
      ## by artifact digest and module name
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

func pathSafe(s: string): bool =
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

# Bindings ---------------------------------------------------------------------

proc staticBinding(
    r: Realizer, d: RealizationDescriptor
): Result[ref NativeBinding, LoaderError] =
  if d.binding notin r.statics:
    # [IMPL] An unknown identifier is a request the Loader can never satisfy.
    return fail(lecInvalidRequest, "no static registration has that binding identifier")
  let reg = r.statics.getOrDefault(d.binding)
  if reg.module != d.module:
    return fail(lecAbiInvalid, "the registration holds another module's ABI symbols")
  if d.binding notin r.staticBindings:
    let b = bindNative(ModuleCode(kind: codeStatic, table: reg.symbols), d.module)
    r.staticBindings[d.binding] =
      if b.isOk:
        let x = new NativeBinding
        x[] = b.get
        Result[ref NativeBinding, string].ok(x)
      else:
        Result[ref NativeBinding, string].err(b.error)
  let b = r.staticBindings.getOrDefault(d.binding)
  if b.isErr:
    return fail(lecAbiInvalid, b.error)
  ok(b.get)

proc dynamicBinding(
    r: Realizer, d: RealizationDescriptor
): Result[ref NativeBinding, LoaderError] =
  ## [SPEC LOADER §3; RUNTIME §3.6 step 4] One verified copy and one mapping
  ## per artifact digest and module; a later instance reuses them (§2.2).
  let key = d.artifact.hashSuite & ":" & hexOf(d.artifact.hash) & "/" & d.module
  if key notin r.dynamicBindings:
    if r.artifactDir.len == 0:
      r.artifactDir = privateDir(r.workDir).valueOr:
        return fail(lecRealizationFailed, "no private artifact directory: " & error)
    inc r.staged
    let path = stage(d.artifact, r.artifactDir, "a" & $r.staged).valueOr:
      return fail(
        (
          case error.kind
          of sfUnavailable: lecArtifactUnavailable
          of sfIntegrity: lecArtifactIntegrityFailed
        ),
        error.msg,
      )
    let lib = mapLibrary(path)
    if lib == nil:
      return fail(lecArtifactUnavailable, "the platform loader refused the library")
    let b = bindNative(ModuleCode(kind: codeDynamic, library: lib), d.module)
    r.dynamicBindings[key] =
      if b.isOk:
        let x = new NativeBinding
        x[] = b.get
        Result[ref NativeBinding, string].ok(x)
      else:
        Result[ref NativeBinding, string].err(b.error)
  let b = r.dynamicBindings.getOrDefault(key)
  if b.isErr:
    return fail(lecAbiInvalid, b.error)
  ok(b.get)

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

proc initInstance*(
    b: ref NativeBinding, input: ptr LogosModuleInitInput
): (LogosResult, ptr LogosModuleContext) =
  ## [SPEC INTERFACE §2.6; LOADER §6 step 8] The one `_MODULE_init` call, with
  ## `*out_context` set to null first. Plain values only, so a Runtime can run
  ## it on a thread of its choosing.
  var ctx: ptr LogosModuleContext = nil
  let res = b.init(input, addr ctx)
  (res, ctx)

proc nextId(r: Realizer): string =
  ## [SPEC LOADER §7] Never issued before by this Loader: a random prefix per
  ## realizer and a counter.
  inc r.issued
  "r-" & r.prefix & "-" & $r.issued

proc realize*(r: Realizer, req: RealizeRequest): Result[Realization, LoaderError] =
  ## [SPEC LOADER §6] Returns the active realization, or an error after every
  ## partial context and binding it can clean is cleaned.
  ?checkRequest(req)
  let key = keyOf(req)
  if req.moduleInstance in r.live:
    let x = r.live.getOrDefault(req.moduleInstance)
    if x.key == key:
      return ok(x) # §6: the same descriptor and handoffs, already realized
    return fail(lecInstanceConflict, "the instance has another realization")
  let d = req.descriptor
  let b =
    case d.strategy
    of stHostedDynamic:
      return fail(lecUnsupportedStrategy, "hosted_dynamic is not advertised")
    of stDirectStatic:
      ?r.staticBinding(d)
    of stDirectDynamic:
      ?r.dynamicBinding(d)
  var stateDir = Opt.none(string)
  if req.state.isSome:
    stateDir = Opt.some(?r.stateDirFor(req.state.get))
  # [SPEC LOADER §6 steps 4-7] The initialization input.
  let dirText = stateDir.get("")
  var input = LogosModuleInitInput(
    abiVersion: ModuleInitAbiVersion,
    structSize: csize_t(sizeof(LogosModuleInitInput)),
    runtimeControl: req.services.runtimeControl,
    publishUserData: req.services.publishUserData,
    publish: req.services.publish,
    stateDir: (if stateDir.isSome: cstring(dirText) else: nil),
    invocationAccess: req.services.invocationAccess,
  )
  checkInitInput(addr input, b.declaresEvents).isOkOr:
    return fail(
      lecRealizationFailed,
      "the Runtime's initialization services are invalid: " & error.message.get(""),
    )
  let (res, ctx) = initInstance(b, addr input)
  let outcome = checkOutcome(res, contextShape(ctx))
  if outcome.isErr:
    if int64(res.code) == 0 and ctx != nil:
      # [IMPL] LOGOS_OK with a context but an invalid status: the instance
      # exists, so it is destroyed exactly once before the failure returns.
      b.destroy(ctx)
    let f = outcome.error
    return err(
      loaderError(
        lecRealizationFailed, "_MODULE_init() failed with " & $f.code, Opt.some(f)
      )
    )
  let x = Realization(
    id: r.nextId(),
    moduleInstance: req.moduleInstance,
    status: rsActive,
    binding: b,
    context: ctx,
    stateDir: stateDir,
    key: key,
  )
  r.live[req.moduleInstance] = x
  ok(x)

proc release*(
    r: Realizer, realization, moduleInstance: string, force = false
): Result[void, LoaderError] =
  ## [SPEC LOADER §9] Graceful release: `_MODULE_destroy` exactly once, then the
  ## record is gone. The Runtime has already stopped and drained the instance's
  ## work. The binding stays (never unloaded).
  if force:
    return fail(lecInvalidRequest, "force_release is not advertised")
  var found: Realization = nil
  for x in r.live.values:
    if x.id == realization:
      found = x
  if found.isNil:
    return ok() # idempotent; touches no other realization
  if found.moduleInstance != moduleInstance:
    return fail(lecRealizationNotFound, "no realization matches both identifiers")
  if found.context != nil:
    let ctx = found.context
    found.context = nil # destruction begins: the context is consumed
    found.binding.destroy(ctx)
  r.live.del(moduleInstance)
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
