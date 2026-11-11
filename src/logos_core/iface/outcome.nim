## INTERFACE §4.6, §5.1, §5.2: shared error codes and invocation outcomes.
##
## A schema-defined invocation has exactly one result: a contract response
## (`LOGOS_OK`, a value of the response schema, expected domain failures
## included) or an invocation failure (a nonzero shared `logos.error_code`, an
## optional diagnostic message, and for `INVALID_PARAMS` an optional encoded
## `logos.invalid_params_detail`).

{.push raises: [].}

import ../cbor
import ../base/perthread
import ../cbor/utf8
import ../commitment

export cbor

const
  MaxMessageBytes* = 512 ## [SPEC INTERFACE §5.1, §5.2] `LOGOS_ERROR_MESSAGE_MAX_LEN`
  MaxDetailBytes* = 4096 ## [SPEC INTERFACE §5.1, §5.2] `LOGOS_ERROR_DETAIL_MAX_LEN`

type
  ErrorCode* = enum
    ## [SPEC INTERFACE §5.1] The `logos.error_code` registry, named by its bare
    ## names (§5.2: `LOGOS_ERR_MODULE` is MODULE_ERROR, `LOGOS_ERR_TRANSPORT` is
    ## TRANSPORT_ERROR).
    ecOk = (0, "OK")
    ecMethodNotFound = (1, "METHOD_NOT_FOUND")
    ecInvalidParams = (2, "INVALID_PARAMS")
    ecModule = (3, "MODULE_ERROR")
    ecNotAuthorised = (4, "NOT_AUTHORISED")
    ecTransport = (5, "TRANSPORT_ERROR")
    ecTimeout = (6, "TIMEOUT")
    ecVersionMismatch = (7, "VERSION_MISMATCH")
    ecNotReady = (8, "NOT_READY")
    ecCancelled = (9, "CANCELLED")

  InvalidParamsReason* = enum
    ## [SPEC INTERFACE §5.1] `logos.invalid_params_reason`.
    iprMalformedCbor = "malformed-cbor"
    iprNonDeterministicCbor = "non-deterministic-cbor"
    iprSchemaMismatch = "schema-mismatch"
    iprConfigurationSchemaMismatch = "configuration-schema-mismatch"
      ## a decoded deterministic configuration value fails the accepted
      ## configuration schema (CONFIGURATION); its path starts at that value

  InvocationFailure* = object
    code*: ErrorCode
    message*: Opt[string]
    detail*: Opt[seq[byte]] ## encoded `logos.invalid_params_detail`

  Outcome* = object
    case ok*: bool
    of true:
      response*: CborValue ## the contract response value
    of false:
      failure*: InvocationFailure

func cName*(c: ErrorCode): string =
  ## [SPEC INTERFACE §5.2] The `logos_error_code_t` enumerator.
  case c
  of ecOk:
    "LOGOS_OK"
  of ecModule:
    "LOGOS_ERR_MODULE"
  of ecTransport:
    "LOGOS_ERR_TRANSPORT"
  else:
    "LOGOS_ERR_" & $c

func errorCode*(n: int64): Opt[ErrorCode] =
  ## An allocated code, or none: this revision allocates 0 through 9 only.
  if n < int64(low(ErrorCode).ord) or n > int64(high(ErrorCode).ord):
    Opt.none(ErrorCode)
  else:
    Opt.some(ErrorCode(n))

func providerStatus*(n: int64): ErrorCode =
  ## [SPEC INTERFACE §5.1] A provider status outside the allocated range is a
  ## module failure; the unknown integer is never passed on as a shared code.
  errorCode(n).get(ecModule)

func parseErrorCode*(v: CborValue): Result[ErrorCode, string] =
  ## [SPEC INTERFACE §5.1] A serialized `logos.error_code`; an unknown value
  ## makes the enclosing value or message invalid for this revision.
  if v.isNil or v.kind != ckUint or v.uint > uint64(high(ErrorCode).ord):
    return err("not an allocated logos.error_code")
  ok(ErrorCode(v.uint))

# logos.invalid_params_detail -------------------------------------------------------

perThread(commonSchema, SchemaModel, pinnedContext().commonModel)

func detailValue*(
    reason: InvalidParamsReason, path: Opt[seq[CborValue]] = Opt.none(seq[CborValue])
): CborValue =
  var entries = @[(cbor("reason"), cbor($reason))]
  if path.isSome:
    entries.add((cbor("path"), cborArray(path.get)))
  cborMap(entries)

func invalidParamsDetail*(
    reason: InvalidParamsReason, path: Opt[seq[CborValue]] = Opt.none(seq[CborValue])
): seq[byte] =
  ## The encoded `logos.invalid_params_detail`. A path that would take the detail
  ## past 4096 bytes is left out (the path is optional) [IMPL].
  let full = encodeCbor(detailValue(reason, path))
  if full.len <= MaxDetailBytes:
    full
  else:
    encodeCbor(detailValue(reason))

proc checkDetail*(code: ErrorCode, detail: openArray[byte]): Result[void, string] =
  ## [SPEC INTERFACE §5.1] Detail is allowed only for INVALID_PARAMS: 1-4096
  ## bytes holding exactly one Logos deterministic-CBOR
  ## `logos.invalid_params_detail`.
  if code != ecInvalidParams:
    return err($code & " carries no detail")
  if detail.len < 1 or detail.len > MaxDetailBytes:
    return err("detail is not 1 to 4096 bytes")
  let v = decodeCbor(detail).valueOr:
    return err("detail is not one deterministic CBOR value: " & $error)
  let decl = commonSchema().find("logos.invalid_params_detail").get
  if not schemaSet(commonSchema()).validates(0, decl.body, v):
    return err("detail is not a logos.invalid_params_detail")
  ok()

proc checkFailure*(f: InvocationFailure): Result[void, string] =
  ## [SPEC INTERFACE §5.1] A nonzero allocated code, a message of at most 512
  ## UTF-8 bytes, and only the detail its code allows.
  if f.code == ecOk:
    return err("an invocation failure has a nonzero code")
  if f.message.isSome:
    let m = f.message.get
    if m.len > MaxMessageBytes:
      return err("the message is longer than 512 bytes")
    if not isValidUtf8(m.toOpenArrayByte(0, m.high)):
      return err("the message is not UTF-8")
  if f.detail.isSome:
    ?checkDetail(f.code, f.detail.get)
  ok()

proc checkStatus*(
    code: ErrorCode, message: Opt[string], detail: Opt[seq[byte]]
): Result[void, string] =
  ## [SPEC INTERFACE §5.1, §5.2] A complete status: `LOGOS_OK` carries neither a
  ## message nor detail; any other code is a valid invocation failure.
  if code == ecOk:
    if message.isSome or detail.isSome:
      return err("LOGOS_OK carries no message or detail")
    return ok()
  checkFailure(InvocationFailure(code: code, message: message, detail: detail))

proc checkedProviderStatus*(
    code: int64, message: Opt[string], detail: Opt[seq[byte]]
): (ErrorCode, Opt[string], Opt[seq[byte]]) =
  ## [SPEC INTERFACE §5.1] What an ABI caller forwards for a native provider's
  ## status, message and detail: them unchanged when they are valid, else
  ## `LOGOS_ERR_MODULE` with neither diagnostics nor detail. A caller that gets
  ## MODULE_ERROR back for an `OK` status forwards no contract-response output.
  let c = errorCode(code)
  if c.isNone or checkStatus(c.get, message, detail).isErr:
    return (ecModule, Opt.none(string), Opt.none(seq[byte]))
  (c.get, message, detail)
