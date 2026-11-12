## A deferred provider for `meter_module` (INTERFACE §2.9.2): the meter kit
## module's symbols plus `_MODULE_async_api`, whose `submit` answers with the
## kit's own `_MODULE_dispatch`. In `dmInline` it completes and releases
## inside `submit`; in `dmHold` it parks the invocation for the test, which
## completes it from its own thread (`settle`). `request_cancel` is counted,
## and can be held at a gate or settle the invocation as CANCELLED.
##
## Its `_MODULE_init` keeps the invocation access of the initialization input,
## so `submit` and `request_cancel` can check that `current` returns the
## context the invocation carries (INTERFACE l.2166-2167).

{.used.}
import std/[atomics, os]
import ../../src/logos_core/abi/types
import ../../src/logos_core/iface/outcome
import ./meter_impl

type DeferredMode* = enum
  dmInline ## complete and release inside `submit`
  dmHold ## park the invocation for `settle`

const MaxHeld = 64

var
  mode*: Atomic[int] ## a `DeferredMode`
  submits*, hooks*, ownerReleases*: Atomic[int]
  submitSawContext*, hookSawContext*: Atomic[int] ## `current` was the invocation's
  hookGate*: Atomic[bool] ## `request_cancel` waits while it is true
  inHook*: Atomic[int]
  settleOnCancel*: Atomic[bool] ## `request_cancel` completes CANCELLED and releases
  held: array[MaxHeld, Atomic[pointer]]
  modules: array[MaxHeld, Atomic[pointer]]
  accessState: Atomic[pointer]
  accessCurrent: Atomic[pointer]
  publishFn, publishData: Atomic[pointer] ## the latest initialization's
  publishes*: Atomic[int] ## initializations given a non-null publish callback

let kit = meterModuleStaticSymbols()

proc symbol(suffix: string): pointer =
  for (name, p) in kit:
    if name == "logos_meter_module_MODULE_" & suffix:
      return p
  nil

let
  kitInit = cast[ModuleInitFn](symbol("init"))
  kitDispatch = cast[ModuleDispatchFn](symbol("dispatch"))
  kitFree = cast[ModuleFreeFn](symbol("free"))

proc resetDeferred*() =
  mode.store(ord(dmInline))
  submits.store(0)
  hooks.store(0)
  ownerReleases.store(0)
  publishes.store(0)
  submitSawContext.store(0)
  hookSawContext.store(0)
  hookGate.store(false)
  settleOnCancel.store(false)
  for i in 0 ..< MaxHeld:
    held[i].store(nil)
    modules[i].store(nil)

proc current(): ptr LogosInvocationContext =
  let f = cast[proc(state: pointer): ptr LogosInvocationContext {.
    cdecl, gcsafe, raises: []
  .}](accessCurrent.load)
  if f.isNil:
    nil
  else:
    f(accessState.load)

# The response owner: the kit's buffer, freed with its `_MODULE_free`.

type Owned = object
  module: ptr LogosModuleContext
  buf: ptr UncheckedArray[uint8]

proc releaseOwned(state: pointer) {.cdecl, gcsafe, raises: [].} =
  let o = cast[ptr Owned](state)
  if o.buf != nil:
    kitFree(o.module, o.buf)
  deallocShared(o)
  ownerReleases += 1

proc settle*(
    module: ptr LogosModuleContext,
    inv: ptr LogosProviderInvocation,
    release = true,
    invalid = false,
) {.gcsafe.} =
  ## Completes `inv` with the kit's answer (with `invalid`: LOGOS_OK and no
  ## response, which breaks §2.9.2), then releases execution.
  var buf: ptr UncheckedArray[uint8] = nil
  var len: csize_t = 0
  let r = kitDispatch(
    module, inv.`method`, inv.paramsCbor, inv.paramsCborLen, addr buf, addr len
  )
  let o = cast[ptr Owned](allocShared0(sizeof(Owned)))
  o.module = module
  o.buf = buf
  let owner = LogosResponseOwner(state: o, release: releaseOwned)
  if invalid:
    inv.complete(inv, LogosResult(), nil, 0, owner)
  elif r.code == 0:
    inv.complete(inv, r, buf, len, owner)
  else:
    inv.complete(inv, r, nil, 0, owner)
  if release:
    inv.executionRelease(inv)

proc submit(
    module: ptr LogosModuleContext, inv: ptr LogosProviderInvocation
) {.cdecl, gcsafe, raises: [].} =
  submits += 1
  if current() == inv.context:
    submitSawContext += 1
  if DeferredMode(mode.load) == dmInline:
    settle(module, inv)
    return
  for i in 0 ..< MaxHeld:
    var expected: pointer = nil
    if held[i].compareExchange(expected, inv):
      modules[i].store(module)
      return
  doAssert false, "too many held invocations"

proc requestCancel(
    module: ptr LogosModuleContext, inv: ptr LogosProviderInvocation
) {.cdecl, gcsafe, raises: [].} =
  hooks += 1
  inHook += 1
  if current() == inv.context:
    hookSawContext += 1
  while hookGate.load:
    sleep(1)
  if settleOnCancel.load:
    for i in 0 ..< MaxHeld:
      if held[i].load == inv:
        held[i].store(nil)
        modules[i].store(nil)
    inv.complete(
      inv,
      LogosResult(code: CErrorCode(ord(ecCancelled)), message: "cancelled"),
      nil,
      0,
      LogosResponseOwner(),
    )
    inv.executionRelease(inv)
  inHook -= 1

proc takeHeld*(
    seconds = 10
): (ptr LogosModuleContext, ptr LogosProviderInvocation) {.gcsafe.} =
  ## The oldest parked invocation, once there is one.
  var waited = 0
  while waited < seconds * 1000:
    for i in 0 ..< MaxHeld:
      let p = held[i].load
      if p != nil:
        var expected = p
        if held[i].compareExchange(expected, nil):
          return (
            cast[ptr LogosModuleContext](modules[i].load),
            cast[ptr LogosProviderInvocation](p),
          )
    sleep(1)
    inc waited
  (nil, nil)

proc heldCount*(): int =
  for i in 0 ..< MaxHeld:
    if held[i].load != nil:
      inc result

var api = LogosAsyncProviderApi(
  abiVersion: AsyncProviderAbiVersion,
  structSize: csize_t(sizeof(LogosAsyncProviderApi)),
  submit: submit,
  requestCancel: requestCancel,
)

proc asyncApi(): ptr LogosAsyncProviderApi {.cdecl, gcsafe, raises: [].} =
  addr api

proc init(
    input: ptr LogosModuleInitInput, outContext: ptr ptr LogosModuleContext
): LogosResult {.cdecl, gcsafe, raises: [].} =
  accessState.store(input.invocationAccess.state)
  accessCurrent.store(cast[pointer](input.invocationAccess.current))
  publishFn.store(cast[pointer](input.publish))
  publishData.store(input.publishUserData)
  if not input.publish.isNil:
    publishes += 1
  kitInit(input, outContext)

proc publishRaw*(name: cstring, payload: openArray[byte]) =
  ## The module's own publish callback, as its code would call it.
  let f = cast[LogosPublishFn](publishFn.load)
  f(
    publishData.load,
    name,
    (
      if payload.len == 0: nil
      else: cast[ptr UncheckedArray[uint8]](unsafeAddr payload[0])
    ),
    csize_t(payload.len),
  )

proc deferredMeterSymbols*(): seq[(string, pointer)] =
  ## The meter's table with this `_MODULE_init` and a `_MODULE_async_api`.
  for (name, p) in kit:
    if name == "logos_meter_module_MODULE_init":
      result.add((name, cast[pointer](init)))
    else:
      result.add((name, p))
  result.add(("logos_meter_module_MODULE_async_api", cast[pointer](asyncApi)))
