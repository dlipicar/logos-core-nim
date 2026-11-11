## INTERFACE §4.1-§4.5: validating method params, response results and event data.
##
## The module dispatch layer owns payload validation (§4.5): bytes are first
## decoded under Logos deterministic CBOR (§4.4), then validated against the
## selected request, response or event declaration. Every rejection says which
## shared code applies and, for `INVALID_PARAMS`, the `logos.invalid_params_detail`
## reason and the path to the offending item.
##
## Payload depth [SPEC INTERFACE §4.5.1]: arrays and maps nest at most
## `maxDepth` levels on any path, a documented, finite and configurable limit of
## at least 128 (`MinMaxDepth`); the default is `DefaultMaxDepth` (1024)
## [IMPL-DECISION G59]. The decoder checks it before descending into a container.

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
      ## payload depth limit (§4.5.1)
    path*: seq[CborValue]
      ## from the rejected value's root to the offending item: the request,
      ## response or event value, or for `configuration-schema-mismatch` the
      ## decoded configuration value
    msg*: string

  ContractValidator* = object
    ## Validates payloads for every callable of one accepted contract set.
    contracts*: ContractSet
    surface*: CallSurface
    maxDepth*: int ## [SPEC INTERFACE §4.5.1] the payload depth limit, >= 128
    sets: seq[SchemaSet] ## one per `contracts.documents` entry

func newValidator(s: ContractSet, maxDepth: int): ContractValidator =
  var v = ContractValidator(contracts: s, surface: s.callSurface, maxDepth: maxDepth)
  for c in s.documents:
    v.sets.add(schemaSetFor(c.model, s.context))
  v

func validator*(s: ContractSet): ContractValidator =
  ## A validator with the default payload depth limit, `DefaultMaxDepth`.
  newValidator(s, DefaultMaxDepth)

func validator*(s: ContractSet, maxDepth: int): Result[ContractValidator, string] =
  ## [SPEC INTERFACE §4.5.1] A validator with a configured payload depth limit;
  ## a limit below 128 is not a conforming configuration.
  if maxDepth < MinMaxDepth:
    return err("the payload depth limit is below " & $MinMaxDepth)
  ok(newValidator(s, maxDepth))

func failure(code: ErrorCode, reason: InvalidParamsReason, msg: string): PayloadError =
  PayloadError(code: code, reason: Opt.some(reason), msg: msg)

func decodePayload*(
    data: openArray[byte], code = ecInvalidParams, maxDepth = DefaultMaxDepth
): Result[CborValue, PayloadError] =
  ## [SPEC INTERFACE §4.4, §4.5] One complete Logos deterministic-CBOR item.
  ## Text that is not UTF-8 decodes, so the schema check can reject it as a
  ## schema mismatch at its path (§4.5). A floating-point item at any depth is
  ## non-deterministic CBOR and never reaches the schema check (§4.4, §4.5).
  ## Containers nest at most `maxDepth` levels (§4.5.1); [IMPL] a value below
  ## 128 is raised to 128.
  var opts = defaultDecodeOptions()
  opts.allowInvalidUtf8 = true
  opts.maxDepth = max(maxDepth, MinMaxDepth)
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
        # [SPEC INTERFACE §4.5.1] Over the depth limit: the payload is not
        # dispatched, accepted or delivered, and the rejection has no detail.
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
  let x = ?decodePayload(data, maxDepth = v.maxDepth)
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
  let x = ?decodePayload(data, ecModule, v.maxDepth)
  ?v.validateAgainst(m.doc, m.response, x, ecModule)
  ok(x)

func checkEvent*(
    v: ContractValidator, eventId: string, data: openArray[byte]
): Result[CborValue, PayloadError] =
  ## [SPEC INTERFACE §2.5, §4.3] Event data: exactly one deterministic-CBOR map of
  ## the selected event's type, for an event the contract declares.
  let e = v.surface.findEvent(eventId).valueOr:
    return err(PayloadError(code: ecInvalidParams, msg: "unknown event " & eventId))
  let x = ?decodePayload(data, maxDepth = v.maxDepth)
  ?v.validateAgainst(e.doc, e.id, x, ecInvalidParams)
  ok(x)

func toFailure*(e: PayloadError): InvocationFailure =
  ## The invocation failure a dispatcher returns for a rejected payload. Only
  ## INVALID_PARAMS carries detail; it describes the caller's own input.
  ## A schema or configuration-schema mismatch names the path to the offending
  ## item (empty: the rejected value itself).
  var f = InvocationFailure(code: e.code)
  if e.code == ecInvalidParams and e.reason.isSome:
    let path =
      if e.reason.get in {iprSchemaMismatch, iprConfigurationSchemaMismatch}:
        Opt.some(e.path)
      else:
        Opt.none(seq[CborValue])
    f.detail = Opt.some(invalidParamsDetail(e.reason.get, path))
  f
