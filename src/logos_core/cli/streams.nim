## lcn_call's streams (Tier 5 step N-2c; DECISIONS G349; plan §3.7): the queue
## between a subscription's handler and the command's writer, and the ends that
## stop a stream. `commands.nim` runs `subscribe` and `events` on them.
## docs/DAEMON.md §7a.
##
## - **Delivery.** The binding runs `onEvent` on its own thread. It copies the
##   borrowed payload (IF l.1414) into the stream's queue and wakes the writer,
##   the worker thread serving the command, which renders and writes it; the
##   handler never waits for the launcher's terminal. The queue holds 1024
##   events or 16 MiB, whichever comes first, and always one event whatever
##   its size. A full queue ends the stream
##   ("the terminal did not keep up") and wakes a writer blocked on the
##   terminal (`abortFd`): dropping one event would lose it unseen, which a
##   binding may not do either (IF l.1472).
## - **Ends.** A route handle's end and a binding-ended subscription on it come
##   through the route table's end hook (`routes.nim`); a binding-ended Runtime
##   Control subscription through the binding's `observe_subscription_end`,
##   registered once at `_MODULE_init` (`register`). A subscription identifier
##   is scoped to its handle (IF l.3367), so the hub finds a stream by handle,
##   or binding, and identifier. An end marks the stream ended and wakes its
##   writer, which first writes what was queued. Neither callback operates on a
##   handle or binding (IF l.1480).
## - **Lifetime.** The hub is never freed: the Runtime Control binding may
##   report an end until its release, which follows `_MODULE_destroy`. A stream
##   leaves the hub when its command ends, and is freed once no handler of it
##   can run: after an `unsubscribe` that returned LOGOS_OK, or with its
##   handle (`routes.keepUntilRelease`; IF l.1436-1438).
## - **Locks.** The hub's, then a stream's. A callback takes no other lock, and
##   no lock here is held across a binding operation.

{.push raises: [], gcsafe.}

import std/locks
import results
import logos_sdk/abi/types
from logos_sdk/base/entry import lcnCallback

when defined(posix):
  import std/posix

export results

const
  MaxQueued* = 1024 ## [G349] events queued for one stream
  MaxQueuedBytes* = 16 * 1024 * 1024 ## [G349] their payload bytes
  MaxNames* = 16 ## [G349] subscriptions in one stream (`events`' names)
  MaxOpen = 128 ## [IMPL] streams open at once; `cli.streams` is at most 64
  NoId = high(LogosSubscriptionId) ## before `subscribe` writes the identifier

type
  EndKind* = enum
    ekNone
    ekRoute ## the route handle ended (IF l.1430-1433)
    ekSubscription ## the binding ended a subscription (IF l.1474-1481)
    ekOverflow ## the queue was full

  Ending* = object ## How a stream ended.
    kind*: EndKind
    reason*: CErrorCode ## the binding's reason; 0 for `ekOverflow`

  Item = object
    data: ptr UncheckedArray[byte]
    len: int
    name: int

  SubCtx = object ## One subscription's handler state.
    stream: ptr StreamObj
    name: int

  StreamObj = object
    lock: Lock
    key: pointer ## the route handle (`Lease.handle`) or the binding
    names: int
    ctx: array[MaxNames, SubCtx]
    ids: array[MaxNames, LogosSubscriptionId]
    live: array[MaxNames, bool] ## `ids[i]` is, or will be, this stream's
    ring: ptr UncheckedArray[Item]
    head, count, bytes: int
    ended: Ending
    wakeR, wakeW: cint ## a byte per wake, read by the writer
    abortR, abortW: cint ## written once, when the queue overflows

  Stream* = ptr StreamObj

  HubObj = object
    lock: Lock
    rc: pointer ## the Runtime Control binding: the key of `events`' streams
    open: array[MaxOpen, Stream]

  Hub* = ptr HubObj

  Event* = object ## One queued event, for the writer.
    name*: int ## the index of its subscription
    data*: seq[byte]

# Pipes -------------------------------------------------------------------------------------

proc pipePair(r, w: var cint): bool =
  ## A close-on-exec, non-blocking pipe.
  when defined(posix):
    var fds: array[2, cint]
    if pipe(fds) != 0:
      return false
    for f in fds:
      discard fcntl(f, F_SETFD, FD_CLOEXEC)
      discard fcntl(f, F_SETFL, fcntl(f, F_GETFL) or O_NONBLOCK)
    r = fds[0]
    w = fds[1]
    true
  else:
    false

proc poke(fd: cint) =
  ## One byte; a full pipe already wakes its reader.
  when defined(posix):
    var b = 1'u8
    discard posix.write(fd, addr b, 1)

# The hub -----------------------------------------------------------------------------------

proc newHub*(rc: ptr LogosRuntimeControlBinding): Hub =
  ## [IMPL] One per `_MODULE_init`, never freed (see the module's doc).
  result = cast[Hub](allocShared0(sizeof(HubObj)))
  initLock(result.lock)
  result.rc = rc

proc noteEnd(h: Hub, key: pointer, sub: Opt[LogosSubscriptionId], reason: CErrorCode) =
  ## A route handle's end (`sub` none) or a binding-ended subscription: every
  ## stream on `key` that it ends is marked and woken.
  withLock h.lock:
    for s in h.open:
      if s == nil or s.key != key:
        continue
      withLock s.lock:
        var hit = sub.isNone
        if sub.isSome:
          for i in 0 ..< s.names:
            if s.live[i] and s.ids[i] == sub.get:
              hit = true
        if hit and s.ended.kind == ekNone:
          s.ended =
            Ending(kind: (if sub.isNone: ekRoute else: ekSubscription), reason: reason)
          poke(s.wakeW)

proc routeEnd*(
    handle: pointer, sub: Opt[LogosSubscriptionId], reason: CErrorCode, data: pointer
) {.nimcall, gcsafe, raises: [].} =
  ## The route table's end hook (`routes.setEndHook`), with the hub as `data`.
  cast[Hub](data).noteEnd(handle, sub, reason)

proc onRcSubscriptionEnd(
    sub: LogosSubscriptionId, reason: CErrorCode, userData: pointer
) {.lcnCallback.} =
  ## [SPEC INTERFACE l.1474-1481] A binding-ended Runtime Control subscription.
  let h = cast[Hub](userData)
  h.noteEnd(h.rc, Opt.some(sub), reason)

proc register*(h: Hub): LogosResult =
  ## [SPEC INTERFACE l.1476-1477] The Runtime Control binding's one
  ## `observe_subscription_end` registration, before any subscription.
  let rc = cast[ptr LogosRuntimeControlBinding](h.rc)
  rc.vtable.observeSubscriptionEnd(rc, onRcSubscriptionEnd, h)

# A stream ----------------------------------------------------------------------------------

proc freeStream*(data: pointer) {.nimcall, gcsafe, raises: [].} =
  ## Frees a stream no handler can reach any more (`routes.FreeProc`).
  let s = cast[Stream](data)
  if s.ring != nil:
    for i in 0 ..< s.count:
      let it = s.ring[(s.head + i) mod MaxQueued]
      if it.data != nil:
        deallocShared(it.data)
    deallocShared(s.ring)
  when defined(posix):
    for fd in [s.wakeR, s.wakeW, s.abortR, s.abortW]:
      if fd >= 0:
        discard posix.close(fd)
  deinitLock(s.lock)
  deallocShared(s)

proc open*(h: Hub, key: pointer, names: int): Result[Stream, string] =
  ## A stream of `names` subscriptions on `key` (a lease's `handle`, or the
  ## binding), listed in the hub before any `subscribe`.
  if names < 1 or names > MaxNames:
    return err("a stream has 1 to " & $MaxNames & " subscriptions")
  let s = cast[Stream](allocShared0(sizeof(StreamObj)))
  initLock(s.lock)
  s.wakeR = -1
  s.wakeW = -1
  s.abortR = -1
  s.abortW = -1
  s.ring = cast[ptr UncheckedArray[Item]](allocShared0(sizeof(Item) * MaxQueued))
  if not pipePair(s.wakeR, s.wakeW) or not pipePair(s.abortR, s.abortW):
    freeStream(s)
    return err("lcn_call cannot open a pipe for the stream")
  s.key = key
  s.names = names
  for i in 0 ..< names:
    s.ctx[i] = SubCtx(stream: s, name: i)
    s.ids[i] = NoId
  var placed = false
  withLock h.lock:
    for slot in h.open.mitems:
      if slot == nil:
        slot = s
        placed = true
        break
  if not placed:
    freeStream(s)
    return err("lcn_call has too many streams open")
  ok(s)

proc detach*(h: Hub, s: Stream) =
  ## Out of the hub: no end callback reaches `s` once this returns.
  withLock h.lock:
    for slot in h.open.mitems:
      if slot == s:
        slot = nil

proc onEvent(
    eventName: cstring,
    cborData: ptr UncheckedArray[uint8],
    cborDataLen: csize_t,
    userData: pointer,
) {.lcnCallback.} =
  ## [SPEC INTERFACE l.1412-1414] Copies the borrowed payload into the queue
  ## and wakes the writer; never waits for it.
  let c = cast[ptr SubCtx](userData)
  let s = c.stream
  let n = int(cborDataLen)
  var wake = false
  withLock s.lock:
    if s.ended.kind == ekNone:
      # One event is always taken: a single one larger than the bound is the
      # provider's to send, not a terminal falling behind.
      if s.count >= MaxQueued or (s.count > 0 and s.bytes + n > MaxQueuedBytes):
        s.ended = Ending(kind: ekOverflow)
        poke(s.abortW)
      else:
        var p: ptr UncheckedArray[byte] = nil
        if n > 0:
          p = cast[ptr UncheckedArray[byte]](allocShared(n))
          copyMem(p, cborData, n)
        s.ring[(s.head + s.count) mod MaxQueued] = Item(data: p, len: n, name: c.name)
        inc s.count
        s.bytes += n
      wake = true
  if wake:
    poke(s.wakeW)

func handler*(): LogosEventHandler =
  ## The handler every stream subscribes with.
  onEvent

proc userData*(s: Stream, i: int): pointer =
  ## Subscription `i`'s handler state.
  addr s.ctx[i]

proc idSlot*(s: Stream, i: int): ptr LogosSubscriptionId =
  ## Where `subscribe` writes subscription `i`'s identifier. The binding
  ## writes it before activation (IF l.1395), so an end reported before
  ## `subscribe` returns still finds the stream.
  withLock s.lock:
    s.live[i] = true
  addr s.ids[i]

proc settle*(s: Stream, i: int, subscribed: bool) =
  ## After `subscribe`: a failed one names no subscription (IF l.1400).
  if not subscribed:
    withLock s.lock:
      s.live[i] = false
      s.ids[i] = NoId

proc id*(s: Stream, i: int): LogosSubscriptionId =
  withLock s.lock:
    result = s.ids[i]

proc markEnded*(s: Stream, kind: EndKind, reason: CErrorCode) =
  ## An end the writer found itself (a route that ended before the stream was
  ## listed).
  withLock s.lock:
    if s.ended.kind == ekNone:
      s.ended = Ending(kind: kind, reason: reason)
  poke(s.wakeW)

proc ending*(s: Stream): Ending =
  withLock s.lock:
    result = s.ended

proc abortFd*(s: Stream): cint =
  ## Readable once the queue has overflowed: a write to the terminal stops.
  s.abortR

proc take*(s: Stream): seq[Event] =
  ## Everything queued, oldest first.
  withLock s.lock:
    for i in 0 ..< s.count:
      let it = s.ring[(s.head + i) mod MaxQueued]
      var e = Event(name: it.name, data: newSeq[byte](it.len))
      if it.len > 0:
        copyMem(addr e.data[0], it.data, it.len)
        deallocShared(it.data)
      result.add(e)
    s.head = (s.head + s.count) mod MaxQueued
    s.count = 0
    s.bytes = 0

proc wait*(s: Stream, cancelFd: cint, timeoutMs: int): bool =
  ## Until an event or an end wakes the stream, the launcher cancels (false),
  ## or `timeoutMs` passes (-1: no limit).
  when defined(posix):
    var p: array[2, TPollfd]
    p[0] = TPollfd(fd: cancelFd, events: POLLIN)
    p[1] = TPollfd(fd: s.wakeR, events: POLLIN)
    let n = poll(addr p[0], 2, cint(timeoutMs))
    if n > 0 and (p[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
      return false
    var buf: array[64, byte]
    while posix.read(s.wakeR, addr buf[0], buf.len) > 0:
      discard
    true
  else:
    false

{.pop.}
