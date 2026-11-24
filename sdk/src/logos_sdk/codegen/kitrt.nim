## Runtime support for lcn-gen's module kit [IMPL]: a native module written in
## Nim exports the INTERFACE §2.6 identity, lifecycle and provider symbols.
##
## A generated `<module>_kit.nim` embeds the module binding's documents and its
## provider call-surface descriptor, and declares one template that the module
## author instantiates with their instance type. That template defines the
## exported C symbols; the procedures here do the work at the C boundary:
##
## - `_MODULE_init` checks the initialization input (`abi/checks`), copies what
##   it borrows, calls the author's `initModule` and returns a fresh context.
## - `_MODULE_destroy` calls the optional `destroyModule` and frees the context.
## - For a kit generated with a configuration (DECISIONS I87),
##   `_MODULE_init` and `_MODULE_apply_configuration` check the
##   `configuration_input` (`checkConfigurationInput`) before any author code.
## - `_MODULE_dispatch` validates the request against the method's request
##   schema (INTERFACE §4.4, §4.5), calls the author's handler, checks the
##   response against the response schema, and returns it in a buffer that
##   `_MODULE_free` releases.
## - The typed `_CALL_` functions (§2.4) convert their C inputs and outputs with
##   the generated converters (`callrt`, `cmirror`) and share the dispatch
##   path's validation and handlers.
## - Every failure becomes a `logos_result_t` whose message and detail live in
##   thread-local storage until the next call on that thread (§2.7), which
##   zeroes them first.
## - Marked payloads (INTERFACE §1.2.1, l.380-386; DECISIONS G276): a marked
##   request is validated in the marked scope, the generated route and typed
##   entries wipe a marked method's trees and typed values, and every dispatch
##   response buffer and failure copy is zeroed once released, marked or not.
##
## Concurrency (§2.8): any entry may run on any thread, concurrently with the
## others on the same context. Each exported entry starts with `kitEnter` in
## its own frame, and every table the kit reads is per thread
## (`base/perthread`). The author's instance is shared by all calls on its
## context: its handlers must synchronize their own state. A foreign thread's
## Nim allocator state is not released when the thread exits. Under refc each
## thread has its own heap: handlers on other threads may read what
## `initModule` stored but must not store GC'd values into the instance, and
## the instance is released on the thread that calls `_MODULE_destroy`, so a
## context should be destroyed on the thread that created it (the tests do so
## under refc; under orc they also create and destroy contexts on other
## threads).
##
## A thread-confined kit (`lcn-gen kit --confined`, `codegen/confinedrt`;
## DECISIONS G335-G337) runs its instance on one module thread instead. This
## module carries what both kinds share: `ModuleServices` routes `publish` to
## the confined runtime's queue when the services belong to a confined
## context, and on a module thread the invocation-scoped operations read the
## *confined scope* the runtime sets around a plain handler (G336) instead of
## the Runtime's per-thread `current`.

{.push raises: [], gcsafe.}

import results
import ../cbor
import ../pins
import ../iface/[accept, outcome, payload]
import ../abi/[types, checks]
import ../base/[entry, libvisibility, perthread, utf8clip, wipe]
import ./[handover, nimrt]

export results, outcome, types, payload, nimrt, handover, entry

proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

type
  ModuleServices* = object
    ## The Runtime bindings one module instance received at `_MODULE_init`
    ## (INTERFACE §2.6, §5.2). They stay valid until its `_MODULE_destroy`
    ## returns. Plain pointers: an instance may keep a copy and use it from any
    ## thread.
    runtimeControl*: ptr LogosRuntimeControlBinding
    publishFn: LogosPublishFn
    publishUserData: pointer
    invocationAccess: LogosInvocationAccess
    confined: pointer ## a confined kit's context (`confinedrt`), else nil
    gate: pointer
      ## [DECISIONS G440] a confined kit's post gate value: what its poster and
      ## its dispatcher's context carry, never its context's address; else nil
    confinedPublish: ConfinedPublishFn
    dispatch: Dispatcher ## where its route handles' callbacks run (G339)

  ModuleInit* = object
    ## What `initModule` receives. The state directory and configuration are
    ## copies: the input itself is borrowed only for `_MODULE_init` (§2.6).
    services*: ModuleServices
    stateDir*: Opt[string]
    configuration*: Opt[seq[byte]]
      ## the `configuration_input` as received: in a configured kit, checked
      ## and also given to `initModule` as its typed value
    configurationRevision*: Opt[uint64]
      ## [SPEC CONFIG §6 l.226] in a configured kit, the delivered value's
      ## revision

  ConfigurationRoots* = object
    ## [SPEC CONFIG §2, §6 l.228-231] The configuration-schema commitment a
    ## module was built against: the schema root and its root type's subtree
    ## root. The other commitment fields are the pinned identifiers.
    schemaRoot*, subtreeRoot*: array[32, byte]

  CallerKind* = enum
    ckModule ## `LOGOS_CALLER_MODULE`
    ckSystemService ## `LOGOS_CALLER_SYSTEM_SERVICE`

  Caller* = object
    ## [SPEC INTERFACE §2.9.3] Authenticated origin of the active provider entry:
    ## a copy, not a permission.
    kind*: CallerKind
    runtimeInstance*: string
    moduleInstance*: Opt[string] ## none for a system-service caller

  ConfinedPublishFn* = proc(
    confined: pointer, eventId: string, data: openArray[byte]
  ): Result[void, InvocationFailure] {.nimcall, gcsafe, raises: [].}
    ## [DECISIONS G337] A confined context's instance-wide publication: queued
    ## for its publisher thread.

  ConfinedScope* = object
    ## [DECISIONS G336] What a plain handler of a confined kit acts for while
    ## it runs on the module thread: its job's captured invocation context and
    ## how that job publishes in the invocation's scope.
    invocation*: ptr LogosInvocationContext
    job*: pointer
    publish*: proc(
      job: pointer, eventId: string, data: openArray[byte]
    ): Result[void, InvocationFailure] {.nimcall, gcsafe, raises: [].}

  KitContext = object ## What `logos_module_context_t*` points to for a kit module.
    services: ModuleServices
    instance: pointer ## the author's instance, kept alive by `GC_ref`

  CreateFn* = proc(init: ModuleInit): Result[pointer, InvocationFailure] {.
    nimcall, gcsafe, raises: []
  .} ## Runs the author's `initModule` and returns its instance, `GC_ref`'d.

  DisposeFn* = proc(instance: pointer) {.nimcall, gcsafe, raises: [].}
    ## Runs the author's `destroyModule`, if any, and `GC_unref`s the instance.

  RouteFn* = proc(
    instance: pointer, bare: string, params: openArray[byte]
  ): Result[seq[byte], InvocationFailure] {.nimcall, gcsafe, raises: [].}
    ## The generated dispatch table: request bytes to response bytes.

  ApplyFn* = proc(
    instance: pointer, input: openArray[byte]
  ): Result[void, InvocationFailure] {.nimcall, gcsafe, raises: [].}
    ## Checks one `configuration_input` and runs the author's
    ## `applyConfiguration` with its typed value.

# Failures --------------------------------------------------------------------------

func failure*(code: ErrorCode, message: sink string): InvocationFailure =
  ## An invocation failure with a diagnostic message (at most 512 UTF-8 bytes;
  ## a longer one is cut at a character boundary when it is returned). The
  ## message is moved in, so a marked method's text leaves no copy (G276).
  InvocationFailure(code: code, message: Opt.some(message))

func moduleError*(message: string): InvocationFailure =
  failure(ecModule, message)

func toFailure(f: AbiFailure): InvocationFailure =
  InvocationFailure(code: f.code, message: f.message, detail: f.detail)

func clip(m: string): string =
  ## At most `MaxMessageBytes` bytes, cut at a UTF-8 boundary.
  clipUtf8(m, MaxMessageBytes)

var
  resultMessage {.threadvar.}: array[MaxMessageBytes + 1, char]
  resultDetail {.threadvar.}: array[MaxDetailBytes, uint8]
  resultUsed {.threadvar.}: int ## bytes of `resultMessage` written last
  detailUsed {.threadvar.}: int ## bytes of `resultDetail` written last

proc clearLastFailure*() =
  ## [DECISIONS G276] Zeroes this thread's last failure message and detail
  ## (§2.7: valid until the thread's next call, which runs this first).
  if resultUsed > 0:
    secureZero(addr resultMessage[0], resultUsed)
    resultUsed = 0
  if detailUsed > 0:
    secureZero(addr resultDetail[0], detailUsed)
    detailUsed = 0

template kitEnter*() =
  ## [IMPL] The first statement of every exported entry, in the entry's own
  ## frame (the kit procedures the entry calls run in deeper frames):
  ## `enterForeignThread` (`base/entry`), which registers the calling thread
  ## with this library's Nim runtime and, under refc, raises the collector's
  ## stack bottom to this frame, then the thread's last failure is cleared. A procedure a binding
  ## runs is marked `{.lcnCallback.}` instead (DECISIONS G339, G464): it may run
  ## nested inside one of this library's entries (a direct provider publishing
  ## during a call, INTERFACE l.1405), whose last failure it must not clear.
  enterForeignThread()
  clearLastFailure()

var failureHooked {.threadvar.}: bool
  ## `releaseLastFailure` is registered for this thread's release

proc releaseLastFailure() {.nimcall, gcsafe, raises: [].} =
  ## [DECISIONS G276] At the thread's end: a failure no later call cleared is
  ## zeroed before the system releases the thread's storage, which it does
  ## without zeroing it.
  clearLastFailure()
  failureHooked = false

proc okResult*(): LogosResult =
  LogosResult(code: CErrorCode(0))

proc normalizedFailure*(f: InvocationFailure): InvocationFailure =
  ## [SPEC INTERFACE §2.7, §5.1] `f` as a status carries it: the message
  ## clipped to `MaxMessageBytes`; a failure that is not a valid status (code
  ## OK, a NUL or invalid UTF-8 in the message, detail its code does not
  ## allow) becomes MODULE_ERROR without diagnostics. The caller's `f` is the
  ## caller's; the copy returned is the receiver's to zero (DECISIONS G276).
  result = f
  if result.message.isSome and result.message.get.len > MaxMessageBytes:
    # Through a local: under refc, `f.message = Opt.some(clip(f.message.get))`
    # resets the destination before the argument reads it (nim-lang/Nim#25993,
    # fixed in 2.4.0, not in 2.2.14).
    var clipped = clip(result.message.get)
    wipe(result.message)
    result.message = Opt.some(clipped)
    wipe(clipped)
  if checkFailure(result).isErr or (
    result.message.isSome and '\0' in result.message.get
  ):
    wipe(result)
    result = InvocationFailure(code: ecModule)

proc failureResult*(f: InvocationFailure): LogosResult =
  ## [SPEC INTERFACE §2.7, §5.1, §5.2] The status of a failed call. Its message
  ## and detail live in this thread's storage until the next kit call on the
  ## thread. A failure that is not a valid status (code OK, a NUL or invalid
  ## UTF-8 in the message, detail its code does not allow) becomes MODULE_ERROR
  ## without diagnostics, as an ABI caller would treat it. [DECISIONS G276] A
  ## marked method's failure text may hold its payload: every copy made here
  ## is zeroed once written; the caller's `f` is the caller's.
  var f = normalizedFailure(f)
  clearLastFailure()
  if not failureHooked:
    failureHooked = true
    onThreadRelease(releaseLastFailure)
  var r = LogosResult(code: CErrorCode(ord(f.code)))
  if f.message.isSome:
    for i, c in f.message.get:
      resultMessage[i] = c
    resultMessage[f.message.get.len] = '\0'
    resultUsed = f.message.get.len + 1
    r.message = cast[cstring](addr resultMessage[0])
  if f.detail.isSome:
    for i, b in f.detail.get:
      resultDetail[i] = b
    detailUsed = f.detail.get.len
    r.detail = cast[ptr UncheckedArray[uint8]](addr resultDetail[0])
    r.detailLen = csize_t(f.detail.get.len)
  wipe(f)
  r

# Services and the confined scope ---------------------------------------------------

var confinedScope {.threadvar.}: ptr ConfinedScope
  ## the plain handler running on this module thread, if any (G336)
  ## (`base/entry` keeps whether this thread is one: `onConfinedThread`)

proc swapConfinedScope*(scope: ptr ConfinedScope): ptr ConfinedScope =
  ## [DECISIONS G336] Sets this module thread's confined scope and returns the
  ## one it replaces, which the caller puts back.
  result = confinedScope
  confinedScope = scope

proc moduleServices*(input: ptr LogosModuleInitInput): ModuleServices =
  ## The bindings of a checked initialization input (`checkInitInput`).
  ModuleServices(
    runtimeControl: input.runtimeControl,
    publishFn: input.publish,
    publishUserData: input.publishUserData,
    invocationAccess: input.invocationAccess,
  )

proc withConfined*(
    s: ModuleServices,
    confined, gate: pointer,
    publish: ConfinedPublishFn,
    post: PostTaskFn,
): ModuleServices =
  ## [DECISIONS G337, G339, G440] `s` for an instance of the confined context
  ## `confined`: its events are queued by `publish`, and its route handles'
  ## callbacks are posted to its module thread by `post` through `gate`, the
  ## context's post gate value.
  result = s
  result.confined = confined
  result.gate = gate
  result.confinedPublish = publish
  result.dispatch = Dispatcher(context: gate, post: post)

proc dispatcher*(s: ModuleServices): Dispatcher =
  ## [DECISIONS G339, P2] What the consumer helpers wrap this instance's route
  ## handles with (`routes.newRouteSet`, `consumert.wrapRoute`): a confined
  ## kit's module thread, or none (callbacks run in the delivery).
  s.dispatch

proc confinedOf*(s: ModuleServices): pointer =
  ## The confined context these services belong to; nil for a plain kit.
  s.confined

proc gateOf*(s: ModuleServices): pointer =
  ## [DECISIONS G440] The post gate value of the confined context these
  ## services belong to; nil for a plain kit. Reads no context memory.
  s.gate

proc hasPublish*(s: ModuleServices): bool =
  not s.publishFn.isNil

proc callPublish*(
    s: ModuleServices, eventId: cstring, data: ptr UncheckedArray[uint8], len: int
): int64 =
  ## The instance's publish callback, called as it is (its raw result).
  int64(s.publishFn(s.publishUserData, eventId, data, csize_t(len)))

proc publishCode*(rc: int64, eventId: string): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE §5.1, App A.4] A publish callback's result: a result
  ## outside the shared registry is MODULE_ERROR.
  let code = errorCode(rc).valueOr:
    return err(moduleError("the publish callback returned code " & $rc))
  if code == ecOk:
    return ok()
  err(failure(code, "the publish callback refused " & eventId))

# Contexts --------------------------------------------------------------------------

func context(module: ptr LogosModuleContext): ptr KitContext =
  cast[ptr KitContext](module)

proc instanceOf*(module: ptr LogosModuleContext): pointer =
  ## The author's instance behind a live context (§2.6: a null, foreign or
  ## destroyed context violates the caller's precondition).
  module.context.instance

proc servicesOf*(module: ptr LogosModuleContext): ModuleServices =
  module.context.services

proc copyBytes(p: ptr UncheckedArray[uint8], len: csize_t): seq[byte] =
  result = newSeq[byte](int(len))
  for i in 0 ..< int(len):
    result[i] = p[i]

proc moduleInit*(
    input: ptr LogosModuleInitInput, services: ModuleServices
): ModuleInit =
  ## [SPEC INTERFACE §2.6] What `initModule` receives for a checked input
  ## (`checkInitInput`): the state directory and configuration copied, since
  ## the input is borrowed only for `_MODULE_init`.
  result = ModuleInit(services: services)
  if input.stateDir != nil:
    result.stateDir = Opt.some($input.stateDir)
  if input.configurationCbor != nil:
    result.configuration =
      Opt.some(copyBytes(input.configurationCbor, input.configurationCborLen))

proc kitInit*(
    input: ptr LogosModuleInitInput,
    outContext: ptr ptr LogosModuleContext,
    declaresEvents: bool,
    create: CreateFn,
): LogosResult =
  ## [SPEC INTERFACE §2.6] `_MODULE_init`: check the input, copy the borrowed
  ## state directory and configuration, create the author's instance and return
  ## a distinct non-null context; on failure a nonzero code and a null context.
  if outContext == nil:
    return failureResult(moduleError("null out_context"))
  outContext[] = nil
  checkInitInput(input, declaresEvents).isOkOr:
    return failureResult(failure(error.code, error.reason))
  let init = moduleInit(input, moduleServices(input))
  # The C allocator, not Nim's: `_MODULE_destroy` may free the context on
  # another thread after this one has exited.
  let c = cast[ptr KitContext](cMalloc(csize_t(sizeof(KitContext))))
  if c == nil:
    return failureResult(moduleError("out of memory for the module context"))
  let instance = create(init).valueOr:
    cFree(c)
    return failureResult(error)
  c[] = KitContext(services: init.services, instance: instance)
  outContext[] = cast[ptr LogosModuleContext](c)
  okResult()

proc kitDestroy*(module: ptr LogosModuleContext, dispose: DisposeFn) =
  ## [SPEC INTERFACE §2.6, §2.8] `_MODULE_destroy`: the caller has quiesced the
  ## context; the author's hook stops its own work before this returns.
  if module == nil:
    return
  let c = module.context
  dispose(c.instance)
  cFree(c)

const ResponseHeader = 16
  ## [IMPL] A dispatch response buffer starts 16 bytes into its block, after
  ## its length, so `_MODULE_free` can zero it (DECISIONS G276).

proc kitFree*(module: ptr LogosModuleContext, p: pointer) =
  ## [SPEC INTERFACE §2.7] `_MODULE_free`: zeroes and releases a dispatch
  ## response buffer; null is a no-op. Thread-safe: the buffers come from the C
  ## allocator.
  if p == nil:
    return
  let base = cast[pointer](cast[uint](p) - ResponseHeader)
  let n = int(cast[ptr uint64](base)[])
  secureZero(base, ResponseHeader + n)
  cFree(base)

proc storeResponse*(
    response: openArray[byte],
    outResponse: ptr ptr UncheckedArray[uint8],
    outResponseLen: ptr csize_t,
): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE §2.7] Copies a dispatch response into a buffer from the C
  ## allocator that `_MODULE_free` releases, and sets the outputs.
  let n = response.len
  let base = cMalloc(csize_t(ResponseHeader + n))
  if base == nil:
    return err(moduleError("out of memory for the response"))
  cast[ptr uint64](base)[] = uint64(n)
  let buffer = cast[ptr UncheckedArray[uint8]](cast[uint](base) + ResponseHeader)
  for i, b in response:
    buffer[i] = b
  outResponse[] = buffer
  outResponseLen[] = csize_t(n)
  ok()

proc kitDispatch*(
    module: ptr LogosModuleContext,
    methodName: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outResponse: ptr ptr UncheckedArray[uint8],
    outResponseLen: ptr csize_t,
    route: RouteFn,
): LogosResult =
  ## [SPEC INTERFACE §2.6, §2.7, App A.3] `_MODULE_dispatch`: on success one
  ## response map in a buffer from the C allocator; on failure a nonzero code
  ## with null and zero outputs.
  if outResponse == nil or outResponseLen == nil:
    return failureResult(moduleError("null response outputs"))
  outResponse[] = nil
  outResponseLen[] = 0
  if methodName == nil:
    return failureResult(failure(ecMethodNotFound, "null method"))
  if params == nil and paramsLen != 0:
    return failureResult(failure(ecInvalidParams, "null params with a length"))
  let bare = $methodName
  # [DECISIONS G276] The response bytes and a failure's text are zeroed once
  # copied out, for every method: the kit runtime does not ask which is marked.
  var response =
    if paramsLen == 0:
      route(module.context.instance, bare, [])
    else:
      route(module.context.instance, bare, params.toOpenArray(0, int(paramsLen) - 1))
  if response.isErr:
    result = failureResult(response.error)
    wipe(response)
    return
  let stored = storeResponse(response.get, outResponse, outResponseLen)
  wipe(response)
  if stored.isErr:
    return failureResult(stored.error)
  okResult()

proc kitApply*(
    module: ptr LogosModuleContext,
    configuration: ptr UncheckedArray[uint8],
    len: csize_t,
    apply: ApplyFn,
): LogosResult =
  ## [SPEC INTERFACE §2.6; CONFIG §8 l.258-266] `_MODULE_apply_configuration`:
  ## one complete `configuration_input`, always present (INTERFACE §5.2);
  ## `LOGOS_OK` once the author reports that the new value governs.
  if module == nil:
    return failureResult(moduleError("null module context"))
  checkConfigurationBytes(configuration, len, required = true).isOkOr:
    return failureResult(failure(error.code, error.reason))
  let r = apply(module.context.instance, configuration.toOpenArray(0, int(len) - 1))
  if r.isErr:
    return failureResult(r.error)
  okResult()

# Configuration (DECISIONS I87) -----------------------------------------------------

proc sameCommitment(v: CborValue, expected: ConfigurationRoots): bool =
  ## [SPEC CONFIG l.228-231] Field by field, against the pinned identifiers
  ## and the module's own roots.
  if v.entries.len != 5:
    return false
  template field(name: string, want: CborValue): bool =
    let f = v.lookup(name)
    f.isSome and f.get == want

  field("commitment_model", cbor(CommitmentModelId)) and
    field("schema_root", cbor(expected.schemaRoot)) and
    field("schema_subtree_root", cbor(expected.subtreeRoot)) and
    field("hash_profile", cbor(HashProfileId)) and field(
    "hash_suite", cbor(HashSuiteId)
  )

proc checkConfigurationInput*(
    bytes: openArray[byte],
    expected: ConfigurationRoots,
    schema: GeneratedSchema,
    root: string,
): Result[(CborValue, uint64), InvocationFailure] =
  ## [SPEC CONFIG §6 l.226-231 (CFG-0068..0071)] One
  ## `logos.module_configuration.configuration_input` as `_MODULE_init` or
  ## `_MODULE_apply_configuration` receives it, for a handwritten Nim module
  ## as for the generated glue: its value, checked against `root` of
  ## `schema`, and its value revision. [IMPL] Bytes that are not a
  ## `configuration_input` are INVALID_PARAMS; a schema commitment other than
  ## `expected` is VERSION_MISMATCH before the value is read (as CONFIG l.196
  ## answers a stale commitment); a value that is not a deterministic-CBOR
  ## value of `root` is INVALID_PARAMS.
  let input = decodePayload(bytes).valueOr:
    return err(failure(ecInvalidParams, "the configuration input is not one value"))
  let
    commitment = input.lookup("schema_commitment")
    value = input.lookup("value")
    revision = input.lookup("value_revision")
  if input.kind != ckMap or input.entries.len != 3 or commitment.isNone or value.isNone or
      revision.isNone or commitment.get.kind != ckMap or value.get.kind != ckBytes or
      revision.get.kind != ckUint:
    return err(failure(ecInvalidParams, "the configuration input is not one"))
  if not sameCommitment(commitment.get, expected):
    return err(
      failure(
        ecVersionMismatch, "the configuration is for another configuration schema"
      )
    )
  let data = value.get.bytes
  if data.len < 1 or data.len > 8_388_608:
    return
      err(failure(ecInvalidParams, "the configuration value has 1 to 8388608 bytes"))
  let v = decodePayload(data).valueOr:
    return err(failure(ecInvalidParams, "the configuration value is not one value"))
  schema.check(root, v).isOkOr:
    return err(failure(ecInvalidParams, "the configuration value is not a " & root))
  ok((v, revision.get.uint))

proc kitConfiguration*(
    init: var ModuleInit,
    expected: ConfigurationRoots,
    schema: GeneratedSchema,
    root: string,
): Result[CborValue, InvocationFailure] =
  ## [SPEC CONFIG §6 l.222-231] A configured kit's `_MODULE_init`: the input
  ## carries a configuration (else INVALID_PARAMS [IMPL]) that
  ## `checkConfigurationInput` accepts. Sets `configurationRevision`.
  if init.configuration.isNone:
    return err(failure(ecInvalidParams, "the module declares a configuration"))
  let (v, revision) =
    ?checkConfigurationInput(init.configuration.get, expected, schema, root)
  init.configurationRevision = Opt.some(revision)
  ok(v)

proc kitNoConfiguration*(init: ModuleInit): Result[void, InvocationFailure] =
  ## [SPEC CONFIG §6 l.222] A kit generated without a configuration receives
  ## none: INVALID_PARAMS before any author code [IMPL].
  if init.configuration.isSome:
    return err(failure(ecInvalidParams, "the module declares no configuration"))
  ok()

# Dispatch helpers ------------------------------------------------------------------

proc loadValidator*(
    primary: string, interfaces, supporting: openArray[string], system: bool
): ContractValidator =
  ## The validator of the documents a kit was generated from. A failure means
  ## this library no longer accepts them: regenerate the kit.
  let s =
    acceptContractSet(primary, interfaces, supporting, AcceptOptions(system: system))
  doAssert s.isOk, "module kit: its schema set is not accepted: " & s.error
  validator(s.get)

proc loadBindingValidator*(
    module: string, interfaces, supporting: openArray[string], system: bool
): ContractValidator =
  ## [DECISIONS G339] The validator of an interface-only binding a kit was
  ## generated from (INTERFACE l.2833-2835): no primary document, `interfaces`
  ## as the implemented set. A failure means this library no longer accepts
  ## them: regenerate the kit.
  let b = acceptBinding(
    module, Opt.none(string), interfaces, supporting, AcceptOptions(system: system)
  )
  doAssert b.isOk, "module kit: its binding is not accepted: " & b.error
  validator(b.get)

proc checkedRequest*(
    v: ContractValidator, bare: string, params: openArray[byte]
): Result[CborValue, InvocationFailure] =
  ## [SPEC INTERFACE §4.3, §4.5] The request of a call to `bare`:
  ## METHOD_NOT_FOUND for a method the contract set does not expose (the
  ## well-known `schema` included: the kit is never given the route's selected
  ## contract, App A.3), INVALID_PARAMS with its detail for bytes that are not
  ## a deterministic-CBOR value of the request schema. A marked request is
  ## validated in the marked scope: one the schema rejects is wiped, and its
  ## detail path stops before the value's own keys (DECISIONS G276, G278).
  markedScope(v.marked(bare).request):
    result = v.checkParams(bare, params).mapErr(toFailure)

proc encodedResponse*(
    r: sink Result[seq[byte], string]
): Result[seq[byte], InvocationFailure] =
  ## A handler's response as the generated `encode` checked it against the
  ## response schema: one that does not match is not a contract response, so
  ## the call fails in the module (MODULE_ERROR, INTERFACE §4.3). The bytes are
  ## moved, not copied (DECISIONS G276).
  var r = r
  if r.isErr:
    return err(moduleError("the response does not match its schema: " & r.error))
  ok(move r.get)

# Services --------------------------------------------------------------------------

proc publishEncoded*(
    s: ModuleServices, eventId: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE §2.5, §2.6, §5.2, App A.4] Publishes one encoded event
  ## through the instance's publish callback and returns its result, which is
  ## the publisher-side check and never a delivery report. NOT_READY when the
  ## instance has none (a null callback must not be called); a result outside
  ## the shared registry is MODULE_ERROR (§5.1).
  ## In a confined kit (DECISIONS G337) the event is queued for the context's
  ## publisher thread instead, and the result is the kit's check.
  if s.publishFn.isNil:
    return err(failure(ecNotReady, "this instance has no publish callback"))
  if data.len == 0:
    return err(moduleError("an event payload is one CBOR map"))
  if s.confined != nil:
    return s.confinedPublish(s.confined, eventId, data)
  publishCode(
    s.callPublish(
      system.cstring(eventId), cast[ptr UncheckedArray[uint8]](addr data[0]), data.len
    ),
    eventId,
  )

proc currentContext*(s: ModuleServices): ptr LogosInvocationContext =
  ## [SPEC INTERFACE §2.9.3] The Runtime's invocation context for the provider
  ## entry active on this thread, as its invocation access answers.
  s.invocationAccess.current(s.invocationAccess.state)

proc currentInvocation(s: ModuleServices): ptr LogosInvocationContext =
  if onConfinedThread():
    # [DECISIONS G336] A module thread acts only for the job whose plain
    # handler it runs.
    return (if confinedScope == nil: nil else: confinedScope.invocation)
  s.currentContext()

proc activeInvocation(
    s: ModuleServices
): Result[ptr LogosInvocationContext, InvocationFailure] =
  let c = s.currentInvocation()
  if c == nil:
    if onConfinedThread():
      return err(
        failure(
          ecNotReady,
          "no plain handler runs on this module thread (an async handler uses its Invocation)",
        )
      )
    return err(failure(ecNotReady, "no active provider entry on this thread"))
  checkInvocationContext(c).isOkOr:
    return err(moduleError(error.reason))
  ok(c)

proc publishVia*(
    c: ptr LogosInvocationContext, eventId: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE §2.9.3] One publication through the invocation context
  ## `c`, called on this thread; its status as the context gave it.
  let r = c.vtable.publish(
    c,
    system.cstring(eventId),
    cast[ptr UncheckedArray[uint8]](addr data[0]),
    csize_t(data.len),
  )
  readStatus(r).mapErr(toFailure)

proc publishScopedEncoded*(
    s: ModuleServices, eventId: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE §2.9.3] Invocation-scoped publication through the active
  ## provider entry's context; its status is returned as the context gave it.
  ## A confined kit's plain handler publishes through its job (G337).
  let c = ?s.activeInvocation()
  if data.len == 0:
    return err(moduleError("an event payload is one CBOR map"))
  if onConfinedThread() and confinedScope.publish != nil:
    return confinedScope.publish(confinedScope.job, eventId, data)
  publishVia(c, eventId, data)

proc isCancelledAt*(c: ptr LogosInvocationContext): bool =
  ## [SPEC INTERFACE §2.9.3] Whether the invocation of the context `c` was
  ## cancelled; false for a null or invalid context.
  if c == nil or checkInvocationContext(c).isErr:
    return false
  c.vtable.isCancelled(c)

proc isCancelled*(s: ModuleServices): bool =
  ## [SPEC INTERFACE §2.9.3] Whether the active provider entry's invocation was
  ## cancelled; false outside a provider entry.
  isCancelledAt(s.currentInvocation())

func text(v: LogosUtf8View): string =
  result = newString(int(v.len))
  for i in 0 ..< int(v.len):
    result[i] = char(v.data[i])

proc callerAt*(c: ptr LogosInvocationContext): Result[Caller, InvocationFailure] =
  ## [SPEC INTERFACE §2.9.3] The authenticated origin of the invocation of the
  ## checked context `c`, copied.
  var view: LogosCallerView
  ?readStatus(c.vtable.caller(c, addr view)).mapErr(toFailure)
  checkCallerView(view).isOkOr:
    return err(moduleError(error.reason))
  if view.kind == CallerModule:
    ok(
      Caller(
        kind: ckModule,
        runtimeInstance: text(view.runtimeInstanceId),
        moduleInstance: Opt.some(text(view.moduleInstanceId)),
      )
    )
  else:
    ok(Caller(kind: ckSystemService, runtimeInstance: text(view.runtimeInstanceId)))

proc caller*(s: ModuleServices): Result[Caller, InvocationFailure] =
  ## [SPEC INTERFACE §2.9.3] The authenticated origin of the active provider
  ## entry, copied.
  callerAt(?s.activeInvocation())
