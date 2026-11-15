## A native module written with the lcn-gen kit for `vault_module`
## (`tests/kit/vault_module.cddl`; Tier 4b step 4b-3b, DECISIONS I92): a
## contract that marks payloads (INTERFACE §1.2.1). `peek` marks nothing,
## `store` its request, `fetch` its response, `exchange` both.
##
## The vault keeps what it stores in fixed slots outside the Nim heap, so a
## handler on any thread may store under refc too, and the free scan of the
## erasure tests never sees the module's own copies (INTERFACE l.388, l.399:
## what a participant keeps is its own). Behaviours:
##
## - `store` with the note `echo` fails with a message that holds the secret
##   (a provider failure forwarded to the caller only, l.3366);
## - `store` with the note `leak` copies the secret to the Nim heap and drops
##   the copy unwiped, stores nothing and answers `stored: false`: the free
##   scan's self-test in an audit host (W-3);
## - `fetch` of slot 15 returns a note longer than its schema allows that holds
##   the secret (a response outside its schema: MODULE_ERROR);
## - `exchange` returns the slot's previous secret and keeps the new one; on
##   slot 14 it first adds a line to the file `held` in its state directory and
##   waits until the invocation is cancelled or the file `open` is there (at
##   most a minute: a module in a Module Host, which the test cannot reach).
##
## `vaultReset` zeroes every slot; `vaultHolds` copies one (the caller wipes it).

{.used.} # imported by the tests for the C symbols it exports
import std/[locks, os]
import ../generated/vault_module_kit

const
  VaultSlots* = 16
  VaultBytes* = 256
  HoldSlot = 14

type
  Slot = object
    stored: bool
    len: int
    data: array[VaultBytes, byte]

  Vault* = ref object
    services: ModuleServices
    stateDir: Opt[string]

var
  vaultLock: Lock
  slots: array[VaultSlots, Slot]
  vaultCalls*: int ## handler calls, under `vaultLock`

initLock(vaultLock)

proc vaultReset*() =
  ## Every slot empty and zeroed.
  withLock vaultLock:
    {.cast(gcsafe).}:
      secureZero(addr slots, sizeof(slots))
      vaultCalls = 0

proc vaultHolds*(slot: int): seq[byte] =
  ## A copy of what `slot` holds (empty when nothing); the caller wipes it.
  withLock vaultLock:
    {.cast(gcsafe).}:
      if slots[slot].stored:
        result = newSeq[byte](slots[slot].len)
        for i in 0 ..< slots[slot].len:
          result[i] = slots[slot].data[i]

proc keep(slot: int, secret: openArray[byte]) =
  {.cast(gcsafe).}:
    secureZero(addr slots[slot], sizeof(Slot))
    slots[slot].stored = true
    slots[slot].len = secret.len
    for i, b in secret:
      slots[slot].data[i] = b
    inc vaultCalls

proc held(slot: int): seq[byte] =
  {.cast(gcsafe).}:
    result = newSeq[byte](slots[slot].len)
    for i in 0 ..< slots[slot].len:
      result[i] = slots[slot].data[i]

proc noSlot(slot: uint32): InvocationFailure =
  failure(ecModule, "no vault slot " & $slot)

proc initModule(_: type Vault, init: ModuleInit): Result[Vault, InvocationFailure] =
  ok(Vault(services: init.services, stateDir: init.stateDir))

proc `peek`(
    v: Vault, r: VaultPeekRequest
): Result[VaultPeekResponse, InvocationFailure] =
  if r.slot >= VaultSlots:
    return err(noSlot(r.slot))
  withLock vaultLock:
    {.cast(gcsafe).}:
      inc vaultCalls
      result = ok(
        VaultPeekResponse(stored: slots[r.slot].stored, size: uint32(slots[r.slot].len))
      )

proc `store`(
    v: Vault, r: VaultStoreRequest
): Result[VaultStoreResponse, InvocationFailure] =
  if r.slot >= VaultSlots:
    return err(noSlot(r.slot))
  if r.note == Opt.some("echo"):
    var text = newString(r.secret.len)
    for i, b in r.secret:
      text[i] = char(b)
    result = err(failure(ecModule, "refused " & text))
    wipe(text)
    return
  if r.note == Opt.some("leak"):
    var leak = newSeq[byte](r.secret.len)
    for i, b in r.secret:
      leak[i] = b
    doAssert leak.len == r.secret.len # released unwiped, on purpose
    return ok(VaultStoreResponse(stored: false))
  withLock vaultLock:
    keep(int(r.slot), r.secret)
  ok(VaultStoreResponse(stored: true))

proc `fetch`(
    v: Vault, r: VaultFetchRequest
): Result[VaultFetchResponse, InvocationFailure] =
  if r.slot >= VaultSlots:
    return err(noSlot(r.slot))
  var secret: seq[byte]
  withLock vaultLock:
    {.cast(gcsafe).}:
      inc vaultCalls
    secret = held(int(r.slot))
  if r.slot == VaultSlots - 1:
    # Outside the schema: the note is at most 64 bytes. Built at its final
    # size, so no smaller copy is released on the way.
    let rounds = 64 div (secret.len + 1) + 1
    var note = newString(rounds * (secret.len + 1))
    var at = 0
    for _ in 0 ..< rounds:
      for b in secret:
        note[at] = char(b)
        inc at
      note[at] = '.'
      inc at
    return ok(VaultFetchResponse(secret: move secret, note: Opt.some(move note)))
  ok(VaultFetchResponse(secret: move secret))

proc hold(v: Vault) =
  let dir = v.stateDir.get("/nonexistent")
  try:
    let f = open(dir / "held", fmAppend)
    f.write("held\n")
    f.close()
  except CatchableError:
    discard
  var waited = 0
  while not v.services.isCancelled and not fileExists(dir / "open") and waited < 60_000:
    sleep(1)
    inc waited

proc `exchange`(
    v: Vault, r: VaultExchangeRequest
): Result[VaultExchangeResponse, InvocationFailure] =
  if r.slot >= VaultSlots:
    return err(noSlot(r.slot))
  if r.slot == HoldSlot:
    v.hold()
  var previous: seq[byte]
  withLock vaultLock:
    previous = held(int(r.slot))
    keep(int(r.slot), r.secret)
  ok(VaultExchangeResponse(previous: move previous))

exportVaultModule(Vault)
