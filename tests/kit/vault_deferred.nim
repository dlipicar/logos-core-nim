## A deferred provider for `vault_module` (INTERFACE §2.9.2; Tier 4b step
## 4b-3b plan §4.2 W-5): the vault kit's symbols plus `_MODULE_async_api`.
## `submit` parks each invocation for the test (`takeVault`) and keeps a
## checksum of its request bytes; the test answers it with the kit's own
## `_MODULE_dispatch` (`answerVault`). Between `complete` and
## `execution_release` the provider reads the request again: the Runtime keeps
## it intact until execution is released (INTERFACE l.2121), whatever the
## caller did meanwhile (`rereadIntact`, `rereadChanged`). `request_cancel` is
## counted and does nothing else.

{.used.}
import std/[atomics, os]
import ../../src/logos_core/abi/types
import ./vault_impl

const MaxHeld = 8

var
  held: array[MaxHeld, Atomic[pointer]]
  heldModules: array[MaxHeld, Atomic[pointer]]
  heldSums: array[MaxHeld, Atomic[uint64]]
  vaultCancels*: Atomic[int] ## `request_cancel` calls
  rereadIntact*, rereadChanged*: Atomic[int]

let kit = vaultModuleStaticSymbols()

proc symbol(suffix: string): pointer =
  for (name, p) in kit:
    if name == "logos_vault_module_MODULE_" & suffix:
      return p
  nil

let
  kitDispatch = cast[ModuleDispatchFn](symbol("dispatch"))
  kitFree = cast[ModuleFreeFn](symbol("free"))

proc sumOf(p: ptr UncheckedArray[uint8], n: csize_t): uint64 =
  ## FNV-1a over the bytes: no copy of them is kept.
  result = 0xcbf29ce484222325'u64
  for i in 0 ..< int(n):
    result = (result xor uint64(p[i])) * 0x100000001b3'u64

proc resetVaultDeferred*() =
  vaultCancels.store(0)
  rereadIntact.store(0)
  rereadChanged.store(0)
  for i in 0 ..< MaxHeld:
    held[i].store(nil)
    heldModules[i].store(nil)

type Owned = object
  module: ptr LogosModuleContext
  buf: ptr UncheckedArray[uint8]

proc releaseOwned(state: pointer) {.cdecl, gcsafe, raises: [].} =
  let o = cast[ptr Owned](state)
  if o.buf != nil:
    kitFree(o.module, o.buf)
  deallocShared(o)

proc submit(
    module: ptr LogosModuleContext, inv: ptr LogosProviderInvocation
) {.cdecl, gcsafe, raises: [].} =
  for i in 0 ..< MaxHeld:
    var expected: pointer = nil
    if held[i].compareExchange(expected, inv):
      heldModules[i].store(module)
      heldSums[i].store(sumOf(inv.paramsCbor, inv.paramsCborLen))
      return
  doAssert false, "too many held vault invocations"

proc requestCancel(
    module: ptr LogosModuleContext, inv: ptr LogosProviderInvocation
) {.cdecl, gcsafe, raises: [].} =
  vaultCancels += 1

type Parked* = object
  module: ptr LogosModuleContext
  inv: ptr LogosProviderInvocation
  sum: uint64

proc takeVault*(seconds = 10): Parked {.gcsafe.} =
  ## The oldest parked invocation, once there is one; none after `seconds`.
  var waited = 0
  while waited < seconds * 1000:
    for i in 0 ..< MaxHeld:
      let p = held[i].load
      if p != nil:
        var expected = p
        if held[i].compareExchange(expected, nil):
          return Parked(
            module: cast[ptr LogosModuleContext](heldModules[i].load),
            inv: cast[ptr LogosProviderInvocation](p),
            sum: heldSums[i].load,
          )
    sleep(1)
    inc waited

func parked*(p: Parked): bool =
  p.inv != nil

proc answerVault*(p: Parked) {.gcsafe.} =
  ## Completes the invocation with the kit's answer, reads its request again,
  ## then releases execution.
  var buf: ptr UncheckedArray[uint8] = nil
  var len: csize_t = 0
  let inv = p.inv
  let r = kitDispatch(
    p.module, inv.`method`, inv.paramsCbor, inv.paramsCborLen, addr buf, addr len
  )
  let o = cast[ptr Owned](allocShared0(sizeof(Owned)))
  o.module = p.module
  o.buf = buf
  let owner = LogosResponseOwner(state: o, release: releaseOwned)
  if r.code == 0:
    inv.complete(inv, r, buf, len, owner)
  else:
    inv.complete(inv, r, nil, 0, owner)
  if sumOf(inv.paramsCbor, inv.paramsCborLen) == p.sum:
    rereadIntact += 1
  else:
    rereadChanged += 1
  inv.executionRelease(inv)

var api = LogosAsyncProviderApi(
  abiVersion: AsyncProviderAbiVersion,
  structSize: csize_t(sizeof(LogosAsyncProviderApi)),
  submit: submit,
  requestCancel: requestCancel,
)

proc asyncApi(): ptr LogosAsyncProviderApi {.cdecl, gcsafe, raises: [].} =
  addr api

proc deferredVaultSymbols*(): seq[(string, pointer)] =
  ## The vault's table with a `_MODULE_async_api`.
  result = kit
  result.add(("logos_vault_module_MODULE_async_api", cast[pointer](asyncApi)))
