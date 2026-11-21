## lcn_call's calls (Tier 5 step N-2; DECISIONS G348): Runtime Control through
## its own binding, and provider calls through a route handle. docs/DAEMON.md
## §7a.
##
## Every call is asynchronous (`prepare_call`, INTERFACE §2.9.1) with a
## deadline: a provider call the command's, a Runtime Control call at most
## `RcDeadlineMs`. The worker waits on a pipe the completion writes to and on
## the launcher's connection: the launcher's EOF cancels the call (G344's
## half-close). The completion copies the outcome into shared memory and
## releases the response owner at once, so no response buffer is held past
## the completion (IF l.3927). The error channel's code, message and detail are
## kept for the launcher.
##
## [G348; plan R5 §3.5 step 7] `prepare_call` on a route handle holds the
## handle's lock (IF l.1935: operations on one handle are serialized). A
## call's `submit`, `cancel` and `release` act on the call (IF l.2001,
## l.2038) and take no handle lock, so a completion that runs inline (IF
## l.2011) never meets one. Operations through the Runtime Control binding
## may run concurrently (IF l.1911): no lock.
##
## [G348; plan §3.5 step 8] `CallResult.prepared` says whether `prepare_call`
## succeeded: when it did not, nothing was submitted and the caller may
## retry on a new route; every later outcome comes through the completion
## (IF l.2009-2011).

{.push raises: [], gcsafe.}

import std/locks
import results
import logos_sdk/abi/[checks, types]
from logos_sdk/codegen/kitrt import callbackEnter
import logos_sdk/iface/outcome
import logos_sdk/kit/rc_types

export results, types, outcome, rc_types

when defined(posix):
  import std/posix except Stat

type
  Failure* = object ## The error channel's values, or a local failure.
    code*: ErrorCode
    message*: string
    detail*: Opt[seq[byte]]

  CallResult* = object ## A provider call's outcome.
    cancelled*: bool ## the launcher cancelled before the outcome
    prepared*: bool ## `prepare_call` succeeded, so the call was submitted
    case ok*: bool
    of true:
      response*: seq[byte]
    of false:
      failure*: Failure

func failure*(code: ErrorCode, message: string): Failure =
  Failure(code: code, message: message)

func failureOf*(f: AbiFailure): Failure =
  Failure(
    code: f.code,
    message: (if f.message.isSome: f.message.get else: f.reason),
    detail: f.detail,
  )

func `$`*(f: Failure): string =
  $f.code & (if f.message.len > 0: ": " & f.message else: "")

const RcDeadlineMs* = 60_000 ## [IMPL] one Runtime Control call, at most

func ptrOf(b: openArray[byte]): ptr UncheckedArray[uint8] =
  if b.len == 0:
    nil
  else:
    cast[ptr UncheckedArray[uint8]](unsafeAddr b[0])

# Provider calls ---------------------------------------------------------------------

type
  SharedBuf = object
    data: ptr UncheckedArray[byte]
    len: int

  CallSlot = object ## Shared between the waiting worker and the completion.
    lock: Lock
    done: bool
    code: ErrorCode
    response, message, detail: SharedBuf
    hasMessage, hasDetail: bool
    wakeW: cint ## the completion writes one byte here

proc shareRaw(p: pointer, len: int): SharedBuf =
  if len > 0 and p != nil:
    result.data = cast[ptr UncheckedArray[byte]](allocShared(len))
    copyMem(result.data, p, len)
    result.len = len

proc free(b: var SharedBuf) =
  if b.data != nil:
    deallocShared(b.data)
  b = SharedBuf()

proc bytesOf(b: SharedBuf): seq[byte] =
  result = newSeq[byte](b.len)
  if b.len > 0:
    copyMem(addr result[0], b.data, b.len)

proc textOf(b: SharedBuf): string =
  result = newString(b.len)
  if b.len > 0:
    copyMem(addr result[0], b.data, b.len)

proc onComplete(
    userData: pointer,
    status: LogosResult,
    response: ptr UncheckedArray[uint8],
    responseLen: csize_t,
    owner: LogosResponseOwner,
) {.cdecl, gcsafe, raises: [].} =
  ## [SPEC INTERFACE §2.9.1, §2.9.2] Copies the outcome into shared memory and
  ## releases the owner; it allocates nothing the collector owns. It runs on a
  ## Runtime or Module Host thread this library did not start, which registers
  ## with its Nim runtime first (`callbackEnter`, G339): under ORC a C thread
  ## has no allocator region until then, and `allocShared` crashed on one
  ## (N-2b's first run).
  callbackEnter()
  let slot = cast[ptr CallSlot](userData)
  var code = ecOk
  var resp, msg, det: SharedBuf
  var hasM, hasD = false
  let st = checkOutcome(status, completionShape(response, responseLen, owner))
  if st.isErr:
    code = st.error.code
    if st.error.message.isSome:
      let m = st.error.message.get
      msg = shareRaw(unsafeAddr m[0], m.len)
      hasM = m.len > 0
    if st.error.detail.isSome:
      let d = st.error.detail.get
      det = shareRaw(unsafeAddr d[0], d.len)
      hasD = d.len > 0
  elif response != nil and responseLen > 0:
    resp = shareRaw(response, int(responseLen))
  if ownerValid(owner) and owner.release != nil:
    owner.release(owner.state)
  withLock slot.lock:
    slot.code = code
    slot.response = resp
    slot.message = msg
    slot.detail = det
    slot.hasMessage = hasM
    slot.hasDetail = hasD
    slot.done = true
  when defined(posix):
    var one = 1'u8
    discard posix.write(slot.wakeW, addr one, 1)

template locked(lock: ptr Lock, body: untyped) =
  if lock.isNil:
    body
  else:
    withLock lock[]:
      body

proc callAsync[H](
    h: ptr H,
    lock: ptr Lock,
    bare: string,
    params: openArray[byte],
    deadlineMs: Opt[int],
    cancelFd: cint,
): CallResult =
  ## [SPEC INTERFACE §2.9.1] One call of `bare` through `h` (a route handle or
  ## the Runtime Control binding), waited for. Readable `cancelFd` (the
  ## launcher's EOF, or lcn_call closing) cancels it; the outcome is still
  ## waited for, then the call is released.
  when defined(posix):
    var pipeFds: array[0 .. 1, cint]
    if pipe(pipeFds) != 0:
      return
        CallResult(ok: false, failure: failure(ecModule, "pipe: " & $strerror(errno)))
    for f in pipeFds:
      discard fcntl(f, F_SETFD, FD_CLOEXEC)
    let slot = cast[ptr CallSlot](allocShared0(sizeof(CallSlot)))
    initLock(slot.lock)
    slot.wakeW = pipeFds[1]
    proc cleanup() =
      free(slot.response)
      free(slot.message)
      free(slot.detail)
      deinitLock(slot.lock)
      deallocShared(slot)
      discard posix.close(pipeFds[0])
      discard posix.close(pipeFds[1])

    var call = LogosAsyncCall()
    var options = LogosAsyncOptions(
      abiVersion: AsyncCallAbiVersion,
      structSize: csize_t(sizeof(LogosAsyncOptions)),
      hasTimeout: deadlineMs.isSome,
      timeoutMs: uint64(max(deadlineMs.get(0), 0)),
    )
    var callbacks = LogosAsyncCallbacks(
      abiVersion: AsyncCallAbiVersion,
      structSize: csize_t(sizeof(LogosAsyncCallbacks)),
      complete: onComplete,
      userData: slot,
    )
    var r: LogosResult
    locked(lock):
      r = h.vtable.prepareCall(
        h,
        cstring(bare),
        ptrOf(params),
        csize_t(params.len),
        addr options,
        addr callbacks,
        addr call,
      )
    let shaped = checkOutcome(r, handleShape(call.vtable, call.state))
    if shaped.isErr:
      if int64(r.code) == 0 and call.vtable != nil and call.state != nil and
          checkAsyncCall(addr call).isOk:
        call.vtable.release(addr call)
      cleanup()
      return CallResult(ok: false, failure: failureOf(shaped.error))
    let checked = checkAsyncCall(addr call)
    if checked.isErr:
      cleanup()
      return CallResult(ok: false, failure: failureOf(checked.error))
    call.vtable.submit(addr call)
    var cancelled = false
    while true:
      var done = false
      withLock slot.lock:
        done = slot.done
      if done:
        break
      var p: array[2, TPollfd]
      p[0] = TPollfd(fd: pipeFds[0], events: POLLIN)
      p[1] = TPollfd(fd: cancelFd, events: POLLIN)
      let watch = not cancelled and cancelFd >= 0
      let n = poll(addr p[0], Tnfds(if watch: 2 else: 1), -1)
      if n < 0 and errno != EINTR:
        break
      if watch and (p[1].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        call.vtable.cancel(addr call)
        cancelled = true
    call.vtable.release(addr call) # waits for a completion that is running
    if slot.code == ecOk:
      result = CallResult(ok: true, response: bytesOf(slot.response))
    else:
      var f = Failure(code: slot.code)
      if slot.hasMessage:
        f.message = textOf(slot.message)
      if slot.hasDetail:
        f.detail = Opt.some(bytesOf(slot.detail))
      result = CallResult(ok: false, failure: f)
    result.cancelled = cancelled
    result.prepared = true
    cleanup()
  else:
    CallResult(ok: false, failure: failure(ecModule, "not supported on this platform"))

proc callRoute*(
    route: ptr LogosRouteHandle,
    handleLock: ptr Lock,
    bare: string,
    params: openArray[byte],
    deadlineMs: Opt[int],
    cancelFd: cint,
): CallResult =
  ## The provider's method `bare` through `route`; `prepare_call` under the
  ## handle's lock.
  callAsync(route, handleLock, bare, params, deadlineMs, cancelFd)

# Runtime Control --------------------------------------------------------------------

proc rcBytes*(
    rc: ptr LogosRuntimeControlBinding,
    bare: string,
    params: openArray[byte],
    cancelFd: cint = -1,
): Result[seq[byte], Failure] =
  ## [SPEC INTERFACE §5.2] One Runtime Control call: the response's bytes. A
  ## cancelled call is CANCELLED.
  let r = callAsync(rc, nil, bare, params, Opt.some(RcDeadlineMs), cancelFd)
  if r.cancelled and not r.ok:
    return err(failure(ecCancelled, "the launcher cancelled"))
  if not r.ok:
    return err(r.failure)
  ok(r.response)

proc rcCall*[Req, Resp](
    rc: ptr LogosRuntimeControlBinding,
    bare: string,
    req: Req,
    resp: typedesc[Resp],
    cancelFd: cint = -1,
): Result[Resp, Failure] =
  ## One typed call; a response that does not decode is MODULE_ERROR.
  let params = encode(req).valueOr:
    return err(failure(ecInvalidParams, "the request has no encoding: " & error))
  let bytes = ?rcBytes(rc, bare, params, cancelFd)
  let r = Resp.decode(bytes)
  if r.isErr:
    return
      err(failure(ecModule, "the " & bare & " response does not decode: " & r.error))
  ok(r.get)

{.pop.}
