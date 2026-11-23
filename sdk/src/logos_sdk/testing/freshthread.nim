## Fresh threads for tests (DECISIONS G464-G467) [IMPL]: each call runs on a
## new C thread that no Nim runtime started, so it has never run this
## library's code, and reports whether the call registered that thread
## (`threadEntered`, read on it once the call returned).
##
## - A procedure marked `{.lcnCallback.}` leaves the probe true; an unmarked
##   one false, and under orc without `useMalloc` its first allocation
##   faults, as G339's completion did (DECISIONS I77 (7)). Run such a call in a
##   child process: `defaultSignals` first there, so it dies by the fault.
## - A procedure exempt with `{.lcnNoNimHeap.}` leaves it false and must not
##   fault: it takes a fresh thread to check the exemption's words.
## - Under refc a missing registration faults only if a collection runs on
##   that thread, so there the probe is the only detector.
##
## The probe is this image's: the procedure must be compiled into the program
## that calls these (a kit library's export list holds no probe). The typed
## helpers deliver as a binding does; `onFreshThread` runs anything else.
## POSIX only.

{.push raises: [], gcsafe.}

import ../abi/types
import ../base/entry

when not defined(posix):
  {.error: "logos_sdk/testing/freshthread needs POSIX threads".}

{.compile: "freshthread.c".}

type FreshFn* = proc(arg: pointer) {.cdecl, gcsafe, raises: [].}
  ## What runs on the fresh thread.

type ProbeFn = proc(): cint {.cdecl, gcsafe, raises: [].}

proc lcnFreshRun(
  fn: FreshFn, arg: pointer, probe: ProbeFn, entered: ptr cint
): cint {.importc: "lcn_fresh_run", cdecl.}

proc defaultSignals*() {.importc: "lcn_fresh_default_signals", cdecl.}
  ## In a child process that must die by a fault or an abort: SIGSEGV, SIGBUS
  ## and SIGABRT back to their default actions, so Nim's handler, which
  ## allocates on that thread and hangs there (upstream drafts 12 and 190),
  ## never runs.

proc probeEntered(): cint {.cdecl, lcnNoNimHeap: "reads a thread variable".} =
  cint(threadEntered())

proc onFreshThread*(fn: FreshFn, arg: pointer): bool =
  ## Runs `fn(arg)` on a new thread and joins it: whether `fn` registered that
  ## thread. A thread that cannot start or be joined is a failed assertion.
  var entered: cint = -1
  let rc = lcnFreshRun(fn, arg, probeEntered, addr entered)
  doAssert rc == 0, "freshthread: the thread did not start or join"
  doAssert entered in [0, 1]
  entered == 1

type
  EventArgs = object
    fn: LogosEventHandler
    name: cstring
    data: ptr UncheckedArray[uint8]
    len: csize_t
    userData: pointer

  RouteEndArgs = object
    fn: LogosRouteEndHandler
    reason: CErrorCode
    userData: pointer

  SubEndArgs = object
    fn: LogosSubscriptionEndHandler
    id: LogosSubscriptionId
    reason: CErrorCode
    userData: pointer

  CompletionArgs = object
    fn: LogosAsyncCompleteFn
    userData: pointer
    status: LogosResult
    data: ptr UncheckedArray[uint8]
    len: csize_t
    owner: LogosResponseOwner

func view(data: openArray[byte]): ptr UncheckedArray[uint8] =
  if data.len > 0:
    cast[ptr UncheckedArray[uint8]](unsafeAddr data[0])
  else:
    nil

proc runEvent(arg: pointer) {.cdecl, lcnNoNimHeap: "unpacks its arguments".} =
  let a = cast[ptr EventArgs](arg)
  a.fn(a.name, a.data, a.len, a.userData)

proc runRouteEnd(arg: pointer) {.cdecl, lcnNoNimHeap: "unpacks its arguments".} =
  let a = cast[ptr RouteEndArgs](arg)
  a.fn(a.reason, a.userData)

proc runSubEnd(arg: pointer) {.cdecl, lcnNoNimHeap: "unpacks its arguments".} =
  let a = cast[ptr SubEndArgs](arg)
  a.fn(a.id, a.reason, a.userData)

proc runCompletion(arg: pointer) {.cdecl, lcnNoNimHeap: "unpacks its arguments".} =
  let a = cast[ptr CompletionArgs](arg)
  a.fn(a.userData, a.status, a.data, a.len, a.owner)

proc runRelease(arg: pointer) {.cdecl, lcnNoNimHeap: "unpacks its arguments".} =
  let o = cast[ptr LogosResponseOwner](arg)
  o.release(o.state)

proc freshEvent*(
    fn: LogosEventHandler, name: cstring, data: openArray[byte], userData: pointer
): bool =
  ## An event delivered to `fn` on a fresh thread, as a binding delivers one
  ## (INTERFACE §2.5): whether `fn` registered it.
  var a = EventArgs(
    fn: fn, name: name, data: view(data), len: csize_t(data.len), userData: userData
  )
  onFreshThread(runEvent, addr a)

proc freshRouteEnd*(
    fn: LogosRouteEndHandler, reason: CErrorCode, userData: pointer
): bool =
  ## A route's end report on a fresh thread (INTERFACE §2.8).
  var a = RouteEndArgs(fn: fn, reason: reason, userData: userData)
  onFreshThread(runRouteEnd, addr a)

proc freshSubscriptionEnd*(
    fn: LogosSubscriptionEndHandler,
    id: LogosSubscriptionId,
    reason: CErrorCode,
    userData: pointer,
): bool =
  ## A subscription's end report on a fresh thread (INTERFACE l.1474-1481).
  var a = SubEndArgs(fn: fn, id: id, reason: reason, userData: userData)
  onFreshThread(runSubEnd, addr a)

proc freshCompletion*(
    fn: LogosAsyncCompleteFn,
    userData: pointer,
    status: LogosResult,
    response: openArray[byte],
    owner: LogosResponseOwner,
): bool =
  ## An asynchronous call's completion on a fresh thread (INTERFACE §2.9.1),
  ## as the Runtime's lifecycle workers deliver one.
  var a = CompletionArgs(
    fn: fn,
    userData: userData,
    status: status,
    data: view(response),
    len: csize_t(response.len),
    owner: owner,
  )
  onFreshThread(runCompletion, addr a)

proc freshRelease*(owner: LogosResponseOwner): bool =
  ## A response owner's release on a fresh thread (INTERFACE §2.7.1): any
  ## thread may release.
  doAssert not owner.release.isNil
  var o = owner
  onFreshThread(runRelease, addr o)

{.pop.}
