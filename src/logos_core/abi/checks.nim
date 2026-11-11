## INTERFACE §2.4, §2.6, §2.7.1, §2.9, §5.2: the checks one side of the native
## module ABI applies to what the other side hands it, as pure procs over the
## `types.nim` structs. They read only the memory the ABI says is readable (a
## version-bearing struct up to its `struct_size`, a message up to one byte past
## its limit) and call nothing through a pointer they check.
##
## Codes. The spec fixes them for binding and versioned-struct validation:
## VERSION_MISMATCH for an unsupported version or too small an extent,
## MODULE_ERROR for a null vtable, state or required operation that the
## binding's producer supplied, INVALID_PARAMS for malformed callback or option
## input to `prepare_call`. Where it only requires some nonzero code (an
## initialization input that breaks a rule a module checks, a provider
## invocation that breaks its rules), these procs follow the same split [I66].
##
## Order [I66]: a null pointer, then the version and extent, then the null
## members, then values; the first failure is reported.

{.push raises: [].}

import results
import ../cbor
import ../cbor/utf8
import ../iface/outcome
from ../iface/surface import MaxSchemaResponseBytes
import ./types

export results, outcome, types

type
  AbiFailure* = object
    ## What the checking side reports: the code, and the diagnostics it may
    ## forward (only a producer's own valid failure status carries them).
    code*: ErrorCode
    message*: Opt[string]
    detail*: Opt[seq[byte]]
    reason*: string
      ## Why the check failed, for local logs; empty when the failure is the
      ## producer's own valid status. Never forwarded.

  AbiCheck* = Result[void, AbiFailure]

  OutputShape* = object
    ## What a call left in its outputs. `success`: everything a success
    ## requires; `failure`: everything still at its caller-initialized value.
    ## Neither (or, for a typed call, both by coincidence) is decided by the
    ## result code in `checkOutcome`.
    success*: bool
    failure*: bool

func reject(code: ErrorCode, reason: string): AbiCheck =
  err(AbiFailure(code: code, reason: reason))

func moduleFailure(reason: string): AbiCheck =
  ## [SPEC INTERFACE §2.4, §2.6] a combination the caller must treat as a
  ## module failure; nothing the call wrote is forwarded.
  reject(ecModule, reason)

func versioned(
    what: string, version: uint32, size: csize_t, supported: uint32, extent: int
): AbiCheck =
  ## [SPEC INTERFACE §5.2] An unsupported version, or a `struct_size` too small
  ## for every field that version defines, is VERSION_MISMATCH. A larger size is
  ## fields appended by a later compatible revision and is accepted.
  if version != supported:
    return reject(
      ecVersionMismatch,
      what & ": unsupported version " & $version & " (supported: " & $supported & ")",
    )
  if size < csize_t(extent):
    return reject(
      ecVersionMismatch,
      what & ": struct_size " & $size & " is below the " & $extent & " bytes version " &
        $supported & " defines",
    )
  ok()

func firstNull(ops: openArray[(string, pointer)]): Opt[string] =
  for (name, p) in ops:
    if p == nil:
      return Opt.some(name)
  Opt.none(string)

template requireOps(what: string, code: ErrorCode, ops: openArray[(string, pointer)]) =
  let missing = firstNull(ops)
  if missing.isSome:
    return reject(code, what & ": null required operation " & missing.get)

# Bindings: Runtime Control, route, async call -----------------------------------

func checkRuntimeControl*(b: ptr LogosRuntimeControlBinding): AbiCheck =
  ## [SPEC INTERFACE §5.2] A Runtime Control binding as its consumer must check
  ## it before any use: vtable, state, version 2, the full version-2 extent and
  ## every operation. A rejected binding is not used, not even to `release` it.
  const what = "Runtime Control binding"
  if b == nil or b.vtable == nil:
    return reject(ecModule, what & ": null vtable")
  if b.state == nil:
    return reject(ecModule, what & ": null state")
  let v = b.vtable
  ?versioned(
    what, v.abiVersion, v.structSize, RuntimeControlVtableAbiVersion,
    RuntimeControlVtableV2Extent,
  )
  requireOps(
    what,
    ecModule,
    [
      ("call", cast[pointer](v.call)),
      ("release_response", cast[pointer](v.releaseResponse)),
      ("subscribe", cast[pointer](v.subscribe)),
      ("unsubscribe", cast[pointer](v.unsubscribe)),
      ("materialize_route", cast[pointer](v.materializeRoute)),
      ("connect_remote", cast[pointer](v.connectRemote)),
      ("release", cast[pointer](v.release)),
      ("prepare_call", cast[pointer](v.prepareCall)),
    ],
  )
  ok()

func checkRoute*(r: ptr LogosRouteHandle): AbiCheck =
  ## [SPEC INTERFACE §5.2] A route handle as its consumer must check it; a
  ## version-2 vtable too short to hold the required `observe_end` is
  ## VERSION_MISMATCH.
  const what = "route handle"
  if r == nil or r.vtable == nil:
    return reject(ecModule, what & ": null vtable")
  if r.state == nil:
    return reject(ecModule, what & ": null state")
  let v = r.vtable
  ?versioned(
    what, v.abiVersion, v.structSize, RouteVtableAbiVersion, RouteVtableV2Extent
  )
  requireOps(
    what,
    ecModule,
    [
      ("call", cast[pointer](v.call)),
      ("release_response", cast[pointer](v.releaseResponse)),
      ("subscribe", cast[pointer](v.subscribe)),
      ("unsubscribe", cast[pointer](v.unsubscribe)),
      ("release", cast[pointer](v.release)),
      ("prepare_call", cast[pointer](v.prepareCall)),
      ("observe_end", cast[pointer](v.observeEnd)),
    ],
  )
  ok()

func checkAsyncCall*(c: ptr LogosAsyncCall): AbiCheck =
  ## [SPEC INTERFACE §2.9.1, §5.2] A prepared call, checked through its vtable
  ## like any producer-supplied binding.
  const what = "async call"
  if c == nil or c.vtable == nil:
    return reject(ecModule, what & ": null vtable")
  if c.state == nil:
    return reject(ecModule, what & ": null state")
  let v = c.vtable
  ?versioned(
    what, v.abiVersion, v.structSize, AsyncCallAbiVersion, AsyncCallVtableV1Extent
  )
  requireOps(
    what,
    ecModule,
    [
      ("submit", cast[pointer](v.submit)),
      ("cancel", cast[pointer](v.cancel)),
      ("release", cast[pointer](v.release)),
    ],
  )
  ok()

# Initialization input -------------------------------------------------------------

template view(p: ptr UncheckedArray[uint8], len: csize_t): untyped =
  ## The borrowed bytes `p[0 ..< len]`; only used with a non-null `p` and a
  ## nonzero `len`.
  toOpenArray(cast[ptr UncheckedArray[byte]](p), 0, int(len) - 1)

func checkConfigurationBytes*(
    p: ptr UncheckedArray[uint8], len: csize_t, required: bool
): AbiCheck =
  ## [SPEC INTERFACE §5.2] Configuration bytes are absent exactly when the
  ## pointer is null and the length zero; present, they hold exactly one
  ## deterministic-CBOR value. `required` for `_MODULE_apply_configuration`,
  ## which always passes one. Its schema and meaning are CONFIGURATION's. A
  ## violation is INVALID_PARAMS [I66].
  if p == nil and len == 0:
    if required:
      return reject(ecInvalidParams, "configuration: absent")
    return ok()
  if p == nil or len == 0:
    return reject(ecInvalidParams, "configuration: pointer and length disagree")
  let r = decodeCbor(view(p, len))
  if r.isErr:
    return reject(
      ecInvalidParams, "configuration: not one deterministic-CBOR value: " & $r.error
    )
  ok()

func checkInitInput*(input: ptr LogosModuleInitInput, declaresEvents: bool): AbiCheck =
  ## [SPEC INTERFACE §2.6, §5.2] What `_MODULE_init()` checks before using its
  ## input. `declaresEvents`: the module's validated call surface declares an
  ## event, so `publish` is required. Version and extent are VERSION_MISMATCH
  ## (§5.2, with a null context); a null required member MODULE_ERROR and a
  ## malformed value INVALID_PARAMS [I66].
  const what = "initialization input"
  if input == nil:
    return reject(ecModule, what & ": null")
  ?versioned(
    what, input.abiVersion, input.structSize, ModuleInitAbiVersion, InitInputV2Extent
  )
  if input.runtimeControl == nil:
    return reject(ecModule, what & ": null runtime_control")
  ?checkRuntimeControl(input.runtimeControl)
  if input.invocationAccess.state == nil:
    return reject(ecModule, what & ": null invocation_access.state")
  if input.invocationAccess.current.isNil:
    return reject(ecModule, what & ": null invocation_access.current")
  if declaresEvents and input.publish.isNil:
    return
      reject(ecModule, what & ": the call surface declares events but publish is null")
  ?checkConfigurationBytes(
    input.configurationCbor, input.configurationCborLen, required = false
  )
  if input.stateDir != nil:
    let dir = $input.stateDir
    if not isValidUtf8(dir):
      return reject(ecInvalidParams, what & ": state_dir is not UTF-8")
  ok()

# Results and outputs --------------------------------------------------------------

func readMessage(m: cstring): Result[Opt[string], string] =
  ## A message of at most 512 bytes before its NUL, read without looking past
  ## the 513th byte.
  if m == nil:
    return ok(Opt.none(string))
  let bytes = cast[ptr UncheckedArray[char]](m)
  var s = newStringOfCap(64)
  for i in 0 .. MaxMessageBytes:
    if bytes[i] == '\0':
      return ok(Opt.some(s))
    s.add bytes[i]
  err("message is longer than " & $MaxMessageBytes & " bytes")

func readDetail(
    p: ptr UncheckedArray[uint8], len: csize_t
): Result[Opt[seq[byte]], string] =
  ## [SPEC INTERFACE §5.2] Absent exactly when null and zero; present exactly
  ## when non-null with 1 to 4096 bytes; every other combination is invalid.
  if p == nil and len == 0:
    return ok(Opt.none(seq[byte]))
  if p == nil or len == 0 or len > csize_t(MaxDetailBytes):
    return err("detail pointer and length are invalid")
  ok(Opt.some(@(view(p, len))))

proc readStatus*(r: LogosResult): AbiCheck =
  ## [SPEC INTERFACE §5.1, §5.2] A status as its receiver copies it: `ok()` for
  ## LOGOS_OK with no message and no detail; a valid failure status (allocated
  ## nonzero code, message of at most 512 UTF-8 bytes, only the detail its code
  ## allows) with its diagnostics copied; anything else MODULE_ERROR with
  ## neither, as `checkedProviderStatus` does.
  let msg = readMessage(r.message)
  if msg.isErr:
    return moduleFailure("invalid status: " & msg.error)
  let det = readDetail(r.detail, r.detailLen)
  if det.isErr:
    return moduleFailure("invalid status: " & det.error)
  let code = errorCode(int64(r.code)).valueOr:
    return moduleFailure("invalid status: unallocated code " & $int64(r.code))
  let st = checkStatus(code, msg.get, det.get)
  if st.isErr:
    return moduleFailure("invalid status: " & st.error)
  if code == ecOk:
    return ok()
  err(AbiFailure(code: code, message: msg.get, detail: det.get))

proc checkOutcome*(r: LogosResult, outputs: OutputShape): AbiCheck =
  ## [SPEC INTERFACE §2.4, §2.6, §2.9.1, §5.2] The combination rule shared by
  ## `_MODULE_init`, `_MODULE_dispatch`, typed provider calls, the Runtime
  ## Control and route `call`, `materialize_route`, `connect_remote`,
  ## `prepare_call` and completion: success is LOGOS_OK, no message, no detail
  ## and every output a success requires; failure is a valid nonzero status
  ## with every output still at its initial value. Any other combination is
  ## MODULE_ERROR without diagnostics, and the caller uses and releases nothing
  ## the call wrote (for a Runtime Control or route `call`, where the spec only
  ## says "reject", the same code [I66]).
  if int64(r.code) == 0:
    if not outputs.success:
      return moduleFailure("LOGOS_OK without the outputs a success requires")
    return readStatus(r)
  if not outputs.failure:
    return moduleFailure("a failure that wrote its outputs")
  readStatus(r)

func bufferShape*(p: pointer, len: csize_t): OutputShape =
  ## A response buffer the caller initialized to null and zero (`_MODULE_dispatch`,
  ## Runtime Control and route `call`).
  OutputShape(success: p != nil and len > 0, failure: p == nil and len == 0)

func handleShape*(vtable, state: pointer): OutputShape =
  ## A route handle, acquired binding or prepared call the caller initialized to
  ## two null pointers.
  OutputShape(
    success: vtable != nil and state != nil, failure: vtable == nil and state == nil
  )

func contextShape*(context: ptr LogosModuleContext): OutputShape =
  ## `_MODULE_init`'s `*out_context`, initialized to null.
  OutputShape(success: context != nil, failure: context == nil)

func ownerEmpty*(o: LogosResponseOwner): bool =
  ## [SPEC INTERFACE §2.7.1] Both members null.
  o.state == nil and o.release.isNil

func ownerValid*(o: LogosResponseOwner): bool =
  ## [SPEC INTERFACE §2.7.1] Empty, or a non-null `release` (its state may be
  ## null).
  ownerEmpty(o) or not o.release.isNil

func typedShape*(owner: LogosResponseOwner, untouched, complete: bool): OutputShape =
  ## [SPEC INTERFACE §2.4] A typed provider call: success needs a valid owner
  ## and complete canonical outputs (`complete`, which the generated caller
  ## decides); failure needs the owner and every output object still zero
  ## (`untouched`).
  OutputShape(
    success: ownerValid(owner) and complete, failure: ownerEmpty(owner) and untouched
  )

func completionShape*(
    response: ptr UncheckedArray[uint8], len: csize_t, owner: LogosResponseOwner
): OutputShape =
  ## [SPEC INTERFACE §2.9.1, §2.9.2] A completion: success supplies a non-null,
  ## nonzero response and failure a null, zero one; an owner may accompany
  ## either but must be valid. The receiver clears a valid owner on every path.
  let valid = ownerValid(owner)
  OutputShape(
    success: valid and response != nil and len > 0,
    failure: valid and response == nil and len == 0,
  )

# Asynchronous calls and provider completion -------------------------------------

func checkAsyncOptions*(o: ptr LogosAsyncOptions): AbiCheck =
  ## [SPEC INTERFACE §5.2] `prepare_call` options: VERSION_MISMATCH for the
  ## version or extent; a null pointer is malformed option input,
  ## INVALID_PARAMS [I66].
  if o == nil:
    return reject(ecInvalidParams, "async options: null")
  versioned(
    "async options", o.abiVersion, o.structSize, AsyncCallAbiVersion,
    AsyncOptionsV1Extent,
  )

func checkAsyncCallbacks*(c: ptr LogosAsyncCallbacks): AbiCheck =
  ## [SPEC INTERFACE §5.2] `prepare_call` callbacks: VERSION_MISMATCH for the
  ## version or extent, INVALID_PARAMS for a null pointer or `complete`.
  if c == nil:
    return reject(ecInvalidParams, "async callbacks: null")
  ?versioned(
    "async callbacks", c.abiVersion, c.structSize, AsyncCallAbiVersion,
    AsyncCallbacksV1Extent,
  )
  if c.complete.isNil:
    return reject(ecInvalidParams, "async callbacks: null complete")
  ok()

func checkAsyncProviderApi*(api: ptr LogosAsyncProviderApi): AbiCheck =
  ## [SPEC INTERFACE §2.9.2] What `_MODULE_async_api()` returned: null is an
  ## absent capability; a descriptor needs version 1, the full extent and
  ## `submit` (`request_cancel` may be null). A rejected descriptor is an
  ## implementation-binding failure and is never invoked.
  if api == nil:
    return ok()
  const what = "async provider descriptor"
  ?versioned(
    what, api.abiVersion, api.structSize, AsyncProviderAbiVersion,
    AsyncProviderApiV1Extent,
  )
  if api.submit.isNil:
    return reject(ecModule, what & ": null required operation submit")
  ok()

func checkInvocationContext*(c: ptr LogosInvocationContext): AbiCheck =
  ## [SPEC INTERFACE §2.9.3, §5.2] A protected invocation context: vtable,
  ## state, version 1, the full extent and all three operations.
  const what = "invocation context"
  if c == nil or c.vtable == nil:
    return reject(ecModule, what & ": null vtable")
  if c.state == nil:
    return reject(ecModule, what & ": null state")
  let v = c.vtable
  ?versioned(
    what, v.abiVersion, v.structSize, InvocationContextAbiVersion,
    InvocationContextVtableV1Extent,
  )
  requireOps(
    what,
    ecModule,
    [
      ("caller", cast[pointer](v.caller)),
      ("is_cancelled", cast[pointer](v.isCancelled)),
      ("publish", cast[pointer](v.publish)),
    ],
  )
  ok()

func checkProviderInvocation*(inv: ptr LogosProviderInvocation): AbiCheck =
  ## [SPEC INTERFACE §2.9.2, §5.2] The invocation the Runtime passes to the
  ## descriptor's `submit`: version 1 and its extent, a method, request bytes,
  ## a valid context and both operations. MODULE_ERROR for a null member [I66].
  const what = "provider invocation"
  if inv == nil:
    return reject(ecModule, what & ": null")
  ?versioned(
    what, inv.abiVersion, inv.structSize, AsyncProviderAbiVersion,
    ProviderInvocationV1Extent,
  )
  requireOps(
    what,
    ecModule,
    [
      ("complete", cast[pointer](inv.complete)),
      ("execution_release", cast[pointer](inv.executionRelease)),
    ],
  )
  if inv.`method` == nil:
    return reject(ecModule, what & ": null method")
  if inv.paramsCbor == nil or inv.paramsCborLen == 0:
    return reject(ecModule, what & ": no request bytes")
  checkInvocationContext(inv.context)

func checkUtf8View(v: LogosUtf8View, present: bool): bool =
  if not present:
    return v.data == nil and v.len == 0
  v.data != nil and v.len > 0 and isValidUtf8(view(v.data, v.len))

func checkCallerView*(v: LogosCallerView): AbiCheck =
  ## [SPEC INTERFACE §2.9.3] A caller view from a successful `caller` query: a
  ## module caller has both identifiers; a system-service caller has the
  ## Runtime identifier and a null, zero-length module view. Identifiers are
  ## nonempty UTF-8 without a NUL terminator requirement. Any other value is
  ## MODULE_ERROR [I66].
  case v.kind
  of CallerModule:
    if not checkUtf8View(v.runtimeInstanceId, true) or
        not checkUtf8View(v.moduleInstanceId, true):
      return reject(ecModule, "caller view: a module caller needs both identifiers")
  of CallerSystemService:
    if not checkUtf8View(v.runtimeInstanceId, true) or
        not checkUtf8View(v.moduleInstanceId, false):
      return reject(
        ecModule,
        "caller view: a system-service caller has a Runtime identifier and no module identifier",
      )
  else:
    return reject(ecModule, "caller view: unknown kind " & $v.kind)
  ok()

# Inputs the Runtime checks ---------------------------------------------------------

func checkMaterializeInput*(
    routeId: cstring,
    expectedRoot: ptr ContractRoot,
    schema: ptr UncheckedArray[uint8],
    schemaLen: csize_t,
): AbiCheck =
  ## [SPEC INTERFACE §5.2] The shape of `materialize_route`'s input before its
  ## construction input is decoded: a route identifier, a 32-byte root and
  ## 1 to 8,388,608 schema bytes. Malformed input is INVALID_PARAMS.
  if routeId == nil:
    return reject(ecInvalidParams, "materialize_route: null route_id")
  if expectedRoot == nil:
    return reject(ecInvalidParams, "materialize_route: null expected_contract_root")
  if schema == nil or schemaLen == 0 or schemaLen > csize_t(MaxSchemaResponseBytes):
    return reject(
      ecInvalidParams, "materialize_route: schema_cbor is not 1 to 8,388,608 bytes"
    )
  ok()

func checkConnectRemoteInput*(
    endpoint: ptr UncheckedArray[uint8],
    endpointLen: csize_t,
    expectedRoot: ptr ContractRoot,
): AbiCheck =
  ## [SPEC INTERFACE §5.2] The shape of `connect_remote`'s input before the
  ## endpoint is decoded: endpoint bytes and a 32-byte root, else
  ## INVALID_PARAMS without detail [I66].
  if endpoint == nil or endpointLen == 0:
    return reject(ecInvalidParams, "connect_remote: no endpoint bytes")
  if expectedRoot == nil:
    return reject(ecInvalidParams, "connect_remote: null expected_contract_root")
  ok()
