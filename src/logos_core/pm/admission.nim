## The admission bound (Tier 5 step 5-5-1; DECISIONS G452; docs/PACKAGE-MANAGER.md §12;
## PACKAGE MANAGER §5 l.824-830).
##
## Before a record is committed, and again for every record at start, each complete required
## single-record result derived from it is encoded in its real Transport response envelope, with
## nothing estimated, and must fit the Core-owned 16 MiB body (`MinFrameLimit`), never the
## configured limit (l.830):
## - `{installed: R}`, the install and update result alike;
## - the one-record installed-list page `{packages: [R], next_cursor: C}` with a 512-byte cursor;
## - `{handoff: H}` for each selected module, its configuration schema and default included.
##
## Each envelope carries the largest call id, 2^64-1, and a payload commitment of two 32-byte
## roots, so surrounding fields count at their largest. Each value must also be valid under App
## A, so a `local_path` over 4,096 bytes fails here. A failure is `MODULE_ERROR` with no detail
## (`responses.moduleError`); the fault says which result failed, for the operator's log.

{.push raises: [].}

import std/strutils
import results
import logos_sdk/cbor
import ../transport/[envelope, framing]
import ./installed

export results, installed

const
  MaxCallId* = high(uint64) ## [SPEC TRANSPORT §1.1] the largest `call-id`
  MaxCursorBytes* = 512 ## [SPEC PM §15] `logos.package_manager.cursor`
  AdmissionLimit* = MinFrameLimit
    ## [SPEC PM §5 l.824, l.830] the Core-owned 16 MiB Transport body

type
  AdmittedResult* = enum
    arInstalled = "the install and update result"
    arPage = "the one-record installed-list page"
    arHandoff = "a module's handoff"

  AdmissionFault* = object
    ## Which result does not fit, and why; for the operator's log only.
    result*: AdmittedResult
    module*: string ## arHandoff: the module
    reason*: string

func maxCursor*(): string =
  ## A cursor of the largest legal size.
  repeat('~', MaxCursorBytes)

proc envelopeBytes*(resultValue: CborValue): Result[int, string] =
  ## [SPEC TRANSPORT §1.1, §2.1] The body size of the successful response envelope carrying
  ## `resultValue`, at the largest call id; any size, so that a fault can say by how much.
  let m = Message(
    kind: mkResponse,
    response: Response(
      id: MaxCallId, ok: true, resultMap: resultValue, commitment: PayloadCommitment()
    ),
  )
  let bytes = encodeMessage(m, peerLimit = high(uint32)).valueOr:
    return err($error)
  ok(bytes.len)

proc fits(
    v: CborValue, what: AdmittedResult, module = ""
): Result[void, AdmissionFault] =
  let n = envelopeBytes(v).valueOr:
    return err(AdmissionFault(result: what, module: module, reason: error))
  if n > AdmissionLimit:
    return err(
      AdmissionFault(
        result: what,
        module: module,
        reason: "a body of " & $n & " bytes, over " & $AdmissionLimit,
      )
    )
  ok()

proc admits*(
    r: InstalledRecord, base: string, handoffs: openArray[(string, CborValue)]
): Result[void, AdmissionFault] =
  ## [SPEC PM §5 l.824-830 (PKG-0468, PKG-0469)] Whether record `r`, its artifacts under
  ## `base`, and the handoff of each selected module (module, `runtime_handoff`) fit.
  let rv = recordValue(r, base)
  checkType(InstalledRecordType, rv).isOkOr:
    return err(AdmissionFault(result: arInstalled, reason: error))
  ?fits(cborMap((cbor("installed"), rv)), arInstalled)
  let page =
    cborMap((cbor("packages"), cborArray(rv)), (cbor("next_cursor"), cbor(maxCursor())))
  ?fits(page, arPage)
  for (module, h) in handoffs:
    checkType(RuntimeHandoffType, h).isOkOr:
      return err(AdmissionFault(result: arHandoff, module: module, reason: error))
    ?fits(cborMap((cbor("handoff"), h)), arHandoff, module)
  ok()

{.pop.}
