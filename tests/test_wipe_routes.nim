## Erasure of marked payloads on routes (Tier 4b step 4b-3b plan §4.2, W-4 to
## W-10; DECISIONS G276-G278, I92): the vault kit module (`kit/vault_impl`),
## whose contract marks `store`'s request, `fetch`'s response and both of
## `exchange`, called on direct, transported and hosted routes, through raw
## dispatch, the generated typed entries and the generated call helpers.
##
## The free scan (`base/wipeaudit`) searches every block released in this
## process, and in an audit-build Module Host, for a canary (32 random
## lowercase letters per run) and the value roots of the payloads that carry
## it. The test's own copies are wiped as the module's would be: a hit is a
## copy something on the path left behind. The scan sees the Nim heap only
## under orc and arc (`test_wipe_routes.nims`); elsewhere the hit counts are
## not checked, and every other check runs. The module keeps what it stores
## outside the Nim heap: its own copies are its own (INTERFACE l.388, l.399).
##
## [DECISIONS G277] A refc build routes no marked contract: there, the cases
## that need a marked route are skipped, and W-10 checks the refusal on the
## product paths, with no test hook. W-3's half in an audit host is here too.

import
  std/[
    atomics, exitprocs, monotimes, os, sequtils, strutils, sysrand, times, typedthreads
  ]
import unittest2
import ../src/logos_core/runtime/[engine, routing]
import logos_sdk/abi/types
import logos_sdk/base/[wipe, wipeaudit]
import logos_sdk/cbor
import logos_sdk/commitment
import logos_sdk/hash
import logos_sdk/iface/[accept, cmap, outcome, provider, surface]
import logos_sdk/codegen/common_types
import ../src/logos_core/authority/scopes except
  LogosNSRuntimeModuleInstanceAddress, LogosNSRuntimeModuleInstanceId,
  LogosNSRuntimeModuleName, LogosNSRuntimeModuleProviderAddress,
  LogosNSRuntimeModuleProviderId, LogosNSRuntimeModuleStateAssignmentId,
  LogosNSRuntimeRouteId, LogosNSRuntimeRuntimeInstanceId
import ../src/logos_core/transport/io/sock
import ./support/[fakeca, shortdir], logos_sdk/testing/[kitbuild, kitruntime]
import logos_sdk/testing/fixtures/meter_impl, ./kit/[vault_impl, vault_deferred]
import logos_sdk/testing/generated/meter_module_calls, ./generated/vault_module_calls

let
  repo = currentSourcePath().parentDir.parentDir
  work = repo / "build" / "wipe-routes" / kitVariant
removeDir(work)
createDir(work)

include ./support/routefixture

# The vault ------------------------------------------------------------------------

let
  vaultSet = acceptContractSet(readFile(repo / "tests/kit/vault_module.cddl")).tryGet
  vaultRoot = vaultSet.primary.root
  vaultSchema = encodeCbor(schemaResponse(vaultSet, vaultRoot).tryGet)
  vaultStatic = checkStaticRegistration("vault", vaultModuleStaticSymbols()).tryGet
  dvaultStatic = checkStaticRegistration("dvault", deferredVaultSymbols()).tryGet

const
  Vault = "vault"
  DVault = "dvault"
  Ca = "ca"
  Slot = 1'u64 ## where the canary is stored
  BadSlot = 15'u64 ## `fetch` answers outside its schema there

proc vaultRecord(binding = "vault"): ModuleRecord =
  ModuleRecord(
    module: "vault_module",
    strategy: stDirectStatic,
    binding: binding,
    primaryContract: Opt.some(vaultRoot),
  )

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

proc kv(k: string, v: CborValue): CborEntry =
  (cbor(k), v)

proc req(entries: varargs[CborEntry]): seq[byte] =
  ## Deterministic CBOR of a map; its tree is wiped once encoded.
  let t = cborMap(entries)
  result = encodeCbor(t)
  wipe(t)

proc storeReq(slot = Slot, note = "", extra = ""): seq[byte] =
  var e = @[kv("secret", cbor(canary)), kv("slot", cbor(slot))]
  if note.len > 0:
    e.add(kv("note", cbor(note)))
  if extra.len > 0:
    e.add(kv(extra, cbor(0'u64)))
  result = req(e)

proc slotReq(slot = Slot): seq[byte] =
  req(kv("slot", cbor(slot)))

proc exchangeReq(slot = Slot): seq[byte] =
  req(kv("secret", cbor(canary)), kv("slot", cbor(slot)))

proc valueRootOf(declaration: string, bytes: seq[byte]): seq[byte] =
  var t = decodeCbor(bytes).tryGet
  let n = vaultSet.schemaSet.normalize(0, declaration, t).tryGet
  result = @(valueRoot(n).tryGet)
  wipe(t)

let roots = block:
  # The value roots of every payload that carries the canary (TRANSPORT §4.1).
  var r: seq[seq[byte]]
  var b = storeReq()
  r.add(valueRootOf("vault.store_request", b))
  wipe(b)
  b = exchangeReq()
  r.add(valueRootOf("vault.exchange_request", b))
  wipe(b)
  b = req(kv("secret", cbor(canary)))
  r.add(valueRootOf("vault.fetch_response", b))
  wipe(b)
  b = req(kv("previous", cbor(canary)))
  r.add(valueRootOf("vault.exchange_response", b))
  wipe(b)
  r

proc patterns(): seq[seq[byte]] =
  ## Fresh copies: `armWipeAudit` zeroes what it is given.
  result.add(canary)
  for r in roots:
    result.add(r)

let scans = wipeAuditScans()

proc found(p: pointer, n: int): int {.gcsafe.} =
  ## The patterns in a live region of `n` bytes, as the scan counts them,
  ## searched here so the check holds where the scanner is off (Windows).
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
    for r in roots:
      if holds(r):
        inc result

proc arm() =
  armWipeAudit(patterns())

proc hits(): int =
  ## Blocks released holding a pattern since arming (backtraces to stderr).
  result = wipeAuditHits()
  if result > 0:
    reportWipeAudit()

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

proc wipe(r: var RcResult) =
  wipe(r.message)
  wipe(r.detail)
  wipe(r.response)

proc lookupBytes(bytes: seq[byte], key: string): seq[byte] =
  ## A byte string of a response map; its tree is wiped.
  let t = decodeCbor(bytes).tryGet
  result = t.lookup(key).get.bytes
  wipe(t)

var engineWork: string ## the latest engine's work directory

proc absentFrom(e: Engine): bool =
  ## [SPEC INTERFACE l.3357-3367; SECURITY l.401-403] No pattern in a call
  ## record, a diagnostic or the engine's files.
  result = true
  for r in e.audit.records:
    if finds(r.bytes) > 0:
      result = false
  for d in e.diagnostics:
    if finds(d) > 0:
      result = false
  for f in walkDirRec(engineWork):
    try:
      var s = readFile(f)
      if finds(s) > 0:
        checkpoint("a pattern in " & f)
        result = false
      wipe(s)
    except IOError:
      discard

# Set-up -----------------------------------------------------------------------------

when unixStream:
  # The endpoints go under a short private base (sun_path).
  proc removeAtExit(dir: string) =
    ## The closure keeps its own copy: the main module's globals are destroyed
    ## before exit procedures run.
    addExitProc(
      proc() =
        removeDir(dir)
    )

  let shortBase = makeShortBase("lcnwr", "/e999/12345678/logos_vault_module.sock")
  removeAtExit(shortBase)

proc wipeConfig(transported = false): EngineConfig =
  result = config(extra = @[vaultStatic, dvaultStatic])
  when unixStream:
    if transported:
      result.routing = @[RoutingRule(callee: "vault_module", mode: rmLocalTransport)]
      result.endpointDir = shortBase / ("e" & $engines)

proc vaultRoute(
    orch: ptr LogosRuntimeControlBinding, e: Engine, instance, key: string
): RcResult =
  orch.establish(
    key,
    root = vaultRoot,
    provider = Opt.some(providerAddress(e.view(instance).tryGet.providerId)),
  )

type NoHandle = object of CatchableError ## a case's route has no handle

proc vaultHandle(
    orch: ptr LogosRuntimeControlBinding, e: Engine, instance, key: string
): LogosRouteHandle =
  let r = orch.vaultRoute(e, instance, key)
  check r.code == ecOk
  if r.code != ecOk:
    raise newException(NoHandle, "establish_route: " & $r.code & " " & r.message)
  var h = LogosRouteHandle()
  let m = toResult(
    rawMaterialize(orch, r.routesOf.routes[0].route, vaultRoot, vaultSchema, h)
  )
  check m.code == ecOk
  if m.code != ecOk:
    # [IMPL] A call through the empty handle would crash the process, and with
    # it the case's failed checks, which unittest2 prints at the suite's end.
    raise newException(NoHandle, "materialize_route: " & $m.code & " " & m.message)
  h

proc ready(cfg: EngineConfig): (Engine, ptr LogosRuntimeControlBinding) =
  vaultReset()
  resetVaultDeferred()
  engineWork = cfg.workDir
  let e = fixtureEngine(cfg)
  let (_, orch) = e.startClient()
  discard e.started(vaultRecord(), Vault)
  discard e.started(vaultRecord("dvault"), DVault)
  (e, orch)

# The call matrix (W-4, W-6, W-7) ---------------------------------------------------------

proc matrix(h: var LogosRouteHandle, local = true) =
  ## Every method and every rejection a marked payload meets, through `h`.
  ## The test's own copies are wiped as it goes. `local`: the vault is in
  ## this process, and what it keeps is checked.
  # `store` (request marked): kept by the module.
  var b = storeReq()
  var r = h.raw("store", b)
  wipe(b)
  check r.code == ecOk
  wipe(r)
  # Initialized: under ORC a local declared without an initializer and first
  # written in a branch is not destroyed by its next write (nim-lang/Nim#26725).
  var held: seq[byte] = @[]
  if local:
    held = vaultHolds(int(Slot))
    check held == canary
    wipe(held)
  # `peek` (unmarked): no payload of the canary.
  b = slotReq()
  r = h.raw("peek", b)
  check r.code == ecOk
  check r.response.len > 0 and finds(r.response) == 0
  wipe(r)
  # `fetch` (response marked).
  b = slotReq()
  r = h.raw("fetch", b)
  check r.code == ecOk
  held = lookupBytes(r.response, "secret")
  check held == canary
  wipe(held)
  wipe(r)
  # `exchange` (both marked).
  b = exchangeReq()
  r = h.raw("exchange", b)
  wipe(b)
  check r.code == ecOk
  held = lookupBytes(r.response, "previous")
  check held == canary
  wipe(held)
  wipe(r)
  # [G278; S4b3b-2 (b)] INVALID_PARAMS for an unknown key that is the canary:
  # the detail path stops before it and the message is fixed.
  b = storeReq(slot = 2, extra = canaryText)
  r = h.raw("store", b)
  wipe(b)
  check r.code == ecInvalidParams
  check finds(r.message) == 0 and finds(r.detail) == 0
  check r.detail.len > 0
  wipe(r)
  # A provider failure whose message holds the canary: forwarded to the
  # caller only (INTERFACE l.3366).
  b = storeReq(slot = 3, note = "echo")
  r = h.raw("store", b)
  wipe(b)
  check r.code == ecModule
  check canaryText in r.message
  wipe(r)
  # A response outside its schema that holds the canary: MODULE_ERROR, and
  # the message says nothing of it.
  b = storeReq(slot = BadSlot)
  r = h.raw("store", b)
  wipe(b)
  check r.code == ecOk
  wipe(r)
  b = slotReq(BadSlot)
  r = h.raw("fetch", b)
  check r.code == ecModule
  check finds(r.message) == 0
  wipe(r)

suite "wipe: a direct route (W-4)":
  teardown:
    disarmWipeAudit()
    leftover()

  test "[IFC-0575] [IFC-0580] [SEC-0057] every method and rejection of a marked contract on a direct route leaves no copy of the canary or its value roots, and no diagnostic, record or file holds them":
    when ChannelsMove:
      let (e, orch) = ready(wipeConfig())
      var h = orch.vaultHandle(e, Vault, "w4")
      arm()
      h.matrix()
      h.release()
      check e.absentFrom()
      e.finish()
      if scans:
        check hits() == 0
    else:
      skip() # [DECISIONS G277] a refc build routes no marked contract (W-10)

suite "wipe: generated code (W-8)":
  teardown:
    disarmWipeAudit()
    leftover()

  test "[IFC-0577] the kit's typed provider entries keep the request and response marked through their temporaries and cleanup":
    vaultReset()
    var ctx: ptr LogosModuleContext
    var init = input()
    let symbols = vaultModuleStaticSymbols()
    proc sym(name: string): pointer =
      for (n, p) in symbols:
        if n == name:
          return p

    let kinit = cast[ModuleInitFn](sym("logos_vault_module_MODULE_init"))
    let kdestroy = cast[ModuleDestroyFn](sym("logos_vault_module_MODULE_destroy"))
    check kinit(addr init, addr ctx).code == 0
    type
      StoreFn = proc(
        p0: ptr LogosModuleContext,
        p1: ptr LogosResponseOwner,
        p2: bool,
        p3: cstring,
        p4: ptr UncheckedArray[uint8],
        p5: csize_t,
        p6: uint32,
        p7: ptr bool,
      ): LogosResult {.cdecl, gcsafe, raises: [].}
      FetchFn = proc(
        p0: ptr LogosModuleContext,
        p1: ptr LogosResponseOwner,
        p2: uint32,
        p3: ptr bool,
        p4: ptr cstring,
        p5: ptr ptr UncheckedArray[uint8],
        p6: ptr csize_t,
      ): LogosResult {.cdecl, gcsafe, raises: [].}
      ExchangeFn = proc(
        p0: ptr LogosModuleContext,
        p1: ptr LogosResponseOwner,
        p2: ptr UncheckedArray[uint8],
        p3: csize_t,
        p4: uint32,
        p5: ptr ptr UncheckedArray[uint8],
        p6: ptr csize_t,
      ): LogosResult {.cdecl, gcsafe, raises: [].}

    let
      store = cast[StoreFn](sym("logos_vault_module_CALL_vault_Store"))
      fetch = cast[FetchFn](sym("logos_vault_module_CALL_vault_Fetch"))
      exchange = cast[ExchangeFn](sym("logos_vault_module_CALL_vault_Exchange"))
    # The caller's input: one block outside the Nim heap, zeroed by the test.
    let input = cast[ptr UncheckedArray[uint8]](allocShared0(canary.len))
    for i, b in canary:
      input[i] = b
    arm()
    var owner = LogosResponseOwner()
    var stored = false
    check store(
      ctx, addr owner, false, nil, input, csize_t(canary.len), uint32(Slot), addr stored
    ).code == 0
    check stored
    var held = vaultHolds(int(Slot))
    check held == canary
    wipe(held)
    # A provider failure that holds the canary, and an invalid input.
    var r =
      store(ctx, addr owner, true, "echo", input, csize_t(canary.len), 3, addr stored)
    check r.code == CErrorCode(ord(ecModule))
    check r.message != nil and found(r.message, r.message.len) == 1
    # A secret over its 256-byte bound, the canary at its start: a block of its
    # own, so the entry reads only what it is given.
    const Over = 300
    let over = cast[ptr UncheckedArray[uint8]](allocShared0(Over))
    copyMem(over, input, canary.len)
    r = store(ctx, addr owner, false, "", over, csize_t(Over), 2, addr stored)
    check r.code == CErrorCode(ord(ecInvalidParams))
    check r.message == nil or found(r.message, r.message.len) == 0
    secureZero(over, Over)
    deallocShared(over)
    # The response: in the arena the owner releases, zeroed then.
    var present = false
    var note: cstring
    var data: ptr UncheckedArray[uint8]
    var len: csize_t
    check fetch(
      ctx, addr owner, uint32(Slot), addr present, addr note, addr data, addr len
    ).code == 0
    check int(len) == canary.len
    check found(data, int(len)) == 1
    owner.release(owner.state)
    owner = LogosResponseOwner()
    check exchange(
      ctx, addr owner, input, csize_t(canary.len), uint32(Slot), addr data, addr len
    ).code == 0
    check found(data, int(len)) == 1
    owner.release(owner.state)
    owner = LogosResponseOwner()
    # Outside the schema: MODULE_ERROR, no copy left.
    discard store(
      ctx,
      addr owner,
      false,
      nil,
      input,
      csize_t(canary.len),
      uint32(BadSlot),
      addr stored,
    )
    r = fetch(
      ctx, addr owner, uint32(BadSlot), addr present, addr note, addr data, addr len
    )
    check r.code == CErrorCode(ord(ecModule))
    check r.message == nil or found(r.message, r.message.len) == 0
    secureZero(input, canary.len)
    deallocShared(input)
    kdestroy(ctx)
    if scans:
      check hits() == 0

  test "[IFC-0577] the generated call helpers keep a marked request and response marked; a handler that keeps the request keeps it intact (INTERFACE l.399)":
    when ChannelsMove:
      let (e, orch) = ready(wipeConfig())
      var h = orch.vaultHandle(e, Vault, "w8")
      arm()
      var rq = VaultStoreRequest(slot: uint32(Slot), secret: canary)
      let s = invoke(addr h, rq)
      wipeTyped(rq)
      check s.isOk and s.get.stored
      var held = vaultHolds(int(Slot))
      check held == canary
      wipe(held)
      var f = invoke(addr h, VaultFetchRequest(slot: uint32(Slot)))
      check f.isOk and f.get.secret == canary
      wipeTyped(f)
      var x = VaultExchangeRequest(slot: uint32(Slot), secret: canary)
      var g = invoke(addr h, x)
      wipeTyped(x)
      check g.isOk and g.get.previous == canary
      wipeTyped(g)
      # A provider failure that holds the canary reaches this caller only.
      var bad = VaultStoreRequest(slot: 3, secret: canary, note: Opt.some("echo"))
      var failed = invoke(addr h, bad)
      wipeTyped(bad)
      check failed.isErr and failed.error.message.isSome and
        finds(failed.error.message.get) == 1
      wipeError(failed)
      # Kept intact by the module: it answers for its own copies.
      held = vaultHolds(int(Slot))
      check held == canary
      wipe(held)
      h.release()
      e.finish()
      if scans:
        check hits() == 0
    else:
      skip() # [DECISIONS G277] a refc build routes no marked contract (W-10)

suite "wipe: G244 lifted (W-10)":
  teardown:
    disarmWipeAudit()
    leftover()

  test "[IFC-0578] [IFC-0579] a contract that marks a payload is routed on every local path kind of an orc or arc build; on a kind without erasure, and on every kind of a refc build, it is refused MODULE_ERROR with no handle (DECISIONS G277)":
    # [SPEC INTERFACE l.388-389] Under refc the refusal is the product's own
    # (`ChannelsMove`); under orc and arc the hook stands for a kind without
    # erasure.
    let (e, orch) = ready(wipeConfig())
    when ChannelsMove:
      check orch.vaultRoute(e, Vault, "direct").code == ecOk
      check e.setErasureMissingForTests({rmDirect}).isOk
    let refused = orch.vaultRoute(e, Vault, "refused")
    check refused.code == ecModule
    check refused.message == MarkedUnsupported
    check refused.response.len == 0
    when ChannelsMove:
      check e.setErasureMissingForTests({}).isOk
      check e.routes().len == 1
    else:
      check e.routes().len == 0
    check e.view(Vault).tryGet.state == msReady
    e.finish()
    when unixStream:
      let (t, torch) = ready(wipeConfig(transported = true))
      when ChannelsMove:
        check torch.vaultRoute(t, Vault, "transported").code == ecOk
        check t.setErasureMissingForTests({rmLocalTransport}).isOk
      let no = torch.vaultRoute(t, Vault, "refused")
      check no.code == ecModule
      check no.message == MarkedUnsupported
      check no.response.len == 0
      when ChannelsMove:
        check t.setErasureMissingForTests({}).isOk
        check t.routes().len == 1
      else:
        check t.routes().len == 0
      t.finish()

suite "wipe: a transported route (W-6)":
  teardown:
    disarmWipeAudit()
    leftover()

  test "[IFC-0575] [IFC-0576] every method and rejection of a marked contract on a local-transport route leaves no copy in the Runtime, its served endpoint or the caller's binding":
    when ChannelsMove:
      when unixStream:
        let (e, orch) = ready(wipeConfig(transported = true))
        var h = orch.vaultHandle(e, Vault, "w6")
        arm()
        h.matrix()
        h.release()
        check e.absentFrom()
        e.finish()
        if scans:
          check hits() == 0
      else:
        skip()
    else:
      skip() # [DECISIONS G277] a refc build routes no marked contract (W-10)

# Retention (W-9) --------------------------------------------------------------------

proc caConfig(transported = false): EngineConfig =
  result = wipeConfig(transported)
  result.statics.add(fakeCaRegistration())
  result.authority = Opt.some(
    AuthorityPolicy(instance: Ca, evaluationDeadline: initDuration(seconds = 60))
  )

proc caReady(transported = false): (Engine, ptr LogosRuntimeControlBinding) =
  resetFake()
  result = ready(caConfig(transported))
  discard result[0].started(fakeCaRecord(), Ca)
  check result[0].authorityBound()[0]

proc retaining(request = true, response = true): Rule =
  ## A single-use allow of every call whose `commitment` retains the sides
  ## asked.
  result = allow("call", validMs = 0)
  result.retainRequest = request
  result.retainResponse = response

proc lastCall(e: Engine): AuthzAnswer =
  for a in e.answers():
    if a.request.action == aaCall:
      result = a

proc holds(hay, needle: openArray[byte]): bool =
  if needle.len == 0 or needle.len > hay.len:
    return false
  for i in 0 .. hay.len - needle.len:
    if hay.toOpenArray(i, i + needle.len - 1) == needle:
      return true

proc retention(e: Engine, orch: ptr LogosRuntimeControlBinding, vault = Vault) =
  ## `vault`: the instance called; the one in this process (`Vault`) is
  ## checked to keep nothing it was refused.
  setScript(allow("establish"))
  var h = orch.vaultHandle(e, vault, "w9")
  arm()
  # Both sides retained: a marked request or response is refused before
  # dispatch (INTERFACE l.395-397; CA l.479); the module never runs.
  setScript(retaining())
  var b = storeReq()
  var r = h.raw("store", b)
  wipe(b)
  check r.code == ecNotAuthorised
  check e.lastCall.outcome == azRefused and e.lastCall.reason == "sensitive-retention"
  wipe(r)
  if vault == Vault:
    check vaultHolds(int(Slot)).len == 0
  b = slotReq()
  r = h.raw("fetch", b)
  check r.code == ecNotAuthorised
  wipe(r)
  b = exchangeReq()
  r = h.raw("exchange", b)
  wipe(b)
  check r.code == ecNotAuthorised
  wipe(r)
  # An unmarked method of the same contract keeps its retention: its record
  # holds its request's value root.
  let records = e.audit.records.len
  b = slotReq()
  let peekRoot = valueRootOf("vault.peek_request", b)
  r = h.raw("peek", b)
  check r.code == ecOk
  wipe(r)
  check waitUntil(
    proc(): bool =
      e.audit.records.len > records
  )
  check e.audit.records[^1].bytes.holds(peekRoot)
  # Per side: the response alone retained lets `store` through, not `fetch`.
  setScript(retaining(request = false))
  b = storeReq()
  r = h.raw("store", b)
  wipe(b)
  check r.code == ecOk
  wipe(r)
  b = slotReq()
  r = h.raw("fetch", b)
  check r.code == ecNotAuthorised
  wipe(r)
  # Nothing retained: every method runs.
  setScript(retaining(request = false, response = false))
  b = slotReq()
  r = h.raw("fetch", b)
  check r.code == ecOk
  var held = lookupBytes(r.response, "secret")
  check held == canary
  wipe(held)
  wipe(r)
  h.release()
  check e.absentFrom()

suite "wipe: retention of a marked payload (W-9)":
  teardown:
    disarmWipeAudit()
    leftover()

  test "[IFC-0581] [SEC-0057] on a direct route a decision that retains a marked side refuses the call NOT_AUTHORISED before dispatch, recorded as sensitive-retention without a value root; an unmarked method keeps its root":
    when ChannelsMove:
      let (e, orch) = caReady()
      e.retention(orch)
      # On a path kind without erasure the route is refused after its authority
      # and contract checks, whatever the decision retains, and nothing is
      # downgraded to ordinary handling (INTERFACE l.386-388; G277).
      check e.setErasureMissingForTests({rmDirect}).isOk
      for i, keep in [true, false]:
        var rule = allow("establish")
        rule.retainRequest = keep
        rule.retainResponse = keep
        setScript(rule)
        let refused = orch.vaultRoute(e, Vault, "w9-" & $i)
        check refused.code == ecModule
        check refused.message == MarkedUnsupported
      check e.setErasureMissingForTests({}).isOk
      e.finish()
      if scans:
        check hits() == 0
    else:
      skip() # [DECISIONS G277] a refc build routes no marked contract (W-10)

  test "[IFC-0581] [SEC-0057] the same on a local-transport route: the served endpoint admits through the same check":
    when ChannelsMove:
      when unixStream:
        let (e, orch) = caReady(transported = true)
        e.retention(orch)
        e.finish()
        if scans:
          check hits() == 0
      else:
        skip()
    else:
      skip() # [DECISIONS G277] a refc build routes no marked contract (W-10)

# Asynchronous calls (W-5) -----------------------------------------------------------

type Done = object
  count: Atomic[int]
  code: Atomic[int]
  canaries: Atomic[int] ## completions whose response held the canary

var done: Done

proc onComplete(
    userData: pointer,
    r: LogosResult,
    response: ptr UncheckedArray[uint8],
    len: csize_t,
    owner: LogosResponseOwner,
) {.cdecl, gcsafe, raises: [].} =
  let d = cast[ptr Done](userData)
  if response != nil and found(response, int(len)) > 0:
    d.canaries += 1
  if not owner.release.isNil:
    owner.release(owner.state)
  d.code.store(int(r.code))
  d.count += 1

proc prepared(
    h: var LogosRouteHandle, name: string, params: var seq[byte], timeoutMs = 0'u64
): LogosAsyncCall =
  ## A prepared call; `params` is wiped once the call holds its own copy.
  var o = LogosAsyncOptions(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncOptions)),
    hasTimeout: timeoutMs > 0,
    timeoutMs: timeoutMs,
  )
  var cb = LogosAsyncCallbacks(
    abiVersion: AsyncCallAbiVersion,
    structSize: csize_t(sizeof(LogosAsyncCallbacks)),
    complete: onComplete,
    userData: addr done,
  )
  result = LogosAsyncCall()
  var r = toResult(
    h.vtable.prepareCall(
      addr h,
      cstring(name),
      cast[ptr UncheckedArray[uint8]](addr params[0]),
      csize_t(params.len),
      addr o,
      addr cb,
      addr result,
    )
  )
  check r.code == ecOk
  wipe(r)
  wipe(params)

proc completions(n: int): bool =
  waitUntil(
    proc(): bool =
      done.count.load >= n
  )

proc deferredCalls(transported: bool) =
  let (e, orch) = ready(wipeConfig(transported))
  var h = orch.vaultHandle(e, DVault, "w5")
  done.count.store(0)
  done.canaries.store(0)
  arm()
  # A held `store` the caller cancels: the provider still reads its request
  # intact after `complete` and before `execution_release` (INTERFACE l.2121).
  var b = storeReq()
  var c = h.prepared("store", b)
  c.vtable.submit(addr c)
  let p = takeVault()
  check p.parked
  c.vtable.cancel(addr c)
  check completions(1)
  check done.code.load == ord(ecCancelled)
  p.answerVault()
  check rereadIntact.load == 1 and rereadChanged.load == 0
  c.vtable.release(addr c)
  var held = vaultHolds(int(Slot))
  check held == canary
  wipe(held)
  # A held `fetch` (response marked) past its deadline: TIMEOUT, then the
  # provider's late response holding the canary is dropped.
  b = slotReq()
  c = h.prepared("fetch", b, timeoutMs = uint64(50 * Slow))
  c.vtable.submit(addr c)
  let q = takeVault()
  check q.parked
  check completions(2)
  check done.code.load == ord(ecTimeout)
  q.answerVault()
  check rereadIntact.load == 2
  c.vtable.release(addr c)
  # A held `fetch` the caller cancels, answered after its CANCELLED: the
  # provider's response holding the canary is dropped. On a local-transport
  # route either the provider's Runtime (once it handled the Stop) or the
  # serving loop drops it, by timing; `lateAnswer` is the loop's case alone.
  b = slotReq()
  c = h.prepared("fetch", b)
  c.vtable.submit(addr c)
  let k = takeVault()
  check k.parked
  c.vtable.cancel(addr c)
  check completions(3)
  check done.code.load == ord(ecCancelled)
  k.answerVault()
  check rereadIntact.load == 3
  c.vtable.release(addr c)
  # A held `exchange` answered in time: its response reaches the caller.
  b = exchangeReq()
  c = h.prepared("exchange", b)
  c.vtable.submit(addr c)
  let x = takeVault()
  check x.parked
  x.answerVault()
  check completions(4)
  check done.code.load == ord(ecOk)
  check done.canaries.load == 1
  c.vtable.release(addr c)
  h.release()
  check e.absentFrom()
  e.finish()
  if scans:
    check hits() == 0

when unixStream:
  # The serving loop alone, its owner standing in for both Runtimes.
  from ./support/trnowner import
    Owner, newOwner, serve, connect, issue, pump, send, stop
  from ./support/peerproc import dupCloexec
  from ../src/logos_core/transport/io import
    CallOutcome, ContractInput, IoCommand, IoCommandKind, IoEvent, IoEventKind,
    createEndpoint, removeEndpoint

  proc seen(o: Owner, cond: proc(ev: IoEvent): bool): Opt[IoEvent] =
    ## The first event of the whole log that matches, once there is one.
    let deadline = getMonoTime() + initDuration(milliseconds = 5000 * Slow)
    while true:
      for i in 0 ..< o.log.len:
        if cond(o.log[i]):
          return Opt.some(o.log[i])
      if getMonoTime() >= deadline:
        return Opt.none(IoEvent)
      discard o.pump(10)

  proc lateAnswer() =
    ## [DECISIONS G276] The provider's ok-Response to a request whose CANCELLED
    ## the serving loop already committed is decoded, then discarded: its tree
    ## is zeroed, as any Response not sent. Through a Runtime this is a race
    ## (the Cancel of a timeout or a cancel reaches the loop before the late
    ## answer that the provider's Runtime had not yet turned away); CI on
    ## eed9d58 hit it once, on aarch64.
    let ep = createEndpoint(shortBase, "vault_module").tryGet
    let input = ContractInput(root: vaultRoot, schema: vaultSchema, system: false)
    let o = newOwner()
    o.respond = false
    check o.serve(
      1,
      dupCloexec(ep.listener),
      provider = "vault_module",
      contract = input,
      contracts = @[vaultRoot],
    )
    o.connect(
      7,
      ep.path,
      o.issue(trnowner.binding(provider = "vault_module", contract = vaultRoot)),
      module = "vault_module",
      selected = input,
    )
    let est = o.seen(
      proc(ev: IoEvent): bool =
        ev.kind == IoEventKind.evEstablished
    )
    check est.isSome
    check o.seen(
      proc(ev: IoEvent): bool =
        ev.kind == IoEventKind.evConnected and ev.conn == 7
    ).isSome
    let callee = est.get.conn
    arm()
    o.send(
      IoCommand(
        conn: 7,
        kind: IoCommandKind.cmdCall,
        tag: 1,
        methodName: "fetch",
        params: slotReq(),
      )
    )
    let d = o.seen(
      proc(ev: IoEvent): bool =
        ev.kind == IoEventKind.evDispatch and ev.conn == callee
    )
    check d.isSome
    o.send(IoCommand(conn: 7, kind: IoCommandKind.cmdCancel, callTag: 1))
    let r = o.seen(
      proc(ev: IoEvent): bool =
        ev.kind == IoEventKind.evResponse and ev.conn == 7 and ev.tag == 1
    )
    check r.isSome and not r.get.outcome.ok and r.get.outcome.failure.code == ecCancelled
    check o.seen(
      proc(ev: IoEvent): bool =
        ev.kind == IoEventKind.evStop and ev.conn == callee
    ).isSome
    # The provider's answer, holding the canary, after its CANCELLED.
    o.send(
      IoCommand(
        conn: callee,
        kind: IoCommandKind.cmdRespond,
        requestId: d.get.requestId,
        outcome: CallOutcome(ok: true, result: req(kv("secret", cbor(canary)))),
        workEnded: true,
      )
    )
    # The loop handles commands in order: once the next call is dispatched,
    # the answer was handled.
    o.send(
      IoCommand(
        conn: 7,
        kind: IoCommandKind.cmdCall,
        tag: 2,
        methodName: "fetch",
        params: slotReq(),
      )
    )
    check o.seen(
      proc(ev: IoEvent): bool =
        ev.kind == IoEventKind.evDispatch and ev.conn == callee and
          ev.requestId != d.get.requestId
    ).isSome
    o.stop()
    check removeEndpoint(ep).isOk
    var answers = 0
    for ev in o.log:
      if ev.kind == IoEventKind.evResponse and ev.conn == 7 and ev.tag == 1:
        inc answers
    check answers == 1 # its CANCELLED only
    if scans:
      check hits() == 0

suite "wipe: asynchronous calls (W-5)":
  teardown:
    disarmWipeAudit()
    leftover()

  test "[IFC-0576] [IFC-0575] a deferred provider's request stays intact until its execution is released, through a cancel and a timeout, and no copy is left once it is":
    when ChannelsMove:
      deferredCalls(transported = false)
    else:
      skip() # [DECISIONS G277] a refc build routes no marked contract (W-10)

  test "[IFC-0576] [IFC-0575] the same through a local-transport route: a Cancel and a late Response":
    when ChannelsMove:
      when unixStream:
        deferredCalls(transported = true)
      else:
        skip()
    else:
      skip() # [DECISIONS G277] a refc build routes no marked contract (W-10)

  test "[IFC-0575] the serving loop alone: a provider's answer after its CANCELLED is discarded and leaves no copy":
    when unixStream:
      lateAnswer()
    else:
      skip()

# Hosted routes (W-7; W-9 and W-10 with a hosted end) ---------------------------------
#
# The vault built as a shared library in an audit build of the Module Host,
# and `probe_module` as a hosted consumer that calls through its own route
# handles (`kit/probe_impl.nim`, `serve`). The Runtime sends each host the
# patterns in its `init` (`setWipeAuditForTests`); an audit host exits 97 at
# a graceful end that released a block holding one. Every host's stderr is
# this process's fd 2, sent to a file for the case and checked. The carrier
# trace counts the frames between the Runtime and its hosts that hold a
# pattern: payloads go between the participants directly.

when defined(posix):
  import std/posix except Time
  from logos_sdk/pins import HashSuiteId
  import logos_sdk/crypto/blake3
  import ../src/logos_core/runtime/hostsup
  import ./support/[childbuild, modulehostbuild]
  from ./support/trnowner import fastConfig, Ms
  from ../src/logos_core/host/state import ExitWipeAudit

  const
    SanitizerEnv =
      ["ASAN_OPTIONS", "LSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS", "UBSAN_OPTIONS"]
    HoldSlot = 14'u64 ## `exchange` there waits for a cancel or the file `open`
    HVault = "hv"
    HProbe = "p"

  proc digestOf(path: string): array[32, byte] =
    var h: Blake3Hasher
    h.init()
    let bytes = readFile(path)
    h.update(bytes.toOpenArrayByte(0, bytes.high))
    h.finish()

  let
    hostProgram = moduleHostProgram()
    vaultLib = buildKitLibrary("vault_impl.nim", "wvault")
    probeLib = buildKitLibrary("probe_impl.nim", "wprobe")
    vaultDigest = digestOf(vaultLib)
    probeDigest = digestOf(probeLib)
    errPath = work / "hosts.stderr"

  proc hostedConfig(): EngineConfig =
    ## `wipeConfig` with a state root and the Module Host; no routing rule, so
    ## a route with a hosted end is `local-transport` (R10).
    result = wipeConfig()
    result.stateRoot = Opt.some(result.workDir / "state")
    result.moduleHost = Opt.some(hostProgram)
    result.moduleHostEnv = @SanitizerEnv
    result.endpointDir = shortBase / ("e" & $engines)
    # [IMPL] Only a bound on how long a Hello with a host may take, which no
    # case here is about. A hosted provider's Hello crosses the carrier both
    # ways, since the Runtime judges it: about 1 s under MemorySanitizer on an
    # idle host (0.13 s under orc), and a loaded CI runner passed fastConfig's
    # 15 s (CI on 8522a1f and 5887c5a; a short deadline gives the same
    # failures, `ccHelloTimeout`).
    var transport = fastConfig()
    transport.helloTimeout = 60_000 * Ms * Slow
    result.transport = Opt.some(transport)
    # [IMPL] Only a bound on the hosts' graceful ends, which a case checks.
    # An audit host's end under ThreadSanitizer on a loaded CI runner passed
    # the 10 s default, and the Runtime killed it (CI on eed9d58).
    result.shutdownGrace = initDuration(seconds = 10 * Slow)

  proc stateOf(cfg: EngineConfig, state: string): string =
    result = cfg.stateRoot.get / state
    createDir(result)

  proc hostedVault(): ModuleRecord =
    ModuleRecord(
      module: "vault_module",
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: "wvault", localPath: vaultLib, hash: vaultDigest, hashSuite: HashSuiteId
      ),
      primaryContract: Opt.some(vaultRoot),
      stateAssignment: Opt.some("hv"),
    )

  proc hostedProbe(): ModuleRecord =
    ModuleRecord(
      module: "probe_module",
      strategy: stHostedDynamic,
      placement: "process",
      artifact: ArtifactRecord(
        id: "wprobe", localPath: probeLib, hash: probeDigest, hashSuite: HashSuiteId
      ),
      stateAssignment: Opt.some("p"),
    )

  # Hosts' stderr and ends.

  var savedErr: cint = -1

  let crashSignals = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT]
  var crashActions: array[5, Sigaction] ## theirs, while captured

  proc replayCaptured() {.noconv.} =
    ## [IMPL] The process ends while fd 2 is captured: fd 2 back, then the
    ## capture, which holds why (a sanitizer's report, a crash's message, a
    ## defect in a thread). Without it the log shows nothing of it (CI on
    ## 8522a1f, the hosted W-7 case under MemorySanitizer). System calls only:
    ## it runs in a signal handler and in a sanitizer's death.
    let saved = savedErr
    if saved < 0:
      return
    savedErr = -1
    discard dup2(saved, 2)
    const Head = "\n[test_wipe_routes] ending while stderr is captured; the capture:\n"
    discard posix.write(2, cstring(Head), Head.len)
    {.cast(gcsafe).}:
      let src = posix.open(cstring(errPath), O_RDONLY)
    if src >= 0:
      var buf: array[4096, char]
      while true:
        let n = posix.read(src, addr buf[0], buf.len)
        if n <= 0:
          break
        discard posix.write(2, addr buf[0], n)
      discard posix.close(src)

  proc onCrash(sig: cint) {.noconv.} =
    ## The capture shown, then the signal's own handler: a fault recurs on
    ## return, and `abort` raises again.
    replayCaptured()
    for i, s in crashSignals:
      if s == sig:
        discard sigaction(sig, crashActions[i], nil)

  addExitProc(replayCaptured) # a `quit`, an unhandled defect in a thread
  when defined(asan) or defined(msan) or defined(tsan):
    proc sanitizerDeathCallback(
      cb: proc() {.noconv.}
    ) {.importc: "__sanitizer_set_death_callback", cdecl.}

    sanitizerDeathCallback(replayCaptured) # its report, before it exits

  proc captureStderr() =
    ## From now on fd 2, which every host spawned inherits, goes to `errPath`.
    flushFile(stderr)
    savedErr = dup(2)
    let fd = posix.open(cstring(errPath), O_WRONLY or O_CREAT or O_TRUNC, 0o600)
    discard dup2(fd, 2)
    discard posix.close(fd)
    var act: Sigaction
    act.sa_handler = onCrash
    discard sigemptyset(act.sa_mask)
    for i, s in crashSignals:
      discard sigaction(s, act, crashActions[i])

  proc restoreStderr(): bool =
    ## fd 2 back; whether nothing written meanwhile holds a pattern. What was
    ## written is shown on it.
    if savedErr < 0:
      return true
    for i, s in crashSignals:
      discard sigaction(s, crashActions[i], nil)
    flushFile(stderr)
    discard dup2(savedErr, 2)
    discard posix.close(savedErr)
    savedErr = -1
    var s = readFile(errPath)
    result = finds(s) == 0
    if s.len > 0:
      stderr.write(s)
    wipe(s)

  proc graceful(since, count: int): bool =
    ## `count` hosts ended after the first `since` ends, every one exited 0:
    ## an audit host exits 97 at a graceful end that found a pattern.
    if not waitUntil(
      proc(): bool =
        hostEnds().len >= since + count
    ):
      return false
    result = true
    let ends = hostEnds()
    for x in ends[since .. ^1]:
      if not x.exited or x.status != 0:
        checkpoint(
          "a host ended: exited " & $x.exited & ", status " & $x.status & ", " & x.reason &
            " " & x.carrierLost
        )
        result = false

  proc noHostLeft(): bool =
    waitUntil(
      proc(): bool =
        hostPids(hostProgram).len == 0
    )

  proc audited(e: Engine) =
    ## Hosts spawned from now on are armed with the patterns, when this build
    ## scans (an audit host of a refc build would find refc's own channel
    ## copies, a stated non-claim). Before `arm`: the copies made on the way
    ## are released unscanned.
    if scans:
      e.setWipeAuditForTests(patterns())

  proc traceAll() =
    ## Counts the carrier frames that hold a pattern, from now on. The one
    ## exemption is the `init`'s `wipe_audit`, the patterns themselves
    ## (`hostsup.sendMsg`), so the trace starts before the hosts do.
    var p = patterns()
    traceMarkers(p)
    for x in p.mitems:
      wipe(x)

  proc noneTraced(): bool =
    let (frames, found) = traced()
    checkpoint("carrier frames " & $frames & ", holding a pattern " & $found)
    frames > 0 and found == 0

  proc unaudited() =
    setWipeAudit(newSeq[seq[byte]]())
    traceMarkers(newSeq[seq[byte]]())

  proc heldCalls(dir: string): int =
    try:
      readFile(dir / "held").splitLines.countIt(it.len > 0)
    except IOError:
      0

  # The probe's command files (as in `test_hosted_routes`).

  type Consumer = object
    dir: string ## its state directory
    n: int ## the commands posted

  proc serving(cfg: EngineConfig): Consumer =
    let dir = cfg.stateOf("p")
    writeFile(dir / "probe.cmd", "serve\n")
    Consumer(dir: dir)

  func hexOf(b: openArray[byte]): string =
    for x in b:
      result.add(toHex(x, 2).toLowerAscii)

  proc unhexOf(s: string): seq[byte] =
    result = newSeq[byte](s.len div 2)
    for i in 0 ..< result.len:
      result[i] = byte(parseHexInt(s[2 * i .. 2 * i + 1]))

  proc run(c: var Consumer, line: string): string =
    ## The probe's answer to one command: `<code> <hex value or message>`, or
    ## `none` if it gave none in time.
    inc c.n
    let path = c.dir / ("cmd-" & $c.n)
    writeFile(path & ".tmp", line)
    moveFile(path & ".tmp", path)
    let answer = c.dir / ("out-" & $c.n)
    if not waitUntil(
      proc(): bool =
        fileExists(answer)
    ):
      return "none"
    readFile(answer)

  proc codeIn(line: string): Opt[ErrorCode] =
    try:
      errorCode(parseBiggestInt(line.split(' ', 1)[0]))
    except ValueError:
      Opt.none(ErrorCode)

  func valueIn(line: string): string =
    let w = line.split(' ', 1)
    if w.len > 1:
      w[1]
    else:
      ""

  proc linesOf(c: Consumer, file: string): seq[string] =
    try:
      readFile(c.dir / file).splitLines.filterIt(it.len > 0)
    except IOError:
      @[]

  proc establishVia(c: var Consumer, e: Engine, instance, key: string): string =
    ## The probe's `establish_route` to `instance`'s vault: its line.
    c.run(
      "rc establish_route " &
        hexOf(
          establishReq(
            key,
            vaultRoot,
            provider = Opt.some(providerAddress(e.view(instance).tryGet.providerId)),
          )
        )
    )

  proc materializeVia(
      c: var Consumer, e: Engine, instance, key: string, slot: int
  ): string =
    ## A route to `instance` established by the probe, then its
    ## `materialize_route` into the handle `slot`: that line.
    let line = c.establishVia(e, instance, key)
    check codeIn(line) == Opt.some(ecOk)
    if codeIn(line) != Opt.some(ecOk):
      return "none"
    let resp =
      LogosNSRuntimeControlEstablishRouteResponse.decode(unhexOf(valueIn(line)))
    check resp.isOk and resp.get.routes.len == 1
    if resp.isErr or resp.get.routes.len != 1:
      return "none"
    c.run(
      "materialize " & $slot & " " & resp.get.routes[0].route & " " & hexOf(vaultRoot) &
        " " & hexOf(vaultSchema)
    )

  proc routeVia(c: var Consumer, e: Engine, instance, key: string, slot: int): bool =
    ## A route to `instance` materialized in the probe's handle `slot`.
    let m = c.materializeVia(e, instance, key, slot)
    checkpoint("materialize: " & m)
    codeIn(m) == Opt.some(ecOk)

  proc refusedInit(e: Engine, r: ModuleRecord, instance: string): bool =
    ## [DECISIONS G277] A provider a refc Module Host refuses at `init`: the
    ## instance ends in error with the host's message.
    discard e.create(r, instance).tryGet
    discard e.start(instance)
    let v = e.view(instance).tryGet
    checkpoint(
      "state " & $v.state & ": " & (if v.failure.isSome: v.failure.get.reason else: "")
    )
    v.state == msError and v.failure.isSome and
      MarkedUnsupportedByHost in v.failure.get.reason

  var refcHost: string

  proc refcHostProgram(): string =
    ## [DECISIONS G277] The Module Host built under refc, for a suite that is
    ## not: the Runtime erases, the host refuses its own part.
    if refcHost.len == 0:
      refcHost = buildChild(
        "src/logos_module_host.nim",
        "logos-module-host",
        "module-host-refc",
        mm = "refc",
      )
    refcHost

  proc callVia(
      c: var Consumer, slot: int, meth: string, params: var seq[byte]
  ): string =
    ## The probe's answer to a call through its handle `slot`; `params` is
    ## wiped once posted (hex: no pattern).
    let line = "call " & $slot & " " & meth & " " & hexOf(params)
    wipe(params)
    c.run(line)

  proc secretIn(line, key: string): seq[byte] =
    ## The value at `key` of a successful answer's map; none for any other
    ## answer, whose message is not hex (its check has failed already).
    if codeIn(line) != Opt.some(ecOk):
      return
    var b = unhexOf(valueIn(line))
    result = lookupBytes(b, key)
    wipe(b)

  proc probeMatrix(c: var Consumer, slot: int, hold: string) =
    ## The W-4 matrix through the probe's handle `slot`, except a provider
    ## failure that holds the canary (the probe writes a failure's message to
    ## its answer file: its own copy), then a held `exchange` the probe
    ## cancels. `hold`: the called vault's state directory.
    var b = storeReq()
    check codeIn(c.callVia(slot, "store", b)) == Opt.some(ecOk)
    b = slotReq()
    var line = c.callVia(slot, "peek", b)
    check codeIn(line) == Opt.some(ecOk)
    b = slotReq()
    line = c.callVia(slot, "fetch", b)
    check codeIn(line) == Opt.some(ecOk)
    var held = line.secretIn("secret")
    check held == canary
    wipe(held)
    b = exchangeReq()
    line = c.callVia(slot, "exchange", b)
    check codeIn(line) == Opt.some(ecOk)
    held = line.secretIn("previous")
    check held == canary
    wipe(held)
    b = storeReq(slot = 2, extra = canaryText)
    line = c.callVia(slot, "store", b)
    check codeIn(line) == Opt.some(ecInvalidParams)
    check canaryText notin line and hexOf(canary) notin line
    b = storeReq(slot = BadSlot)
    check codeIn(c.callVia(slot, "store", b)) == Opt.some(ecOk)
    b = slotReq(BadSlot)
    line = c.callVia(slot, "fetch", b)
    check codeIn(line) == Opt.some(ecModule)
    check canaryText notin line
    # A held `exchange` cancelled by the probe: the vault answers once it sees
    # the cancel, with the canary; its late response is dropped.
    b = storeReq(slot = HoldSlot)
    check codeIn(c.callVia(slot, "store", b)) == Opt.some(ecOk)
    b = exchangeReq(HoldSlot)
    let prep = "prepare " & $slot & " 0 exchange " & hexOf(b) & " -"
    wipe(b)
    let before = heldCalls(hold)
    check codeIn(c.run(prep)) == Opt.some(ecOk)
    check codeIn(c.run("submit 0")) == Opt.some(ecOk)
    check waitUntil(
      proc(): bool =
        heldCalls(hold) == before + 1
    )
    check codeIn(c.run("cancel 0")) == Opt.some(ecOk)
    let probe = c
    check waitUntil(
      proc(): bool =
        probe.linesOf("done").len == 1
    )
    let ended = c.linesOf("done")
    check ended.len == 1 and ended[0].startsWith("0 " & $ord(ecCancelled) & " ")
    check codeIn(c.run("release-call 0")) == Opt.some(ecOk)
    b = slotReq(HoldSlot)
    line = c.callVia(slot, "fetch", b)
    check codeIn(line) == Opt.some(ecOk)
    held = line.secretIn("secret")
    check held == canary
    wipe(held)
    check codeIn(c.run("release " & $slot)) == Opt.some(ecOk)

  proc heldCancel(h: var LogosRouteHandle, hold: string) =
    ## A held `exchange` this process cancels on its handle: the hosted vault
    ## answers with the canary once it sees the cancel; the late response is
    ## dropped.
    var b = storeReq(slot = HoldSlot)
    var r = h.raw("store", b)
    wipe(b)
    check r.code == ecOk
    wipe(r)
    done.count.store(0)
    done.canaries.store(0)
    b = exchangeReq(HoldSlot)
    var c = h.prepared("exchange", b)
    c.vtable.submit(addr c)
    check waitUntil(
      proc(): bool =
        heldCalls(hold) == 1
    )
    c.vtable.cancel(addr c)
    check completions(1)
    check done.code.load == ord(ecCancelled)
    c.vtable.release(addr c)
    b = slotReq(HoldSlot)
    r = h.raw("fetch", b)
    check r.code == ecOk
    var held = lookupBytes(r.response, "secret")
    check held == canary
    wipe(held)
    wipe(r)

  suite "wipe: hosted routes (W-3, W-7, W-9, W-10)":
    teardown:
      unaudited()
      disarmWipeAudit()
      discard restoreStderr()
      leftover()

    test "[IFC-0575] [IFC-0576] [IFC-0580] W-7 every method, rejection and a Cancel on a route to a hosted provider leaves no copy in the audit host, the Runtime or the caller, no carrier frame holds one, and nor does the host's stderr":
      when ChannelsMove:
        let since = hostEnds().len
        let cfg = hostedConfig()
        let hold = cfg.stateOf("hv")
        engineWork = cfg.workDir
        vaultReset()
        let e = fixtureEngine(cfg)
        e.audited()
        captureStderr()
        traceAll()
        check e.started(hostedVault(), HVault).state == msReady
        let (_, orch) = e.startClient()
        var h = orch.vaultHandle(e, HVault, "w7")
        arm()
        h.matrix(local = false)
        h.heldCancel(hold)
        h.release()
        check noneTraced()
        check e.absentFrom()
        e.finish()
        # Every host ended, and so wrote all it will, before the capture is read.
        check graceful(since, 1)
        check restoreStderr()
        check noHostLeft()
        if scans:
          check hits() == 0
      else:
        skip() # [DECISIONS G277] a refc build routes no marked contract (W-10)

    test "[IFC-0575] [IFC-0576] [IFC-0580] W-7 the same from a hosted consumer, to a provider the Runtime serves and to a hosted one: no copy in either host or the Runtime":
      when ChannelsMove:
        let since = hostEnds().len
        var cfg = hostedConfig()
        let hold = cfg.stateOf("hv")
        let local = cfg.stateOf("v")
        engineWork = cfg.workDir
        vaultReset()
        var c = cfg.serving()
        let e = fixtureEngine(cfg)
        e.audited()
        captureStderr()
        var record = vaultRecord()
        record.stateAssignment = Opt.some("v")
        traceAll()
        check e.started(record, Vault).state == msReady
        check e.started(hostedVault(), HVault).state == msReady
        check e.started(hostedProbe(), HProbe).state == msReady
        arm()
        check c.routeVia(e, Vault, "local", 0)
        c.probeMatrix(0, local)
        writeFile(c.dir / "done", "") # the next Cancel's line is the first again
        check c.routeVia(e, HVault, "hosted", 1)
        c.probeMatrix(1, hold)
        check noneTraced()
        check e.absentFrom()
        e.finish()
        # Every host ended, and so wrote all it will, before the capture is read.
        check graceful(since, 2)
        check restoreStderr()
        check noHostLeft()
        if scans:
          check hits() == 0
      else:
        skip() # [DECISIONS G277] a refc build routes no marked contract (W-10)

    test "[IFC-0581] [SEC-0057] W-9 on a route to a hosted provider a decision that retains a marked side refuses the call NOT_AUTHORISED before dispatch; the host never runs it":
      when ChannelsMove:
        let since = hostEnds().len
        var cfg = hostedConfig()
        discard cfg.stateOf("hv")
        cfg.statics.add(fakeCaRegistration())
        cfg.authority = Opt.some(
          AuthorityPolicy(instance: Ca, evaluationDeadline: initDuration(seconds = 60))
        )
        engineWork = cfg.workDir
        resetFake()
        let e = fixtureEngine(cfg)
        e.audited()
        captureStderr()
        let (_, orch) = e.startClient()
        check e.started(hostedVault(), HVault).state == msReady
        discard e.started(fakeCaRecord(), Ca)
        check e.authorityBound()[0]
        e.retention(orch, HVault)
        e.finish()
        # Every host ended, and so wrote all it will, before the capture is read.
        check graceful(since, 1)
        check restoreStderr()
        if scans:
          check hits() == 0
      else:
        skip() # [DECISIONS G277] a refc build routes no marked contract (W-10)

    test "[IFC-0578] [IFC-0579] W-10 a marked contract is routed to a hosted provider and from a hosted consumer; with the path kind without erasure, and in a refc build, it is refused MODULE_ERROR with no handle, and a refc host refuses the provider at init":
      var cfg = hostedConfig()
      discard cfg.stateOf("hv")
      var c = cfg.serving()
      let e = fixtureEngine(cfg)
      check e.started(vaultRecord(), Vault).state == msReady
      when ChannelsMove:
        check e.started(hostedVault(), HVault).state == msReady
      else:
        check e.refusedInit(hostedVault(), HVault)
      check e.started(hostedProbe(), HProbe).state == msReady
      when ChannelsMove:
        let (_, orch) = e.startClient()
        check orch.vaultRoute(e, HVault, "to-hosted").code == ecOk
        check codeIn(c.establishVia(e, Vault, "from-hosted")) == Opt.some(ecOk)
        check e.setErasureMissingForTests({rmLocalTransport}).isOk
        let refused = orch.vaultRoute(e, HVault, "refused")
        check refused.code == ecModule
        check refused.message == MarkedUnsupported
        check refused.response.len == 0
      let line = c.establishVia(e, Vault, "refused-hosted")
      check codeIn(line) == Opt.some(ecModule)
      check MarkedUnsupported in line
      when ChannelsMove:
        check e.setErasureMissingForTests({}).isOk
        check e.routes().len == 2
      else:
        check e.routes().len == 0
      e.finish()
      check noHostLeft()

    test "[IFC-0578] [IFC-0579] W-10 a refc Module Host under an orc Runtime refuses its own part: a provider whose contract marks a payload fails init, and a hosted consumer's route to one fails at materialization, MODULE_ERROR":
      when ChannelsMove and (defined(msan) or (defined(asan) and not defined(clang))):
        # Under gcc's AddressSanitizer refc's stack scan is instrumented
        # (nimbase.h's CLANG_NO_SANITIZE_ADDRESS is empty but for clang), so a
        # refc program reports its own scan of the stack as an overflow. Under
        # MemorySanitizer, which nimbase.h exempts it from on no compiler, the
        # scan reads stack memory nothing initialized, such as its own
        # `registers` buffer (on x86_64 and aarch64).
        skip()
      elif ChannelsMove:
        when defined(asan):
          # refc scans the stack conservatively and cannot see AddressSanitizer's
          # fake stack frames, so a refc host under detect_stack_use_after_return
          # frees what its locals still hold. Its hosts start without fake
          # stacks (the last setting wins); this process read its own at start.
          let asanOptions = getEnv("ASAN_OPTIONS")
          putEnv(
            "ASAN_OPTIONS",
            (if asanOptions.len > 0: asanOptions & ":" else: "") &
              "detect_stack_use_after_return=0",
          )
          defer:
            if asanOptions.len == 0:
              delEnv("ASAN_OPTIONS")
            else:
              putEnv("ASAN_OPTIONS", asanOptions)
        let program = refcHostProgram()
        var cfg = hostedConfig()
        cfg.moduleHost = Opt.some(program)
        discard cfg.stateOf("hv")
        var c = cfg.serving()
        let e = fixtureEngine(cfg)
        check e.started(vaultRecord(), Vault).state == msReady
        check e.refusedInit(hostedVault(), HVault)
        check e.started(hostedProbe(), HProbe).state == msReady
        let line = c.materializeVia(e, Vault, "refc-host", 0)
        check codeIn(line) == Opt.some(ecModule)
        check MarkedUnsupported in line
        e.finish()
        check waitUntil(
          proc(): bool =
            hostPids(program).len == 0
        )
      else:
        skip() # the W-10 case above runs this build's own refc host

    test "W-3 the free scan proves itself in an audit host: a copy the module releases unwiped makes the host exit 97 at its graceful end, with the report on its stderr":
      when ChannelsMove:
        if not scans:
          skip()
        else:
          let since = hostEnds().len
          let cfg = hostedConfig()
          discard cfg.stateOf("hv")
          engineWork = cfg.workDir
          vaultReset()
          let e = fixtureEngine(cfg)
          e.audited()
          captureStderr()
          check e.started(hostedVault(), HVault).state == msReady
          let (_, orch) = e.startClient()
          var h = orch.vaultHandle(e, HVault, "w3")
          var b = storeReq(note = "leak")
          var r = h.raw("store", b)
          wipe(b)
          check r.code == ecOk
          wipe(r)
          h.release()
          e.finish()
          check waitUntil(
            proc(): bool =
              hostEnds().len >= since + 1
          )
          let ends = hostEnds()
          check ends.len == since + 1 and ends[^1].exited and
            ends[^1].status == ExitWipeAudit
          let report = readFile(errPath)
          check "wipe audit: pattern" in report
          writeFile(errPath, "") # expected: not shown again
          check restoreStderr()
          check noHostLeft()
      else:
        skip() # [DECISIONS G277] a refc build routes no marked contract (W-10)
