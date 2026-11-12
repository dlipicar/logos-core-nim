## A Runtime stand-in for the Capability Authority module (step 8a.2; DECISIONS
## I84): its exported C symbols, an init input, a publish callback and an
## invocation context that record what they get, and a caller, cancellation
## and route label set per thread. As `kitruntime.nim`, for the CA.

import std/[atomics, locks]
import results
import ../../src/logos_core/cbor
import ../../src/logos_core/abi/[checks, types]
import ../../src/logos_core/iface/outcome
import ../../src/logos_core/authority/provider
from ./kitruntime import rcBinding

export atomics, locks, results, checks, types, outcome, provider

# The CA's symbols ------------------------------------------------------------------------

proc symbol(name: string): pointer =
  for (n, p) in logosCapabilityAuthorityStaticSymbols():
    if n == name:
      return p
  doAssert false, "no symbol " & name

let
  caInit* = cast[ModuleInitFn](symbol("logos_logos_capability_authority_MODULE_init"))
  caDestroy* =
    cast[ModuleDestroyFn](symbol("logos_logos_capability_authority_MODULE_destroy"))
  caDispatch* =
    cast[ModuleDispatchFn](symbol("logos_logos_capability_authority_MODULE_dispatch"))
  caFree* = cast[ModuleFreeFn](symbol("logos_logos_capability_authority_MODULE_free"))

# Publications ------------------------------------------------------------------------

type Publication* = object
  event*: string
  payload*: seq[byte]
  scoped*: bool ## through the invocation context, not the publish callback
  label*: string ## the publishing thread's route label, for scoped ones

const
  MaxPublications = 64
  MaxEvent = 96
  MaxPayload = 8192
  MaxLabel = 64

type Slot = object
  ## One publication in plain memory: the CA thread and watch threads record
  ## them, and under refc no GC'd value may cross threads.
  event: array[MaxEvent, char]
  eventLen: int
  payload: array[MaxPayload, byte]
  payloadLen: int
  scoped: bool
  label: array[MaxLabel, char]
  labelLen: int

var
  publishedLock: Lock
  slots: array[MaxPublications, Slot]
  slotCount: int ## under `publishedLock`
initLock(publishedLock)

proc record(
    eventName: cstring,
    data: ptr UncheckedArray[uint8],
    len: csize_t,
    scoped: bool,
    label: openArray[char],
) =
  let n = int(len)
  let e = eventName.len
  doAssert n <= MaxPayload and e <= MaxEvent and label.len <= MaxLabel
  {.cast(gcsafe).}:
    withLock publishedLock:
      doAssert slotCount < MaxPublications, "too many publications recorded"
      let s = addr slots[slotCount]
      for i in 0 ..< e:
        s.event[i] = eventName[i]
      s.eventLen = e
      for i in 0 ..< n:
        s.payload[i] = data[i]
      s.payloadLen = n
      s.scoped = scoped
      for i in 0 ..< label.len:
        s.label[i] = label[i]
      s.labelLen = label.len
      inc slotCount

proc publications*(): seq[Publication] =
  ## What was published since `clearPublications`, copied onto this thread.
  {.cast(gcsafe).}:
    withLock publishedLock:
      for k in 0 ..< slotCount:
        let s = addr slots[k]
        var p = Publication(scoped: s.scoped)
        p.event = newString(s.eventLen)
        for i in 0 ..< s.eventLen:
          p.event[i] = s.event[i]
        p.payload = newSeq[byte](s.payloadLen)
        for i in 0 ..< s.payloadLen:
          p.payload[i] = s.payload[i]
        p.label = newString(s.labelLen)
        for i in 0 ..< s.labelLen:
          p.label[i] = s.label[i]
        result.add p

proc clearPublications*() =
  {.cast(gcsafe).}:
    withLock publishedLock:
      slotCount = 0

var publishState: byte

proc publishOp(
    userData: pointer,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
) {.cdecl, gcsafe, raises: [].} =
  doAssert userData == addr publishState
  record(eventName, cborData, cborDataLen, false, [])

# The invocation context ---------------------------------------------------------------

type ScopedHook* = proc() {.nimcall, gcsafe, raises: [].}
  ## Runs inside each scoped publication, on the publishing thread.

var
  callerSystem {.threadvar.}: bool
  callerRuntime {.threadvar.}: string
  callerInstance {.threadvar.}: string
  routeLabel {.threadvar.}: string
  cancelFlag {.threadvar.}: ptr Atomic[bool]
  onScoped {.threadvar.}: ScopedHook
  activeContext {.threadvar.}: ptr LogosInvocationContext

proc callerOp(
    invocation: ptr LogosInvocationContext, outCaller: ptr LogosCallerView
): LogosResult {.cdecl, gcsafe, raises: [].} =
  outCaller[] = LogosCallerView(
    kind: (if callerSystem: CallerSystemService else: CallerModule),
    runtimeInstanceId: LogosUtf8View(
      data: cast[ptr UncheckedArray[uint8]](cstring(callerRuntime)),
      len: csize_t(callerRuntime.len),
    ),
  )
  if not callerSystem:
    outCaller.moduleInstanceId = LogosUtf8View(
      data: cast[ptr UncheckedArray[uint8]](cstring(callerInstance)),
      len: csize_t(callerInstance.len),
    )
  LogosResult()

proc cancelledOp(
    invocation: ptr LogosInvocationContext
): bool {.cdecl, gcsafe, raises: [].} =
  cancelFlag != nil and cancelFlag[].load

proc scopedPublishOp(
    invocation: ptr LogosInvocationContext,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  record(eventName, cborData, cborDataLen, true, routeLabel)
  if onScoped != nil:
    onScoped()
  LogosResult()

var
  contextVtable = LogosInvocationContextVtable(
    abiVersion: 1,
    structSize: csize_t(sizeof(LogosInvocationContextVtable)),
    caller: callerOp,
    isCancelled: cancelledOp,
    publish: scopedPublishOp,
  )
  contextState: byte
  theContext =
    LogosInvocationContext(vtable: addr contextVtable, state: addr contextState)

proc currentOp(
    state: pointer
): ptr LogosInvocationContext {.cdecl, gcsafe, raises: [].} =
  activeContext

var accessState: byte

proc actAs*(
    instance: string,
    runtime = "rt-1",
    system = false,
    label = "",
    cancel: ptr Atomic[bool] = nil,
    scoped: ScopedHook = nil,
) =
  ## Makes this thread's calls come from `instance` (or the system service),
  ## through a route labelled `label`, cancelled when `cancel` is set.
  callerSystem = system
  callerRuntime = runtime
  callerInstance = instance
  routeLabel = label
  cancelFlag = cancel
  onScoped = scoped
  activeContext = addr theContext

# Instances and calls ------------------------------------------------------------------

proc newCa*(
    stateDir: string, publish = true
): Result[ptr LogosModuleContext, AbiFailure] =
  ## A CA instance on `stateDir`, as a Runtime initializes one.
  var i = LogosModuleInitInput(
    abiVersion: ModuleInitAbiVersion,
    structSize: csize_t(sizeof(LogosModuleInitInput)),
    runtimeControl: addr rcBinding, # every operation a stub the CA must not call
    publishUserData: addr publishState,
    publish: (if publish: publishOp else: nil),
    stateDir: (if stateDir.len > 0: cstring(stateDir) else: nil),
    invocationAccess: LogosInvocationAccess(state: addr accessState, current: currentOp),
  )
  var ctx: ptr LogosModuleContext = nil
  let r = caInit(addr i, addr ctx)
  let c = checkOutcome(r, contextShape(ctx))
  if c.isErr:
    return err(c.error)
  ok(ctx)

proc callCa*(
    ctx: ptr LogosModuleContext, bare: string, params: openArray[byte]
): seq[byte] {.gcsafe.} =
  ## One dispatch from this thread's caller; the response bytes. A failed
  ## dispatch is a test failure: the CA answers every request in band.
  var outBuf: ptr UncheckedArray[uint8] = nil
  var outLen: csize_t = 0
  let p =
    if params.len == 0:
      nil
    else:
      cast[ptr UncheckedArray[uint8]](unsafeAddr params[0])
  let r =
    caDispatch(ctx, cstring(bare), p, csize_t(params.len), addr outBuf, addr outLen)
  doAssert checkOutcome(r, bufferShape(outBuf, outLen)).isOk, "the dispatch failed"
  result = newSeq[byte](int(outLen))
  for i in 0 ..< int(outLen):
    result[i] = outBuf[i]
  caFree(ctx, outBuf)
