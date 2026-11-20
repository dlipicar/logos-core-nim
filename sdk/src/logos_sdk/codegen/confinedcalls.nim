## `invokeAsync` [IMPL] (DECISIONS G338): a typed call through a route handle
## as a chronos future, for a thread-confined kit's module thread. The
## generated `prepareInvoke` of the request's method (App A.5, `callsgen`)
## prepares the call with a completion that completes the future; the call is
## submitted at once and released once the future has completed, never from
## its own completion (INTERFACE l.2043).
##
## The handle must be one the kit wrapped (`wrapRoute` with the context's
## dispatcher, G339), used on its module thread: its completion then runs
## there as a task, where the future may be completed. Any other use answers
## NOT_READY at once.
##
## Cancelling the future (an `async` handler's cancellation reaching the
## future it awaits) asks the call's cancellation (INTERFACE §2.9.1); the
## future then completes with the call's outcome, CANCELLED or whatever
## arrived first.

{.push raises: [], gcsafe.}

import results
import chronos/asyncloop
import ../iface/outcome
import ./[confinedrt, consumert]

type
  InvokeFuture*[R] = Future[Result[R, InvocationFailure]].Raising([])
    ## What `invokeAsync` returns for a method whose response type is `R`.

  InvokeState[R] = ref object
    fut: InvokeFuture[R]
    call: PreparedCall

proc releaseLater[R](arg: pointer) {.gcsafe, raises: [].} =
  let s = cast[InvokeState[R]](arg)
  discard s.call.release()
  GC_unref(s)

proc onInvokeDone[R](
    outcome: Result[R, InvocationFailure], user: pointer
) {.nimcall, gcsafe, raises: [].} =
  ## The call's one completion, on the module thread.
  let s {.cursor.} = cast[InvokeState[R]](user)
  if not s.fut.finished():
    s.fut.complete(outcome)
  # [SPEC INTERFACE l.2043] Released once its completion has returned.
  callSoon(releaseLater[R], user)

proc invokeAsync*[Q](h: RouteHandle, request: Q, timeoutMs = 0'u64): auto =
  ## [DECISIONS G338] The method of `request`'s type through `h`, as a future
  ## of its outcome; a nonzero `timeoutMs` is the call's deadline (TIMEOUT).
  ## On the module thread of the kit that wrapped `h`.
  mixin prepareInvoke, invoke
  type R = typeof(invoke(h, request).unsafeGet)
  let fut = InvokeFuture[R].init("invokeAsync", {FutureFlag.OwnCancelSchedule})
  if h.isNil or not h.dispatcher.onItsModuleThread:
    fut.complete(
      Result[R, InvocationFailure].err(
        failure(
          ecNotReady,
          "invokeAsync runs on a confined kit's module thread, through a handle the kit wrapped",
        )
      )
    )
    return fut
  let s = InvokeState[R](fut: fut)
  GC_ref(s)
  let c = prepareInvoke(h, request, onInvokeDone[R], cast[pointer](s), timeoutMs)
  if c.isErr:
    GC_unref(s)
    fut.complete(Result[R, InvocationFailure].err(c.unsafeError))
    return fut
  s.call = c.unsafeGet
  fut.cancelCallback = proc(arg: pointer) {.gcsafe, raises: [].} =
    # [SPEC INTERFACE §2.9.1] The completion still comes, and completes it.
    s.call.cancel()
  s.call.submit()
  fut

{.pop.}
