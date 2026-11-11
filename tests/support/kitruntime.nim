## A Runtime stand-in for tests that call kit modules through their exported C
## symbols (`tests/test_kit.nim` in process, `tests/test_kit_dylib.nim` through
## `dlopen`): a Runtime Control binding whose operations must not be called, a
## publish callback and an invocation context that record what they get, and
## a dispatch caller that checks results the way an ABI caller does.

import std/[atomics, locks]
import results
import ../../src/logos_core/cbor
import ../../src/logos_core/abi/[checks, types]
import ../../src/logos_core/iface/outcome

export atomics, locks, results, checks, types, outcome

# A Runtime stand-in -------------------------------------------------------------------

proc unusedOp*() {.cdecl.} =
  doAssert false, "the kit called a Runtime Control operation it does not use"

let unusedAddr* = cast[pointer](unusedOp)
  ## Through a runtime pointer: a direct proc-to-proc cast reaches the C
  ## compiler as an incompatible function-pointer assignment (as in test_abi).

proc procOnly*[P: proc](p: P) =
  discard

proc armed*[T](v: T): T =
  ## `v` with every operation set to a stub the kit must not call.
  result = v
  for f in fields(result):
    when compiles(procOnly(f)):
      f = cast[typeof(f)](unusedAddr)

var
  rcVtable* = armed(
    LogosRuntimeControlVtable(
      abiVersion: 2, structSize: csize_t(sizeof(LogosRuntimeControlVtable))
    )
  )
  rcState*: byte
  rcBinding* = LogosRuntimeControlBinding(vtable: addr rcVtable, state: addr rcState)

var
  publishedLock*: Lock
  published*: seq[(string, seq[byte], string)] ## event, payload, "plain" or "scoped"
initLock(publishedLock)

proc record*(
    name: cstring, data: ptr UncheckedArray[uint8], len: csize_t, how: string
) =
  var bytes = newSeq[byte](int(len))
  for i in 0 ..< int(len):
    bytes[i] = data[i]
  {.cast(gcsafe).}:
    withLock publishedLock:
      published.add(($name, bytes, how))

var publishState*: byte

proc publishOp*(
    userData: pointer,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
) {.cdecl, gcsafe, raises: [].} =
  doAssert userData == addr publishState
  record(eventName, cborData, cborDataLen, "plain")

# The invocation context a Runtime makes current during a provider entry (§2.9.3).

const
  runtimeId* = "runtime-a"
  consumerId* = "consumer-7"

var cancelled*: Atomic[bool]

proc callerOp*(
    invocation: ptr LogosInvocationContext, outCaller: ptr LogosCallerView
): LogosResult {.cdecl, gcsafe, raises: [].} =
  outCaller[] = LogosCallerView(
    kind: CallerModule,
    runtimeInstanceId: LogosUtf8View(
      data: cast[ptr UncheckedArray[uint8]](cstring(runtimeId)),
      len: csize_t(runtimeId.len),
    ),
    moduleInstanceId: LogosUtf8View(
      data: cast[ptr UncheckedArray[uint8]](cstring(consumerId)),
      len: csize_t(consumerId.len),
    ),
  )
  LogosResult()

proc cancelledOp*(
    invocation: ptr LogosInvocationContext
): bool {.cdecl, gcsafe, raises: [].} =
  cancelled.load

proc scopedPublishOp*(
    invocation: ptr LogosInvocationContext,
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  record(eventName, cborData, cborDataLen, "scoped")
  LogosResult()

var
  contextVtable* = LogosInvocationContextVtable(
    abiVersion: 1,
    structSize: csize_t(sizeof(LogosInvocationContextVtable)),
    caller: callerOp,
    isCancelled: cancelledOp,
    publish: scopedPublishOp,
  )
  contextState*: byte
  activeContext* {.threadvar.}: ptr LogosInvocationContext
    ## what `current` returns on this thread: set around a provider entry

proc currentOp*(
    state: pointer
): ptr LogosInvocationContext {.cdecl, gcsafe, raises: [].} =
  activeContext

var accessState*: byte

proc input*(
    publish = true, stateDir: cstring = nil, configuration: seq[byte] = @[]
): LogosModuleInitInput =
  ## An init input that borrows `stateDir` and the bytes of `configuration`:
  ## both must outlive the `_MODULE_init` call.
  result = LogosModuleInitInput(
    abiVersion: ModuleInitAbiVersion,
    structSize: csize_t(sizeof(LogosModuleInitInput)),
    runtimeControl: addr rcBinding,
    publishUserData: addr publishState,
    publish: (if publish: publishOp else: nil),
    stateDir: stateDir,
    invocationAccess: LogosInvocationAccess(state: addr accessState, current: currentOp),
  )
  if configuration.len > 0:
    result.configurationCbor =
      cast[ptr UncheckedArray[uint8]](unsafeAddr configuration[0])
    result.configurationCborLen = csize_t(configuration.len)

# Calling helpers ------------------------------------------------------------------------

type Call* = object
  status*: AbiCheck ## as the ABI caller reads the result and outputs
  response*: seq[byte]

type
  DispatchFn* = ModuleDispatchFn
  FreeFn* = ModuleFreeFn

proc call*(
    dispatch: DispatchFn,
    free: FreeFn,
    ctx: ptr LogosModuleContext,
    bare: string,
    params: openArray[byte],
): Call {.gcsafe.} =
  ## One dispatch as an ABI caller makes it (§2.6): outputs set to null and
  ## zero first, the result and outputs checked together, the response copied
  ## and released with the same instance's `_MODULE_free`.
  var outBuf: ptr UncheckedArray[uint8] = nil
  var outLen: csize_t = 0
  let p =
    if params.len == 0:
      nil
    else:
      cast[ptr UncheckedArray[uint8]](unsafeAddr params[0])
  let r = dispatch(ctx, cstring(bare), p, csize_t(params.len), addr outBuf, addr outLen)
  result.status = checkOutcome(r, bufferShape(outBuf, outLen))
  if r.code == 0 and outBuf != nil:
    result.response = newSeq[byte](int(outLen))
    for i in 0 ..< int(outLen):
      result.response[i] = outBuf[i]
    free(ctx, outBuf)

proc code*(c: Call): ErrorCode =
  if c.status.isOk: ecOk else: c.status.error.code

proc diag*(s: string): seq[byte] =
  encodeCbor(parseDiag(s).get)
