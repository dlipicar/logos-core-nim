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
## - `_MODULE_dispatch` validates the request against the method's request
##   schema (INTERFACE §4.4, §4.5), calls the author's handler, checks the
##   response against the response schema, and returns it in a buffer that
##   `_MODULE_free` releases.
## - The typed `_CALL_` functions (§2.4) convert their C inputs and outputs with
##   the generated converters (`callrt`, `cmirror`) and share the dispatch
##   path's validation and handlers.
## - Every failure becomes a `logos_result_t` whose message and detail live in
##   thread-local storage until the next call on that thread (§2.7).
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

{.push raises: [], gcsafe.}

import results
import ../cbor
import ../iface/[accept, outcome, payload]
import ../abi/[types, checks]
import ../base/[libvisibility, perthread]

export results, outcome, types, payload

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

  ModuleInit* = object
    ## What `initModule` receives. The state directory and configuration are
    ## copies: the input itself is borrowed only for `_MODULE_init` (§2.6).
    services*: ModuleServices
    stateDir*: Opt[string]
    configuration*: Opt[seq[byte]] ## one deterministic-CBOR value, unvalidated

  CallerKind* = enum
    ckModule ## `LOGOS_CALLER_MODULE`
    ckSystemService ## `LOGOS_CALLER_SYSTEM_SERVICE`

  Caller* = object
    ## [SPEC INTERFACE §2.9.3] Authenticated origin of the active provider entry:
    ## a copy, not a permission.
    kind*: CallerKind
    runtimeInstance*: string
    moduleInstance*: Opt[string] ## none for a system-service caller

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

template kitEnter*() =
  ## [IMPL] The first statement of every exported entry, in the entry's own
  ## frame (the procedures below run in deeper frames). Registers the calling
  ## thread with this library's Nim runtime (`setupForeignThreadGc` is
  ## idempotent) and, under refc, raises the collector's stack bottom to this
  ## frame: refc scans only between the stack pointer and the bottom it
  ## recorded, and a shared library's runtime starts in a load-time constructor
  ## deeper in the stack than the calls that come later. Without it refc takes
  ## the entry's stack slots for heap slots.
  setupForeignThreadGc()
  enterThread()
  when not defined(gcDestructors):
    var kitStackBottom {.volatile, noinit.}: pointer
    nimGC_setStackBottom(addr kitStackBottom)

# Failures --------------------------------------------------------------------------

func failure*(code: ErrorCode, message: string): InvocationFailure =
  ## An invocation failure with a diagnostic message (at most 512 UTF-8 bytes;
  ## a longer one is cut at a character boundary when it is returned).
  InvocationFailure(code: code, message: Opt.some(message))

func moduleError*(message: string): InvocationFailure =
  failure(ecModule, message)

func toFailure(f: AbiFailure): InvocationFailure =
  InvocationFailure(code: f.code, message: f.message, detail: f.detail)

func clip(m: string): string =
  ## At most `MaxMessageBytes` bytes, cut before a continuation byte.
  if m.len <= MaxMessageBytes:
    return m
  var n = MaxMessageBytes
  while n > 0 and (uint8(m[n]) and 0xC0'u8) == 0x80'u8:
    dec n
  m[0 ..< n]

var
  resultMessage {.threadvar.}: array[MaxMessageBytes + 1, char]
  resultDetail {.threadvar.}: array[MaxDetailBytes, uint8]

proc okResult*(): LogosResult =
  LogosResult(code: CErrorCode(0))

proc failureResult*(f: InvocationFailure): LogosResult =
  ## [SPEC INTERFACE §2.7, §5.1, §5.2] The status of a failed call. Its message
  ## and detail live in this thread's storage until the next kit call on the
  ## thread. A failure that is not a valid status (code OK, a NUL or invalid
  ## UTF-8 in the message, detail its code does not allow) becomes MODULE_ERROR
  ## without diagnostics, as an ABI caller would treat it.
  var f = f
  if f.message.isSome:
    # Through a local: under refc, `f.message = Opt.some(clip(f.message.get))`
    # resets the destination before the argument reads it (nim-lang/Nim#25993,
    # fixed in 2.4.0, not in 2.2.14).
    let clipped = clip(f.message.get)
    f.message = Opt.some(clipped)
  if checkFailure(f).isErr or (f.message.isSome and '\0' in f.message.get):
    f = InvocationFailure(code: ecModule)
  var r = LogosResult(code: CErrorCode(ord(f.code)))
  if f.message.isSome:
    let m = f.message.get
    for i, c in m:
      resultMessage[i] = c
    resultMessage[m.len] = '\0'
    r.message = cast[cstring](addr resultMessage[0])
  if f.detail.isSome:
    let d = f.detail.get
    for i, b in d:
      resultDetail[i] = b
    r.detail = cast[ptr UncheckedArray[uint8]](addr resultDetail[0])
    r.detailLen = csize_t(d.len)
  r

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
  var init = ModuleInit(
    services: ModuleServices(
      runtimeControl: input.runtimeControl,
      publishFn: input.publish,
      publishUserData: input.publishUserData,
      invocationAccess: input.invocationAccess,
    )
  )
  if input.stateDir != nil:
    init.stateDir = Opt.some($input.stateDir)
  if input.configurationCbor != nil:
    init.configuration =
      Opt.some(copyBytes(input.configurationCbor, input.configurationCborLen))
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

proc kitFree*(module: ptr LogosModuleContext, p: pointer) =
  ## [SPEC INTERFACE §2.7] `_MODULE_free`: releases a dispatch response buffer;
  ## null is a no-op. Thread-safe: the buffers come from the C allocator.
  cFree(p)

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
  let response =
    if paramsLen == 0:
      route(module.context.instance, bare, [])
    else:
      route(module.context.instance, bare, params.toOpenArray(0, int(paramsLen) - 1))
  if response.isErr:
    return failureResult(response.error)
  let bytes = response.get
  let buffer = cast[ptr UncheckedArray[uint8]](cMalloc(csize_t(bytes.len)))
  if buffer == nil:
    return failureResult(moduleError("out of memory for the response"))
  for i, b in bytes:
    buffer[i] = b
  outResponse[] = buffer
  outResponseLen[] = csize_t(bytes.len)
  okResult()

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

proc checkedRequest*(
    v: ContractValidator, bare: string, params: openArray[byte]
): Result[CborValue, InvocationFailure] =
  ## [SPEC INTERFACE §4.3, §4.5] The request of a call to `bare`:
  ## METHOD_NOT_FOUND for a method the contract set does not expose (the
  ## well-known `schema` included: the kit is never given the route's selected
  ## contract, App A.3), INVALID_PARAMS with its detail for bytes that are not
  ## a deterministic-CBOR value of the request schema.
  v.checkParams(bare, params).mapErr(toFailure)

proc encodedResponse*(
    r: Result[seq[byte], string]
): Result[seq[byte], InvocationFailure] =
  ## A handler's response as the generated `encode` checked it against the
  ## response schema: one that does not match is not a contract response, so
  ## the call fails in the module (MODULE_ERROR, INTERFACE §4.3).
  if r.isErr:
    return err(moduleError("the response does not match its schema: " & r.error))
  ok(r.get)

# Services --------------------------------------------------------------------------

proc publishEncoded*(
    s: ModuleServices, eventId: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE §2.5, §2.6, App A.4] Publishes one encoded event through
  ## the instance's publish callback. NOT_READY when the instance has none (a
  ## null callback must not be called). The callback returns nothing, so
  ## success says only that the event was handed over.
  if s.publishFn.isNil:
    return err(failure(ecNotReady, "this instance has no publish callback"))
  if data.len == 0:
    return err(moduleError("an event payload is one CBOR map"))
  s.publishFn(
    s.publishUserData,
    system.cstring(eventId),
    cast[ptr UncheckedArray[uint8]](addr data[0]),
    csize_t(data.len),
  )
  ok()

proc currentInvocation(s: ModuleServices): ptr LogosInvocationContext =
  s.invocationAccess.current(s.invocationAccess.state)

proc activeInvocation(
    s: ModuleServices
): Result[ptr LogosInvocationContext, InvocationFailure] =
  let c = s.currentInvocation()
  if c == nil:
    return err(failure(ecNotReady, "no active provider entry on this thread"))
  checkInvocationContext(c).isOkOr:
    return err(moduleError(error.reason))
  ok(c)

proc publishScopedEncoded*(
    s: ModuleServices, eventId: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [SPEC INTERFACE §2.9.3] Invocation-scoped publication through the active
  ## provider entry's context; its status is returned as the context gave it.
  let c = ?s.activeInvocation()
  if data.len == 0:
    return err(moduleError("an event payload is one CBOR map"))
  let r = c.vtable.publish(
    c,
    system.cstring(eventId),
    cast[ptr UncheckedArray[uint8]](addr data[0]),
    csize_t(data.len),
  )
  readStatus(r).mapErr(toFailure)

proc isCancelled*(s: ModuleServices): bool =
  ## [SPEC INTERFACE §2.9.3] Whether the active provider entry's invocation was
  ## cancelled; false outside a provider entry.
  let c = s.currentInvocation()
  if c == nil or checkInvocationContext(c).isErr:
    return false
  c.vtable.isCancelled(c)

func text(v: LogosUtf8View): string =
  result = newString(int(v.len))
  for i in 0 ..< int(v.len):
    result[i] = char(v.data[i])

proc caller*(s: ModuleServices): Result[Caller, InvocationFailure] =
  ## [SPEC INTERFACE §2.9.3] The authenticated origin of the active provider
  ## entry, copied.
  let c = ?s.activeInvocation()
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
