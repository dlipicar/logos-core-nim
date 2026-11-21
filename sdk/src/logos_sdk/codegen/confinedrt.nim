## Runtime support for lcn-gen's thread-confined module kits [IMPL]
## (DECISIONS G335, G336, G337): `lcn-gen kit --confined` generates a kit whose
## entries hand their work to one module thread per context, which runs a
## chronos dispatcher. Generated files reach this module through the
## `logos_sdk/confined` facade.
##
## **The module thread** (G335). `_MODULE_init` creates the context, starts its
## module thread and its publisher thread, and runs the author's `initModule`
## on the module thread; the instance is allocated, used and released there
## only, so under refc handlers may store GC'd values in it. Two contexts never
## share a thread.
##
## **The handoff.** `_MODULE_init`, `_MODULE_destroy`, `_MODULE_dispatch`,
## `_MODULE_apply_configuration` and the typed `_CALL_` functions build a job
## on the calling thread's stack (its arguments are the caller's, borrowed
## while it waits), queue it under the context's lock and wake the module
## thread through a `ThreadSignalPtr`; the calling thread waits on the job's
## own condition. No GC'd value crosses threads: the module thread writes the
## outcome into the job's fixed storage, and the calling thread builds the
## `logos_result_t` from it with `failureResult`, on its own thread (INTERFACE
## §2.7). `_MODULE_name`, `_MODULE_call_surface` and `_MODULE_free` touch no
## instance state and stay on the calling thread.
##
## **Tasks.** The module thread starts one chronos task per job, so an
## `async` handler that awaits lets it serve the next job; a plain handler runs
## to completion inside its task.
##
## **Re-entry** (G337). An entry called on the module thread itself (a direct
## subscriber re-entering, a direct route cycle) runs inline: its task starts
## at once and the thread polls its dispatcher until the job is done. chronos
## tolerates the nested `poll` unless built with `chronosStrictReentrancy`, so
## this module refuses to compile under it.
##
## **Serving waits (P3).** A plain handler's `publishScoped` hands the
## publication to the entry thread that waits for its job (it holds the
## provider entry); while it waits the module thread polls its dispatcher, so
## a job that arrives meanwhile (a direct subscriber re-entering from the
## entry thread) runs.
##
## **The invocation context** (G336). The entry captures the Runtime's
## `current` on its own thread before it hands off; the module thread acts for
## that job only. A plain handler reaches it through the kit's *confined
## scope* (`kitrt`), set only while the handler runs and cleared around every
## nested poll; an `async` handler takes an `Invocation` as its third
## parameter, which refuses use (NOT_READY) once its job has ended. Before a
## job's entry returns, every publication it made in its invocation's scope
## has been answered.
##
## **Publication** (G337). `publish` checks the event, copies it into C
## memory and queues it for the context's publisher thread, which calls the
## instance's publish callback in order; it returns the kit's check, or the
## kit's own NOT_READY when the queue is full (64 events or 1 MiB [IMPL]).
## The callback's refusals are counted (`publishRefusals`,
## `lastPublishRefusal`). `publishAsync` returns a future of the callback's
## result and waits for room. An async handler's `publishScoped` goes through
## the publisher thread with its invocation's context.
##
## **Foreign threads.** `post` hands a C callback and its payload to the
## module thread from any thread, one the Nim runtime has never seen
## included; it uses only the C allocator and writes the signal's descriptor
## directly. C code linked into the module library calls it as
## `lcn_kit_post`.
##
## **Consumer callbacks** (G339). The context's dispatcher (`withConfined`,
## `ModuleServices.dispatcher`) lets the consumer helpers (`consumert`) queue
## task nodes for the module thread: a copied delivery, counted against the
## context's bound (1024 events [IMPL], `setDeliveryBound`), and end reports
## and completions in storage their owners reserved, which are never refused.
## The module thread runs them in order between jobs; a task queued once the
## instance is gone is dropped, freeing what it holds.
##
## **Destroy** (INTERFACE l.1949-1962). The author's `destroyModule` and the
## instance's release run on the module thread; then the publisher thread
## delivers what was queued and exits; then the module thread answers what is
## left with NOT_READY, closes its signal and tears down its dispatcher; both
## threads are joined and the context freed before `_MODULE_destroy` returns.
## A failed initialization joins both threads the same way, dropping the
## queued events.
##
## **Deferred provider** (DECISIONS G338). With `lcn-gen kit --confined
## --async-api` the kit exports `_MODULE_async_api` (INTERFACE §2.9.2). Its
## `submit` copies nothing: it queues a job in C memory for the module thread
## and returns at once; the job runs the same route a dispatch runs, over the
## Runtime's method and request bytes (borrowed until the release), with the
## invocation's own context. Once the handler returned and its scoped
## publications were answered, the job completes the invocation once, with
## the response or the failure's diagnostics in one C block that its owner
## zeroes and frees on any thread, and releases execution once. The
## invocation's `Invocation` refuses use before that release. `request_cancel`
## finds the invocation among the context's outstanding ones under the lock,
## or returns; otherwise it queues one notice, which cancels an `async`
## handler's future on the module thread (a plain handler sees
## `isCancelled`). A job queued when a cancellation arrived completes
## CANCELLED without its handler. Neither operation waits.
##
## **Marked payloads** (INTERFACE l.363; DECISIONS G276). Every copy this
## module makes in C memory (queued events, a status's message and detail) and
## every request, response and tree it holds is zeroed after its last use,
## marked or not.

{.push raises: [], gcsafe.}

import std/[locks, typedthreads]
import results
import chronos/[asyncloop, config, threadsync]
import ../cbor
import ../abi/[checks, types]
import ../iface/[outcome, payload]
import ../base/[perthread, wipe]
import ./[handover, kitrt]

when defined(posix):
  import std/posix
when not defined(windows):
  import chronos/selectors2

export asyncloop

when chronosStrictReentrancy:
  {.
    fatal:
      "a confined module kit re-enters its module thread by polling chronos's " &
      "dispatcher inside a running task, which chronosStrictReentrancy (turned on " &
      "by chronosPreviewV5) forbids: build without it (DECISIONS G335, G341)"
  .}

proc cCalloc(n, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}
proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc cAbort() {.importc: "abort", header: "<stdlib.h>", noreturn.}
proc cWrite(
  fd: cint, p: pointer, n: csize_t
): int {.importc: "write", header: "<unistd.h>".}

proc die(message: static string) {.noreturn.} =
  ## A broken precondition or a failure nothing can report: a fixed message on
  ## stderr, then abort. Never allocates.
  const line = "logos module kit (confined): " & message & "\n"
  discard cWrite(2, cstring(line), csize_t(line.len))
  cAbort()

const
  DefaultMaxEvents* = 64 ## [IMPL] the publisher queue's bound in events
  DefaultMaxBytes* = 1_048_576 ## [IMPL] and in payload bytes
  DefaultMaxDeliveries* = 1024
    ## [IMPL] (DECISIONS G339, P1) events queued for the module thread's
    ## handlers, across the context's subscriptions
  RefusalNameCap = 256
  UnwindMs = 2000
    ## [IMPL] (DECISIONS G338) how long destroy waits for the cancelled handlers
    ## of submitted invocations a Runtime did not drain

# Statuses copied across threads ---------------------------------------------------

proc toLogosResult(src: var StatusCopy): LogosResult =
  ## The calling thread's `logos_result_t` for a job's outcome (INTERFACE §2.7:
  ## its diagnostics live in this thread's storage); the copy is zeroed.
  if src.code == 0 and not src.bad and src.messageLen < 0 and src.detailLen < 0:
    return okResult()
  var f = InvocationFailure(code: ecModule)
  let code = errorCode(src.code)
  if not src.bad and code.isSome:
    f.code = code.get
    if src.messageLen >= 0:
      var m = newString(src.messageLen)
      for i in 0 ..< src.messageLen:
        m[i] = src.message[i]
      f.message = Opt.some(m)
      wipe(m)
    if src.detailLen >= 0:
      var d = newSeq[byte](src.detailLen)
      for i in 0 ..< src.detailLen:
        d[i] = src.detail[i]
      f.detail = Opt.some(d)
      wipe(d)
  result = failureResult(f)
  wipe(f)
  src.clear()

# Contexts and jobs -----------------------------------------------------------------

type
  LaunchFn = proc(job: ptr ConfinedJob) {.nimcall, gcsafe, raises: [].}
    ## Starts a job's task on the module thread.

  Mail = object
    ## A plain handler's invocation-scoped publication, for the entry thread.
    eventId: cstring
    data: ptr UncheckedArray[uint8]
    len: int
    done: bool ## under the context's lock
    status: StatusCopy

  ConfinedJob* = object ## One handed-off entry, on its calling thread's stack.
    node: Node
    ctx: ptr ConfinedObj
    launch: LaunchFn
    args: pointer ## the entry's own arguments, borrowed while it waits
    invocation: ptr LogosInvocationContext ## captured on the calling thread
    scope: ConfinedScope ## what a plain handler of this job reads (G336)
    inline: bool ## runs on the module thread itself
    done: bool ## under the context's lock
    cond: Cond
    mail: ptr Mail ## under the context's lock
    status: StatusCopy
    inflight: int ## module thread: scoped publications not yet answered
    drained: pointer ## module thread: a `DrainFuture` waiting for `inflight` to be 0
    deferred: bool ## a `DeferredJob`'s: no entry thread waits for it

  DeferredJob = object
    ## [DECISIONS G338] One submitted provider invocation (INTERFACE §2.9.2),
    ## in C memory from `submit` until its last reference is dropped.
    job: ConfinedJob ## first: the queue's node is the job's
    invocation: ptr LogosProviderInvocation ## the Runtime's, until `execution_release`
    route: ConfinedRoute
    next, prev: ptr DeferredJob ## the context's outstanding invocations, under its lock
    cancelTask: TaskNode ## the cancellation notice, reserved
    cancelQueued: bool ## under the context's lock
    cancelRequested: bool ## under the context's lock
    finished: bool ## under the context's lock: completed, not yet released
    refs: int ## under the context's lock: the job's own, and a queued notice's
    inv: pointer ## module thread: the job's `InvocationObj` while its handler runs
    unwound: bool ## module thread: destroy cancelled its handler (G338)

  PostFn* = proc(payload: pointer) {.cdecl, gcsafe, raises: [].}
    ## A callback `post` runs on the module thread.

  PostNode = object
    node: Node
    fn: PostFn
    payload: pointer

  PubKind = enum
    pkInstance ## the instance's publish callback
    pkScoped ## an invocation context's `publish`

  PubItem = object
    ## One queued publication: the header, then the event id (NUL-terminated)
    ## and the payload, in one block from the C allocator.
    next: ptr PubItem
    kind: PubKind
    invocation: ptr LogosInvocationContext
    job: ptr ConfinedJob ## a scoped publication's job
    reply: pointer ## a `ReplyFuture` the module thread completes; nil for `publish`
    rc: int64 ## the callback's result
    status: StatusCopy ## the context's status
    nameLen, dataLen: int

  ConfinedObj = object ## What `logos_module_context_t*` points to for a confined kit.
    lock: Lock
    head, tail: ptr Node
    repHead, repTail: ptr PubItem ## answered publications, for the module thread
    room: bool ## the publisher took an event while the module thread wanted room
    stopping: bool
    closed: bool ## the module thread drained its queue for the last time
    live: ptr DeferredJob ## submitted invocations not yet completed (G338)
    deliveries: int ## counted tasks queued (G339's delivery bound)
    maxDeliveries: int
    signal: ThreadSignalPtr
    module: Thread[ptr ConfinedObj]
    services: ModuleServices
    # Module thread only.
    instance: pointer
    disposed: bool
    ending: bool ## the module thread is tearing down
    # The publisher.
    pubLock: Lock
    pubCond: Cond
    pubHead, pubTail: ptr PubItem
    pubCount, pubBytes: int
    maxEvents, maxBytes: int
    pubStop, pubDrop, roomWanted: bool
    publisher: Thread[ptr ConfinedObj]
    refusals: uint64
    refusalRc: int64
    refusalName: array[RefusalNameCap, char]
    refusalLen: int

  InvocationObj = object
    job: ptr ConfinedJob
    handler: FutureBase
      ## [DECISIONS G338] an `async` handler's future while it is awaited: what
      ## a cancellation of a submitted invocation cancels

  Invocation* = ref InvocationObj
    ## [DECISIONS G336] An `async` handler's invocation: valid until its job
    ## ends, NOT_READY afterwards (INTERFACE l.2130). Use it on the module
    ## thread only.

  ReplyFuture = Future[Result[void, InvocationFailure]].Raising([])
  DrainFuture = Future[void].Raising([])

  CreateFuture* = Future[Result[pointer, InvocationFailure]].Raising([])
  RouteFuture* = Future[Result[seq[byte], InvocationFailure]].Raising([])
  ApplyFuture* = Future[Result[void, InvocationFailure]].Raising([])
  DisposeFuture* = Future[void].Raising([])

  ConfinedCreate* = proc(init: ModuleInit): CreateFuture {.nimcall, gcsafe, raises: [].}
    ## Runs the author's `initModule` and returns its instance, `GC_ref`'d.
  ConfinedDispose* =
    proc(instance: pointer): DisposeFuture {.nimcall, gcsafe, raises: [].}
    ## Runs the author's `destroyModule`, if any, and `GC_unref`s the instance.
  ConfinedRoute* = proc(
    instance: pointer,
    bare: string,
    params: ptr UncheckedArray[uint8],
    len: int,
    inv: Invocation,
  ): RouteFuture {.nimcall, gcsafe, raises: [].}
    ## The generated dispatch table: request bytes to response bytes.
  ConfinedApply* = proc(
    instance: pointer, input: ptr UncheckedArray[uint8], len: int
  ): ApplyFuture {.nimcall, gcsafe, raises: [].}
    ## Checks one `configuration_input` and runs `applyConfiguration`.
  TypedRequest* = proc(args: pointer, bytes: var seq[byte]): Result[void, string] {.
    nimcall, gcsafe, raises: []
  .} ## A typed function's C inputs as request bytes.
  TypedRespond* = proc(args: pointer, v: CborValue): Result[void, string] {.
    nimcall, gcsafe, raises: []
  .} ## A checked response as a typed function's C outputs.

  Poster* = distinct pointer
    ## [IMPL] What `post` takes: valid from `initModule` until `_MODULE_destroy`
    ## returns.

  PublishRefusal* = object
    ## [DECISIONS G337] The publish callback's last refusal of a queued event.
    rc*: int64 ## the callback's result as it returned it
    event*: string

var
  ownCtx {.threadvar.}: ptr ConfinedObj ## the context whose module thread this is
  roomWaiters {.threadvar.}: seq[DrainFuture]

# Waking the module thread ------------------------------------------------------------

when defined(windows):
  type SignalMirror = object
    event: int

  proc setEvent(h: int): int32 {.importc: "SetEvent", stdcall, header: "<windows.h>".}
elif defined(linux) and not defined(emscripten):
  type SignalMirror = object
    efd: cint

else:
  type SignalMirror = object
    rfd, wfd: cint

static:
  doAssert sizeof(SignalMirror) == sizeof(ThreadSignal),
    "chronos's ThreadSignal changed its layout: update confinedrt's mirror"

proc fire(signal: ThreadSignalPtr) =
  ## Wakes the thread that waits on `signal`. Any thread, one the Nim runtime
  ## never saw included: no Nim heap, and a failure aborts. A signal already
  ## pending is enough.
  let m = cast[ptr SignalMirror](signal)
  when defined(windows):
    if setEvent(m.event) == 0:
      die("the module thread's signal could not be set")
  elif defined(linux) and not defined(emscripten):
    var one = 1'u64
    while true:
      let n = posix.write(m.efd, addr one, sizeof(one))
      if n == sizeof(one):
        return
      if n < 0 and errno == EINTR:
        continue
      if n < 0 and errno == EAGAIN:
        return
      die("the module thread's signal could not be written")
  else:
    var probe = 0'u64
    if recv(SocketHandle(m.rfd), addr probe, sizeof(probe), MSG_PEEK) > 0:
      # the socket is non-blocking
      return
    var one = 1'u64
    while true:
      let n = send(SocketHandle(m.wfd), addr one, sizeof(one), 0)
      if n == sizeof(one):
        return
      if n < 0 and errno == EINTR:
        continue
      if n < 0 and (errno == EAGAIN or errno == ENOBUFS):
        return
      die("the module thread's signal could not be written")

proc enqueue(ctx: ptr ConfinedObj, n: ptr Node) =
  ## Under the context's lock.
  n.next = nil
  if ctx.tail == nil:
    ctx.head = n
  else:
    ctx.tail.next = n
  ctx.tail = n

proc takeNode(ctx: ptr ConfinedObj): ptr Node =
  ## Under the context's lock.
  result = ctx.head
  if result != nil:
    ctx.head = result.next
    if ctx.head == nil:
      ctx.tail = nil
    result.next = nil
    if result.kind == nkTask and cast[ptr TaskNode](result).counted:
      dec ctx.deliveries

# The publisher ----------------------------------------------------------------------

proc itemName(item: ptr PubItem): cstring =
  cast[cstring](cast[uint](item) + uint(sizeof(PubItem)))

proc itemData(item: ptr PubItem): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](item) + uint(sizeof(PubItem)) +
    uint(item.nameLen + 1))

proc freeItem(item: ptr PubItem) =
  ## Zeroes the event and frees it (INTERFACE l.363).
  item.status.clear()
  secureZero(cast[pointer](item), sizeof(PubItem) + item.nameLen + 1 + item.dataLen)
  cFree(item)

proc newItem(
    kind: PubKind, eventId: string, data: openArray[byte]
): Result[ptr PubItem, InvocationFailure] =
  let size = sizeof(PubItem) + eventId.len + 1 + data.len
  let item = cast[ptr PubItem](cCalloc(1, csize_t(size)))
  if item == nil:
    return err(moduleError("out of memory for a queued event"))
  item.kind = kind
  item.nameLen = eventId.len
  item.dataLen = data.len
  item.status.messageLen = -1
  item.status.detailLen = -1
  let name = cast[ptr UncheckedArray[char]](item.itemName)
  for i, c in eventId:
    name[i] = c
  let d = item.itemData
  for i, b in data:
    d[i] = b
  ok(item)

proc tryQueue(ctx: ptr ConfinedObj, item: ptr PubItem, wantRoom: bool): bool =
  ## Queues `item` unless the queue is full; a full queue asks the publisher
  ## to report room when `wantRoom`. An event larger than the byte bound goes
  ## alone into an empty queue.
  acquire(ctx.pubLock)
  if ctx.pubStop or (
    ctx.pubCount > 0 and
    (ctx.pubCount >= ctx.maxEvents or ctx.pubBytes + item.dataLen > ctx.maxBytes)
  ):
    if wantRoom and not ctx.pubStop:
      ctx.roomWanted = true
    release(ctx.pubLock)
    return false
  item.next = nil
  if ctx.pubTail == nil:
    ctx.pubHead = item
  else:
    ctx.pubTail.next = item
  ctx.pubTail = item
  inc ctx.pubCount
  ctx.pubBytes += item.dataLen
  signal(ctx.pubCond)
  release(ctx.pubLock)
  true

proc answer(ctx: ptr ConfinedObj, item: ptr PubItem) =
  ## Hands an answered publication back to the module thread.
  acquire(ctx.lock)
  item.next = nil
  if ctx.repTail == nil:
    ctx.repHead = item
  else:
    ctx.repTail.next = item
  ctx.repTail = item
  release(ctx.lock)
  fire(ctx.signal)

proc recordRefusal(ctx: ptr ConfinedObj, item: ptr PubItem) =
  acquire(ctx.pubLock)
  inc ctx.refusals
  ctx.refusalRc = item.rc
  let n = min(item.nameLen, RefusalNameCap)
  let name = item.itemName
  for i in 0 ..< n:
    ctx.refusalName[i] = name[i]
  ctx.refusalLen = n
  release(ctx.pubLock)

proc deliver(ctx: ptr ConfinedObj, item: ptr PubItem, drop: bool) =
  if drop:
    item.rc = int64(ord(ecNotReady))
    copyFailure(item.status, failure(ecNotReady, "the module did not start"))
  else:
    case item.kind
    of pkInstance:
      item.rc = ctx.services.callPublish(item.itemName, item.itemData, item.dataLen)
      if item.rc != 0:
        ctx.recordRefusal(item)
    of pkScoped:
      let r = item.invocation.vtable.publish(
        item.invocation, item.itemName, item.itemData, csize_t(item.dataLen)
      )
      copyResult(item.status, r)
  if item.reply != nil:
    ctx.answer(item)
  else:
    freeItem(item)

proc publisherMain(ctx: ptr ConfinedObj) {.thread.} =
  ## [DECISIONS G337] Calls the publish callbacks in queue order; touches only
  ## C memory. Leaves once stopped and empty.
  acquire(ctx.pubLock)
  while true:
    while ctx.pubHead == nil and not ctx.pubStop:
      wait(ctx.pubCond, ctx.pubLock)
    let item = ctx.pubHead
    if item == nil:
      break
    ctx.pubHead = item.next
    if ctx.pubHead == nil:
      ctx.pubTail = nil
    dec ctx.pubCount
    ctx.pubBytes -= item.dataLen
    let room = ctx.roomWanted
    ctx.roomWanted = false
    let drop = ctx.pubDrop
    release(ctx.pubLock)
    if room:
      acquire(ctx.lock)
      ctx.room = true
      release(ctx.lock)
      fire(ctx.signal)
    ctx.deliver(item, drop)
    acquire(ctx.pubLock)
  release(ctx.pubLock)

proc queuePublish(
    confined: pointer, eventId: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [DECISIONS G337] `publish` in a confined kit: queued, never waiting; the
  ## kit's own NOT_READY when the queue is full. Any thread.
  let ctx = cast[ptr ConfinedObj](confined)
  let item = ?newItem(pkInstance, eventId, data)
  if not ctx.tryQueue(item, wantRoom = false):
    freeItem(item)
    return err(
      failure(
        ecNotReady,
        "the kit's publish queue is full (the kit's refusal, not the callback's): " &
          eventId,
      )
    )
  ok()

proc waitRoom(ctx: ptr ConfinedObj): DrainFuture =
  let f = DrainFuture.init("confined publisher room", {FutureFlag.OwnCancelSchedule})
  roomWaiters.add(f)
  f

proc onModuleThread(ctx: ptr ConfinedObj): bool =
  ctx != nil and ownCtx == ctx

proc newReply(): ReplyFuture =
  result = ReplyFuture.init("confined publication", {FutureFlag.OwnCancelSchedule})
  GC_ref(result)

proc publishEncodedAsync*(
    s: ModuleServices, eventId: string, data: seq[byte]
): Future[Result[void, InvocationFailure]] {.async: (raises: []).} =
  ## [DECISIONS G337, App A.4] Queues one encoded event for the publish
  ## callback and completes with the callback's result once it returned,
  ## waiting for room in a full queue. The module thread only.
  let ctx = cast[ptr ConfinedObj](s.confinedOf)
  if not ctx.onModuleThread:
    return Result[void, InvocationFailure].err(
      failure(ecNotReady, "publishAsync runs on its module's thread")
    )
  if not s.hasPublish:
    return Result[void, InvocationFailure].err(
      failure(ecNotReady, "this instance has no publish callback")
    )
  if data.len == 0:
    return Result[void, InvocationFailure].err(
      moduleError("an event payload is one CBOR map")
    )
  let made = newItem(pkInstance, eventId, data)
  if made.isErr:
    return Result[void, InvocationFailure].err(made.unsafeError)
  let item = made.unsafeGet
  let reply = newReply()
  item.reply = cast[pointer](reply)
  while not ctx.tryQueue(item, wantRoom = true):
    await ctx.waitRoom()
  await reply

# Statuses back on the module thread --------------------------------------------------

proc settleReply(ctx: ptr ConfinedObj, item: ptr PubItem) =
  ## Completes an answered publication's future; after the instance's release
  ## the future is let go without resuming anyone.
  let reply {.cursor.} = cast[ReplyFuture](item.reply)
  let job = item.job
  if job != nil:
    dec job.inflight
    if job.inflight == 0 and job.drained != nil:
      let d {.cursor.} = cast[DrainFuture](job.drained)
      if not d.finished():
        d.complete()
  if not ctx.disposed and not ctx.ending and not reply.finished():
    case item.kind
    of pkInstance:
      reply.complete(publishCode(item.rc, $item.itemName))
    of pkScoped:
      reply.complete(readCopy(item.status))
  GC_unref(reply)
  freeItem(item)

# Jobs on the module thread ----------------------------------------------------------

proc scopedPublish(
  job: pointer, eventId: string, data: openArray[byte]
): Result[void, InvocationFailure] {.nimcall, gcsafe, raises: [].}

proc startJob(job: ptr ConfinedJob): Invocation =
  job.scope = ConfinedScope(
    invocation: job.invocation, job: cast[pointer](job), publish: scopedPublish
  )
  Invocation(job: job)

proc drain(job: ptr ConfinedJob) {.async: (raises: []).} =
  ## [DECISIONS G336, G337] Waits until every publication the job made in its
  ## invocation's scope was answered (INTERFACE l.2157; RUNTIME l.1200).
  if job.inflight > 0:
    let d = DrainFuture.init("confined drain", {FutureFlag.OwnCancelSchedule})
    job.drained = cast[pointer](d)
    await d
    job.drained = nil

proc finishJob(
    job: ptr ConfinedJob, inv: Invocation, outcome: var Result[void, InvocationFailure]
) =
  ## Writes the outcome and releases the waiting entry. The job is not touched
  ## afterwards: its frame may be gone.
  if inv != nil:
    inv.job = nil
  if outcome.isOk:
    job.status.clear()
  else:
    copyFailure(job.status, outcome.unsafeError)
    wipeError(outcome)
  let ctx = job.ctx
  acquire(ctx.lock)
  job.done = true
  if not job.inline:
    signal(job.cond)
  release(ctx.lock)

template settled*(fut: untyped): untyped =
  ## The value of a future that cannot fail, once it finished, moved out of it
  ## (so no copy of a marked value stays in the future). In an `async` proc.
  block:
    let f = fut
    if not f.finished():
      await noCancel(join(f))
    move(f.internalValue)

template settleHandler*(response: untyped, call: untyped) =
  ## [DECISIONS G336] An `async` hook's outcome, moved out of its future once
  ## it finished; a future that ended cancelled answers CANCELLED. In an
  ## `async` proc.
  block:
    let f = call
    if not f.finished():
      await noCancel(join(f))
    if f.completed():
      response = move(f.internalValue)
    elif f.cancelled():
      response.err(failure(ecCancelled, "the handler was cancelled"))
    else:
      response.err(moduleError("the handler's future did not complete"))

proc recordHandler(inv: Invocation, f: FutureBase) =
  if not inv.isNil:
    inv.handler = f

template settleHandler*(response: untyped, call: untyped, inv: Invocation) =
  ## [DECISIONS G336, G338] An `async` handler's outcome, as above; while it is
  ## awaited, a cancellation of `inv`'s submitted invocation cancels its
  ## future. In an `async` proc.
  bind recordHandler
  block:
    let f = call
    if not f.finished():
      recordHandler(inv, f)
      await noCancel(join(f))
      recordHandler(inv, nil)
    if f.completed():
      response = move(f.internalValue)
    elif f.cancelled():
      response.err(failure(ecCancelled, "the handler was cancelled"))
    else:
      response.err(moduleError("the handler's future did not complete"))

proc notReady(): Result[void, InvocationFailure] =
  err(failure(ecNotReady, "the module instance is not running"))

type
  InitArgs = object
    input: ptr LogosModuleInitInput
    create: ConfinedCreate

  DestroyArgs = object
    dispose: ConfinedDispose

  ApplyArgs = object
    apply: ConfinedApply
    input: ptr UncheckedArray[uint8]
    len: int

  DispatchArgs = object
    route: ConfinedRoute
    methodName: cstring
    params: ptr UncheckedArray[uint8]
    len: int
    outResponse: ptr ptr UncheckedArray[uint8]
    outResponseLen: ptr csize_t

  TypedArgs = object
    route: ConfinedRoute
    bare: cstring
    args: pointer
    request: TypedRequest
    respond: TypedRespond

proc initTask(job: ptr ConfinedJob) {.async: (raises: []).} =
  let a = cast[ptr InitArgs](job.args)
  let ctx = job.ctx
  var outcome: Result[void, InvocationFailure]
  var r = settled(a.create(moduleInit(a.input, ctx.services)))
  if r.isOk:
    ctx.instance = r.unsafeGet
    outcome = Result[void, InvocationFailure].ok()
  else:
    outcome = Result[void, InvocationFailure].err(r.unsafeError)
    wipeError(r)
  finishJob(job, nil, outcome)

proc cancelHandler(dj: ptr DeferredJob): bool =
  ## [SPEC INTERFACE §2.9.2 l.2112; DECISIONS G338] Module thread: cancels the
  ## future of the `async` handler `dj`'s invocation runs, if one is waiting.
  ## The route awaits it behind `noCancel`, so only the handler sees it.
  if dj.inv == nil:
    return false
  let inv {.cursor.} = cast[Invocation](dj.inv)
  if inv.handler.isNil or inv.handler.finished():
    return false
  inv.handler.cancelSoon()
  true

proc unwindDeferred(ctx: ptr ConfinedObj) {.async: (raises: []).} =
  ## [SPEC INTERFACE l.2100, l.2113-2117; DECISIONS G338] A second chance for a
  ## Runtime that destroys with submitted invocations it did not drain
  ## (against l.2114): each waiting `async` handler is cancelled, as
  ## `request_cancel` would, and every outstanding invocation gets `UnwindMs`
  ## to complete while the instance still lives. One whose handler was
  ## cancelled here completes NOT_READY; one waiting for its scoped
  ## publications keeps its outcome. What is still outstanding then is
  ## completed at teardown, its task abandoned. An `await`, never a nested
  ## poll: destroy may itself run inside a handler's nested loop.
  var running: seq[ptr DeferredJob]
  acquire(ctx.lock)
  var dj = ctx.live
  while dj != nil:
    if dj.inv != nil:
      running.add(dj)
    dj = dj.next
  release(ctx.lock)
  for dj in running:
    # Outside the lock: a cancellation may run the handler's callbacks. A job
    # whose handler runs cannot complete before this thread turns again.
    dj.unwound = true
    discard dj.cancelHandler()
  let deadline = Moment.now() + UnwindMs.milliseconds
  while Moment.now() < deadline:
    acquire(ctx.lock)
    let outstanding = ctx.live != nil
    release(ctx.lock)
    if not outstanding:
      break
    try:
      await sleepAsync(1.milliseconds)
    except CancelledError:
      break

proc destroyTask(job: ptr ConfinedJob) {.async: (raises: []).} =
  let a = cast[ptr DestroyArgs](job.args)
  let ctx = job.ctx
  # [DECISIONS G338] No new job reaches the instance (each answers NOT_READY);
  # running handlers keep their own reference to it until it is disposed.
  # `disposed` waits for the unwinding: it drops posted tasks, and a cancelled
  # handler may await a completion that arrives as one.
  let instance = ctx.instance
  ctx.instance = nil
  await unwindDeferred(ctx)
  ctx.disposed = true
  if instance != nil:
    let f = a.dispose(instance)
    if not f.finished():
      await noCancel(join(f))
  var outcome = Result[void, InvocationFailure].ok()
  finishJob(job, nil, outcome)

proc applyTask(job: ptr ConfinedJob) {.async: (raises: []).} =
  let a = cast[ptr ApplyArgs](job.args)
  let ctx = job.ctx
  var outcome: Result[void, InvocationFailure]
  if ctx.instance == nil:
    outcome = notReady()
  else:
    outcome = settled(a.apply(ctx.instance, a.input, a.len))
  finishJob(job, nil, outcome)

proc dispatchTask(job: ptr ConfinedJob) {.async: (raises: []).} =
  let a = cast[ptr DispatchArgs](job.args)
  let ctx = job.ctx
  let inv = startJob(job)
  var outcome: Result[void, InvocationFailure]
  if ctx.instance == nil:
    outcome = notReady()
  else:
    var response = settled(a.route(ctx.instance, $a.methodName, a.params, a.len, inv))
    if response.isOk:
      outcome = storeResponse(response.unsafeGet, a.outResponse, a.outResponseLen)
    else:
      outcome = Result[void, InvocationFailure].err(response.unsafeError)
    wipe(response)
  await drain(job)
  finishJob(job, inv, outcome)

proc typedTask(job: ptr ConfinedJob) {.async: (raises: []).} =
  let a = cast[ptr TypedArgs](job.args)
  let ctx = job.ctx
  let inv = startJob(job)
  var outcome: Result[void, InvocationFailure]
  if ctx.instance == nil:
    outcome = notReady()
  else:
    var bytes: seq[byte]
    let built = a.request(a.args, bytes)
    if built.isErr:
      outcome =
        Result[void, InvocationFailure].err(failure(ecInvalidParams, built.unsafeError))
    else:
      let p =
        if bytes.len == 0:
          nil
        else:
          cast[ptr UncheckedArray[uint8]](addr bytes[0])
      var response = settled(a.route(ctx.instance, $a.bare, p, bytes.len, inv))
      wipe(bytes)
      if response.isErr:
        outcome = Result[void, InvocationFailure].err(response.unsafeError)
      else:
        let v = decodePayload(response.unsafeGet)
        if v.isErr:
          outcome = Result[void, InvocationFailure].err(
            moduleError("the response does not decode: " & v.unsafeError.msg)
          )
        else:
          let r = a.respond(a.args, v.unsafeGet)
          if r.isErr:
            outcome = Result[void, InvocationFailure].err(
              moduleError("the response has no canonical C value: " & r.unsafeError)
            )
          else:
            outcome = Result[void, InvocationFailure].ok()
          wipe(v.unsafeGet)
      wipe(response)
  await drain(job)
  finishJob(job, inv, outcome)

# Submitted invocations (DECISIONS G338) ---------------------------------------------

proc isCancelled*(inv: Invocation): bool

type OwnedBlock = object
  ## What a completion's response owner governs: `size` bytes follow.
  size: int

proc blockBytes(b: ptr OwnedBlock): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](b) + uint(sizeof(OwnedBlock)))

proc newBlock(size: int): ptr OwnedBlock =
  result = cast[ptr OwnedBlock](cCalloc(1, csize_t(sizeof(OwnedBlock) + size)))
  if result != nil:
    result.size = size

proc releaseBlock(state: pointer) {.cdecl, gcsafe, raises: [].} =
  ## [SPEC INTERFACE §2.7.1, l.2085-2091] A completion's response owner: the
  ## response, or the failure's message and detail, zeroed and freed (G276).
  ## Any thread: only the C allocator.
  let b = cast[ptr OwnedBlock](state)
  if b != nil:
    secureZero(state, sizeof(OwnedBlock) + b.size)
    cFree(state)

proc completeNow(
    invocation: ptr LogosProviderInvocation, code: ErrorCode, message: cstring
) =
  ## A completion whose message is static, then the release. Any thread; no
  ## Nim heap.
  invocation.complete(
    invocation,
    LogosResult(code: CErrorCode(ord(code)), message: message),
    nil,
    0,
    LogosResponseOwner(),
  )
  invocation.executionRelease(invocation)

proc link(ctx: ptr ConfinedObj, dj: ptr DeferredJob) =
  ## Under the context's lock.
  dj.prev = nil
  dj.next = ctx.live
  if ctx.live != nil:
    ctx.live.prev = dj
  ctx.live = dj

proc unlink(ctx: ptr ConfinedObj, dj: ptr DeferredJob) =
  ## Under the context's lock.
  if dj.prev != nil:
    dj.prev.next = dj.next
  elif ctx.live == dj:
    ctx.live = dj.next
  if dj.next != nil:
    dj.next.prev = dj.prev
  dj.next = nil
  dj.prev = nil

proc unref(dj: ptr DeferredJob) =
  ## Drops one reference; the last frees the job.
  let ctx = dj.job.ctx
  acquire(ctx.lock)
  dec dj.refs
  let last = dj.refs == 0
  release(ctx.lock)
  if last:
    secureZero(cast[pointer](dj), sizeof(DeferredJob))
    cFree(dj)

proc completeDeferred(
    dj: ptr DeferredJob, outcome: var Result[seq[byte], InvocationFailure]
) =
  ## [SPEC INTERFACE §2.9.2] The invocation's one completion and then its one
  ## release (IFC-0753). The response, or the failure's message and detail as
  ## a status carries them, go in one C block the owner governs until it is
  ## cleared, on any thread (IFC-0754). The outstanding list forgets the
  ## invocation first, so a later `request_cancel` finds nothing (IFC-0763).
  ## Module thread; `outcome` is the caller's to zero.
  let invocation = dj.invocation
  let ctx = dj.job.ctx
  acquire(ctx.lock)
  ctx.unlink(dj)
  dj.finished = true
  release(ctx.lock)
  if outcome.isOk and outcome.unsafeGet.len == 0:
    outcome = Result[seq[byte], InvocationFailure].err(
      moduleError("the handler's response is empty")
    )
  var r = LogosResult()
  var data: ptr UncheckedArray[uint8] = nil
  var len = 0
  var owner = LogosResponseOwner()
  if outcome.isOk:
    let n = outcome.unsafeGet.len
    let b = newBlock(n)
    if b == nil:
      r = LogosResult(
        code: CErrorCode(ord(ecModule)), message: "out of memory for the response"
      )
    else:
      let d = b.blockBytes
      for i in 0 ..< n:
        d[i] = outcome.unsafeGet[i]
      data = d
      len = n
      owner = LogosResponseOwner(state: b, release: releaseBlock)
  else:
    var f = normalizedFailure(outcome.unsafeError)
    r.code = CErrorCode(ord(f.code))
    if f.message.isSome or f.detail.isSome:
      let m = (if f.message.isSome: f.message.unsafeGet.len + 1 else: 0)
      let dl = (if f.detail.isSome: f.detail.unsafeGet.len else: 0)
      let b = newBlock(m + dl)
      if b != nil:
        # Out of memory, the code goes without its diagnostics.
        let d = b.blockBytes
        if f.message.isSome:
          for i, c in f.message.unsafeGet:
            d[i] = uint8(c)
          d[m - 1] = 0
          r.message = cast[cstring](d)
        if f.detail.isSome:
          let p = cast[ptr UncheckedArray[uint8]](cast[uint](d) + uint(m))
          for i, x in f.detail.unsafeGet:
            p[i] = x
          r.detail = p
          r.detailLen = csize_t(dl)
        owner = LogosResponseOwner(state: b, release: releaseBlock)
    wipe(f)
  invocation.complete(invocation, r, data, csize_t(len), owner)
  invocation.executionRelease(invocation)
  dj.unref()

proc deferredTask(dj: ptr DeferredJob) {.async: (raises: []).} =
  ## [SPEC INTERFACE §2.9.2; DECISIONS G338] One submitted invocation on the
  ## module thread: the route over the Runtime's method and request bytes,
  ## borrowed until the release (IFC-0752), with the invocation's own context
  ## (l.2131); then its scoped publications answered, its `Invocation`
  ## closed (IFC-0779), its completion and its release.
  let job = addr dj.job
  let ctx = job.ctx
  let inv = startJob(job)
  let i = dj.invocation
  var outcome: Result[seq[byte], InvocationFailure]
  acquire(ctx.lock)
  let cancelled = dj.cancelRequested
  release(ctx.lock)
  if ctx.instance == nil:
    outcome.err(failure(ecNotReady, "the module instance is not running"))
  elif cancelled or inv.isCancelled():
    outcome.err(failure(ecCancelled, "cancelled before its handler ran"))
  else:
    dj.inv = cast[pointer](inv)
    outcome = settled(
      dj.route(ctx.instance, $i.`method`, i.paramsCbor, int(i.paramsCborLen), inv)
    )
    dj.inv = nil
    if dj.unwound:
      # [DECISIONS G338] Unwound by destroy's cancellation: whatever it
      # answered goes, wiped, since it may be a marked response.
      wipe(outcome)
      outcome = Result[seq[byte], InvocationFailure].err(
        failure(ecNotReady, "the module was destroyed")
      )
  await drain(job)
  inv.job = nil
  completeDeferred(dj, outcome)
  wipe(outcome)

proc runCancel(task: ptr TaskNode, drop: bool) {.nimcall, gcsafe, raises: [].} =
  ## [SPEC INTERFACE §2.9.2 l.2112; DECISIONS G338] A cancellation notice on
  ## the module thread: cancels an `async` handler's future while it runs.
  let dj =
    cast[ptr DeferredJob](cast[uint](task) - uint(offsetOf(DeferredJob, cancelTask)))
  let ctx = dj.job.ctx
  acquire(ctx.lock)
  dj.cancelQueued = false
  let finished = dj.finished
  release(ctx.lock)
  if not drop and not finished:
    discard dj.cancelHandler()
  dj.unref()

proc launchInit(job: ptr ConfinedJob) =
  asyncSpawn initTask(job)

proc launchDestroy(job: ptr ConfinedJob) =
  asyncSpawn destroyTask(job)

proc launchApply(job: ptr ConfinedJob) =
  asyncSpawn applyTask(job)

proc launchDispatch(job: ptr ConfinedJob) =
  asyncSpawn dispatchTask(job)

proc launchTyped(job: ptr ConfinedJob) =
  asyncSpawn typedTask(job)

proc launchDeferred(job: ptr ConfinedJob) =
  asyncSpawn deferredTask(cast[ptr DeferredJob](job))

proc runNode(ctx: ptr ConfinedObj, n: ptr Node) =
  case n.kind
  of nkJob:
    let job = cast[ptr ConfinedJob](n)
    job.launch(job)
  of nkPost:
    let p = cast[ptr PostNode](n)
    let (fn, payload) = (p.fn, p.payload)
    cFree(p)
    if not ctx.disposed:
      fn(payload)
  of nkTask:
    let t = cast[ptr TaskNode](n)
    t.run(t, ctx.disposed)

proc serve(ctx: ptr ConfinedObj) =
  ## Runs what is queued, one node at a time, answered publications first; a
  ## nested serve (a handler polling) takes the next node.
  while true:
    acquire(ctx.lock)
    let replies = ctx.repHead
    ctx.repHead = nil
    ctx.repTail = nil
    let room = ctx.room
    ctx.room = false
    let n = ctx.takeNode()
    release(ctx.lock)
    var item = replies
    while item != nil:
      let next = item.next
      ctx.settleReply(item)
      item = next
    if room:
      let waiters = move roomWaiters
      for w in waiters:
        if not w.finished():
          w.complete()
    if n == nil:
      return
    ctx.runNode(n)

proc onSignal(arg: pointer) {.gcsafe, raises: [].}

proc arm(ctx: ptr ConfinedObj) =
  ctx.signal.wait().addCallback(onSignal)

proc onSignal(arg: pointer) {.gcsafe, raises: [].} =
  let ctx = ownCtx
  if ctx == nil:
    return
  acquire(ctx.lock)
  let stopping = ctx.stopping
  release(ctx.lock)
  if not stopping:
    ctx.arm()
  ctx.serve()

proc pollUntil(ctx: ptr ConfinedObj, flag: ptr bool) =
  ## [DECISIONS G337, P3/P4] Polls this module thread's dispatcher until
  ## `*flag`, read under the context's lock, holds: a serving wait, and the
  ## wait of an inline entry. The confined scope is cleared meanwhile.
  let saved = swapConfinedScope(nil)
  while true:
    acquire(ctx.lock)
    let set = flag[]
    release(ctx.lock)
    if set:
      break
    poll()
  discard swapConfinedScope(saved)

proc deferredScopedPublish(
    job: ptr ConfinedJob, eventId: string, data: openArray[byte]
): Result[void, InvocationFailure] =
  ## [DECISIONS G337, G338, P3] A plain handler's `publishScoped` in a
  ## submitted invocation, which no entry thread waits for: through the
  ## publisher thread with the invocation's context, while this thread serves
  ## with the confined scope cleared.
  let ctx = job.ctx
  if data.len == 0:
    return err(moduleError("an event payload is one CBOR map"))
  let item = ?newItem(pkScoped, eventId, data)
  item.invocation = job.invocation
  item.job = job
  let reply = newReply()
  item.reply = cast[pointer](reply)
  inc job.inflight
  let saved = swapConfinedScope(nil)
  var queued = ctx.tryQueue(item, wantRoom = true)
  while not queued and not ctx.disposed:
    let room = ctx.waitRoom()
    while not room.finished() and not ctx.disposed:
      poll()
    queued = ctx.tryQueue(item, wantRoom = true)
  if queued:
    while not reply.finished() and not ctx.disposed:
      poll()
  discard swapConfinedScope(saved)
  if not queued:
    dec job.inflight
    GC_unref(reply)
    freeItem(item)
  if not reply.finished():
    return err(failure(ecNotReady, "the module instance is not running"))
  move(reply.internalValue)

proc scopedPublish(
    job: pointer, eventId: string, data: openArray[byte]
): Result[void, InvocationFailure] {.nimcall, gcsafe, raises: [].} =
  ## [DECISIONS G337, P3] A plain handler's `publishScoped`: by the entry
  ## thread, which waits for this job anyway; this thread serves meanwhile. An
  ## inline job publishes here, on the entry's own thread.
  let job = cast[ptr ConfinedJob](job)
  if job.deferred:
    return deferredScopedPublish(job, eventId, data)
  if job.inline:
    return publishVia(job.invocation, eventId, data)
  let ctx = job.ctx
  var mail = Mail(
    eventId: system.cstring(eventId),
    data: cast[ptr UncheckedArray[uint8]](unsafeAddr data[0]),
    len: data.len,
  )
  mail.status.messageLen = -1
  mail.status.detailLen = -1
  acquire(ctx.lock)
  job.mail = addr mail
  signal(job.cond)
  release(ctx.lock)
  ctx.pollUntil(addr mail.done)
  readCopy(mail.status)

proc teardown(ctx: ptr ConfinedObj) =
  ## [DECISIONS G335] The module thread's last act: answers what is still
  ## queued (NOT_READY), lets go of every pending future, closes its signal
  ## and tears down its dispatcher (`transport/io/loop.nim` does the same).
  ctx.ending = true
  while true:
    acquire(ctx.lock)
    let n = ctx.takeNode()
    let replies = ctx.repHead
    ctx.repHead = nil
    ctx.repTail = nil
    if n == nil and replies == nil:
      # A task posted from now on is dropped where it is posted.
      ctx.closed = true
    release(ctx.lock)
    var item = replies
    while item != nil:
      let next = item.next
      ctx.settleReply(item)
      item = next
    if n == nil:
      if replies == nil:
        break
      continue
    case n.kind
    of nkJob:
      let job = cast[ptr ConfinedJob](n)
      if job.deferred:
        var outcome = Result[seq[byte], InvocationFailure].err(
          failure(ecNotReady, "the module was destroyed")
        )
        completeDeferred(cast[ptr DeferredJob](job), outcome)
      else:
        var outcome = notReady()
        finishJob(job, nil, outcome)
    of nkPost:
      cFree(n)
    of nkTask:
      let t = cast[ptr TaskNode](n)
      t.run(t, true)
  # [DECISIONS G338] Submitted invocations still outstanding after destroy's
  # unwinding (a Runtime that destroys before their release, against INTERFACE
  # l.2114, and a handler that did not end when cancelled): completed NOT_READY
  # and released here, once each. No task resumes after teardown: an abandoned
  # one keeps its frames, which chronos pins while they wait (l.2116-2117).
  while true:
    acquire(ctx.lock)
    let dj = ctx.live
    release(ctx.lock)
    if dj == nil:
      break
    dj.inv = nil
    var outcome = Result[seq[byte], InvocationFailure].err(
      failure(ecNotReady, "the module was destroyed")
    )
    completeDeferred(dj, outcome)
  roomWaiters = @[]
  discard ctx.signal.close()
  let disp = getThreadDispatcher()
  when not defined(windows):
    discard disp.getIoHandler().close2()
  disp.callbacks.clear()
  setThreadDispatcher(nil)

proc moduleMain(ctx: ptr ConfinedObj) {.thread.} =
  ownCtx = ctx
  enterThread()
  enterConfinedThread()
  ctx.arm()
  ctx.serve()
  while true:
    acquire(ctx.lock)
    let stopping = ctx.stopping
    release(ctx.lock)
    if stopping:
      break
    poll()
  ctx.teardown()
  ownCtx = nil
  releasePerThread()

# The entries -----------------------------------------------------------------------

proc confinedOf(module: ptr LogosModuleContext): ptr ConfinedObj =
  cast[ptr ConfinedObj](module)

proc handOff(
    ctx: ptr ConfinedObj,
    launch: LaunchFn,
    args: pointer,
    invocation: ptr LogosInvocationContext,
): LogosResult =
  ## Runs one job on the module thread while this thread waits, serving the
  ## job's invocation-scoped publications; inline on the module thread itself.
  var job = ConfinedJob(
    node: Node(kind: nkJob),
    ctx: ctx,
    launch: launch,
    args: args,
    invocation: invocation,
  )
  job.status.messageLen = -1
  job.status.detailLen = -1
  if ctx.onModuleThread:
    # [DECISIONS G337] Re-entry: the task starts here and this thread polls
    # until it is done (the nesting rule, G336: the outer scope comes back).
    job.inline = true
    launch(addr job)
    ctx.pollUntil(addr job.done)
    return job.status.toLogosResult()
  initCond(job.cond)
  acquire(ctx.lock)
  if ctx.stopping:
    release(ctx.lock)
    deinitCond(job.cond)
    return failureResult(failure(ecNotReady, "the module is being destroyed"))
  ctx.enqueue(addr job.node)
  release(ctx.lock)
  fire(ctx.signal)
  acquire(ctx.lock)
  while not job.done:
    if job.mail != nil:
      # [DECISIONS G337] The context's `publish` on the entry thread; its
      # status copied here, before it crosses (INTERFACE l.2161).
      let m = job.mail
      job.mail = nil
      release(ctx.lock)
      let r = invocation.vtable.publish(invocation, m.eventId, m.data, csize_t(m.len))
      copyResult(m.status, r)
      acquire(ctx.lock)
      m.done = true
      release(ctx.lock)
      fire(ctx.signal)
      acquire(ctx.lock)
    else:
      wait(job.cond, ctx.lock)
  release(ctx.lock)
  deinitCond(job.cond)
  job.status.toLogosResult()

proc stopThreads(ctx: ptr ConfinedObj, deliver: bool) =
  ## The publisher delivers what is queued (or drops it) and leaves; then the
  ## module thread tears down. Both are joined.
  acquire(ctx.pubLock)
  ctx.pubStop = true
  ctx.pubDrop = not deliver
  signal(ctx.pubCond)
  release(ctx.pubLock)
  joinThread(ctx.publisher)
  acquire(ctx.lock)
  ctx.stopping = true
  # Under the lock: the module thread closes the signal only once it has seen
  # `stopping`, which it reads under this lock.
  fire(ctx.signal)
  release(ctx.lock)
  joinThread(ctx.module)

proc freeContext(ctx: ptr ConfinedObj) =
  deinitLock(ctx.lock)
  deinitLock(ctx.pubLock)
  deinitCond(ctx.pubCond)
  secureZero(cast[pointer](ctx), sizeof(ConfinedObj))
  cFree(ctx)

proc postTask(context: pointer, task: ptr TaskNode): bool

proc confinedInit*(
    input: ptr LogosModuleInitInput,
    outContext: ptr ptr LogosModuleContext,
    declaresEvents: bool,
    create: ConfinedCreate,
    maxEvents = DefaultMaxEvents,
    maxBytes = DefaultMaxBytes,
): LogosResult =
  ## [SPEC INTERFACE §2.6; DECISIONS G335] `_MODULE_init` of a confined kit:
  ## the input is checked here; the context's threads start and the author's
  ## `initModule` runs on the module thread. On failure both threads are
  ## joined before this returns.
  if outContext == nil:
    return failureResult(moduleError("null out_context"))
  outContext[] = nil
  checkInitInput(input, declaresEvents).isOkOr:
    return failureResult(failure(error.code, error.reason))
  let ctx = cast[ptr ConfinedObj](cCalloc(1, csize_t(sizeof(ConfinedObj))))
  if ctx == nil:
    return failureResult(moduleError("out of memory for the module context"))
  let signal = ThreadSignalPtr.new()
  if signal.isErr:
    cFree(ctx)
    return failureResult(moduleError("the module thread's signal: " & signal.error))
  ctx.signal = signal.get
  initLock(ctx.lock)
  initLock(ctx.pubLock)
  initCond(ctx.pubCond)
  ctx.maxEvents = max(maxEvents, 1)
  ctx.maxBytes = max(maxBytes, 1)
  ctx.maxDeliveries = DefaultMaxDeliveries
  ctx.services = moduleServices(input).withConfined(ctx, queuePublish, postTask)
  try:
    createThread(ctx.publisher, publisherMain, ctx)
  except ResourceExhaustedError:
    discard ctx.signal.close()
    freeContext(ctx)
    return failureResult(moduleError("the module's publisher thread did not start"))
  try:
    createThread(ctx.module, moduleMain, ctx)
  except ResourceExhaustedError:
    acquire(ctx.pubLock)
    ctx.pubStop = true
    signal(ctx.pubCond)
    release(ctx.pubLock)
    joinThread(ctx.publisher)
    discard ctx.signal.close()
    freeContext(ctx)
    return failureResult(moduleError("the module thread did not start"))
  var a = InitArgs(input: input, create: create)
  result = handOff(ctx, launchInit, addr a, nil)
  if result.code != CErrorCode(0):
    # [SPEC INTERFACE l.1607, l.3892] Nothing of the instance outlives a
    # failed initialization; the queued events are dropped.
    ctx.stopThreads(deliver = false)
    freeContext(ctx)
    return
  outContext[] = cast[ptr LogosModuleContext](ctx)

proc confinedDestroy*(module: ptr LogosModuleContext, dispose: ConfinedDispose) =
  ## [SPEC INTERFACE §2.6, l.1949-1962] `_MODULE_destroy` of a confined kit:
  ## the author's hook and the instance's release on the module thread, then
  ## the queued events delivered, then both threads joined and the context
  ## freed. Nothing is delivered after it returns.
  if module == nil:
    return
  let ctx = module.confinedOf
  if ctx.onModuleThread:
    die("_MODULE_destroy was called on its own module thread")
  var a = DestroyArgs(dispose: dispose)
  discard handOff(ctx, launchDestroy, addr a, nil)
  ctx.stopThreads(deliver = true)
  freeContext(ctx)

proc confinedApply*(
    module: ptr LogosModuleContext,
    configuration: ptr UncheckedArray[uint8],
    len: csize_t,
    apply: ConfinedApply,
): LogosResult =
  ## [SPEC INTERFACE §2.6; CONFIG §8] `_MODULE_apply_configuration` of a
  ## confined kit: the bytes are checked here, the author's
  ## `applyConfiguration` runs on the module thread.
  if module == nil:
    return failureResult(moduleError("null module context"))
  checkConfigurationBytes(configuration, len, required = true).isOkOr:
    return failureResult(failure(error.code, error.reason))
  var a = ApplyArgs(apply: apply, input: configuration, len: int(len))
  handOff(module.confinedOf, launchApply, addr a, nil)

proc confinedDispatch*(
    module: ptr LogosModuleContext,
    methodName: cstring,
    params: ptr UncheckedArray[uint8],
    paramsLen: csize_t,
    outResponse: ptr ptr UncheckedArray[uint8],
    outResponseLen: ptr csize_t,
    route: ConfinedRoute,
): LogosResult =
  ## [SPEC INTERFACE §2.6, §2.7, App A.3] `_MODULE_dispatch` of a confined kit:
  ## the request is routed on the module thread.
  if outResponse == nil or outResponseLen == nil:
    return failureResult(moduleError("null response outputs"))
  outResponse[] = nil
  outResponseLen[] = 0
  if methodName == nil:
    return failureResult(failure(ecMethodNotFound, "null method"))
  if params == nil and paramsLen != 0:
    return failureResult(failure(ecInvalidParams, "null params with a length"))
  let ctx = module.confinedOf
  var a = DispatchArgs(
    route: route,
    methodName: methodName,
    params: params,
    len: int(paramsLen),
    outResponse: outResponse,
    outResponseLen: outResponseLen,
  )
  handOff(ctx, launchDispatch, addr a, ctx.services.currentContext())

proc confinedCall*(
    module: ptr LogosModuleContext,
    bare: cstring,
    args: pointer,
    request: TypedRequest,
    respond: TypedRespond,
    route: ConfinedRoute,
): LogosResult =
  ## [SPEC INTERFACE §2.4] A typed `_CALL_` function of a confined kit: its C
  ## inputs become request bytes, which take the dispatch route, and the
  ## response becomes its C outputs, all on the module thread. The caller
  ## checked its pointers.
  let ctx = module.confinedOf
  var a =
    TypedArgs(route: route, bare: bare, args: args, request: request, respond: respond)
  handOff(ctx, launchTyped, addr a, ctx.services.currentContext())

proc confinedSubmit*(
    module: ptr LogosModuleContext,
    invocation: ptr LogosProviderInvocation,
    route: ConfinedRoute,
) =
  ## [SPEC INTERFACE §2.9.2; DECISIONS G338] The `submit` of a confined kit's
  ## `_MODULE_async_api`: queues the invocation for the module thread, where
  ## it takes the dispatch route (IFC-0748), and returns; it completes and is
  ## released there. Any thread, the module thread included; never waits; only
  ## the C allocator past the checks.
  if invocation == nil or invocation.abiVersion != AsyncProviderAbiVersion or
      invocation.structSize < csize_t(ProviderInvocationV1Extent) or
      invocation.complete.isNil or invocation.executionRelease.isNil:
    die("submit: a null or malformed provider invocation")
  if module == nil or checkProviderInvocation(invocation).isErr:
    completeNow(invocation, ecModule, "submit: a malformed provider invocation")
    return
  let ctx = module.confinedOf
  let dj = cast[ptr DeferredJob](cCalloc(1, csize_t(sizeof(DeferredJob))))
  if dj == nil:
    completeNow(invocation, ecModule, "out of memory for a submitted invocation")
    return
  dj.job.node.kind = nkJob
  dj.job.ctx = ctx
  dj.job.launch = launchDeferred
  dj.job.invocation = invocation.context
  dj.job.deferred = true
  dj.job.status.messageLen = -1
  dj.job.status.detailLen = -1
  dj.invocation = invocation
  dj.route = route
  dj.refs = 1
  dj.cancelTask.run = runCancel
  acquire(ctx.lock)
  if ctx.stopping:
    release(ctx.lock)
    cFree(dj)
    completeNow(invocation, ecNotReady, "the module is being destroyed")
    return
  ctx.link(dj)
  ctx.enqueue(addr dj.job.node)
  # Under the lock: the module thread closes its signal only after `stopping`.
  fire(ctx.signal)
  release(ctx.lock)

proc confinedRequestCancel*(
    module: ptr LogosModuleContext, invocation: ptr LogosProviderInvocation
) =
  ## [SPEC INTERFACE §2.9.2; DECISIONS G338] The descriptor's
  ## `request_cancel`: finds the invocation among the context's outstanding
  ## ones under its lock, which is the protected reference (IFC-0762), and
  ## returns harmlessly when it is not there (IFC-0763); otherwise marks it
  ## and queues one notice for the module thread, which cancels its `async`
  ## handler's future (IFC-0767). Never waits (IFC-0766). Any thread; no
  ## allocation.
  if module == nil or invocation == nil:
    return
  let ctx = module.confinedOf
  acquire(ctx.lock)
  var dj = ctx.live
  while dj != nil and dj.invocation != invocation:
    dj = dj.next
  if dj != nil:
    dj.cancelRequested = true
    if not dj.cancelQueued and not ctx.closed:
      dj.cancelQueued = true
      inc dj.refs
      dj.cancelTask.node.kind = nkTask
      ctx.enqueue(addr dj.cancelTask.node)
      fire(ctx.signal)
  release(ctx.lock)

proc checkedRequestAt*(
    v: ContractValidator, bare: string, params: ptr UncheckedArray[uint8], len: int
): Result[CborValue, InvocationFailure] =
  ## `checkedRequest` over a borrowed buffer.
  if len == 0:
    v.checkedRequest(bare, [])
  else:
    v.checkedRequest(bare, params.toOpenArray(0, len - 1))

# Invocations -----------------------------------------------------------------------

proc active(inv: Invocation): Result[ptr LogosInvocationContext, InvocationFailure] =
  if inv.isNil or inv.job == nil:
    return err(failure(ecNotReady, "the invocation has ended"))
  let c = inv.job.invocation
  if c == nil:
    return err(failure(ecNotReady, "no active provider entry for this invocation"))
  checkInvocationContext(c).isOkOr:
    return err(moduleError(error.reason))
  ok(c)

proc caller*(inv: Invocation): Result[Caller, InvocationFailure] =
  ## [SPEC INTERFACE §2.9.3] The authenticated origin of `inv`, copied.
  callerAt(?inv.active())

proc isCancelled*(inv: Invocation): bool =
  ## [SPEC INTERFACE §2.9.3] Whether `inv` was cancelled; false once it ended.
  let c = inv.active()
  c.isOk and isCancelledAt(c.unsafeGet)

proc enterPlain*(inv: Invocation): ptr ConfinedScope =
  ## [DECISIONS G336] Sets the confined scope for a plain handler of `inv`'s
  ## job; `leavePlain` puts back the one returned.
  swapConfinedScope(
    if inv.isNil or inv.job == nil:
      nil
    else:
      addr inv.job.scope
  )

proc leavePlain*(saved: ptr ConfinedScope) =
  discard swapConfinedScope(saved)

proc publishScopedEncodedAsync*(
    inv: Invocation, eventId: string, data: seq[byte]
): Future[Result[void, InvocationFailure]] {.async: (raises: []).} =
  ## [SPEC INTERFACE §2.9.3; DECISIONS G337] An `async` handler's
  ## invocation-scoped publication, through the publisher thread with its
  ## invocation's context; completes with the context's status.
  let c = inv.active()
  if c.isErr:
    return Result[void, InvocationFailure].err(c.unsafeError)
  if data.len == 0:
    return Result[void, InvocationFailure].err(
      moduleError("an event payload is one CBOR map")
    )
  let job = inv.job
  let ctx = job.ctx
  if not ctx.onModuleThread:
    return Result[void, InvocationFailure].err(
      failure(ecNotReady, "an Invocation is used on its module's thread")
    )
  let made = newItem(pkScoped, eventId, data)
  if made.isErr:
    return Result[void, InvocationFailure].err(made.unsafeError)
  let item = made.unsafeGet
  item.invocation = c.unsafeGet
  item.job = job
  let reply = newReply()
  item.reply = cast[pointer](reply)
  inc job.inflight
  while not ctx.tryQueue(item, wantRoom = true):
    await ctx.waitRoom()
  await reply

# The services ----------------------------------------------------------------------

proc publishRefusals*(s: ModuleServices): uint64 =
  ## [DECISIONS G337] How many queued events the publish callback refused.
  let ctx = cast[ptr ConfinedObj](s.confinedOf)
  if ctx == nil:
    return 0
  acquire(ctx.pubLock)
  result = ctx.refusals
  release(ctx.pubLock)

proc lastPublishRefusal*(s: ModuleServices): Opt[PublishRefusal] =
  ## [DECISIONS G337] The publish callback's last refusal of a queued event.
  let ctx = cast[ptr ConfinedObj](s.confinedOf)
  if ctx == nil:
    return Opt.none(PublishRefusal)
  acquire(ctx.pubLock)
  if ctx.refusals > 0:
    var name = newString(ctx.refusalLen)
    for i in 0 ..< ctx.refusalLen:
      name[i] = ctx.refusalName[i]
    result = Opt.some(PublishRefusal(rc: ctx.refusalRc, event: name))
  release(ctx.pubLock)

proc poster*(s: ModuleServices): Poster =
  ## [IMPL] What `post` takes for this instance (null for a plain kit).
  Poster(s.confinedOf)

proc post*(p: Poster, fn: PostFn, payload: pointer) =
  ## [IMPL] Runs `fn(payload)` on the module thread. Any thread, one the Nim
  ## runtime never saw included: only the C allocator, and a failure aborts. A
  ## callback still queued at destroy is dropped without running, so `fn`
  ## owns `payload` only once it runs; stop posting before `destroyModule`
  ## returns.
  let ctx = cast[ptr ConfinedObj](p)
  if ctx == nil or fn == nil:
    die("post: a null poster or callback")
  let n = cast[ptr PostNode](cMalloc(csize_t(sizeof(PostNode))))
  if n == nil:
    die("post: out of memory")
  n.node = Node(kind: nkPost)
  n.fn = fn
  n.payload = payload
  acquire(ctx.lock)
  if ctx.closed:
    release(ctx.lock)
    cFree(n)
    return
  ctx.enqueue(addr n.node)
  # Under the lock: the module thread closes its signal only after `closed`.
  fire(ctx.signal)
  release(ctx.lock)

proc postTask(context: pointer, task: ptr TaskNode): bool =
  ## [DECISIONS G339, P1] The confined dispatcher's `post`: queues a task its
  ## owner keeps in C memory for the module thread; false when the task is
  ## counted and the context's delivery bound is reached. A task posted after
  ## the module thread's last drain is dropped here. Any thread; never waits
  ## or allocates.
  let ctx = cast[ptr ConfinedObj](context)
  task.node.kind = nkTask
  acquire(ctx.lock)
  if ctx.closed:
    release(ctx.lock)
    task.run(task, true)
    return true
  if task.counted:
    if ctx.deliveries >= ctx.maxDeliveries:
      release(ctx.lock)
      return false
    inc ctx.deliveries
  ctx.enqueue(addr task.node)
  fire(ctx.signal)
  release(ctx.lock)
  true

proc setDeliveryBound*(s: ModuleServices, events: int) =
  ## [DECISIONS G339, P1] How many events may wait for the module thread's
  ## handlers at once (default 1024); a subscription whose delivery finds the
  ## bound reached ends with `onEnd(MODULE_ERROR)`. For tests and modules that
  ## want less.
  let ctx = cast[ptr ConfinedObj](s.confinedOf)
  if ctx != nil:
    acquire(ctx.lock)
    ctx.maxDeliveries = max(events, 1)
    release(ctx.lock)

proc lcnKitPost(
    poster: pointer, fn: PostFn, payload: pointer
) {.exportc: "lcn_kit_post", cdecl, gcsafe, raises: [].} =
  ## `post` for C code linked into the module library (a Rust staticlib's
  ## threads): `void lcn_kit_post(void *poster, void (*fn)(void *), void *payload)`.
  post(Poster(poster), fn, payload)

proc onItsModuleThread*(s: ModuleServices): bool =
  ## Whether the calling thread is the module thread of `s`'s context.
  cast[ptr ConfinedObj](s.confinedOf).onModuleThread

proc onItsModuleThread*(d: Dispatcher): bool =
  ## Whether `d` is a confined kit's dispatcher and the calling thread its
  ## module thread.
  d.confined and cast[ptr ConfinedObj](d.context).onModuleThread
