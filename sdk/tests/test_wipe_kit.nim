## Erasure of a marked payload in the SDK's generated code [IMPL] (INTERFACE
## §1.4.1; DECISIONS G276-G278, I92), with no Runtime: the ledger fixture's
## `seal`, which marks its request and response, through the kit's typed
## provider entry, the generated call helpers over a test route, and the typed
## `prepareInvoke` over a wrapped handle. The free scan (`base/wipeaudit`, this
## suite's `.nims`) searches every block released after arming for a canary,
## its sealed form and their value roots; the test wipes its own copies first.
## Hits are counted only where the scan sees the Nim heap (orc, arc). These
## paths carry a marked payload under refc too, unlike a Runtime's routes
## (G277), so every other check runs there. The Windows leg runs the suite
## too: the scan is off there (`wipeAuditScans()`), so only the hit counts are
## skipped and the suite needs no POSIX guard.

import std/[os, strutils, sysrand]
import unittest2
import logos_sdk/base/[wipe, wipeaudit]
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/hash
import logos_sdk/iface/accept
import logos_sdk/testing/[testdirs, testroute]
import logos_sdk/testing/fixtures/ledger_impl
import logos_sdk/testing/generated/ledger_module_calls

exportLedgerModuleCalls()

# The exported symbols, as an ABI caller declares them -------------------------------

proc ledgerInit(
  input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.importc: "logos_ledger_module_MODULE_init", cdecl, gcsafe, raises: [].}

proc ledgerDestroy(
  module: ptr LogosModuleContext
) {.importc: "logos_ledger_module_MODULE_destroy", cdecl, gcsafe, raises: [].}

proc ledgerFree(
  module: ptr LogosModuleContext, p: pointer
) {.importc: "logos_ledger_module_MODULE_free", cdecl, gcsafe, raises: [].}

proc ledgerDispatch(
  module: ptr LogosModuleContext,
  methodName: cstring,
  params: ptr UncheckedArray[uint8],
  paramsLen: csize_t,
  outResponse: ptr ptr UncheckedArray[uint8],
  outResponseLen: ptr csize_t,
): LogosResult {.
  importc: "logos_ledger_module_MODULE_dispatch", cdecl, gcsafe, raises: []
.}

proc ledgerSeal(
  module: ptr LogosModuleContext,
  owner: ptr LogosResponseOwner,
  secret: ptr UncheckedArray[uint8],
  secretLen: csize_t,
  sealed: ptr ptr UncheckedArray[uint8],
  sealedLen: ptr csize_t,
): LogosResult {.
  importc: "logos_ledger_module_CALL_ledger_Seal", cdecl, gcsafe, raises: []
.}

proc openLedger(): ptr LogosModuleContext =
  var i = input()
  doAssert ledgerInit(addr i, addr result).code == CErrorCode(0), "init failed"

# The canary and the patterns ------------------------------------------------------

let canary = block:
  var c = urandom(32)
  for b in c.mitems:
    b = byte(ord('a') + int(b) mod 26)
  c

let canaryText = block:
  var s = newString(canary.len)
  for i, b in canary:
    s[i] = char(b)
  s

let sealedCanary = block:
  ## What `seal` answers for the canary: reversed and masked.
  var s = newSeq[byte](canary.len)
  for i, b in canary:
    s[s.high - i] = b xor 0x5A
  s

let ledgerSet = acceptContractSet(readFile(fixtureDir / "ledger_module.cddl")).tryGet

proc valueRootOf(declaration, key: string, bytes: seq[byte]): seq[byte] =
  var t = cborMap(@[(cbor(key), cbor(bytes))])
  let n = ledgerSet.schemaSet.normalize(0, declaration, t).tryGet
  result = @(valueRoot(n).tryGet)
  wipe(t)

let roots = @[
  valueRootOf("ledger.seal_request", "secret", canary),
  valueRootOf("ledger.seal_response", "sealed", sealedCanary),
]

proc patterns(): seq[seq[byte]] =
  ## Fresh copies: `armWipeAudit` zeroes what it is given.
  result.add(canary)
  result.add(sealedCanary)
  for r in roots:
    result.add(r)

let scans = wipeAuditScans()

proc found(p: pointer, n: int): int {.gcsafe.} =
  ## The patterns in a live region of `n` bytes, as the scan counts them,
  ## searched here so the check holds where the scanner is off.
  if p == nil or n <= 0:
    return 0
  let b = cast[ptr UncheckedArray[byte]](p)
  template holds(m: seq[byte]): bool =
    var hit = false
    if m.len > 0 and m.len <= n:
      for i in 0 .. n - m.len:
        if equalMem(addr b[i], unsafeAddr m[0], m.len):
          hit = true
          break
    hit

  {.cast(gcsafe).}:
    if holds(canary):
      inc result
    if holds(sealedCanary):
      inc result
    for r in roots:
      if holds(r):
        inc result

proc finds(s: string): int =
  if s.len == 0:
    0
  else:
    found(unsafeAddr s[0], s.len)

proc finds(b: seq[byte]): int =
  if b.len == 0:
    0
  else:
    found(unsafeAddr b[0], b.len)

proc finds(r: LogosResult): int =
  ## The patterns in a failure's message, read before the next call.
  if r.message == nil:
    0
  else:
    found(r.message, r.message.len)

proc arm() =
  armWipeAudit(patterns())

proc hits(): int =
  ## Blocks released holding a pattern since arming (backtraces to stderr).
  result = wipeAuditHits()
  if result > 0:
    reportWipeAudit()

proc sharedCopy(b: openArray[byte], extra = 0): ptr UncheckedArray[uint8] =
  ## `b` in one block outside the Nim heap, zero-padded by `extra` bytes.
  result = cast[ptr UncheckedArray[uint8]](allocShared0(b.len + extra))
  copyMem(result, unsafeAddr b[0], b.len)

const Over = 300 ## a secret over its 256-byte bound, the canary first

# A route whose prepared calls the test completes (INTERFACE §2.9.1) ----------------

var
  asyncState: byte
  asyncCallbacks: LogosAsyncCallbacks
  carried: Atomic[int] ## prepared requests that held the canary
  failing: Atomic[bool] ## complete with a failure whose text holds the canary
  responseBytes: ptr UncheckedArray[uint8] ## the sealed canary's response, the test's
  responseLen: int
  failText: ptr UncheckedArray[uint8] ## NUL-terminated, the test's
  failLen: int
  ownerReleases: Atomic[int]
  seen: Atomic[int]
    ## what `onSealed` saw: 1 the sealed canary, 2 the canary in a failure's text

proc releaseOwner(state: pointer) {.cdecl, gcsafe, raises: [].} =
  ownerReleases += 1 # the bytes are the test's, which wipes them at the end

proc submitOp(call: ptr LogosAsyncCall) {.cdecl, gcsafe, raises: [].} =
  ## Completes the call before `submit` returns (l.2011).
  {.cast(gcsafe).}:
    let cb = asyncCallbacks
    let bytes = responseBytes
    let n = responseLen
    let text = cast[cstring](failText)
  if failing.load:
    cb.complete(
      cb.userData,
      LogosResult(code: CErrorCode(ord(ecModule)), message: text),
      nil,
      0,
      LogosResponseOwner(),
    )
  else:
    cb.complete(
      cb.userData,
      LogosResult(),
      bytes,
      csize_t(n),
      LogosResponseOwner(state: addr asyncState, release: releaseOwner),
    )

proc cancelOp(call: ptr LogosAsyncCall) {.cdecl, gcsafe, raises: [].} =
  discard

proc callReleaseOp(call: ptr LogosAsyncCall) {.cdecl, gcsafe, raises: [].} =
  discard

var asyncCallVtable = LogosAsyncCallVtable(
  abiVersion: AsyncCallAbiVersion,
  structSize: csize_t(sizeof(LogosAsyncCallVtable)),
  submit: submitOp,
  cancel: cancelOp,
  release: callReleaseOp,
)

proc prepareOp(
    route: ptr LogosRouteHandle,
    m: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    options: ptr LogosAsyncOptions,
    callbacks: ptr LogosAsyncCallbacks,
    outCall: ptr LogosAsyncCall,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  if found(params, int(paramsLen)) > 0:
    carried += 1
  {.cast(gcsafe).}:
    asyncCallbacks = callbacks[]
  outCall[] = LogosAsyncCall(vtable: addr asyncCallVtable, state: addr asyncState)
  LogosResult()

proc routeReleaseOp(route: ptr LogosRouteHandle) {.cdecl, gcsafe, raises: [].} =
  discard

proc observeOk(
    route: ptr LogosRouteHandle, handler: LogosRouteEndHandler, userData: pointer
): LogosResult {.cdecl, gcsafe, raises: [].} =
  LogosResult()

proc observeSubscriptionsOk(
    route: ptr LogosRouteHandle, handler: LogosSubscriptionEndHandler, userData: pointer
): LogosResult {.cdecl, gcsafe, raises: [].} =
  LogosResult()

var asyncRouteVtable = block:
  var v = armed(
    LogosRouteVtable(
      abiVersion: RouteVtableAbiVersion, structSize: csize_t(sizeof(LogosRouteVtable))
    )
  )
  v.prepareCall = prepareOp
  v.release = routeReleaseOp
  v.observeEnd = observeOk
  v.observeSubscriptionEnd = observeSubscriptionsOk
  v

proc onSealed(
    o: Result[LedgerSealResponse, InvocationFailure], user: pointer
) {.nimcall, gcsafe, raises: [].} =
  ## Reads the outcome and keeps nothing: the helper erases it.
  {.cast(gcsafe).}:
    seen.store(
      if o.isOk and o.get.sealed == sealedCanary:
        1
      elif o.isErr and o.unsafeError.message.isSome and
        canaryText in o.unsafeError.message.get:
        2
      else:
        3
    )

# Tests ------------------------------------------------------------------------------

suite "wipe: the SDK's generated code (DECISIONS G276-G278, I92) [IMPL]":
  teardown:
    disarmWipeAudit()

  test "[IFC-0577] the kit's typed provider entry keeps seal's request and response marked through its temporaries and cleanup":
    let ctx = openLedger()
    let input = sharedCopy(canary)
    let over = sharedCopy(canary, Over - canary.len)
    arm()
    var owner = LogosResponseOwner()
    var sealed: ptr UncheckedArray[uint8]
    var sealedLen: csize_t
    check ledgerSeal(
      ctx, addr owner, input, csize_t(canary.len), addr sealed, addr sealedLen
    ).code == CErrorCode(0)
    check int(sealedLen) == canary.len
    check equalMem(sealed, unsafeAddr sealedCanary[0], canary.len)
    check found(sealed, int(sealedLen)) == 1
    clearOwner(addr owner)
    # An input outside its schema: INVALID_PARAMS, its message without the canary.
    let r =
      ledgerSeal(ctx, addr owner, over, csize_t(Over), addr sealed, addr sealedLen)
    check r.code == CErrorCode(ord(ecInvalidParams))
    check finds(r) == 0
    freeWiped(over, Over)
    freeWiped(input, canary.len)
    ledgerDestroy(ctx)
    if scans:
      check hits() == 0

  test "[IFC-0577] the generated call helpers keep seal's request and response marked, from Nim and from C, a rejected request included":
    let ctx = openLedger()
    let route = newRoute(rmDirect, ctx, ledgerDispatch, ledgerFree)
    let input = sharedCopy(canary)
    let over = sharedCopy(canary, Over - canary.len)
    arm()
    # From Nim.
    var rq = LedgerSealRequest(secret: canary)
    var s = invoke(route.routeHandle, rq)
    wipeTyped(rq)
    check s.isOk and s.get.sealed == sealedCanary
    wipeTyped(s)
    var big = LedgerSealRequest(secret: newSeq[byte](Over))
    copyMem(addr big.secret[0], unsafeAddr canary[0], canary.len)
    var refused = invoke(route.routeHandle, big)
    wipeTyped(big)
    check refused.isErr and refused.unsafeError.code == ecInvalidParams
    check refused.isErr and finds(refused.unsafeError.message.get("")) == 0
    check refused.isErr and finds(refused.unsafeError.detail.get(@[])) == 0
    wipeError(refused)
    # From C: the outputs in an arena the owner releases.
    var owner = LogosResponseOwner()
    var sealed: ptr UncheckedArray[uint8]
    var sealedLen: csize_t
    check ledgerModuleCallsInvoke2(
      route.routeHandle,
      addr owner,
      input,
      csize_t(canary.len),
      addr sealed,
      addr sealedLen,
    ).code == CErrorCode(0)
    check int(sealedLen) == canary.len
    check equalMem(sealed, unsafeAddr sealedCanary[0], canary.len)
    ledgerModuleCallsClear2(addr owner, addr sealed, addr sealedLen)
    check sealed == nil and sealedLen == 0
    let r = ledgerModuleCallsInvoke2(
      route.routeHandle, addr owner, over, csize_t(Over), addr sealed, addr sealedLen
    )
    check r.code == CErrorCode(ord(ecInvalidParams))
    check finds(r) == 0
    check route.counts == (4, 2, 0) # every buffer handed over released once
    check not route.outstanding
    route.dispose()
    freeWiped(over, Over)
    freeWiped(input, canary.len)
    ledgerDestroy(ctx)
    if scans:
      check hits() == 0

  test "[IFC-0577] [IMPL-DECISION G276] the typed prepareInvoke over a wrapped handle erases seal's request, its response and a failure's text once onDone returns":
    block:
      var response = LedgerSealResponse(sealed: sealedCanary)
      var bytes = encode(response).get
      wipeTyped(response)
      responseLen = bytes.len
      responseBytes = sharedCopy(bytes)
      wipe(bytes)
    var text = "refused: " & canaryText
    failLen = text.len + 1
    failText = sharedCopy(text.toOpenArrayByte(0, text.high), 1)
    wipe(text)
    let h = wrapRoute(
      LogosRouteHandle(vtable: addr asyncRouteVtable, state: addr asyncState)
    ).get
    arm()
    for (fails, expected) in [(false, 1), (true, 2)]:
      checkpoint "failing: " & $fails
      failing.store(fails)
      seen.store(0)
      var rq = LedgerSealRequest(secret: canary)
      let c = h.prepareInvoke(rq, onSealed)
      wipeTyped(rq)
      check c.isOk
      if c.isOk:
        c.get.submit()
        check seen.load == expected
        check c.get.release().isOk
    check carried.load == 2 # each request reached the route
    check ownerReleases.load == 1
    check h.release().isOk
    freeWiped(failText, failLen)
    freeWiped(responseBytes, responseLen)
    if scans:
      check hits() == 0
