## Runtime support for lcn-gen's typed call helpers [IMPL] (INTERFACE §2.7.2,
## §5.2, App A.5).
##
## A generated `<stem>_calls.nim` calls a method through a consumer's route
## handle. Nim callers get `invoke(route, <Request>)`, and C callers get the
## helpers of `<stem>_calls.h` once a module instantiates its export template.
## Both go through `routeCall`:
##
## 1. It checks the route handle as its consumer must (`checkRoute`), then
##    sets the response outputs to null and zero.
## 2. It calls the route's `call` with the bare method name and the request's
##    deterministic CBOR.
## 3. It checks the result and buffer together (`checkOutcome`). Any other
##    combination than a valid failure status with no buffer, or LOGOS_OK
##    with a buffer, is MODULE_ERROR, and the caller uses and releases
##    nothing the call wrote (I66). A valid failure is returned with its
##    code, message and detail.
## 4. After a success, it decodes the buffer into a CBOR value the Nim heap
##    owns, then passes the exact pointer and length to `release_response`
##    once. It does so even when the bytes turn out not to be a response,
##    since a success-shaped result has already transferred the buffer
##    (§2.7). Nothing returned refers to the released buffer.
## 5. Last, it checks the value against the method's response schema. A
##    value that is not one deterministic-CBOR item, or that the schema
##    rejects, is MODULE_ERROR.
##
## The C helpers then write the outputs as a typed provider call does
## (`callrt`): one arena of C-allocated blocks becomes the response owner, a
## failure releases it and leaves the owner and outputs untouched. Their
## cleanup helpers clear the owner and zero every output object, never reading
## through the outputs (§2.7.2).
##
## A request without a deterministic-CBOR encoding fails locally with
## INVALID_PARAMS, without validation detail, before the route is called: a C
## input the converters cannot read (a null text, an unknown discriminant, a
## cyclic value), and request bytes that do not decode as one deterministic
## item within the depth limit (text that is not UTF-8, nesting past
## `MaxConvertDepth`). Anything else goes to the route, whose provider
## validates it against the request schema. Results returned to a C caller keep
## their message and detail in this thread's storage until its next helper or
## kit call (§2.7).

{.push raises: [], gcsafe.}

import results
import ../cbor
import ../abi/[checks, types]
import ../base/perthread
import ./[callrt, kitrt, nimrt]

export results, cbor, checks, types, perthread, callrt, kitrt, nimrt

func toFailure(f: AbiFailure): InvocationFailure =
  ## A producer's valid failure status as it gave it; any other rejection as
  ## the helper's own failure, with the reason as its message.
  if f.message.isSome or f.detail.isSome or f.reason.len == 0:
    InvocationFailure(code: f.code, message: f.message, detail: f.detail)
  else:
    failure(f.code, "route call: " & f.reason)

proc routeCall*(
    route: ptr LogosRouteHandle,
    bare: string,
    params: openArray[byte],
    schema: GeneratedSchema,
    response: string,
): Result[CborValue, InvocationFailure] =
  ## [SPEC INTERFACE §5.2, §2.7.2] The checked response value of the method
  ## `bare` (whose response declaration is `response`) called through `route`
  ## with the request bytes `params`.
  checkRoute(route).isOkOr:
    return err(toFailure(error))
  # The bytes the route gets are one deterministic-CBOR item within the depth
  # limit: text that is not UTF-8, or nesting past the limit, stops here.
  decodeCbor(params).isOkOr:
    return
      err(failure(ecInvalidParams, "the request has no deterministic CBOR: " & $error))
  var buffer: ptr UncheckedArray[uint8] = nil
  var len: csize_t = 0
  let r = route.vtable.call(
    route,
    cstring(bare),
    cast[ptr UncheckedArray[uint8]](unsafeAddr params[0]),
    csize_t(params.len),
    addr buffer,
    addr len,
  )
  checkOutcome(r, bufferShape(buffer, len)).isOkOr:
    return err(toFailure(error))
  var decoded = Result[CborValue, string].err("a response longer than memory")
  if len <= csize_t(high(int)):
    let d = decodeCbor(buffer.toOpenArray(0, int(len) - 1))
    decoded =
      if d.isOk:
        Result[CborValue, string].ok(d.get)
      else:
        Result[CborValue, string].err($d.error)
  route.vtable.releaseResponse(route, buffer, len)
  let v = decoded.valueOr:
    return err(
      moduleError("the route's response is not one deterministic-CBOR item: " & error)
    )
  schema.check(response, v).isOkOr:
    return err(moduleError("the route's response does not match its schema: " & error))
  ok(v)

proc clearOwner*(owner: ptr LogosResponseOwner) =
  ## [SPEC INTERFACE §2.7.1] `logos_response_owner_clear`: empty the owner
  ## first, then release what it held. A null owner is left alone [IMPL].
  if owner == nil:
    return
  let previous = owner[]
  owner[] = LogosResponseOwner()
  if not previous.release.isNil:
    previous.release(previous.state)

proc resetOutput*[T](p: ptr T) =
  ## [SPEC INTERFACE §2.7.2] One output object as a C `{0}` initializer leaves
  ## it, without reading it. A null output is left alone [IMPL].
  if p != nil:
    zeroMem(p, sizeof(T))
