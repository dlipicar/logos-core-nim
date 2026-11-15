## RUNTIME §4.1 l.833-841, §7.3 l.1221-1227; INTERFACE §5.1: the payload checks
## of a call and an event, which a hosted provider's Module Host runs too
## (Tier 4b step 4b-3, part 4b-3.2; plan §2.7 [Rev R14]; RUN-0815).
##
## A selected contract (`Selected`) is rebuilt from its construction input, a
## `logos.schema_response` whose primary contract is the selected root, on
## each thread that uses it. The checks here read nothing else, so the Runtime
## (`invoke.nim`, `events.nim`, `asynccall.nim`) and a Module Host
## (`host/endpoint.nim`) run the same code on the same payload.

{.push raises: [], gcsafe.}

import results
import ../cbor
import ../abi/cstatus
import ../hash/hashinput
import ../iface/[accept, outcome, payload, surface]
import ../transport/boundary
import ./callaudit

export boundary, callaudit

type Selected* = object ## One selected contract, as this thread loaded it.
  boundary*: Boundary
  validator*: ContractValidator

proc buildSelected*(
    schema: openArray[byte], root: Digest, depth: int
): Result[Selected, string] =
  ## [SPEC INTERFACE §5.1] The contract `root` from its construction input,
  ## with payloads nested at most `depth` deep.
  let set = ?acceptSchemaResponse(schema, root, AcceptOptions(system: true))
  let bd = ?boundary(set, root)
  let v = ?validator(set, depth)
  ok(Selected(boundary: bd, validator: v))

proc buildSelected*(
    set: ContractSet, root: Digest, depth: int
): Result[Selected, string] =
  let bd = ?boundary(set, root)
  let v = ?validator(set, depth)
  ok(Selected(boundary: bd, validator: v))

func marked*(sel: Selected, bare: string): tuple[request, response: bool] =
  ## [SPEC INTERFACE §1.2.1] Which payloads of method `bare` `_sensitive` marks.
  sel.boundary.marked(bare)

proc checkRequestIn(
    sel: Selected, bare: string, params: openArray[byte], trail: var CallTrail
): Result[CborValue, InvocationFailure] =
  let request =
    if sel.validator.surface.findMethod(bare).isSome:
      sel.validator.checkParams(bare, params).valueOr:
        return err(toFailure(error))
    else:
      decodePayload(params, maxDepth = sel.validator.maxDepth).valueOr:
        return err(toFailure(error))
  let c = sel.boundary.commitRequest(bare, request).valueOr:
    wipe(request) # [DECISIONS G276] refused: nothing else holds it
    return err(error.failure)
  trail.request = Opt.some(c)
  ok(request)

proc checkRequest*(
    sel: Selected, bare: string, params: openArray[byte], trail: var CallTrail
): Result[CborValue, InvocationFailure] =
  ## [SPEC RUNTIME §4.1 l.833-841, l.852-853] A request is validated and
  ## committed before provider code runs; `logos.schema` is the boundary's.
  ## [RUN-0332; I85] The commitment is kept in `trail`. A marked request is
  ## checked in the marked scope, and its tree, once returned, is the caller's
  ## to wipe after dispatch; a refused one is wiped here [DECISIONS G276].
  markedScope(sel.marked(bare).request):
    result = checkRequestIn(sel, bare, params, trail)

proc checkRequest*(
    sel: Selected, bare: string, params: openArray[byte]
): Result[CborValue, InvocationFailure] =
  var trail: CallTrail
  checkRequest(sel, bare, params, trail)

proc checkResponse*(
    sel: Selected, bare: string, bytes: openArray[byte], trail: var CallTrail
): Result[void, InvocationFailure] =
  ## [SPEC RUNTIME §4.1 l.838-840] A response that does not validate or commit
  ## is not returned as a success. [RUN-0332; I85] Its commitment is kept in
  ## `trail`. A marked response is checked in the marked scope and its tree
  ## wiped before return [DECISIONS G276].
  let marked = sel.marked(bare).response
  markedScope(marked):
    let response = sel.validator.checkResult(bare, bytes).valueOr:
      return err(failure(ecModule, "the provider's response does not match its schema"))
    let c = sel.boundary.commitResponse(bare, response)
    if marked or c.isErr:
      wipe(response)
    if c.isErr:
      return err(failure(ecModule, "the provider's response cannot be committed"))
    trail.response = Opt.some(c.get)
  ok()

proc notReadyAfter*(
    sel: Result[Selected, string],
    bare: string,
    params: openArray[byte],
    f: InvocationFailure,
): InvocationFailure =
  ## [G171 interim (TF-18)] A call the Runtime thread answered NOT_READY is
  ## authorized; its payload is validated before readiness is reported.
  if f.code == ecNotReady and sel.isOk:
    let r = checkRequest(sel.get, bare, params)
    if r.isErr:
      return r.error
    if sel.get.marked(bare).request:
      wipe(r.get) # [DECISIONS G276]
  f

proc introspect*(
    sel: Selected,
    bare: string,
    params: openArray[byte],
    schema: openArray[byte],
    trail: var CallTrail,
): Result[seq[byte], InvocationFailure] =
  ## [SPEC INTERFACE §5.1; RUNTIME §9.3 l.2990-2992] `logos.schema`: the
  ## selected contract's `logos.schema_response`, from the boundary, whose
  ## commitments are under the common schema (CA l.1203-1204). [SPEC RUNTIME
  ## l.432-434] `schema` is that response built from the provider's validated
  ## surface; the request is checked first (DECISIONS I88).
  discard ?checkRequest(sel, bare, params, trail)
  if schema.len == 0:
    return err(failure(ecModule, "the schema response cannot be built"))
  let v = decodeCbor(schema).valueOr:
    return err(failure(ecModule, "the schema response cannot be built"))
  let c = sel.boundary.commitResponse(bare, v).valueOr:
    return err(failure(ecModule, "the schema response cannot be committed"))
  trail.response = Opt.some(c)
  ok(@schema)

proc checkEvent*(
    sel: Selected, name: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [SPEC RUNTIME l.1221-1227, l.1233-1235] The name resolves under the
  ## selected contract (NOT_AUTHORISED otherwise); the payload is one value of
  ## its event-data type; its commitment is computed before delivery.
  if not sel.boundary.knowsEvent(name):
    return
      err(failure(ecNotAuthorised, name & " is not an event of the selected contract"))
  let v = sel.validator.checkEvent(name, data).valueOr:
    return err(toFailure(error))
  discard sel.boundary.commitEvent(name, v).valueOr:
    return err(error.failure)
  ok()
