## G77(a); TRANSPORT §8.6: the transport I/O thread. One per process, owned by
## the Runtime: it runs a chronos 4.4.1 dispatcher, owns every transport fd,
## and talks to its owner only through values (`api.nim`).
##
## - `submit` (any thread, never blocks): a `Channel` send, then a
##   `ThreadSignalPtr` fire. Commands are handled in channel order.
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

import std/[algorithm, atomics]
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
    thread: Thread[ptr LoopObj]
    config: TransportConfig
    limits: TransportLimits
    sink: IoSink
    ctx: pointer

  Loop* = ptr LoopObj ## A running transport I/O thread.

const StopTick = 5_000_000'i64 ## [IMPL] 5 ms: polling for the end while stopping

var
  current {.threadvar.}: Loop
  onIoThread {.threadvar.}: bool

proc isIoThread*(): bool =
  ## Whether the calling thread is a transport I/O thread.
  onIoThread

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

  proc handle(io: Io, cmd: sink IoCommand) =
    let c = io.conns.getOrDefault(cmd.conn)
    case cmd.kind
    of cmdServe:
      io.serve(cmd)
    of cmdStopServing:
      io.stopServing(cmd.stopEndpoint)
    of cmdAdmit:
      if not c.isNil and c.role == roCallee:
        io.admit(c, cmd.verdict)
    of cmdRespond:
      if not c.isNil:
        io.respond(c, cmd.requestId, cmd.outcome)
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

  var theIo {.threadvar.}: Io

  proc emit(io: Io, ev: sink IoEvent) =
    io.sink(ev, io.ctx)

  proc handle(io: Io, cmd: sink IoCommand) =
    ## [SPEC TRANSPORT §8.2.1] No unix-stream profile here (G107): every
    ## placement and connect fails closed, and no fd is opened.
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

proc drain(lp: Loop, io: Io) =
  while true:
    var got = lp.chan.tryRecv()
    if not got.dataAvailable:
      return
    io.handle(move got.msg)

proc onSignal(arg: pointer) {.gcsafe, raises: [].}

proc armPump(lp: Loop) =
  lp.signal.wait().addCallback(onSignal)

proc onSignal(arg: pointer) {.gcsafe, raises: [].} =
  let lp = current
  let io = theIo
  if lp.isNil or io.isNil:
    return
  lp.drain(io)
  # While stopping, the tick drains instead, so no wait is left pending on the
  # signal when it is closed.
  if not io.stopping:
    lp.armPump()

proc onStopTick(arg: pointer) {.gcsafe, raises: [].} =
  let lp = current
  let io = theIo
  if lp.isNil or io.isNil:
    return
  lp.drain(io)
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
  else:
    let io = Io(sink: lp.sink, ctx: lp.ctx)
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
  lp.drain(io)
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

proc submit*(lp: Loop, cmd: sink IoCommand): SubmitResult =
  ## Queues `cmd` for the I/O thread. Never blocks. `sbStopped` once
  ## `stopTransport` began; `cmdShutdown` is internal.
  if cmd.kind == cmdShutdown:
    return sbStopped
  discard lp.users.fetchAdd(1)
  if lp.stopping.load:
    discard lp.users.fetchSub(1)
    return sbStopped
  lp.chan.send(cmd)
  discard lp.signal.fireSync()
  discard lp.users.fetchSub(1)
  sbOk

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
