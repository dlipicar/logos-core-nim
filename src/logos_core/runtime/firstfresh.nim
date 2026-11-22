## The first delivery to each module callback on a new thread (DECISIONS G466,
## Fable's (d2)) [IMPL]. Test hooks only.
##
## A thread that once ran a library's code stays registered with that
## library's Nim runtime, so a callback that does not register its thread
## first (DECISIONS G464) fails only on a thread its library never saw: G339's
## completion did, on a worker a kit library had not run on before. Under test
## hooks the Runtime's and the Module Host's delivery workers hand the whole
## per-delivery function to a new thread the first time they meet a callback
## pointer, with no lock held, and join it; later deliveries run as before.
## The new thread is set up as the worker is (`setup`), so every thread-kind
## marker the handler's rules read is on it.
##
## Every hosted suite then delivers each module callback once on a thread that
## module's library never saw, and under orc without `useMalloc` a missing
## registration faults there. A module compiled into the Runtime's own image
## shares its Nim runtime, which registered the thread, so there it proves
## nothing; the probe (`logos_sdk/testing/freshthread`) covers that case.
## Events a direct route delivers on the publishing thread stay there
## (INTERFACE l.1961-1967). Outside test hooks `firstOnFreshThread` is the call
## itself, and the callers' key procedures (`...KeyForTests`) do not exist.

{.push raises: [], gcsafe.}

type
  HandoverFn* = proc(arg: pointer) {.nimcall, gcsafe, raises: [].}
    ## A per-delivery function and its one argument.
  ThreadSetup* = proc() {.nimcall, gcsafe, raises: [].}
    ## What the worker that hands over ran first on its own thread.

when defined(lcnTestHooks):
  import std/[atomics, locks, typedthreads]
  import logos_sdk/base/[perthread, testhooks]

  testHooksMarker("firstfresh")

  const SeenSlots = 4096
    ## distinct callbacks remembered; past that, deliveries run as before

  var
    seenLock: Lock
    seen: array[SeenSlots, pointer]
    handedOver: Atomic[int]
    onHandover {.threadvar.}: bool

  initLock(seenLock)

  proc firstTime(cb: pointer): bool =
    ## Whether `cb` is new, remembering it.
    if cb == nil:
      return false
    let start = int((cast[uint](cb) shr 3) mod SeenSlots)
    {.cast(gcsafe).}:
      withLock seenLock:
        var i = start
        while seen[i] != nil:
          if seen[i] == cb:
            return false
          i = (i + 1) mod SeenSlots
          if i == start:
            return false
        seen[i] = cb
    true

  type Handover = object
    fn: HandoverFn
    arg: pointer
    setup: ThreadSetup

  proc handoverMain(h: ptr Handover) {.thread.} =
    onHandover = true
    if h.setup != nil:
      h.setup()
    h.fn(h.arg)
    releasePerThread()

  proc handedOverForTests*(): int =
    ## Test hook: how many deliveries this process ran on a new thread.
    handedOver.load

  proc onHandoverThreadForTests*(): bool =
    ## Test hook: whether this thread is one a delivery was handed to.
    onHandover

  proc firstOnFreshThread*(
      cb: pointer, fn: HandoverFn, arg: pointer, setup: ThreadSetup
  ) =
    ## `fn(arg)`, on a new thread joined before this returns when `cb` is a
    ## callback this process has not delivered to before. The caller holds no
    ## lock. A thread that cannot start leaves the delivery here.
    if firstTime(cb):
      var h = Handover(fn: fn, arg: arg, setup: setup)
      var t: Thread[ptr Handover]
      try:
        createThread(t, handoverMain, addr h)
      except ResourceExhaustedError:
        fn(arg)
        return
      joinThread(t)
      discard handedOver.fetchAdd(1)
    else:
      fn(arg)

else:
  template firstOnFreshThread*(cb, fn, arg, setup: untyped) =
    ## The call itself: `cb` and `setup` are not evaluated.
    fn(arg)

{.pop.}
