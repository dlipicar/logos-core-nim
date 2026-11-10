## INTERFACE §4.1-§4.5: validating method params, response results and event data.
##
## The module dispatch layer owns payload validation (§4.5): bytes are first
## decoded under Logos deterministic CBOR (§4.4), then validated against the
## selected request, response or event declaration. Every rejection says which
## shared code applies and, for `INVALID_PARAMS`, the `logos.invalid_params_detail`
## reason and the path to the offending item.

{.push raises: [].}

import ../cbor
import ../commitment
import ./[surface, outcome]

export surface, outcome

type
  PayloadError* = object
    code*: ErrorCode
    reason*: Opt[InvalidParamsReason]
      ## none when no detail applies: an unknown method, or nesting past the
      ## decoder cap (G59)
    path*: seq[CborValue] ## from the payload's root to the offending item
    msg*: string

  ContractValidator* = object
    ## Validates payloads for every callable of one accepted contract set.
    contracts*: ContractSet
    surface*: CallSurface
    sets: seq[SchemaSet] ## one per `contracts.documents` entry

func validator*(s: ContractSet): ContractValidator =
  var v = ContractValidator(contracts: s, surface: s.callSurface)
  for c in s.documents:
    v.sets.add(schemaSetFor(c.model, s.context))
  v

func failure(code: ErrorCode, reason: InvalidParamsReason, msg: string): PayloadError =
  PayloadError(code: code, reason: Opt.some(reason), msg: msg)

func decodePayload*(
    data: openArray[byte], code = ecInvalidParams
): Result[CborValue, PayloadError] =
  ## [SPEC INTERFACE §4.4, §4.5] One complete Logos deterministic-CBOR item.
  ## Text that is not UTF-8 decodes, so the schema check can reject it as a
  ## schema mismatch at its path (§4.5).
  var opts = defaultDecodeOptions()
  opts.allowInvalidUtf8 = true
  let v = decodeCbor(data, opts).valueOr:
    return
      case error.kind
      of cekMalformed:
        err(failure(code, iprMalformedCbor, $error))
      of cekNonDeterministic:
        err(failure(code, iprNonDeterministicCbor, $error))
      of cekInvalidUtf8:
        err(failure(code, iprSchemaMismatch, $error))
      of cekTooDeep:
        # [IMPL-DECISION G59] Over the depth cap: INVALID_PARAMS without detail.
        err(PayloadError(code: code, msg: $error))
  ok(v)

func validateAgainst(
    v: ContractValidator, doc: int, declaration: string, x: CborValue, code: ErrorCode
): Result[void, PayloadError] =
  let set = v.sets[doc]
  let d = set.docs[0].find(declaration)
  if d.isNone:
    return err(PayloadError(code: code, msg: declaration & " is not declared"))
  set.validatePath(0, d.get.body, x).isOkOr:
    return err(
      PayloadError(
        code: code,
        reason: Opt.some(iprSchemaMismatch),
        path: error,
        msg: "the value does not match " & declaration,
      )
    )
  ok()

func checkParams*(
    v: ContractValidator, methodName: string, data: openArray[byte]
): Result[CborValue, PayloadError] =
  ## [SPEC INTERFACE §4.3, §4.5] The params map of a call to the bare method
  ## name `methodName`: an unknown name is METHOD_NOT_FOUND; bytes that are not
  ## deterministic CBOR, or not a value of the request schema, are
  ## INVALID_PARAMS. A rejected value never reaches the provider.
  let m = v.surface.findMethod(methodName).valueOr:
    return
      err(PayloadError(code: ecMethodNotFound, msg: "unknown method " & methodName))
  let x = ?decodePayload(data)
  ?v.validateAgainst(m.doc, m.request, x, ecInvalidParams)
  ok(x)

func checkResult*(
    v: ContractValidator, methodName: string, data: openArray[byte]
): Result[CborValue, PayloadError] =
  ## [SPEC INTERFACE §4.3] The result map a provider returned with `LOGOS_OK`.
  ## One outside its response schema is not a contract response: the
  ## invocation failed in the module (MODULE_ERROR) [IMPL].
  let m = v.surface.findMethod(methodName).valueOr:
    return
      err(PayloadError(code: ecMethodNotFound, msg: "unknown method " & methodName))
  let x = ?decodePayload(data, ecModule)
  ?v.validateAgainst(m.doc, m.response, x, ecModule)
  ok(x)

func checkEvent*(
    v: ContractValidator, eventId: string, data: openArray[byte]
): Result[CborValue, PayloadError] =
  ## [SPEC INTERFACE §2.5, §4.3] Event data: exactly one deterministic-CBOR map of
  ## the selected event's type, for an event the contract declares.
  let e = v.surface.findEvent(eventId).valueOr:
    return err(PayloadError(code: ecInvalidParams, msg: "unknown event " & eventId))
  let x = ?decodePayload(data)
  ?v.validateAgainst(e.doc, e.id, x, ecInvalidParams)
  ok(x)

func toFailure*(e: PayloadError): InvocationFailure =
  ## The invocation failure a dispatcher returns for a rejected payload. Only
  ## INVALID_PARAMS carries detail; it describes the caller's own input.
  ## A schema mismatch names the path to the offending item (empty: the value
  ## itself).
  var f = InvocationFailure(code: e.code)
  if e.code == ecInvalidParams and e.reason.isSome:
    let path =
      if e.reason.get == iprSchemaMismatch:
        Opt.some(e.path)
      else:
        Opt.none(seq[CborValue])
    f.detail = Opt.some(invalidParamsDetail(e.reason.get, path))
  f
