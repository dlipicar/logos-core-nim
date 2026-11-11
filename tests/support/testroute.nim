## A route handle stand-in (INTERFACE §5.2) for the typed call helpers' tests
## (`tests/test_calls.nim`). In direct mode its `call` is a kit module's
## `_MODULE_dispatch` and its `release_response` that module's `_MODULE_free`,
## as a Runtime's direct binding does. The other modes break the route's side
## of the contract in one way each. Every route counts its calls and releases,
## checks that each release names the exact buffer and length it handed out,
## and overwrites a released buffer before freeing it.

import std/atomics
import ./kitruntime

export kitruntime

type
  RouteMode* = enum
    rmDirect ## dispatch into the module; release with its `_MODULE_free`
    rmGive ## LOGOS_OK with a copy of `response`
    rmOkNull ## LOGOS_OK without a buffer
    rmOkEmpty ## LOGOS_OK with a non-null (static) buffer of length zero
    rmOkMessage ## LOGOS_OK with a message, and a copy of `response`
    rmFailBuffer ## TIMEOUT that also hands out a copy of `response`
    rmFailure ## a valid failure: NOT_AUTHORISED, a message and no detail
    rmBadCode ## an unallocated code without a buffer

  RouteState* = object
    mode*: RouteMode
    module*: ptr LogosModuleContext
    dispatch*: DispatchFn
    free*: FreeFn
    response*: ptr UncheckedArray[uint8] ## for the modes that hand out bytes
    responseLen*: int
    record*: bool ## keep the last method name and params (one thread only)
    lastMethod*: array[64, char]
    lastParams*: array[4096, uint8]
    lastParamsLen*: int
    calls*, releases*, mismatches*: Atomic[int]
    given: ptr UncheckedArray[uint8]
    givenLen: csize_t

  TestRoute* = object
    handle*: LogosRouteHandle
    state*: RouteState

var emptyBuffer: array[1, uint8]

proc giveCopy(
    st: ptr RouteState, outBuf: ptr ptr UncheckedArray[uint8], outLen: ptr csize_t
) =
  let p = cast[ptr UncheckedArray[uint8]](allocShared(max(st.responseLen, 1)))
  for i in 0 ..< st.responseLen:
    p[i] = st.response[i]
  outBuf[] = p
  outLen[] = csize_t(st.responseLen)

proc routeCallOp(
    route: ptr LogosRouteHandle,
    `method`: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outBuf: ptr ptr UncheckedArray[uint8],
    outLen: ptr csize_t,
): LogosResult {.cdecl, gcsafe, raises: [].} =
  let st = cast[ptr RouteState](route.state)
  discard st.calls.fetchAdd(1)
  doAssert outBuf[] == nil and outLen[] == 0,
    "the caller did not initialize the outputs"
  if st.mode in {rmOkMessage, rmFailBuffer} and st.given != nil:
    deallocShared(st.given) # what the caller rightly did not release last time
    st.given = nil
  if st.record:
    let name = $`method`
    doAssert name.len < st.lastMethod.len
    for i, c in name:
      st.lastMethod[i] = c
    st.lastMethod[name.len] = '\0'
    if int(paramsLen) <= st.lastParams.len:
      for i in 0 ..< int(paramsLen):
        st.lastParams[i] = params[i]
      st.lastParamsLen = int(paramsLen)
    else:
      st.lastParamsLen = 0 # too long to keep
  case st.mode
  of rmDirect:
    result = st.dispatch(st.module, `method`, params, paramsLen, outBuf, outLen)
  of rmGive:
    giveCopy(st, outBuf, outLen)
  of rmOkNull:
    discard
  of rmOkEmpty:
    outBuf[] = cast[ptr UncheckedArray[uint8]](addr emptyBuffer)
  of rmOkMessage:
    giveCopy(st, outBuf, outLen)
    result.message = "fine"
  of rmFailBuffer:
    giveCopy(st, outBuf, outLen)
    result.code = CErrorCode(ord(ecTimeout))
  of rmFailure:
    result.code = CErrorCode(ord(ecNotAuthorised))
    result.message = "the route says no"
  of rmBadCode:
    result.code = CErrorCode(999)
  st.given = outBuf[]
  st.givenLen = outLen[]

proc routeReleaseOp(
    route: ptr LogosRouteHandle, buf: ptr UncheckedArray[uint8], len: csize_t
) {.cdecl, gcsafe, raises: [].} =
  let st = cast[ptr RouteState](route.state)
  discard st.releases.fetchAdd(1)
  if buf != st.given or len != st.givenLen or buf == nil:
    discard st.mismatches.fetchAdd(1)
    return
  for i in 0 ..< int(len):
    buf[i] = 0xEE # whatever still reads the buffer reads this (§2.7.2)
  if buf == cast[ptr UncheckedArray[uint8]](addr emptyBuffer):
    discard # rmOkEmpty's static buffer
  elif st.mode == rmDirect:
    st.free(st.module, buf)
  else:
    deallocShared(buf)
  st.given = nil
  st.givenLen = 0

var routeVtable = block:
  var v = armed(
    LogosRouteVtable(abiVersion: 2, structSize: csize_t(sizeof(LogosRouteVtable)))
  )
  v.call = routeCallOp
  v.releaseResponse = routeReleaseOp
  v

proc newRoute*(
    mode = rmDirect,
    module: ptr LogosModuleContext = nil,
    dispatch: DispatchFn = nil,
    free: FreeFn = nil,
    response: openArray[byte] = [],
    record = false,
): ptr TestRoute =
  ## A route on the shared heap, so that any thread may use it (one at a time,
  ## §2.8).
  result = createShared(TestRoute)
  result.handle = LogosRouteHandle(vtable: addr routeVtable, state: addr result.state)
  result.state.mode = mode
  result.state.module = module
  result.state.dispatch = dispatch
  result.state.free = free
  result.state.record = record
  if response.len > 0:
    result.state.response = cast[ptr UncheckedArray[uint8]](allocShared(response.len))
    for i, b in response:
      result.state.response[i] = b
    result.state.responseLen = response.len

proc outstanding*(r: ptr TestRoute): bool =
  ## A buffer handed out and not released.
  r.state.given != nil and
    r.state.given != cast[ptr UncheckedArray[uint8]](addr emptyBuffer)

proc dispose*(r: ptr TestRoute) =
  ## Frees the route and any buffer it handed out that was never released.
  if r.outstanding and r.state.mode != rmDirect:
    deallocShared(r.state.given)
  if r.state.response != nil:
    deallocShared(r.state.response)
  freeShared(r)

proc routeHandle*(r: ptr TestRoute): ptr LogosRouteHandle =
  addr r.handle

proc asModule*(r: ptr TestRoute): ptr LogosModuleContext =
  ## The route where the typed harness passes a module context
  ## (`tests/kit/calls_shims.c`).
  cast[ptr LogosModuleContext](addr r.handle)

proc lastMethod*(r: ptr TestRoute): string =
  $cast[cstring](addr r.state.lastMethod[0])

proc lastParams*(r: ptr TestRoute): seq[byte] =
  @(r.state.lastParams.toOpenArray(0, r.state.lastParamsLen - 1))

proc counts*(r: ptr TestRoute): (int, int, int) =
  ## (calls, releases, mismatched releases)
  (r.state.calls.load, r.state.releases.load, r.state.mismatches.load)
