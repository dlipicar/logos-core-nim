## TRANSPORT §2.1, §2.3, §3.2, §8.6; G77(a): one connection's framed reading and
## writing over a raw non-blocking unix-stream fd, driven by the chronos
## dispatcher of the transport I/O thread, and the loop-wide byte pools. Only
## the I/O thread touches anything here.
##
## Every chronos callback gets a connection's `key` as its argument, never the
## `ref`: keys are never reused, so a callback still queued for a connection
## closed earlier in the same dispatcher step finds nothing and returns.
##
## Reading [IMPL]: the 4-byte prefix, then `parsePrefix` against the frame
## limit, then the body's bytes are reserved from an input pool (the pre-Hello
## pool until establishment) before the body is allocated and read (TRANSPORT
## §8.6). Frames are handled one at a time, in order (§2.1): the next is read
## only after the previous one's handler returned and no hold remains.
##
## Writing [IMPL]: one ordered queue per connection. A frame is committed when
## it is appended (§2.1, §5.2). Data frames (ok-Responses, Requests) need room
## in the connection's data budget (`connOutputBytes - controlReserve`) and in
## `maxOutputBytes`; control frames use that room when there is some, else the
## connection's control reserve. A final ProtocolError is never refused.

{.push raises: [], gcsafe.}

import std/[algorithm, deques, sets, tables]
import chronos/[asyncloop, timer]
import results
import ../../cbor
import ../../iface/[outcome, surface]
import ../[boundary, envelope, framing, session]
import ./[api, aggregate, sock]

export deques, sets, tables, timer, api, aggregate, session

type
  Outcome = outcome.Outcome ## `commitment/choice` exports another `Outcome`

  Role* = enum
    roCallee
    roCaller

  Phase* = enum
    phConnecting ## caller: `connect` in progress; nothing read or written
    phHello
      ## callee: awaiting the first frame; caller: the Hello is committed and
      ## the response awaited
    phAdmitting ## callee: `evHello` sent, `cmdAdmit` awaited; nothing read
    phOpen ## established
    phLinger ## closed and reported; flushing the frames already committed
    phDone ## the fd is closed

  Hold* = enum
    ## Why reading is paused. Input is never read and dropped (§8.6).
    hAdmit ## callee: the admission verdict is awaited (one frame at a time)
    hBytes ## a frame waits for room in an input pool
    hSession ## the session admits no input now (`maxInFlight`)

  FrameClass* = enum
    fcControl ## error Responses, SubscriptionResults, Cancel, the Hello frames
    fcData ## ok-Responses and Requests

  OutFrame = object
    data: seq[byte] ## prefix and body
    pooled: int ## charged to the data budget and `maxOutputBytes`
    reserve: int ## charged to the control reserve
    secret: bool ## holds a route ticket: zeroed once written or dropped

  PendingResponse = object
    ## An ok-Response that found no room: not committed, so a Cancel processed
    ## meanwhile commits CANCELLED and this one is discarded (§6). It holds the
    ## response value, not an `Outcome`: a moved `Outcome` meets the
    ## `=wasMoved` fault noted at `IoCommandKind`.
    id: uint64
    response: CborValue
    size: int ## an upper bound of its frame, prefix included

  Conn* = ref object
    key*: uint64
    id*: ConnId
    fd*: cint
    role*: Role
    phase*: Phase
    holds*: set[Hold]
    reading, registered: bool
    writing*: bool
    # input
    prefix: array[4, byte]
    prefixGot: int
    body: seq[byte]
    bodyGot: int
    want: int ## the body length being read; -1 while reading a prefix
    reserved: int ## input-pool bytes held for `body`
    helloPool: bool ## `reserved` came from the pre-Hello pool
    # output
    outq: Deque[OutFrame]
    outOff: int ## bytes of the first frame already written
    dataBytes: int
    reserveBytes: int
    pending: Deque[PendingResponse]
    outWaiting: bool ## in `outWaiters`
    writeFailed*: bool
    lastProgress: Moment
    stallTimer, helloTimer, admitTimer, lingerTimer*, retryTimer*: TimerCallback
    deadline*: Moment ## the end of the Hello exchange
    # callee
    endpoint*: EndpointId
    peer*: Opt[PeerCred]
    callee*: CalleeConn
    dispatched*: HashSet[uint64]
      ## Requests handed to the owner with no Response or CANCELLED committed
    pendingHello*: bool ## counted in `pendingHellos`
    inbound*: bool ## counted in `inbound`
    # caller
    caller*: CallerConn
    outboundCounted*: bool
    expected*: PeerIdentity
    path*: string
    sent*: Hello ## the module and schema of the Hello; its token is always empty
    selected*: Boundary
    firstId*: uint64
    hello*: seq[byte] ## the encoded Hello, until committed; zeroed with it
    toWire*: Table[uint64, uint64] ## call tag -> Request id
    toTag*: Table[uint64, uint64] ## Request id -> call tag
    connected*: bool ## `evConnected` was sent

  Serve* = ref object
    key*: uint64
    id*: EndpointId
    fd*: cint
    served*: CalleeEndpoint
    contracts*: ContractSet
    boundaries*: Table[Digest, Boundary] ## by selected contract

  ConnectFail* = object ## How a caller's connection failed before establishment.
    code*: ErrorCode
    cause*: ConnectFailure
    msg*: string ## never the ticket
    observed*: Opt[PeerCred]

  FrameHandler* =
    proc(io: Io, c: Conn, body: sink seq[byte]) {.nimcall, gcsafe, raises: [].}

  Io* = ref object
    config*: TransportConfig
    limits*: TransportLimits
    sink: IoSink
    ctx: pointer
    nextKey: uint64
    nextAccepted*: uint64
    conns*: Table[ConnId, Conn] ## open connections, by the owner's id
    byKey*: Table[uint64, Conn] ## open and lingering connections
    serves*: Table[EndpointId, Serve]
    serveByKey*: Table[uint64, Serve]
    selected*: Table[Digest, Boundary] ## the callers' selected contracts
    helloPool*, inputPool*, outputPool*: BytePool
    helloWaiters, inputWaiters: Deque[uint64] ## connection keys, FIFO
    outWaiters: Deque[uint64] ## connections with ok-Responses waiting for the pool
    inbound*, pendingHellos*, outbound*: int
    onFrame*: FrameHandler
    responseOverhead: int
    requestOverhead*: int
      ## an upper bound of a Request's frame less its method name and params
    stopping*: bool

var theIo* {.threadvar.}: Io ## the I/O thread's state; nil elsewhere

# Basics ----------------------------------------------------------------------------

proc newIo*(
    config: TransportConfig, limits: TransportLimits, sink: IoSink, ctx: pointer
): Io =
  # The frame of an ok-Response whose result map is empty, with the largest id:
  # each byte of a result map then adds exactly one.
  let probe = Message(
    kind: mkResponse,
    response: Response(id: high(uint64), ok: true, resultMap: cborMap()),
  )
  # A Request with an empty method name and params; a text header grows by at
  # most 8 bytes.
  let req = Message(
    kind: mkRequest,
    request: Request(id: high(uint64), methodName: "", params: cborMap()),
  )
  Io(
    config: config,
    limits: limits,
    sink: sink,
    ctx: ctx,
    nextKey: 1,
    nextAccepted: AcceptedConnBase,
    helloPool: bytePool(config.maxHelloInputBytes),
    inputPool: bytePool(config.maxInputBytes),
    outputPool: bytePool(config.maxOutputBytes),
    responseOverhead: encodeCbor(toCbor(probe)).len - 1 + 4,
    requestOverhead: encodeCbor(toCbor(req)).len - 1 + 4 + 8,
  )

proc emit*(io: Io, ev: sink IoEvent) =
  io.sink(ev, io.ctx)

proc newKey*(io: Io): uint64 =
  result = io.nextKey
  inc io.nextKey

func keyArg*(key: uint64): pointer =
  cast[pointer](key)

func argKey*(arg: pointer): uint64 =
  cast[uint64](arg)

proc fromNow(ns: int64): Moment =
  Moment.fromNow(nanoseconds(ns))

proc cancelTimer(t: var TimerCallback) =
  if not t.isNil:
    clearTimer(t)
    t = nil

func protocolErrorBody*(code: ErrorCode): seq[byte] =
  ## [SPEC TRANSPORT §1.3, §2.3] A ProtocolError without message or detail.
  encodeCbor(
    toCbor(Message(kind: mkProtocolError, protocolError: InvocationFailure(code: code)))
  )

func framed*(body: openArray[byte]): seq[byte] =
  result = newSeqUninit[byte](body.len + 4)
  let p = prefixOf(body.len)
  for i in 0 .. 3:
    result[i] = p[i]
  if body.len > 0:
    copyMem(addr result[4], unsafeAddr body[0], body.len)

proc zero*(s: var seq[byte]) =
  if s.len > 0:
    zeroMem(addr s[0], s.len)

proc newConn*(io: Io, id: ConnId, role: Role, fd: cint): Conn =
  Conn(key: io.newKey(), id: id, role: role, fd: fd, want: -1)

proc track*(io: Io, c: Conn) =
  io.conns[c.id] = c
  io.byKey[c.key] = c

proc lookup*(io: Io, key: uint64): Conn =
  io.byKey.getOrDefault(key)

proc established*(c: Conn): bool =
  c.phase == phOpen

proc closed*(c: Conn): bool =
  c.phase in {phLinger, phDone}

proc register*(c: Conn): bool =
  ## Registers the fd with the dispatcher once.
  if not c.registered:
    if register2(AsyncFD(c.fd)).isErr:
      return false
    c.registered = true
  true

# Forward declarations --------------------------------------------------------------

proc closeConn*(
  io: Io,
  c: Conn,
  cause: CloseCause,
  code = ecOk,
  final = Opt.none(seq[byte]),
  ids: seq[uint64] = @[],
  failure = Opt.none(ConnectFail),
)

proc finalClose*(io: Io, c: Conn)
proc updateReading*(io: Io, c: Conn)
proc updateWriting(io: Io, c: Conn)
proc drainPending(io: Io, c: Conn)

# Input pools -----------------------------------------------------------------------

proc pool(io: Io, hello: bool): var BytePool =
  if hello:
    return io.helloPool
  io.inputPool

proc wakeWaiters(io: Io, hello: bool) =
  ## Grants waiting frames their bytes in arrival order; the first one that
  ## does not fit keeps the others waiting (no starvation of large frames).
  while true:
    let q =
      if hello:
        addr io.helloWaiters
      else:
        addr io.inputWaiters
    if q[].len == 0:
      return
    let c = io.lookup(q[].peekFirst)
    if c.isNil or c.closed or hBytes notin c.holds or c.helloPool != hello:
      discard q[].popFirst
      continue
    if not io.pool(hello).tryReserve(c.want):
      return
    discard q[].popFirst
    c.reserved = c.want
    c.body = newSeqUninit[byte](c.want)
    c.holds.excl(hBytes)
    cancelTimer(c.admitTimer)
    io.updateReading(c)

proc releaseInput(io: Io, n: int, hello: bool) =
  if n > 0:
    io.pool(hello).release(n)
    io.wakeWaiters(hello)

proc onAdmitTimeout(arg: pointer) {.gcsafe, raises: [].} =
  ## [SPEC TRANSPORT §8.6] A frame waited `admissionTimeout` for input bytes.
  let io = theIo
  if io.isNil:
    return
  let c = io.lookup(argKey(arg))
  if c.isNil or c.closed or hBytes notin c.holds:
    return
  c.admitTimer = nil
  io.closeConn(c, ccProtocol, ecTransport, Opt.some(protocolErrorBody(ecTransport)))

proc reserveInput(io: Io, c: Conn): bool =
  ## Reserves the declared body before it is allocated; false when the frame
  ## must wait for room (reading is paused meanwhile).
  c.helloPool = not c.established
  if c.want == 0:
    c.body = @[]
    return true
  let q =
    if c.helloPool:
      addr io.helloWaiters
    else:
      addr io.inputWaiters
  if q[].len == 0 and io.pool(c.helloPool).tryReserve(c.want):
    c.reserved = c.want
    c.body = newSeqUninit[byte](c.want)
    return true
  c.holds.incl(hBytes)
  q[].addLast(c.key)
  if c.established:
    # Before establishment the Hello deadline bounds the wait.
    c.admitTimer =
      setTimer(fromNow(io.config.admissionTimeout), onAdmitTimeout, keyArg(c.key))
  false

# Reading ---------------------------------------------------------------------------

proc onReadable(arg: pointer) {.gcsafe, raises: [].}

proc readable(c: Conn): bool =
  c.phase in {phHello, phAdmitting, phOpen} and c.holds.len == 0 and not c.closed

proc updateReading*(io: Io, c: Conn) =
  let want = c.readable and c.registered
  if want and not c.reading:
    if addReader2(AsyncFD(c.fd), onReadable, keyArg(c.key)).isOk:
      c.reading = true
  elif not want and c.reading:
    discard removeReader2(AsyncFD(c.fd))
    c.reading = false

proc inputEnded(io: Io, c: Conn) =
  ## [SPEC TRANSPORT §3.2] End of input or a read error: connection loss.
  io.closeConn(c, ccPeerClosed, ecTransport)

proc readSome(io: Io, c: Conn) =
  while c.readable:
    if c.want < 0:
      let r = sockRecv(c.fd, addr c.prefix[c.prefixGot], csize_t(4 - c.prefixGot))
      if r <= 0:
        if wouldBlock(r):
          break
        io.inputEnded(c)
        return
      c.prefixGot += int(r)
      if c.prefixGot < 4:
        continue
      c.prefixGot = 0
      let n = parsePrefix(c.prefix, io.config.frameLimit).valueOr:
        # [SPEC TRANSPORT §2.1, §8.3] The body is neither allocated nor read.
        io.closeConn(
          c, ccProtocol, ecInvalidParams, Opt.some(protocolErrorBody(ecInvalidParams))
        )
        return
      c.want = int(n)
      c.bodyGot = 0
      if not io.reserveInput(c):
        break
    if c.bodyGot < c.want:
      let r = sockRecv(c.fd, addr c.body[c.bodyGot], csize_t(c.want - c.bodyGot))
      if r <= 0:
        if wouldBlock(r):
          break
        io.inputEnded(c)
        return
      c.bodyGot += int(r)
      if c.bodyGot < c.want:
        continue
    var body = move c.body
    c.body = @[]
    c.want = -1
    c.bodyGot = 0
    let held = c.reserved
    let hello = c.helloPool
    c.reserved = 0
    io.onFrame(io, c, move body)
    io.releaseInput(held, hello)
  io.updateReading(c)

proc onReadable(arg: pointer) {.gcsafe, raises: [].} =
  let io = theIo
  if io.isNil:
    return
  let c = io.lookup(argKey(arg))
  if c.isNil or c.closed:
    return
  io.readSome(c)

proc hold*(io: Io, c: Conn, h: Hold) =
  c.holds.incl(h)
  io.updateReading(c)

proc unhold*(io: Io, c: Conn, h: Hold) =
  ## Resumes reading; bytes already buffered by the kernel make the reader fire.
  c.holds.excl(h)
  io.updateReading(c)

# Writing ---------------------------------------------------------------------------

proc onWritable(arg: pointer) {.gcsafe, raises: [].}

proc onStall(arg: pointer) {.gcsafe, raises: [].}

proc armStall(io: Io, c: Conn) =
  if c.stallTimer.isNil:
    c.stallTimer = setTimer(
      c.lastProgress + nanoseconds(io.config.writeStallTimeout), onStall, keyArg(c.key)
    )

proc updateWriting(io: Io, c: Conn) =
  let want = c.outq.len > 0 and not c.writeFailed and c.registered and c.phase != phDone
  if want and not c.writing:
    if addWriter2(AsyncFD(c.fd), onWritable, keyArg(c.key)).isOk:
      c.writing = true
  elif not want and c.writing:
    discard removeWriter2(AsyncFD(c.fd))
    c.writing = false
  if want:
    io.armStall(c)
  else:
    cancelTimer(c.stallTimer)

proc dropFrame(io: Io, c: Conn, f: var OutFrame) =
  if f.secret:
    zero(f.data)
  if f.pooled > 0:
    c.dataBytes -= f.pooled
    io.outputPool.release(f.pooled)
  c.reserveBytes -= f.reserve

proc dropOutput(io: Io, c: Conn) =
  while c.outq.len > 0:
    var f = c.outq.popFirst
    io.dropFrame(c, f)
  c.outOff = 0

proc wakeOutput(io: Io) =
  ## Connections whose ok-Responses wait for `maxOutputBytes`, in order.
  var n = io.outWaiters.len
  while n > 0 and io.outWaiters.len > 0:
    dec n
    let c = io.lookup(io.outWaiters.popFirst)
    if not c.isNil:
      c.outWaiting = false
      if c.established:
        io.drainPending(c)

proc writeFailedAt(io: Io, c: Conn) =
  ## [SPEC TRANSPORT §3.2] A write error. In the caller's Hello phase the
  ## callee may already have written its ProtocolError and closed (a callee at
  ## its connection cap does not read): keep reading what is queued, bounded by
  ## the Hello deadline, before classifying (F7). Otherwise the peer is not
  ## writable: close without a ProtocolError.
  c.writeFailed = true
  io.dropOutput(c)
  io.updateWriting(c)
  if c.role == roCaller and not c.connected and not c.closed:
    return
  if c.phase == phLinger:
    io.finalClose(c)
  else:
    io.closeConn(c, ccNotWritable, ecTransport)

proc flush(io: Io, c: Conn) =
  var released = false
  while c.outq.len > 0:
    let r = block:
      let f = addr c.outq[0]
      sockSend(c.fd, addr f.data[c.outOff], csize_t(f.data.len - c.outOff))
    if r < 0:
      if wouldBlock(r):
        break
      io.writeFailedAt(c)
      return
    if r > 0:
      c.lastProgress = Moment.now()
      cancelTimer(c.stallTimer)
    c.outOff += int(r)
    if c.outOff == c.outq[0].data.len:
      var f = c.outq.popFirst
      c.outOff = 0
      io.dropFrame(c, f)
      released = released or f.pooled > 0
  if c.outq.len == 0 and c.phase == phLinger:
    io.finalClose(c)
    if released:
      io.wakeOutput()
    return
  io.updateWriting(c)
  if released:
    if c.established:
      io.drainPending(c)
    io.wakeOutput()

proc onWritable(arg: pointer) {.gcsafe, raises: [].} =
  let io = theIo
  if io.isNil:
    return
  let c = io.lookup(argKey(arg))
  if c.isNil or c.phase == phDone:
    return
  io.flush(c)

proc onStall(arg: pointer) {.gcsafe, raises: [].} =
  ## [SPEC TRANSPORT §3.2, §5.2] Output pending and no byte written for
  ## `writeStallTimeout`: the peer is not writable. Close without ProtocolError.
  let io = theIo
  if io.isNil:
    return
  let c = io.lookup(argKey(arg))
  if c.isNil or c.phase == phDone:
    return
  c.stallTimer = nil
  if c.outq.len == 0 or c.writeFailed:
    return
  if Moment.now() - c.lastProgress < nanoseconds(io.config.writeStallTimeout):
    io.armStall(c)
    return
  io.dropOutput(c)
  if c.phase == phLinger:
    io.finalClose(c)
  else:
    io.closeConn(c, ccNotWritable, ecTransport)

proc dataRoom(io: Io, c: Conn): int =
  io.config.connOutputBytes - io.config.controlReserve - c.dataBytes

proc commit*(
    io: Io, c: Conn, body: openArray[byte], cls: FrameClass, secret = false
): bool =
  ## Appends one frame to the connection's ordered output: it is committed.
  ## False, and nothing committed, when there is no room: a data frame then
  ## waits or fails; a control frame has exhausted the control reserve.
  if c.closed or c.writeFailed or c.phase == phConnecting:
    return false
  let n = body.len + 4
  var f = OutFrame(secret: secret)
  if n <= io.dataRoom(c) and io.outputPool.tryReserve(n):
    f.pooled = n
    c.dataBytes += n
  elif cls == fcControl and c.reserveBytes + n <= io.config.controlReserve:
    f.reserve = n
    c.reserveBytes += n
  else:
    return false
  f.data = framed(body)
  if c.outq.len == 0:
    c.lastProgress = Moment.now()
  c.outq.addLast(move f)
  io.updateWriting(c)
  true

proc commitControl*(io: Io, c: Conn, body: openArray[byte]) =
  ## [SPEC TRANSPORT §6, §8.6] A control frame, or, once the control reserve is
  ## spent, ProtocolError TRANSPORT_ERROR from the final slot and close.
  if not io.commit(c, body, fcControl):
    if not c.closed:
      io.closeConn(c, ccProtocol, ecTransport, Opt.some(protocolErrorBody(ecTransport)))

# ok-Responses ----------------------------------------------------------------------

proc refreshSession*(io: Io, c: Conn) =
  ## Reading follows the session's admission (`maxInFlight`, §8.6).
  if c.role == roCallee and c.established:
    if c.callee.admitsInput:
      if hSession in c.holds:
        io.unhold(c, hSession)
    elif hSession notin c.holds:
      io.hold(c, hSession)

proc commitResponse(io: Io, c: Conn, id: uint64, outcome: Outcome) =
  let bytes = c.callee.respond(id, outcome)
  if bytes.isSome:
    c.dispatched.excl(id)
    let cls = if outcome.ok: fcData else: fcControl
    if not io.commit(c, bytes.get, cls) and cls == fcControl and not c.closed:
      io.closeConn(c, ccProtocol, ecTransport, Opt.some(protocolErrorBody(ecTransport)))
  if not c.closed:
    io.refreshSession(c)

proc fitsNow*(io: Io, c: Conn, size: int): bool =
  ## Whether a data frame of `size` bytes, prefix included, can be committed now.
  size <= io.dataRoom(c) and size <= io.outputPool.available

proc drainPending(io: Io, c: Conn) =
  ## Commits waiting ok-Responses, in order, while they fit; a request whose
  ## CANCELLED was committed meanwhile is discarded.
  while c.pending.len > 0 and c.established:
    let p = addr c.pending[0]
    if not c.callee.isInFlight(p.id):
      discard c.pending.popFirst
      continue
    if not io.fitsNow(c, p.size):
      if p.size <= io.dataRoom(c) and not c.outWaiting:
        # Blocked by the loop-wide pool, not by this connection.
        c.outWaiting = true
        io.outWaiters.addLast(c.key)
      return
    let r = c.pending.popFirst
    io.commitResponse(c, r.id, Outcome(ok: true, response: r.response))

func okFrameSize*(io: Io, resultLen: int): int =
  ## An upper bound of the frame of an ok-Response whose encoded result map
  ## has `resultLen` bytes, prefix included.
  io.responseOverhead + resultLen

proc respondOutcome*(io: Io, c: Conn, id: uint64, outcome: Outcome, resultLen = 0) =
  ## [SPEC TRANSPORT §4.1, §6] The terminal Response of request `id`
  ## (`resultLen`: the encoded result map's length, for an ok one). An
  ## ok-Response that does not fit the output budgets now waits, uncommitted;
  ## it is never dropped for capacity, and the write-stall timer bounds the wait.
  if not c.established or not c.callee.isInFlight(id):
    return
  if outcome.ok:
    let size = io.okFrameSize(resultLen)
    if c.pending.len > 0 or not io.fitsNow(c, size):
      c.pending.addLast(PendingResponse(id: id, response: outcome.response, size: size))
      io.drainPending(c)
      return
  io.commitResponse(c, id, outcome)

# Closing ---------------------------------------------------------------------------

proc onLinger(arg: pointer) {.gcsafe, raises: [].} =
  let io = theIo
  if io.isNil:
    return
  let c = io.lookup(argKey(arg))
  if c.isNil or c.phase != phLinger:
    return
  c.lingerTimer = nil
  io.finalClose(c)

proc finalClose*(io: Io, c: Conn) =
  ## Closes the fd and releases everything the connection holds.
  if c.phase == phDone:
    return
  c.phase = phDone
  for t in [
    addr c.stallTimer,
    addr c.helloTimer,
    addr c.admitTimer,
    addr c.lingerTimer,
    addr c.retryTimer,
  ]:
    cancelTimer(t[])
  if c.reading:
    discard removeReader2(AsyncFD(c.fd))
    c.reading = false
  if c.writing:
    discard removeWriter2(AsyncFD(c.fd))
    c.writing = false
  if c.registered:
    discard unregister2(AsyncFD(c.fd))
    c.registered = false
  if c.fd >= 0:
    discard fdClose(c.fd)
    c.fd = -1
  io.dropOutput(c)
  zero(c.hello)
  c.hello = @[]
  if c.reserved > 0:
    let n = c.reserved
    c.reserved = 0
    io.releaseInput(n, c.helloPool)
  c.body = @[]
  c.pending.clear()
  io.byKey.del(c.key)
  if io.conns.getOrDefault(c.id) == c:
    io.conns.del(c.id)

proc report(
    io: Io,
    c: Conn,
    cause: CloseCause,
    code: ErrorCode,
    ids: seq[uint64],
    failure: Opt[ConnectFail],
) =
  case c.role
  of roCallee:
    var all = ids
    for id in c.dispatched:
      all.add(id)
    c.dispatched.clear()
    if c.established:
      c.callee.state = csClosed
    all.sort()
    io.emit(IoEvent(conn: c.id, kind: evClosed, cause: cause, code: code, ids: all))
  of roCaller:
    if c.connected:
      var tags = ids
      for ev in c.caller.close():
        if ev.kind == ceResponse:
          var tag: uint64
          if c.toTag.pop(ev.id, tag):
            c.toWire.del(tag)
            tags.add(tag)
            io.emit(
              IoEvent(
                conn: c.id,
                kind: evResponse,
                tag: tag,
                outcome:
                  CallOutcome(ok: false, failure: InvocationFailure(code: ecTransport)),
              )
            )
      tags.sort()
      io.emit(IoEvent(conn: c.id, kind: evClosed, cause: cause, code: code, ids: tags))
    else:
      # [SPEC RUNTIME §4.1] Before establishment: a ProtocolError's code passes
      # through; loss, the deadline and a stall are TRANSPORT_ERROR.
      let f =
        if failure.isSome:
          failure.get
        else:
          case cause
          of ccShutdown:
            ConnectFail(
              code: ecTransport, cause: cfShutdown, msg: "the loop is stopping"
            )
          of ccPeerError, ccProtocol:
            ConnectFail(code: code, cause: cfHello, msg: $cause)
          else:
            ConnectFail(code: ecTransport, cause: cfHello, msg: $cause)
      io.emit(
        IoEvent(
          conn: c.id,
          kind: evConnectFailed,
          failCode: f.code,
          failCause: f.cause,
          observed: f.observed,
          failMsg: f.msg,
        )
      )

proc closeConn*(
    io: Io,
    c: Conn,
    cause: CloseCause,
    code = ecOk,
    final = Opt.none(seq[byte]),
    ids: seq[uint64] = @[],
    failure = Opt.none(ConnectFail),
) =
  ## Reports the close (`evClosed`, or `evConnectFailed` for a caller not yet
  ## established), stops reading, commits `final` (a ProtocolError) after the
  ## frames already committed, and closes once they are flushed or
  ## `closeLinger` passed.
  if c.closed:
    return
  io.report(c, cause, code, ids, failure)
  if c.inbound:
    dec io.inbound
    c.inbound = false
  if c.pendingHello:
    dec io.pendingHellos
    c.pendingHello = false
  if c.outboundCounted:
    dec io.outbound
    c.outboundCounted = false
  let wasConnecting = c.phase == phConnecting
  c.phase = phLinger
  for t in [addr c.helloTimer, addr c.admitTimer, addr c.retryTimer]:
    cancelTimer(t[])
  io.updateReading(c)
  if c.reserved > 0:
    let n = c.reserved
    c.reserved = 0
    io.releaseInput(n, c.helloPool)
  c.body = @[]
  c.pending.clear()
  if io.conns.getOrDefault(c.id) == c:
    io.conns.del(c.id)
  if final.isSome and not c.writeFailed and not wasConnecting and c.registered:
    # The final slot: never refused, outside the budgets (aggregate.nim).
    if c.outq.len == 0:
      c.lastProgress = Moment.now()
    c.outq.addLast(OutFrame(data: framed(final.get)))
  if c.outq.len == 0 or c.writeFailed or not c.registered:
    io.finalClose(c)
    return
  c.lingerTimer = setTimer(fromNow(io.config.closeLinger), onLinger, keyArg(c.key))
  io.updateWriting(c)

# Timers for the Hello exchange -----------------------------------------------------

proc onHelloTimeout(arg: pointer) {.gcsafe, raises: [].} =
  ## [SPEC TRANSPORT §8.6; G61] The Hello exchange did not finish in time. A
  ## callee closes without a ProtocolError [IMPL]; a caller reports
  ## TRANSPORT_ERROR (RUNTIME §4.1).
  let io = theIo
  if io.isNil:
    return
  let c = io.lookup(argKey(arg))
  if c.isNil or c.closed or c.established:
    return
  c.helloTimer = nil
  io.closeConn(c, ccHelloTimeout, ecTransport)

proc armHello*(io: Io, c: Conn) =
  c.deadline = fromNow(io.config.helloTimeout)
  c.helloTimer = setTimer(c.deadline, onHelloTimeout, keyArg(c.key))

proc helloDone*(c: Conn) =
  cancelTimer(c.helloTimer)
