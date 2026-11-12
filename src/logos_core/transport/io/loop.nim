## G77(a); TRANSPORT §8.6: the transport I/O thread. One per process, owned by
## the Runtime: it runs a chronos 4.4.1 dispatcher, owns every transport fd,
## and talks to its owner only through values (`api.nim`).
##
## - `submit` (any thread, never blocks): a `Channel` send, then a
##   `ThreadSignalPtr` fire. Commands are handled in channel order, in slices
##   of `DrainSlice`: the I/O that became ready meanwhile (sockets, timers) is
##   served between slices, so a burst of commands does not hold it back.
##   Response and Event payloads count against `maxPendingOutputBytes` from
##   `submit` until committed or discarded (F8): a full budget is `sbBusy`.
## - `submitWait` (not on the I/O thread or an owner thread): `submit`,
##   waiting while the budget is full, up to an optional bound.
## - The sink is called on the I/O thread, in order.
## - `stopTransport` (exactly once, not from the sink): every connection is
##   closed and reported, committed output gets at most `closeLinger`, then
##   `evStopped` is the last event and the thread is joined.
##
## Closing the signal on a thread without a dispatcher would create one, so the
## I/O thread closes it, once no `submit` can still fire it: each `submit` and
## `stopTransport` count themselves in `users` before reading the state, and
## the thread waits for `users` to reach zero after the state changed.

{.push raises: [], gcsafe.}

import std/[algorithm, atomics, monotimes, os, times]
import chronos/[asyncloop, threadsync]
import ../../base/perthread
import ./[api, sock]

when unixStream:
  import chronos/selectors2
  import ./[callee, caller, conn]

export api

type
  LoopObj = object
    chan: Channel[IoCommand]
    signal: ThreadSignalPtr
    stopping: Atomic[bool]
    users: Atomic[int]
    pendingOut: Atomic[int] ## payload bytes submitted and not yet committed
    thread: Thread[ptr LoopObj]
    config: TransportConfig
    limits: TransportLimits
    sink: IoSink
    ctx: pointer

  Loop* = ptr LoopObj ## A running transport I/O thread.

const
  StopTick = 5_000_000'i64 ## [IMPL] 5 ms: polling for the end while stopping
  DrainSlice = 5_000_000'i64
    ## [IMPL] 5 ms of commands (at least one) per turn of the dispatcher

var
  current {.threadvar.}: Loop
  onIoThread {.threadvar.}: bool
  ownerOf {.threadvar.}: Loop
  morePending {.threadvar.}: bool ## a `callSoon(onMore)` is queued

proc isIoThread*(): bool =
  ## Whether the calling thread is a transport I/O thread.
  onIoThread

proc registerOwnerThread*(lp: Loop) =
  ## Marks the calling thread as one the I/O thread's events wait for (the
  ## Runtime thread): `submitWait` refuses to block on it.
  ownerOf = lp

proc unregisterOwnerThread*() =
  ownerOf = nil

func charge(cmd: IoCommand): int =
  ## The payload bytes `cmd` adds to `maxPendingOutputBytes` (F8).
  case cmd.kind
  of cmdRespond:
    if cmd.outcome.ok: cmd.outcome.result.len else: 0
  of cmdPublish, cmdPublishScoped:
    cmd.data.len
  else:
    0

when unixStream:
  proc onFrame(io: Io, c: Conn, body: sink seq[byte]) {.nimcall, gcsafe, raises: [].} =
    case c.role
    of roCallee:
      calleeFrame(io, c, body)
    of roCaller:
      callerFrame(io, c, body)

  proc shutdown(io: Io) =
    io.stopping = true
    var ids: seq[EndpointId]
    for id in io.serves.keys:
      ids.add(id)
    for id in ids:
      io.stopServing(id, closePending = false)
    var conns: seq[Conn]
    for c in io.conns.values:
      conns.add(c)
    conns.sort(
      proc(a, b: Conn): int =
        cmp(a.id, b.id)
    )
    for c in conns:
      io.closeConn(c, ccShutdown, ecTransport)
    io.zombies.clear()
    io.slotWaiters.clear()

  proc handle(io: Io, cmd: sink IoCommand) =
    let c = io.conns.getOrDefault(cmd.conn)
    # A closed callee connection whose work has not ended (A21).
    let z =
      if c.isNil:
        io.zombies.getOrDefault(cmd.conn)
      else:
        c
    case cmd.kind
    of cmdServe:
      io.serve(cmd)
    of cmdStopServing:
      io.stopServing(cmd.stopEndpoint)
    of cmdAdmit:
      if not c.isNil and c.role == roCallee:
        io.admit(c, cmd.verdict)
    of cmdRespond:
      if z.isNil:
        io.uncharge(charge(cmd))
      else:
        io.respond(z, cmd.requestId, cmd.outcome, cmd.workEnded, charge(cmd))
    of cmdWorkEnded:
      if not z.isNil:
        io.workEnded(z, cmd.endedId)
    of cmdSubscriptionResult:
      if not c.isNil:
        io.subscriptionResult(c, cmd.subId, cmd.subFailure)
    of cmdPublish:
      io.publish(cmd)
      io.uncharge(charge(cmd))
    of cmdPublishScoped:
      io.publishScoped(c, cmd)
      io.uncharge(charge(cmd))
    of cmdTerminate:
      if not c.isNil:
        io.terminate(c)
    of cmdSubscribe:
      io.subscribe(c, cmd)
    of cmdUnsubscribe:
      io.unsubscribe(c, cmd)
    of cmdAbandonSubscription:
      io.abandonSubscription(c, cmd.subId)
    of cmdRelease:
      io.release(c, cmd.releaseBytes)
    of cmdConnect:
      var cmd = cmd
      io.connect(cmd)
    of cmdCall:
      io.call(c, cmd)
    of cmdCancel:
      io.cancel(c, cmd.callTag)
    of cmdAbandon:
      io.abandon(c, cmd.callTag)
    of cmdClose:
      if not c.isNil:
        io.closeConn(c, ccOwner)
    of cmdShutdown:
      if not io.stopping:
        io.shutdown()

else:
  type Io = ref object
    sink: IoSink
    ctx: pointer
    stopping: bool
    pendingOut: ptr Atomic[int]

  var theIo {.threadvar.}: Io

  proc emit(io: Io, ev: sink IoEvent) =
    io.sink(ev, io.ctx)

  proc uncharge(io: Io, n: int) =
    if n > 0 and not io.pendingOut.isNil:
      discard io.pendingOut[].fetchSub(n)

  proc handle(io: Io, cmd: sink IoCommand) =
    ## [SPEC TRANSPORT §8.2.1] No unix-stream profile here (G107): every
    ## placement and connect fails closed, and no fd is opened.
    io.uncharge(charge(cmd))
    case cmd.kind
    of cmdServe:
      discard fdClose(cmd.listener)
      io.emit(
        IoEvent(
          kind: evServeFailed,
          failedEndpoint: cmd.endpoint,
          serveError: "unix-stream is not supported on this platform",
        )
      )
    of cmdConnect:
      zeroMem(addr cmd.ticket[0], cmd.ticket.len)
      io.emit(
        IoEvent(
          conn: cmd.conn,
          kind: evConnectFailed,
          failCode: ecTransport,
          failCause: cfUnsupported,
          failMsg: "unix-stream is not supported on this platform",
        )
      )
    of cmdCall:
      io.emit(
        IoEvent(
          conn: cmd.conn,
          kind: evLocalFailure,
          localTag: cmd.tag,
          localCode: ecNotReady,
          localMsg: "no such connection",
        )
      )
    of cmdShutdown:
      io.stopping = true
    else:
      discard

proc drain(lp: Loop, io: Io, slice = high(int64)): bool =
  ## Handles queued commands in channel order for about `slice` nanoseconds,
  ## at least one; true when it stopped with commands possibly left.
  let start = getMonoTime()
  while true:
    var got = lp.chan.tryRecv()
    if not got.dataAvailable:
      return false
    io.handle(move got.msg)
    if (getMonoTime() - start).inNanoseconds >= slice:
      return true

when unixStream:
  proc pumpNow(io: Io) {.nimcall, gcsafe, raises: [].} =
    ## [IMPL] Before a deadline judges a peer (`helloVerdict`, `admitVerdict`):
    ## the commands queued by then are handled, and only those, so an owner
    ## that keeps submitting cannot hold the thread here.
    let lp = current
    if lp.isNil:
      return
    for _ in 0 ..< lp.chan.peek():
      var got = lp.chan.tryRecv()
      if not got.dataAvailable:
        return
      io.handle(move got.msg)

proc onMore(arg: pointer) {.gcsafe, raises: [].}

proc drainSlice(lp: Loop, io: Io) =
  ## [IMPL] One slice; the rest waits for the dispatcher's next turn, after the
  ## timers and the sockets that became ready meanwhile.
  if lp.drain(io, DrainSlice) and not io.stopping and not morePending:
    morePending = true
    callSoon(onMore, nil)

proc onMore(arg: pointer) {.gcsafe, raises: [].} =
  morePending = false
  let lp = current
  let io = theIo
  if lp.isNil or io.isNil:
    return
  lp.drainSlice(io)

proc onSignal(arg: pointer) {.gcsafe, raises: [].}

proc armPump(lp: Loop) =
  lp.signal.wait().addCallback(onSignal)

proc onSignal(arg: pointer) {.gcsafe, raises: [].} =
  let lp = current
  let io = theIo
  if lp.isNil or io.isNil:
    return
  lp.drainSlice(io)
  # While stopping, the tick drains instead, so no wait is left pending on the
  # signal when it is closed.
  if not io.stopping:
    lp.armPump()

proc onStopTick(arg: pointer) {.gcsafe, raises: [].} =
  let lp = current
  let io = theIo
  if lp.isNil or io.isNil:
    return
  discard lp.drain(io)
  discard setTimer(Moment.fromNow(nanoseconds(StopTick)), onStopTick)

proc finished(lp: Loop, io: Io): bool =
  when unixStream:
    io.stopping and io.byKey.len == 0 and lp.users.load == 0
  else:
    io.stopping and lp.users.load == 0

proc run(lp: Loop) =
  ## Every `ref` of the loop lives in this frame and dies when it returns,
  ## before the dispatcher is torn down and cycles are collected.
  when unixStream:
    let io = newIo(lp.config, lp.limits, lp.sink, lp.ctx)
    io.onFrame = onFrame
    io.pumpCommands = pumpNow
  else:
    let io = Io(sink: lp.sink, ctx: lp.ctx)
  io.pendingOut = addr lp.pendingOut
  theIo = io
  current = lp
  lp.armPump()
  var ticking = false
  while not lp.finished(io):
    poll()
    if io.stopping and not ticking:
      ticking = true
      discard setTimer(Moment.fromNow(nanoseconds(StopTick)), onStopTick)
  # Commands sent before the last `submit` returned: handled in stopping mode,
  # so each still gets its failure event.
  discard lp.drain(io)
  io.emit(IoEvent(kind: evStopped))
  theIo = nil
  current = nil

proc teardown(lp: Loop) =
  discard lp.signal.close()
  let disp = getThreadDispatcher()
  when unixStream:
    discard disp.getIoHandler().close2()
  disp.callbacks.clear()
  setThreadDispatcher(nil)

proc ioThread(lp: Loop) {.thread.} =
  onIoThread = true
  lp.run()
  lp.teardown()
  releasePerThread()

proc startTransport*(
    config: TransportConfig, sink: IoSink, ctx: pointer = nil
): Result[Loop, string] =
  ## Validates `config` and starts the I/O thread. `sink` receives every event
  ## on that thread.
  ?config.validate()
  let limits = ?config.connLimits()
  let signal = ?ThreadSignalPtr.new()
  let lp = createShared(LoopObj)
  lp.chan.open()
  lp.signal = signal
  lp.config = config
  lp.limits = limits
  lp.sink = sink
  lp.ctx = ctx
  try:
    createThread(lp.thread, ioThread, lp)
  except ResourceExhaustedError as e:
    discard signal.close()
    lp.chan.close()
    deallocShared(lp)
    return err("the transport I/O thread could not start: " & e.msg)
  ok(lp)

proc reserveOutput(lp: Loop, n: int): bool =
  ## [SPEC TRANSPORT §5.2, §8.6] Counts `n` payload bytes against
  ## `maxPendingOutputBytes`. A payload larger than the whole budget passes
  ## when nothing else is pending, so it is never refused forever [IMPL].
  if n <= 0:
    return true
  var cur = lp.pendingOut.load
  while true:
    if cur > 0 and cur + n > lp.config.maxPendingOutputBytes:
      return false
    if lp.pendingOut.compareExchange(cur, cur + n):
      return true

proc trySubmit(lp: Loop, cmd: var IoCommand): SubmitResult =
  if cmd.kind == cmdShutdown:
    return sbStopped
  discard lp.users.fetchAdd(1)
  if lp.stopping.load:
    discard lp.users.fetchSub(1)
    return sbStopped
  let n = charge(cmd)
  if not lp.reserveOutput(n):
    discard lp.users.fetchSub(1)
    return sbBusy
  lp.chan.send(move cmd)
  discard lp.signal.fireSync()
  discard lp.users.fetchSub(1)
  sbOk

proc submit*(lp: Loop, cmd: sink IoCommand): SubmitResult =
  ## Queues `cmd` for the I/O thread. Never blocks. `sbBusy` when its payload
  ## does not fit `maxPendingOutputBytes`; `sbStopped` once `stopTransport`
  ## began. `cmdShutdown` is internal.
  var cmd = cmd
  lp.trySubmit(cmd)

proc submitWait*(
    lp: Loop, cmd: sink IoCommand, timeout = Opt.none(int64)
): SubmitResult =
  ## [SPEC TRANSPORT §5.2 l.806-807] `submit`, waiting while
  ## `maxPendingOutputBytes` is full: up to `timeout` nanoseconds, then
  ## `sbBusy`; without a timeout the wait has no finite bound. `sbRefused` on
  ## the I/O thread or a registered owner thread, whose waiting could keep the
  ## budget from draining.
  if onIoThread or (not ownerOf.isNil and ownerOf == lp):
    return sbRefused
  var cmd = cmd
  let start = getMonoTime()
  while true:
    let r = lp.trySubmit(cmd)
    if r != sbBusy:
      return r
    if timeout.isSome and (getMonoTime() - start).inNanoseconds >= timeout.get:
      return sbBusy
    sleep(1) # [IMPL] 1 ms between attempts

proc stopTransport*(lp: Loop) =
  ## Stops the I/O thread, waits for `evStopped`, joins it and frees the loop.
  ## Call exactly once, never from the sink or the I/O thread.
  discard lp.users.fetchAdd(1)
  if not lp.stopping.exchange(true):
    lp.chan.send(IoCommand(kind: cmdShutdown))
    discard lp.signal.fireSync()
  discard lp.users.fetchSub(1)
  joinThread(lp.thread)
  lp.chan.close()
  deallocShared(lp)
