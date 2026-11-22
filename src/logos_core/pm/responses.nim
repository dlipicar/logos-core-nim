## The Package Manager's method responses (Tier 5 step 5-5-1; DECISIONS G450;
## docs/PACKAGE-MANAGER.md §12; PACKAGE MANAGER §14 l.1467-1520, §15 l.1522-1734).
##
## - **One encoder per §15 response variant** that the operations and the 5-6 steps return:
##   `{installed}` (install and update), `{}` (remove), `{inspection}`, `{handoff}`, the
##   installed-list page `{packages, ?next_cursor}`, and `{error: package_error}`. Each builds
##   deterministic CBOR from typed values; test_pm_records checks each against the mirrored
##   method types. A success variant holds no error, and an error variant exactly one package
##   error (PKG-0356).
## - **A message** (PKG-0360) is diagnostic text only: the caller's public text, cut to 512 bytes
##   at a character boundary. Callers put in it only the request's own fields, identities and
##   versions the caller named or may observe, and fixed text for the cause; never a state
##   directory, `local_path`, binding or storage name, locator, trust content or limit value.
##   Those go to the operator's log (PM l.1514).
## - **Invocation failures** (PKG-0361, PKG-0362): a package error is an operational result,
##   carried in a successful response; what prevents a valid response (the admission bound, a
##   damaged installed state, a worker failure, a stop) is `moduleError()`, `MODULE_ERROR` with
##   no message or detail, and never a package error.

{.push raises: [].}

import results
import logos_sdk/cbor
import logos_sdk/iface/outcome
import ../package/[errors, records]
import ./installed

export results, outcome

const MaxMessageBytes* = 512 ## [SPEC PM §14] `package_error.message`

func publicMessage*(s: string): string =
  ## `s` cut to at most 512 bytes, never inside a UTF-8 sequence.
  if s.len <= MaxMessageBytes:
    return s
  var n = MaxMessageBytes
  while n > 0 and (byte(s[n]) and 0xC0'u8) == 0x80'u8:
    dec n
  s[0 ..< n]

func errorValue*(code: PackageErrorCode, message = ""): CborValue =
  ## [SPEC PM §14] One `package_error`; an empty message is left out.
  var m = cborMap((cbor("code"), cbor($code)))
  let text = publicMessage(message)
  if text.len > 0:
    m.entries.add((cbor("message"), cbor(text)))
  m

func errorResult*(code: PackageErrorCode, message = ""): CborValue =
  ## [SPEC PM §14, §15] Any method's error variant: exactly one package error.
  cborMap((cbor("error"), errorValue(code, message)))

func errorResult*(e: PackageError): CborValue =
  ## The error variant of `e`, whose message is public text (PKG-0360).
  errorResult(e.code, e.msg)

func installedResult*(r: InstalledRecord, base: string): CborValue =
  ## [SPEC PM §15 l.1675-1719] `install_package` and `update_package`'s success: the record,
  ## its artifacts under `base`.
  cborMap((cbor("installed"), recordValue(r, base)))

func removedResult*(): CborValue =
  ## [SPEC PM §15 l.1693-1699] `remove_package`'s success.
  cborMap()

func inspectionResult*(i: InspectRecord): CborValue =
  ## [SPEC PM §15 l.1667-1673] `inspect_package`'s success.
  cborMap((cbor("inspection"), i.toCbor))

func handoffResult*(h: CborValue): CborValue =
  ## [SPEC PM §15] `get_runtime_handoff`'s success, from `buildHandoff`.
  cborMap((cbor("handoff"), h))

func installedPage*(records: openArray[CborValue], next = Opt.none(string)): CborValue =
  ## [SPEC PM §15] One `list_installed_packages` page of record values (`recordValue`), and the
  ## cursor of the next page when there is one.
  var m = cborMap((cbor("packages"), CborValue(kind: ckArray, items: @records)))
  if next.isSome:
    m.entries.add((cbor("next_cursor"), cbor(next.get)))
  m

func moduleError*(): InvocationFailure =
  ## [SPEC PM §5 l.827-828, §14 l.1515-1517] `MODULE_ERROR` with no message and no detail.
  InvocationFailure(code: ecModule)

{.pop.}
