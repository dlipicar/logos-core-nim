## Runtime Control through a module's binding, for Nim modules [IMPL]
## (INTERFACE §2.9, §5.2; RUNTIME §9.3; DECISIONS I94).
##
## A module that holds a `ptr LogosRuntimeControlBinding` (`ModuleServices.
## runtimeControl`) calls the Runtime through it alone (RUNTIME l.182-184):
##
## - `call` sends a typed request (`runtime/rc_types.nim`, types only) by the
##   method's bare name and decodes the typed response. Results are checked
##   as INTERFACE §5.2 requires of a consumer (`checkOutcome`); a buffer handed
##   over with LOGOS_OK is released exactly once, even when it is rejected.
## - `prepare` makes an asynchronous call (`prepare_call`); `submit`, `cancel`
##   and `release` act on it. `readCompletion` turns a completion into a code
##   and a copy of the response in shared memory, and releases the response
##   owner; it allocates nothing the garbage collector owns that outlives it,
##   so it may run on the Runtime's thread that delivers the completion.
## - `subscribe` and `unsubscribe` take a module's event handler.
##
## The binding is never used after the module's `_MODULE_destroy` returns, and
## `release` of an asynchronous call is never made from that call's own
## completion (INTERFACE l.2085).

{.push raises: [], gcsafe.}

import results
import ../abi/[checks, types]
import ../iface/outcome
import ../runtime/rc_types

export results, types, outcome, rc_types

type
  RcFailure* = object ## A refused or failed call: its code and message.
    code*: ErrorCode
    message*: string

  SharedBytes* = object ## A response copied into shared memory; `free` once used.
    data*: ptr UncheckedArray[byte]
    len*: int

func rcFailure*(code: ErrorCode, message: string): RcFailure =
  RcFailure(code: code, message: message)

func failureOf(f: AbiFailure): RcFailure =
  RcFailure(code: f.code, message: if f.message.isSome: f.message.get else: f.reason)

func `$`*(f: RcFailure): string =
  $f.code & (if f.message.len > 0: ": " & f.message else: "")

proc checkBinding*(rc: ptr LogosRuntimeControlBinding): Result[void, RcFailure] =
  ## [SPEC INTERFACE §5.2] The binding as its consumer checks it before use.
  checkRuntimeControl(rc).mapErr(failureOf)

proc callBytes*(
    rc: ptr LogosRuntimeControlBinding, bare: string, params: openArray[byte]
): Result[seq[byte], RcFailure] =
  ## [SPEC INTERFACE §5.2] One synchronous call: the response's bytes, copied
  ## before the buffer is released.
  var buffer: ptr UncheckedArray[uint8] = nil
  var len: csize_t = 0
  let p =
    if params.len == 0:
      nil
    else:
      cast[ptr UncheckedArray[uint8]](unsafeAddr params[0])
  let r =
    rc.vtable.call(rc, cstring(bare), p, csize_t(params.len), addr buffer, addr len)
  checkOutcome(r, bufferShape(buffer, len)).isOkOr:
    if transfersBuffer(r, buffer):
      rc.vtable.releaseResponse(rc, buffer, len)
    return err(failureOf(error))
  var bytes = newSeq[byte](int(len))
  if len > 0:
    copyMem(addr bytes[0], buffer, int(len))
  rc.vtable.releaseResponse(rc, buffer, len)
  ok(bytes)

proc call*[Req, Resp](
    rc: ptr LogosRuntimeControlBinding, bare: string, req: Req, resp: typedesc[Resp]
): Result[Resp, RcFailure] =
  ## One typed synchronous call. A request with no encoding fails locally,
  ## INVALID_PARAMS; a response that does not decode is MODULE_ERROR.
  let params = encode(req).valueOr:
    return err(rcFailure(ecInvalidParams, "the request has no encoding: " & error))
  let bytes = ?callBytes(rc, bare, params)
  let r = Resp.decode(bytes)
  if r.isErr:
    return
      err(rcFailure(ecModule, "the " & bare & " response does not decode: " & r.error))
  ok(r.get)

proc prepareBytes*(
    rc: ptr LogosRuntimeControlBinding,
    bare: string,
    params: openArray[byte],
    complete: LogosAsyncCompleteFn,
    userData: pointer,
    outCall: var LogosAsyncCall,
): Result[void, RcFailure] =
  ## [SPEC INTERFACE §2.9.1] An asynchronous call, prepared and not yet
  ## submitted. On failure no call exists and `outCall` is empty.
  outCall = LogosAsyncCall()
  var options = LogosAsyncOptions(
    abiVersion: AsyncCallAbiVersion, structSize: csize_t(sizeof(LogosAsyncOptions))
  )
  var callbacks = LogosAsyncCallbacks(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncCallbacks)),
    complete: complete,
    userData: userData,
  )
  let p =
    if params.len == 0:
      nil
    else:
      cast[ptr UncheckedArray[uint8]](unsafeAddr params[0])
  let r = rc.vtable.prepareCall(
    rc,
    cstring(bare),
    p,
    csize_t(params.len),
    addr options,
    addr callbacks,
    addr outCall,
  )
  let shaped = checkOutcome(r, handleShape(outCall.vtable, outCall.state))
  if shaped.isErr:
    # A success-shaped handle that fails the check is still a call to release.
    if int64(r.code) == 0 and outCall.vtable != nil and outCall.state != nil and
        checkAsyncCall(addr outCall).isOk:
      outCall.vtable.release(addr outCall)
    outCall = LogosAsyncCall()
    return err(failureOf(shaped.error))
  checkAsyncCall(addr outCall).isOkOr:
    outCall = LogosAsyncCall()
    return err(failureOf(error))
  ok()

proc prepare*[Req](
    rc: ptr LogosRuntimeControlBinding,
    bare: string,
    req: Req,
    complete: LogosAsyncCompleteFn,
    userData: pointer,
    outCall: var LogosAsyncCall,
): Result[void, RcFailure] =
  ## A typed request, prepared asynchronously.
  let params = encode(req).valueOr:
    return err(rcFailure(ecInvalidParams, "the request has no encoding: " & error))
  prepareBytes(rc, bare, params, complete, userData, outCall)

proc submit*(c: var LogosAsyncCall) =
  c.vtable.submit(addr c)

proc cancel*(c: var LogosAsyncCall) =
  c.vtable.cancel(addr c)

proc release*(c: var LogosAsyncCall) =
  ## [SPEC INTERFACE l.2079-2087] Ends the call: cancels it if it has no
  ## outcome and waits for a completion that is running. Never from that
  ## call's own completion.
  if c.vtable != nil:
    c.vtable.release(addr c)
  c = LogosAsyncCall()

proc free*(b: var SharedBytes) =
  if b.data != nil:
    deallocShared(b.data)
  b = SharedBytes()

proc readCompletion*(
    status: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
): (ErrorCode, SharedBytes) =
  ## [SPEC INTERFACE §2.9.1, §2.9.2] A completion as its receiver reads it: the
  ## code (MODULE_ERROR for a combination the rule rejects) and, on success, a
  ## copy of the response in shared memory. A valid owner is released on every
  ## path, after the copy.
  var code = ecOk
  var copy = SharedBytes()
  let st = checkOutcome(status, completionShape(response, len, owner))
  if st.isErr:
    code = st.error.code
  elif response != nil and len > 0:
    copy.len = int(len)
    copy.data = cast[ptr UncheckedArray[byte]](allocShared(copy.len))
    copyMem(copy.data, response, copy.len)
  if ownerValid(owner) and owner.release != nil:
    owner.release(owner.state)
  (code, copy)

proc decodeShared*[Resp](b: SharedBytes, resp: typedesc[Resp]): Result[Resp, string] =
  if b.data == nil or b.len == 0:
    return err("no response")
  Resp.decode(b.data.toOpenArray(0, b.len - 1))

proc subscribe*(
    rc: ptr LogosRuntimeControlBinding,
    event: string,
    handler: LogosEventHandler,
    userData: pointer,
): Result[LogosSubscriptionId, RcFailure] =
  ## [SPEC INTERFACE l.3837; G178] The handler runs on a Runtime thread, one
  ## delivery at a time per subscription.
  var id: LogosSubscriptionId = 0
  readStatus(rc.vtable.subscribe(rc, cstring(event), handler, userData, addr id)).isOkOr:
    return err(failureOf(error))
  ok(id)

proc unsubscribe*(
    rc: ptr LogosRuntimeControlBinding, id: LogosSubscriptionId
): Result[void, RcFailure] =
  ## [SPEC INTERFACE §2.5] Waits for a delivery that is running, unless it is
  ## the handler's own.
  readStatus(rc.vtable.unsubscribe(rc, id)).mapErr(failureOf)

{.pop.}
